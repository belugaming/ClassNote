import XCTest
@testable import ClassNote

final class WavEncoderTests: XCTestCase {
    func testEncodeProducesValidRIFFHeader() {
        let pcm = Data(repeating: 0, count: 32000)  // 1s of silence at 16k mono
        let wav = WavEncoder.encode(pcm16: pcm, sampleRate: 16000, channels: 1)
        XCTAssertGreaterThan(wav.count, 44)
        // RIFF header signature
        XCTAssertEqual(wav.subdata(in: 0..<4), "RIFF".data(using: .ascii))
        // WAVE format
        XCTAssertEqual(wav.subdata(in: 8..<12), "WAVE".data(using: .ascii))
        XCTAssertEqual(wav.subdata(in: 12..<16), "fmt ".data(using: .ascii))
        // data chunk
        XCTAssertEqual(wav.subdata(in: 36..<40), "data".data(using: .ascii))
    }

    func testEncodeSampleRateInHeader() {
        let pcm = Data(repeating: 0, count: 320)
        let wav = WavEncoder.encode(pcm16: pcm, sampleRate: 16000, channels: 1)
        // bytes 24-27 = sample rate little-endian
        let rate = wav.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self).littleEndian
        }
        XCTAssertEqual(rate, 16000)
    }
}

final class VADTests: XCTestCase {
    func testSilenceProducesLowRMS() {
        let silence = Data(repeating: 0, count: 16000 * 2)  // 1s silence
        let rms = VADGate.rms(pcm16: silence)
        XCTAssertEqual(rms, 0, accuracy: 1e-6)
    }

    func testToneProducesHighRMS() {
        // 1 kHz tone at amplitude 0.5 for 1s @ 16k
        let n = 16000
        var data = Data(capacity: n * 2)
        for i in 0..<n {
            let t = Double(i) / 16000.0
            let v = sin(2 * .pi * 1000 * t) * 0.5
            let s = Int16(v * 32767.0)
            withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) }
        }
        let rms = VADGate.rms(pcm16: data)
        XCTAssertGreaterThan(rms, 0.3)
    }

    func testGatePassesSpeechAndSuppressesSilence() async {
        let gate = VADGate(rmsThreshold: 0.05)
        // Loud chunk
        let n = 1600
        var loud = Data(capacity: n * 2)
        for i in 0..<n {
            let t = Double(i) / 16000.0
            let v = sin(2 * .pi * 440 * t) * 0.8
            let s = Int16(v * 32767.0)
            withUnsafeBytes(of: s.littleEndian) { loud.append(contentsOf: $0) }
        }
        let silent = Data(repeating: 0, count: n * 2)
        let chunkLoud = AudioChunk(pcmData: loud, sampleRate: 16000, timestamp: 0)
        let chunkSilent = AudioChunk(pcmData: silent, sampleRate: 16000, timestamp: 100)
        let pass1 = await gate.shouldPass(chunk: chunkLoud)
        let pass2 = await gate.shouldPass(chunk: chunkSilent)
        XCTAssertTrue(pass1, "Loud chunk must pass VAD")
        // Within hangover window so should still pass
        XCTAssertTrue(pass2, "Silent chunk within hangover should still pass")
    }
}

final class DatabaseTests: XCTestCase {
    func testSetupCreatesAllTables() throws {
        // Reuse the shared DB; the migrator is idempotent.
        try Database.shared.setup()
        let tables: [String] = try Database.shared.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        for required in ["course", "session", "segment", "highlight", "note", "api_config"] {
            XCTAssertTrue(tables.contains(required), "Missing table \(required)")
        }
        let virtualTables: [String] = try Database.shared.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name='segment_fts'")
        }
        XCTAssertTrue(virtualTables.contains("segment_fts"))
    }

    func testFTSRoundTrip() async throws {
        try Database.shared.setup()
        let course = Course.new(name: "Test Course")
        try await CourseRepository.shared.insert(course)
        let session = Session.new(courseId: course.id, title: "Test session")
        try await SessionRepository.shared.insert(session)

        let seg = Segment(id: nil, sessionId: session.id, startMs: 0, endMs: 1000,
                           speakerId: nil, textOriginal: "The quick brown fox jumps over the lazy dog",
                           textTranslated: "敏捷的棕色狐狸跳过懒狗", isFinal: true,
                           confidence: 0.9, version: 1)
        let id = try await SegmentRepository.shared.insert(seg)
        XCTAssertGreaterThan(id, 0)

        let hits = try await SegmentRepository.shared.searchFTS(query: "brown", limit: 10)
        XCTAssertTrue(hits.contains(where: { $0.segment.id == id }))

        // Cleanup
        try await SessionRepository.shared.delete(id: session.id)
        try await CourseRepository.shared.delete(id: course.id)
    }

    func testApiConfigPersistence() async throws {
        try Database.shared.setup()
        var c = try await ApiConfigRepository.shared.load()
        c.baseUrl = "https://example.test/v1"
        c.apiKey = "test-secret-key-do-not-keep"
        c.translationModel = "test-translation-model"
        try await ApiConfigRepository.shared.save(c)

        let reloaded = try await ApiConfigRepository.shared.load()
        XCTAssertEqual(reloaded.baseUrl, "https://example.test/v1")
        XCTAssertEqual(reloaded.translationModel, "test-translation-model")
        XCTAssertEqual(reloaded.redactedKey, "test…keep")

        // Restore default
        try await ApiConfigRepository.shared.save(.default)
    }
}

final class TranscriptBufferTests: XCTestCase {
    @MainActor
    func testAppendAndUpdateTranslation() {
        let buf = TranscriptBuffer()
        buf.appendFinal(rowId: 1, startMs: 0, endMs: 1000, original: "Hello world")
        buf.appendFinal(rowId: 2, startMs: 1000, endMs: 2000, original: "How are you")
        XCTAssertEqual(buf.segments.count, 2)
        buf.appendTranslationDelta(rowId: 1, delta: "你好")
        buf.appendTranslationDelta(rowId: 1, delta: "世界")
        XCTAssertEqual(buf.segments[0].translated, "你好世界")
        buf.updateTranslation(rowId: 2, translated: "你怎么样")
        XCTAssertEqual(buf.segments[1].translated, "你怎么样")
        XCTAssertEqual(buf.recent(1), ["How are you"])
    }
}

final class ShouldEmitTests: XCTestCase {
    func testRejectsEmptyAndJunk() {
        XCTAssertFalse(OpenAICompatibleSTT.shouldEmit("", minChars: 3))
        XCTAssertFalse(OpenAICompatibleSTT.shouldEmit("   ", minChars: 3))
        XCTAssertFalse(OpenAICompatibleSTT.shouldEmit("...", minChars: 3))
        XCTAssertFalse(OpenAICompatibleSTT.shouldEmit("The.", minChars: 3))
        XCTAssertFalse(OpenAICompatibleSTT.shouldEmit("you", minChars: 3))
        XCTAssertFalse(OpenAICompatibleSTT.shouldEmit("Thank you.", minChars: 3))
        XCTAssertFalse(OpenAICompatibleSTT.shouldEmit("[BLANK_AUDIO]", minChars: 3))
    }

    func testAcceptsRealSentences() {
        XCTAssertTrue(OpenAICompatibleSTT.shouldEmit("Welcome to the lecture.", minChars: 3))
        XCTAssertTrue(OpenAICompatibleSTT.shouldEmit("Today we will cover eigenvectors.", minChars: 3))
        XCTAssertTrue(OpenAICompatibleSTT.shouldEmit("大家好", minChars: 3))
    }

    func testRejectsTooFewLetters() {
        XCTAssertFalse(OpenAICompatibleSTT.shouldEmit("!!", minChars: 3))
        XCTAssertFalse(OpenAICompatibleSTT.shouldEmit(". . .", minChars: 3))
    }
}
