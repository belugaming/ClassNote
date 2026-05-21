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
        for required in ["course", "session", "segment", "highlight", "note", "api_config", "flashcard", "study_tool_result"] {
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

    func testSessionCanMoveBetweenCoursesAndUnfiled() async throws {
        try Database.shared.setup()
        let sourceCourse = Course.new(name: "Source Course")
        let targetCourse = Course.new(name: "Target Course")
        try await CourseRepository.shared.insert(sourceCourse)
        try await CourseRepository.shared.insert(targetCourse)

        let session = Session.new(courseId: sourceCourse.id, title: "Movable session")
        try await SessionRepository.shared.insert(session)

        try await SessionRepository.shared.move(id: session.id, toCourseId: targetCourse.id)
        var reloaded = try await SessionRepository.shared.get(id: session.id)
        XCTAssertEqual(reloaded?.courseId, targetCourse.id)

        try await SessionRepository.shared.move(id: session.id, toCourseId: nil)
        reloaded = try await SessionRepository.shared.get(id: session.id)
        XCTAssertNil(reloaded?.courseId)

        try await SessionRepository.shared.delete(id: session.id)
        try await CourseRepository.shared.delete(id: sourceCourse.id)
        try await CourseRepository.shared.delete(id: targetCourse.id)
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
        XCTAssertEqual(reloaded.apiKey, "test-secret-key-do-not-keep")
        XCTAssertEqual(reloaded.translationModel, "test-translation-model")
        XCTAssertEqual(reloaded.redactedKey, "test…keep")

        let rawDatabaseKey: String = try await Database.shared.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT api_key FROM api_config WHERE id=1") ?? ""
        }
        XCTAssertEqual(rawDatabaseKey, "", "API key should live in Keychain, not SQLite")

        // Restore default
        try await ApiConfigRepository.shared.save(.default)
    }

    func testFlashcardPersistenceAndOrdering() async throws {
        try Database.shared.setup()
        let session = Session.new(courseId: nil, title: "Flashcard source")
        try await SessionRepository.shared.insert(session)

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let cards = [
            Flashcard(id: nil, sessionId: session.id, front: "What is ATP?", back: "Energy carrier", sourceModel: "test-model", createdAt: now, sortOrder: 99),
            Flashcard(id: nil, sessionId: session.id, front: "Define osmosis", back: "Water diffusion", sourceModel: "test-model", createdAt: now, sortOrder: 99)
        ]
        try await FlashcardRepository.shared.replace(sessionId: session.id, cards: cards)

        let loaded = try await FlashcardRepository.shared.all(sessionId: session.id)
        XCTAssertEqual(loaded.map(\.front), ["What is ATP?", "Define osmosis"])
        XCTAssertEqual(loaded.map(\.sortOrder), [0, 1])

        try await SessionRepository.shared.delete(id: session.id)
    }

    func testFlashcardsMarkdownExport() {
        let session = Session.new(courseId: nil, title: "Biology 101")
        let input = SessionExporter.Input(
            session: session,
            segments: [],
            note: nil,
            highlights: [],
            flashcards: [
                Flashcard(id: nil, sessionId: session.id, front: "What is ATP?", back: "Energy carrier", sourceModel: nil, createdAt: 1, sortOrder: 0)
            ],
            studyToolResults: [])

        let md = SessionExporter.flashcardsMarkdown(input)
        XCTAssertTrue(md.contains("# Biology 101 Flashcards"))
        XCTAssertTrue(md.contains("**Front:** What is ATP?"))
        XCTAssertTrue(md.contains("**Back:** Energy carrier"))
    }

    func testStudyToolResultPersistence() async throws {
        try Database.shared.setup()
        let session = Session.new(courseId: nil, title: "Study tool source")
        try await SessionRepository.shared.insert(session)

        let result = StudyToolResult(id: UUID().uuidString,
                                     sessionId: session.id,
                                     toolId: "catch_up",
                                     markdown: "# Catch up",
                                     model: "test-model",
                                     generatedAt: 10)
        try await StudyToolResultRepository.shared.upsert(result)

        let loaded = try await StudyToolResultRepository.shared.get(sessionId: session.id, toolId: "catch_up")
        XCTAssertEqual(loaded?.markdown, "# Catch up")

        try await SessionRepository.shared.delete(id: session.id)
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

final class OverlayCaptionFormatterTests: XCTestCase {
    func testOverlayCaptionTailKeepsLatestLogicalLines() {
        let text = """
        First sentence.
        Second sentence.
        Third sentence.
        Fourth sentence.
        """

        let tail = text.overlayCaptionTail(maxLines: 2)
        XCTAssertFalse(tail.contains("First sentence"))
        XCTAssertTrue(tail.contains("Third sentence"))
        XCTAssertTrue(tail.contains("Fourth sentence"))
    }

    func testOverlayCaptionTailBoundsVeryLongText() {
        let text = String(repeating: "linear algebra ", count: 80)
        let tail = text.overlayCaptionTail(maxLines: 1)
        XCTAssertLessThanOrEqual(tail.count, 86)
        XCTAssertFalse(tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

final class TranscriptTextPolisherTests: XCTestCase {
    func testPolishNormalizesSpacingAndCapitalization() {
        let polished = TranscriptTextPolisher.polish("  today   we discuss teh matrix , eigenvalues . ")
        XCTAssertEqual(polished, "Today we discuss the matrix, eigenvalues.")
    }

    func testPolishLeavesChineseTextReadable() {
        let polished = TranscriptTextPolisher.polish("  今天   我们 学 线性代数 。  ")
        XCTAssertEqual(polished, "今天 我们 学 线性代数。")
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
