import Foundation

/// The per-course facts the user typed, rendered once so every prompt
/// (translation, notes, study tools, QA, highlights) says the same thing.
/// Empty when the course has nothing filled in, so callers can append it
/// unconditionally without emitting a dangling header.
struct CourseContext: Sendable, Equatable {
    var courseName = ""
    var instructor = ""
    var glossary = ""
    var notes = ""

    static let empty = CourseContext()

    var isEmpty: Bool {
        courseName.isEmpty && instructor.isEmpty && glossary.isEmpty && notes.isEmpty
    }

    init() {}

    init(course: Course?) {
        guard let course else { return }
        courseName = course.name
        instructor = course.instructor ?? ""
        glossary = course.glossary ?? ""
        notes = course.notes ?? ""
    }

    /// Block for a notes / QA / study-tool / highlight system prompt.
    var promptBlock: String {
        guard !isEmpty else { return "" }
        var lines = ["Course context (authoritative — prefer it over your own guesses):"]
        if !courseName.isEmpty { lines.append("- Course: \(courseName)") }
        if !instructor.isEmpty { lines.append("- Instructor: \(instructor)") }
        if !notes.isEmpty { lines.append("- Notes from the student: \(notes)") }
        if !glossary.isEmpty { lines.append("- Glossary (use these renderings verbatim):\n\(glossary)") }
        return lines.joined(separator: "\n")
    }

    /// Glossary only, hard-capped: this rides on *every* sentence of a live
    /// translation, so it is the one place prompt size costs latency and tokens.
    var translationGlossaryBlock: String {
        guard !glossary.isEmpty else { return "" }
        return "Use these fixed renderings for course terms (term = translation), one per line:\n"
            + String(glossary.prefix(1200))
    }
}
