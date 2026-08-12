import SwiftUI

#if os(macOS)
/// Shuts the warm ASR sidecar down on quit.
///
/// The sidecar now outlives individual recordings so its models stay in memory,
/// which means nothing else would reap it: an orphan would keep several GB
/// resident and hold its port.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Terminating is synchronous, so block briefly rather than leaving the
        // teardown to a task that never gets scheduled.
        let done = DispatchSemaphore(value: 0)
        Task {
            await LocalASRWarmPool.shared.retire()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
    }
}
#endif

@main
struct ClassNoteApp: App {
    @StateObject private var appState = AppState.shared
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        AppBootstrap.run()
        DispatchQueue.main.async {
            Task {
                await AppState.shared.bootstrap()
            }
        }
    }

    var body: some Scene {
        #if os(macOS)
        macOSScenes
        #else
        iOSScenes
        #endif
    }

    #if os(macOS)
    @SceneBuilder
    private var macOSScenes: some Scene {
        WindowGroup(id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 640)
                .background(LiveSessionOpener().environmentObject(appState))
                .background(translationBridgeView)
                .id(appState.languageRefreshToken)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Course") { appState.presentNewCourseSheet = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Session") { appState.startNewSession() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check Permissions…") { appState.presentPermissionsSheet = true }
            }
        }

        WindowGroup(id: "live-session", for: String.self) { $sessionId in
            if let id = sessionId {
                LiveSessionView(sessionId: id)
                    .environmentObject(appState)
                    .frame(minWidth: 720, minHeight: 520)
                    .id(appState.languageRefreshToken)
            }
        }
        .defaultSize(width: 900, height: 600)
        .defaultPosition(.center)

        Window("Overlay", id: "overlay") {
            OverlayView()
                .environmentObject(appState)
                .frame(minWidth: 420, minHeight: 180)
                .id(appState.languageRefreshToken)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 260)
        .defaultPosition(.topTrailing)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        .defaultSize(width: 720, height: 560)

        MenuBarExtra {
            MenuBarExtraView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isRecording ? "record.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
    #else
    /// iOS/iPadOS has no independent windows, menu bar, or global shortcuts.
    /// Everything lives in one WindowGroup; live session and settings are
    /// presented as a full-screen cover / sheet from `MainWindowView`.
    @SceneBuilder
    private var iOSScenes: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appState)
                .background(translationBridgeView)
                .id(appState.languageRefreshToken)
        }
    }
    #endif

    @ViewBuilder
    private var translationBridgeView: some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            AppleTranslationBridgeView()
        } else {
            EmptyView()
        }
    }
}

#if os(macOS)
/// Hidden helper view that listens for the `openLiveSession` notification and uses
/// the environment's openWindow to pop the live session window.
private struct LiveSessionOpener: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var overlayOpen = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .openLiveSession)) { note in
                if let sid = note.object as? String {
                    openWindow(id: "live-session", value: sid)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleOverlay)) { _ in
                if overlayOpen {
                    dismissWindow(id: "overlay")
                    overlayOpen = false
                } else {
                    openWindow(id: "overlay")
                    overlayOpen = true
                }
            }
    }
}
#endif
