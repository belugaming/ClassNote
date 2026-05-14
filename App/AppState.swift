import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isRecording: Bool = false
    @Published var currentSessionId: String? = nil
    @Published var presentNewCourseSheet: Bool = false
    @Published var presentPermissionsSheet: Bool = false
    @Published var apiConfig: ApiConfig = .default
    @Published var lastError: String? = nil
    @Published var translationEnabled: Bool = true
    @Published var sttBackend: SttBackend = .openAICompatible
    @Published var interruptedSessions: [Session] = []
    @Published private var importOrchestrators: [String: SessionOrchestrator] = [:]

    /// Bumped whenever the user changes the language. Views observe this to
    /// re-render all L10n strings without needing an app restart.
    @Published var languageRefreshToken: UUID = UUID()

    let orchestrator: SessionOrchestrator

    private init() {
        self.orchestrator = SessionOrchestrator()
        Task {
            await loadConfig()
            await refreshInterruptedSessions()
        }
    }

    func loadConfig() async {
        if let cfg = try? await ApiConfigRepository.shared.load() {
            self.apiConfig = cfg
            self.sttBackend = SttBackend(rawValue: cfg.sttBackend) ?? .openAICompatible
        }
    }

    func saveConfig(_ cfg: ApiConfig) async {
        try? await ApiConfigRepository.shared.save(cfg)
        self.apiConfig = cfg
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

    func startNewSession(source: AudioSourceKind = .microphone) {
        Task { @MainActor in
            do {
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

    func startNewSession(courseId: String?, source: AudioSourceKind) async -> String? {
        do {
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

    func importFile(url: URL, courseId: String?) async -> String? {
        do {
            let importOrchestrator = SessionOrchestrator()
            let sessionId = try await importOrchestrator.ingestFile(url: url, courseId: courseId)
            importOrchestrators[sessionId] = importOrchestrator
            NotificationCenter.default.post(name: .openLiveSession, object: sessionId)
            return sessionId
        } catch {
            setError(error.localizedDescription)
            return nil
        }
    }

    func stopImport(windowId: String) async {
        guard let importOrchestrator = importOrchestrators[windowId] else { return }
        await importOrchestrator.stop()
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
}

extension Notification.Name {
    static let openLiveSession = Notification.Name("openLiveSession")
    static let toggleOverlay = Notification.Name("toggleOverlay")
    static let requestImportFile = Notification.Name("requestImportFile")
}

enum SttBackend: String, CaseIterable, Identifiable {
    case openAICompatible = "openai"
    case whisperKitLocal = "whisperkit"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI Compatible (Cloud)"
        case .whisperKitLocal: return "WhisperKit (Local, macOS Apple Silicon)"
        }
    }
}
