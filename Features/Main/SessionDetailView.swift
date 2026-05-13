import SwiftUI
import AVFoundation

struct SessionDetailView: View {
    let sessionId: String
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = SessionDetailViewModel()
    @State private var selectedTab: DetailTab = .transcript

    enum DetailTab: String, CaseIterable, Identifiable {
        case transcript, notes, highlights
        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .transcript: return "session.tab.transcript"
            case .notes: return "session.tab.notes"
            case .highlights: return "session.tab.highlights"
            }
        }
        var icon: String {
            switch self {
            case .transcript: return "captions.bubble"
            case .notes: return "sparkles"
            case .highlights: return "star.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            Divider().opacity(0.5)
            Group {
                switch selectedTab {
                case .transcript: TranscriptPane(vm: vm)
                case .notes: NotesPane(vm: vm)
                case .highlights: HighlightsPane(vm: vm)
                }
            }
        }
        .task(id: sessionId) { await vm.load(sessionId: sessionId) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(vm.session?.session.title ?? "…")
                        .font(.title.weight(.semibold))
                    HStack(spacing: 6) {
                        if let s = vm.session?.session {
                            Text(stateLabel(s.state)).pill(stateColor(s.state))
                            Text(sourceLabel(s.sourceKind)).pill(Theme.accent)
                            Text(vm.durationLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()

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

                Button {
                    Task { await vm.generateNotes() }
                } label: {
                    Label(vm.isGeneratingNotes ? L10n.t("session.action.generatingNotes") : L10n.t("session.action.generateNotes"),
                          systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(vm.isGeneratingNotes || (vm.session?.segments.isEmpty ?? true))
            }
        }
        .padding(16)
    }

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                            Text(L10n.t(tab.titleKey))
                        }
                        .font(.callout.weight(selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedTab == tab ? Theme.accent : .secondary)
                        Rectangle()
                            .fill(selectedTab == tab ? Theme.accent : .clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .background(Color.primary.opacity(0.02))
    }

    private func stateLabel(_ s: String) -> String {
        switch s {
        case "recording": return L10n.t("session.state.recording")
        case "summarized": return L10n.t("session.state.summarized")
        case "transcribed": return L10n.t("session.state.transcribed")
        default: return s
        }
    }

    private func stateColor(_ s: String) -> Color {
        switch s {
        case "recording": return Theme.recording
        case "summarized": return Theme.success
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
            .padding(14)
        }
    }
}

struct SegmentRowView: View {
    let segment: Segment
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onTap()
            } label: {
                Text(formatTs(segment.startMs))
                    .monospacedDigit()
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accentSoft))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .frame(width: 68, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(segment.textOriginal)
                    .font(.body)
                    .textSelection(.enabled)
                if !segment.textTranslated.isEmpty {
                    Text(segment.textTranslated)
                        .font(.callout)
                        .foregroundStyle(Theme.translation)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(10)
        .cardBackground()
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
        ScrollView {
            if let note = vm.note, !note.markdown.isEmpty {
                let rendered = (try? AttributedString(markdown: note.markdown,
                                                     options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(note.markdown)
                Text(rendered)
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
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(vm.highlights) { h in
                            HStack(spacing: 10) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(Theme.accent)
                                Text(formatTs(h.timestampMs))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(h.userNote.isEmpty ? "—" : h.userNote)
                                    .font(.body)
                                Spacer()
                            }
                            .padding(10)
                            .cardBackground()
                        }
                    }
                    .padding(14)
                }
            }
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

@MainActor
final class SessionDetailViewModel: ObservableObject {
    @Published var session: SessionWithSegments?
    @Published var note: Note?
    @Published var highlights: [Highlight] = []
    @Published var isGeneratingNotes: Bool = false
    @Published var isRetranslating: Bool = false
    @Published var isPlaying: Bool = false

    private var currentSessionId: String?
    private var player: AVAudioPlayer?

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
            self.highlights = try await HighlightRepository.shared.all(sessionId: sessionId)
        } catch {
            NSLog("SessionDetail load error: \(error)")
        }
    }

    func generateNotes() async {
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
        Produce a structured Markdown study note from the lecture transcript below.
        Requirements:
        - Title (H1): try to infer a concrete topic.
        - Overview (3-5 bullets): what the lecture covered.
        - Sections (H2): break into logical sections of the lecture.
        - Key terms (bilingual): English term — 中文解释
        - Formulas / examples: include verbatim if present.
        - Questions & Answers (if any from the classroom).
        - Takeaways (bullets).
        Do NOT paraphrase the transcript word-for-word. Do synthesize and organize.
        Write in Chinese for the explanatory text; keep English terms in parentheses.
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
                                   version: (note?.version ?? 0) + 1,
                                   generatedAt: Int64(Date().timeIntervalSince1970 * 1000),
                                   model: config.llmModel)
            try await NoteRepository.shared.upsert(noteEntity)
            try await SessionRepository.shared.setState(s.session.id, state: "summarized")
            self.note = noteEntity
        } catch {
            AppState.shared.setError("Note generation failed: \(error.localizedDescription)")
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

    private func formatTimecode(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}

struct SessionWithSegments {
    let session: Session
    let segments: [Segment]
}
