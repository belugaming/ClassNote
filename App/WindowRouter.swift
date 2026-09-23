import SwiftUI

/// Opens and closes the app's windows from anywhere: the orchestrator, the
/// menu bar, a global shortcut.
///
/// SwiftUI only hands out `openWindow` inside a view, and the old opener lived
/// in the main window's background, so with the main window closed a
/// recording started from the menu bar or a shortcut never showed its live
/// window. Every window (and the always-present menu bar label) now registers
/// its actions here, and the router listens for the app's notifications.
@MainActor
final class WindowRouter: ObservableObject {
    static let shared = WindowRouter()

    static let mainWindowId = "main"
    static let liveWindowId = "live-session"
    static let overlayWindowId = "overlay"

    private var openWindow: OpenWindowAction?
    private var dismissWindow: DismissWindowAction?
    private var observers: [NSObjectProtocol] = []

    /// Tracked by the overlay itself, so a toggle is right however it was
    /// closed last time.
    @Published var isOverlayVisible = false

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .openLiveSession, object: nil, queue: .main) { note in
            let id = note.object as? String
            MainActor.assumeIsolated {
                if let id { WindowRouter.shared.openLive(windowId: id) }
            }
        })
        observers.append(center.addObserver(forName: .toggleOverlay, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WindowRouter.shared.toggleOverlay() }
        })
    }

    func register(open: OpenWindowAction, dismiss: DismissWindowAction) {
        openWindow = open
        dismissWindow = dismiss
    }

    func openLive(windowId: String) {
        openWindow?(id: Self.liveWindowId, value: windowId)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openMain() {
        openWindow?(id: Self.mainWindowId)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleOverlay() {
        if isOverlayVisible {
            dismissWindow?(id: Self.overlayWindowId)
            isOverlayVisible = false
        } else {
            openWindow?(id: Self.overlayWindowId)
            isOverlayVisible = true
        }
    }
}

private struct CaptureWindowActions: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear {
            WindowRouter.shared.register(open: openWindow, dismiss: dismissWindow)
        }
    }
}

extension View {
    /// Registers this scene's window actions with `WindowRouter`.
    func captureWindowActions() -> some View {
        modifier(CaptureWindowActions())
    }
}
