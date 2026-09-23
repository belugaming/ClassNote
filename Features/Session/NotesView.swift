import SwiftUI

/// AI notes for the session, with the versions generated so far.
struct NotesView: View {
    @ObservedObject var vm: SessionDetailViewModel
    @State private var confirmingDelete = false
    @State private var showingHistory = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if vm.isPreviewingOldVersion, !vm.isShowingNoteStream { oldVersionBanner }
                content
            }
            if showingHistory {
                Divider()
                history.frame(width: 250)
            }
        }
        .confirmationDialog(L10n.t("notes.delete.title"), isPresented: $confirmingDelete) {
            Button(L10n.t("common.delete"), role: .destructive) {
                Task { await vm.deleteCurrentNote() }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("notes.delete.message"))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if vm.isShowingNoteStream {
                ProgressView().controlSize(.small)
                Text(L10n.t("notes.status.streaming")).foregroundStyle(Theme.accent)
            } else if let note = vm.note {
                Text(L10n.t(NoteTemplates.find(templateId(for: note)).labelKey))
                    .font(.callout.weight(.medium))
                Text("v\(note.version) · \(DateLabels.dateTime(Date(timeIntervalSince1970: TimeInterval(note.generatedAt) / 1000)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let note = vm.note, !vm.isShowingNoteStream {
                Button {
                    Clipboard.copy(note.markdown)
                } label: {
                    Label(L10n.t("common.copy"), systemImage: "doc.on.doc")
                }
            }
            Toggle(isOn: $showingHistory) {
                Label(L10n.t("notes.history.title"), systemImage: "clock.arrow.circlepath")
            }
            .toggleStyle(.button)
            .disabled(vm.noteVersions.isEmpty)
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label(L10n.t("notes.action.delete"), systemImage: "trash")
            }
            .disabled(vm.note == nil || vm.isGeneratingNotes)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func templateId(for note: Note) -> String {
        vm.noteVersions.first { $0.version == note.version }?.template ?? "study"
    }

    private var oldVersionBanner: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
            Text(L10n.t("notes.oldVersion"))
            Spacer()
            Button(L10n.t("notes.showLatest")) { Task { await vm.showLatestNote() } }
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.accentSoft)
    }

    @ViewBuilder
    private var content: some View {
        if vm.isShowingNoteStream {
            ScrollView {
                StreamingMarkdownPreview(markdown: vm.streamingNoteMarkdown)
                    .textSelection(.enabled)
                    .frame(maxWidth: Theme.readingWidth, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
            }
        } else if let markdown = vm.note?.markdown, !markdown.isEmpty {
            ScrollView {
                MarkdownView(markdown: markdown)
                    .textSelection(.enabled)
                    .frame(maxWidth: Theme.readingWidth, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 16) {
                EmptyStateView(systemImage: "sparkles",
                               title: L10n.t("session.empty.notes.title"),
                               message: L10n.t("session.empty.notes.desc"))
                    .frame(maxHeight: 260)
                HStack(spacing: 8) {
                    ForEach(NoteTemplates.all) { template in
                        Button(L10n.t(template.labelKey)) {
                            Task { await vm.generateNotes(template: template) }
                        }
                    }
                }
                .disabled(vm.isGeneratingNotes || (vm.session?.segments.isEmpty ?? true))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var history: some View {
        List(vm.noteVersions) { version in
            Button {
                vm.previewNoteVersion(version)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(L10n.t(NoteTemplates.find(version.template).labelKey)) · v\(version.version)")
                        .font(.callout.weight(vm.note?.version == version.version ? .semibold : .regular))
                    Text(DateLabels.dateTime(Date(timeIntervalSince1970: TimeInterval(version.generatedAt) / 1000)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.sidebar)
    }
}
