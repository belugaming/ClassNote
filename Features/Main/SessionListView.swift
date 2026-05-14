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
        Group {
            if sessions.isEmpty {
                EmptySessionList(onStart: onStartSession, onImport: { importing = true })
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
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
                    .padding(12)
                }
            }
        }
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
    }
}

struct SessionCard: View {
    let session: Session
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.16))
                    .frame(width: 40, height: 40)
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(formatDate(session.startedAt))
                    Text("·")
                    Text(formatDuration(session.durationMs))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(stateLabel).pill(stateColor)
                    Text(sourceLabel).pill(Theme.accent)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerMedium)
                .fill(isSelected ? Theme.accentSoft : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerMedium)
                .stroke(isSelected ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: 1)
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
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "mic.circle")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)
            Text(L10n.t("session.empty.transcript.title"))
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(L10n.t("session.empty.transcript.desc"))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            HStack {
                Button {
                    onStart()
                } label: {
                    Label(L10n.t("toolbar.newSession"), systemImage: "mic.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                Button {
                    onImport()
                } label: {
                    Label(L10n.t("toolbar.import"), systemImage: "square.and.arrow.down")
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
