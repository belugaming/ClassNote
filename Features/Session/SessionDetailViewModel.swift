import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit

@MainActor
final class SessionDetailViewModel: ObservableObject {
    @Published var session: SessionWithSegments?
    @Published var note: Note?
    @Published var noteVersions: [NoteVersion] = []
    @Published var highlights: [Highlight] = []
    @Published var isGeneratingNotes: Bool = false
    @Published var streamingNoteMarkdown: String = ""
    @Published var isRetranslating: Bool = false
    @Published var isPlaying: Bool = false
    @Published var isAnsweringQuestion: Bool = false
    @Published var qaMessages: [QAMessage] = []
    @Published var streamingQAResponse: String = ""
    @Published var isGeneratingFlashcards: Bool = false
    @Published var streamingFlashcardsRaw: String = ""
    @Published var flashcards: [Flashcard] = []
    @Published var studyToolResults: [StudyToolResult] = []
    @Published var selectedStudyToolId: String? = StudyTools.all.first?.id
    @Published var isGeneratingStudyTool: Bool = false
    @Published var streamingStudyToolId: String?
    @Published var streamingStudyToolMarkdown: String = ""

    @Published var selectedHighlightId: Int64?
    @Published var streamingHighlightId: Int64?
    @Published var streamingBuffer: String = ""

    /// Audio transport. `playheadMs` is written by the ticker, except while the
    /// user drags the scrubber.
    @Published private(set) var hasAudio: Bool = false
    @Published var playheadMs: Int64 = 0
    @Published var playbackDurationMs: Int64 = 0
    @Published var isScrubbing = false

    /// Search-jump plumbing: the transcript scrolls to `pendingScrollSegmentId`
    /// once and flashes `flashSegmentId` for a moment afterwards.
    @Published var pendingScrollSegmentId: Int64?
    @Published var flashSegmentId: Int64?

    @Published var retranslateProgress: (done: Int, total: Int)?
    @Published private(set) var retryingSegmentIds: Set<Int64> = []

    /// Which session the in-flight note generation belongs to. The view model
    /// outlives a session switch, so the stream must not be painted into
    /// whatever session the user moved on to.
    @Published private(set) var notesGenerationSessionId: String?
    /// Set while a local-model generation runs on a shortened transcript.
    @Published private(set) var transcriptTruncatedNotice: String = ""
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
    private let explanationService = HighlightExplanationService()
    private var streamingTask: Task<Void, Never>?

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

    /// True only while the stream on screen belongs to the session on screen.
    var isShowingNoteStream: Bool {
        isGeneratingNotes && notesGenerationSessionId == currentSessionId
    }

    var failedTranslationCount: Int {
        (session?.segments ?? []).filter { !$0.translationState.isSettled && !$0.textOriginal.isEmpty }.count
    }

    /// Segment under the playhead, for the transcript highlight.
    var playingSegmentId: Int64? {
        guard isPlaying || playheadMs > 0, let segs = session?.segments else { return nil }
        return segs.last(where: { $0.startMs <= playheadMs })?.id
    }

    func load(sessionId: String) async {
        // A player still holding the previous session's file would keep playing
        // it under the new transcript.
        if currentSessionId != sessionId { stopPlayback() }
        currentSessionId = sessionId
        do {
            guard let s = try await SessionRepository.shared.get(id: sessionId) else { return }
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
            self.courseContext = CourseContext(course: self.course)
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
            streamingNoteMarkdown = ""
        } catch {
            AppState.shared.setError("Delete note failed: \(error.localizedDescription)")
        }
    }

    func generateNotes(template: NoteTemplate = NoteTemplates.find("study")) async {
        guard let s = session, !s.segments.isEmpty else { return }
        // Everything the write needs is captured before the first await. The
        // published note and version list belong to whatever session the view
        // is showing when the stream ends, which may no longer be this one —
        // reading them afterwards is what moved a note between sessions.
        let target = s.session.id
        let currentNote: Note? = note?.sessionId == target ? note : nil
        let existingNoteId = currentNote?.id
        let baseVersion: Int64 = noteVersions.filter { $0.sessionId == target }.map(\.version).max()
            ?? currentNote?.version
            ?? 0
        isGeneratingNotes = true
        notesGenerationSessionId = target
        streamingNoteMarkdown = ""
        defer {
            isGeneratingNotes = false
            notesGenerationSessionId = nil
            streamingNoteMarkdown = ""
        }
        let config = AppState.shared.apiConfig
        let backend = AppState.shared.llmBackend
        let llm = EngineFactory.makeLLM(config: config, backend: backend)
        let transcriptText = s.segments.map { seg in
            "[\(formatTimecode(seg.startMs))] \(seg.textOriginal)"
        }.joined(separator: "\n")

        var system = """
        You are an academic note-taking assistant for a Chinese student studying in the US.
        \(template.systemPrompt)
        Do NOT paraphrase the transcript word-for-word. Do synthesize and organize.
        """
        if !courseContext.promptBlock.isEmpty {
            system = courseContext.promptBlock + "\n\n" + system
        }
        do {
            let md: String
            if backend == .localMLX {
                md = try await generateNotesInParts(system: system,
                                                    transcript: transcriptText,
                                                    llm: llm,
                                                    config: config,
                                                    target: target)
            } else {
                md = try await streamNotePass(system: system,
                                              user: "Transcript:\n\(transcriptText)",
                                              llm: llm,
                                              config: config,
                                              target: target,
                                              header: "")
            }
            let noteEntity = Note(id: existingNoteId ?? UUID().uuidString,
                                   sessionId: target,
                                   markdown: md,
                                   version: baseVersion + 1,
                                   generatedAt: Int64(Date().timeIntervalSince1970 * 1000),
                                   model: config.llmModel)
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
                                      target: String) async throws -> String {
        let chunks = TranscriptChunker.split(text: transcript, maxChars: Self.localChunkChars)
        guard chunks.count > 1 else {
            return try await streamNotePass(system: system,
                                            user: "Transcript:\n\(chunks.first ?? transcript)",
                                            llm: llm,
                                            config: config,
                                            target: target,
                                            header: "")
        }
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let header = String(format: L10n.t("notes.local.chunkProgress"),
                                "\(index + 1)", "\(chunks.count)")
            let part = try await streamNotePass(
                system: system,
                user: "Transcript (part \(index + 1) of \(chunks.count)):\n\(chunk)",
                llm: llm,
                config: config,
                target: target,
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
        return try await streamNotePass(system: mergeSystem,
                                        user: merged,
                                        llm: llm,
                                        config: config,
                                        target: target,
                                        header: L10n.t("notes.local.merging"))
    }

    /// One streaming pass, mirrored into `streamingNoteMarkdown` under `header`
    /// so a multi-pass local run still looks alive. Publishes only while the
    /// session it belongs to is the one on screen.
    private func streamNotePass(system: String,
                                user: String,
                                llm: LLMProvider,
                                config: ApiConfig,
                                target: String,
                                header: String) async throws -> String {
        var md = ""
        for try await delta in llm.chat(messages: [
            .init(role: .system, content: system),
            .init(role: .user, content: user)
        ], model: config.llmModel, temperature: 0.3)
        {
            md += delta
            guard currentSessionId == target else { continue }
            streamingNoteMarkdown = header.isEmpty ? md : header + "\n\n" + md
        }
        return md
    }

    func askQuestion(_ question: String) async {
        guard let s = session, !s.segments.isEmpty else { return }
        let target = s.session.id
        isAnsweringQuestion = true
        streamingQAResponse = ""
        defer {
            isAnsweringQuestion = false
            streamingQAResponse = ""
            transcriptTruncatedNotice = ""
        }
        let config = AppState.shared.apiConfig
        let llm = EngineFactory.makeLLM(config: config, backend: AppState.shared.llmBackend)
        let transcriptText = budgetedTranscript(transcriptForLLM(s.segments))
        let createdAt = Int64(Date().timeIntervalSince1970 * 1000)
        let userMessage = QAMessage(id: UUID().uuidString,
                                    sessionId: target,
                                    role: .user,
                                    content: question,
                                    model: nil,
                                    createdAt: createdAt)
        let recentHistory = qaMessages.suffix(10)
        qaMessages.append(userMessage)
        var system = """
        You answer questions about one lecture transcript for a Chinese student studying in the US.
        Answer in Chinese, cite useful timecodes, and keep technical terms bilingual.
        If the transcript does not contain enough evidence, say so.
        """
        if !courseContext.promptBlock.isEmpty {
            system = courseContext.promptBlock + "\n\n" + system
        }
        do {
            try await QAMessageRepository.shared.insert(userMessage)
            var answer = ""
            let messages = [
                .init(role: .system, content: system),
                .init(role: .user, content: "Lecture transcript:\n\(transcriptText)")
            ] + recentHistory.map { message in
                ChatMessage(role: message.role == .user ? .user : .assistant,
                            content: message.content)
            } + [
                .init(role: .user, content: question)
            ]
            for try await delta in llm.chat(messages: messages, model: config.llmModel, temperature: 0.2)
            {
                answer += delta
                guard currentSessionId == target else { continue }
                streamingQAResponse = answer
            }
            let assistantMessage = QAMessage(id: UUID().uuidString,
                                             sessionId: target,
                                             role: .assistant,
                                             content: answer,
                                             model: config.llmModel,
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
            streamingQAResponse = ""
        } catch {
            AppState.shared.setError("Clear QA history failed: \(error.localizedDescription)")
        }
    }

    func generateFlashcards() async {
        guard let s = session, !s.segments.isEmpty else { return }
        let target = s.session.id
        isGeneratingFlashcards = true
        streamingFlashcardsRaw = ""
        defer {
            isGeneratingFlashcards = false
            streamingFlashcardsRaw = ""
            transcriptTruncatedNotice = ""
        }
        let config = AppState.shared.apiConfig
        let llm = EngineFactory.makeLLM(config: config, backend: AppState.shared.llmBackend)
        var system = """
        Generate 8-12 high-value review flashcards from this lecture.
        Return one card per line exactly as: front || back
        Front should be a question or term. Back should be concise Chinese with key English terms preserved.
        """
        if !courseContext.promptBlock.isEmpty {
            system = courseContext.promptBlock + "\n\n" + system
        }
        do {
            var raw = ""
            for try await delta in llm.chat(messages: [
                .init(role: .system, content: system),
                .init(role: .user, content: budgetedTranscript(transcriptForLLM(s.segments)))
            ], model: config.llmModel, temperature: 0.25)
            {
                raw += delta
                guard currentSessionId == target else { continue }
                streamingFlashcardsRaw = raw
            }
            var parsed: [Flashcard] = []
            let createdAt = Int64(Date().timeIntervalSince1970 * 1000)
            for line in raw.split(separator: "\n") {
                let parts = String(line).components(separatedBy: "||")
                guard parts.count >= 2 else { continue }
                let front = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let back = parts.dropFirst().joined(separator: "||").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !front.isEmpty, !back.isEmpty else { continue }
                parsed.append(Flashcard(id: nil,
                                        sessionId: target,
                                        front: front,
                                        back: back,
                                        sourceModel: config.llmModel,
                                        createdAt: createdAt,
                                        sortOrder: parsed.count))
            }
            try await FlashcardRepository.shared.replace(sessionId: target, cards: parsed)
            let fresh = try await FlashcardRepository.shared.all(sessionId: target)
            guard currentSessionId == target else { return }
            flashcards = fresh
        } catch {
            AppState.shared.setError("Flashcards failed: \(error.localizedDescription)")
        }
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
        isGeneratingStudyTool = true
        streamingStudyToolId = tool.id
        streamingStudyToolMarkdown = ""
        defer {
            isGeneratingStudyTool = false
            streamingStudyToolId = nil
            streamingStudyToolMarkdown = ""
            transcriptTruncatedNotice = ""
        }
        let config = AppState.shared.apiConfig
        let llm = EngineFactory.makeLLM(config: config, backend: AppState.shared.llmBackend)
        let system = courseContext.promptBlock.isEmpty
            ? tool.systemPrompt
            : courseContext.promptBlock + "\n\n" + tool.systemPrompt
        let transcript = budgetedTranscript(StudyTools.transcriptForLLM(s.segments))
        do {
            var markdown = ""
            for try await delta in llm.chat(messages: [
                .init(role: .system, content: system),
                .init(role: .user, content: "Lecture transcript:\n\(transcript)")
            ], model: config.llmModel, temperature: 0.25)
            {
                markdown += delta
                guard currentSessionId == target else { continue }
                streamingStudyToolMarkdown = markdown
            }
            let result = StudyToolResult(id: UUID().uuidString,
                                         sessionId: target,
                                         toolId: tool.id,
                                         markdown: markdown,
                                         model: config.llmModel,
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
        isRetranslating = true
        retranslateProgress = (0, 0)
        defer {
            isRetranslating = false
            retranslateProgress = nil
        }
        do {
            // Its own orchestrator: the shared one belongs to the live
            // recording, whose state a batch pass must not touch.
            let worker = SessionOrchestrator()
            let stillFailed = try await worker.retranslateSession(
                sessionId: sid,
                failedOnly: failedOnly,
                onProgress: { [weak self] done, total in
                    guard let self, self.currentSessionId == sid else { return }
                    self.retranslateProgress = (done, total)
                })
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
        guard let path = session?.session.audioPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            p.prepareToPlay()
            player = p
            playbackDurationMs = Int64(p.duration * 1000)
            return p
        } catch {
            AppState.shared.setError("Playback failed: \(error.localizedDescription)")
            return nil
        }
    }

    func togglePlayPause() {
        guard let p = ensurePlayer() else { return }
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
        guard let p = ensurePlayer() else { return }
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
        guard let p = ensurePlayer() else { return }
        p.currentTime = min(max(0, Double(ms) / 1000), p.duration)
        playheadMs = Int64(p.currentTime * 1000)
    }

    func stopPlayback() {
        stopTicker()
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
        streamingHighlightId = highlightId
        let llm = EngineFactory.makeLLM(config: config, backend: AppState.shared.llmBackend)
        // Captured now: a session switch mid-stream would otherwise explain
        // this range with another course's glossary.
        let coursePrompt = courseContext.promptBlock

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await self.explanationService.generate(
                    rangeStartMs: range.start,
                    rangeEndMs: range.end,
                    allSegments: segments,
                    preset: preset,
                    config: config,
                    llm: llm,
                    courseContext: coursePrompt)
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

    /// Transcript for a one-shot prompt. The cloud path is untouched; the local
    /// sidecar gets a head-and-tail shortening and the UI says so, because a
    /// silently halved lecture reads as a bad model rather than a full context.
    private func budgetedTranscript(_ text: String) -> String {
        guard AppState.shared.llmBackend == .localMLX else {
            transcriptTruncatedNotice = ""
            return text
        }
        let result = TranscriptChunker.truncate(text: text, maxChars: Self.localPromptChars)
        transcriptTruncatedNotice = result.wasTruncated ? L10n.t("notes.local.truncated") : ""
        return result.text
    }
}

struct SessionWithSegments {
    let session: Session
    let segments: [Segment]
}
