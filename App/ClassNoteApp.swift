import SwiftUI

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

    // AppKit calls both `Task { @MainActor in ... }` blocks above back into
    // here, and `NSApp.reply(toApplicationShouldTerminate:)` is main-actor only.
    @MainActor
    private func replyOnce() {
        guard !didReply else { return }
        didReply = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

@main
struct ClassNoteApp: App {
    @StateObject private var appState = AppState.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppBootstrap.run()
        WindowRouter.shared.start()
        // The test bundle is hosted by this app, so a bootstrap here would race
        // every test: `loadConfig()` overwrites whatever config a test just set,
        // `refreshMicrophoneDevices()` writes back a preference, and
        // `preloadLocalEngine()` pulls ~650 MB of weights into memory.
        guard !AppEnvironment.isRunningTests else { return }
        DispatchQueue.main.async {
            Task {
                await AppState.shared.bootstrap()
            }
        }
    }

    var body: some Scene {
        WindowGroup(id: WindowRouter.mainWindowId) {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 600)
                .background(translationBridgeView)
                .captureWindowActions()
                .id(appState.languageRefreshToken)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { AppCommands(appState: appState) }

        WindowGroup(id: WindowRouter.liveWindowId, for: String.self) { $sessionId in
            if let id = sessionId {
                LiveSessionView(windowId: id)
                    .environmentObject(appState)
                    .frame(minWidth: 640, minHeight: 460)
                    .background(translationBridgeView)
                    .captureWindowActions()
                    .id(appState.languageRefreshToken)
            }
        }
        .defaultSize(width: 920, height: 640)
        .defaultPosition(.center)

        Window(L10n.t("overlay.windowTitle"), id: WindowRouter.overlayWindowId) {
            OverlayView()
                .environmentObject(appState)
                .frame(minWidth: 420, minHeight: 160)
                .id(appState.languageRefreshToken)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 580, height: 240)
        .defaultPosition(.topTrailing)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        MenuBarExtra {
            MenuBarExtraView()
                .environmentObject(appState)
                .captureWindowActions()
        } label: {
            // The label is the one view that exists for the whole life of the
            // app, so it is where window actions are captured for a start
            // from the menu bar or a shortcut with every window closed.
            MenuBarLabel(isRecording: appState.isRecording)
                .captureWindowActions()
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var translationBridgeView: some View {
        if #available(macOS 15.0, *) {
            AppleTranslationBridgeView()
        } else {
            EmptyView()
        }
    }
}

private struct MenuBarLabel: View {
    let isRecording: Bool

    var body: some View {
        Image(systemName: isRecording ? "record.circle.fill" : "waveform")
    }
}

/// Menu commands. Recording goes through the launcher, so ⌘N uses the same
/// source and mode as the toolbar and never silently ends a running
/// recording to start another.
private struct AppCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(appState.isRecording ? L10n.t("record.stop") : L10n.t("record.start")) {
                RecordingLauncher.toggle(appState)
            }
            .keyboardShortcut("n", modifiers: .command)
            Button(L10n.t("main.newCourse")) { appState.presentNewCourseSheet = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button(L10n.t("toolbar.import")) {
                WindowRouter.shared.openMain()
                NotificationCenter.default.post(name: .requestImportFile, object: nil)
            }
            .keyboardShortcut("i", modifiers: .command)
        }
        CommandMenu(L10n.t("menu.recording")) {
            Button(L10n.t("live.highlight")) { appState.markHighlight() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!appState.isRecording)
            Button(L10n.t("menubar.toggleOverlay")) { WindowRouter.shared.toggleOverlay() }
                .keyboardShortcut("o", modifiers: [.command, .option])
        }
    }
}
