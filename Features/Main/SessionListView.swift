import SwiftUI
import UniformTypeIdentifiers

struct SessionListView: View {
    let courseId: String?
    @Binding var selection: String?
    let sessions: [Session]
    let onStartSession: () -> Void
    let onImport: (URL) -> Void
    let onDelete: (String) -> Void

    @State private var importing = false

    var body: some View {
        List(selection: $selection) {
            ForEach(sessions) { session in
                SessionRow(session: session)
                    .tag(String?.some(session.id))
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(session.id)
                        } label: {
                            Label("Delete session", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.inset)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    onStartSession()
                } label: {
                    Label("New Session", systemImage: "mic.circle.fill")
                }
                Button {
                    importing = true
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
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

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(formatDate(session.startedAt))
                    Text("·")
                    Text(formatDuration(session.durationMs))
                    Text("·")
                    Text(session.state.capitalized)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch session.sourceKind {
        case "system": return "speaker.wave.3.fill"
        case "mixed": return "person.wave.2.fill"
        case "file": return "doc.fill"
        default: return "mic.fill"
        }
    }

    private func formatDate(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
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
