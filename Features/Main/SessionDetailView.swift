import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

struct SessionDetailView: View {
    let sessionId: String
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = SessionDetailViewModel()
    @State private var selectedTab: DetailTab = .transcript

    enum DetailTab: String, CaseIterable, Identifiable {
        case transcript, notes, qa, flashcards, highlights
        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .transcript: return "session.tab.transcript"
            case .notes: return "session.tab.notes"
            case .qa: return "session.tab.qa"
            case .flashcards: return "session.tab.flashcards"
            case .highlights: return "session.tab.highlights"
            }
        }
        var icon: String {
            switch self {
            case .transcript: return "captions.bubble"
            case .notes: return "sparkles"
            case .qa: return "questionmark.bubble"
            case .flashcards: return "rectangle.stack"
            case .highlights: return "star.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            Group {
                switch selectedTab {
                case .transcript: TranscriptPane(vm: vm)
                case .notes: NotesPane(vm: vm)
                case .qa: QAPane(vm: vm)
                case .flashcards: FlashcardsPane(vm: vm)
                case .highlights: HighlightsPane(vm: vm)
                }
            }
            .background(Theme.surfaceElevated.opacity(0.25))
        }
        .task(id: sessionId) { await vm.load(sessionId: sessionId) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(vm.session?.session.title ?? "…")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                    metadataRow
                }
                Spacer(minLength: 16)

                Menu {
                    ForEach(NoteTemplates.all) { template in
                        Button {
                            Task { await vm.generateNotes(template: template) }
                        } label: {
                            Label(L10n.t(template.labelKey), systemImage: "sparkles")
                        }
                    }
                } label: {
                    Label(vm.isGeneratingNotes ? L10n.t("session.action.generatingNotes") : L10n.t("session.action.generateNotes"),
                          systemImage: "sparkles")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(vm.isGeneratingNotes || (vm.session?.segments.isEmpty ?? true))
            }

            HStack(spacing: 8) {
                if vm.isPlaying {
                    Button {
                        vm.stopPlayback()
                    } label: {
                        Label(L10n.t("session.action.stop"), systemImage: "stop.circle")
                    }
                } else if vm.hasAudio {
                    Button {
                        vm.playFromBeginning()
                    } label: {
                        Label(L10n.t("session.action.play"), systemImage: "play.circle")
                    }
                }

                Button {
                    Task { await vm.retranslate() }
                } label: {
                    Label(vm.isRetranslating ? L10n.t("session.action.retranslating") : L10n.t("session.action.retranslate"),
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(vm.isRetranslating || (vm.session?.segments.isEmpty ?? true))

                Spacer()

                Menu {
                    Button(L10n.t("session.export.transcriptMd"))   { vm.runExport(.transcriptMarkdown) }
                    Button(L10n.t("session.export.transcriptTxt"))  { vm.runExport(.transcriptPlain) }
                    Button(L10n.t("session.export.transcriptSrt"))  { vm.runExport(.transcriptSrt) }
                    Divider()
                    Button(L10n.t("session.export.notes"))          { vm.runExport(.notesMarkdown) }
                        .disabled(vm.note == nil)
                    Button(L10n.t("session.export.audio"))          { vm.runExport(.audio) }
                        .disabled(!vm.hasAudio)
                    Divider()
                    Button(L10n.t("session.export.bundle"))         { vm.runExport(.bundle) }
                } label: {
                    Label(L10n.t("session.action.export"), systemImage: "square.and.arrow.up")
                }
                .disabled(vm.session?.segments.isEmpty ?? true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(Theme.surfaceElevated.opacity(0.72))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 7) {
            if let s = vm.session?.session {
                Text(stateLabel(s.state)).pill(stateColor(s.state))
                Text(sourceLabel(s.sourceKind)).pill(Theme.accentMuted)
                Label(vm.durationLabel, systemImage: "clock")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 6) {
            ForEach(DetailTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                } label: {
                    Label(L10n.t(tab.titleKey), systemImage: tab.icon)
                        .font(.callout.weight(selectedTab == tab ? .semibold : .medium))
                        .foregroundStyle(selectedTab == tab ? Theme.accent : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                                .fill(selectedTab == tab ? Theme.accentSoft : Color.clear)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                                .stroke(selectedTab == tab ? Theme.accent.opacity(0.28) : Color.clear, lineWidth: 1)
                        }
                    }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.58))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
    }

    private func stateLabel(_ s: String) -> String {
        switch s {
        case "recording": return L10n.t("session.state.recording")
        case "summarized": return L10n.t("session.state.summarized")
        case "transcribed": return L10n.t("session.state.transcribed")
        case "interrupted": return L10n.t("session.state.interrupted")
        case "failed": return L10n.t("session.state.failed")
        case "ready": return L10n.t("session.state.transcribed")
        default: return s
        }
    }

    private func stateColor(_ s: String) -> Color {
        switch s {
        case "recording": return Theme.recording
        case "summarized": return Theme.success
        case "interrupted": return Theme.warning
        case "failed": return .red
        default: return .secondary
        }
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "system": return L10n.t("session.source.system")
        case "mixed": return L10n.t("session.source.mixed")
        case "file": return L10n.t("session.source.file")
        default: return L10n.t("session.source.mic")
        }
    }
}

struct TranscriptPane: View {
    @ObservedObject var vm: SessionDetailViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let segments = vm.session?.segments, !segments.isEmpty {
                    ForEach(segments) { seg in
                        SegmentRowView(segment: seg) {
                            vm.seek(to: seg.startMs)
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label(L10n.t("session.empty.transcript.title"), systemImage: "captions.bubble")
                    } description: {
                        Text(L10n.t("session.empty.transcript.desc"))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
    }
}

struct SegmentRowView: View {
    let segment: Segment
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                onTap()
            } label: {
                Text(formatTs(segment.startMs))
                    .monospacedDigit()
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                            .fill(Theme.accentSoft)
                    )
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .frame(width: 68, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(segment.textOriginal)
                    .font(.body)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                if !segment.textTranslated.isEmpty {
                    Text(segment.textTranslated)
                        .font(.callout)
                        .foregroundStyle(Theme.translation)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                .fill(Theme.surfaceElevated.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }

    private func formatTs(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}

struct NotesPane: View {
    @ObservedObject var vm: SessionDetailViewModel
    var body: some View {
        HSplitView {
            ScrollView {
                if let note = vm.note, !note.markdown.isEmpty {
                    MarkdownView(markdown: note.markdown)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                } else {
                    ContentUnavailableView {
                        Label(L10n.t("session.empty.notes.title"), systemImage: "sparkles")
                    } description: {
                        Text(L10n.t("session.empty.notes.desc"))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
                }
            }
            NoteHistoryPane(vm: vm)
                .frame(minWidth: 260, idealWidth: 320)
        }
    }
}

struct NoteHistoryPane: View {
    @ObservedObject var vm: SessionDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("notes.history.title"))
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            List(vm.noteVersions) { version in
                Button {
                    vm.previewNoteVersion(version)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(L10n.t(NoteTemplates.find(version.template).labelKey)) · v\(version.version)")
                            .font(.callout.weight(.medium))
                        Text(formatDate(version.generatedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func formatDate(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct QAPane: View {
    @ObservedObject var vm: SessionDetailViewModel
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if vm.qaAnswer.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.t("qa.empty.title"), systemImage: "questionmark.bubble")
                    } description: {
                        Text(L10n.t("qa.empty.desc"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                } else {
                    MarkdownView(markdown: vm.qaAnswer)
                        .textSelection(.enabled)
                        .padding(18)
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField(L10n.t("qa.placeholder"), text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button {
                    submit()
                } label: {
                    Label(vm.isAnsweringQuestion ? L10n.t("qa.answering") : L10n.t("qa.ask"),
                          systemImage: "paperplane")
                }
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isAnsweringQuestion)
            }
            .padding(12)
        }
    }

    private func submit() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Task { await vm.askQuestion(q) }
    }
}

struct FlashcardsPane: View {
    @ObservedObject var vm: SessionDetailViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("flashcards.title"))
                    .font(.headline)
                Spacer()
                Button {
                    Task { await vm.generateFlashcards() }
                } label: {
                    Label(vm.isGeneratingFlashcards ? L10n.t("flashcards.generating") : L10n.t("flashcards.generate"),
                          systemImage: "rectangle.stack.badge.plus")
                }
                .disabled(vm.isGeneratingFlashcards || (vm.session?.segments.isEmpty ?? true))
            }
            .padding(12)
            Divider()
            ScrollView {
                if vm.flashcards.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.t("flashcards.empty.title"), systemImage: "rectangle.stack")
                    } description: {
                        Text(L10n.t("flashcards.empty.desc"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(Array(vm.flashcards.enumerated()), id: \.offset) { _, card in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(card.front)
                                    .font(.headline)
                                Divider()
                                Text(card.back)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .cardBackground()
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

struct HighlightsPane: View {
    @ObservedObject var vm: SessionDetailViewModel
    var body: some View {
        Group {
            if vm.highlights.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("session.empty.highlights.title"), systemImage: "star")
                } description: {
                    Text(L10n.t("session.empty.highlights.desc"))
                }
            } else {
                HSplitView {
                    HighlightListPane(vm: vm)
                        .frame(minWidth: 220, idealWidth: 280)
                    HighlightDetailPane(vm: vm)
                        .frame(minWidth: 380)
                }
            }
        }
    }
}

struct HighlightListPane: View {
    @ObservedObject var vm: SessionDetailViewModel
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(vm.highlights) { h in
                    Button {
                        vm.selectHighlight(h.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(Theme.accent)
                            Text(formatTs(h.timestampMs))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if !h.userNote.isEmpty {
                                Text(h.userNote)
                                    .font(.callout)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if h.explanationMd != nil {
                                Image(systemName: "sparkles")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(vm.selectedHighlightId == h.id
                                      ? Theme.accentSoft
                                      : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }

    private func formatTs(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}

struct HighlightDetailPane: View {
    @ObservedObject var vm: SessionDetailViewModel

    var body: some View {
        if let h = vm.selectedHighlight {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailHeader(h)
                    rangePreview(h)
                    presetRow(h)
                    explanationArea(h)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(h.id)
        } else {
            ContentUnavailableView {
                Label(L10n.t("session.empty.highlights.title"), systemImage: "sparkles")
            } description: {
                Text(L10n.t("highlight.detail.empty"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func detailHeader(_ h: Highlight) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "star.fill").foregroundStyle(Theme.accent)
            Text(formatTs(h.timestampMs))
                .font(.title3.monospacedDigit().weight(.semibold))
            if let r = currentRange(h) {
                Text("\(L10n.t("highlight.detail.rangeLabel")) \(formatTs(r.start)) — \(formatTs(r.end))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                vm.shrinkRange(h)
            } label: {
                Label(L10n.t("highlight.detail.shrinkRange"), systemImage: "minus.magnifyingglass")
            }
            .disabled(!vm.canAdjustRange(h))
            Button {
                vm.expandRange(h)
            } label: {
                Label(L10n.t("highlight.detail.expandRange"), systemImage: "plus.magnifyingglass")
            }
            .disabled(!vm.canAdjustRange(h))
            if h.explanationMd != nil {
                Button {
                    Task { await vm.clearExplanation(h) }
                } label: {
                    Label(L10n.t("highlight.action.clear"), systemImage: "trash")
                }
            }
        }
        if !h.userNote.isEmpty {
            Text(h.userNote).font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func rangePreview(_ h: Highlight) -> some View {
        let segs = vm.segmentsForRange(h)
        if !segs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("highlight.detail.rangePreview"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(segs) { seg in
                    SegmentRowView(segment: seg) { vm.seek(to: seg.startMs) }
                }
            }
        }
    }

    @ViewBuilder
    private func presetRow(_ h: Highlight) -> some View {
        if vm.session?.segments.isEmpty == true {
            Label(L10n.t("highlight.error.noSegments"), systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        } else {
            HStack(spacing: 8) {
                ForEach(HighlightPrompts.all) { preset in
                    Button {
                        Task { await vm.runPreset(preset, on: h) }
                    } label: {
                        Text(L10n.t(preset.labelKey))
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .tint(h.explanationPrompt == preset.key ? Theme.accent : .secondary)
                    .disabled(vm.streamingHighlightId != nil)
                }
                if h.explanationPrompt != nil {
                    Spacer()
                    Button {
                        Task { await vm.regenerate(h) }
                    } label: {
                        Label(L10n.t("highlight.action.regenerate"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(vm.streamingHighlightId != nil)
                }
            }
        }
    }

    @ViewBuilder
    private func explanationArea(_ h: Highlight) -> some View {
        if vm.streamingHighlightId == h.id {
            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.t("highlight.status.streaming"), systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                Text(vm.streamingBuffer)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .cardBackground()
            }
        } else if let md = h.explanationMd, !md.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                let rendered = (try? AttributedString(markdown: md,
                                                       options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(md)
                Text(rendered)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .cardBackground()
                if let footer = explanationFooter(h) {
                    Text(footer).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(L10n.t("highlight.detail.pickPreset"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private func explanationFooter(_ h: Highlight) -> String? {
        guard let model = h.explanationModel,
              let key = h.explanationPrompt,
              let ts = h.explanationGeneratedAt else { return nil }
        let presetLabel = HighlightPrompts.find(key: key).map { L10n.t($0.labelKey) } ?? key
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return "\(model) · \(df.string(from: date)) · \(presetLabel)"
    }

    private func currentRange(_ h: Highlight) -> (start: Int64, end: Int64)? {
        if let s = h.rangeStartMs, let e = h.rangeEndMs { return (s, e) }
        return vm.previewRange(for: h)
    }

    private func formatTs(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}

@MainActor
final class SessionDetailViewModel: ObservableObject {
    @Published var session: SessionWithSegments?
    @Published var note: Note?
    @Published var noteVersions: [NoteVersion] = []
    @Published var highlights: [Highlight] = []
    @Published var isGeneratingNotes: Bool = false
    @Published var isRetranslating: Bool = false
    @Published var isPlaying: Bool = false
    @Published var isAnsweringQuestion: Bool = false
    @Published var qaAnswer: String = ""
    @Published var isGeneratingFlashcards: Bool = false
    @Published var flashcards: [Flashcard] = []

    @Published var selectedHighlightId: Int64?
    @Published var streamingHighlightId: Int64?
    @Published var streamingBuffer: String = ""

    private var currentSessionId: String?
    private var player: AVAudioPlayer?
    private let explanationService = HighlightExplanationService()
    private var streamingTask: Task<Void, Never>?

    var selectedHighlight: Highlight? {
        guard let id = selectedHighlightId else { return nil }
        return highlights.first { $0.id == id }
    }

    var durationLabel: String {
        guard let s = session?.session else { return "" }
        let ms = s.durationMs
        let sec = Int(ms / 1000)
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let ss = sec % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, ss) }
        return String(format: "%d:%02d", m, ss)
    }

    var hasAudio: Bool {
        guard let path = session?.session.audioPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    func load(sessionId: String) async {
        currentSessionId = sessionId
        do {
            guard let s = try await SessionRepository.shared.get(id: sessionId) else { return }
            let segs = try await SegmentRepository.shared.all(sessionId: sessionId)
            self.session = SessionWithSegments(session: s, segments: segs)
            self.note = try await NoteRepository.shared.get(sessionId: sessionId)
            self.noteVersions = try await NoteRepository.shared.versions(sessionId: sessionId)
            self.highlights = try await HighlightRepository.shared.all(sessionId: sessionId)
        } catch {
            NSLog("SessionDetail load error: \(error)")
        }
    }

    func previewNoteVersion(_ version: NoteVersion) {
        self.note = Note(id: version.noteId,
                         sessionId: version.sessionId,
                         markdown: version.markdown,
                         version: version.version,
                         generatedAt: version.generatedAt,
                         model: version.model)
    }

    func generateNotes(template: NoteTemplate = NoteTemplates.find("study")) async {
        guard let s = session, !s.segments.isEmpty else { return }
        isGeneratingNotes = true
        defer { isGeneratingNotes = false }
        let config = AppState.shared.apiConfig
        let llm = EngineFactory.makeLLM(config: config)
        let transcriptText = s.segments.map { seg in
            "[\(formatTimecode(seg.startMs))] \(seg.textOriginal)"
        }.joined(separator: "\n")

        let system = """
        You are an academic note-taking assistant for a Chinese student studying in the US.
        \(template.systemPrompt)
        Do NOT paraphrase the transcript word-for-word. Do synthesize and organize.
        """
        let user = "Transcript:\n\(transcriptText)"
        do {
            let md = try await llm.chatComplete(messages: [
                .init(role: .system, content: system),
                .init(role: .user, content: user)
            ], model: config.llmModel, temperature: 0.3)

            let noteEntity = Note(id: note?.id ?? UUID().uuidString,
                                   sessionId: s.session.id,
                                   markdown: md,
                                   version: ((noteVersions.map(\.version).max() ?? note?.version) ?? 0) + 1,
                                   generatedAt: Int64(Date().timeIntervalSince1970 * 1000),
                                   model: config.llmModel)
            try await NoteRepository.shared.upsert(noteEntity, template: template.id)
            try await SessionRepository.shared.setState(s.session.id, state: "summarized")
            self.note = noteEntity
            self.noteVersions = try await NoteRepository.shared.versions(sessionId: s.session.id)
        } catch {
            AppState.shared.setError("Note generation failed: \(error.localizedDescription)")
        }
    }

    func askQuestion(_ question: String) async {
        guard let s = session, !s.segments.isEmpty else { return }
        isAnsweringQuestion = true
        defer { isAnsweringQuestion = false }
        let config = AppState.shared.apiConfig
        let llm = EngineFactory.makeLLM(config: config)
        let transcriptText = transcriptForLLM(s.segments)
        do {
            qaAnswer = try await llm.chatComplete(messages: [
                .init(role: .system, content: """
                You answer questions about one lecture transcript for a Chinese student studying in the US.
                Answer in Chinese, cite useful timecodes, and keep technical terms bilingual.
                If the transcript does not contain enough evidence, say so.
                """),
                .init(role: .user, content: "Question:\n\(question)\n\nTranscript:\n\(transcriptText)")
            ], model: config.llmModel, temperature: 0.2)
        } catch {
            AppState.shared.setError("QA failed: \(error.localizedDescription)")
        }
    }

    func generateFlashcards() async {
        guard let s = session, !s.segments.isEmpty else { return }
        isGeneratingFlashcards = true
        defer { isGeneratingFlashcards = false }
        let config = AppState.shared.apiConfig
        let llm = EngineFactory.makeLLM(config: config)
        do {
            let raw = try await llm.chatComplete(messages: [
                .init(role: .system, content: """
                Generate 8-12 high-value review flashcards from this lecture.
                Return one card per line exactly as: front || back
                Front should be a question or term. Back should be concise Chinese with key English terms preserved.
                """),
                .init(role: .user, content: transcriptForLLM(s.segments))
            ], model: config.llmModel, temperature: 0.25)
            flashcards = raw
                .split(separator: "\n")
                .compactMap { line in
                    let parts = line.components(separatedBy: "||")
                    guard parts.count >= 2 else { return nil }
                    return Flashcard(front: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                                     back: parts.dropFirst().joined(separator: "||").trimmingCharacters(in: .whitespacesAndNewlines))
                }
        } catch {
            AppState.shared.setError("Flashcards failed: \(error.localizedDescription)")
        }
    }

    func retranslate() async {
        guard let sid = currentSessionId else { return }
        isRetranslating = true
        defer { isRetranslating = false }
        do {
            try await AppState.shared.orchestrator.retranslateSession(sessionId: sid)
            await load(sessionId: sid)
        } catch {
            AppState.shared.setError("Retranslate failed: \(error.localizedDescription)")
        }
    }

    func seek(to startMs: Int64) {
        guard let path = session?.session.audioPath,
              FileManager.default.fileExists(atPath: path) else { return }
        do {
            if player == nil {
                player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
                player?.prepareToPlay()
            }
            player?.currentTime = Double(startMs) / 1000
            player?.play()
            isPlaying = true
        } catch {
            AppState.shared.setError("Playback failed: \(error.localizedDescription)")
        }
    }

    func playFromBeginning() {
        guard let path = session?.session.audioPath,
              FileManager.default.fileExists(atPath: path) else { return }
        do {
            player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player?.prepareToPlay()
            player?.play()
            isPlaying = true
        } catch {
            AppState.shared.setError("Playback failed: \(error.localizedDescription)")
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    // MARK: - Highlight explanation

    func selectHighlight(_ id: Int64?) {
        if streamingHighlightId != nil && streamingHighlightId != id {
            streamingTask?.cancel()
            streamingTask = nil
            streamingHighlightId = nil
            streamingBuffer = ""
        }
        selectedHighlightId = id
    }

    func segmentsForRange(_ h: Highlight) -> [Segment] {
        guard let all = session?.segments, !all.isEmpty else { return [] }
        let range = h.rangeStartMs.flatMap { s in h.rangeEndMs.map { (s, $0) } }
            ?? HighlightRange.compute(timestampMs: h.timestampMs, segments: all)
        guard let r = range else { return [] }
        return all.filter { $0.startMs <= r.1 && $0.endMs >= r.0 }
    }

    func previewRange(for h: Highlight) -> (start: Int64, end: Int64)? {
        guard let all = session?.segments else { return nil }
        return HighlightRange.compute(timestampMs: h.timestampMs, segments: all)
    }

    func canAdjustRange(_ h: Highlight) -> Bool {
        guard let all = session?.segments else { return false }
        return !all.isEmpty && streamingHighlightId == nil
    }

    func expandRange(_ h: Highlight) {
        guard let id = h.id, let all = session?.segments else { return }
        let current = h.rangeStartMs.flatMap { s in h.rangeEndMs.map { (s, $0) } }
            ?? HighlightRange.compute(timestampMs: h.timestampMs, segments: all)
        guard let r = current else { return }
        let next = HighlightRange.expand(currentRange: r, segments: all)
        Task {
            try? await HighlightRepository.shared.updateRange(id: id,
                                                                rangeStartMs: next.start,
                                                                rangeEndMs: next.end)
            await reloadHighlights()
        }
    }

    func shrinkRange(_ h: Highlight) {
        guard let id = h.id, let all = session?.segments else { return }
        let current = h.rangeStartMs.flatMap { s in h.rangeEndMs.map { (s, $0) } }
            ?? HighlightRange.compute(timestampMs: h.timestampMs, segments: all)
        guard let r = current else { return }
        let next = HighlightRange.shrink(currentRange: r, segments: all)
        Task {
            try? await HighlightRepository.shared.updateRange(id: id,
                                                                rangeStartMs: next.start,
                                                                rangeEndMs: next.end)
            await reloadHighlights()
        }
    }

    func runPreset(_ preset: PromptPreset, on h: Highlight) async {
        guard let id = h.id, let all = session?.segments, !all.isEmpty else { return }
        let range: (start: Int64, end: Int64)
        if let s = h.rangeStartMs, let e = h.rangeEndMs {
            range = (s, e)
        } else if let computed = HighlightRange.compute(timestampMs: h.timestampMs, segments: all) {
            range = computed
        } else {
            return
        }
        await stream(highlightId: id, range: range, preset: preset, segments: all)
    }

    func regenerate(_ h: Highlight) async {
        guard let id = h.id,
              let key = h.explanationPrompt,
              let preset = HighlightPrompts.find(key: key),
              let all = session?.segments, !all.isEmpty,
              let s = h.rangeStartMs, let e = h.rangeEndMs else { return }
        await stream(highlightId: id, range: (s, e), preset: preset, segments: all)
    }

    func clearExplanation(_ h: Highlight) async {
        guard let id = h.id else { return }
        try? await HighlightRepository.shared.clearExplanation(id: id)
        await reloadHighlights()
    }

    private func stream(highlightId: Int64,
                        range: (start: Int64, end: Int64),
                        preset: PromptPreset,
                        segments: [Segment]) async {
        streamingTask?.cancel()
        let config = AppState.shared.apiConfig
        streamingBuffer = ""
        streamingHighlightId = highlightId

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await self.explanationService.generate(
                    rangeStartMs: range.start,
                    rangeEndMs: range.end,
                    allSegments: segments,
                    preset: preset,
                    config: config)
                for try await delta in stream {
                    if Task.isCancelled { return }
                    self.streamingBuffer += delta
                }
                if Task.isCancelled { return }
                let final = self.streamingBuffer
                try await HighlightRepository.shared.updateExplanation(
                    id: highlightId,
                    rangeStartMs: range.start,
                    rangeEndMs: range.end,
                    promptKey: preset.key,
                    model: config.llmModel,
                    markdown: final,
                    generatedAt: Int64(Date().timeIntervalSince1970 * 1000))
                self.streamingHighlightId = nil
                self.streamingBuffer = ""
                await self.reloadHighlights()
            } catch is CancellationError {
                self.streamingHighlightId = nil
                self.streamingBuffer = ""
            } catch {
                AppState.shared.setError("\(L10n.t("highlight.error.generateFailed")): \(error.localizedDescription)")
                self.streamingHighlightId = nil
                self.streamingBuffer = ""
            }
        }
        streamingTask = task
    }

    private func reloadHighlights() async {
        guard let sid = currentSessionId else { return }
        if let fresh = try? await HighlightRepository.shared.all(sessionId: sid) {
            self.highlights = fresh
        }
    }

    // MARK: - Export

    func runExport(_ kind: SessionExporter.Kind) {
        guard let session = self.session?.session,
              let segments = self.session?.segments else { return }
        let input = SessionExporter.Input(session: session,
                                           segments: segments,
                                           note: self.note,
                                           highlights: self.highlights)
        do {
            switch kind {
            case .transcriptMarkdown:
                try saveTextWithPanel(content: SessionExporter.transcriptMarkdown(input),
                                       suggestedName: SessionExporter.suggestedFilename(input, ext: "md"),
                                       utType: .init(filenameExtension: "md") ?? .plainText)
            case .transcriptPlain:
                try saveTextWithPanel(content: SessionExporter.transcriptPlain(input),
                                       suggestedName: SessionExporter.suggestedFilename(input, ext: "txt"),
                                       utType: .plainText)
            case .transcriptSrt:
                try saveTextWithPanel(content: SessionExporter.transcriptSRT(input),
                                       suggestedName: SessionExporter.suggestedFilename(input, ext: "srt"),
                                       utType: .init(filenameExtension: "srt") ?? .plainText)
            case .notesMarkdown:
                guard let note = self.note, !note.markdown.isEmpty else {
                    throw SessionExporter.ExportError.noNotes
                }
                try saveTextWithPanel(content: note.markdown,
                                       suggestedName: SessionExporter.suggestedFilename(input, ext: "md"),
                                       utType: .init(filenameExtension: "md") ?? .plainText)
            case .audio:
                guard let path = session.audioPath,
                      FileManager.default.fileExists(atPath: path) else {
                    throw SessionExporter.ExportError.noAudio
                }
                let ext = (path as NSString).pathExtension.isEmpty ? "m4a" : (path as NSString).pathExtension
                try saveFileWithPanel(suggestedName: SessionExporter.suggestedFilename(input, ext: ext),
                                       utType: .audio) { dest in
                    try SessionExporter.copyAudio(from: input, to: dest)
                }
            case .bundle:
                try saveBundleWithPanel(input: input, suggestedFolderName: input.session.title)
            }
        } catch {
            AppState.shared.setError("\(L10n.t("session.export.failed")): \(error.localizedDescription)")
        }
    }

    private func saveTextWithPanel(content: String, suggestedName: String, utType: UTType) throws {
        try saveFileWithPanel(suggestedName: suggestedName, utType: utType) { dest in
            try SessionExporter.writeText(content, to: dest)
        }
    }

    private func saveFileWithPanel(suggestedName: String,
                                    utType: UTType,
                                    write: (URL) throws -> Void) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [utType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try write(url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func saveBundleWithPanel(input: SessionExporter.Input, suggestedFolderName: String) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFolderName
        panel.allowedContentTypes = [.folder]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try SessionExporter.writeBundle(input, to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func formatTimecode(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    private func transcriptForLLM(_ segments: [Segment]) -> String {
        segments.map { seg in
            "[\(formatTimecode(seg.startMs))] \(seg.textOriginal)" +
            (seg.textTranslated.isEmpty ? "" : "\n译文: \(seg.textTranslated)")
        }.joined(separator: "\n")
    }
}

struct SessionWithSegments {
    let session: Session
    let segments: [Segment]
}

struct Flashcard: Hashable {
    let front: String
    let back: String
}
