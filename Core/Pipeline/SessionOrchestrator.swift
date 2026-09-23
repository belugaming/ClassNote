import Foundation
import SwiftUI
import Combine

@MainActor
final class SessionOrchestrator: ObservableObject {
    @Published private(set) var currentSessionId: String? = nil
    @Published private(set) var currentSession: Session? = nil
    @Published private(set) var statusText: String = "Idle"
    @Published private(set) var currentTimestampMs: Int64 = 0
    @Published private(set) var isImporting: Bool = false
    @Published private(set) var importCompleted: Int = 0
    @Published private(set) var importTotal: Int = 0
    @Published private(set) var isEphemeralTranslation: Bool = false
    @Published private(set) var importErrorMessage: String?
    @Published var source: AudioSourceKind = .microphone
    @Published var transcript = TranscriptBuffer()

    var importProgress: Double? {
        guard isImporting, importTotal > 0 else { return nil }
        return Double(importCompleted) / Double(importTotal)
    }

    private var audioManager: AudioSourceManager?
    private var sttTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var importWaiters: [CheckedContinuation<Void, Error>] = []
    private var translateTasks: [Int64: Task<Void, Never>] = [:]
    private var draftTranslateTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var ephemeralRowId: Int64 = 0
    /// Lines of the sentence still being spoken, waiting for the line that
    /// ends it. Translation works on whole sentences; see `SentenceGroups`.
    private var pendingSentence: [(rowId: Int64, text: String)] = []
    /// The last few sentences sent to translation, oldest first: the context
    /// the next one is translated with.
    private var sentenceHistory: [String] = []
    /// Whether finished sentences are written back to the database. False for a
    /// live translation that is never saved.
    private var persistTranslations = true
    /// The translator and config the live pipeline runs with, kept so Stop can
    /// translate a sentence the recording ended in the middle of.
    private var liveTranslator: TranslationProvider?
    private var liveConfig: ApiConfig?
    /// The stop currently in flight, if any. Every start calls `stop()` first
    /// and the Stop button can be double-tapped, so the second caller has to
    /// *join* the first rather than skip it: the drain takes seconds, and both
    /// `startNewSession` and `prepareForTermination` read `await stop()` as
    /// "the pipeline is torn down and the row is closed".
    private var stopTask: Task<Void, Never>?
    /// Set when the import/re-transcribe task ended because it was cancelled.
    /// `importErrorMessage` alone cannot express that: it makes
    /// `waitForImportToFinish` throw `EngineError`, which AppState reports as a
    /// failure rather than a cancellation.
    private var importWasCancelled = false
    /// Added to every engine timestamp. The sidecar's start/end times are
    /// connection-relative and restart at 0 after a reconnect, so each attempt
    /// is rebased onto the session's own clock.
    private var engineTimeOffsetMs: Int64 = 0
    /// Resolved once per session, not per sentence: the glossary rides on every
    /// live translation request.
    private var courseContext: CourseContext = .empty
    /// A lost session row makes every later insert fail; say so once rather
    /// than raising an alert per sentence for the rest of the lecture.
    private var didReportSegmentInsertFailure = false
    /// Replaces the engine the factory would build from settings. The only way
    /// to drive cancellation, reconnect and drain behaviour in a test without a
    /// real sidecar or a network.
    var sttProviderOverride: STTProvider?

    private func makeSTTProvider(config: ApiConfig, backend: SttBackend) -> STTProvider {
        if let sttProviderOverride { return sttProviderOverride }
        return EngineFactory.makeSTT(config: config, backend: backend,
                                     hint: courseContext.recognitionHint)
    }

    /// Starts a new session, opens audio capture, begins STT/translation pipeline.
    /// Returns the new session id.
    @discardableResult
    func startNewSession(courseId: String?,
                         title: String? = nil,
                         source: AudioSourceKind? = nil) async throws -> String {
        await stop()
        let src = source ?? self.source
        self.source = src
        let config = AppState.shared.apiConfig
        let sess = Session.new(courseId: courseId,
                               title: title ?? Self.defaultTitle(),
                               sourceKind: src.rawValue)
        try await SessionRepository.shared.insert(sess)
        self.currentSession = sess
        self.currentSessionId = sess.id
        self.isEphemeralTranslation = false
        self.statusText = "Starting capture…"
        self.transcript.reset()
        self.resetSentenceState()
        self.engineTimeOffsetMs = 0
        self.currentTimestampMs = 0
        self.ephemeralRowId = 0
        self.didReportSegmentInsertFailure = false
        if let courseId {
            self.courseContext = CourseContext(course: try? await CourseRepository.shared.get(id: courseId))
        } else {
            self.courseContext = .empty
        }

        let outputURL = AppBootstrap.recordingURL(sessionId: sess.id)
        let manager = AudioSourceManager(microphoneDeviceID: AppState.shared.selectedMicrophoneUniqueID)
        self.audioManager = manager

        if src == .file {
            throw EngineError.unsupported("Use ingestFile for file import")
        }

        do {
            try await manager.start(source: src, outputURL: outputURL)
        } catch {
            // Clean up on failure so next attempt starts fresh. `start` marks
            // itself running before anything can throw, and for `.mixed` the
            // mic engine and its tap are already live when system audio fails,
            // so the manager has to be stopped and not merely dropped.
            await manager.stop()
            self.audioManager = nil
            self.currentSession = nil
            self.currentSessionId = nil
            self.courseContext = .empty
            self.statusText = "Failed to start capture"
            // force: the row is still `recording`, which the repository refuses
            // to delete, and this is the one caller that owns that state.
            try? await SessionRepository.shared.delete(id: sess.id, force: true)
            throw error
        }
        statusText = "Recording"
        try await SessionRepository.shared.setAudioPath(sess.id, audioPath: outputURL.path)
        self.currentSession?.audioPath = outputURL.path

        startTicker()
        startPipeline(config: config, persistSegments: true)

        return sess.id
    }

    /// Starts a live translation session without creating a Session row,
    /// recording audio, or persisting transcript segments. The live window can
    /// display subtitles exactly like a normal recording, but stopping discards
    /// everything in memory.
    @discardableResult
    func startEphemeralTranslation(source: AudioSourceKind? = nil) async throws -> String {
        await stop()
        let src = source ?? self.source
        guard src != .file else {
            throw EngineError.unsupported("Temporary translation does not support file import")
        }

        self.source = src
        let config = AppState.shared.apiConfig
        self.currentSession = nil
        self.currentSessionId = nil
        self.isEphemeralTranslation = true
        self.statusText = "Live translation only"
        self.transcript.reset()
        self.resetSentenceState()
        self.engineTimeOffsetMs = 0
        self.currentTimestampMs = 0
        self.ephemeralRowId = 0
        self.didReportSegmentInsertFailure = false
        self.courseContext = .empty

        let manager = AudioSourceManager(microphoneDeviceID: AppState.shared.selectedMicrophoneUniqueID)
        self.audioManager = manager

        do {
            try await manager.start(source: src, outputURL: nil)
        } catch {
            await manager.stop()
            self.audioManager = nil
            self.isEphemeralTranslation = false
            self.statusText = "Failed to start translation"
            throw error
        }

        startTicker()
        startPipeline(config: config, persistSegments: false)

        return "ephemeral-translation"
    }

    // MARK: - File transcription

    @discardableResult
    func ingestFile(url: URL, courseId: String?) async throws -> String {
        let sess = Session.new(courseId: courseId,
                               title: url.deletingPathExtension().lastPathComponent,
                               sourceKind: "file")
        try await SessionRepository.shared.insert(sess)
        self.currentSession = sess
        return try await runFileTranscription(sessionId: sess.id,
                                              url: url,
                                              replaceExisting: false,
                                              finalAudioPath: url.path,
                                              sourceLabel: url.lastPathComponent)
    }

    /// Re-runs transcription over a session's own recording, replacing its
    /// segments. Same engine path as a file import; the session row, its title
    /// and its course are kept.
    @discardableResult
    func retranscribeSession(_ session: Session) async throws -> String {
        guard let path = session.audioPath,
              FileManager.default.fileExists(atPath: path) else {
            throw EngineError.unsupported(L10n.t("retranscribe.noAudio"))
        }
        guard AppState.shared.orchestrator.currentSessionId != session.id else {
            throw EngineError.unsupported(L10n.t("retranscribe.recording"))
        }
        self.currentSession = session
        return try await runFileTranscription(sessionId: session.id,
                                              url: URL(fileURLWithPath: path),
                                              replaceExisting: true,
                                              finalAudioPath: path,
                                              sourceLabel: session.title)
    }

    /// Shared body of "transcribe a file into this session".
    ///
    /// `replaceExisting` buffers the new segments in memory and commits them in
    /// one transaction at the end: a re-transcription that fails halfway must
    /// leave the old transcript intact rather than a truncated new one.
    @discardableResult
    private func runFileTranscription(sessionId: String,
                                      url: URL,
                                      replaceExisting: Bool,
                                      finalAudioPath: String,
                                      sourceLabel: String) async throws -> String {
        let config = AppState.shared.apiConfig
        self.currentSessionId = sessionId
        self.source = .file
        self.isEphemeralTranslation = false
        self.statusText = "Importing \(sourceLabel)"
        self.transcript.reset()
        self.resetSentenceState()
        self.engineTimeOffsetMs = 0
        self.currentTimestampMs = 0
        self.ephemeralRowId = 0
        self.isImporting = true
        self.importCompleted = 0
        self.importTotal = 0
        self.importErrorMessage = nil
        self.importWasCancelled = false
        self.courseContext = CourseContext(course: try? await CourseRepository.shared.forSession(id: sessionId))

        let startedAt = self.currentSession?.startedAt ?? Int64(Date().timeIntervalSince1970 * 1000)
        let stt = makeSTTProvider(config: config, backend: AppState.shared.sttBackend)
        let translator = EngineFactory.makeTranslator(config: config, backend: AppState.shared.translationBackend)
        // A re-transcription does not own this row's terminal state: its
        // segments are only committed by `replaceAll` at the very end, so
        // failing or cancelling leaves the old transcript — and the notes and
        // flashcards built on it — perfectly intact. Remember where the row was
        // so the catches can put it back instead of branding a healthy session
        // `failed`, which nothing would ever clear.
        let priorState: String?
        if replaceExisting {
            let existing = try? await SessionRepository.shared.get(id: sessionId)
            priorState = (existing ?? nil)?.state ?? SessionState.transcribed.rawValue
        } else {
            priorState = nil
        }
        try? await SessionRepository.shared.setState(sessionId, state: SessionState.transcribing.rawValue)

        importTask?.cancel()
        importTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var lastEndMs: Int64 = 0
            var buffered: [Segment] = []
            do {
                let stream = stt.transcribeFile(url: url, language: config.sourceLanguage)
                for try await ev in stream {
                    switch ev {
                    case .progress(let completed, let total):
                        self.importCompleted = completed
                        self.importTotal = total
                    case .segment(let event):
                        let polishedText = TranscriptTextPolisher.polish(event.text)
                        let seg = Segment(id: nil,
                                           sessionId: sessionId,
                                           startMs: event.startMs,
                                           endMs: event.endMs,
                                           speakerId: nil,
                                           textOriginal: polishedText,
                                           textTranslated: "",
                                           isFinal: true,
                                           confidence: 0,
                                           version: 1,
                                           continuesNext: event.continuesSentence)
                        let rowId: Int64
                        if replaceExisting {
                            // Not committed yet, so the live view gets the same
                            // synthetic negative ids the ephemeral path uses.
                            buffered.append(seg)
                            self.ephemeralRowId -= 1
                            rowId = self.ephemeralRowId
                        } else {
                            rowId = try await SegmentRepository.shared.insert(seg)
                        }
                        self.transcript.appendFinal(rowId: rowId,
                                                    startMs: event.startMs,
                                                    endMs: event.endMs,
                                                    original: polishedText,
                                                    continuesNext: event.continuesSentence)
                        self.currentTimestampMs = event.endMs
                        lastEndMs = max(lastEndMs, event.endMs)
                        if !replaceExisting, AppState.shared.translationEnabled {
                            self.enqueueForTranslation(rowId: rowId,
                                                       text: polishedText,
                                                       continuesSentence: event.continuesSentence,
                                                       translator: translator,
                                                       config: config)
                        }
                    }
                }
                // AsyncThrowingStream ends the loop (returns nil) when the
                // consuming task is cancelled rather than throwing, so ask the
                // task directly instead of reading "the loop ended" as success.
                try Task.checkCancellation()
                if !replaceExisting, AppState.shared.translationEnabled {
                    // A file that ends mid-sentence still gets that sentence.
                    self.flushPendingSentence(translator: translator, config: config)
                }
                if replaceExisting {
                    let ids = try await SegmentRepository.shared.replaceAll(sessionId: sessionId,
                                                                             with: buffered)
                    if AppState.shared.translationEnabled {
                        var committed: [Segment] = []
                        for (index, id) in ids.enumerated() where index < buffered.count {
                            var seg = buffered[index]
                            seg.id = id
                            committed.append(seg)
                        }
                        _ = try await self.translateSegments(committed,
                                                             translator: translator,
                                                             config: config,
                                                             glossary: self.courseContext.translationGlossary)
                    }
                }
                try await SessionRepository.shared.setEnded(sessionId,
                                                             endedAt: startedAt + lastEndMs,
                                                             durationMs: lastEndMs,
                                                             audioPath: finalAudioPath)
                self.statusText = "Import finished"
                self.importErrorMessage = nil
                self.finishImportWaiters()
            } catch is CancellationError {
                // Keep whatever was transcribed, but say so honestly: `failed`
                // rather than `transcribed`, and keep the audio path so U7 can
                // pick the session up again later. `interrupted` would be
                // invisible, since recovery excludes source_kind='file'.
                self.importWasCancelled = true
                if let priorState {
                    try? await SessionRepository.shared.setState(sessionId, state: priorState)
                } else {
                    try? await SessionRepository.shared.setFailed(sessionId)
                }
                try? await SessionRepository.shared.setAudioPath(sessionId, audioPath: finalAudioPath)
                self.statusText = "Import cancelled"
                self.importErrorMessage = CancellationError().localizedDescription
                self.finishImportWaiters(with: CancellationError())
            } catch {
                NSLog("[ClassNote] file transcription failed: \(error)")
                if let priorState {
                    try? await SessionRepository.shared.setState(sessionId, state: priorState)
                } else {
                    try? await SessionRepository.shared.setFailed(sessionId)
                }
                self.statusText = "Import failed: \(error.localizedDescription)"
                self.importErrorMessage = error.localizedDescription
                AppState.shared.setError(error.localizedDescription)
                self.finishImportWaiters(with: error)
            }
            self.isImporting = false
        }
        return sessionId
    }

    func waitForImportToFinish() async throws {
        if !isImporting {
            if importWasCancelled { throw CancellationError() }
            if let importErrorMessage {
                throw EngineError.unsupported(importErrorMessage)
            }
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            importWaiters.append(continuation)
        }
    }

    // MARK: - Stop

    /// Tears the pipeline down producer-first: ending the audio stream is what
    /// makes every STT backend flush its last utterance, so the consumers are
    /// drained to their natural end and cancelled only on a timeout.
    ///
    /// `drainTimeout` bounds the two long waits (STT, then the in-flight
    /// translations). The quit path passes a shorter one so the whole teardown
    /// fits inside AppKit's reply backstop; a stop that is already running
    /// keeps the timeout it started with, which is what joining it means.
    func stop(drainTimeout: Duration = .seconds(5)) async {
        if let inFlight = stopTask {
            await inFlight.value
            return
        }
        // Unstructured on purpose: the joiner and the originator must both see
        // the same stop through to the end, even if the caller that started it
        // is cancelled. `@MainActor` keeps the body on this actor, so the
        // ordering below is unchanged.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStop(drainTimeout: drainTimeout)
            // Cleared from inside, before the task completes: a caller that
            // resumed later could otherwise clobber a stop that started in the
            // meantime, or hand the next one a finished task to "join" while a
            // new recording is live.
            self.stopTask = nil
        }
        stopTask = task
        await task.value
    }

    private func performStop(drainTimeout: Duration) async {
        tickerTask?.cancel()
        tickerTask = nil
        draftTranslateTask?.cancel()
        draftTranslateTask = nil

        // An import owns its own session row and writes its own terminal state,
        // so remember whether one was running before draining it.
        let wasImporting = isImporting
        let running = importTask
        importTask = nil
        running?.cancel()
        await drain(running, timeout: min(drainTimeout, .seconds(2)))

        let finalMs = currentTimestampMs
        // Read before stopping: `stop()` is also the second, defensive stop at
        // the head of the next start, where there is no manager left to ask.
        let audioPath = audioManager?.state.audioFileURL?.path

        await audioManager?.stop()
        audioManager = nil

        // The final segment is inserted under `currentSessionId`, so it must
        // still be set while these drain.
        let stt = sttTask
        sttTask = nil
        await drain(stt, timeout: drainTimeout)
        // Whatever the engine flushed last may have been a line cut mid
        // sentence; nothing will come to finish it now.
        if let translator = liveTranslator, let config = liveConfig {
            flushPendingSentence(translator: translator, config: config)
        }
        liveTranslator = nil
        liveConfig = nil
        await drainTranslations(timeout: drainTimeout)

        // Only a live recording's row is ours to close: an import writes its
        // own terminal state (and its own audio path), and an ephemeral session
        // has no row at all. `source` still says which this was.
        if let sid = currentSessionId, !wasImporting, !isEphemeralTranslation, source != .file {
            let duration = max(finalMs, transcript.segments.last?.endMs ?? 0)
            try? await SessionRepository.shared.setEnded(sid,
                                                          endedAt: Int64(Date().timeIntervalSince1970 * 1000),
                                                          durationMs: duration,
                                                          audioPath: audioPath)
        }
        // Release ownership last. Anything above still needs the session id.
        currentSessionId = nil
        currentSession = nil
        courseContext = .empty
        isImporting = false
        isEphemeralTranslation = false
        statusText = "Stopped"
        finishImportWaiters(with: CancellationError())
    }

    /// Awaits `task`, cancelling it only if it outstays `timeout`.
    private func drain(_ task: Task<Void, Never>?, timeout: Duration) async {
        guard let running = task else { return }
        let watchdog = Task { try? await Task.sleep(for: timeout); running.cancel() }
        await running.value
        watchdog.cancel()
    }

    /// Same for translations of segments that were already committed: their
    /// `updateTranslation` write is the last thing standing between a finished
    /// sentence and a permanently blank translation.
    private func drainTranslations(timeout: Duration) async {
        let tasks = Array(translateTasks.values)
        translateTasks.removeAll()
        guard !tasks.isEmpty else { return }
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            for task in tasks { task.cancel() }
        }
        for task in tasks { await task.value }
        watchdog.cancel()
    }

    private func finishImportWaiters(with error: Error? = nil) {
        let waiters = importWaiters
        importWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }

    // MARK: - Pipeline

    private func startTicker() {
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run {
                    if let start = self?.audioManager?.state.startedAt {
                        self?.currentTimestampMs = Int64(Date().timeIntervalSince(start) * 1000)
                    }
                }
            }
        }
    }

    /// Supervises the STT stream. A local sidecar can die mid-lecture; before
    /// this the pipeline simply ended and the rest of the class had no
    /// subtitles, while capture kept running.
    private func startPipeline(config: ApiConfig, persistSegments: Bool) {
        guard audioManager != nil else { return }
        let backend = AppState.shared.sttBackend

        sttTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self = self, let manager = self.audioManager else { return }
                do {
                    try await self.runSTTStream(manager: manager,
                                                config: config,
                                                persistSegments: persistSegments,
                                                backend: backend)
                    // Clean end of stream: capture stopped, stop() is draining us.
                    return
                } catch {
                    // Cancellation ends the stream without throwing, so reaching
                    // here means the engine really failed — unless stop() got in
                    // between.
                    guard !Task.isCancelled else { return }
                    attempt += 1
                    NSLog("[ClassNote] STT stream failed (attempt \(attempt)): \(error)")
                    guard attempt <= 5 else {
                        self.statusText = L10n.t("live.engineGaveUp")
                        AppState.shared.setError(error.localizedDescription)
                        return
                    }
                    self.statusText = L10n.t("live.engineReconnecting")
                    // The engine clock restarts at 0 on a new connection. A
                    // sentence left open stays pending: its rest arrives on
                    // the new connection.
                    self.engineTimeOffsetMs = self.currentTimestampMs
                    if backend.isLocalSidecar, attempt >= 2 {
                        // Twice in a row means the process is wedged, not the
                        // socket: replace it before the next attempt.
                        _ = await LocalASRWarmPool.shared.retire(force: true)
                    }
                    try? await Task.sleep(for: .seconds(min(1 << (attempt - 1), 8)))
                }
            }
        }
    }

    /// One attempt at consuming the engine's event stream. Throws on engine
    /// failure so `startPipeline` can decide whether to reconnect.
    private func runSTTStream(manager: AudioSourceManager,
                              config: ApiConfig,
                              persistSegments: Bool,
                              backend: SttBackend) async throws {
        let stt = makeSTTProvider(config: config, backend: backend)
        let translator = EngineFactory.makeTranslator(config: config,
                                                      backend: AppState.shared.translationBackend)
        liveTranslator = translator
        liveConfig = config
        persistTranslations = persistSegments
        // Feed all chunks (including short silences) to STT — it does its own
        // silence-aware sentence buffering. A naive VAD pre-filter would prevent
        // it from seeing the trailing silence that signals "end of sentence".
        // A fresh subscriber per attempt: the previous one died with its engine.
        let stream = manager.makeChunkStream()
        let offsetMs = engineTimeOffsetMs
        let ttStream = stt.transcribe(audio: stream,
                                      language: config.sourceLanguage.isEmpty ? nil : config.sourceLanguage)

        for try await rawEvent in ttStream {
            let event = rawEvent.shifted(by: offsetMs)
            // The engine produced something, so any local-engine setup
            // progress is done and its status line can go away.
            if !AppState.shared.localEngineStatus.isEmpty {
                AppState.shared.localEngineStatus = ""
            }

            guard event.isFinal else {
                // The line still being spoken. If translation is on, the
                // draft translation covers the whole sentence so far: the
                // lines of it already committed plus this one.
                let polishedDraft = TranscriptTextPolisher.polish(event.text)
                transcript.updateDraft(polishedDraft)
                if AppState.shared.translationEnabled {
                    let sentence = SentenceGroups.join(pendingSentence.map(\.text) + [polishedDraft])
                    self.translateDraft(text: sentence, draft: polishedDraft,
                                        translator: translator, config: config)
                }
                continue
            }

            self.draftTranslateTask?.cancel()
            self.draftTranslateTask = nil
            let rowId: Int64
            let polishedText = TranscriptTextPolisher.polish(event.text)
            if persistSegments {
                guard let sid = self.currentSessionId else { continue }
                let seg = Segment(id: nil,
                                   sessionId: sid,
                                   startMs: event.startMs,
                                   endMs: event.endMs,
                                   speakerId: event.speakerId,
                                   textOriginal: polishedText,
                                   textTranslated: "",
                                   isFinal: event.isFinal,
                                   confidence: 0,
                                   version: 1,
                                   continuesNext: event.continuesSentence)
                do {
                    rowId = try await SegmentRepository.shared.insert(seg)
                } catch {
                    // The session row can vanish under us (deleted from the
                    // sidebar) and the database can be momentarily unavailable.
                    // Keep transcribing into the live buffer instead of tearing
                    // the pipeline down for the rest of the lecture.
                    NSLog("[ClassNote] segment insert failed: \(error)")
                    if !self.didReportSegmentInsertFailure {
                        self.didReportSegmentInsertFailure = true
                        AppState.shared.setError(error.localizedDescription)
                    }
                    self.statusText = "Not saving: session row is gone"
                    self.ephemeralRowId -= 1
                    let fallbackId = self.ephemeralRowId
                    transcript.appendFinal(rowId: fallbackId,
                                           startMs: event.startMs,
                                           endMs: event.endMs,
                                           original: polishedText,
                                           continuesNext: event.continuesSentence)
                    continue
                }
            } else {
                self.ephemeralRowId -= 1
                rowId = self.ephemeralRowId
            }
            transcript.appendFinal(rowId: rowId,
                                   startMs: event.startMs,
                                   endMs: event.endMs,
                                   original: polishedText,
                                   continuesNext: event.continuesSentence)
            if AppState.shared.translationEnabled {
                self.enqueueForTranslation(rowId: rowId,
                                           text: polishedText,
                                           continuesSentence: event.continuesSentence,
                                           translator: translator,
                                           config: config)
            }
        }
    }

    // MARK: - Translation

    private func resetSentenceState() {
        pendingSentence.removeAll()
        sentenceHistory.removeAll()
    }

    /// Takes one committed line. A line cut mid-sentence waits for the rest;
    /// the line that ends a sentence sends the whole sentence to translation.
    private func enqueueForTranslation(rowId: Int64,
                                       text: String,
                                       continuesSentence: Bool,
                                       translator: TranslationProvider,
                                       config: ApiConfig) {
        pendingSentence.append((rowId, text))
        guard !continuesSentence else { return }
        flushPendingSentence(translator: translator, config: config)
    }

    /// Translates whatever sentence is pending, finished or not.
    private func flushPendingSentence(translator: TranslationProvider, config: ApiConfig) {
        let lines = pendingSentence
        pendingSentence.removeAll()
        guard let last = lines.last else { return }
        let text = SentenceGroups.join(lines.map(\.text))
        guard !text.isEmpty else { return }
        let context = Array(sentenceHistory.suffix(Self.contextSentences))
        sentenceHistory.append(text)
        if sentenceHistory.count > 8 { sentenceHistory.removeFirst(sentenceHistory.count - 8) }
        translate(rowId: last.rowId,
                  leadingRowIds: lines.dropLast().map(\.rowId),
                  text: text,
                  context: context,
                  translator: translator,
                  config: config,
                  persistTranslation: persistTranslations)
    }

    /// How many preceding sentences a translation sees. Enough to resolve
    /// "it" and "this" across a sentence boundary.
    static let contextSentences = 2

    /// Translates one sentence. Its translation lands on `rowId`, the line that
    /// ends it; `leadingRowIds` are the lines before it in the same sentence,
    /// marked `.merged` once the translation is in.
    private func translate(rowId: Int64,
                           leadingRowIds: [Int64],
                           text: String,
                           context: [String],
                           translator: TranslationProvider,
                           config: ApiConfig,
                           persistTranslation: Bool) {
        let glossary = courseContext.translationGlossary
        let task = Task { @MainActor [transcript] in
            let stream = translator.translate(text: text,
                                               sourceLanguage: config.sourceLanguage,
                                               targetLanguage: config.targetLanguage,
                                               context: context,
                                               glossary: glossary)
            // Hoisted above the `do` so both catches can persist the part that
            // did arrive. Ephemeral rows have synthetic negative ids that match
            // no DB row, which is what `persistTranslation` guards.
            var accumulated = ""
            do {
                for try await delta in stream {
                    accumulated += delta
                    transcript.appendTranslationDelta(rowId: rowId, delta: delta)
                }
                if persistTranslation {
                    try? await SegmentRepository.shared.updateTranslation(id: rowId,
                                                                           textTranslated: accumulated,
                                                                           state: .ok)
                    try? await SegmentRepository.shared.markMerged(ids: leadingRowIds)
                }
            } catch is CancellationError {
                // Stop() cancels in-flight translations; keep what arrived and
                // mark the row so the retry can find it instead of leaving it
                // indistinguishable from a line with nothing to translate.
                if persistTranslation {
                    try? await SegmentRepository.shared.updateTranslation(id: rowId,
                                                                           textTranslated: accumulated,
                                                                           state: .failed)
                }
            } catch {
                if persistTranslation {
                    try? await SegmentRepository.shared.updateTranslation(id: rowId,
                                                                           textTranslated: accumulated,
                                                                           state: .failed)
                }
                AppState.shared.setError("Translation error: \(error.localizedDescription)")
            }
        }
        translateTasks[rowId] = task
    }

    /// Translates the sentence being spoken so the translation keeps pace
    /// instead of only starting once the sentence is committed. Debounced: the
    /// engine emits a new draft several times a second, and translating every
    /// one would keep the translator permanently busy with text about to
    /// change.
    ///
    /// `text` is the whole sentence so far; `draft` is the draft line it was
    /// built for, which is what a late result is checked against.
    private func translateDraft(text: String, draft: String,
                                translator: TranslationProvider, config: ApiConfig) {
        draftTranslateTask?.cancel()
        guard !text.isEmpty else { return }
        let glossary = courseContext.translationGlossary
        let context = Array(sentenceHistory.suffix(Self.contextSentences))
        draftTranslateTask = Task { @MainActor [transcript] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let stream = translator.translate(text: text,
                                               sourceLanguage: config.sourceLanguage,
                                               targetLanguage: config.targetLanguage,
                                               context: context,
                                               glossary: glossary)
            do {
                var accumulated = ""
                for try await delta in stream {
                    guard !Task.isCancelled else { return }
                    accumulated += delta
                    transcript.updateDraftTranslation(accumulated, forDraft: draft)
                }
            } catch {
                // A draft translation failing (or being superseded by a
                // newer draft mid-stream) isn't worth surfacing as a user
                // facing error — the sentence's own translation will retry.
            }
        }
    }

    // MARK: - Retranslate / Resummarize helpers

    /// Retranslates a session. `failedOnly` covers just the sentences whose
    /// translation never landed (a network error, or a stream cancelled by
    /// Stop); the full pass stays available for a language or model change.
    /// Returns how many sentences are still untranslated afterwards.
    @discardableResult
    func retranslateSession(sessionId: String,
                            failedOnly: Bool = false,
                            onProgress: ((Int, Int) -> Void)? = nil) async throws -> Int {
        let config = AppState.shared.apiConfig
        let translator = EngineFactory.makeTranslator(config: config,
                                                      backend: AppState.shared.translationBackend)
        let course = try? await CourseRepository.shared.forSession(id: sessionId)
        let segs = try await SegmentRepository.shared.all(sessionId: sessionId)
        return try await translateSegments(segs,
                                           translator: translator,
                                           config: config,
                                           glossary: CourseContext(course: course).translationGlossary,
                                           failedOnly: failedOnly,
                                           onProgress: onProgress)
    }

    /// Translates `segments` sentence by sentence, with bounded concurrency,
    /// collecting failures instead of aborting the run. Returns the number of
    /// sentences that failed.
    ///
    /// `failedOnly` skips sentences whose lines are all settled. Grouping
    /// always runs over the whole list, so a retried sentence is still
    /// translated whole and with the sentences before it as context.
    ///
    /// 4 at a time: a 90-minute lecture is ~600 lines and serial round-trips
    /// make a retry unusable, while more would upset cloud rate limits and the
    /// single-worker MLX sidecar.
    @discardableResult
    private func translateSegments(_ segments: [Segment],
                                   translator: TranslationProvider,
                                   config: ApiConfig,
                                   glossary: TranslationGlossary,
                                   failedOnly: Bool = false,
                                   onProgress: ((Int, Int) -> Void)? = nil) async throws -> Int {
        let groups = SentenceGroups.group(segments.filter { $0.id != nil && !$0.textOriginal.isEmpty })
        var jobs: [SentenceJob] = []
        var previous: [String] = []
        for group in groups {
            let text = SentenceGroups.join(group.map(\.textOriginal))
            let context = Array(previous.suffix(Self.contextSentences))
            previous.append(text)
            if failedOnly && group.allSatisfy({ $0.translationState.isSettled }) { continue }
            jobs.append(SentenceJob(lines: group, text: text, context: context))
        }
        guard !jobs.isEmpty else {
            onProgress?(0, 0)
            return 0
        }
        var done = 0
        var failed = 0
        try await withThrowingTaskGroup(of: Bool.self) { group in
            var next = 0
            while next < min(4, jobs.count) {
                let job = jobs[next]
                group.addTask {
                    try await Self.translateOne(job, translator: translator,
                                                config: config, glossary: glossary)
                }
                next += 1
            }
            while let ok = try await group.next() {
                done += 1
                if !ok { failed += 1 }
                onProgress?(done, jobs.count)
                if next < jobs.count {
                    let job = jobs[next]
                    group.addTask {
                        try await Self.translateOne(job, translator: translator,
                                                    config: config, glossary: glossary)
                    }
                    next += 1
                }
            }
        }
        return failed
    }

    /// One sentence of a batch translation.
    struct SentenceJob: Sendable {
        let lines: [Segment]
        let text: String
        let context: [String]
    }

    /// One sentence's translation, off the main actor. Returns false when the
    /// translation did not land, so the caller can report a partial run.
    nonisolated private static func translateOne(_ job: SentenceJob,
                                                 translator: TranslationProvider,
                                                 config: ApiConfig,
                                                 glossary: TranslationGlossary) async throws -> Bool {
        guard let last = job.lines.last?.id else { return true }
        let leading = job.lines.dropLast().compactMap(\.id)
        var buf = ""
        do {
            let stream = translator.translate(text: job.text,
                                               sourceLanguage: config.sourceLanguage,
                                               targetLanguage: config.targetLanguage,
                                               context: job.context,
                                               glossary: glossary)
            for try await delta in stream {
                buf += delta
            }
            guard !buf.isEmpty else {
                try? await SegmentRepository.shared.updateTranslation(id: last,
                                                                       textTranslated: buf,
                                                                       state: .failed)
                return false
            }
            try? await SegmentRepository.shared.updateTranslation(id: last,
                                                                   textTranslated: buf,
                                                                   state: .ok)
            try? await SegmentRepository.shared.markMerged(ids: leading)
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // One bad sentence must not abort the rest — that is exactly the
            // failure this pass exists to clean up.
            try? await SegmentRepository.shared.updateTranslation(id: last,
                                                                   textTranslated: buf,
                                                                   state: .failed)
            return false
        }
    }

    static func defaultTitle() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return "Session \(df.string(from: Date()))"
    }
}

extension TranscriptEvent {
    /// Rebases an engine event onto the session's clock. Sidecar timestamps are
    /// connection-relative (`stream_ms` restarts at 0), so after a reconnect
    /// every start/end has to be shifted by however far the session already ran.
    func shifted(by offsetMs: Int64) -> TranscriptEvent {
        guard offsetMs != 0 else { return self }
        return TranscriptEvent(startMs: startMs + offsetMs,
                               endMs: endMs + offsetMs,
                               text: text,
                               isFinal: isFinal,
                               speakerId: speakerId,
                               continuesSentence: continuesSentence)
    }
}

enum TranscriptTextPolisher {
    private static let replacements: [(pattern: String, replacement: String)] = [
        (#"\bteh\b"#, "the"),
        (#"\brecieve\b"#, "receive"),
        (#"\bseperate\b"#, "separate"),
        (#"\bdefinately\b"#, "definitely"),
        (#"\boccured\b"#, "occurred")
    ]

    static func polish(_ text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return "" }

        output = output.replacingOccurrences(of: #"\s+"#,
                                             with: " ",
                                             options: .regularExpression)
        output = output.replacingOccurrences(of: #"\s+([,.;:?!])"#,
                                             with: "$1",
                                             options: .regularExpression)
        output = output.replacingOccurrences(of: #"\s+([，。；：？！])"#,
                                             with: "$1",
                                             options: .regularExpression)
        output = output.replacingOccurrences(of: #"([。！？!?])\s*"#,
                                             with: "$1 ",
                                             options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for replacement in replacements {
            output = output.replacingOccurrences(of: replacement.pattern,
                                                 with: replacement.replacement,
                                                 options: [.regularExpression, .caseInsensitive])
        }

        if let first = output.unicodeScalars.first,
           CharacterSet.lowercaseLetters.contains(first),
           output.range(of: #"^[a-z][A-Za-z0-9 ,;:'"\-()]+[.!?]?$"#, options: .regularExpression) != nil {
            output = output.prefix(1).uppercased() + output.dropFirst()
        }
        return output
    }
}
