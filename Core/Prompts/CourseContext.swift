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

    /// What a speech recogniser that takes a text prompt (R2T2) is told about
    /// the lecture: the course and its terms, so a name or term it has only
    /// heard once is spelled the way the course spells it.
    var recognitionHint: String {
        var lines: [String] = []
        if !courseName.isEmpty { lines.append(courseName) }
        let terms = translationGlossary.pairs.map(\.0)
        if !terms.isEmpty { lines.append(terms.prefix(60).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    /// The glossary as every translator needs it.
    var translationGlossary: TranslationGlossary {
        TranslationGlossary(raw: glossary)
    }

    /// Glossary only, hard-capped: this rides on *every* sentence of a live
    /// translation, so it is the one place prompt size costs latency and tokens.
    var translationGlossaryBlock: String {
        translationGlossary.promptBlock
    }
}

/// A course glossary: free text, one "term = rendering" per line.
///
/// Kept as the raw text plus two views of it, because the translators want it
/// in different shapes: a chat model takes a prompt block, while Hy-MT2 has a
/// trained terminology template that needs the pairs.
struct TranslationGlossary: Sendable, Equatable {
    var raw: String

    static let empty = TranslationGlossary(raw: "")

    var isEmpty: Bool { raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Block for a chat model's system prompt. Capped: it rides on every line.
    var promptBlock: String {
        guard !isEmpty else { return "" }
        return "Use these fixed renderings for course terms (term = translation), one per line:\n"
            + String(raw.prefix(1200))
    }

    /// (term, rendering) pairs. Accepts "=", "：", ":" and "->" as separators,
    /// since students paste glossaries from wherever they keep them; lines
    /// without one are skipped.
    var pairs: [(String, String)] {
        raw.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let text = String(line)
            // The separator that comes first in the line, longest first where
            // two start at the same place ("=>" before "=").
            let separators = ["=>", "->", "=", "→", "：", ":"]
            let found = separators.compactMap { text.range(of: $0) }
                .min { $0.lowerBound < $1.lowerBound
                    || ($0.lowerBound == $1.lowerBound && $0.upperBound > $1.upperBound) }
            guard let range = found else { return nil }
            let term = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let rendering = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, !rendering.isEmpty else { return nil }
            return (term, rendering)
        }
    }
}
