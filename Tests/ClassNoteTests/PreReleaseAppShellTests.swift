import Darwin
import Foundation
import XCTest
@testable import ClassNote

/// Regressions in the app shell: the recovery scan, the re-transcription
/// registry, the sidebar filter and the process-wide SIGPIPE guard.
@MainActor
final class PreReleaseAppShellTests: XCTestCase {

    // MARK: - The recovery scan never touches a session being written

    /// A live recording looks exactly like a crashed one in the database:
    /// `recording`, no end time. Marking it listed it for recovery and lifted
    /// the delete guard while its .m4a was being written.
    func testScanMarksOnlySessionsNobodyIsWriting() async throws {
        try ClassNote.Database.shared.setup()
        let live = try await insertSession("Live lecture")
        let crashed = try await insertSession("Crashed lecture", startedAt: 1_000)

        let found = await RecoveryCoordinator.scanInterruptedSessions { $0.id == live.id }

        XCTAssertFalse(found.contains { $0.id == live.id })
        XCTAssertTrue(found.contains { $0.id == crashed.id })
        let liveRow = try await SessionRepository.shared.get(id: live.id)
        XCTAssertEqual(liveRow?.state, SessionState.recording.rawValue)
        let crashedRow = try await SessionRepository.shared.get(id: crashed.id)
        XCTAssertEqual(crashedRow?.state, SessionState.interrupted.rawValue)
    }

    /// The same through AppState, with the live orchestrator holding the
    /// session the way a recording does.
    func testLiveOrchestratorsSessionStaysRecordingAndUndeletable() async throws {
        try ClassNote.Database.shared.setup()
        let appState = AppState.shared
        let wasTranslating = appState.translationEnabled
        appState.translationEnabled = false
        let url = try makeAudioFile()
        let live = try await insertSession("Live lecture", audioPath: url.path)
        let crashed = try await insertSession("Crashed lecture", startedAt: 1_000)

        let orchestrator = appState.orchestrator
        let previousSource = orchestrator.source
        orchestrator.sttProviderOverride = ParkedEngine()
        defer {
            orchestrator.sttProviderOverride = nil
            orchestrator.source = previousSource
            appState.translationEnabled = wasTranslating
        }
        // No capture device here: a re-transcription is what makes the live
        // orchestrator own a session id without one.
        _ = try await orchestrator.retranscribeSession(live)
        XCTAssertEqual(orchestrator.currentSessionId, live.id)
        try await SessionRepository.shared.setState(live.id, state: SessionState.recording.rawValue)

        await appState.refreshInterruptedSessions()

        XCTAssertFalse(appState.interruptedSessions.contains { $0.id == live.id })
        XCTAssertTrue(appState.interruptedSessions.contains { $0.id == crashed.id })
        let liveRow = try await SessionRepository.shared.get(id: live.id)
        XCTAssertEqual(liveRow?.state, SessionState.recording.rawValue)
        do {
            try await SessionRepository.shared.delete(id: live.id)
            XCTFail("a session that is being recorded must not be deletable")
        } catch {
            XCTAssertTrue(error is SessionRepository.SessionRepositoryError)
        }

        await orchestrator.stop()
        XCTAssertNil(orchestrator.currentSessionId)
    }

    func testScanLeavesASessionBeingRetranscribedAlone() async throws {
        try ClassNote.Database.shared.setup()
        let appState = AppState.shared
        let restore = parkImportWorkers()
        defer { restore() }
        let url = try makeAudioFile()
        // Interrupted and never recovered: no end time, so the scan sees it.
        let session = try await insertSession("Interrupted lecture",
                                              state: .interrupted,
                                              audioPath: url.path)

        let job = Task { await appState.retranscribe(session: session) }
        try await waitUntilRunning(session, in: appState)
        XCTAssertTrue(appState.isWriting(session))

        await appState.refreshInterruptedSessions()

        XCTAssertFalse(appState.interruptedSessions.contains { $0.id == session.id })
        let row = try await SessionRepository.shared.get(id: session.id)
        XCTAssertEqual(row?.state, SessionState.transcribing.rawValue)

        await appState.stopImport(windowId: session.id)
        await job.value
        XCTAssertFalse(appState.isWriting(session))
    }

    // MARK: - One re-transcription per session

    /// The second job used to take over the first's registry entry, and the
    /// first's cleanup then removed it: the window lost its orchestrator,
    /// `hasActiveImports` went false and quitting left the job running.
    func testASecondRetranscriptionOfTheSameSessionJoinsTheFirst() async throws {
        try ClassNote.Database.shared.setup()
        let appState = AppState.shared
        let restore = parkImportWorkers()
        defer { restore() }
        let url = try makeAudioFile()
        let session = try await insertSession("Finished lecture",
                                              state: .transcribed,
                                              endedAt: 2_000,
                                              audioPath: url.path)

        let first = Task { await appState.retranscribe(session: session) }
        try await waitUntilRunning(session, in: appState)
        let worker = try XCTUnwrap(appState.orchestrator(for: session.id))

        let secondReturned = Flag()
        Task {
            await appState.retranscribe(session: session)
            secondReturned.value = true
        }
        try await waitUntil { secondReturned.value }

        XCTAssertTrue(appState.orchestrator(for: session.id) === worker)
        XCTAssertTrue(appState.hasActiveImports)

        await appState.stopImport(windowId: session.id)
        await first.value
        XCTAssertNil(appState.orchestrator(for: session.id))
        XCTAssertFalse(appState.hasActiveImports)
    }

    // MARK: - The sidebar never stays on a deleted course

    func testFilterOnADeletedCourseFallsBackToAll() {
        let kept = Course.new(name: "Linear Algebra")
        XCTAssertEqual(LibraryFilter.course(kept.id).existing(in: [kept]), .course(kept.id))
        XCTAssertEqual(LibraryFilter.course("deleted-elsewhere").existing(in: [kept]), .all)
        XCTAssertEqual(LibraryFilter.unfiled.existing(in: []), .unfiled)
        XCTAssertEqual(LibraryFilter.all.existing(in: []), .all)
    }

    // MARK: - A dead sidecar's pipe cannot kill the app

    /// Checked as a disposition first: if the guard were missing, the write
    /// below would kill the whole test run instead of failing this test.
    func testWritingToAClosedPipeFailsInsteadOfKillingTheApp() throws {
        var current = sigaction()
        XCTAssertEqual(sigaction(SIGPIPE, nil, &current), 0)
        let handler = unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
        guard handler == unsafeBitCast(SIG_IGN, to: Int.self) else {
            return XCTFail("SIGPIPE is not ignored")
        }

        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        close(fds[0])
        defer { close(fds[1]) }
        var byte: UInt8 = 0
        let written = write(fds[1], &byte, 1)
        let failure = errno
        XCTAssertEqual(written, -1)
        XCTAssertEqual(failure, EPIPE)
    }

    // MARK: - Helpers

    @MainActor
    private final class Flag {
        var value = false
    }

    private func insertSession(_ title: String,
                               state: SessionState = .recording,
                               startedAt: Int64? = nil,
                               endedAt: Int64? = nil,
                               audioPath: String? = nil) async throws -> Session {
        var session = Session.new(courseId: nil, title: title, sourceKind: "mic")
        if let startedAt { session.startedAt = startedAt }
        session.state = state.rawValue
        session.endedAt = endedAt
        session.audioPath = audioPath
        try await SessionRepository.shared.insert(session)
        let id = session.id
        addTeardownBlock {
            try? await SessionRepository.shared.delete(id: id, force: true)
        }
        return session
    }

    /// The stub engine never reads it; it only has to exist.
    private func makeAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-shell-\(UUID().uuidString).m4a")
        try Data("not audio, the engine is a stub".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Makes AppState's imports and re-transcriptions run on a stub engine that
    /// parks after one line, so they stay mid-flight until stopped. Returns
    /// what puts the real factory back.
    private func parkImportWorkers() -> () -> Void {
        let appState = AppState.shared
        let original = appState.makeImportWorker
        let wasTranslating = appState.translationEnabled
        appState.translationEnabled = false
        appState.makeImportWorker = {
            let worker = SessionOrchestrator()
            worker.sttProviderOverride = ParkedEngine()
            return worker
        }
        return {
            appState.makeImportWorker = original
            appState.translationEnabled = wasTranslating
        }
    }

    /// Until the stub has emitted its line: the worker writes `transcribing`
    /// only after it reports `isImporting`.
    private func waitUntilRunning(_ session: Session, in appState: AppState) async throws {
        try await waitUntil { appState.orchestrator(for: session.id)?.transcript.segments.isEmpty == false }
    }

    private func waitUntil(_ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        var waited = 0
        while !condition(), waited < 300 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertTrue(condition(), "condition never became true", file: file, line: line)
    }
}

/// Emits one line and then never finishes, like a sidecar partway through a
/// long file: only cancellation ends it.
private struct ParkedEngine: STTProvider {
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
                                                        text: "first line",
                                                        isFinal: true)))
        }
    }
}
