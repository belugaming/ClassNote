import SwiftUI
import UniformTypeIdentifiers

/// Merged sidebar: "All sessions" pinned at top, followed by collapsible
/// per-course groups. Replaces the old three-column CourseListView +
/// SessionListView split with a single two-column navigation structure.
struct CourseSessionSidebarView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedSessionId: String?
    let totalSessionCount: Int
    let courses: [Course]
    let allSessions: [Session]
    /// The session currently being recorded, if any. It stays visible and
    /// movable, but deleting it would pull the .m4a out from under the writer
    /// and cascade-delete the rows the pipeline is still inserting.
    let recordingSessionId: String?
    let onCreateCourse: (String) -> Void
    let onUpdateCourse: (Course) -> Void
    let onDeleteCourse: (String) -> Void
    let onStartSession: (String?) -> Void
    let onImport: ([URL], String?) -> Void
    let onDeleteSession: (String) -> Void
    let onMoveSession: (String, String?) -> Void
    let onRevealStorage: () -> Void

    @State private var expandedCourseIds: Set<String> = []
    @State private var presentNewCourse = false
    @State private var newCourseName = ""
    @State private var importingCourseId: String?
    @State private var editingCourse: Course?
    @State private var sessionPendingDeletion: Session?
    @State private var coursePendingDeletion: Course?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            List(selection: $selectedSessionId) {
                Section {
                    ForEach(allSessions) { session in
                        SessionCard(session: session, isSelected: selectedSessionId == session.id)
                            .tag(session.id)
                            .contextMenu { sessionContextMenu(session) }
                    }
                } header: {
                    HStack {
                        Text(L10n.t("main.allSessions"))
                        Spacer()
                        Button {
                            importingCourseId = nil
                            onStartSession(nil)
                        } label: {
                            Image(systemName: "mic.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("toolbar.newSession"))
                    }
                }

                ForEach(courses) { course in
                    courseSection(course)
                }
            }
            .listStyle(.sidebar)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    presentNewCourse = true
                } label: {
                    Label(L10n.t("main.newCourse"), systemImage: "plus.circle.fill")
                }
                .help(L10n.t("main.newCourse"))
            }
        }
        .sheet(isPresented: $presentNewCourse) {
            newCourseSheet
        }
        .sheet(item: $editingCourse) { course in
            CourseEditorSheet(course: course) { updated in
                onUpdateCourse(updated)
                editingCourse = nil
            }
        }
        .confirmationDialog(L10n.t("main.deleteSession.confirm.title"),
                            isPresented: Binding(get: { sessionPendingDeletion != nil },
                                                 set: { if !$0 { sessionPendingDeletion = nil } }),
                            presenting: sessionPendingDeletion) { session in
            Button(L10n.t("common.delete"), role: .destructive) {
                // Clear the selection first, or the detail view spends a frame
                // loading a row that is already gone.
                if selectedSessionId == session.id { selectedSessionId = nil }
                onDeleteSession(session.id)
                sessionPendingDeletion = nil
            }
            Button(L10n.t("common.cancel"), role: .cancel) { sessionPendingDeletion = nil }
        } message: { session in
            Text(String(format: L10n.t("main.deleteSession.confirm.message"), session.title))
        }
        .confirmationDialog(L10n.t("main.deleteCourse.confirm.title"),
                            isPresented: Binding(get: { coursePendingDeletion != nil },
                                                 set: { if !$0 { coursePendingDeletion = nil } }),
                            presenting: coursePendingDeletion) { course in
            Button(L10n.t("common.delete"), role: .destructive) {
                onDeleteCourse(course.id)
                coursePendingDeletion = nil
            }
            Button(L10n.t("common.cancel"), role: .cancel) { coursePendingDeletion = nil }
        } message: { course in
            Text(String(format: L10n.t("main.deleteCourse.confirm.message"), course.name))
        }
        // The ⌘⇧N menu command only sets this flag; the sheet it is named after
        // lives here, so this is where it has to be answered. `initial: true`
        // consumes a request raised while no sidebar existed (window closed,
        // Settings frontmost) — otherwise the flag would stay stuck at true and
        // every later press would be a no-op true→true assignment.
        .onChange(of: appState.presentNewCourseSheet, initial: true) { _, requested in
            guard requested else { return }
            presentNewCourse = true
            appState.presentNewCourseSheet = false
        }
        .fileImporter(isPresented: Binding(get: { importingCourseId != nil || isImportingUnfiled },
                                            set: { if !$0 { importingCourseId = nil; isImportingUnfiled = false } }),
                      allowedContentTypes: [.movie, .audio, .mpeg4Movie, .audiovisualContent],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                onImport(urls, importingCourseId)
            case .failure(let err):
                AppState.shared.setError(err.localizedDescription)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestImportFile)) { _ in
            importingCourseId = nil
            isImportingUnfiled = true
        }
    }

    @State private var isImportingUnfiled = false

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("app.name"))
                .font(.title2.weight(.semibold))
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var summaryText: String {
        if L10n.isChinese {
            return "\(courses.count) 门课程 · \(totalSessionCount) 个会话"
        }
        return "\(courses.count) courses · \(totalSessionCount) sessions"
    }

    private func courseSection(_ course: Course) -> some View {
        let sessions = allSessions.filter { $0.courseId == course.id }
        return DisclosureGroup(isExpanded: Binding(
            get: { expandedCourseIds.contains(course.id) },
            set: { isExpanded in
                if isExpanded { expandedCourseIds.insert(course.id) }
                else { expandedCourseIds.remove(course.id) }
            }
        )) {
            ForEach(sessions) { session in
                SessionCard(session: session, isSelected: selectedSessionId == session.id)
                    .tag(session.id)
                    .contextMenu { sessionContextMenu(session) }
            }
        } label: {
            HStack {
                Text(course.name).lineLimit(1)
                Spacer()
                Text("\(sessions.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contextMenu {
                Button {
                    importingCourseId = course.id
                } label: {
                    Label(L10n.t("toolbar.import"), systemImage: "square.and.arrow.down")
                }
                Button {
                    onStartSession(course.id)
                } label: {
                    Label(L10n.t("toolbar.newSession"), systemImage: "mic.circle.fill")
                }
                Divider()
                Button {
                    editingCourse = course
                } label: {
                    Label(L10n.t("main.editCourse"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    coursePendingDeletion = course
                } label: {
                    Label(L10n.t("main.deleteCourse"), systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func sessionContextMenu(_ session: Session) -> some View {
        Menu {
            Button {
                onMoveSession(session.id, nil)
            } label: {
                Label(L10n.t("main.unfiled"), systemImage: session.courseId == nil ? "checkmark" : "tray")
            }
            .disabled(session.courseId == nil)

            if !courses.isEmpty {
                Divider()
                ForEach(courses) { course in
                    Button {
                        onMoveSession(session.id, course.id)
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
            sessionPendingDeletion = session
        } label: {
            Label(L10n.t("main.deleteSession"), systemImage: "trash")
        }
        .disabled(session.id == recordingSessionId)
    }

    private var newCourseSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "book.closed.fill")
                    .font(.title)
                Text(L10n.t("main.newCourse"))
                    .font(.title2.weight(.semibold))
            }
            TextField(L10n.t("main.newCourse.prompt"), text: $newCourseName)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onSubmit { commitNewCourse() }
            HStack {
                Spacer()
                Button(L10n.t("common.cancel"), role: .cancel) {
                    presentNewCourse = false
                    newCourseName = ""
                }
                Button(L10n.t("common.create")) { commitNewCourse() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(newCourseName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func commitNewCourse() {
        let name = newCourseName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onCreateCourse(name)
        newCourseName = ""
        presentNewCourse = false
    }
}
