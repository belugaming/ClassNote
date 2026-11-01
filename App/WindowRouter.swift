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
    /// Registered by the main window's view. The main scene is a
    /// `WindowGroup`, whose `openWindow` always makes another window, so the
    /// router brings this one forward instead.
    private weak var mainWindow: NSWindow?

    /// Whether the main window is open and not minimized, so its alert can
    /// be seen.
    var isMainWindowOnScreen: Bool {
        guard let mainWindow, !NSApp.isHidden else { return false }
        return mainWindow.isVisible && !mainWindow.isMiniaturized
    }

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

    /// Brings the main window forward, and opens one only when there is none.
    func openMain() {
        // A hidden app's windows read as not visible, which would open a second.
        if NSApp.isHidden { NSApp.unhide(nil) }
        if let mainWindow, mainWindow.isVisible || mainWindow.isMiniaturized {
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: Self.mainWindowId)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    fileprivate func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
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

/// Hands the window it lands in to `WindowRouter` as the main window.
private struct MainWindowReporter: NSViewRepresentable {
    func makeNSView(context: Context) -> ReporterView { ReporterView() }
    func updateNSView(_ nsView: ReporterView, context: Context) {}

    final class ReporterView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WindowRouter.shared.registerMainWindow(window) }
        }
    }
}

extension View {
    /// Registers this scene's window actions with `WindowRouter`.
    func captureWindowActions() -> some View {
        modifier(CaptureWindowActions())
    }

    /// Marks the window holding this view as the main window for `WindowRouter`.
    func reportsMainWindow() -> some View {
        background(MainWindowReporter())
    }
}
