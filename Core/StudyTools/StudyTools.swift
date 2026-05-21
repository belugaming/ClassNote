import Foundation

struct StudyToolDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let labelKey: String
    let descriptionKey: String
    let icon: String
    let systemPrompt: String
}

enum StudyTools {
    static let all: [StudyToolDefinition] = [
        .init(id: "catch_up",
              labelKey: "studyTools.catchUp.title",
              descriptionKey: "studyTools.catchUp.desc",
              icon: "figure.walk.motion",
              systemPrompt: """
              Turn the lecture into a catch-up brief for a student who missed class.
              Use Chinese explanations with English technical terms inline.
              Include: what happened, prerequisite ideas, the main chain of reasoning,
              3 examples from the transcript, and what to review before next class.
              Keep the output structured and practical.
              """),
        .init(id: "homework_plan",
              labelKey: "studyTools.homework.title",
              descriptionKey: "studyTools.homework.desc",
              icon: "checklist.checked",
              systemPrompt: """
              Create a homework attack plan from this lecture.
              Infer likely problem types, formulas or definitions to know, common traps,
              and a step-by-step review checklist. If the transcript does not mention
              homework, still produce a useful practice plan grounded in the covered concepts.
              Write in Chinese with English technical terms preserved.
              """),
        .init(id: "confusions",
              labelKey: "studyTools.confusions.title",
              descriptionKey: "studyTools.confusions.desc",
              icon: "exclamationmark.bubble",
              systemPrompt: """
              Identify 5-8 points that a Chinese student studying in the US is likely to
              misunderstand from this lecture. For each: name the confusing point, explain
              the correct idea, give a quick example, and include a useful timecode if possible.
              """),
        .init(id: "office_hours",
              labelKey: "studyTools.officeHours.title",
              descriptionKey: "studyTools.officeHours.desc",
              icon: "person.2.wave.2",
              systemPrompt: """
              Generate strong office-hour questions based on this lecture.
              Include questions to ask the professor or TA, why each question matters,
              and the exact transcript concept/timecode that motivated it when available.
              Keep questions specific, not generic.
              """),
        .init(id: "vocab_drill",
              labelKey: "studyTools.vocab.title",
              descriptionKey: "studyTools.vocab.desc",
              icon: "character.book.closed",
              systemPrompt: """
              Build a bilingual vocabulary drill from this lecture.
              Extract important English terms, provide Chinese explanations, a short example,
              and a self-test prompt for each term. Skip generic words.
              """)
    ]

    static func find(_ id: String) -> StudyToolDefinition? {
        all.first { $0.id == id }
    }

    static func transcriptForLLM(_ segments: [Segment]) -> String {
        segments.map { seg in
            let original = "[\(formatTimecode(seg.startMs))] \(seg.textOriginal)"
            guard !seg.textTranslated.isEmpty else { return original }
            return "\(original)\n译文: \(seg.textTranslated)"
        }.joined(separator: "\n")
    }

    private static func formatTimecode(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}
