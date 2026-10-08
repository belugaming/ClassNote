import Foundation

/// Lays out a task over one lecture's transcript for the notes & Q&A engine.
///
/// On an engine with a prompt cache (Claude) every feature opens the same
/// way: one shared system prompt, then the transcript in one fixed rendering
/// with the cache breakpoint on it, then the task's own instructions. Notes,
/// flashcards, study tools, highlight explanations and Q&A on the same lecture
/// all read the transcript from that one cache entry, as long as each starts
/// within a few minutes of the last, and only the first pays to write it. The
/// cache matches from the first byte, so a feature-specific system prompt in
/// front of the transcript would give every feature its own entry, which a
/// one-off run pays extra to write and never reads back.
///
/// Other engines have no prompt cache and keep the layout they always had:
/// the feature's instructions as the system prompt and its own rendering of
/// the transcript as the user turn.
enum LecturePrompt {
    static let sharedSystem = """
    You are a study assistant for a Chinese student studying in the US. The first message is \
    the transcript of one of their lectures: a timecode and the original text per line, with a \
    Chinese translation (译文) under lines that have one. The messages after it say what to do.
    """

    /// - Parameter courseContext: the course's facts as a prompt block, or empty.
    /// - Parameter instructions: what the feature asks for; its system prompt
    ///   on an engine without a cache.
    /// - Parameter legacyUser: the user turn as the feature sends it to an
    ///   engine without a cache.
    /// - Parameter task: what the request is about beyond the transcript (the
    ///   marked range), after the instructions in the shared layout.
    /// - Parameter followUp: turns after the opening, such as Q&A history.
    static func messages(courseContext: String,
                         instructions: String,
                         legacyUser: String,
                         segments: [Segment],
                         task: String = "",
                         followUp: [ChatMessage] = [],
                         sharedCache: Bool) -> [ChatMessage] {
        guard sharedCache else {
            return [.init(role: .system, content: joined(courseContext, instructions)),
                    .init(role: .user, content: legacyUser)] + followUp
        }
        return [
            .init(role: .system, content: joined(courseContext, sharedSystem)),
            .init(role: .user,
                  content: "Lecture transcript:\n" + StudyTools.transcriptForLLM(segments),
                  endsCachedPrefix: true),
            .init(role: .user, content: joined(instructions, task)),
        ] + followUp
    }

    private static func joined(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
