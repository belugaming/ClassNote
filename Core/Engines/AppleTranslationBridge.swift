import SwiftUI
import Translation

/// `TranslationSession` cannot be instantiated directly pre-macOS 26 — it's
/// only obtainable through the SwiftUI `.translationTask` modifier. This
/// bridge hosts that modifier on an invisible view kept alive for the app's
/// lifetime, and hands the resulting session to whichever caller is waiting
/// for the current source/target language pair.
///
/// On macOS 26+ `TranslationSession(installedSource:target:)` exists and
/// needs no view at all, so `AppleTranslationEngine` prefers that path and
/// only falls back to this bridge on macOS 15-25.
@available(macOS 15.0, *)
@MainActor
final class AppleTranslationBridge: ObservableObject {
    static let shared = AppleTranslationBridge()

    @Published fileprivate var activeConfiguration: TranslationSession.Configuration?

    private var pendingWaiters: [(source: Locale.Language, target: Locale.Language, continuation: CheckedContinuation<TranslationSession, Never>)] = []
    private var currentPair: (source: Locale.Language, target: Locale.Language)?

    private init() {}

    /// Requests a session for the given language pair. Triggers (or reuses)
    /// the hidden view's `.translationTask`. Suspends until that task's
    /// action closure delivers a session for this exact pair.
    func session(source: Locale.Language, target: Locale.Language) async -> TranslationSession {
        if let current = currentPair, current.source == source, current.target == target,
           let existing = latestSession {
            return existing
        }
        return await withCheckedContinuation { continuation in
            pendingWaiters.append((source, target, continuation))
            currentPair = (source, target)
            activeConfiguration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private var latestSession: TranslationSession?

    fileprivate func received(session: TranslationSession) {
        latestSession = session
        guard let pair = currentPair else { return }
        let matching = pendingWaiters.filter { $0.source == pair.source && $0.target == pair.target }
        pendingWaiters.removeAll { $0.source == pair.source && $0.target == pair.target }
        for waiter in matching {
            waiter.continuation.resume(returning: session)
        }
    }
}

@available(macOS 15.0, *)
struct AppleTranslationBridgeView: View {
    @ObservedObject var bridge = AppleTranslationBridge.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(bridge.activeConfiguration) { session in
                bridge.received(session: session)
            }
    }
}
