import SwiftUI

struct CourseListView: View {
    @Binding var selection: String?
    let courses: [Course]
    let onCreate: (String) -> Void
    let onDelete: (String) -> Void

    @State private var presentNew = false
    @State private var newName = ""

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("All sessions", systemImage: "tray.full")
                    .tag(String?.none as String?)
            }
            Section("Courses") {
                ForEach(courses) { course in
                    Label(course.name, systemImage: "book.closed")
                        .tag(String?.some(course.id))
                        .contextMenu {
                            Button(role: .destructive) {
                                onDelete(course.id)
                            } label: {
                                Label("Delete course", systemImage: "trash")
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
                    Label("New Course", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $presentNew) {
            VStack(spacing: 12) {
                Text("New Course")
                    .font(.title3)
                TextField("Course name (e.g. CS 6.001 SICP)", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    .onSubmit { commit() }
                HStack {
                    Button("Cancel", role: .cancel) {
                        presentNew = false
                        newName = ""
                    }
                    Button("Create") { commit() }
                        .keyboardShortcut(.return)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
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
