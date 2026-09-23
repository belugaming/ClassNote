import SwiftUI

/// Left column: the whole library, unfiled recordings, and one row per course.
struct LibrarySidebar: View {
    @EnvironmentObject var appState: AppState
    @Binding var filter: LibraryFilter?
    @ObservedObject var vm: MainWindowViewModel
    let onRecord: (String?) -> Void
    let onImport: (String?) -> Void

    @State private var newCourseName = ""
    @State private var presentingNewCourse = false
    @State private var editingCourse: Course?
    @State private var coursePendingDeletion: Course?

    var body: some View {
        List(selection: $filter) {
            Section(L10n.t("library.section")) {
                row(L10n.t("library.all"), icon: "tray.full", count: vm.count(for: .all))
                    .tag(LibraryFilter.all)
                row(L10n.t("main.unfiled"), icon: "tray", count: vm.count(for: .unfiled))
                    .tag(LibraryFilter.unfiled)
            }

            Section {
                ForEach(vm.courses) { course in
                    courseRow(course)
                        .tag(LibraryFilter.course(course.id))
                        .contextMenu { courseMenu(course) }
                }
                if vm.courses.isEmpty {
                    Button {
                        presentingNewCourse = true
                    } label: {
                        Label(L10n.t("main.newCourse"), systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text(L10n.t("library.courses"))
                    Spacer()
                    Button {
                        presentingNewCourse = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.t("main.newCourse"))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { engineStatus }
        .sheet(isPresented: $presentingNewCourse) { newCourseSheet }
        .sheet(item: $editingCourse) { course in
            CourseEditorSheet(course: course) { updated in
                Task { await vm.updateCourse(updated) }
            }
        }
        .confirmationDialog(L10n.t("main.deleteCourse.confirm.title"),
                            isPresented: Binding(get: { coursePendingDeletion != nil },
                                                 set: { if !$0 { coursePendingDeletion = nil } }),
                            presenting: coursePendingDeletion) { course in
            Button(L10n.t("common.delete"), role: .destructive) {
                if filter == .course(course.id) { filter = .all }
                Task { await vm.deleteCourse(id: course.id) }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: { course in
            Text(String(format: L10n.t("main.deleteCourse.confirm.message"), course.name))
        }
        // ⇧⌘N only raises the flag; the sheet it names lives here. `initial`
        // answers a request raised while no sidebar existed.
        .onChange(of: appState.presentNewCourseSheet, initial: true) { _, requested in
            guard requested else { return }
            presentingNewCourse = true
            appState.presentNewCourseSheet = false
        }
    }

    private func row(_ title: String, icon: String, count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    private func courseRow(_ course: Course) -> some View {
        Label {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(course.name).lineLimit(1)
                    if let detail = courseDetail(course) {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text("\(vm.count(for: .course(course.id)))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: "book.closed")
        }
    }

    private func courseDetail(_ course: Course) -> String? {
        let parts = [course.semester, course.instructor].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func courseMenu(_ course: Course) -> some View {
        Button {
            onRecord(course.id)
        } label: {
            Label(L10n.t("library.recordHere"), systemImage: "record.circle")
        }
        Button {
            onImport(course.id)
        } label: {
            Label(L10n.t("library.importHere"), systemImage: "square.and.arrow.down")
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

    /// The local engine loading at launch takes a while; say so where the
    /// user is looking instead of letting the first recording look stuck.
    @ViewBuilder
    private var engineStatus: some View {
        if appState.isLocalEnginePreloading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(appState.localEngineStatus.isEmpty ? L10n.t("settings.engines.loading")
                                                        : appState.localEngineStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.bar)
        }
    }

    private var newCourseSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("main.newCourse")).font(.title3.weight(.semibold))
            TextField(L10n.t("main.newCourse.prompt"), text: $newCourseName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitNewCourse)
            HStack {
                Spacer()
                Button(L10n.t("common.cancel"), role: .cancel) {
                    presentingNewCourse = false
                    newCourseName = ""
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.t("common.create"), action: commitNewCourse)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newCourseName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func commitNewCourse() {
        let name = newCourseName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newCourseName = ""
        presentingNewCourse = false
        Task {
            if let course = await vm.createCourse(name: name) {
                filter = .course(course.id)
            }
        }
    }
}
