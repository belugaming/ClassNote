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
    private var tickerTask: Task<Void, Never>?
    private var ephemeralRowId: Int64 = 0

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
        self.currentTimestampMs = 0

        let outputURL = AppBootstrap.recordingURL(sessionId: sess.id)
        let manager = AudioSourceManager()
        self.audioManager = manager

        if src == .file {
            throw EngineError.unsupported("Use ingestFile for file import")
        }

        do {
            try await manager.start(source: src, outputURL: outputURL)
        } catch {
            // Clean up on failure so next attempt starts fresh.
            self.audioManager = nil
            self.currentSession = nil
            self.currentSessionId = nil
            self.statusText = "Failed to start capture"
            try? await SessionRepository.shared.delete(id: sess.id)
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
        self.currentTimestampMs = 0
        self.ephemeralRowId = 0

        let manager = AudioSourceManager()
        self.audioManager = manager

        do {
            try await manager.start(source: src, outputURL: nil)
        } catch {
            self.audioManager = nil
            self.isEphemeralTranslation = false
            self.statusText = "Failed to start translation"
            throw error
        }

        startTicker()
        startPipeline(config: config, persistSegments: false)

        return "ephemeral-translation"
    }

    func ingestFile(url: URL, courseId: String?) async throws -> String {
        let config = AppState.shared.apiConfig
        let sess = Session.new(courseId: courseId,
                               title: url.deletingPathExtension().lastPathComponent,
                               sourceKind: "file")
        try await SessionRepository.shared.insert(sess)
        self.currentSession = sess
        self.currentSessionId = sess.id
        self.source = .file
        self.isEphemeralTranslation = false
        self.statusText = "Importing \(url.lastPathComponent)"
        self.transcript.reset()
        self.currentTimestampMs = 0
        self.isImporting = true
        self.importCompleted = 0
        self.importTotal = 0
        self.importErrorMessage = nil

        let stt = EngineFactory.makeSTT(config: config, backend: .openAICompatible)
        let translator = EngineFactory.makeTranslator(config: config)
        let sessionId = sess.id

        importTask?.cancel()
        importTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var lastEndMs: Int64 = 0
            do {
                let stream = stt.transcribeFile(url: url, language: config.sourceLanguage)
                for try await ev in stream {
                    switch ev {
                    case .progress(let completed, let total):
                        self.importCompleted = completed
                        self.importTotal = total
                    case .segment(let event):
                        let seg = Segment(id: nil,
                                           sessionId: sessionId,
                                           startMs: event.startMs,
                                           endMs: event.endMs,
                                           speakerId: nil,
                                           textOriginal: event.text,
                                           textTranslated: "",
                                           isFinal: true,
                                           confidence: 0,
                                           version: 1)
                        let rowId = try await SegmentRepository.shared.insert(seg)
                        self.transcript.appendFinal(rowId: rowId,
                                                    startMs: event.startMs,
                                                    endMs: event.endMs,
                                                    original: event.text)
                        self.currentTimestampMs = event.endMs
                        lastEndMs = max(lastEndMs, event.endMs)
                        if AppState.shared.translationEnabled {
                            self.translate(rowId: rowId, text: event.text,
                                           translator: translator, config: config)
                        }
                    }
                }
                try await SessionRepository.shared.setEnded(sessionId,
                                                             endedAt: Int64(Date().timeIntervalSince1970 * 1000),
                                                             durationMs: lastEndMs,
                                                             audioPath: url.path)
                self.statusText = "Import finished"
                self.importErrorMessage = nil
                self.finishImportWaiters()
            } catch is CancellationError {
                self.statusText = "Import cancelled"
                self.importErrorMessage = CancellationError().localizedDescription
                self.finishImportWaiters(with: CancellationError())
            } catch {
                NSLog("[ClassNote] ingestFile failed: \(error)")
                self.statusText = "Import failed: \(error.localizedDescription)"
                self.importErrorMessage = error.localizedDescription
                AppState.shared.setError(error.localizedDescription)
                self.finishImportWaiters(with: error)
            }
            self.isImporting = false
        }
        return sess.id
    }

    func waitForImportToFinish() async throws {
        if !isImporting {
            if let importErrorMessage {
                throw EngineError.unsupported(importErrorMessage)
            }
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            importWaiters.append(continuation)
        }
    }

    func stop() async {
        sttTask?.cancel()
        sttTask = nil
        importTask?.cancel()
        importTask = nil
        tickerTask?.cancel()
        tickerTask = nil
        for (_, t) in translateTasks { t.cancel() }
        translateTasks.removeAll()

        let finalMs = currentTimestampMs
        let audioPath = audioManager?.state.audioFileURL?.path
        await audioManager?.stop()
        audioManager = nil

        if let sid = currentSessionId {
            try? await SessionRepository.shared.setEnded(sid,
                                                          endedAt: Int64(Date().timeIntervalSince1970 * 1000),
                                                          durationMs: finalMs,
                                                          audioPath: audioPath)
        }
        isImporting = false
        isEphemeralTranslation = false
        statusText = "Stopped"
        finishImportWaiters(with: CancellationError())
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

    private func startPipeline(config: ApiConfig, persistSegments: Bool) {
        guard let manager = audioManager else { return }
        let backend = AppState.shared.sttBackend
        let stt = EngineFactory.makeSTT(config: config, backend: backend)
        let translator = EngineFactory.makeTranslator(config: config)

        // Feed all chunks (including short silences) to STT — it does its own
        // silence-aware sentence buffering. A naive VAD pre-filter would prevent
        // it from seeing the trailing silence that signals "end of sentence".
        let stream = manager.chunks

        sttTask = Task { [weak self, transcript, config] in
            guard let self = self else { return }
            let ttStream = stt.transcribe(audio: stream, language: config.sourceLanguage.isEmpty ? nil : config.sourceLanguage)
            do {
                for try await event in ttStream {
                    let rowId: Int64
                    if persistSegments {
                        guard let sid = await MainActor.run(body: { self.currentSessionId }) else { continue }
                        let seg = Segment(id: nil,
                                           sessionId: sid,
                                           startMs: event.startMs,
                                           endMs: event.endMs,
                                           speakerId: event.speakerId,
                                           textOriginal: event.text,
                                           textTranslated: "",
                                           isFinal: event.isFinal,
                                           confidence: 0,
                                           version: 1)
                        rowId = try await SegmentRepository.shared.insert(seg)
                    } else {
                        rowId = await MainActor.run {
                            self.ephemeralRowId -= 1
                            return self.ephemeralRowId
                        }
                    }
                    await MainActor.run {
                        transcript.appendFinal(rowId: rowId, startMs: event.startMs, endMs: event.endMs, original: event.text)
                    }
                    if AppState.shared.translationEnabled {
                        self.translate(rowId: rowId,
                                       text: event.text,
                                       translator: translator,
                                       config: config,
                                       persistTranslation: persistSegments)
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusText = "STT error: \(error.localizedDescription)"
                    AppState.shared.setError(error.localizedDescription)
                }
            }
        }
    }

    private func translate(rowId: Int64,
                           text: String,
                           translator: TranslationProvider,
                           config: ApiConfig,
                           persistTranslation: Bool = true) {
        let task = Task { @MainActor [transcript, weak self] in
            guard let _ = self else { return }
            let ctx = transcript.recent(4)
            let stream = translator.translate(text: text,
                                               sourceLanguage: config.sourceLanguage,
                                               targetLanguage: config.targetLanguage,
                                               context: ctx)
            do {
                var accumulated = ""
                for try await delta in stream {
                    accumulated += delta
                    transcript.appendTranslationDelta(rowId: rowId, delta: delta)
                }
                if persistTranslation {
                    try? await SegmentRepository.shared.updateTranslation(id: rowId, textTranslated: accumulated)
                }
            } catch {
                AppState.shared.setError("Translation error: \(error.localizedDescription)")
            }
        }
        translateTasks[rowId] = task
    }

    // MARK: - Retranslate / Resummarize helpers

    func retranslateSession(sessionId: String) async throws {
        let config = AppState.shared.apiConfig
        let translator = EngineFactory.makeTranslator(config: config)
        let segs = try await SegmentRepository.shared.all(sessionId: sessionId)
        for seg in segs {
            guard let sid = seg.id else { continue }
            var buf = ""
            let stream = translator.translate(text: seg.textOriginal,
                                               sourceLanguage: config.sourceLanguage,
                                               targetLanguage: config.targetLanguage,
                                               context: [])
            for try await delta in stream {
                buf += delta
            }
            try? await SegmentRepository.shared.updateTranslation(id: sid, textTranslated: buf)
        }
    }

    static func defaultTitle() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return "Session \(df.string(from: Date()))"
    }
}
