import Foundation
import Combine

/// How often the live tutor explains the lecture on its own.
enum LiveTutorPace: String, CaseIterable, Identifiable, Sendable {
    case off
    case frequent
    case normal
    case relaxed

    var id: String { rawValue }

    /// Lecture time a stretch has to cover before it is explained on its own,
    /// or nil when the tutor only answers when asked.
    var intervalMs: Int64? {
        switch self {
        case .off: return nil
        case .frequent: return 30_000
        case .normal: return 60_000
        case .relaxed: return 120_000
        }
    }

    var titleKey: String { "liveTutor.pace.\(rawValue)" }
}

/// One thing the tutor said: an explanation of a stretch of the lecture, or the
/// answer to a question.
struct LiveTutorCard: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Explained on its own, on the pace's schedule.
        case auto
        /// The student asked to have the last bit explained.
        case manual
        /// The student's question.
        case question(String)

        var isQuestion: Bool {
            if case .question = self { return true }
            return false
        }
    }

    let id = UUID()
    let kind: Kind
    /// The stretch of lecture the card is about, on the session clock.
    let startMs: Int64
    let endMs: Int64
    /// The model that wrote it, for the highlight it can be saved as.
    var model = ""
    var markdown = ""
    var isStreaming = true
    var errorMessage: String?
    var isSaved = false

    var question: String? {
        if case .question(let text) = kind { return text }
        return nil
    }
}

/// Which stretch of the live transcript the tutor explains next. Pure, so the
/// schedule is testable without a model or a clock.
enum LiveTutorSchedule {
    /// Least text a stretch needs before it is worth a request on its own: a
    /// few words of "OK, so" across a long pause are not.
    static let minimumCharacters = 40

    /// How far back "explain the last bit" reaches when little is new.
    static let manualSpanMs: Int64 = 60_000

    /// The lines the next automatic explanation covers, or nil when none is due.
    ///
    /// A stretch is due once it spans `intervalMs` of lecture. It ends after the
    /// last line that closes a sentence: a sentence still being spoken waits for
    /// the next stretch, unless the lecturer has run on without a sentence end
    /// for twice the interval.
    static func dueStretch(_ segments: [LiveSegment],
                           coveredCount: Int,
                           intervalMs: Int64) -> Range<Int>? {
        let start = max(0, coveredCount)
        guard start < segments.count else { return nil }
        var end = segments.count
        while end > start, segments[end - 1].continuesNext { end -= 1 }
        if end == start {
            let openSpan = segments[segments.count - 1].endMs - segments[start].startMs
            guard openSpan >= intervalMs * 2 else { return nil }
            end = segments.count
        }
        let span = segments[end - 1].endMs - segments[start].startMs
        guard span >= intervalMs else { return nil }
        let characters = segments[start..<end].reduce(0) {
            $0 + $1.original.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        guard characters >= minimumCharacters else { return nil }
        return start..<end
    }

    /// What "explain the last bit" covers: everything not yet explained,
    /// reaching back to at least `minimumSpanMs` of lecture so a click right
    /// after an explanation still has something to work with.
    static func manualStretch(_ segments: [LiveSegment],
                              coveredCount: Int,
                              minimumSpanMs: Int64 = manualSpanMs) -> Range<Int> {
        guard !segments.isEmpty else { return 0..<0 }
        let end = segments.count
        var start = min(max(0, coveredCount), end - 1)
        let lastEnd = segments[end - 1].endMs
        while start > 0, lastEnd - segments[start].startMs < minimumSpanMs {
            start -= 1
        }
        return start..<end
    }
}

/// The AI tutor beside the live transcript.
///
/// While a recording runs it explains, every minute or so of lecture, what the
/// lecturer just said: in the student's language, with the terms a newcomer
/// would not know. The student can also have the last bit explained at once, or
/// ask a question, at any time, including after the recording stops.
///
/// Runs on the notes & Q&A engine, so it follows that setting, including the
/// local model.
@MainActor
final class LiveTutor: ObservableObject {
    @Published private(set) var cards: [LiveTutorCard] = []
    /// True from a recording's start to its stop: the only time explanations
    /// run on their own.
    @Published private(set) var isLive = false
    /// True once the transcript has a committed line to explain.
    @Published private(set) var hasTranscript = false
    /// Why automatic explanations stopped, after several failed in a row. A
    /// lecture's worth of identical errors helps nobody.
    @Published private(set) var autoPausedMessage: String?
    @Published var pace: LiveTutorPace {
        didSet {
            guard pace != oldValue else { return }
            AppEnvironment.defaults.set(pace.rawValue, forKey: Self.paceKey)
            evaluate()
        }
    }

    let transcript: TranscriptBuffer
    /// The session saved cards go to as highlights; nil for a live translation
    /// that is never saved.
    private(set) var sessionId: String?
    private var courseContext: CourseContext = .empty
    /// How many transcript lines an explanation has already covered. The
    /// buffer only ever appends (until a reset, which comes with `begin`), so
    /// an index is the cheapest exact cursor.
    private var coveredCount = 0
    private var consecutiveFailures = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// What each card was asked, kept until it succeeds so Retry sends the same.
    private var requests: [UUID: [ChatMessage]] = [:]
    /// Replaces the engine built from settings. Tests only.
    var llmOverride: LLMProvider?

    static let paceKey = "liveTutorPace"
    /// Failures in a row after which explanations stop running on their own.
    static let failuresBeforePause = 3
    /// Earlier explanations shown back to the model, so it does not repeat them.
    static let previousCardsInPrompt = 2
    /// Earlier questions kept as conversation, so a follow-up resolves.
    static let questionHistory = 3

    init(transcript: TranscriptBuffer) {
        self.transcript = transcript
        let stored = AppEnvironment.defaults.string(forKey: Self.paceKey) ?? ""
        self.pace = LiveTutorPace(rawValue: stored) ?? .normal
    }

    // MARK: - Lifecycle

    /// A new recording: the previous lecture's cards go, explanations start.
    func begin(sessionId: String?, courseContext: CourseContext) {
        cancelAll()
        cards.removeAll()
        requests.removeAll()
        coveredCount = 0
        consecutiveFailures = 0
        autoPausedMessage = nil
        hasTranscript = false
        self.sessionId = sessionId
        self.courseContext = courseContext
        isLive = true
    }

    /// The recording stopped. Cards stay, and asking still works; nothing more
    /// runs on its own. An answer still streaming is left to finish.
    func end() {
        isLive = false
    }

    /// A line was committed to the transcript.
    func transcriptDidAdvance() {
        if !hasTranscript, !transcript.segments.isEmpty { hasTranscript = true }
        evaluate()
    }

    func resumeAutomatic() {
        consecutiveFailures = 0
        autoPausedMessage = nil
        evaluate()
    }

    // MARK: - State the panel reads

    /// Whether a card can be kept as a highlight of the session.
    var canSave: Bool { sessionId != nil }

    /// The notes engine needs a key that is not stored: every request would fail.
    var isMissingCredential: Bool {
        guard llmOverride == nil else { return false }
        let config = AppState.shared.apiConfig
        switch AppState.shared.llmBackend {
        case .openAICompatible: return config.isCloudCredentialMissing
        case .anthropic: return config.isAnthropicCredentialMissing
        case .localMLX: return false
        }
    }

    var usesLocalModel: Bool { AppState.shared.llmBackend == .localMLX }

    /// An explanation (not an answer) is being written. Automatic ones wait for
    /// it: two at once would cover the same stretch.
    private var isExplaining: Bool {
        cards.contains { !$0.kind.isQuestion && $0.isStreaming }
    }

    // MARK: - Explaining

    private func evaluate() {
        guard isLive, autoPausedMessage == nil, !isExplaining, !isMissingCredential,
              let interval = pace.intervalMs else { return }
        let segments = transcript.segments
        guard let range = LiveTutorSchedule.dueStretch(segments, coveredCount: coveredCount,
                                                       intervalMs: interval) else { return }
        explain(range: range, of: segments, draft: "", kind: .auto)
    }

    /// Explains the last bit now, including the line still being spoken: the
    /// student clicks right after hearing what lost them.
    func explainNow() {
        let segments = transcript.segments
        let range = LiveTutorSchedule.manualStretch(segments, coveredCount: coveredCount)
        let draft = transcript.draftText
        guard !range.isEmpty || !draft.isEmpty else { return }
        explain(range: range, of: segments, draft: draft, kind: .manual)
    }

    private func explain(range: Range<Int>, of segments: [LiveSegment], draft: String,
                         kind: LiveTutorCard.Kind) {
        let stretch = Array(segments[range])
        let previous = cards
            .filter { !$0.kind.isQuestion && !$0.isStreaming && $0.errorMessage == nil && !$0.markdown.isEmpty }
            .suffix(Self.previousCardsInPrompt)
            .map(\.markdown)
        let messages = LiveTutorPrompts.explainMessages(
            stretch: stretch,
            draft: draft,
            background: Array(segments[..<range.lowerBound]),
            previous: Array(previous),
            voice: voice,
            courseBlock: courseContext.promptBlock,
            budget: budget)
        coveredCount = max(coveredCount, range.upperBound)
        let anchor = segments.last?.endMs ?? 0
        let card = LiveTutorCard(kind: kind,
                                 startMs: stretch.first?.startMs ?? anchor,
                                 endMs: stretch.last?.endMs ?? anchor)
        cards.append(card)
        run(cardId: card.id, messages: messages)
    }

    // MARK: - Questions

    func ask(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let segments = transcript.segments
        let history = cards.compactMap { card -> (question: String, answer: String)? in
            guard let asked = card.question, !card.isStreaming, card.errorMessage == nil,
                  !card.markdown.isEmpty else { return nil }
            return (question: asked, answer: card.markdown)
        }
        let messages = LiveTutorPrompts.questionMessages(
            question: question,
            transcript: segments,
            draft: transcript.draftText,
            history: Array(history.suffix(Self.questionHistory)),
            voice: voice,
            courseBlock: courseContext.promptBlock,
            budget: budget)
        // Anchored on the last minute of lecture, which is what a question
        // asked mid-lecture is almost always about, and what a highlight made
        // from it should show.
        let recent = LiveTutorSchedule.manualStretch(segments, coveredCount: segments.count)
        let anchor = segments.last?.endMs ?? 0
        let card = LiveTutorCard(kind: .question(question),
                                 startMs: recent.isEmpty ? anchor : segments[recent.lowerBound].startMs,
                                 endMs: anchor)
        cards.append(card)
        run(cardId: card.id, messages: messages)
    }

    func retry(_ cardId: UUID) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }),
              !cards[index].isStreaming,
              let messages = requests[cardId] else { return }
        cards[index].markdown = ""
        cards[index].errorMessage = nil
        cards[index].isStreaming = true
        run(cardId: cardId, messages: messages)
    }

    // MARK: - Running a request

    private var voice: LiveTutorPrompts.Voice {
        LiveTutorPrompts.Voice(targetLanguage: AppState.shared.apiConfig.targetLanguage)
    }

    private var budget: LiveTutorPrompts.Budget {
        usesLocalModel ? .local : .cloud
    }

    private func run(cardId: UUID, messages: [ChatMessage]) {
        requests[cardId] = messages
        let config = AppState.shared.apiConfig
        let backend = AppState.shared.llmBackend
        let llm = llmOverride ?? EngineFactory.makeLLM(config: config, backend: backend)
        let model = backend == .localMLX
            ? (LocalMLXLLMProcess.modelRepo.split(separator: "/").last.map(String.init) ?? "local")
            : config.activeLLMModel
        update(cardId) { $0.model = model }
        tasks[cardId]?.cancel()
        tasks[cardId] = Task { @MainActor [weak self] in
            var text = ""
            do {
                for try await delta in llm.chat(messages: messages, model: config.activeLLMModel, temperature: 0.3) {
                    text += delta
                    self?.update(cardId) { $0.markdown = text }
                }
                // A cancelled stream ends the loop instead of throwing.
                try Task.checkCancellation()
                self?.finish(cardId, error: nil)
            } catch is CancellationError {
                return
            } catch {
                self?.finish(cardId, error: error)
            }
        }
    }

    private func update(_ cardId: UUID, _ change: (inout LiveTutorCard) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        change(&cards[index])
    }

    private func finish(_ cardId: UUID, error: Error?) {
        tasks[cardId] = nil
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        cards[index].isStreaming = false
        let isAutomatic = cards[index].kind == .auto
        if let error {
            cards[index].errorMessage = error.localizedDescription
            if isAutomatic {
                consecutiveFailures += 1
                if consecutiveFailures >= Self.failuresBeforePause {
                    autoPausedMessage = error.localizedDescription
                }
            }
        } else if cards[index].markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cards[index].errorMessage = L10n.t("liveTutor.error.empty")
        } else {
            requests[cardId] = nil
            if isAutomatic { consecutiveFailures = 0 }
        }
        // Whatever piled up while this one was being written.
        evaluate()
    }

    private func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    // MARK: - Keeping a card

    /// Saves a card as a highlight of the session, explanation included, so it
    /// is there to review after class next to the moments the student marked.
    func save(_ cardId: UUID) {
        guard let sessionId,
              let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        let card = cards[index]
        guard !card.isStreaming, card.errorMessage == nil, !card.isSaved, !card.markdown.isEmpty else { return }
        cards[index].isSaved = true
        Task { @MainActor [weak self] in
            do {
                try await HighlightRepository.shared.insertExplained(
                    sessionId: sessionId,
                    timestampMs: card.startMs,
                    rangeStartMs: card.startMs,
                    rangeEndMs: card.endMs,
                    note: card.question ?? "",
                    promptKey: "explain",
                    model: card.model,
                    markdown: card.markdown,
                    generatedAt: Int64(Date().timeIntervalSince1970 * 1000))
                AppState.shared.lastHighlightAt = Date()
            } catch {
                self?.update(cardId) { $0.isSaved = false }
                AppState.shared.setError(error.localizedDescription)
            }
        }
    }
}
