import SwiftUI
import UniformTypeIdentifiers

/// Middle column: the sessions of the selected library section, newest first,
/// grouped by day.
struct SessionListView: View {
    let title: String
    let sessions: [Session]
    let courses: [Course]
    @Binding var selection: String?
    /// The session being recorded, if any. Deleting it would pull the audio
    /// file out from under the writer.
    let recordingSessionId: String?
    @ObservedObject var vm: MainWindowViewModel
    let onRecord: () -> Void
    let onImport: () -> Void
    let onDropFiles: ([URL]) -> Void

    @State private var renaming: Session?
    @State private var renameText = ""
    @State private var pendingDeletion: Session?
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if sessions.isEmpty {
                EmptyStateView(systemImage: "waveform",
                               title: L10n.t("list.empty.title"),
                               message: L10n.t("list.empty.message"))
            } else {
                List(selection: $selection) {
                    ForEach(days, id: \.self) { day in
                        Section(DateLabels.day(day)) {
                            ForEach(sessionsByDay[day] ?? []) { session in
                                SessionRow(session: session,
                                           courseName: courseName(session),
                                           isRecording: session.id == recordingSessionId)
                                    .tag(session.id)
                                    .contextMenu { menu(session) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(sessions.isEmpty ? "" : String(format: L10n.t("list.count"), sessions.count))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.cornerLarge)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .overlay(Label(L10n.t("list.dropToImport"), systemImage: "square.and.arrow.down")
                        .padding(10)
                        .background(.regularMaterial, in: Capsule()))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let media = urls.filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .audiovisualContent)
            }
            guard !media.isEmpty else { return false }
            onDropFiles(media)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .sheet(item: $renaming) { session in
            renameSheet(session)
        }
        .confirmationDialog(L10n.t("main.deleteSession.confirm.title"),
                            isPresented: Binding(get: { pendingDeletion != nil },
                                                 set: { if !$0 { pendingDeletion = nil } }),
                            presenting: pendingDeletion) { session in
            Button(L10n.t("common.delete"), role: .destructive) {
                if selection == session.id { selection = nil }
                Task { await vm.deleteSession(id: session.id) }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: { session in
            Text(String(format: L10n.t("main.deleteSession.confirm.message"), session.title))
        }
    }

    private var sessionsByDay: [Date: [Session]] {
        Dictionary(grouping: sessions) { Calendar.current.startOfDay(for: $0.startedDate) }
    }

    private var days: [Date] {
        sessionsByDay.keys.sorted(by: >)
    }

    private func courseName(_ session: Session) -> String? {
        guard let id = session.courseId else { return nil }
        return courses.first { $0.id == id }?.name
    }

    @ViewBuilder
    private func menu(_ session: Session) -> some View {
        Button {
            renameText = session.title
            renaming = session
        } label: {
            Label(L10n.t("session.action.rename"), systemImage: "pencil")
        }
        Menu {
            Button {
                Task { await vm.moveSession(id: session.id, courseId: nil) }
            } label: {
                Label(L10n.t("main.unfiled"), systemImage: session.courseId == nil ? "checkmark" : "tray")
            }
            .disabled(session.courseId == nil)
            if !courses.isEmpty { Divider() }
            ForEach(courses) { course in
                Button {
                    Task { await vm.moveSession(id: session.id, courseId: course.id) }
                } label: {
                    Label(course.name, systemImage: session.courseId == course.id ? "checkmark" : "book.closed")
                }
                .disabled(session.courseId == course.id)
            }
        } label: {
            Label(L10n.t("main.moveSession"), systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            pendingDeletion = session
        } label: {
            Label(L10n.t("main.deleteSession"), systemImage: "trash")
        }
        .disabled(session.id == recordingSessionId)
    }

    private func renameSheet(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("session.action.rename")).font(.title3.weight(.semibold))
            TextField("", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRename(session) }
            HStack {
                Spacer()
                Button(L10n.t("common.cancel"), role: .cancel) { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("common.save")) { commitRename(session) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func commitRename(_ session: Session) {
        let title = renameText
        renaming = nil
        Task { await vm.renameSession(id: session.id, title: title) }
    }
}

/// One session in the list.
struct SessionRow: View {
    let session: Session
    let courseName: String?
    let isRecording: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isRecording ? "record.circle.fill" : session.sourceValue.icon)
                .foregroundStyle(isRecording ? Theme.recording : .secondary)
                .symbolEffect(.pulse, isActive: isRecording)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(DateLabels.time(session.startedDate))
                    if session.durationMs > 0 {
                        Text("·")
                        Text(session.durationLabel).monospacedDigit()
                    }
                    if let courseName {
                        Text("·")
                        Text(courseName).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if showsState {
                Text(session.stateLabel).pill(session.stateColor)
            }
        }
        .padding(.vertical, 3)
    }

    /// Only states worth a glance: a finished transcript is the normal case.
    private var showsState: Bool {
        switch session.stateValue {
        case .transcribed, .summarized: return false
        case .recording: return !isRecording
        default: return true
        }
    }
}
