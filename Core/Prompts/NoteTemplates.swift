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
              """),
        .init(id: "lesson",
              labelKey: "notes.template.lesson",
              systemPrompt: """
              Produce lesson notes for a one-on-one or small-group lesson (an instrument, voice, or other \
              practical skill), for the student to practise from before the next lesson.
              Include, in this order:
              1. Pieces and exercises worked on, each under its own heading (composer, title, movement or \
              bars when they are said or given in the course context).
              2. For each one: what the teacher asked to change, how (fingering, pedalling, tempo, \
              dynamics, phrasing, posture, breathing…), any image or analogy the teacher used, and the \
              timecode where the teacher says it.
              3. Technique and general habits the teacher brought up beyond one piece.
              4. A practice plan for the coming week: concrete steps per piece, with tempos or repetitions \
              when the teacher gave them.
              5. Assignments and what to prepare for next time, then questions worth asking the teacher.
              Quote the teacher's exact words where they are memorable. Do not invent feedback the teacher \
              did not give. Write in Chinese and keep musical and technical terms in their original \
              language next to the Chinese.
              """),
        .init(id: "discussion",
              labelKey: "notes.template.discussion",
              systemPrompt: """
              Produce notes for a seminar or discussion class.
              Include: the question or reading under discussion; each position or argument raised, with \
              who raised it when the transcript says (the instructor, a classmate, the student); the \
              evidence and examples given; where people disagreed and how it was left; points the \
              instructor stressed; readings and assignments; and open questions worth bringing next time.
              Write in Chinese, keep technical terms and titles bilingual.
              """)
    ]

    static func find(_ id: String) -> NoteTemplate {
        all.first { $0.id == id } ?? all[0]
    }
}
