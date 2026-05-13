import SwiftUI

struct LiveSessionView: View {
    let sessionId: String
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            LiveSubtitleView(buffer: appState.orchestrator.transcript)
        }
        .background(
            LinearGradient(colors: [
                Color.black.opacity(0.02),
                Color.primary.opacity(0.04)
            ], startPoint: .top, endPoint: .bottom)
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.orchestrator.currentSession?.title ?? L10n.t("live.title"))
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.isRecording ? Theme.recording : Color.secondary)
                        .frame(width: 8, height: 8)
                        .opacity(appState.isRecording ? 1 : 0.5)
                        .scaleEffect(appState.isRecording ? 1.0 : 0.85)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: appState.isRecording)
                    Text(appState.isRecording ? L10n.t("live.statusLive") : L10n.t("live.statusIdle"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(appState.isRecording ? Theme.recording : .secondary)
                    Text("·")
                    Text(formatDuration(appState.orchestrator.currentTimestampMs))
                        .monospacedDigit()
                        .font(.caption.monospacedDigit())
                    Text("·")
                    Text(sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            LiveControlsView()
        }
        .padding(16)
    }

    private var sourceLabel: String {
        switch appState.orchestrator.source {
        case .microphone: return L10n.t("session.source.mic")
        case .system: return L10n.t("session.source.system")
        case .mixed: return L10n.t("session.source.mixed")
        case .file: return L10n.t("session.source.file")
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
