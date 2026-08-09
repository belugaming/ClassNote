import SwiftUI
import UniformTypeIdentifiers

/// Merged sidebar: "All sessions" pinned at top, followed by collapsible
/// per-course groups. Replaces the old three-column CourseListView +
/// SessionListView split with a single two-column navigation structure.
struct CourseSessionSidebarView: View {
    @Binding var selectedSessionId: String?
    let totalSessionCount: Int
    let courses: [Course]
    let allSessions: [Session]
    let onCreateCourse: (String) -> Void
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
                Button(role: .destructive) {
                    onDeleteCourse(course.id)
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
            onDeleteSession(session.id)
        } label: {
            Label(L10n.t("main.deleteSession"), systemImage: "trash")
        }
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
