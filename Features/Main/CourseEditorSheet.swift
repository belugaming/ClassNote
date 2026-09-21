import SwiftUI

/// Editor for everything a course carries beyond its name.
///
/// The sidebar could only ever create a course with a name and delete it, so the
/// semester, instructor and notes columns had existed since the first schema
/// with no way to fill them, and the glossary — which is what makes translation
/// render course jargon consistently — had nowhere to be typed at all.
struct CourseEditorSheet: View {
    @State private var draft: Course
    let onSave: (Course) -> Void
    @Environment(\.dismiss) private var dismiss

    init(course: Course, onSave: @escaping (Course) -> Void) {
        _draft = State(initialValue: course)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "book.closed.fill")
                    .font(.title)
                Text(L10n.t("main.editCourse"))
                    .font(.title2.weight(.semibold))
            }

            LabeledRow(label: L10n.t("course.field.name")) {
                TextField(L10n.t("main.newCourse.prompt"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                LabeledRow(label: L10n.t("course.field.semester")) {
                    TextField("", text: optionalBinding(\.semester))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledRow(label: L10n.t("course.field.instructor")) {
                    TextField("", text: optionalBinding(\.instructor))
                        .textFieldStyle(.roundedBorder)
                }
            }

            LabeledRow(label: L10n.t("course.field.glossary")) {
                VStack(alignment: .leading, spacing: 6) {
                    // Monospaced because the content is `term = 译名` pairs, one
                    // per line: aligned columns are the point.
                    TextEditor(text: optionalBinding(\.glossary))
                        .font(.system(.callout, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(height: 120)
                        .padding(6)
                        .cardBackground(radius: Theme.cornerSmall)
                    Text(L10n.t("course.field.glossary.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LabeledRow(label: L10n.t("course.field.notes")) {
                TextEditor(text: optionalBinding(\.notes))
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(height: 70)
                    .padding(6)
                    .cardBackground(radius: Theme.cornerSmall)
            }

            HStack {
                Spacer()
                Button(L10n.t("common.cancel"), role: .cancel) { dismiss() }
                Button(L10n.t("common.save")) { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// `Course`'s optional text columns as non-optional field bindings: an empty
    /// field stores nil, so a cleared instructor does not turn into an empty
    /// string the prompt builders would then have to filter out.
    private func optionalBinding(_ keyPath: WritableKeyPath<Course, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" },
                set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func commit() {
        var course = draft
        course.name = course.name.trimmingCharacters(in: .whitespaces)
        guard !course.name.isEmpty else { return }
        onSave(course)
        dismiss()
    }
}
