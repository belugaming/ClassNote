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

    /// Bumped whenever the user changes the language. Views observe this to
    /// re-render all L10n strings without needing an app restart.
    @Published var languageRefreshToken: UUID = UUID()

    let orchestrator: SessionOrchestrator

    private init() {
        self.orchestrator = SessionOrchestrator()
        Task { await loadConfig() }
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

    func stopRecording() {
        Task { @MainActor in
            await orchestrator.stop()
            self.isRecording = false
        }
    }

    func markHighlight(note: String = "") {
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
