import SwiftUI

/// "Tell the AI about this class": the kind of class, then what happened in
/// this one, in the student's words. Everything the AI writes about the
/// session reads it. All of it is optional.
struct SessionBriefingSheet: View {
    @ObservedObject var vm: SessionDetailViewModel
    /// Set when the sheet was opened to write notes: saving then writes them
    /// with the template picked here.
    var onGenerate: ((NoteTemplate) -> Void)?
    /// The course row changed (its kind of class), so lists showing it reload.
    var onCourseChanged: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var format: CourseFormat?
    @State private var templateId = NoteTemplates.all[0].id
    @State private var previous: String?
    @State private var drafting: Task<Void, Never>?
    /// Which draft `drafting` is, so a stopped one finishing late cannot clear
    /// the one that replaced it.
    @State private var draftToken = UUID()
    @State private var draftError: String?
    @State private var loaded = false

    private var isDrafting: Bool { drafting != nil }
    private var hasTranscript: Bool { !(vm.session?.segments.isEmpty ?? true) }
    private var starterKeys: [String] { format?.briefingStarterKeys ?? CourseFormat.generalStarterKeys }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if vm.course != nil { formatRow }
            editor
            assist
            if onGenerate != nil { templateRow }
            footer
        }
        .padding(20)
        .frame(width: 540)
        .task { await loadOnce() }
        .onDisappear { drafting?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L10n.t("briefing.title"), systemImage: "person.text.rectangle")
                .font(.title2.weight(.semibold))
            Text(L10n.t("briefing.subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var formatRow: some View {
        LabeledRow(label: L10n.t("briefing.formatLabel")) {
            Picker("", selection: $format) {
                Text(L10n.t("course.format.none")).tag(CourseFormat?.none)
                ForEach(CourseFormat.allCases) { format in
                    Text(L10n.t(format.titleKey)).tag(CourseFormat?.some(format))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .onChange(of: format) { _, newFormat in
                templateId = newFormat?.recommendedTemplateId ?? templateId
            }
        }
    }

    private var editor: some View {
        LabeledRow(label: L10n.t("briefing.textLabel")) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .disabled(isDrafting)
                    if text.isEmpty {
                        Text(L10n.t(format?.briefingPlaceholderKey ?? "briefing.placeholder.general"))
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 150)
                .padding(6)
                .cardBackground(radius: Theme.cornerSmall)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(starterKeys, id: \.self) { key in
                        Button {
                            insert(L10n.t(key))
                        } label: {
                            Label(L10n.t(key), systemImage: "plus")
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isDrafting)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var assist: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let previous, previous != text {
                    Button {
                        insert(previous, asBlock: true)
                    } label: {
                        Label(L10n.t("briefing.previous"), systemImage: "arrow.uturn.backward")
                    }
                    .help(L10n.t("briefing.previous.help") + "\n\n" + previous)
                    .disabled(isDrafting)
                }
                if hasTranscript {
                    Button {
                        if isDrafting { stopDrafting() } else { startDrafting() }
                    } label: {
                        Label(L10n.t(isDrafting ? "briefing.drafting.stop" : "briefing.draft"),
                              systemImage: isDrafting ? "stop.circle" : "wand.and.stars")
                    }
                    .help(L10n.t("briefing.draft.help"))
                    if isDrafting { ProgressView().controlSize(.small) }
                }
                Spacer()
            }
            .controlSize(.small)
            if let draftError {
                Label(draftError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var templateRow: some View {
        LabeledRow(label: L10n.t("briefing.template")) {
            HStack(spacing: 8) {
                Picker("", selection: $templateId) {
                    ForEach(NoteTemplates.all) { template in
                        Text(L10n.t(template.labelKey)).tag(template.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if let format, templateId == format.recommendedTemplateId {
                    Text(L10n.t("briefing.template.recommended"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L10n.t("common.cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if onGenerate != nil {
                Button(L10n.t("common.save")) { save(generate: false) }
                Button(L10n.t("briefing.saveAndGenerate")) { save(generate: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!hasTranscript)
            } else {
                Button(L10n.t("common.save")) { save(generate: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .disabled(isDrafting)
    }

    // MARK: - Actions

    private func loadOnce() async {
        guard !loaded else { return }
        loaded = true
        text = vm.briefing
        format = vm.course?.formatValue
        templateId = vm.recommendedTemplate.id
        previous = await vm.previousBriefing()
    }

    /// Adds `addition` on a line of its own after what is already there.
    private func insert(_ addition: String, asBlock: Bool = false) {
        let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            text = addition
        } else {
            text = text.trimmingCharacters(in: .newlines) + (asBlock ? "\n\n" : "\n") + addition
        }
    }

    private func startDrafting() {
        draftError = nil
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stream = vm.briefingDraft(format: format)
        let token = UUID()
        draftToken = token
        drafting = Task { @MainActor in
            var draft = ""
            do {
                for try await delta in stream {
                    guard draftToken == token, !Task.isCancelled else { return }
                    draft += delta
                    text = base.isEmpty ? draft : base + "\n\n" + draft
                }
            } catch is CancellationError {
            } catch {
                draftError = error.localizedDescription
            }
            guard draftToken == token else { return }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            drafting = nil
        }
    }

    private func stopDrafting() {
        drafting?.cancel()
        drafting = nil
        draftToken = UUID()
    }

    private func save(generate: Bool) {
        let chosenFormat = format
        let template = NoteTemplates.find(templateId)
        let briefing = text
        Task { @MainActor in
            if vm.course != nil, chosenFormat != vm.course?.formatValue {
                await vm.setCourseFormat(chosenFormat)
                onCourseChanged()
            }
            await vm.saveBriefing(briefing)
            dismiss()
            if generate { onGenerate?(template) }
        }
    }
}
