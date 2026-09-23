import SwiftUI

/// The menu bar panel: start and stop, a glance at what is being said, and the
/// way back into the app.
struct MenuBarExtraView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarPanel(appState: appState,
                     orchestrator: appState.orchestrator,
                     prefs: RecordingPreferences.shared,
                     openSettings: openSettings)
    }
}

private struct MenuBarPanel: View {
    @ObservedObject var appState: AppState
    @ObservedObject var orchestrator: SessionOrchestrator
    @ObservedObject var prefs: RecordingPreferences
    @ObservedObject private var router = WindowRouter.shared
    let openSettings: OpenSettingsAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if appState.isRecording {
                recordingSection
            } else {
                idleSection
            }
            Divider()
            VStack(spacing: 2) {
                MenuRow(title: router.isOverlayVisible ? L10n.t("menubar.hideOverlay") : L10n.t("menubar.showOverlay"),
                        icon: "captions.bubble") {
                    router.toggleOverlay()
                }
                MenuRow(title: L10n.t("menubar.openMain"), icon: "macwindow") {
                    router.openMain()
                }
                MenuRow(title: L10n.t("menubar.settings"), icon: "gearshape") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                MenuRow(title: L10n.t("menubar.quit"), icon: "power") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: appState.isRecording ? "record.circle.fill" : "waveform")
                .font(.title2)
                .foregroundStyle(appState.isRecording ? Theme.recording : Theme.accent)
                .symbolEffect(.pulse, isActive: appState.isRecording)
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.isRecording ? activeTitle : L10n.t("app.name"))
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

    private var activeTitle: String {
        if orchestrator.isEphemeralTranslation { return L10n.t("live.ephemeral.title") }
        return orchestrator.currentSession?.title ?? L10n.t("menubar.recording")
    }

    private var subtitle: String {
        if appState.isRecording {
            // What is actually recording, not the remembered preference.
            return "\(TimeLabel.string(ms: orchestrator.currentTimestampMs)) · \(orchestrator.source.shortTitle)"
        }
        if appState.isLocalEnginePreloading {
            return appState.localEngineStatus.isEmpty ? L10n.t("settings.engines.loading") : appState.localEngineStatus
        }
        return appState.selectedMicrophoneName
    }

    @ViewBuilder
    private var recordingSection: some View {
        if let block = orchestrator.transcript.segments.sentenceBlocks.last {
            VStack(alignment: .leading, spacing: 4) {
                Text(SentenceGroups.join(block.lines.map(\.original)))
                    .font(.callout)
                    .lineLimit(3)
                if let translated = block.lines.last?.translated, !translated.isEmpty {
                    Text(translated)
                        .font(.callout)
                        .foregroundStyle(Theme.translation)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .cardBackground()
        }
        HStack(spacing: 8) {
            Button {
                appState.stopRecording()
            } label: {
                Label(L10n.t("record.stop"), systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.recording)
            if !orchestrator.isEphemeralTranslation {
                Button {
                    appState.markHighlight()
                } label: {
                    Image(systemName: "star")
                }
                .help(L10n.t("menubar.markHighlight"))
            }
            Button {
                router.openLive(windowId: AppState.liveWindowId)
            } label: {
                Image(systemName: "rectangle.and.text.magnifyingglass")
            }
            .help(L10n.t("menubar.openLive"))
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var idleSection: some View {
        Button {
            RecordingLauncher.start(appState)
        } label: {
            Label(prefs.intent == .temporary ? L10n.t("record.startTemporary") : L10n.t("record.start"),
                  systemImage: "record.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(appState.isStartingRecording || appState.isMissingCloudCredentialForRecording)

        RecordingOptionsView(source: $prefs.source,
                             intent: $prefs.intent,
                             translationEnabled: $appState.translationEnabled)
        if prefs.intent == .temporary {
            Text(L10n.t("record.hint.temporary"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if appState.isMissingCloudCredentialForRecording {
            Label(L10n.t("toolbar.help.configureKey"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MenuRow: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: Theme.cornerSmall)
                .fill(hovering ? Theme.chrome : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
