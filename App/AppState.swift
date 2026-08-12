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
    @Published var presentNewCourseSheet: Bool = false
    @Published var presentPermissionsSheet: Bool = false
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
    @Published var interruptedSessions: [Session] = []
    @Published var microphoneDevices: [MicrophoneInputDevice] = []
    @AppStorage("preferredMicrophoneDeviceID") var preferredMicrophoneDeviceID: String = MicrophoneInputDevice.systemDefaultID
    @Published private var importOrchestrators: [String: SessionOrchestrator] = [:]
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
            self.sttBackend = SttBackend(rawValue: cfg.sttBackend) ?? .openAICompatible
            self.translationBackend = TranslationBackend(rawValue: cfg.translationBackend) ?? .openAICompatible
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
        await LocalASRWarmPool.shared.retire()
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
            self.sttBackend = SttBackend(rawValue: self.apiConfig.sttBackend) ?? .openAICompatible
            self.translationBackend = TranslationBackend(rawValue: self.apiConfig.translationBackend) ?? .openAICompatible
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
                let sessionId = try await orchestrator.startNewSession(courseId: nil, source: source)
                self.currentSessionId = sessionId
                self.isRecording = true
                NotificationCenter.default.post(name: .openLiveSession, object: sessionId)
            } catch {
                self.setError(error.localizedDescription)
                self.isRecording = false
            }
        }
    }

    func orchestrator(for windowId: String) -> SessionOrchestrator {
        importOrchestrators[windowId] ?? orchestrator
    }

    func startNewSession(courseId: String?,
                         source: AudioSourceKind,
                         translationEnabled: Bool? = nil) async -> String? {
        do {
            if let translationEnabled {
                self.translationEnabled = translationEnabled
            }
            let sessionId = try await orchestrator.startNewSession(courseId: courseId, source: source)
            self.currentSessionId = sessionId
            self.isRecording = true
            NotificationCenter.default.post(name: .openLiveSession, object: sessionId)
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
                let windowId = try await orchestrator.startEphemeralTranslation(source: source)
                self.currentSessionId = nil
                self.isRecording = true
                NotificationCenter.default.post(name: .openLiveSession, object: windowId)
            } catch {
                self.setError(error.localizedDescription)
                self.isRecording = false
            }
        }
    }

    func startEphemeralTranslation(source: AudioSourceKind) async -> Bool {
        do {
            self.translationEnabled = true
            let windowId = try await orchestrator.startEphemeralTranslation(source: source)
            self.currentSessionId = nil
            self.isRecording = true
            NotificationCenter.default.post(name: .openLiveSession, object: windowId)
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
        }
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
    }

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
                            status: apiConfig.apiKey.isEmpty && sttBackend == .openAICompatible ? .warning : .ok,
                            detail: apiConfig.apiKey.isEmpty ? L10n.t("diagnostics.apiKey.missing") : L10n.t("diagnostics.ok")))
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
    case whisperKitLocal = "whisperkit"
    case appleSpeech = "apple"
    case funasr = "funasr"
    case nemotronStreaming = "nemotron"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI Compatible (Cloud)"
        case .whisperKitLocal: return "WhisperKit (Local, macOS Apple Silicon)"
        case .appleSpeech: return L10n.t("settings.engines.sttBackend.apple")
        case .funasr: return "FunASR (Local, 2-Pass)"
        case .nemotronStreaming: return "Nemotron Streaming (Local, English)"
        }
    }

    /// True for backends backed by a local Python WebSocket sidecar process
    /// that may need first-run installation before it can be used.
    var isLocalSidecar: Bool {
        switch self {
        case .funasr, .nemotronStreaming: return true
        case .openAICompatible, .whisperKitLocal, .appleSpeech: return false
        }
    }
}

enum TranslationBackend: String, CaseIterable, Identifiable {
    case openAICompatible = "openai"
    case appleTranslation = "apple"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .openAICompatible: return L10n.t("settings.engines.translationBackend.openai")
        case .appleTranslation: return L10n.t("settings.engines.translationBackend.apple")
        }
    }
}
