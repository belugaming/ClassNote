import Foundation
import SwiftUI
import Combine
import AVFoundation
import CoreGraphics

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isRecording: Bool = false
    @Published var currentSessionId: String? = nil
    /// Raised by the ⌘⇧N menu command and lowered by the sidebar once it has
    /// opened its new-course sheet.
    @Published var presentNewCourseSheet: Bool = false
    @Published var apiConfig: ApiConfig = .default
    /// False until `loadConfig()` has read the stored config. `apiConfig` holds
    /// `.default` before that, so saving during this window would overwrite the
    /// user's real settings with defaults.
    private(set) var hasLoadedConfig = false

    /// Setup progress of a local ASR sidecar (dependency install, then model
    /// loading). Non-empty while the engine is still coming up; views show it so
    /// the ~30s startup doesn't look like a hang. Cleared once audio flows.
    @Published var localEngineStatus: String = ""

    /// True while the selected local engine's models are being loaded into
    /// memory, so Settings can show progress and the record button can explain
    /// the wait instead of appearing to do nothing.
    @Published var isLocalEnginePreloading = false
    /// True once a sidecar for the current engine + language is warm and a
    /// recording can start immediately.
    @Published var isLocalEngineReady = false
    @Published var lastError: String? = nil
    @Published var translationEnabled: Bool = true
    @Published var sttBackend: SttBackend = .openAICompatible
    @Published var translationBackend: TranslationBackend = .openAICompatible
    /// Which engine writes notes, answers questions and explains highlights.
    @Published var llmBackend: LLMBackend = .openAICompatible
    @Published var interruptedSessions: [Session] = []
    @Published var microphoneDevices: [MicrophoneInputDevice] = []
    @AppStorage("preferredMicrophoneDeviceID", store: AppEnvironment.defaults) var preferredMicrophoneDeviceID: String = MicrophoneInputDevice.systemDefaultID
    @Published private var importOrchestrators: [String: SessionOrchestrator] = [:]
    /// Task Center ids for the running imports/re-transcriptions, keyed the same
    /// way, so the live window's own Cancel button can mark the task cancelled
    /// instead of leaving it running forever.
    private var importTaskIds: [String: String] = [:]
    /// A settings change that arrived mid-recording, applied once the recording
    /// ends. Retiring the warm pool while the live pipeline streams through it
    /// kills that recording's transcription for good.
    private var needsEngineReloadAfterRecording = false
    @Published var diagnosticReport: [DiagnosticCheck] = []

    /// Bumped whenever the user changes the language. Views observe this to
    /// re-render all L10n strings without needing an app restart.
    @Published var languageRefreshToken: UUID = UUID()

    let orchestrator: SessionOrchestrator
    let taskCenter = TaskCenter()

    private init() {
        self.orchestrator = SessionOrchestrator()
    }

    func bootstrap() async {
        await loadConfig()
        await cleanupOrphanedRecordings()
        refreshMicrophoneDevices()
        await refreshInterruptedSessions()
        // Warm the local engine last, and without awaiting it: loading models
        // takes ~30s and must not delay the rest of startup.
        Task { await preloadLocalEngine() }
    }

    func loadConfig() async {
        if let cfg = try? await ApiConfigRepository.shared.load() {
            // Assign the backend pickers first, then the config. Both are
            // @Published and views observe them with onChange, so setting them
            // while hasLoadedConfig is still false keeps those handlers from
            // saving a half-applied state.
            self.apiConfig = cfg
            let backend = SttBackend.resolve(cfg.sttBackend)
            self.sttBackend = backend
            self.translationBackend = TranslationBackend(rawValue: cfg.translationBackend) ?? .openAICompatible
            self.llmBackend = LLMBackend(rawValue: cfg.llmBackend) ?? .openAICompatible
            if cfg.sttBackend != backend.rawValue {
                // Persist the fold, or the stored string stays unreadable
                // forever and Settings fires a spurious save the first time it
                // opens. saveConfig() short-circuits while hasLoadedConfig is
                // false, so this has to go through the repository directly.
                var migrated = cfg
                migrated.sttBackend = backend.rawValue
                self.apiConfig = migrated
                try? await ApiConfigRepository.shared.save(migrated)
            }
        }
        hasLoadedConfig = true
    }

    /// Loads the selected local engine's models into memory ahead of recording.
    ///
    /// Only warms an already-installed environment: a first-run install
    /// downloads ~1 GB, which should be an explicit choice in Settings rather
    /// than something the app starts on its own at launch.
    func preloadLocalEngine() async {
        guard sttBackend.isLocalSidecar else {
            isLocalEngineReady = false
            return
        }
        let engine: LocalASREngineKind = sttBackend == .funasr ? .funasr : .nemotron
        guard LocalASREnvironment.shared.isReady(engine: engine) else {
            isLocalEngineReady = false
            return
        }
        let language = apiConfig.sourceLanguage
        if await LocalASRWarmPool.shared.isReady(engine: engine, language: language) {
            isLocalEngineReady = true
            return
        }

        isLocalEnginePreloading = true
        isLocalEngineReady = false
        await LocalASRWarmPool.shared.preload(engine: engine, language: language) { stage in
            Task { @MainActor in AppState.shared.localEngineStatus = stage }
        }
        isLocalEnginePreloading = false
        isLocalEngineReady = await LocalASRWarmPool.shared.isReady(engine: engine,
                                                                  language: language)
        if isLocalEngineReady {
            localEngineStatus = ""
        }
    }

    /// Retires a warm sidecar whose models no longer match the settings, then
    /// warms the new configuration.
    func reloadLocalEngine() async {
        guard !isRecording else {
            needsEngineReloadAfterRecording = true
            return
        }
        _ = await LocalASRWarmPool.shared.retire()
        isLocalEngineReady = false
        await preloadLocalEngine()
    }

    func cleanupOrphanedRecordings() async {
        do {
            _ = try await SessionRepository.shared.cleanupOrphanedRecordings()
        } catch {
            NSLog("[ClassNote] Orphan recording cleanup failed: \(error)")
        }
    }

    func saveConfig(_ cfg: ApiConfig) async {
        // Ignore saves triggered before the stored config has been read (SwiftUI
        // onChange handlers can fire during startup). Persisting then would
        // write the placeholder `.default` over real settings.
        guard hasLoadedConfig else {
            NSLog("[ClassNote] Ignoring config save before initial load completed")
            return
        }
        do {
            try await ApiConfigRepository.shared.save(cfg)
            self.apiConfig = try await ApiConfigRepository.shared.load()
            self.sttBackend = SttBackend.resolve(self.apiConfig.sttBackend)
            self.translationBackend = TranslationBackend(rawValue: self.apiConfig.translationBackend) ?? .openAICompatible
            self.llmBackend = LLMBackend(rawValue: self.apiConfig.llmBackend) ?? .openAICompatible
        } catch is CancellationError {
            // `ApiConfigRepository.save` runs its write in an unstructured task,
            // so the settings have landed; only the read-back above is
            // cancellable, and `SettingsView`'s debounced autosave task is
            // cancelled on the next keystroke. Nothing failed — the next save
            // refreshes the mirrored fields.
        } catch {
            setError("Save settings failed: \(error.localizedDescription)")
        }
    }

    func refreshMicrophoneDevices() {
        microphoneDevices = MicrophoneDeviceCatalog.availableInputDevices()
        if selectedMicrophoneUniqueID != nil,
           !microphoneDevices.contains(where: { $0.id == preferredMicrophoneDeviceID }) {
            preferredMicrophoneDeviceID = MicrophoneInputDevice.systemDefaultID
        }
    }

    var selectedMicrophoneUniqueID: String? {
        preferredMicrophoneDeviceID == MicrophoneInputDevice.systemDefaultID ? nil : preferredMicrophoneDeviceID
    }

    var selectedMicrophoneName: String {
        microphoneDevices.first { $0.id == preferredMicrophoneDeviceID }?.name
        ?? MicrophoneDeviceCatalog.name(for: selectedMicrophoneUniqueID)
    }

    func refreshInterruptedSessions() async {
        interruptedSessions = await RecoveryCoordinator.scanInterruptedSessions()
    }

    func recoverInterruptedSession(_ session: Session) async {
        do {
            try await RecoveryCoordinator.recover(session)
            await refreshInterruptedSessions()
        } catch {
            setError(error.localizedDescription)
        }
    }

    func dismissInterruptedSession(_ session: Session) async {
        do {
            try await RecoveryCoordinator.dismiss(session)
            await refreshInterruptedSessions()
        } catch {
            setError(error.localizedDescription)
        }
    }

    func startNewSession(source: AudioSourceKind = .microphone,
                         translationEnabled: Bool? = nil) {
        Task { @MainActor in
            do {
                if let translationEnabled {
                    self.translationEnabled = translationEnabled
                }
                await Self.freeMemoryForRecording()
                let sessionId = try await orchestrator.startNewSession(courseId: nil, source: source)
                self.currentSessionId = sessionId
                self.isRecording = true
                NotificationCenter.default.post(name: .openLiveSession, object: Self.liveWindowId)
            } catch {
                self.setError(error.localizedDescription)
                self.isRecording = false
            }
        }
    }

    /// Window id every live recording reuses.
    ///
    /// Recordings all share `self.orchestrator`, so opening one window per
    /// session id gained nothing and cost a lot: `openWindow(id:value:)` only
    /// reuses a window when the value matches, so each new recording stacked
    /// another identical window on screen. Imports keep their own per-session id
    /// because each one really does get its own orchestrator.
    static let liveWindowId = "live"

    /// Frees the notes/Q&A model before capture starts. ASR, translation and
    /// notes are three separate MLX sidecars, and all three resident at once is
    /// more memory than a 16 GB machine has; the long-form one is the only one
    /// nobody is waiting on during a lecture.
    private static func freeMemoryForRecording() async {
        #if os(macOS)
        await LocalMLXLLMProcess.shared.shutdown()
        #endif
    }

    /// The orchestrator a window should bind to, or nil once that window's work
    /// is over.
    ///
    /// The live orchestrator is only a fallback for the live window. An
    /// import's entry is dropped the moment it finishes, and a window that
    /// re-resolved to the shared orchestrator would start showing the live
    /// recording's transcript — with a Stop button that kills it.
    func orchestrator(for windowId: String) -> SessionOrchestrator? {
        if let worker = importOrchestrators[windowId] { return worker }
        return windowId == Self.liveWindowId ? orchestrator : nil
    }

    func startNewSession(courseId: String?,
                         source: AudioSourceKind,
                         translationEnabled: Bool? = nil) async -> String? {
        do {
            if let translationEnabled {
                self.translationEnabled = translationEnabled
            }
            await Self.freeMemoryForRecording()
            let sessionId = try await orchestrator.startNewSession(courseId: courseId, source: source)
            self.currentSessionId = sessionId
            self.isRecording = true
            NotificationCenter.default.post(name: .openLiveSession, object: Self.liveWindowId)
            return sessionId
        } catch {
            self.setError(error.localizedDescription)
            self.isRecording = false
            return nil
        }
    }

    func startEphemeralTranslation(source: AudioSourceKind = .microphone) {
        Task { @MainActor in
            do {
                self.translationEnabled = true
                _ = try await orchestrator.startEphemeralTranslation(source: source)
                self.currentSessionId = nil
                self.isRecording = true
                NotificationCenter.default.post(name: .openLiveSession, object: Self.liveWindowId)
            } catch {
                self.setError(error.localizedDescription)
                self.isRecording = false
            }
        }
    }

    func startEphemeralTranslation(source: AudioSourceKind) async -> Bool {
        do {
            self.translationEnabled = true
            _ = try await orchestrator.startEphemeralTranslation(source: source)
            self.currentSessionId = nil
            self.isRecording = true
            NotificationCenter.default.post(name: .openLiveSession, object: Self.liveWindowId)
            return true
        } catch {
            self.setError(error.localizedDescription)
            self.isRecording = false
            return false
        }
    }

    func stopRecording() {
        Task { @MainActor in
            await orchestrator.stop()
            self.isRecording = false
            self.currentSessionId = nil
            if self.needsEngineReloadAfterRecording {
                self.needsEngineReloadAfterRecording = false
                await self.reloadLocalEngine()
            }
        }
    }

    /// Shorter than the interactive default: the whole quit — the live stop,
    /// every import's stop, then the three sidecars — has to finish inside the
    /// `applicationShouldTerminate` backstop, or the reply fires first and the
    /// session row is left `recording` with no `ended_at`, which is the very
    /// failure this path exists to prevent.
    private static let terminationDrainTimeout: Duration = .seconds(2)

    /// Finalises everything that must not be left half-written when the app
    /// quits: the live recording's .m4a and session row, any running import,
    /// then the sidecars. Every step is guarded, so calling it twice is safe.
    func prepareForTermination() async {
        if isRecording || orchestrator.currentSessionId != nil || orchestrator.isEphemeralTranslation {
            await orchestrator.stop(drainTimeout: Self.terminationDrainTimeout)
            isRecording = false
            currentSessionId = nil
        }
        let workers = Array(importOrchestrators.values)
        importOrchestrators.removeAll()
        for worker in workers {
            await worker.stop(drainTimeout: Self.terminationDrainTimeout)
        }
        // force: a deferred retire would orphan a ~2 GB sidecar holding its
        // port when the app quits mid-recording.
        #if os(macOS)
        async let asr: Bool = LocalASRWarmPool.shared.retire(force: true)
        async let translator: Void = LocalMLXTranslatorProcess.shared.shutdown()
        async let llm: Void = LocalMLXLLMProcess.shared.shutdown()
        _ = await (asr, translator, llm)
        #else
        _ = await LocalASRWarmPool.shared.retire(force: true)
        #endif
    }

    func importFile(url: URL,
                    courseId: String?,
                    parentTaskId: String? = nil,
                    countLabel: String? = nil,
                    onWorkerReady: ((SessionOrchestrator) -> Void)? = nil) async -> String? {
        var importOrchestrator: SessionOrchestrator?
        let taskId = taskCenter.start(title: L10n.t("task.import.title"),
                                      detail: countLabel.map { "\($0) · \(url.lastPathComponent)" } ?? url.lastPathComponent,
                                      icon: "square.and.arrow.down",
                                      progress: 0)
        taskCenter.configureActions(id: taskId,
                                    retry: { [weak self] in
                                        _ = await self?.importFile(url: url, courseId: courseId)
                                    },
                                    cancel: { [weak self] in
                                        await importOrchestrator?.stop()
                                        self?.taskCenter.cancel(id: taskId, detail: L10n.t("task.import.cancelled"))
                                    })
        // Registered under the session id below; dropped however this ends, or
        // every import in the app's lifetime keeps its orchestrator alive.
        var registeredSessionId: String?
        defer {
            if let registeredSessionId {
                importOrchestrators[registeredSessionId] = nil
                importTaskIds[registeredSessionId] = nil
            }
        }
        do {
            let worker = SessionOrchestrator()
            importOrchestrator = worker
            onWorkerReady?(worker)
            let sessionId = try await worker.ingestFile(url: url, courseId: courseId)
            taskCenter.configureActions(id: taskId,
                                        retry: { [weak self] in
                                            _ = await self?.importFile(url: url, courseId: courseId)
                                        },
                                        cancel: { [weak self, weak worker] in
                                            await worker?.stop()
                                            self?.taskCenter.cancel(id: taskId, detail: L10n.t("task.import.cancelled"))
                                        })
            importOrchestrators[sessionId] = worker
            importTaskIds[sessionId] = taskId
            registeredSessionId = sessionId
            // Imports keep a per-session window id: each has its own orchestrator,
            // and several can run at once. Only live recordings share one window.
            NotificationCenter.default.post(name: .openLiveSession, object: sessionId)
            while worker.isImporting {
                taskCenter.update(id: taskId,
                                  detail: countLabel.map { "\($0) · \(worker.statusText)" } ?? worker.statusText,
                                  progress: worker.importProgress)
                if let parentTaskId {
                    taskCenter.update(id: parentTaskId,
                                      detail: countLabel ?? url.lastPathComponent,
                                      progress: nil)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            try await worker.waitForImportToFinish()
            taskCenter.succeed(id: taskId, detail: L10n.t("task.import.done"))
            return sessionId
        } catch is CancellationError {
            taskCenter.cancel(id: taskId, detail: L10n.t("task.import.cancelled"))
            return nil
        } catch {
            taskCenter.fail(id: taskId, detail: url.lastPathComponent, error: error)
            setError(error.localizedDescription)
            return nil
        }
    }

    func importFiles(urls: [URL], courseId: String?) async {
        guard !urls.isEmpty else { return }
        var cancelled = false
        var currentImport: SessionOrchestrator?
        let taskId = taskCenter.start(title: L10n.t("task.batchImport.title"),
                                      detail: "\(urls.count)",
                                      icon: "tray.and.arrow.down",
                                      progress: 0)
        taskCenter.configureActions(id: taskId,
                                    retry: { [weak self] in
                                        await self?.importFiles(urls: urls, courseId: courseId)
                                    },
                                    cancel: { [weak self] in
                                        cancelled = true
                                        await currentImport?.stop()
                                        self?.taskCenter.cancel(id: taskId, detail: L10n.t("task.status.cancelled"))
                                    })
        var completed = 0
        for url in urls {
            if cancelled { break }
            let label = "\(completed + 1)/\(urls.count)"
            let result = await importFile(url: url,
                                          courseId: courseId,
                                          parentTaskId: taskId,
                                          countLabel: label,
                                          onWorkerReady: { currentImport = $0 })
            currentImport = nil
            if cancelled { break }
            if result == nil {
                taskCenter.fail(id: taskId,
                                detail: "\(completed)/\(urls.count)",
                                message: L10n.t("task.batchImport.partialFailure"))
                return
            }
            completed += 1
            taskCenter.update(id: taskId,
                              detail: "\(completed)/\(urls.count)",
                              progress: Double(completed) / Double(max(urls.count, 1)))
        }
        if cancelled {
            taskCenter.cancel(id: taskId, detail: "\(completed)/\(urls.count)")
        } else {
            taskCenter.succeed(id: taskId, detail: "\(completed)/\(urls.count)")
        }
    }

    func stopImport(windowId: String) async {
        guard let importOrchestrator = importOrchestrators[windowId] else { return }
        await importOrchestrator.stop()
        // The live window's own Cancel button bypasses the Task Center's cancel
        // action, so say it here; `.cancelled` is sticky, so a later success
        // report from the import's own path cannot overwrite it.
        if let taskId = importTaskIds[windowId] {
            taskCenter.cancel(id: taskId, detail: L10n.t("task.import.cancelled"))
        }
    }

    /// Re-transcribes a session from its own recording, on its own orchestrator
    /// so a live recording is never stomped. Same Task Center shape as an import.
    func retranscribe(session: Session) async {
        let taskId = taskCenter.start(title: L10n.t("task.retranscribe.title"),
                                      detail: session.title,
                                      icon: "arrow.clockwise",
                                      progress: 0)
        let worker = SessionOrchestrator()
        importOrchestrators[session.id] = worker
        importTaskIds[session.id] = taskId
        defer {
            importOrchestrators[session.id] = nil
            importTaskIds[session.id] = nil
        }
        taskCenter.configureActions(id: taskId,
                                    retry: { [weak self] in
                                        await self?.retranscribe(session: session)
                                    },
                                    cancel: { [weak self, weak worker] in
                                        await worker?.stop()
                                        self?.taskCenter.cancel(id: taskId,
                                                                detail: L10n.t("task.status.cancelled"))
                                    })
        do {
            _ = try await worker.retranscribeSession(session)
            NotificationCenter.default.post(name: .openLiveSession, object: session.id)
            while worker.isImporting {
                taskCenter.update(id: taskId, detail: worker.statusText, progress: worker.importProgress)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            try await worker.waitForImportToFinish()
            taskCenter.succeed(id: taskId, detail: L10n.t("task.retranscribe.done"))
        } catch is CancellationError {
            taskCenter.cancel(id: taskId, detail: L10n.t("task.status.cancelled"))
        } catch {
            taskCenter.fail(id: taskId, detail: session.title, error: error)
            setError(error.localizedDescription)
        }
    }

    /// Recovery banner's second action: stamp the interrupted session closed,
    /// then rebuild its transcript from the audio that was captured.

    func saveTemporaryTranslationAsSession(courseId: String? = nil) async -> String? {
        guard orchestrator.isEphemeralTranslation,
              !orchestrator.transcript.segments.isEmpty else { return nil }
        let taskId = taskCenter.start(title: L10n.t("task.saveTemporary.title"),
                                      detail: L10n.t("task.saveTemporary.detail"),
                                      icon: "tray.and.arrow.down",
                                      progress: nil)
        do {
            let saved = Session.new(courseId: courseId,
                                    title: SessionOrchestrator.defaultTitle(),
                                    sourceKind: orchestrator.source.rawValue)
            try await SessionRepository.shared.insert(saved)
            let segments = orchestrator.transcript.segments.map {
                Segment(id: nil,
                        sessionId: saved.id,
                        startMs: $0.startMs,
                        endMs: $0.endMs,
                        speakerId: nil,
                        textOriginal: $0.original,
                        textTranslated: $0.translated,
                        isFinal: $0.isFinal,
                        confidence: 0,
                        version: 1)
            }
            try await SegmentRepository.shared.insertMany(segments)
            let duration = segments.map(\.endMs).max() ?? 0
            try await SessionRepository.shared.setEnded(saved.id,
                                                        endedAt: Int64(Date().timeIntervalSince1970 * 1000),
                                                        durationMs: duration,
                                                        audioPath: nil)
            taskCenter.succeed(id: taskId, detail: saved.title)
            return saved.id
        } catch {
            taskCenter.fail(id: taskId, error: error)
            setError(error.localizedDescription)
            return nil
        }
    }

    func markHighlight(note: String = "") {
        guard !orchestrator.isEphemeralTranslation else { return }
        guard let sid = currentSessionId else { return }
        Task {
            try? await HighlightRepository.shared.mark(sessionId: sid,
                                                        timestampMs: orchestrator.currentTimestampMs,
                                                        note: note)
        }
    }

    func setError(_ message: String) {
        self.lastError = message
    }

    /// True when something the app is configured to use needs a cloud key that
    /// is not stored. Not simply `apiKey.isEmpty`: a fully local setup needs no
    /// key at all, and some presets are keyless.
    var isMissingCloudCredential: Bool {
        apiConfig.isCloudCredentialMissing
            && (sttBackend == .openAICompatible
                || translationBackend == .openAICompatible
                || llmBackend == .openAICompatible)
    }

    /// The same question for the record button: only the engines a recording
    /// actually drives count, so a missing key does not block a local lecture
    /// just because notes would use the cloud.
    var isMissingCloudCredentialForRecording: Bool {
        apiConfig.isCloudCredentialMissing
            && (sttBackend == .openAICompatible
                || (translationEnabled && translationBackend == .openAICompatible))
    }

    /// Switch UI language. Persists choice and re-publishes a token so any
    /// view observing `languageRefreshToken` re-renders with new strings.
    func setLanguage(_ lang: L10n.LanguageOverride) {
        L10n.override = lang
        languageRefreshToken = UUID()
    }

    func runDiagnostics() async {
        let taskId = taskCenter.start(title: L10n.t("diagnostics.title"),
                                      detail: L10n.t("common.loading"),
                                      icon: "stethoscope",
                                      progress: nil)
        var checks: [DiagnosticCheck] = []
        checks.append(.init(name: L10n.t("diagnostics.apiKey"),
                            status: isMissingCloudCredential ? .warning : .ok,
                            detail: isMissingCloudCredential ? L10n.t("diagnostics.apiKey.missing") : L10n.t("diagnostics.ok")))
        checks.append(.init(name: L10n.t("diagnostics.database"),
                            status: Database.shared.dbPool == nil ? .failed : .ok,
                            detail: Database.shared.dbPool == nil ? L10n.t("diagnostics.database.failed") : L10n.t("diagnostics.ok")))
        checks.append(.init(name: L10n.t("diagnostics.microphone"),
                            status: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .ok : .warning,
                            detail: "\(L10n.t("diagnostics.microphone.detail")) \(selectedMicrophoneName)"))
        #if os(macOS)
        checks.append(.init(name: L10n.t("diagnostics.screen"),
                            status: CGPreflightScreenCaptureAccess() ? .ok : .warning,
                            detail: L10n.t("diagnostics.screen.detail")))
        #endif
        diagnosticReport = checks
        taskCenter.succeed(id: taskId, detail: L10n.t("diagnostics.done"))
    }
}

enum DiagnosticStatus: String, Sendable {
    case ok
    case warning
    case failed
}

struct DiagnosticCheck: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let status: DiagnosticStatus
    let detail: String
}

extension Notification.Name {
    static let openLiveSession = Notification.Name("openLiveSession")
    static let toggleOverlay = Notification.Name("toggleOverlay")
    static let requestImportFile = Notification.Name("requestImportFile")
}

enum SttBackend: String, CaseIterable, Identifiable {
    case openAICompatible = "openai"
    case appleSpeech = "apple"
    // Both rawValues now drive the same sherpa-onnx sidecar. They are kept as
    // two cases only so a stored setting from an earlier build still decodes;
    // the language-specific engine split they used to mean is gone.
    case funasr = "funasr"
    case nemotronStreaming = "nemotron"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .openAICompatible: return L10n.t("settings.engines.sttBackend.openai")
        case .appleSpeech: return L10n.t("settings.engines.sttBackend.apple")
        case .funasr, .nemotronStreaming: return L10n.t("settings.engines.sttBackend.local")
        }
    }

    /// What the settings picker offers.
    ///
    /// `.nemotronStreaming` still exists so a stored setting from an earlier
    /// build decodes, but both cases now drive the same sidecar, so listing both
    /// just showed the user two identical "Local MLX" rows. It is decoded, never
    /// offered — `AppState.loadConfig` folds it into `.funasr`.
    static var selectableCases: [SttBackend] {
        allCases.filter { $0 != .nemotronStreaming }
    }

    /// Decodes a stored rawValue, folding values that no longer name a real
    /// backend onto the one they actually ran.
    ///
    /// `"whisperkit"` never had an implementation — it silently used the cloud
    /// engine, which is where the nil-coalescing lands it. Both `loadConfig` and
    /// `saveConfig` go through here: `saveConfig` used to skip the nemotron fold
    /// and so republished a value the picker cannot display.
    static func resolve(_ raw: String) -> SttBackend {
        let backend = SttBackend(rawValue: raw) ?? .openAICompatible
        return backend == .nemotronStreaming ? .funasr : backend
    }

    /// True for backends backed by a local Python WebSocket sidecar process
    /// that may need first-run installation before it can be used.
    var isLocalSidecar: Bool {
        switch self {
        case .funasr, .nemotronStreaming: return true
        case .openAICompatible, .appleSpeech: return false
        }
    }
}

/// Which engine writes notes, answers questions, makes flashcards and explains
/// highlights. Separate from the translation backend: the useful setup is a
/// small local translation model plus a cloud model for the long-form work, or
/// the other way round on a machine with memory to spare.
enum LLMBackend: String, CaseIterable, Identifiable {
    case openAICompatible = "openai"
    case localMLX = "mlx"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .openAICompatible: return L10n.t("settings.engines.llmBackend.openai")
        case .localMLX: return L10n.t("settings.engines.llmBackend.mlx")
        }
    }

    /// True for backends backed by the local Python sidecar, which may need a
    /// first-run install before it can be used.
    var isLocalSidecar: Bool { self == .localMLX }
}

enum TranslationBackend: String, CaseIterable, Identifiable {
    case openAICompatible = "openai"
    case appleTranslation = "apple"
    case localMLX = "mlx"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .openAICompatible: return L10n.t("settings.engines.translationBackend.openai")
        case .appleTranslation: return L10n.t("settings.engines.translationBackend.apple")
        case .localMLX: return L10n.t("settings.engines.translationBackend.mlx")
        }
    }

    /// True for backends backed by the local Python sidecar, which may need a
    /// first-run install before it can be used.
    var isLocalSidecar: Bool { self == .localMLX }
}
