import Foundation

/// The prompt that drafts a session's background from its transcript, for the
/// student to correct before notes are written.
enum BriefingPrompt {
    /// - Parameter labels: the line labels to use where they fit, the same
    ///   sentence starters the background editor offers, so the draft reads
    ///   like something the student would have typed.
    /// - Parameter chinese: whether the student reads the app in Chinese.
    static func draftInstructions(labels: [String], chinese: Bool) -> String {
        let language = chinese ? "Simplified Chinese" : "English"
        let labelList = labels
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        return """
        Before notes are written for this class, draft a short background of it for the student \
        to check and correct. Write 3 to 6 short lines in \(language), one fact per line, each \
        starting with a label and a colon. Use these labels where they fit: \(labelList). Add a \
        line for anything else that matters for the notes, such as what kind of class it seems \
        to be or who is speaking.

        Say only what the transcript shows: topics, chapters, the pieces or works being worked on \
        (composer and title as said), what the teacher stressed or corrected, and what to prepare \
        next time. Mark a guess with "(?)" and leave out what you cannot tell. Plain lines only: no \
        heading, no Markdown, no preamble and no closing remark.
        """
    }
}
