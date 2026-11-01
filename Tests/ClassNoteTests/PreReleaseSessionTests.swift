import Foundation
import XCTest
@testable import ClassNote

// Regressions found in the pre-release review of the session detail: a job
// that outlived its view model, empty replies that wiped saved content, a
// seek dropped while the recording downloaded, playback during a recording,
// and a port number that crashed Settings.

// MARK: - U1: a port above 65535

final class LocalNetworkProbePortTests: XCTestCase {
    /// `URL` accepts the port, and `UInt16(_:)` used to trap on it as soon as
    /// Settings probed the typed base URL.
    func testAPortThatDoesNotFitIsNotProbed() async {
        let typed = "http://localhost:114345/v1"
        XCTAssertEqual(URL(string: typed)?.port, 114_345)

        let started = Date()
        let result = await LocalNetworkAccess.probe(baseUrlString: typed, timeout: 3)
        XCTAssertEqual(result, .unreachable)
        // Answered at once, not by the timeout: nothing was dialled.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

        let lan = await LocalNetworkAccess.probe(baseUrlString: "http://192.168.1.10:70000", timeout: 3)
        XCTAssertEqual(lan, .unreachable)
    }
}

// MARK: - Shared fixtures

@MainActor
class SessionDetailTestCase: XCTestCase {
    private var savedBackend: LLMBackend = .openAICompatible

    override func setUp() async throws {
        try await super.setUp()
        try Database.shared.setup()
        savedBackend = AppState.shared.llmBackend
        // The local backend shortens transcripts and splits notes into parts.
        AppState.shared.llmBackend = .openAICompatible
        AppState.shared.lastError = nil
    }

    override func tearDown() async throws {
        AppState.shared.llmBackend = savedBackend
        AppState.shared.lastError = nil
        try await super.tearDown()
    }

    /// A finished lecture with a short transcript, recorded to `audioPath`.
    func makeSession(audioPath: String? = nil, recording: Bool = false) async throws -> Session {
        let session = Session.new(courseId: nil, title: "Pre-release \(UUID().uuidString.prefix(8))")
        try await SessionRepository.shared.insert(session)
        addTeardownBlock { try? await SessionRepository.shared.delete(id: session.id, force: true) }
        if recording {
            if let audioPath { try await SessionRepository.shared.setAudioPath(session.id, audioPath: audioPath) }
        } else {
            try await SessionRepository.shared.setEnded(session.id, endedAt: session.startedAt + 3_000,
                                                        durationMs: 3_000, audioPath: audioPath)
        }
        try await SegmentRepository.shared.insertMany([
            segment(session.id, 0, "A compressor reduces the dynamic range."),
            segment(session.id, 1_500, "The ratio sets how much."),
        ])
        return try await SessionRepository.shared.get(id: session.id) ?? session
    }

    private func segment(_ sessionId: String, _ startMs: Int64, _ text: String) -> Segment {
        Segment(id: nil, sessionId: sessionId, startMs: startMs, endMs: startMs + 1_500, speakerId: nil,
                textOriginal: text, textTranslated: "", isFinal: true, confidence: 1, version: 1)
    }

    func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        var waited = 0
        while !condition(), waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertTrue(condition(), "condition never became true", file: file, line: line)
    }
}

// MARK: - U3: a reply with nothing usable keeps what was there

final class EmptyReplyKeepsContentTests: SessionDetailTestCase {
    private func seedFlashcards(_ sessionId: String) async throws {
        try await FlashcardRepository.shared.replace(sessionId: sessionId, cards: [
            Flashcard(id: nil, sessionId: sessionId, front: "Ratio", back: "压缩比", sourceModel: "m",
                      createdAt: 1, sortOrder: 0),
            Flashcard(id: nil, sessionId: sessionId, front: "Knee", back: "拐点", sourceModel: "m",
                      createdAt: 1, sortOrder: 1),
        ])
    }

    /// A Markdown table, the Q:/A: pairs a local Qwen3 writes, or nothing at
    /// all used to delete the whole deck without a word.
    func testAReplyWithoutCardsKeepsTheDeck() async throws {
        let session = try await makeSession()
        try await seedFlashcards(session.id)
        for reply in ["| Front | Back |\n|---|---|\n| Ratio | 压缩比 |", "Q: What is a knee?\nA: 拐点", ""] {
            AppState.shared.lastError = nil
            let vm = SessionDetailViewModel()
            vm.llmOverride = ScriptedLLM(reply)
            await vm.load(sessionId: session.id)
            await vm.generateFlashcards()

            let stored = try await FlashcardRepository.shared.all(sessionId: session.id)
            XCTAssertEqual(stored.map(\.front), ["Ratio", "Knee"], "reply: \(reply)")
            XCTAssertEqual(vm.flashcards.map(\.front), ["Ratio", "Knee"])
            XCTAssertEqual(AppState.shared.lastError, L10n.t("flashcards.error.noCards"))
        }
    }

    func testAReplyWithCardsStillReplacesTheDeck() async throws {
        let session = try await makeSession()
        try await seedFlashcards(session.id)
        let vm = SessionDetailViewModel()
        vm.llmOverride = ScriptedLLM("Attack || 启动时间\nnot a card\nRelease || 释放时间")
        await vm.load(sessionId: session.id)
        await vm.generateFlashcards()

        XCTAssertEqual(vm.flashcards.map(\.front), ["Attack", "Release"])
        XCTAssertNil(AppState.shared.lastError)
    }

    func testParsingSkipsLinesThatAreNotCards() {
        let cards = SessionDetailViewModel.parseFlashcards("""
            Here are your cards:
            Attack || 启动时间
             || no front
            Ratio ||
            Knee || 拐点 || soft or hard
            """, sessionId: "s", model: "m", createdAt: 5)
        XCTAssertEqual(cards.map(\.front), ["Attack", "Knee"])
        XCTAssertEqual(cards.map(\.back), ["启动时间", "拐点 || soft or hard"])
        XCTAssertEqual(cards.map(\.sortOrder), [0, 1])
    }

    func testAnEmptyNoteKeepsTheCurrentNote() async throws {
        let session = try await makeSession()
        try await NoteRepository.shared.upsert(Note(id: UUID().uuidString, sessionId: session.id,
                                                    markdown: "# Old note", version: 1, generatedAt: 1,
                                                    model: "m"))
        let vm = SessionDetailViewModel()
        vm.llmOverride = ScriptedLLM(" \n\n ")
        await vm.load(sessionId: session.id)
        await vm.generateNotes()

        let stored = try await NoteRepository.shared.get(sessionId: session.id)
        XCTAssertEqual(stored?.markdown, "# Old note")
        XCTAssertEqual(stored?.version, 1)
        XCTAssertEqual(vm.note?.markdown, "# Old note")
        XCTAssertEqual(AppState.shared.lastError, L10n.t("notes.error.empty"))
    }

    func testAnEmptyStudyToolResultKeepsTheLastOne() async throws {
        let session = try await makeSession()
        let tool = try XCTUnwrap(StudyTools.all.first)
        try await StudyToolResultRepository.shared.upsert(StudyToolResult(id: UUID().uuidString,
                                                                          sessionId: session.id,
                                                                          toolId: tool.id,
                                                                          markdown: "# Old result",
                                                                          model: "m",
                                                                          generatedAt: 1))
        let vm = SessionDetailViewModel()
        vm.llmOverride = ScriptedLLM("")
        await vm.load(sessionId: session.id)
        vm.selectedStudyToolId = tool.id
        await vm.generateSelectedStudyTool()

        let stored = try await StudyToolResultRepository.shared.get(sessionId: session.id, toolId: tool.id)
        XCTAssertEqual(stored?.markdown, "# Old result")
        XCTAssertEqual(vm.selectedStudyToolMarkdown, "# Old result")
        XCTAssertEqual(AppState.shared.lastError, L10n.t("studyTools.error.empty"))
    }
}

// MARK: - U2: a job outlives the view model that started it

final class SessionJobsTests: SessionDetailTestCase {
    func testOneStatePerSession() {
        let a = SessionJobs.shared.state(for: "jobs-a")
        XCTAssertTrue(a === SessionJobs.shared.state(for: "jobs-a"))
        XCTAssertFalse(a === SessionJobs.shared.state(for: "jobs-b"))
        XCTAssertEqual(a.sessionId, "jobs-a")
    }

    func testFinishingAJobTellsTheViewsOfThatSession() async {
        let owner = SessionDetailViewModel()
        let ownerId = ObjectIdentifier(owner)
        let posted = expectation(forNotification: .sessionContentDidChange, object: nil) { note in
            note.userInfo?["sessionId"] as? String == "jobs-c"
                && note.object.map { ObjectIdentifier($0 as AnyObject) } == ownerId
        }
        SessionJobs.shared.jobDidFinish(sessionId: "jobs-c", by: owner)
        await fulfillment(of: [posted], timeout: 1)
    }

    /// Lecture A's view model is dropped when the user switches to B, but its
    /// job runs on. Back on A, a new view model must show the job running,
    /// refuse a second one, and load the result once it is saved.
    func testComingBackShowsTheJobAndRefusesASecondOne() async throws {
        let session = try await makeSession()
        let llm = GatedLLM(head: "Attack || 启动时间\n", tail: "Release || 释放时间")
        let first = SessionDetailViewModel()
        first.llmOverride = llm
        await first.load(sessionId: session.id)
        let job = Task { await first.generateFlashcards() }
        try await waitUntil { first.isGeneratingFlashcards }

        // The new view model of the same lecture, as after switching back.
        let second = SessionDetailViewModel()
        second.llmOverride = llm
        await second.load(sessionId: session.id)
        XCTAssertTrue(second.isGeneratingFlashcards)
        try await waitUntil { second.streamingFlashcardsRaw == "Attack || 启动时间\n" }

        await second.generateFlashcards()
        XCTAssertEqual(llm.requestCount, 1, "a second generation started")

        let finished = expectation(forNotification: .sessionContentDidChange, object: nil) { note in
            note.userInfo?["sessionId"] as? String == session.id
        }
        llm.release()
        await job.value
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(second.isGeneratingFlashcards)

        // What SessionDetailView does on the notification.
        await second.load(sessionId: session.id)
        XCTAssertEqual(second.flashcards.map(\.front), ["Attack", "Release"])
    }

    /// Two note runs used to both write version N+1.
    func testNotesAreWrittenOnceWhenAskedFromTwoViewModels() async throws {
        let session = try await makeSession()
        let llm = GatedLLM(head: "# Compression\n", tail: "Ratio and knee.")
        let first = SessionDetailViewModel()
        first.llmOverride = llm
        await first.load(sessionId: session.id)
        let job = Task { await first.generateNotes() }
        try await waitUntil { first.isGeneratingNotes }

        let second = SessionDetailViewModel()
        second.llmOverride = llm
        await second.load(sessionId: session.id)
        XCTAssertTrue(second.isShowingNoteStream)
        try await waitUntil { second.streamingNoteMarkdown == "# Compression\n" }
        await second.generateNotes()
        XCTAssertEqual(llm.requestCount, 1)

        llm.release()
        await job.value
        let versions = try await NoteRepository.shared.versions(sessionId: session.id)
        XCTAssertEqual(versions.map(\.version), [1])
        await second.load(sessionId: session.id)
        XCTAssertFalse(second.isShowingNoteStream)
        XCTAssertEqual(second.note?.markdown, "# Compression\nRatio and knee.")
    }
}

// MARK: - U6 and U4: playback

final class PendingPlaybackTests: XCTestCase {
    func testAScrubMovesWithoutPlaying() {
        var request = PendingPlayback()
        request.scrub(to: 2_000)
        request.scrub(to: 12_000)
        XCTAssertEqual(request, PendingPlayback(positionMs: 12_000, play: false))
    }

    func testPlayAskedForStaysAskedForAcrossAScrub() {
        var request = PendingPlayback()
        request.togglePlay()
        request.scrub(to: 10_000)
        XCTAssertEqual(request, PendingPlayback(positionMs: 10_000, play: true))
    }

    func testALineClickedPlaysFromIt() {
        var request = PendingPlayback()
        request.seek(to: 4_500)
        XCTAssertEqual(request, PendingPlayback(positionMs: 4_500, play: true))
    }
}

final class CloudPlaybackTests: SessionDetailTestCase {
    private func silentRecording() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prerelease-\(UUID().uuidString).wav")
        try Self.silentWav(seconds: 3).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func viewModel(playing url: URL, cloud: FakeCloud? = nil,
                           recording: Bool = false) async throws -> SessionDetailViewModel {
        let session = try await makeSession(audioPath: url.path, recording: recording)
        let vm = SessionDetailViewModel()
        if let cloud { vm.cloudFiles = cloud.access }
        await vm.load(sessionId: session.id)
        XCTAssertTrue(vm.hasAudio)
        return vm
    }

    /// ±10 s or the scrubber on a recording still in iCloud used to start
    /// playback from 0:00 once it had downloaded.
    func testAScrubWhileDownloadingLeavesPlaybackPausedThere() async throws {
        let cloud = FakeCloud()
        let vm = try await viewModel(playing: try silentRecording(), cloud: cloud)
        defer { vm.stopPlayback() }

        vm.scrub(to: 2_000)
        XCTAssertTrue(vm.isDownloadingAudio)
        XCTAssertEqual(vm.playheadMs, 2_000)

        cloud.finishDownload()
        try await waitUntil { !vm.isDownloadingAudio }
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(Double(vm.playheadMs), 2_000, accuracy: 1)
    }

    func testAClickedLineWhileDownloadingPlaysFromThatLine() async throws {
        let cloud = FakeCloud()
        let vm = try await viewModel(playing: try silentRecording(), cloud: cloud)
        defer { vm.stopPlayback() }

        vm.seek(to: 1_500)
        XCTAssertFalse(vm.isPlaying)
        cloud.finishDownload()
        try await waitUntil { !vm.isDownloadingAudio }
        XCTAssertTrue(vm.isPlaying)
        XCTAssertEqual(Double(vm.playheadMs), 1_500, accuracy: 1)
    }

    /// The fragmented .m4a exists from the first second of a recording, but
    /// nothing could pause playback started from it then.
    func testNothingPlaysWhileTheLectureRecords() async throws {
        let vm = try await viewModel(playing: try silentRecording(), recording: true)
        defer { vm.stopPlayback() }
        XCTAssertTrue(vm.isSessionRecording)

        vm.seek(to: 1_000)
        vm.togglePlayPause()
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.playheadMs, 0)
    }

    /// 16 kHz mono 16-bit PCM of silence.
    nonisolated static func silentWav(seconds: Int) -> Data {
        let rate: UInt32 = 16_000
        let bytes = UInt32(seconds) * rate * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))         // PCM
        append(UInt16(1))         // mono
        append(rate)
        append(rate * 2)          // byte rate
        append(UInt16(2))         // block align
        append(UInt16(16))        // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(bytes)
        data.append(Data(count: Int(bytes)))
        return data
    }
}

// MARK: - U7: exporting the recording

final class AudioExportTests: XCTestCase {
    func testExportsCopyTheRecording() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recording = dir.appendingPathComponent("lecture.wav")
        try CloudPlaybackTests.silentWav(seconds: 1).write(to: recording)

        var session = Session.new(courseId: nil, title: "Lecture")
        session.audioPath = recording.path
        let input = SessionExporter.Input(session: session, segments: [], note: nil, highlights: [],
                                          flashcards: [], studyToolResults: [])

        let copy = dir.appendingPathComponent("copy.wav")
        try await SessionExporter.exportAudio(input, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: recording))

        let folder = try await SessionExporter.exportBundle(input, to: dir.appendingPathComponent("Bundle"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.wav").path))
    }
}

// MARK: - Test doubles

/// Answers every request with the same text, in one piece.
private final class ScriptedLLM: LLMProvider, @unchecked Sendable {
    private let reply: String

    init(_ reply: String) { self.reply = reply }

    func chat(messages: [ChatMessage], model: String, temperature: Double) -> AsyncThrowingStream<String, Error> {
        let reply = self.reply
        return AsyncThrowingStream { continuation in
            if !reply.isEmpty { continuation.yield(reply) }
            continuation.finish()
        }
    }

    func chatComplete(messages: [ChatMessage], model: String, temperature: Double) async throws -> String {
        reply
    }
}

/// Streams `head` at once and `tail` only when released, so a test can act
/// while a job is still running.
private final class GatedLLM: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let head: String
    private let tail: String
    private var requests = 0
    private var open: [AsyncThrowingStream<String, Error>.Continuation] = []

    init(head: String, tail: String) {
        self.head = head
        self.tail = tail
    }

    var requestCount: Int { lock.withLock { requests } }

    func chat(messages: [ChatMessage], model: String, temperature: Double) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            self.lock.withLock {
                self.requests += 1
                self.open.append(continuation)
            }
            continuation.yield(self.head)
        }
    }

    func chatComplete(messages: [ChatMessage], model: String, temperature: Double) async throws -> String {
        head + tail
    }

    func release() {
        let streams = lock.withLock { () -> [AsyncThrowingStream<String, Error>.Continuation] in
            defer { open = [] }
            return open
        }
        for stream in streams {
            stream.yield(tail)
            stream.finish()
        }
    }
}

/// A recording that is only in iCloud until the test lets it arrive.
private final class FakeCloud: @unchecked Sendable {
    private let lock = NSLock()
    private var inCloud = true

    var access: CloudFileAccess {
        CloudFileAccess(needsDownload: { [self] _ in lock.withLock { inCloud } },
                        download: { [self] _ in
                            while lock.withLock({ inCloud }) {
                                try await Task.sleep(nanoseconds: 10_000_000)
                            }
                        })
    }

    func finishDownload() {
        lock.withLock { inCloud = false }
    }
}
