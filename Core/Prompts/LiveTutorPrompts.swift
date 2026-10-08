import Foundation

/// Prompts for the live tutor: the assistant beside the live transcript that
/// explains, while the lecture is still going, what the lecturer just said, and
/// answers the student's questions about it.
enum LiveTutorPrompts {
    /// The language the tutor answers in, and the section labels it uses.
    ///
    /// It follows the translation target: that is the language the student
    /// reads the lecture in, so it is the one they want the explanation in.
    struct Voice: Equatable, Sendable {
        let languageName: String
        let nowLabel: String
        let ideasLabel: String
        let intuitionLabel: String

        init(targetLanguage: String) {
            let code = targetLanguage.lowercased()
            if code.isEmpty || code.hasPrefix("zh") {
                let traditional = code.contains("hant") || code.hasSuffix("-tw") || code.hasSuffix("-hk")
                languageName = traditional ? "Traditional Chinese (繁體中文)" : "Simplified Chinese (简体中文)"
                nowLabel = traditional ? "正在講" : "正在讲"
                ideasLabel = traditional ? "關鍵概念" : "关键概念"
                intuitionLabel = traditional ? "幫你理解" : "帮你理解"
            } else {
                languageName = Locale(identifier: "en_US").localizedString(forIdentifier: targetLanguage)
                    ?? targetLanguage
                nowLabel = "Right now"
                ideasLabel = "Key ideas"
                intuitionLabel = "To make it click"
            }
        }
    }

    /// How much transcript goes into one request. The local model is a 4B one
    /// with a small context, and every request here sits on the live path, so
    /// it gets less than a cloud model.
    struct Budget: Equatable, Sendable {
        /// The stretch being explained. Longer only when explanations fell
        /// behind; the newest part is the part that matters.
        let stretchChars: Int
        /// What came before the stretch, so "it" and "this" resolve.
        let backgroundChars: Int
        /// The transcript a question is answered from.
        let questionChars: Int
        /// Each earlier explanation shown back to the model.
        let previousCardChars: Int

        static let cloud = Budget(stretchChars: 6000, backgroundChars: 1500,
                                  questionChars: 12_000, previousCardChars: 600)
        static let local = Budget(stretchChars: 3000, backgroundChars: 800,
                                  questionChars: 5000, previousCardChars: 400)
    }

    private static let persona = """
    You are a patient teaching assistant sitting beside a student during a live \
    lecture. The student is studying abroad, is not a native speaker of the \
    lecture's language, and finds this subject hard. The lecture text comes from \
    live speech recognition, so expect misheard words: silently read them as what \
    the lecturer most plausibly meant, using the course context when there is one. \
    If no course is given, work out the subject from the lecture itself.
    """

    /// What the panel renders: Markdown, including tables and LaTeX.
    private static let formatting = """
    Format in Markdown. Write any formula in LaTeX: inline between single dollar \
    signs, like $L = 20\\log_{10}(A)$, or on its own line between $$ and $$. A small \
    table is fine when comparing two or three things side by side.
    """

    // MARK: - Explaining the latest stretch

    static func explainSystem(voice: Voice, courseBlock: String) -> String {
        var system = """
        \(persona)

        Every so often you are given the newest stretch of what the lecturer said. \
        Help the student keep up in real time. Answer in exactly this shape:

        **\(voice.nowLabel)**: one or two sentences on what the lecturer is talking \
        about right now and how it connects to what came before.

        **\(voice.ideasLabel)**
        - **English term** (its rendering in the answer language) — what it means, in plain words.

        At most three terms, and only ones a newcomer to the subject would not already \
        know. Leave out anything you already explained earlier in this lecture. Omit \
        this section when nothing qualifies.

        **\(voice.intuitionLabel)**: one concrete analogy or example, or the intuition \
        behind a formula, diagram or sound the lecturer is describing. Only when it \
        genuinely helps; otherwise omit it.

        Rules:
        - Short: at most about 150 words. The student reads this while still listening.
        - Plain language. Never explain a term with more jargon.
        - Explain only what the lecturer actually said; do not invent content or jump ahead in the course.
        - If the stretch is only logistics, small talk or a pause, reply with the first line only.
        - Write in \(voice.languageName). Keep English technical terms inline next to their translation.

        \(formatting)
        """
        if !courseBlock.isEmpty {
            system = courseBlock + "\n\n" + system
        }
        return system
    }

    /// - Parameter stretch: the lines to explain, oldest first.
    /// - Parameter draft: the line still being spoken, if it should be included.
    /// - Parameter background: the lines before the stretch, oldest first.
    /// - Parameter previous: earlier explanations in this lecture, oldest first.
    static func explainMessages(stretch: [LiveSegment],
                                draft: String,
                                background: [LiveSegment],
                                previous: [String],
                                voice: Voice,
                                courseBlock: String,
                                budget: Budget) -> [ChatMessage] {
        var parts: [String] = []
        let earlier = tail(render(background), maxChars: budget.backgroundChars)
        if !earlier.isEmpty {
            parts.append("Earlier in the lecture (background only, do not explain it again):\n\(earlier)")
        }
        let told = previous.map { String($0.prefix(budget.previousCardChars)) }
        if !told.isEmpty {
            parts.append("What you already told the student in this lecture (do not repeat it):\n"
                         + told.joined(separator: "\n---\n"))
        }
        var lines = render(stretch)
        let draftLine = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draftLine.isEmpty {
            lines += (lines.isEmpty ? "" : "\n") + "[still speaking] \(draftLine)"
        }
        let span = timeSpan(stretch).map { " \($0)" } ?? ""
        parts.append("""
        The newest stretch\(span) (explain THIS):
        ===
        \(tail(lines, maxChars: budget.stretchChars))
        ===
        """)
        return [
            .init(role: .system, content: explainSystem(voice: voice, courseBlock: courseBlock)),
            .init(role: .user, content: parts.joined(separator: "\n\n")),
        ]
    }

    // MARK: - Answering a question

    static func questionSystem(voice: Voice, courseBlock: String) -> String {
        var system = """
        \(persona)

        The student just asked you something, quietly, while the lecture goes on. \
        Answer the question directly and briefly: at most about 200 words. Use the \
        lecture transcript so far together with your general knowledge of the subject. \
        When the answer refers to something the lecturer said, point to it with its \
        timestamp, like [12:30]. When the transcript does not cover the question, \
        answer from general knowledge and say so in one short clause. Plain language; \
        explain any jargon you use. Write in \(voice.languageName). Keep English \
        technical terms inline next to their translation.

        \(formatting)
        """
        if !courseBlock.isEmpty {
            system = courseBlock + "\n\n" + system
        }
        return system
    }

    /// - Parameter history: earlier questions in this lecture and their
    ///   answers, oldest first, so a follow-up ("and the other one?") resolves.
    static func questionMessages(question: String,
                                 transcript: [LiveSegment],
                                 draft: String,
                                 history: [(question: String, answer: String)],
                                 voice: Voice,
                                 courseBlock: String,
                                 budget: Budget) -> [ChatMessage] {
        var lines = render(transcript)
        let draftLine = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draftLine.isEmpty {
            lines += (lines.isEmpty ? "" : "\n") + "[still speaking] \(draftLine)"
        }
        let body = tail(lines, maxChars: budget.questionChars)
        var messages: [ChatMessage] = [
            .init(role: .system, content: questionSystem(voice: voice, courseBlock: courseBlock)),
            .init(role: .user, content: body.isEmpty
                  ? "The lecture has not produced any transcript yet."
                  : "Lecture transcript so far:\n\(body)"),
            .init(role: .assistant, content: "Got it. What is your question?"),
        ]
        for turn in history {
            messages.append(.init(role: .user, content: turn.question))
            messages.append(.init(role: .assistant, content: String(turn.answer.prefix(budget.previousCardChars * 2))))
        }
        messages.append(.init(role: .user, content: question))
        return messages
    }

    // MARK: - Rendering

    /// One line per segment, each with its start time, the way every other
    /// transcript prompt in the app reads.
    static func render(_ segments: [LiveSegment]) -> String {
        segments.compactMap { segment -> String? in
            let text = segment.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "[\(TimeLabel.string(ms: segment.startMs))] \(text)"
        }
        .joined(separator: "\n")
    }

    /// "[03:12–04:05]", or nil for no lines.
    static func timeSpan(_ segments: [LiveSegment]) -> String? {
        guard let first = segments.first, let last = segments.last else { return nil }
        return "[\(TimeLabel.string(ms: first.startMs))–\(TimeLabel.string(ms: last.endMs))]"
    }

    /// The end of `text`, at most `maxChars` long, cut at a line start so no
    /// line arrives without its timestamp.
    static func tail(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let suffix = text.suffix(maxChars)
        if let newline = suffix.firstIndex(of: "\n") {
            return "…\n" + String(suffix[suffix.index(after: newline)...])
        }
        return "…" + String(suffix)
    }
}
