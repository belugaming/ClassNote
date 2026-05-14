import SwiftUI

struct LiveControlsView: View {
    @EnvironmentObject var appState: AppState
    let windowId: String
    @ObservedObject var orchestrator: SessionOrchestrator

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $appState.translationEnabled) {
                Label(L10n.t("live.translation.toggle"), systemImage: "character.bubble")
            }
            .toggleStyle(.button)
            .tint(Theme.accent)

            if !orchestrator.isImporting {
                Button {
                    appState.markHighlight()
                } label: {
                    Label(L10n.t("live.highlight"), systemImage: "star.circle")
                }
                .disabled(!appState.isRecording || orchestrator.isEphemeralTranslation)
            }

            if orchestrator.isImporting {
                Button(role: .destructive) {
                    Task { await appState.stopImport(windowId: windowId) }
                } label: {
                    Label(L10n.t("live.import.cancel"), systemImage: "xmark.circle.fill")
                }
                .tint(Theme.recording)
                .buttonStyle(.borderedProminent)
            } else if appState.isRecording {
                Button(role: .destructive) {
                    appState.stopRecording()
                } label: {
                    Label(L10n.t("live.stop"), systemImage: "stop.circle.fill")
                }
                .tint(Theme.recording)
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    appState.startNewSession()
                } label: {
                    Label(L10n.t("live.start"), systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
    }
}
