import SwiftUI

#if os(macOS)
/// Finishes the recording and shuts the sidecars down on quit.
///
/// `applicationWillTerminate` is the wrong hook for any of that: it is
/// MainActor-isolated, so a `Task` created there is enqueued on the very thread
/// that is about to go away, and waiting for it on that thread deadlocks by
/// construction. AppKit's async-teardown hook is `applicationShouldTerminate`
/// plus `.terminateLater`, which keeps the run loop spinning until we reply.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isTearingDown = false
    private var didReply = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Re-entry (⌘Q again while teardown runs): keep waiting on the reply
        // already in flight rather than cancelling the quit.
        guard !isTearingDown else { return .terminateLater }
        isTearingDown = true

        Task { @MainActor in
            await AppState.shared.prepareForTermination()
            self.replyOnce()
        }
        // Backstop: a wedged sidecar must never hold the app hostage. It has to
        // sit above the graceful path's own budget, not under it — the live
        // stop drains its engines, then every import stops, then three sidecars
        // shut down. Replying early would abort exactly the `setEnded` write
        // that `.terminateLater` was taken for. `.terminateLater` keeps the run
        // loop spinning, so the wait is not a beachball.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            self.replyOnce()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Belt and braces for whatever the graceful path did not reach (the
        // backstop firing, or a quit that never went through
        // applicationShouldTerminate). Synchronous on purpose: signalling pids
        // needs no actor hop.
        SidecarRegistry.shared.terminateAll()
    }

    private func replyOnce() {
        guard !didReply else { return }
        didReply = true
        NSApp.reply(toApplicationShouldTerminate: true)
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
                // The flag is answered by CourseSessionSidebarView, which owns
                // the sheet this command is named after.
                Button("New Course") { appState.presentNewCourseSheet = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Session") { appState.startNewSession() }
                    .keyboardShortcut("n", modifiers: .command)
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
