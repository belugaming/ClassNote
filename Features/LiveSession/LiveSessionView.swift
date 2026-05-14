import SwiftUI

struct LiveSessionView: View {
    let sessionId: String
    @EnvironmentObject var appState: AppState

    var body: some View {
        InnerView(windowId: sessionId,
                  appState: appState,
                  orchestrator: appState.orchestrator(for: sessionId))
    }
}

private struct InnerView: View {
    let windowId: String
    @ObservedObject var appState: AppState
    @ObservedObject var orchestrator: SessionOrchestrator

    var body: some View {
        VStack(spacing: 0) {
            header
            if orchestrator.isImporting {
                ImportProgressBar(completed: orchestrator.importCompleted,
                                  total: orchestrator.importTotal,
                                  fraction: orchestrator.importProgress)
            }
            Divider().opacity(0.4)
            LiveSubtitleView(buffer: orchestrator.transcript)
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
                HStack(spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    if orchestrator.isEphemeralTranslation {
                        Text(L10n.t("live.ephemeral.badge"))
                            .pill(Theme.translation)
                    }
                }
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 8, height: 8)
                        .opacity(isActive ? 1 : 0.5)
                        .scaleEffect(isActive ? 1.0 : 0.85)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isActive)
                    Text(statusLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusDotColor)
                    Text("·")
                    Text(formatDuration(orchestrator.currentTimestampMs))
                        .monospacedDigit()
                        .font(.caption.monospacedDigit())
                    Text("·")
                    Text(sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if orchestrator.isEphemeralTranslation {
                    Label(L10n.t("live.ephemeral.description"), systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            LiveControlsView(windowId: windowId, orchestrator: orchestrator)
        }
        .padding(16)
    }

    private var isActive: Bool {
        appState.isRecording || orchestrator.isImporting
    }

    private var statusDotColor: Color {
        if orchestrator.isImporting { return Theme.accent }
        if appState.isRecording { return Theme.recording }
        return .secondary
    }

    private var statusLabel: String {
        if orchestrator.isImporting { return L10n.t("live.statusImporting") }
        if orchestrator.isEphemeralTranslation { return L10n.t("live.statusEphemeral") }
        if appState.isRecording { return L10n.t("live.statusLive") }
        return L10n.t("live.statusIdle")
    }

    private var title: String {
        if orchestrator.isEphemeralTranslation {
            return L10n.t("live.ephemeral.title")
        }
        return orchestrator.currentSession?.title ?? L10n.t("live.title")
    }

    private var sourceLabel: String {
        switch orchestrator.source {
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

private struct ImportProgressBar: View {
    let completed: Int
    let total: Int
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView(value: fraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                Text(counterText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.accentSoft.opacity(0.4))
    }

    private var counterText: String {
        if total <= 0 { return L10n.t("live.import.preparing") }
        if let f = fraction {
            return "\(completed)/\(total) · \(Int(f * 100))%"
        }
        return "\(completed)/\(total)"
    }
}
