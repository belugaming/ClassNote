import Foundation

struct NoteTemplate: Identifiable, Hashable, Sendable {
    let id: String
    let labelKey: String
    let systemPrompt: String
}

enum NoteTemplates {
    static let all: [NoteTemplate] = [
        .init(id: "study",
              labelKey: "notes.template.study",
              systemPrompt: """
              Produce a structured Markdown study note from the lecture transcript.
              Include: title, overview, logical sections, bilingual key terms, examples/formulas, questions and answers, takeaways.
              Write explanatory text in Chinese and keep English terms in parentheses.
              """),
        .init(id: "exam",
              labelKey: "notes.template.exam",
              systemPrompt: """
              Produce an exam-focused Markdown review guide.
              Include: likely exam concepts, definitions, common mistakes, practice questions with answers, and a short checklist.
              Write in Chinese, keep technical terms bilingual.
              """),
        .init(id: "terms",
              labelKey: "notes.template.terms",
              systemPrompt: """
              Produce a bilingual glossary from the transcript.
              Group terms by topic. For each term include English, Chinese explanation, why it matters, and one short example.
              """),
        .init(id: "timeline",
              labelKey: "notes.template.timeline",
              systemPrompt: """
              Produce a timeline summary from the transcript.
              Organize by timecode, highlight topic shifts, decisions, examples, and action items.
              Write concise Chinese explanations.
              """)
    ]

    static func find(_ id: String) -> NoteTemplate {
        all.first { $0.id == id } ?? all[0]
    }
}
