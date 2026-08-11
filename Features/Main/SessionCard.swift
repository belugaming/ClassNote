import SwiftUI
import UniformTypeIdentifiers

/// `SessionCard` and `EmptySessionList` are shared with
/// `CourseSessionSidebarView`, which replaced the old `SessionListView`
/// three-column layout.
struct SessionCard: View {
    let session: Session
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(session.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(formatDuration(session.durationMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(formatDate(session.startedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if session.state == "recording" {
                    Circle()
                        .fill(Theme.recording)
                        .frame(width: 6, height: 6)
                }
                Text(stateLabel).pill(stateColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(isSelected ? Theme.accentSoft : Color.clear)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Theme.hairline),
            alignment: .bottom
        )
        .contentShape(Rectangle())
    }

    private var stateLabel: String {
        switch session.state {
        case "recording": return L10n.t("session.state.recording")
        case "summarized": return L10n.t("session.state.summarized")
        case "transcribed": return L10n.t("session.state.transcribed")
        case "interrupted": return L10n.t("session.state.interrupted")
        case "failed": return L10n.t("session.state.failed")
        case "ready": return L10n.t("session.state.transcribed")
        default: return session.state
        }
    }

    private var stateColor: Color {
        switch session.state {
        case "recording": return Theme.recording
        case "summarized": return Theme.success
        case "interrupted": return Theme.warning
        case "failed": return .red
        default: return .secondary
        }
    }

    private func formatDate(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = L10n.isChinese ? "MM月dd日 HH:mm" : "MMM d, HH:mm"
        return f.string(from: date)
    }

    private func formatDuration(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

struct EmptySessionList: View {
    let onStart: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 72, height: 72)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.accentSoft)
                )
            VStack(spacing: 6) {
                Text(L10n.t("session.empty.transcript.title"))
                    .font(.headline)
                Text(L10n.t("session.empty.transcript.desc"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 270)
            }
            VStack(spacing: 8) {
                Button {
                    onStart()
                } label: {
                    Label(L10n.t("toolbar.newSession"), systemImage: "mic.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                Button {
                    onImport()
                } label: {
                    Label(L10n.t("toolbar.import"), systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .frame(width: 190)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
