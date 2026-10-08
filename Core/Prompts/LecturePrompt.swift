import Foundation

/// Lays out a task over one lecture's transcript for the notes & Q&A engine.
///
/// Every feature opens the same way: one shared system prompt, then the
/// transcript, then the feature's own instructions. Prompt caches match from
/// the first byte, so notes, Q&A, flashcards, study tools and highlight
/// explanations on the same lecture all reuse one cached transcript, as long
/// as each starts within a few minutes of the last: Claude through the
/// breakpoint on the transcript, and OpenAI-style providers that cache
/// repeated prefixes on their own. A feature-specific system prompt in front
/// of the transcript would give every feature its own entry, which a one-off
/// run pays to write and never reads back.
enum LecturePrompt {
    static let sharedSystem = """
    You are a study assistant for a Chinese student studying in the US. The conversation opens \
    with the transcript of one of their classes (a lecture, seminar, lab or lesson): a timecode and \
    the original text per line, with a Chinese translation (译文) under lines that have one. What \
    follows it says what to do.
    """

    /// - Parameter courseContext: the course's facts as a prompt block, or empty.
    /// - Parameter transcript: the lecture as `StudyTools.transcriptForLLM`
    ///   renders it, identical for every feature or the cache misses.
    /// - Parameter instructions: what the feature asks for.
    /// - Parameter task: what the request is about beyond the transcript
    ///   (the marked range), after the instructions.
    /// - Parameter followUp: turns after the opening, such as Q&A history.
    static func messages(courseContext: String,
                         transcript: String,
                         instructions: String,
                         task: String = "",
                         followUp: [ChatMessage] = []) -> [ChatMessage] {
        [
            .init(role: .system, content: joined(courseContext, sharedSystem)),
            .init(role: .user, content: "Lecture transcript:\n" + transcript, endsCachedPrefix: true),
            .init(role: .user, content: joined(instructions, task)),
        ] + followUp
    }

    private static func joined(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
