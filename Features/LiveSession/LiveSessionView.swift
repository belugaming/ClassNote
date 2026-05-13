import SwiftUI

struct LiveSessionView: View {
    let sessionId: String
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text(appState.orchestrator.currentSession?.title ?? "Live session")
                        .font(.title2.weight(.semibold))
                    HStack(spacing: 8) {
                        Circle().fill(appState.isRecording ? .red : .secondary).frame(width: 8, height: 8)
                        Text(appState.isRecording ? "Recording" : "Idle")
                        Text("·")
                        Text(formatDuration(appState.orchestrator.currentTimestampMs))
                            .monospacedDigit()
                        Text("·")
                        Text(appState.orchestrator.source.displayName)
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
                Spacer()
                LiveControlsView()
            }
            .padding(16)

            Divider()

            LiveSubtitleView(buffer: appState.orchestrator.transcript)
        }
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
