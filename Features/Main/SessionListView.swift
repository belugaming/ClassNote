import SwiftUI
import UniformTypeIdentifiers

struct SessionListView: View {
    let courseId: String?
    @Binding var selection: String?
    let courses: [Course]
    let sessions: [Session]
    let onStartSession: () -> Void
    let onImport: (URL) -> Void
    let onDelete: (String) -> Void
    let onMove: (String, String?) -> Void

    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            listHeader
            Divider().opacity(0.45)
            Group {
                if sessions.isEmpty {
                    EmptySessionList(onStart: onStartSession, onImport: { importing = true })
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(sessions) { session in
                                SessionCard(session: session, isSelected: selection == session.id)
                                    .onTapGesture { selection = session.id }
                                    .contextMenu {
                                        Menu {
                                            Button {
                                                onMove(session.id, nil)
                                            } label: {
                                                Label(L10n.t("main.unfiled"), systemImage: session.courseId == nil ? "checkmark" : "tray")
                                            }
                                            .disabled(session.courseId == nil)

                                            if !courses.isEmpty {
                                                Divider()
                                                ForEach(courses) { course in
                                                    Button {
                                                        onMove(session.id, course.id)
                                                    } label: {
                                                        Label(course.name, systemImage: session.courseId == course.id ? "checkmark" : "folder")
                                                    }
                                                    .disabled(session.courseId == course.id)
                                                }
                                            }
                                        } label: {
                                            Label(L10n.t("main.moveSession"), systemImage: "folder")
                                        }

                                        Button(role: .destructive) {
                                            onDelete(session.id)
                                        } label: {
                                            Label(L10n.t("main.deleteSession"), systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(10)
                    }
                }
            }
        }
        .background(Theme.surface.opacity(0.28))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    onStartSession()
                } label: {
                    Label(L10n.t("toolbar.newSession"), systemImage: "mic.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
                Button {
                    importing = true
                } label: {
                    Label(L10n.t("toolbar.import"), systemImage: "square.and.arrow.down")
                }
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.movie, .audio, .mpeg4Movie, .audiovisualContent],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { onImport(url) }
            case .failure(let err):
                AppState.shared.setError(err.localizedDescription)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestImportFile)) { _ in
            importing = true
        }
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Theme.surfaceElevated.opacity(0.55))
    }

    private var title: String {
        guard let courseId else { return L10n.t("main.allSessions") }
        return courses.first { $0.id == courseId }?.name ?? L10n.t("main.courses")
    }

    private var countLabel: String {
        if L10n.isChinese {
            return "\(sessions.count) 个会话"
        }
        return "\(sessions.count) sessions"
    }
}

struct SessionCard: View {
    let session: Session
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isSelected ? Theme.accent : Color.clear)
                .frame(width: 3, height: 48)

            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(iconColor.opacity(0.11))
                )

            VStack(alignment: .leading, spacing: 5) {
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
                    Text("·")
                    Text(sourceLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(stateLabel).pill(stateColor)
                    if session.state == "recording" {
                        Circle()
                            .fill(Theme.recording)
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerMedium)
                .fill(isSelected ? Theme.accentSoft : Theme.surfaceElevated.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerMedium)
                .stroke(isSelected ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch session.sourceKind {
        case "system": return "speaker.wave.3.fill"
        case "mixed": return "person.wave.2.fill"
        case "file": return "doc.fill"
        default: return "mic.fill"
        }
    }

    private var iconColor: Color {
        switch session.sourceKind {
        case "system": return .blue
        case "mixed": return .purple
        case "file": return .gray
        default: return Theme.accent
        }
    }

    private var sourceLabel: String {
        switch session.sourceKind {
        case "system": return L10n.t("session.source.system")
        case "mixed": return L10n.t("session.source.mixed")
        case "file": return L10n.t("session.source.file")
        default: return L10n.t("session.source.mic")
        }
    }

    private var stateLabel: String {
        switch session.state {
        case "recording": return L10n.t("session.state.recording")
        case "summarized": return L10n.t("session.state.summarized")
        case "transcribed": return L10n.t("session.state.transcribed")
        default: return session.state
        }
    }

    private var stateColor: Color {
        switch session.state {
        case "recording": return Theme.recording
        case "summarized": return Theme.success
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
