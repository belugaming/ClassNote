import SwiftUI

/// Study tools, questions about the lecture, and flashcards.
struct StudyView: View {
    @ObservedObject var vm: SessionDetailViewModel
    @AppStorage("studySection", store: AppEnvironment.defaults) private var sectionRaw = Section.qa.rawValue

    enum Section: String, CaseIterable, Identifiable {
        case qa, flashcards, tools
        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .tools: return "session.tab.tools"
            case .qa: return "session.tab.qa"
            case .flashcards: return "session.tab.flashcards"
            }
        }
        var icon: String {
            switch self {
            case .tools: return "wand.and.stars"
            case .qa: return "bubble.left.and.bubble.right"
            case .flashcards: return "rectangle.on.rectangle.angled"
            }
        }
    }

    private var section: Section { Section(rawValue: sectionRaw) ?? .qa }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $sectionRaw) {
                    ForEach(Section.allCases) { s in
                        Label(L10n.t(s.titleKey), systemImage: s.icon).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            Divider()
            switch section {
            case .tools: StudyToolsPane(vm: vm)
            case .qa: QAPane(vm: vm)
            case .flashcards: FlashcardsPane(vm: vm)
            }
        }
    }
}

/// Says the transcript was shortened for a local model, so a thin answer is
/// explained rather than mysterious.
private struct LocalContextNotice: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "scissors")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Q&A

struct QAPane: View {
    @ObservedObject var vm: SessionDetailViewModel
    @State private var question = ""
    @State private var confirmingClear = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if vm.qaMessages.isEmpty && !vm.isAnsweringQuestion {
                        EmptyStateView(systemImage: "bubble.left.and.bubble.right",
                                       title: L10n.t("qa.empty.title"),
                                       message: L10n.t("qa.empty.desc"))
                            .frame(minHeight: 280)
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(vm.qaMessages) { message in
                                QABubble(message: message) {
                                    Task { await vm.deleteQAMessage(message) }
                                }
                                .id(message.id)
                            }
                            if vm.isAnsweringQuestion {
                                QAStreamingBubble(text: vm.streamingQAResponse)
                                    .id("streaming")
                            }
                        }
                        .frame(maxWidth: Theme.readingWidth)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                    }
                }
                .onChange(of: vm.qaMessages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: vm.streamingQAResponse) { _, _ in scrollToBottom(proxy) }
            }
            if !vm.transcriptTruncatedNotice.isEmpty && vm.isAnsweringQuestion {
                LocalContextNotice(text: vm.transcriptTruncatedNotice).padding(.bottom, 4)
            }
            Divider()
            HStack(spacing: 8) {
                TextField(L10n.t("qa.placeholder"), text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(submit)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: Theme.cornerMedium).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerMedium).strokeBorder(Theme.hairline))
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isAnsweringQuestion)
                .help(L10n.t("qa.ask"))
                Menu {
                    Button(L10n.t("qa.clearHistory"), role: .destructive) { confirmingClear = true }
                        .disabled(vm.qaMessages.isEmpty || vm.isAnsweringQuestion)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(12)
        }
        .confirmationDialog(L10n.t("qa.clearHistory"), isPresented: $confirmingClear) {
            Button(L10n.t("common.delete"), role: .destructive) {
                Task { await vm.clearQAMessages() }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("qa.clearHistory.message"))
        }
    }

    private func submit() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !vm.isAnsweringQuestion else { return }
        question = ""
        Task { await vm.askQuestion(q) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            if vm.isAnsweringQuestion {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = vm.qaMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct QABubble: View {
    let message: QAMessage
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 6) {
                if message.role == .assistant {
                    MarkdownView(markdown: message.content).textSelection(.enabled)
                } else {
                    Text(message.content)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                    .fill(message.role == .user ? Theme.accentSoft : Theme.surface)
            )
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: delete) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("qa.deleteMessage"))
                    .offset(x: 6, y: -6)
                }
            }
            if message.role == .assistant { Spacer(minLength: 60) }
        }
        .onHover { hovering = $0 }
    }
}

private struct QAStreamingBubble: View {
    let text: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                if text.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    StreamingMarkdownPreview(markdown: text).textSelection(.enabled)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous).fill(Theme.surface))
            Spacer(minLength: 60)
        }
    }
}

// MARK: - Flashcards

struct FlashcardsPane: View {
    @ObservedObject var vm: SessionDetailViewModel
    @State private var revealed: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if !vm.flashcards.isEmpty {
                    Text(String(format: L10n.t("flashcards.count"), vm.flashcards.count))
                        .foregroundStyle(.secondary)
                    Button(revealed.count == vm.flashcards.count ? L10n.t("flashcards.hideAll")
                                                                 : L10n.t("flashcards.showAll")) {
                        revealed = revealed.count == vm.flashcards.count ? [] : Set(vm.flashcards.indices)
                    }
                }
                Spacer()
                Button {
                    vm.copyFlashcardsForAnki()
                } label: {
                    Label(L10n.t("flashcards.copyAnki"), systemImage: "doc.on.clipboard")
                }
                .disabled(vm.flashcards.isEmpty)
                Button {
                    revealed = []
                    Task { await vm.generateFlashcards() }
                } label: {
                    Label(vm.isGeneratingFlashcards ? L10n.t("flashcards.generating")
                                                    : (vm.flashcards.isEmpty ? L10n.t("flashcards.generate")
                                                                             : L10n.t("flashcards.regenerate")),
                          systemImage: "sparkles")
                }
                .disabled(vm.isGeneratingFlashcards || (vm.session?.segments.isEmpty ?? true))
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                if vm.isGeneratingFlashcards {
                    VStack(alignment: .leading, spacing: 8) {
                        if !vm.transcriptTruncatedNotice.isEmpty {
                            LocalContextNotice(text: vm.transcriptTruncatedNotice)
                        }
                        Text(vm.streamingFlashcardsRaw.isEmpty ? L10n.t("common.loading") : vm.streamingFlashcardsRaw)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                } else if vm.flashcards.isEmpty {
                    EmptyStateView(systemImage: "rectangle.on.rectangle.angled",
                                   title: L10n.t("flashcards.empty.title"),
                                   message: L10n.t("flashcards.empty.desc"))
                        .frame(minHeight: 280)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        ForEach(Array(vm.flashcards.enumerated()), id: \.offset) { index, card in
                            FlashcardView(card: card, isRevealed: revealed.contains(index)) {
                                if revealed.contains(index) { revealed.remove(index) } else { revealed.insert(index) }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        // A new set is a new deck: indices from the old one mean nothing.
        .onChange(of: vm.flashcards.count) { _, _ in revealed = [] }
    }
}

private struct FlashcardView: View {
    let card: Flashcard
    let isRevealed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 10) {
                Text(card.front)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                if isRevealed {
                    Text(card.back)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Label(L10n.t("flashcards.showAnswer"), systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .cardBackground(radius: Theme.cornerLarge)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isRevealed ? L10n.t("flashcards.hideAnswer") : L10n.t("flashcards.showAnswer"))
    }
}

// MARK: - Study tools

struct StudyToolsPane: View {
    @ObservedObject var vm: SessionDetailViewModel

    var body: some View {
        HStack(spacing: 0) {
            List(StudyTools.all, selection: $vm.selectedStudyToolId) { tool in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Label(L10n.t(tool.labelKey), systemImage: tool.icon)
                            .font(.callout.weight(.medium))
                        Spacer()
                        if vm.studyToolResults.contains(where: { $0.toolId == tool.id }) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.success)
                        }
                    }
                    Text(L10n.t(tool.descriptionKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 3)
                .tag(tool.id)
            }
            .listStyle(.sidebar)
            .frame(width: 250)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    if let tool = vm.selectedStudyTool {
                        Label(L10n.t(tool.labelKey), systemImage: tool.icon).font(.headline)
                    }
                    Spacer()
                    Button {
                        Task { await vm.generateSelectedStudyTool() }
                    } label: {
                        Label(vm.isGeneratingStudyTool ? L10n.t("studyTools.generating")
                                                       : L10n.t("studyTools.generate"),
                              systemImage: "sparkles")
                    }
                    .disabled(vm.selectedStudyTool == nil || vm.isGeneratingStudyTool
                              || (vm.session?.segments.isEmpty ?? true))
                }
                .controlSize(.small)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                Divider()
                ScrollView {
                    if let markdown = vm.selectedStudyToolMarkdown, !markdown.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if vm.streamingStudyToolId == vm.selectedStudyToolId {
                                if !vm.transcriptTruncatedNotice.isEmpty {
                                    LocalContextNotice(text: vm.transcriptTruncatedNotice)
                                }
                                StreamingMarkdownPreview(markdown: markdown).textSelection(.enabled)
                            } else {
                                MarkdownView(markdown: markdown).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: Theme.readingWidth, alignment: .leading)
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    } else {
                        EmptyStateView(systemImage: "wand.and.stars",
                                       title: L10n.t("studyTools.title"),
                                       message: L10n.t("studyTools.empty"))
                            .frame(minHeight: 280)
                    }
                }
            }
        }
    }
}
