import AVFoundation
import Foundation
import XCTest
@testable import ClassNote

/// Regressions for the capture and live-pipeline bugs found before release:
/// the mic restart's watchdog and the bus across a mic gap (P1), timestamps
/// after an STT reconnect (P2), the reconnect counter (P3), the system-audio
/// resampler (P4), bookmarks and duration on the bus clock (P5), and a stale
/// half-sentence after toggling translation (P6). The live paths run through
/// the real orchestrator on a capture manager with no devices, fed by hand.
@MainActor
final class PreReleasePipelineTests: XCTestCase {
    private var savedTranslationEnabled = true
    private var savedTranslationBackend: TranslationBackend = .openAICompatible

    override func setUp() async throws {
        try await super.setUp()
        savedTranslationEnabled = AppState.shared.translationEnabled
        savedTranslationBackend = AppState.shared.translationBackend
        // The sentence translator, not T3PO, whatever an earlier test left.
        AppState.shared.translationBackend = .openAICompatible
        AppState.shared.translationEnabled = false
    }

    override func tearDown() async throws {
        AppState.shared.translationEnabled = savedTranslationEnabled
        AppState.shared.translationBackend = savedTranslationBackend
        try await super.tearDown()
    }

    // MARK: - P4: one resampler for the whole system-audio stream

    private static let sckFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                 channels: 2, interleaved: false)!
    private static let busFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                 channels: 1, interleaved: true)!

    /// `count` frames of a 440 Hz sine continuing from frame `from`, in the
    /// float stereo layout ScreenCaptureKit delivers.
    private static func sine(_ format: AVAudioFormat, from: Int, count: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<count {
                samples[i] = Float(0.5 * sin(2 * .pi * 440 * Double(from + i) / format.sampleRate))
            }
        }
        return buffer
    }

    nonisolated private static func int16(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    /// A fresh converter per ~20 ms buffer gave 15,700 frames a second instead
    /// of 16,000, with a gap at every buffer.
    func testReusedResamplerKeepsASecondOfSystemAudioWholeAndOnTime() {
        let resampler = StreamingResampler(target: Self.busFormat)
        var out: [Int16] = []
        for index in 0..<50 {
            let buffer = Self.sine(Self.sckFormat, from: index * 960, count: 960)
            if let data = resampler.convert(buffer) { out += Self.int16(data) }
        }
        XCTAssertEqual(resampler.converterCount, 1)
        // Only the filter's look-ahead is still held back.
        XCTAssertLessThanOrEqual(out.count, 16_000)
        XCTAssertGreaterThanOrEqual(out.count, 16_000 - 32)
        // No seams: 440 Hz at 16 kHz moves at most 2π·440/16000 ≈ 0.17 of
        // the amplitude per sample, and a dropped sample shows as a jump.
        let amplitude = 0.5 * 32_767.0
        let steps = zip(out.dropFirst(64), out.dropFirst(65)).map { abs(Double($1) - Double($0)) }
        XCTAssertLessThan(steps.max() ?? 0, 0.2 * amplitude)
    }

    func testResamplerIsRebuiltOnlyWhenTheInputFormatChanges() {
        let resampler = StreamingResampler(target: Self.busFormat)
        let other = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                  channels: 2, interleaved: false)!
        var frames = 0
        for index in 0..<25 {
            let buffer = Self.sine(Self.sckFormat, from: index * 960, count: 960)
            frames += resampler.convert(buffer).map { $0.count / 2 } ?? 0
        }
        for index in 0..<25 {
            let buffer = Self.sine(other, from: index * 882, count: 882)
            frames += resampler.convert(buffer).map { $0.count / 2 } ?? 0
        }
        XCTAssertEqual(resampler.converterCount, 2)
        XCTAssertGreaterThanOrEqual(frames, 16_000 - 64)
        XCTAssertLessThanOrEqual(frames, 16_000)
    }

    // MARK: - P1: the mic watchdog, and the bus across a restart gap

    func testWatchdogStaysQuietWhileTheMicrophoneDelivers() {
        var watchdog = MicrophoneWatchdog()
        for second in 1...30 {
            let now = TimeInterval(second)
            XCTAssertEqual(watchdog.check(now: now, lastSample: now - 0.1), .none)
        }
    }

    func testWatchdogReportsSilenceOnceRetriesAndSeesTheMicrophoneComeBack() {
        var watchdog = MicrophoneWatchdog()
        XCTAssertEqual(watchdog.check(now: 4.9, lastSample: 0), .none)
        XCTAssertEqual(watchdog.check(now: 5.0, lastSample: 0), .reportSilence)
        for now in [6.0, 7.0, 8.0, 9.0] {
            XCTAssertEqual(watchdog.check(now: now, lastSample: 0), .none, "reported once, not every second")
        }
        XCTAssertEqual(watchdog.check(now: 10.0, lastSample: 0), .retry)
        XCTAssertEqual(watchdog.check(now: 11.0, lastSample: 0), .none)
        XCTAssertEqual(watchdog.check(now: 15.0, lastSample: 0), .retry)
        XCTAssertEqual(watchdog.check(now: 16.0, lastSample: 15.5), .reportRecovered)
        XCTAssertEqual(watchdog.check(now: 17.0, lastSample: 16.9), .none)
    }

    /// A restart that throws is reported at once. The last sample before it is
    /// recent, but it is no sign the microphone is back.
    func testFailedRestartIsReportedAtOnceAndOnlyANewSampleClearsIt() {
        var watchdog = MicrophoneWatchdog()
        XCTAssertTrue(watchdog.restartFailed(at: 10))
        XCTAssertEqual(watchdog.check(now: 11, lastSample: 9.7), .none)
        XCTAssertFalse(watchdog.restartFailed(at: 12), "already reported")
        XCTAssertEqual(watchdog.check(now: 17, lastSample: 9.7), .retry)
        XCTAssertEqual(watchdog.check(now: 18, lastSample: 17.5), .reportRecovered)
    }

    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(pts: Int64, samples: [Int16])] = []
        var all: [(pts: Int64, samples: [Int16])] { lock.withLock { storage } }
        func append(_ data: Data, _ pts: Int64) {
            lock.withLock { storage.append((pts, PreReleasePipelineTests.int16(data))) }
        }
    }

    private static func pcm(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Mic only: while the engine restarts nothing is padded in and the clock
    /// stands still, and the samples on either side of the gap stay adjacent.
    func testMicOnlyRestartGapNeitherPadsNorAdvancesTheClock() {
        let frames = Frames()
        let bus = AudioMixBus(sampleRate: 16_000, frameMs: 100) { data, pts, _ in frames.append(data, pts) }
        bus.activate(.microphone)
        bus.submit(Self.pcm(Array(repeating: 1, count: 1_600 + 700)), from: .microphone)
        XCTAssertTrue(bus.tick())
        // The engine stopped mid-chunk.
        XCTAssertFalse(bus.tick())
        XCTAssertFalse(bus.tick())
        XCTAssertEqual(bus.emittedMs, 100)

        bus.submit(Self.pcm(Array(repeating: 2, count: 900)), from: .microphone)
        XCTAssertTrue(bus.tick())
        XCTAssertEqual(bus.emittedMs, 200)
        let second = frames.all[1]
        XCTAssertEqual(second.pts, 1_600)
        XCTAssertEqual(second.samples, Array(repeating: 1, count: 700) + Array(repeating: 2, count: 900))
    }

    /// Mixed: the classroom drops out for a moment, the meeting audio carries
    /// the timeline on, and the mic comes back in at the current position.
    func testMixedRestartGapKeepsSystemAudioOnTimeAndTheMicRejoins() {
        let frames = Frames()
        let bus = AudioMixBus(sampleRate: 16_000, frameMs: 100) { data, pts, _ in frames.append(data, pts) }
        bus.activate(.microphone)
        bus.activate(.system)
        bus.submit(Self.pcm(Array(repeating: 100, count: 1_600)), from: .microphone)
        bus.submit(Self.pcm(Array(repeating: 10, count: 1_600)), from: .system)
        XCTAssertTrue(bus.tick())
        for _ in 0..<2 {
            bus.submit(Self.pcm(Array(repeating: 10, count: 1_600)), from: .system)
            XCTAssertTrue(bus.tick())
        }
        bus.submit(Self.pcm(Array(repeating: 100, count: 1_600)), from: .microphone)
        bus.submit(Self.pcm(Array(repeating: 10, count: 1_600)), from: .system)
        XCTAssertTrue(bus.tick())

        let all = frames.all
        XCTAssertEqual(all.map(\.pts), [0, 1_600, 3_200, 4_800])
        XCTAssertEqual(all[1].samples, Array(repeating: 10, count: 1_600))
        XCTAssertEqual(all[3].samples, Array(repeating: 110, count: 1_600))
    }

    // MARK: - P3: reconnect limits count failures in a row

    func testFailuresSpreadOverALectureNeverEndLiveTranscription() {
        var policy = STTReconnectPolicy()
        for _ in 0..<12 {
            XCTAssertEqual(policy.attemptFailed(heardEngine: true, ranFor: .seconds(2)),
                           .retry(after: .seconds(1), replaceSidecar: false))
        }
    }

    func testFailuresInARowBackOffReplaceTheSidecarAndThenGiveUp() {
        var policy = STTReconnectPolicy()
        let decisions = (0..<6).map { _ in policy.attemptFailed(heardEngine: false, ranFor: .seconds(1)) }
        XCTAssertEqual(decisions, [
            .retry(after: .seconds(1), replaceSidecar: false),
            .retry(after: .seconds(2), replaceSidecar: true),
            .retry(after: .seconds(4), replaceSidecar: true),
            .retry(after: .seconds(8), replaceSidecar: true),
            .retry(after: .seconds(8), replaceSidecar: true),
            .giveUp,
        ])
    }

    /// A silent room produces no events, but a connection that lasted this long
    /// was working.
    func testALongQuietRunAlsoResetsTheCount() {
        var policy = STTReconnectPolicy()
        for _ in 0..<3 { _ = policy.attemptFailed(heardEngine: false, ranFor: .seconds(1)) }
        XCTAssertEqual(policy.attemptFailed(heardEngine: false, ranFor: STTReconnectPolicy.healthyRun),
                       .retry(after: .seconds(1), replaceSidecar: false))
    }

    // MARK: - P2: timestamps after a reconnect

    func testOnlyTheCloudEngineStampsEventsFromChunks() {
        // Through the protocol, as the orchestrator sees them.
        let engines: [STTProvider] = [OpenAICompatibleSTT(config: .default),
                                      LocalWebSocketSTT(engine: .funasr),
                                      LocalWebSocketSTT(engine: .r2t2),
                                      AppleSpeechSTT()]
        XCTAssertEqual(engines.map { $0 is ChunkTimestampedSTT }, [true, false, false, false])
    }

    /// A sidecar's clock restarts at 0 on every connection. Its events after a
    /// reconnect at 30 s used to be shifted by wall time and come out early,
    /// and what was said during the backoff never reached the new connection.
    func testSidecarEventsAfterAReconnectLandWhereTheyWereSaid() async throws {
        let stt = SidecarClockSTT(failAfterChunks: 300)
        try await runReconnect(with: stt)
    }

    /// The cloud engine already stamps events with the bus's chunk times. Adding
    /// the wall-clock offset to them doubled every time after a reconnect.
    func testChunkStampedEventsAfterAReconnectAreNotShiftedAgain() async throws {
        let stt = ChunkClockSTT(failAfterChunks: 300)
        try await runReconnect(with: stt)
    }

    private func runReconnect(with stt: ScriptedSTT,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let orchestrator = SessionOrchestrator()
        let capture = AudioSourceManager(capturesDevices: false)
        orchestrator.captureOverride = capture
        orchestrator.sttProviderOverride = stt
        _ = try await orchestrator.startEphemeralTranslation(source: .microphone)

        capture.feedForTesting(Self.tone(seconds: 30))
        // Set right where the next subscription is made, before the backoff.
        try await waitUntil { orchestrator.statusText == L10n.t("live.engineReconnecting") }
        XCTAssertEqual(orchestrator.transcript.segments.count, 1, file: file, line: line)

        // Spoken during the 1 s backoff.
        capture.feedForTesting(Self.tone(seconds: 2))
        try await waitUntil(seconds: 6) { orchestrator.transcript.segments.count == 2 }

        XCTAssertEqual(stt.firstChunkMs(attempt: 0), 0, file: file, line: line)
        XCTAssertEqual(stt.firstChunkMs(attempt: 1), 30_000, "the backoff's audio was lost",
                       file: file, line: line)
        let segments = orchestrator.transcript.segments
        XCTAssertEqual(segments.map(\.startMs), [29_000, 30_000], file: file, line: line)
        XCTAssertEqual(segments.map(\.endMs), [30_000, 31_000], file: file, line: line)
        await orchestrator.stop()
    }

    // MARK: - P5: bookmarks and duration on the bus clock

    /// `AppState.markHighlight` stamps a bookmark with `currentTimestampMs`. It
    /// was wall time, which runs on while the bus skips a stretch with no
    /// audio (system audio, lecture video paused), so the stored duration also
    /// overran the file.
    func testBookmarkTimeAndDurationFollowTheRecordingNotTheWallClock() async throws {
        try ClassNote.Database.shared.setup()
        let orchestrator = SessionOrchestrator()
        let capture = AudioSourceManager(capturesDevices: false)
        orchestrator.captureOverride = capture
        orchestrator.sttProviderOverride = ManualSTT()
        let sessionId = try await orchestrator.startNewSession(courseId: nil, title: "Clock", source: .microphone)
        addTeardownBlock {
            try? await SessionRepository.shared.delete(id: sessionId, force: true)
        }

        // Ten seconds of lecture in a fraction of a second of wall time.
        capture.feedForTesting(Self.tone(seconds: 10))
        try await waitUntil { orchestrator.currentTimestampMs == 10_000 }

        // The video is paused: no audio, so the recording does not grow.
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(orchestrator.currentTimestampMs, 10_000)

        capture.feedForTesting(Self.tone(seconds: 2))
        try await waitUntil { orchestrator.currentTimestampMs == 12_000 }

        await orchestrator.stop()
        let session = try await SessionRepository.shared.get(id: sessionId)
        XCTAssertEqual(session?.durationMs, 12_000)
    }

    // MARK: - P6: no stale half-sentence after toggling translation

    func testAHalfSentenceQueuedBeforeTranslationWasTurnedOffIsDropped() async throws {
        let (orchestrator, stt, translator) = try await startTranslatingSession()

        stt.emit("So the derivative of", continues: true)
        try await waitUntil { orchestrator.transcript.segments.count == 1 }

        AppState.shared.translationEnabled = false
        stt.emit("Okay, let's take a ten minute break.", continues: false)
        try await waitUntil { orchestrator.transcript.segments.count == 2 }

        AppState.shared.translationEnabled = true
        stt.emit("Welcome back.", continues: false)
        try await waitUntil { orchestrator.transcript.segments.count == 3 }
        try await waitUntil { !translator.texts.isEmpty }
        XCTAssertEqual(translator.texts, ["Welcome back."])

        await orchestrator.stop()
        XCTAssertEqual(translator.texts, ["Welcome back."])
    }

    func testStopWithTranslationOffDoesNotTranslateTheLeftover() async throws {
        let (orchestrator, stt, translator) = try await startTranslatingSession()

        stt.emit("So the derivative of", continues: true)
        try await waitUntil { orchestrator.transcript.segments.count == 1 }
        AppState.shared.translationEnabled = false

        await orchestrator.stop()
        XCTAssertEqual(translator.texts, [])
    }

    private func startTranslatingSession() async throws -> (SessionOrchestrator, ManualSTT, RecordingTranslator) {
        AppState.shared.translationEnabled = true
        let orchestrator = SessionOrchestrator()
        let stt = ManualSTT()
        let translator = RecordingTranslator()
        orchestrator.captureOverride = AudioSourceManager(capturesDevices: false)
        orchestrator.sttProviderOverride = stt
        orchestrator.translatorOverride = translator
        _ = try await orchestrator.startEphemeralTranslation(source: .microphone)
        try await waitUntil { stt.isConnected }
        return (orchestrator, stt, translator)
    }

    // MARK: - Helpers

    /// Bus-format PCM: a quiet tone, so the recording file has something in it.
    private static func tone(seconds: Int) -> Data {
        let samples = (0..<(16_000 * seconds)).map { i in
            Int16(3_000 * sin(2 * .pi * 220 * Double(i) / 16_000))
        }
        return pcm(samples)
    }

    private func waitUntil(seconds: Double = 2,
                           _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "condition never became true", file: file, line: line)
    }
}

// MARK: - Fakes

/// A live engine that reads the audio it is sent and emits on its own clock:
/// from 0 per connection like a local sidecar, or from the chunk timestamps
/// like the cloud engine (the `ChunkTimestampedSTT` subclass). The first
/// connection emits the last second it heard and drops after
/// `failAfterChunks`; later ones emit their first second and then run until
/// capture stops.
private class ScriptedSTT: STTProvider, @unchecked Sendable {
    private let failAfterChunks: Int
    private let lock = NSLock()
    private var firstChunks: [Int64?] = []

    init(failAfterChunks: Int) {
        self.failAfterChunks = failAfterChunks
    }

    func firstChunkMs(attempt: Int) -> Int64? {
        lock.withLock { attempt < firstChunks.count ? firstChunks[attempt] : nil }
    }

    func transcribe(audio: AsyncStream<AudioChunk>,
                    language: String?) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let attempt = lock.withLock {
            firstChunks.append(nil)
            return firstChunks.count - 1
        }
        let stampsChunks = self is ChunkTimestampedSTT
        let failAfter = failAfterChunks
        return AsyncThrowingStream { continuation in
            let task = Task {
                var count = 0
                var heardMs: Int64 = 0
                for await chunk in audio {
                    if count == 0 { self.lock.withLock { self.firstChunks[attempt] = chunk.timestamp } }
                    count += 1
                    let duration = Int64(chunk.pcmData.count / 2) * 1_000 / Int64(chunk.sampleRate)
                    let chunkEnd = (stampsChunks ? chunk.timestamp : heardMs) + duration
                    heardMs += duration
                    if attempt == 0, count == failAfter {
                        continuation.yield(TranscriptEvent(startMs: chunkEnd - 1_000, endMs: chunkEnd,
                                                           text: "Before the drop.", isFinal: true))
                        continuation.finish(throwing: URLError(.networkConnectionLost))
                        return
                    }
                    if attempt > 0, count == 10 {
                        continuation.yield(TranscriptEvent(startMs: chunkEnd - 1_000, endMs: chunkEnd,
                                                           text: "After the reconnect.", isFinal: true))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func transcribeFile(url: URL,
                        language: String?) -> AsyncThrowingStream<FileTranscriptionEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class SidecarClockSTT: ScriptedSTT, @unchecked Sendable {}

private final class ChunkClockSTT: ScriptedSTT, ChunkTimestampedSTT, @unchecked Sendable {}

/// A live engine the test speaks through. It drains the audio it is sent and
/// ends when capture does, like a real one.
private final class ManualSTT: STTProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?

    var isConnected: Bool { lock.withLock { continuation != nil } }

    func emit(_ text: String, continues: Bool) {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(TranscriptEvent(startMs: 0, endMs: 1_000, text: text, isFinal: true,
                                            continuesSentence: continues))
    }

    func transcribe(audio: AsyncStream<AudioChunk>,
                    language: String?) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            self.lock.withLock { self.continuation = continuation }
            let drain = Task {
                for await _ in audio {}
                continuation.finish()
            }
            continuation.onTermination = { _ in drain.cancel() }
        }
    }

    func transcribeFile(url: URL,
                        language: String?) -> AsyncThrowingStream<FileTranscriptionEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Records every sentence it is asked to translate.
private final class RecordingTranslator: TranslationProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var texts: [String] { lock.withLock { storage } }

    func translate(text: String,
                   sourceLanguage: String,
                   targetLanguage: String,
                   context: [String],
                   glossary: TranslationGlossary) -> AsyncThrowingStream<String, Error> {
        lock.withLock { storage.append(text) }
        return AsyncThrowingStream { continuation in
            continuation.yield("译文")
            continuation.finish()
        }
    }
}
