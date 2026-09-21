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
@available(macOS 15.0, iOS 18.0, *)
@MainActor
final class AppleTranslationBridge: ObservableObject {
    static let shared = AppleTranslationBridge()

    @Published fileprivate var activeConfiguration: TranslationSession.Configuration?

    private var pendingWaiters: [(source: Locale.Language, target: Locale.Language, continuation: CheckedContinuation<TranslationSessionBox, Never>)] = []
    private var currentPair: (source: Locale.Language, target: Locale.Language)?

    private init() {}

    /// Requests a session for the given language pair. Triggers (or reuses)
    /// the hidden view's `.translationTask`. Suspends until that task's
    /// action closure delivers a session for this exact pair.
    func session(source: Locale.Language, target: Locale.Language) async -> TranslationSessionBox {
        if let current = currentPair, current.source == source, current.target == target,
           let existing = latestSession {
            return TranslationSessionBox(session: existing)
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
            waiter.continuation.resume(returning: TranslationSessionBox(session: session))
        }
    }
}

/// Carries a `TranslationSession` across the two boundaries it has to cross:
/// the `CheckedContinuation` above, and the hop from the main actor back to the
/// task that asked for a translation. Both require a `Sendable` value.
///
/// `@unchecked` here is an accepted hand-over, not a claim of thread safety:
/// `TranslationSession` has no `Sendable` conformance, yet the only way to get
/// one is on the main actor and the only things to do with it are nonisolated
/// `async` calls, so the crossing is unavoidable. The box keeps it in one named
/// place instead of at every call site; the session itself is used exactly
/// where it was before the box existed — in the task that requested it.
@available(macOS 15.0, iOS 18.0, *)
struct TranslationSessionBox: @unchecked Sendable {
    let session: TranslationSession
}

@available(macOS 15.0, iOS 18.0, *)
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
