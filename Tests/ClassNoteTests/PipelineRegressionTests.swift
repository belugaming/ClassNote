import CoreMedia
import Foundation
import XCTest
@testable import ClassNote

/// Regressions for the capture/pipeline bugs. The audio ones drive the mix bus
/// by hand rather than through its timer, so the arithmetic is checked without
/// a device and without waiting on wall clock.
final class PipelineRegressionTests: XCTestCase {

    // MARK: - Helpers

    /// Collects the bus's output. A class because the bus's sink is `@Sendable`
    /// and cannot capture a mutable local.
    private final class MixCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(pcm: [Int16], pts: Int64)] = []

        var frames: [(pcm: [Int16], pts: Int64)] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ data: Data, _ pts: Int64) {
            lock.lock()
            storage.append((PipelineRegressionTests.samples(from: data), pts))
            lock.unlock()
        }
    }

    private static func pcm(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    fileprivate static func samples(from data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    private func makeBus(_ collector: MixCollector, backlogMs: Int = 400) -> AudioMixBus {
        AudioMixBus(sampleRate: 16000, frameMs: 100, backlogMs: backlogMs) { data, pts, _ in
            collector.append(data, pts)
        }
    }

    // MARK: - C6: the mix bus is the single producer

    func testSingleSourceIsPassedThroughUnattenuated() {
        let collector = MixCollector()
        let bus = makeBus(collector)
        bus.activate(.microphone)

        let first = (0..<1600).map { Int16(truncatingIfNeeded: $0 * 7 - 16000) }
        let second = (0..<1600).map { Int16(truncatingIfNeeded: 12000 - $0 * 3) }
        bus.submit(Self.pcm(first + second), from: .microphone)

        XCTAssertTrue(bus.tick())
        XCTAssertTrue(bus.tick())
        XCTAssertFalse(bus.tick(), "nothing buffered, so nothing should be emitted")

        XCTAssertEqual(collector.frames.count, 2)
        XCTAssertEqual(collector.frames[0].pcm, first)
        XCTAssertEqual(collector.frames[1].pcm, second)
        // Sample-derived PTS: the second block starts exactly one frame chunk in.
        XCTAssertEqual(collector.frames[0].pts, 0)
        XCTAssertEqual(collector.frames[1].pts, 1600)
    }

    func testTwoSourcesAreSummedWithClipping() {
        let collector = MixCollector()
        let bus = makeBus(collector)
        bus.activate(.microphone)
        bus.activate(.system)

        var mic = [Int16](repeating: 0, count: 1600)
        var system = [Int16](repeating: 0, count: 1600)
        mic[0] = 20_000;  system[0] = 20_000      // clips positive
        mic[1] = -20_000; system[1] = -20_000     // clips negative
        mic[2] = 10_000;  system[2] = -3_000      // ordinary sum
        bus.submit(Self.pcm(mic), from: .microphone)
        bus.submit(Self.pcm(system), from: .system)

        XCTAssertTrue(bus.tick())
        let mixed = collector.frames[0].pcm
        XCTAssertEqual(mixed.count, 1600)
        XCTAssertEqual(mixed[0], Int16.max)
        XCTAssertEqual(mixed[1], Int16.min)
        XCTAssertEqual(mixed[2], 7_000)
        XCTAssertEqual(mixed[3], 0)
    }

    func testStalledSourceIsZeroFilledInsteadOfStallingTheMix() {
        let collector = MixCollector()
        let bus = makeBus(collector)
        bus.activate(.microphone)
        bus.activate(.system)

        // System audio has not delivered its first buffer yet — mixed mode must
        // still emit, or nothing is ever written or transcribed.
        let mic = (0..<1600).map { Int16(truncatingIfNeeded: $0) }
        bus.submit(Self.pcm(mic), from: .microphone)

        XCTAssertTrue(bus.tick())
        XCTAssertEqual(collector.frames.count, 1)
        XCTAssertEqual(collector.frames[0].pcm, mic)
    }

    func testBacklogIsCappedSoAWedgedSourceCannotGrowMemory() {
        let collector = MixCollector()
        let bus = makeBus(collector, backlogMs: 400)
        bus.activate(.microphone)

        // One second submitted at once: 1600 frames are emitted and the rest is
        // trimmed to the 400 ms ceiling, so only four more ticks have anything.
        bus.submit(Self.pcm([Int16](repeating: 999, count: 16_000)), from: .microphone)

        var emitted = 0
        while bus.tick() {
            emitted += 1
            XCTAssertLessThan(emitted, 12, "backlog was not capped")
        }
        XCTAssertEqual(emitted, 5)
        XCTAssertEqual(collector.frames.count, 5)
    }

    func testFinishFlushesThePartialTail() {
        let collector = MixCollector()
        let bus = makeBus(collector)
        bus.activate(.microphone)
        bus.submit(Self.pcm([Int16](repeating: 42, count: 400)), from: .microphone)

        // Mid-recording a part-filled chunk waits rather than splicing silence
        // into the timeline...
        XCTAssertFalse(bus.tick())
        // ...but the tail must still reach the file when capture stops.
        bus.finish()
        XCTAssertEqual(collector.frames.count, 1)
        XCTAssertEqual(collector.frames[0].pcm.count, 1600)
        XCTAssertEqual(Array(collector.frames[0].pcm.prefix(400)),
                       [Int16](repeating: 42, count: 400))
        XCTAssertEqual(collector.frames[0].pcm[400], 0)
    }

    // MARK: - U3: PCM reaches the fragmented writer with its own timeline

    func testMakeSampleBufferCarriesFrameCountAndPTS() throws {
        let data = Self.pcm([Int16](repeating: 1_234, count: 1600))
        let buffer = try XCTUnwrap(FileWriter.makeSampleBuffer(data, sampleRate: 16000, ptsFrames: 32_000))

        XCTAssertEqual(CMSampleBufferGetNumSamples(buffer), 1600)
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        XCTAssertEqual(pts.value, 32_000)
        XCTAssertEqual(pts.timescale, 16_000)
        XCTAssertEqual(CMTimeGetSeconds(pts), 2.0, accuracy: 0.0001)
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(buffer), 3200)
    }

    // MARK: - U8: reconnect rebases the engine clock

    func testShiftedRebasesTimestampsAndKeepsEverythingElse() {
        let event = TranscriptEvent(startMs: 100,
                                    endMs: 900,
                                    text: "hello",
                                    isFinal: true,
                                    speakerId: "spk",
                                    continuesSentence: true)
        let shifted = event.shifted(by: 5_000)

        XCTAssertEqual(shifted.startMs, 5_100)
        XCTAssertEqual(shifted.endMs, 5_900)
        XCTAssertEqual(shifted.text, "hello")
        XCTAssertEqual(shifted.speakerId, "spk")
        XCTAssertTrue(shifted.continuesSentence)
        // The first connection has nothing to rebase, so the event is untouched.
        XCTAssertEqual(event.shifted(by: 0).id, event.id)
    }

    // MARK: - C18: a cancelled task stays cancelled

    @MainActor
    func testCancelledTaskCenterItemIsNotOverwrittenBySuccess() {
        let center = TaskCenter()
        let id = center.start(title: "Import file", detail: "lecture.m4a", icon: "square.and.arrow.down")

        center.cancel(id: id, detail: "Import cancelled")
        // The import's own completion path reports success moments later.
        center.succeed(id: id, detail: "Import finished")

        XCTAssertEqual(center.items.first?.status, .cancelled)
        XCTAssertEqual(center.items.first?.detail, "Import cancelled")
    }

    // MARK: - C18: a cancelled import is recorded honestly

    @MainActor
    func testCancelledImportIsMarkedFailedAndReportsCancellation() async throws {
        try ClassNote.Database.shared.setup()
        let wasTranslating = AppState.shared.translationEnabled
        AppState.shared.translationEnabled = false
        defer { AppState.shared.translationEnabled = wasTranslating }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-import-\(UUID().uuidString).m4a")
        try Data("not audio, the engine is a stub".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let orchestrator = SessionOrchestrator()
        orchestrator.sttProviderOverride = ParkingSTTProvider()
        let sessionId = try await orchestrator.ingestFile(url: url, courseId: nil)
        addTeardownBlock {
            try? await SessionRepository.shared.delete(id: sessionId, force: true)
        }

        // Wait for the one segment the stub emits before it parks, so the import
        // is genuinely mid-flight when it is cancelled.
        var waited = 0
        while orchestrator.transcript.segments.isEmpty, waited < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        XCTAssertFalse(orchestrator.transcript.segments.isEmpty, "stub engine never emitted")

        await orchestrator.stop()

        do {
            try await orchestrator.waitForImportToFinish()
            XCTFail("a cancelled import must not report success")
        } catch is CancellationError {
            // expected
        }

        let session = try await SessionRepository.shared.get(id: sessionId)
        XCTAssertEqual(session?.state, SessionState.failed.rawValue)
        // Kept so the session can be re-transcribed later.
        XCTAssertEqual(session?.audioPath, url.path)
        // The partial transcript survives the cancellation.
        let segments = try await SegmentRepository.shared.all(sessionId: sessionId)
        XCTAssertEqual(segments.count, 1)
    }

    // MARK: - U7: a cancelled re-transcription is not a failed session

    /// `replaceAll` only runs at the very end, so a cancelled re-transcription
    /// has changed nothing — marking the row `failed` would brand a complete,
    /// healthy session broken with no way back.
    @MainActor
    func testCancelledRetranscriptionLeavesTheSessionTranscribed() async throws {
        try ClassNote.Database.shared.setup()
        let wasTranslating = AppState.shared.translationEnabled
        AppState.shared.translationEnabled = false
        defer { AppState.shared.translationEnabled = wasTranslating }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-retranscribe-\(UUID().uuidString).m4a")
        try Data("not audio, the engine is a stub".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var sess = Session.new(courseId: nil, title: "Lecture", sourceKind: "mic")
        sess.audioPath = url.path
        sess.state = SessionState.transcribed.rawValue
        sess.endedAt = sess.startedAt + 1_000
        sess.durationMs = 1_000
        let sessionId = sess.id
        try await SessionRepository.shared.insert(sess)
        addTeardownBlock {
            try? await SessionRepository.shared.delete(id: sessionId, force: true)
        }
        _ = try await SegmentRepository.shared.insert(Segment(id: nil,
                                                               sessionId: sessionId,
                                                               startMs: 0,
                                                               endMs: 1_000,
                                                               speakerId: nil,
                                                               textOriginal: "original transcript",
                                                               textTranslated: "",
                                                               isFinal: true,
                                                               confidence: 0,
                                                               version: 1))

        let orchestrator = SessionOrchestrator()
        orchestrator.sttProviderOverride = ParkingSTTProvider()
        _ = try await orchestrator.retranscribeSession(sess)

        var waited = 0
        while orchestrator.transcript.segments.isEmpty, waited < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        XCTAssertFalse(orchestrator.transcript.segments.isEmpty, "stub engine never emitted")

        await orchestrator.stop()
        do {
            try await orchestrator.waitForImportToFinish()
            XCTFail("a cancelled re-transcription must not report success")
        } catch is CancellationError {
            // expected
        }

        let refreshed = try await SessionRepository.shared.get(id: sessionId)
        XCTAssertEqual(refreshed?.state, SessionState.transcribed.rawValue)
        let segments = try await SegmentRepository.shared.all(sessionId: sessionId)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.textOriginal, "original transcript")
    }
}

/// Emits one segment and then never finishes, the way a sidecar chewing through
/// a long file behaves: the only way out is cancellation.
private struct ParkingSTTProvider: STTProvider {
    func transcribe(audio: AsyncStream<AudioChunk>,
                    language: String?) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { _ in }
    }

    func transcribeFile(url: URL,
                        language: String?) -> AsyncThrowingStream<FileTranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.progress(completed: 1, total: 10))
            continuation.yield(.segment(TranscriptEvent(startMs: 0,
                                                        endMs: 1_000,
                                                        text: "first slice",
                                                        isFinal: true)))
        }
    }
}

// MARK: - Whole-sentence translation

final class SentenceGroupsTests: XCTestCase {
    private func line(_ id: Int64, _ text: String, continues: Bool = false) -> Segment {
        Segment(id: id, sessionId: "s", startMs: id * 1000, endMs: id * 1000 + 900,
                speakerId: nil, textOriginal: text, textTranslated: "", isFinal: true,
                confidence: 0, version: 1, continuesNext: continues)
    }

    func testLinesCutMidSentenceJoinTheLineThatEndsIt() {
        let groups = SentenceGroups.group([
            line(1, "First part of it,", continues: true),
            line(2, "and the rest."),
            line(3, "A whole sentence."),
        ])
        XCTAssertEqual(groups.map { $0.compactMap(\.id) }, [[1, 2], [3]])
    }

    func testASentenceLeftOpenAtTheEndIsStillAGroup() {
        let groups = SentenceGroups.group([line(1, "Done."), line(2, "Cut off", continues: true)])
        XCTAssertEqual(groups.map { $0.compactMap(\.id) }, [[1], [2]])
    }

    func testJoinSpacesLatinButNotCJK() {
        XCTAssertEqual(SentenceGroups.join(["first part,", "and the rest."]),
                       "first part, and the rest.")
        XCTAssertEqual(SentenceGroups.join(["糖酵解发生在", "细胞质中。"]), "糖酵解发生在细胞质中。")
        XCTAssertEqual(SentenceGroups.join(["这叫做", "glycolysis"]), "这叫做glycolysis")
        XCTAssertEqual(SentenceGroups.join(["", " spaced ", "out"]), "spaced out")
    }

    func testSettledStates() {
        XCTAssertTrue(TranslationState.ok.isSettled)
        XCTAssertTrue(TranslationState.merged.isSettled)
        XCTAssertFalse(TranslationState.failed.isSettled)
        XCTAssertFalse(TranslationState.notAttempted.isSettled)
    }
}

final class TranslationGlossaryTests: XCTestCase {
    func testPairsAcceptTheSeparatorsStudentsUse() {
        let glossary = TranslationGlossary(raw: """
        eigenvalue = 特征值
        kernel -> 核
        矩阵：matrix
        no separator here
         = missing term
        """)
        let pairs = glossary.pairs
        XCTAssertEqual(pairs.map(\.0), ["eigenvalue", "kernel", "矩阵"])
        XCTAssertEqual(pairs.map(\.1), ["特征值", "核", "matrix"])
    }

    func testRecognitionHintNamesTheCourseAndItsTerms() {
        var context = CourseContext()
        context.courseName = "Linear Algebra"
        context.glossary = "eigenvalue = 特征值\nkernel = 核"
        XCTAssertEqual(context.recognitionHint, "Linear Algebra\neigenvalue, kernel")
        XCTAssertEqual(CourseContext.empty.recognitionHint, "")
    }
}
