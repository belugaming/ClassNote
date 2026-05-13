import SwiftUI

@main
struct ClassNoteApp: App {
    @StateObject private var appState = AppState.shared

    init() {
        AppBootstrap.run()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 640)
                .background(LiveSessionOpener().environmentObject(appState))
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
                .frame(minWidth: 320, minHeight: 160)
                .id(appState.languageRefreshToken)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 380, height: 220)
        .defaultPosition(.topTrailing)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 640, height: 520)
        }

        MenuBarExtra {
            MenuBarExtraView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isRecording ? "record.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

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
