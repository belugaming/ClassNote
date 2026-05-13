import SwiftUI

struct MenuBarExtraView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(appState.isRecording ? Theme.recording.opacity(0.18) : Theme.accentSoft)
                        .frame(width: 32, height: 32)
                    Image(systemName: appState.isRecording ? "record.circle.fill" : "waveform")
                        .foregroundStyle(appState.isRecording ? Theme.recording : Theme.accent)
                        .font(.title3)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.isRecording
                         ? (appState.orchestrator.currentSession?.title ?? L10n.t("menubar.recording"))
                         : L10n.t("menubar.idle"))
                        .font(.headline)
                        .lineLimit(1)
                    if appState.isRecording {
                        Text("\(L10n.t("menubar.duration")): \(formatDuration(appState.orchestrator.currentTimestampMs))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.t("app.tagline"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.bottom, 2)

            Divider()

            if appState.isRecording {
                MenubarButton(label: L10n.t("menubar.stopSession"),
                              icon: "stop.circle.fill",
                              tint: Theme.recording) {
                    appState.stopRecording()
                }
            } else {
                MenubarButton(label: L10n.t("menubar.recordMic"),
                              icon: "mic.circle.fill",
                              tint: Theme.accent) {
                    appState.startNewSession(source: .microphone)
                }
                MenubarButton(label: L10n.t("menubar.recordSystem"),
                              icon: "speaker.wave.3.fill",
                              tint: .blue) {
                    appState.startNewSession(source: .system)
                }
                MenubarButton(label: L10n.t("menubar.recordMixed"),
                              icon: "person.wave.2.fill",
                              tint: .purple) {
                    appState.startNewSession(source: .mixed)
                }
            }

            Divider()

            MenubarButton(label: L10n.t("menubar.toggleOverlay"),
                          icon: "rectangle.on.rectangle",
                          tint: .secondary) {
                NotificationCenter.default.post(name: .toggleOverlay, object: nil)
            }
            MenubarButton(label: L10n.t("menubar.markHighlight"),
                          icon: "star.circle",
                          tint: .yellow,
                          disabled: !appState.isRecording) {
                appState.markHighlight()
            }
            Toggle(isOn: $appState.translationEnabled) {
                Label(L10n.t("menubar.liveTranslation"), systemImage: "character.bubble")
            }
            .tint(Theme.accent)
            .padding(.horizontal, 4)

            Divider()

            MenubarButton(label: L10n.t("menubar.openMain"),
                          icon: "macwindow",
                          tint: .secondary) {
                NSApp.activate(ignoringOtherApps: true)
                if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                    win.makeKeyAndOrderFront(nil)
                }
            }
            MenubarButton(label: L10n.t("menubar.settings"),
                          icon: "gearshape",
                          tint: .secondary) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }

            Divider()

            MenubarButton(label: L10n.t("menubar.quit"),
                          icon: "power",
                          tint: .secondary) {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
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

private struct MenubarButton: View {
    let label: String
    let icon: String
    let tint: Color
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundStyle(disabled ? .secondary : tint)
                Text(label)
                    .foregroundStyle(disabled ? .secondary : .primary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
