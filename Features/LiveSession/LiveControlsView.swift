import SwiftUI

struct LiveControlsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $appState.translationEnabled) {
                Label("Translate", systemImage: "character.bubble")
            }
            .toggleStyle(.button)

            Button {
                appState.markHighlight()
            } label: {
                Label("Highlight", systemImage: "star.circle")
            }
            .disabled(!appState.isRecording)

            Button(role: appState.isRecording ? .destructive : nil) {
                if appState.isRecording { appState.stopRecording() } else { appState.startNewSession() }
            } label: {
                Label(appState.isRecording ? "Stop" : "Start",
                      systemImage: appState.isRecording ? "stop.circle.fill" : "record.circle")
            }
        }
    }
}
