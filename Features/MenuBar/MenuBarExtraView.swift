import SwiftUI

struct MenuBarExtraView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: appState.isRecording ? "record.circle.fill" : "waveform")
                    .foregroundStyle(appState.isRecording ? .red : .primary)
                Text(appState.isRecording ? "Recording — " + (appState.orchestrator.currentSession?.title ?? "…") : "ClassNote")
                    .font(.headline)
            }
            if appState.isRecording {
                Text("Duration: \(formatDuration(appState.orchestrator.currentTimestampMs))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button {
                if appState.isRecording { appState.stopRecording() }
                else { appState.startNewSession(source: .microphone) }
            } label: {
                Label(appState.isRecording ? "Stop session" : "Record · Microphone",
                      systemImage: appState.isRecording ? "stop.circle.fill" : "mic.circle.fill")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            if !appState.isRecording {
                Button {
                    appState.startNewSession(source: .system)
                } label: {
                    Label("Record · System audio", systemImage: "speaker.wave.3.fill")
                }
                Button {
                    appState.startNewSession(source: .mixed)
                } label: {
                    Label("Record · Mic + System", systemImage: "person.wave.2.fill")
                }
            }

            Button {
                NotificationCenter.default.post(name: .toggleOverlay, object: nil)
            } label: {
                Label("Toggle overlay window", systemImage: "rectangle.on.rectangle")
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button {
                appState.markHighlight()
            } label: {
                Label("Mark highlight", systemImage: "star.circle")
            }
            .disabled(!appState.isRecording)
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Toggle(isOn: $appState.translationEnabled) {
                Label("Live translation", systemImage: "character.bubble")
            }

            Divider()

            Button {
                NSApp.activate(ignoringOtherApps: true)
                if let win = NSApp.windows.first(where: { $0.title.contains("ClassNote") || $0.identifier?.rawValue == "main" }) {
                    win.makeKeyAndOrderFront(nil)
                } else {
                    if let url = URL(string: "classnote://open") { NSWorkspace.shared.open(url) }
                }
            } label: {
                Label("Open main window", systemImage: "macwindow")
            }

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])

            Divider()

            Button("Quit ClassNote") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .padding(12)
        .frame(width: 260)
    }

    private func formatDuration(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}
