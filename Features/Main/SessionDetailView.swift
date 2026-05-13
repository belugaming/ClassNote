import SwiftUI
import AVFoundation

struct SessionDetailView: View {
    let sessionId: String
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = SessionDetailViewModel()
    @State private var selectedTab: DetailTab = .transcript

    enum DetailTab: String, CaseIterable, Identifiable {
        case transcript = "Bilingual transcript"
        case notes = "AI notes"
        case highlights = "Highlights"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $selectedTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)
            Divider()

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
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.session?.session.title ?? "…")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Text(vm.session?.session.state.capitalized ?? "")
                    if let s = vm.session?.session {
                        Text("·")
                        Text("\(s.sourceKind)")
                        Text("·")
                        Text(vm.durationLabel)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if vm.isPlaying {
                Button {
                    vm.stopPlayback()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
            } else if vm.hasAudio {
                Button {
                    vm.playFromBeginning()
                } label: {
                    Label("Play audio", systemImage: "play.circle")
                }
            }
            Button {
                Task { await vm.generateNotes() }
            } label: {
                Label(vm.isGeneratingNotes ? "Generating…" : "Generate AI notes",
                      systemImage: "sparkles")
            }
            .disabled(vm.isGeneratingNotes || (vm.session?.segments.isEmpty ?? true))
            Button {
                Task { await vm.retranslate() }
            } label: {
                Label(vm.isRetranslating ? "Retranslating…" : "Retranslate",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(vm.isRetranslating || (vm.session?.segments.isEmpty ?? true))
        }
        .padding(12)
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
                    ContentUnavailableView("No transcript yet",
                                            systemImage: "captions.bubble",
                                            description: Text("Start recording or import a video to populate the transcript."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(40)
                }
            }
            .padding(12)
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
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .frame(width: 56, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(segment.textOriginal)
                    .textSelection(.enabled)
                if !segment.textTranslated.isEmpty {
                    Text(segment.textTranslated)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.03))
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
        ScrollView {
            if let note = vm.note, !note.markdown.isEmpty {
                let rendered = (try? AttributedString(markdown: note.markdown,
                                                     options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(note.markdown)
                Text(rendered)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                ContentUnavailableView("No AI notes yet",
                                        systemImage: "sparkles",
                                        description: Text("Click 'Generate AI notes' to synthesize a structured markdown summary from the transcript."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
            }
        }
    }
}

struct HighlightsPane: View {
    @ObservedObject var vm: SessionDetailViewModel
    var body: some View {
        List(vm.highlights) { h in
            HStack {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
                Text(formatTs(h.timestampMs))
                    .font(.caption.monospacedDigit())
                Text(h.userNote.isEmpty ? "(marked)" : h.userNote)
            }
        }
        .overlay {
            if vm.highlights.isEmpty {
                ContentUnavailableView("No highlights",
                                        systemImage: "star",
                                        description: Text("Press ⌘⇧M during a live session or use the menubar button to mark a moment."))
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
