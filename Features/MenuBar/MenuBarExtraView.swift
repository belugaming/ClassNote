import SwiftUI

struct MenuBarExtraView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        InnerMenuBarView(appState: appState,
                         orchestrator: appState.orchestrator,
                         openSettings: openSettings)
    }
}

private struct InnerMenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var orchestrator: SessionOrchestrator
    let openSettings: OpenSettingsAction

    private let launcher = RecordingLauncher()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            status

            Divider()

            // One primary action driven by the pickers below, instead of the
            // seven fixed source/mode combinations this menu used to list.
            Button {
                launcher.toggle(appState)
            } label: {
                Label(appState.isRecording ? L10n.t("record.stop") : L10n.t("record.start"),
                      systemImage: appState.isRecording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(appState.isRecording ? Theme.recording : Theme.accent)
            .foregroundStyle(appState.isRecording ? Color.white : Theme.onAccent)

            if !appState.isRecording {
                RecordingOptionsView(source: sourceBinding,
                                     intent: intentBinding,
                                     translationEnabled: $appState.translationEnabled)
                if launcher.intent == .temporary {
                    Text(L10n.t("record.hint.temporary"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            MenubarRow(label: L10n.t("menubar.markHighlight"),
                       icon: "star",
                       disabled: !appState.isRecording || orchestrator.isEphemeralTranslation) {
                appState.markHighlight()
            }
            MenubarRow(label: L10n.t("menubar.toggleOverlay"), icon: "rectangle.on.rectangle") {
                NotificationCenter.default.post(name: .toggleOverlay, object: nil)
            }

            Divider()

            MenubarRow(label: L10n.t("menubar.openMain"), icon: "macwindow") {
                NSApp.activate(ignoringOtherApps: true)
                if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                    win.makeKeyAndOrderFront(nil)
                }
            }
            // openSettings env value is the macOS 14+ way to launch the Settings
            // scene from menu bar extras without the deprecated
            // showSettingsWindow: action.
            MenubarRow(label: L10n.t("menubar.settings"), icon: "gearshape") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            MenubarRow(label: L10n.t("menubar.quit"), icon: "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var status: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(appState.isRecording ? Theme.recording.opacity(0.16) : Theme.accentSoft)
                    .frame(width: 34, height: 34)
                Image(systemName: appState.isRecording ? "record.circle.fill" : "waveform")
                    .foregroundStyle(appState.isRecording ? Theme.recording : Theme.accent)
                    .font(.title3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.isRecording ? activeTitle : L10n.t("menubar.idle"))
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        if appState.isRecording {
            return "\(formatDuration(orchestrator.currentTimestampMs)) · \(launcher.source.shortTitle)"
        }
        return appState.selectedMicrophoneName
    }

    private var activeTitle: String {
        if orchestrator.isEphemeralTranslation {
            return L10n.t("live.ephemeral.title")
        }
        return orchestrator.currentSession?.title ?? L10n.t("menubar.recording")
    }

    private var sourceBinding: Binding<AudioSourceKind> {
        Binding(get: { launcher.source }, set: { launcher.source = $0 })
    }

    private var intentBinding: Binding<RecordingIntent> {
        Binding(get: { launcher.intent }, set: { launcher.intent = $0 })
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

/// Plain menu row. Deliberately monochrome: `Theme` documents a single-accent,
/// no-color-coded-chrome design language, which the previous per-item .blue /
/// .purple / .yellow tints ignored.
private struct MenubarRow: View {
    let label: String
    let icon: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                Text(label)
                Spacer()
            }
            .foregroundStyle(disabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                    .fill(hovering && !disabled ? Theme.chrome : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}
