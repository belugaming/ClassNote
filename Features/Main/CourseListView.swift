import SwiftUI

enum CourseSidebarSelection: Hashable {
    case all
    case course(id: String)

    var courseId: String? {
        switch self {
        case .all:
            return nil
        case .course(let id):
            return id
        }
    }
}

struct CourseListView: View {
    @Binding var selection: CourseSidebarSelection?
    let courses: [Course]
    let onCreate: (String) -> Void
    let onDelete: (String) -> Void

    @State private var presentNew = false
    @State private var newName = ""

    var body: some View {
        List(selection: $selection) {
            Section {
                Label {
                    Text(L10n.t("main.allSessions")).font(.body)
                } icon: {
                    Image(systemName: "tray.full")
                        .foregroundStyle(Theme.accent)
                }
                .tag(CourseSidebarSelection.all)
            }
            Section(L10n.t("main.courses")) {
                ForEach(courses) { course in
                    Label {
                        Text(course.name).font(.body)
                    } icon: {
                        Image(systemName: "book.closed.fill")
                            .foregroundStyle(Theme.accent)
                    }
                    .tag(CourseSidebarSelection.course(id: course.id))
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(course.id)
                        } label: {
                            Label(L10n.t("main.deleteCourse"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    presentNew = true
                } label: {
                    Label(L10n.t("main.newCourse"), systemImage: "plus.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
                .help(L10n.t("main.newCourse"))
            }
        }
        .sheet(isPresented: $presentNew) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "book.closed.fill")
                        .font(.title)
                        .foregroundStyle(Theme.accent)
                    Text(L10n.t("main.newCourse"))
                        .font(.title2.weight(.semibold))
                }
                TextField(L10n.t("main.newCourse.prompt"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit { commit() }
                HStack {
                    Spacer()
                    Button(L10n.t("common.cancel"), role: .cancel) {
                        presentNew = false
                        newName = ""
                    }
                    Button(L10n.t("common.create")) { commit() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .keyboardShortcut(.return)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
    }

    private func commit() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onCreate(name)
        newName = ""
        presentNew = false
    }
}
