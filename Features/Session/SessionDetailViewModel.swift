import SwiftUI
import Combine
import AVFoundation
import UniformTypeIdentifiers
import AppKit

@MainActor
final class SessionDetailViewModel: ObservableObject {
    @Published var session: SessionWithSegments? {
        didSet {
            sentenceBlocks = session?.segments.sentenceBlocks ?? []
            updatePlayingSegment()
        }
    }
    /// The transcript grouped into sentences, once per change to it rather
    /// than on every redraw of the transcript (which follows every change to
    /// this object, a streamed token included).
    private(set) var sentenceBlocks: [SentenceBlock<Segment>] = []
    @Published var note: Note?
    @Published var noteVersions: [NoteVersion] = []
    @Published var highlights: [Highlight] = []
    @Published var isPlaying: Bool = false {
        didSet { updatePlayingSegment() }
    }
    @Published var qaMessages: [QAMessage] = []
    @Published var flashcards: [Flashcard] = []
    @Published var studyToolResults: [StudyToolResult] = []
    @Published var selectedStudyToolId: String? = StudyTools.all.first?.id

    /// The long jobs of the session on screen, which may have been started by
    /// an earlier view model of it; see `SessionJobState`.
    private var jobs: SessionJobState?
    private var jobsObservation: AnyCancellable?

    var isGeneratingNotes: Bool { jobs?.isGeneratingNotes ?? false }
    var streamingNoteMarkdown: String { jobs?.streamingNoteMarkdown ?? "" }
    /// The model's reasoning summary while it works, for engines that stream
    /// one (Claude), shown until the first words of the answer arrive.
    var streamingNoteThinking: String { jobs?.streamingNoteThinking ?? "" }
    var isRetranslating: Bool { jobs?.isRetranslating ?? false }
    var retranslateProgress: (done: Int, total: Int)? { jobs?.retranslateProgress }
    var isAnsweringQuestion: Bool { jobs?.isAnsweringQuestion ?? false }
    var streamingQAResponse: String { jobs?.streamingQAResponse ?? "" }
    var streamingQAThinking: String { jobs?.streamingQAThinking ?? "" }
    var isGeneratingFlashcards: Bool { jobs?.isGeneratingFlashcards ?? false }
    var streamingFlashcardsRaw: String { jobs?.streamingFlashcardsRaw ?? "" }
    var isGeneratingStudyTool: Bool { jobs?.isGeneratingStudyTool ?? false }
    var streamingStudyToolId: String? { jobs?.streamingStudyToolId }
    var streamingStudyToolMarkdown: String { jobs?.streamingStudyToolMarkdown ?? "" }
    /// Set while a local-model generation runs on a shortened transcript.
    var transcriptTruncatedNotice: String { jobs?.transcriptTruncatedNotice ?? "" }

    @Published var selectedHighlightId: Int64?
    @Published var streamingHighlightId: Int64?
    @Published var streamingBuffer: String = ""
    @Published var streamingHighlightThinking: String = ""

    /// Audio transport. `playheadMs` is written by the ticker, except while the
    /// user drags the scrubber.
    @Published private(set) var hasAudio: Bool = false
    /// The recording is only in iCloud and is being downloaded to play it.
    @Published private(set) var isDownloadingAudio = false
    /// The playhead lives in its own object: it moves ten times a second
    /// during playback, and as a property of this one it redrew every view of
    /// the session on each tick, the notes or answer being scrolled included.
    let clock = PlaybackClock()
    var playheadMs: Int64 {
        get { clock.playheadMs }
        set {
            clock.playheadMs = newValue
            updatePlayingSegment()
        }
    }
    @Published var playbackDurationMs: Int64 = 0
    @Published var isScrubbing = false

    /// Search-jump plumbing: the transcript scrolls to `pendingScrollSegmentId`
    /// once and flashes `flashSegmentId` for a moment afterwards.
    @Published var pendingScrollSegmentId: Int64?
    @Published var flashSegmentId: Int64?

    @Published private(set) var retryingSegmentIds: Set<Int64> = []
    /// An export is copying the recording, which may first have to come down
    /// from iCloud.
    @Published private(set) var isExporting = false

    @Published private(set) var course: Course?

    /// Characters per local-model pass. A 4B MLX model has a few thousand
    /// usable tokens and mixed English/Chinese runs ~3 characters per token,
    /// which leaves room for the answer on top of the transcript.
    private static let localChunkChars = 12_000
    private static let localPromptChars = 16_000

    private(set) var currentSessionId: String?
    private var courseContext: CourseContext = .empty
    private var player: AVAudioPlayer?
    private var playbackTicker: Task<Void, Never>?
    /// What was asked of the player while the recording downloads from iCloud.
    private var pendingPlayback: PendingPlayback?
    private let explanationService = HighlightExplanationService()
    private var streamingTask: Task<Void, Never>?

    /// Replaces the engine built from settings. Tests only.
    var llmOverride: LLMProvider?
    /// Stands in for iCloud Drive, so a test can play a recording that is
    /// only in the cloud. Tests only.
    var cloudFiles = CloudFileAccess()

    var selectedHighlight: Highlight? {
        guard let id = selectedHighlightId else { return nil }
        return highlights.first { $0.id == id }
    }

    var selectedStudyTool: StudyToolDefinition? {
        guard let id = selectedStudyToolId else { return nil }
        return StudyTools.find(id)
    }

    var selectedStudyToolResult: StudyToolResult? {
        guard let id = selectedStudyToolId else { return nil }
        return studyToolResults.first { $0.toolId == id }
    }

    var selectedStudyToolMarkdown: String? {
        if streamingStudyToolId == selectedStudyToolId {
            return streamingStudyToolMarkdown
        }
        return selectedStudyToolResult?.markdown
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

    var isSessionRecording: Bool { session?.session.state == "recording" }

    /// A note is being written for the session on screen. The job state is
    /// per session, so it is never another session's stream.
    var isShowingNoteStream: Bool { isGeneratingNotes }

    var failedTranslationCount: Int {
        (session?.segments ?? []).filter { !$0.translationState.isSettled && !$0.textOriginal.isEmpty }.count
    }

    /// Segment under the playhead, for the transcript highlight. Published
    /// only when the playhead crosses into another line.
    @Published private(set) var playingSegmentId: Int64?

    private func updatePlayingSegment() {
        var id: Int64?
        if isPlaying || playheadMs > 0, let segs = session?.segments {
            id = segs.last(where: { $0.startMs <= playheadMs })?.id
        }
        if id != playingSegmentId { playingSegmentId = id }
    }

    func load(sessionId: String) async {
        // A player still holding the previous session's file would keep playing
        // it under the new transcript.
        if currentSessionId != sessionId { stopPlayback() }
        currentSessionId = sessionId
        // Before the first await, so a job still running from an earlier view
        // of this session shows at once and cannot be started twice.
        watchJobs(of: sessionId)
        do {
            guard let stored = try await SessionRepository.shared.get(id: sessionId) else { return }
            let s = await SessionRepository.shared.relocatingMovedAudio(stored)
            let segs = try await SegmentRepository.shared.all(sessionId: sessionId)
            self.session = SessionWithSegments(session: s, segments: segs)
            // Stat the recording once per load instead of on every body pass —
            // the header reads this while note generation publishes per token.
            self.hasAudio = s.audioPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            // Seed the scrubber's range from the stored duration so it is live
            // before the first play; opening the file here would also grab the
            // iOS audio session out from under a still-recording session. A
            // player that is already open knows the file's exact length, so a
            // reload of the same session must not overwrite it.
            if self.hasAudio && self.playbackDurationMs == 0 {
                self.playbackDurationMs = s.durationMs
            }
            if let courseId = s.courseId {
                self.course = try await CourseRepository.shared.get(id: courseId)
            } else {
                self.course = nil
            }
            self.courseContext = CourseContext(course: self.course, session: s)
            self.note = try await NoteRepository.shared.get(sessionId: sessionId)
            self.noteVersions = try await NoteRepository.shared.versions(sessionId: sessionId)
            self.highlights = try await HighlightRepository.shared.all(sessionId: sessionId)
            self.flashcards = try await FlashcardRepository.shared.all(sessionId: sessionId)
            self.studyToolResults = try await StudyToolResultRepository.shared.all(sessionId: sessionId)
            self.qaMessages = try await QAMessageRepository.shared.all(sessionId: sessionId)
        } catch {
            NSLog("SessionDetail load error: \(error)")
        }
    }

    /// Shows the jobs of `sessionId`, whichever view model started them.
    private func watchJobs(of sessionId: String) {
        guard jobs?.sessionId != sessionId else { return }
        let state = SessionJobs.shared.state(for: sessionId)
        objectWillChange.send()
        jobs = state
        jobsObservation = state.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func makeLLM(config: ApiConfig, backend: LLMBackend) -> LLMProvider {
        llmOverride ?? EngineFactory.makeLLM(config: config, backend: backend)
    }

    // MARK: - Class background

    /// What the student said about this session; see `Session.briefing`.
    var briefing: String { session?.session.briefing ?? "" }

    /// The note template that suits this course's kind of class.
    var recommendedTemplate: NoteTemplate {
        NoteTemplates.find(course?.formatValue?.recommendedTemplateId ?? "study")
    }

    func saveBriefing(_ text: String) async {
        guard let current = session else { return }
        let sid = current.session.id
        do {
            try await SessionRepository.shared.setBriefing(sid, briefing: text)
            guard currentSessionId == sid, let latest = session, latest.session.id == sid else { return }
            var updated = latest.session
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.briefing = trimmed.isEmpty ? nil : trimmed
            session = SessionWithSegments(session: updated, segments: latest.segments)
            courseContext = CourseContext(course: course, session: updated)
        } catch {
            AppState.shared.setError(error.localizedDescription)
        }
    }

    /// Sets the course's kind of class, which every session of it shares.
    func setCourseFormat(_ format: CourseFormat?) async {
        guard var updated = course else { return }
        do {
            try await CourseRepository.shared.setFormat(updated.id, format: format)
            guard course?.id == updated.id else { return }
            updated.format = format?.rawValue
            course = updated
            courseContext = CourseContext(course: updated, session: session?.session)
        } catch {
            AppState.shared.setError(error.localizedDescription)
        }
    }

    /// The background of the last earlier session of this course, if it had one.
    func previousBriefing() async -> String? {
        guard let s = session?.session, let courseId = s.courseId else { return nil }
        return try? await SessionRepository.shared.previousBriefing(courseId: courseId, before: s)
    }

    /// A first draft of the session background, read off the transcript, for
    /// the student to correct rather than write from scratch.
    func briefingDraft(format: CourseFormat?) -> AsyncThrowingStream<String, Error> {
        guard let s = session, !s.segments.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        let config = AppState.shared.apiConfig
        let backend = AppState.shared.llmBackend
        let llm = makeLLM(config: config, backend: backend)
        var transcript = StudyTools.transcriptForLLM(s.segments)
        if backend == .localMLX {
            transcript = TranscriptChunker.truncate(text: transcript, maxChars: Self.localPromptChars).text
        }
        // The course as it stands, minus the background being drafted.
        var context = courseContext
        context.format = format
        context.sessionBriefing = ""
        let starters = (format?.briefingStarterKeys ?? CourseFormat.generalStarterKeys).map(L10n.t)
        let messages = LecturePrompt.messages(
            courseContext: context.promptBlock,
            transcript: transcript,
            instructions: BriefingPrompt.draftInstructions(labels: starters, chinese: L10n.isChinese))
        return llm.chat(messages: messages, model: config.activeLLMModel, temperature: 0.2)
    }

    func previewNoteVersion(_ version: NoteVersion) {
        self.note = Note(id: version.noteId,
                         sessionId: version.sessionId,
                         markdown: version.markdown,
                         version: version.version,
                         generatedAt: version.generatedAt,
                         model: version.model)
    }

    func deleteCurrentNote() async {
        guard let sid = currentSessionId else { return }
        do {
            try await NoteRepository.shared.delete(sessionId: sid)
            note = nil
            noteVersions = []
        } catch {
            AppState.shared.setError("Delete note failed: \(error.localizedDescription)")
        }
    }

    func generateNotes(template: NoteTemplate = NoteTemplates.find("study")) async {
        guard let s = session, !s.segments.isEmpty else { return }
        let target = s.session.id
        // One at a time per session, whichever view model asks: two runs would
        // both write version N+1.
        let job = SessionJobs.shared.state(for: target)
        guard !job.isGeneratingNotes else { return }
        // Everything the write needs is captured before the first await. The
        // published note and version list belong to whatever session the view
        // is showing when the stream ends, which may no longer be this one —
        // reading them afterwards is what moved a note between sessions.
        let currentNote: Note? = note?.sessionId == target ? note : nil
        let existingNoteId = currentNote?.id
        let baseVersion: Int64 = noteVersions.filter { $0.sessionId == target }.map(\.version).max()
            ?? currentNote?.version
            ?? 0
        job.isGeneratingNotes = true
        job.streamingNoteMarkdown = ""
        job.streamingNoteThinking = ""
        defer {
            job.isGeneratingNotes = false
            job.streamingNoteMarkdown = ""
            job.streamingNoteThinking = ""
            SessionJobs.shared.jobDidFinish(sessionId: target, by: self)
        }
        let config = AppState.shared.apiConfig
        let backend = AppState.shared.llmBackend
        let llm = makeLLM(config: config, backend: backend)
        let instructions = """
        You are an academic note-taking assistant for a Chinese student studying in the US.
        \(template.systemPrompt)
        Do NOT paraphrase the transcript word-for-word. Do synthesize and organize.
        """
        do {
            let md: String
            if backend == .localMLX {
                // A 4B model cannot hold a whole lecture, so the local path
                // goes part by part (no translations, to fit more per part)
                // and cannot share the opening the other features use.
                let system = courseContext.promptBlock.isEmpty
                    ? instructions
                    : courseContext.promptBlock + "\n\n" + instructions
                let transcriptText = s.segments.map { seg in
                    "[\(formatTimecode(seg.startMs))] \(seg.textOriginal)"
                }.joined(separator: "\n")
                md = try await generateNotesInParts(system: system,
                                                    transcript: transcriptText,
                                                    llm: llm,
                                                    config: config,
                                                    job: job)
            } else {
                md = try await streamNotePass(
                    messages: LecturePrompt.messages(courseContext: courseContext.promptBlock,
                                                     transcript: StudyTools.transcriptForLLM(s.segments),
                                                     instructions: instructions),
                    llm: llm,
                    config: config,
                    job: job,
                    header: "")
            }
            // Saved, an empty reply would become the current note.
            guard !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                AppState.shared.setError(L10n.t("notes.error.empty"))
                return
            }
            let noteEntity = Note(id: existingNoteId ?? UUID().uuidString,
                                   sessionId: target,
                                   markdown: md,
                                   version: baseVersion + 1,
                                   generatedAt: Int64(Date().timeIntervalSince1970 * 1000),
                                   model: config.activeLLMModel)
            try await NoteRepository.shared.upsert(noteEntity, template: template.id)
            try await SessionRepository.shared.setState(target, state: "summarized")
            guard currentSessionId == target else { return }   // persisted, just not on screen
            // `upsert` keys on the session, so the surviving row may carry an
            // id other than the one just built. Read into locals and re-check:
            // the user can switch sessions while these two reads are in flight.
            let freshNote = try await NoteRepository.shared.get(sessionId: target)
            let freshVersions = try await NoteRepository.shared.versions(sessionId: target)
            guard currentSessionId == target else { return }
            self.note = freshNote
            self.noteVersions = freshVersions
        } catch {
            AppState.shared.setError("Note generation failed: \(error.localizedDescription)")
        }
    }

    /// Map-reduce for the local sidecar: one pass per chunk, then a merge pass.
    /// A small model cannot hold a 90-minute lecture, and a single truncated
    /// pass would silently drop the second half of the class.
    private func generateNotesInParts(system: String,
                                      transcript: String,
                                      llm: LLMProvider,
                                      config: ApiConfig,
                                      job: SessionJobState) async throws -> String {
        let chunks = TranscriptChunker.split(text: transcript, maxChars: Self.localChunkChars)
        guard chunks.count > 1 else {
            return try await streamNotePass(messages: [
                                                .init(role: .system, content: system),
                                                .init(role: .user, content: "Transcript:\n\(chunks.first ?? transcript)"),
                                            ],
                                            llm: llm,
                                            config: config,
                                            job: job,
                                            header: "")
        }
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let header = String(format: L10n.t("notes.local.chunkProgress"),
                                "\(index + 1)", "\(chunks.count)")
            let part = try await streamNotePass(
                messages: [
                    .init(role: .system, content: system),
                    .init(role: .user, content: "Transcript (part \(index + 1) of \(chunks.count)):\n\(chunk)"),
                ],
                llm: llm,
                config: config,
                job: job,
                header: header)
            partials.append(part)
        }
        let mergeSystem = """
        \(system)

        You are given notes for consecutive parts of one lecture. Merge them into
        a single set of notes: keep every distinct point, drop repetition, and use
        one consistent heading structure. Never mention that the notes were merged
        or that the lecture was processed in parts.
        """
        let merged = partials.enumerated()
            .map { "## Part \($0.offset + 1)\n\($0.element)" }
            .joined(separator: "\n\n")
        return try await streamNotePass(messages: [
                                            .init(role: .system, content: mergeSystem),
                                            .init(role: .user, content: merged),
                                        ],
                                        llm: llm,
                                        config: config,
                                        job: job,
                                        header: L10n.t("notes.local.merging"))
    }

    /// One streaming pass, mirrored into the session's `streamingNoteMarkdown`
    /// under `header` so a multi-pass local run still looks alive.
    private func streamNotePass(messages: [ChatMessage],
                                llm: LLMProvider,
                                config: ApiConfig,
                                job: SessionJobState,
                                header: String) async throws -> String {
        var md = ""
        for try await event in llm.chatEvents(messages: messages, model: config.activeLLMModel, temperature: 0.3)
        {
            switch event {
            case .text(let delta):
                md += delta
                job.streamingNoteMarkdown = header.isEmpty ? md : header + "\n\n" + md
            case .thinking(let delta):
                job.streamingNoteThinking += delta
            }
        }
        return md
    }

    func askQuestion(_ question: String) async {
        guard let s = session, !s.segments.isEmpty else { return }
        let target = s.session.id
        let job = SessionJobs.shared.state(for: target)
        guard !job.isAnsweringQuestion else { return }
        job.isAnsweringQuestion = true
        job.streamingQAResponse = ""
        job.streamingQAThinking = ""
        defer {
            job.isAnsweringQuestion = false
            job.streamingQAResponse = ""
            job.streamingQAThinking = ""
            job.transcriptTruncatedNotice = ""
            SessionJobs.shared.jobDidFinish(sessionId: target, by: self)
        }
        let config = AppState.shared.apiConfig
        let llm = makeLLM(config: config, backend: AppState.shared.llmBackend)
        let transcriptText = budgetedTranscript(StudyTools.transcriptForLLM(s.segments), job: job)
        let createdAt = Int64(Date().timeIntervalSince1970 * 1000)
        let userMessage = QAMessage(id: UUID().uuidString,
                                    sessionId: target,
                                    role: .user,
                                    content: question,
                                    model: nil,
                                    createdAt: createdAt)
        let recentHistory = qaMessages.suffix(10)
        qaMessages.append(userMessage)
        let instructions = """
        You answer questions about one lecture transcript for a Chinese student studying in the US.
        Answer in Chinese, cite useful timecodes, and keep technical terms bilingual.
        If the transcript does not contain enough evidence, say so.
        """
        do {
            try await QAMessageRepository.shared.insert(userMessage)
            var answer = ""
            let history: [ChatMessage] = recentHistory.map { message in
                ChatMessage(role: message.role == .user ? .user : .assistant,
                            content: message.content)
            }
            let messages = LecturePrompt.messages(courseContext: courseContext.promptBlock,
                                                  transcript: transcriptText,
                                                  instructions: instructions,
                                                  followUp: history + [.init(role: .user, content: question)])
            for try await event in llm.chatEvents(messages: messages, model: config.activeLLMModel, temperature: 0.2)
            {
                switch event {
                case .text(let delta):
                    answer += delta
                    job.streamingQAResponse = answer
                case .thinking(let delta):
                    job.streamingQAThinking += delta
                }
            }
            let assistantMessage = QAMessage(id: UUID().uuidString,
                                             sessionId: target,
                                             role: .assistant,
                                             content: answer,
                                             model: config.activeLLMModel,
                                             createdAt: Int64(Date().timeIntervalSince1970 * 1000))
            try await QAMessageRepository.shared.insert(assistantMessage)
            guard currentSessionId == target else { return }
            qaMessages.append(assistantMessage)
        } catch {
            try? await QAMessageRepository.shared.delete(id: userMessage.id)
            // Only prune the in-memory list when it is still this session's —
            // otherwise the removal would hit whatever is on screen now.
            if currentSessionId == target {
                qaMessages.removeAll { $0.id == userMessage.id }
            }
            AppState.shared.setError("QA failed: \(error.localizedDescription)")
        }
    }

    func deleteQAMessage(_ message: QAMessage) async {
        do {
            try await QAMessageRepository.shared.delete(id: message.id)
            qaMessages.removeAll { $0.id == message.id }
        } catch {
            AppState.shared.setError("Delete QA message failed: \(error.localizedDescription)")
        }
    }

    func clearQAMessages() async {
        guard let sid = currentSessionId else { return }
        do {
            try await QAMessageRepository.shared.deleteAll(sessionId: sid)
            qaMessages = []
        } catch {
            AppState.shared.setError("Clear QA history failed: \(error.localizedDescription)")
        }
    }

    func generateFlashcards() async {
        guard let s = session, !s.segments.isEmpty else { return }
        let target = s.session.id
        let job = SessionJobs.shared.state(for: target)
        guard !job.isGeneratingFlashcards else { return }
        job.isGeneratingFlashcards = true
        job.streamingFlashcardsRaw = ""
        defer {
            job.isGeneratingFlashcards = false
            job.streamingFlashcardsRaw = ""
            job.transcriptTruncatedNotice = ""
            SessionJobs.shared.jobDidFinish(sessionId: target, by: self)
        }
        let config = AppState.shared.apiConfig
        let llm = makeLLM(config: config, backend: AppState.shared.llmBackend)
        let instructions = """
        Generate 8-12 high-value review flashcards from this lecture.
        Return one card per line exactly as: front || back
        Front should be a question or term. Back should be concise Chinese with key English terms preserved.
        """
        let messages = LecturePrompt.messages(courseContext: courseContext.promptBlock,
                                              transcript: budgetedTranscript(StudyTools.transcriptForLLM(s.segments),
                                                                             job: job),
                                              instructions: instructions)
        do {
            var raw = ""
            for try await delta in llm.chat(messages: messages, model: config.activeLLMModel, temperature: 0.25)
            {
                raw += delta
                job.streamingFlashcardsRaw = raw
            }
            let parsed = Self.parseFlashcards(raw,
                                              sessionId: target,
                                              model: config.activeLLMModel,
                                              createdAt: Int64(Date().timeIntervalSince1970 * 1000))
            // A reply in another shape (a table, Q:/A: pairs) or none at all
            // would otherwise replace the deck with nothing.
            guard !parsed.isEmpty else {
                AppState.shared.setError(L10n.t("flashcards.error.noCards"))
                return
            }
            try await FlashcardRepository.shared.replace(sessionId: target, cards: parsed)
            let fresh = try await FlashcardRepository.shared.all(sessionId: target)
            guard currentSessionId == target else { return }
            flashcards = fresh
        } catch {
            AppState.shared.setError("Flashcards failed: \(error.localizedDescription)")
        }
    }

    /// The cards in a reply, one `front || back` per line; other lines are
    /// skipped.
    static func parseFlashcards(_ raw: String, sessionId: String, model: String?, createdAt: Int64) -> [Flashcard] {
        var cards: [Flashcard] = []
        for line in raw.split(separator: "\n") {
            let parts = String(line).components(separatedBy: "||")
            guard parts.count >= 2 else { continue }
            let front = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let back = parts.dropFirst().joined(separator: "||").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !front.isEmpty, !back.isEmpty else { continue }
            cards.append(Flashcard(id: nil,
                                   sessionId: sessionId,
                                   front: front,
                                   back: back,
                                   sourceModel: model,
                                   createdAt: createdAt,
                                   sortOrder: cards.count))
        }
        return cards
    }

    func copyFlashcardsForAnki() {
        guard let session = self.session?.session else { return }
        let input = SessionExporter.Input(session: session,
                                           segments: self.session?.segments ?? [],
                                           note: self.note,
                                           highlights: self.highlights,
                                           flashcards: self.flashcards,
                                           studyToolResults: self.studyToolResults)
        Clipboard.copy(SessionExporter.flashcardsTSV(input))
    }

    func generateSelectedStudyTool() async {
        guard let s = session,
              !s.segments.isEmpty,
              let tool = selectedStudyTool else { return }
        let target = s.session.id
        let job = SessionJobs.shared.state(for: target)
        guard !job.isGeneratingStudyTool else { return }
        job.isGeneratingStudyTool = true
        job.streamingStudyToolId = tool.id
        job.streamingStudyToolMarkdown = ""
        defer {
            job.isGeneratingStudyTool = false
            job.streamingStudyToolId = nil
            job.streamingStudyToolMarkdown = ""
            job.transcriptTruncatedNotice = ""
            SessionJobs.shared.jobDidFinish(sessionId: target, by: self)
        }
        let config = AppState.shared.apiConfig
        let llm = makeLLM(config: config, backend: AppState.shared.llmBackend)
        let messages = LecturePrompt.messages(courseContext: courseContext.promptBlock,
                                              transcript: budgetedTranscript(StudyTools.transcriptForLLM(s.segments),
                                                                             job: job),
                                              instructions: tool.systemPrompt)
        do {
            var markdown = ""
            for try await delta in llm.chat(messages: messages, model: config.activeLLMModel, temperature: 0.25)
            {
                markdown += delta
                job.streamingStudyToolMarkdown = markdown
            }
            // Saved, an empty reply would replace this tool's last result.
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                AppState.shared.setError(L10n.t("studyTools.error.empty"))
                return
            }
            let result = StudyToolResult(id: UUID().uuidString,
                                         sessionId: target,
                                         toolId: tool.id,
                                         markdown: markdown,
                                         model: config.activeLLMModel,
                                         generatedAt: Int64(Date().timeIntervalSince1970 * 1000))
            try await StudyToolResultRepository.shared.upsert(result)
            let fresh = try await StudyToolResultRepository.shared.all(sessionId: target)
            guard currentSessionId == target else { return }
            studyToolResults = fresh
        } catch {
            AppState.shared.setError("Study tool failed: \(error.localizedDescription)")
        }
    }

    /// `failedOnly` covers just the rows whose translation never landed; the
    /// full pass stays for a language or model change.
    func retranslate(failedOnly: Bool) async {
        guard let sid = currentSessionId else { return }
        let job = SessionJobs.shared.state(for: sid)
        guard !job.isRetranslating else { return }
        job.isRetranslating = true
        job.retranslateProgress = (0, 0)
        defer {
            job.isRetranslating = false
            job.retranslateProgress = nil
            SessionJobs.shared.jobDidFinish(sessionId: sid, by: self)
        }
        do {
            // Its own orchestrator: the shared one belongs to the live
            // recording, whose state a batch pass must not touch.
            let worker = SessionOrchestrator()
            let stillFailed = try await worker.retranslateSession(
                sessionId: sid,
                failedOnly: failedOnly,
                onProgress: { done, total in job.retranslateProgress = (done, total) })
            guard currentSessionId == sid else { return }
            await load(sessionId: sid)
            if stillFailed > 0 {
                AppState.shared.setError(L10n.t("session.retranslate.partial"))
            }
        } catch {
            AppState.shared.setError("Retranslate failed: \(error.localizedDescription)")
        }
    }

    /// Retranslates a single row. A whole-session pass is the wrong tool when
    /// one sentence lost its stream to a hiccup.
    func retryTranslation(for segment: Segment) async {
        guard let rowId = segment.id,
              !segment.textOriginal.isEmpty,
              let sid = currentSessionId,
              !retryingSegmentIds.contains(rowId) else { return }
        retryingSegmentIds.insert(rowId)
        defer { retryingSegmentIds.remove(rowId) }
        // The whole sentence the line belongs to: a line cut mid-sentence has
        // no translation of its own to retry.
        if !(await SessionOrchestrator.retranslateSentence(containing: rowId, sessionId: sid)) {
            AppState.shared.setError(L10n.t("detail.translation.retryFailed"))
        }
        guard currentSessionId == sid, let current = session, current.session.id == sid else { return }
        if let segs = try? await SegmentRepository.shared.all(sessionId: sid) {
            guard currentSessionId == sid else { return }
            self.session = SessionWithSegments(session: current.session, segments: segs)
        }
    }

    // MARK: - Playback

    /// Lazily opens the session's recording. `AVAudioPlayerDelegate` needs an
    /// `NSObject` and nonisolated callbacks, so the end of the file is noticed
    /// by the ticker instead — the same idiom the orchestrator uses.
    private func ensurePlayer() -> AVAudioPlayer? {
        if let player { return player }
        // The file is still being written, the player bar is hidden (so there
        // is no Pause), and the microphone would record the playback.
        guard !isSessionRecording else { return nil }
        guard let path = session?.session.audioPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        // Opening a recording that is only in iCloud would block the UI for
        // the whole download. What the caller wanted is kept in
        // `pendingPlayback` and done once the file is here.
        if pendingPlayback != nil { return nil }
        if cloudFiles.needsDownload(url) {
            pendingPlayback = PendingPlayback()
            download(url)
            return nil
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            player = p
            playbackDurationMs = Int64(p.duration * 1000)
            return p
        } catch {
            AppState.shared.setError("Playback failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func download(_ url: URL) {
        isDownloadingAudio = true
        let sessionId = currentSessionId
        Task {
            do {
                try await cloudFiles.download(url)
                isDownloadingAudio = false
                // Unless another session is now on screen, or playback was
                // stopped meanwhile (which drops the request).
                guard currentSessionId == sessionId, let request = pendingPlayback else { return }
                pendingPlayback = nil
                guard let p = ensurePlayer() else { return }
                if let ms = request.positionMs {
                    p.currentTime = min(max(0, Double(ms) / 1000), p.duration)
                    playheadMs = Int64(p.currentTime * 1000)
                }
                if request.play {
                    p.play()
                    isPlaying = true
                    startTicker()
                }
            } catch {
                isDownloadingAudio = false
                pendingPlayback = nil
                AppState.shared.setError(error.localizedDescription)
            }
        }
    }

    func togglePlayPause() {
        guard let p = ensurePlayer() else {
            pendingPlayback?.togglePlay()
            return
        }
        if p.isPlaying {
            // Stop the ticker first: `pause()` clears `isPlaying`, which the
            // ticker would otherwise read as "reached the end".
            stopTicker()
            p.pause()
            isPlaying = false
        } else {
            p.play()
            isPlaying = true
            startTicker()
        }
    }

    /// Tapping a transcript line means "play from here", so this starts
    /// playback if it is not already running.
    func seek(to startMs: Int64) {
        guard let p = ensurePlayer() else {
            pendingPlayback?.seek(to: startMs)
            showPendingPosition()
            return
        }
        p.currentTime = min(max(0, Double(startMs) / 1000), p.duration)
        playheadMs = Int64(p.currentTime * 1000)
        if !p.isPlaying {
            p.play()
            isPlaying = true
            startTicker()
        }
    }

    /// Moves the playhead without deciding whether to play. Releasing the
    /// scrubber on a paused recording must leave it paused — `seek(to:)` is the
    /// other half of the pair, for "play from this line".
    func scrub(to ms: Int64) {
        guard let p = ensurePlayer() else {
            pendingPlayback?.scrub(to: ms)
            showPendingPosition()
            return
        }
        p.currentTime = min(max(0, Double(ms) / 1000), p.duration)
        playheadMs = Int64(p.currentTime * 1000)
    }

    /// Moves the playhead to where playback will start once the download
    /// ends, so ±10 s and the scrubber still answer meanwhile.
    private func showPendingPosition() {
        guard let ms = pendingPlayback?.positionMs else { return }
        playheadMs = playbackDurationMs > 0 ? min(max(0, ms), playbackDurationMs) : max(0, ms)
    }

    func stopPlayback() {
        stopTicker()
        pendingPlayback = nil
        player?.stop()
        player = nil
        isPlaying = false
        playheadMs = 0
        // Otherwise the next session's transport inherits this file's length:
        // `playbackDurationMs` is only rewritten when a player is opened.
        playbackDurationMs = 0
    }

    private func startTicker() {
        stopTicker()
        playbackTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let p = self.player else { return }
                if !self.isScrubbing { self.playheadMs = Int64(p.currentTime * 1000) }
                if !p.isPlaying {
                    // Reached the end: nothing calls back, so rewind here or
                    // the transport stays stuck on Pause forever.
                    p.currentTime = 0
                    self.isPlaying = false
                    self.playheadMs = 0
                    self.playbackTicker = nil
                    return
                }
            }
        }
    }

    private func stopTicker() {
        playbackTicker?.cancel()
        playbackTicker = nil
    }

    /// Consumes a search hit: scroll target plus a brief flash. Ignored when
    /// the hit belongs to a session this view model is not showing, or when the
    /// segment was deleted between the search and the click.
    func applyJump(_ target: SegmentJumpTarget?) {
        guard let target,
              target.sessionId == currentSessionId,
              session?.segments.contains(where: { $0.id == target.segmentId }) == true else { return }
        pendingScrollSegmentId = target.segmentId
        flashSegmentId = target.segmentId
    }

    // MARK: - Highlight explanation

    func deleteHighlight(_ h: Highlight) async {
        guard let id = h.id else { return }
        if selectedHighlightId == id { selectHighlight(nil) }
        do {
            try await HighlightRepository.shared.delete(id: id)
        } catch {
            AppState.shared.setError(error.localizedDescription)
        }
        await reloadHighlights()
    }

    func setHighlightNote(_ h: Highlight, note: String) async {
        guard let id = h.id else { return }
        try? await HighlightRepository.shared.setNote(id: id, note: note)
        await reloadHighlights()
    }

    /// Reloads the stored note, leaving a previewed older version.
    func showLatestNote() async {
        guard let sid = currentSessionId else { return }
        note = try? await NoteRepository.shared.get(sessionId: sid)
    }

    /// Whether `note` is an older version being previewed.
    var isPreviewingOldVersion: Bool {
        guard let note, let latest = noteVersions.map(\.version).max() else { return false }
        return note.version < latest
    }

    /// Picks up lines written since the last load, while the session is still
    /// recording. The detail used to be a snapshot taken when it opened.
    func refreshSegments() async {
        guard let sid = currentSessionId, let current = session else { return }
        guard let segs = try? await SegmentRepository.shared.all(sessionId: sid),
              currentSessionId == sid else { return }
        let fresh = (try? await SessionRepository.shared.get(id: sid)) ?? current.session
        session = SessionWithSegments(session: fresh, segments: segs)
    }

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
        streamingHighlightThinking = ""
        streamingHighlightId = highlightId
        let llm = makeLLM(config: config, backend: AppState.shared.llmBackend)
        // Captured now: a session switch mid-stream would otherwise explain
        // this range with another course's glossary.
        let coursePrompt = courseContext.promptBlock
        let transcript = Self.fitToEngine(StudyTools.transcriptForLLM(segments)).text
        let sessionId = currentSessionId

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await self.explanationService.generate(
                    rangeStartMs: range.start,
                    rangeEndMs: range.end,
                    allSegments: segments,
                    transcript: transcript,
                    preset: preset,
                    config: config,
                    llm: llm,
                    courseContext: coursePrompt)
                for try await event in stream {
                    if Task.isCancelled { return }
                    switch event {
                    case .text(let delta): self.streamingBuffer += delta
                    case .thinking(let delta): self.streamingHighlightThinking += delta
                    }
                }
                if Task.isCancelled { return }
                let final = self.streamingBuffer
                try await HighlightRepository.shared.updateExplanation(
                    id: highlightId,
                    rangeStartMs: range.start,
                    rangeEndMs: range.end,
                    promptKey: preset.key,
                    model: config.activeLLMModel,
                    markdown: final,
                    generatedAt: Int64(Date().timeIntervalSince1970 * 1000))
                self.streamingHighlightId = nil
                self.streamingBuffer = ""
                self.streamingHighlightThinking = ""
                await self.reloadHighlights()
                // Shown on a later visit to the session too; see `SessionJobs`.
                if let sessionId { SessionJobs.shared.jobDidFinish(sessionId: sessionId, by: self) }
            } catch is CancellationError {
                self.streamingHighlightId = nil
                self.streamingBuffer = ""
                self.streamingHighlightThinking = ""
            } catch {
                AppState.shared.setError("\(L10n.t("highlight.error.generateFailed")): \(error.localizedDescription)")
                self.streamingHighlightId = nil
                self.streamingBuffer = ""
                self.streamingHighlightThinking = ""
            }
        }
        streamingTask = task
    }

    private func reloadHighlights() async {
        guard let sid = currentSessionId else { return }
        if let fresh = try? await HighlightRepository.shared.all(sessionId: sid) {
            // The read is an await: the view may have moved to another session
            // while it was in flight.
            guard currentSessionId == sid else { return }
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
                                           highlights: self.highlights,
                                           flashcards: self.flashcards,
                                           studyToolResults: self.studyToolResults)
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
            case .flashcardsMarkdown:
                try saveTextWithPanel(content: SessionExporter.flashcardsMarkdown(input),
                                       suggestedName: SessionExporter.suggestedFilename(input, ext: "flashcards.md"),
                                       utType: .init(filenameExtension: "md") ?? .plainText)
            case .studyToolsMarkdown:
                try saveTextWithPanel(content: SessionExporter.studyToolsMarkdown(input),
                                       suggestedName: SessionExporter.suggestedFilename(input, ext: "study-tools.md"),
                                       utType: .init(filenameExtension: "md") ?? .plainText)
            case .audio:
                guard let path = session.audioPath,
                      FileManager.default.fileExists(atPath: path) else {
                    throw SessionExporter.ExportError.noAudio
                }
                let ext = (path as NSString).pathExtension.isEmpty ? "m4a" : (path as NSString).pathExtension
                guard let dest = chooseDestination(suggestedName: SessionExporter.suggestedFilename(input, ext: ext),
                                                   utType: .audio) else { return }
                exportInBackground {
                    try await SessionExporter.exportAudio(input, to: dest)
                    return dest
                }
            case .bundle:
                guard let url = chooseDestination(suggestedName: input.session.title, utType: .folder) else { return }
                exportInBackground { try await SessionExporter.exportBundle(input, to: url) }
            }
        } catch {
            AppState.shared.setError("\(L10n.t("session.export.failed")): \(error.localizedDescription)")
        }
    }

    private func saveTextWithPanel(content: String, suggestedName: String, utType: UTType) throws {
        guard let url = chooseDestination(suggestedName: suggestedName, utType: utType) else { return }
        try SessionExporter.writeText(content, to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func chooseDestination(suggestedName: String, utType: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [utType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// For an export that copies the recording, which may first have to come
    /// down from iCloud: it runs off the main actor while the ⋯ button shows
    /// progress, and the result is shown in Finder when it is written.
    private func exportInBackground(_ write: @escaping @Sendable () async throws -> URL) {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let written = try await write()
                NSWorkspace.shared.activateFileViewerSelecting([written])
            } catch {
                AppState.shared.setError("\(L10n.t("session.export.failed")): \(error.localizedDescription)")
            }
        }
    }

    private func formatTimecode(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    /// Transcript for a one-shot prompt. The cloud path is untouched; the local
    /// sidecar gets a head-and-tail shortening and the UI says so, because a
    /// silently halved lecture reads as a bad model rather than a full context.
    private func budgetedTranscript(_ text: String, job: SessionJobState) -> String {
        let result = Self.fitToEngine(text)
        job.transcriptTruncatedNotice = result.wasTruncated ? L10n.t("notes.local.truncated") : ""
        return result.text
    }

    /// The shortening alone, for a caller with no notice to show.
    private static func fitToEngine(_ text: String) -> (text: String, wasTruncated: Bool) {
        guard AppState.shared.llmBackend == .localMLX else { return (text, false) }
        return TranscriptChunker.truncate(text: text, maxChars: localPromptChars)
    }
}

struct SessionWithSegments {
    let session: Session
    let segments: [Segment]
}

/// Where playback is. Only the views that show the playhead observe it.
final class PlaybackClock: ObservableObject {
    @Published var playheadMs: Int64 = 0
}

/// What the transport was asked to do while the recording was still coming
/// down from iCloud: the last position asked for, and whether to play from
/// it. A scrub or ±10 s only moves it; Play, or a line clicked, also plays.
struct PendingPlayback: Equatable {
    var positionMs: Int64?
    var play = false

    mutating func togglePlay() { play.toggle() }

    mutating func seek(to ms: Int64) {
        positionMs = ms
        play = true
    }

    mutating func scrub(to ms: Int64) { positionMs = ms }
}

/// iCloud Drive as the player sees it; see `CloudFile`.
struct CloudFileAccess {
    var needsDownload: (URL) -> Bool = { CloudFile.needsDownload($0) }
    var download: @Sendable (URL) async throws -> Void = { try await CloudFile.ensureDownloaded($0) }
}
