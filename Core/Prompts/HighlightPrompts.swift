import Foundation

struct PromptPreset: Identifiable, Hashable, Sendable {
    let key: String
    let labelKey: String
    let systemBody: String
    var id: String { key }
}

enum HighlightPrompts {
    static let systemPrefix = """
    You are an academic study assistant for a Chinese student studying in the US. \
    The student marked a specific range inside a lecture transcript. \
    Treat everything outside the `===` fence as background context — use it only \
    when it helps you explain the fenced range. Focus your answer on the fenced range. \
    Write in Chinese for explanatory prose; keep English technical terms inline.
    """

    static let all: [PromptPreset] = [
        PromptPreset(
            key: "explain",
            labelKey: "highlight.preset.explain",
            systemBody: """
            Explain what this range covers. Break down the core concept(s) in plain language, \
            connect them to anything from the surrounding context that's needed to make sense \
            of it, and call out anything that might trip a student up. Keep it to 150-250 words.
            """
        ),
        PromptPreset(
            key: "example",
            labelKey: "highlight.preset.example",
            systemBody: """
            Give 1-2 concrete analogies or worked examples for the concept(s) in this range. \
            Prefer scenarios a CN student studying in the US would already be familiar with. \
            Be specific — actual numbers, names, or step-by-step walkthroughs beat abstractions.
            """
        ),
        PromptPreset(
            key: "exam",
            labelKey: "highlight.preset.exam",
            systemBody: """
            List 3-5 things from this range that are likely to show up on an exam, quiz, or \
            problem set. For each, name the concept, state the form it might be tested in, \
            and flag one common trap or mistake. Use a numbered list.
            """
        ),
        PromptPreset(
            key: "terms",
            labelKey: "highlight.preset.terms",
            systemBody: """
            Extract every technical / domain term that appears in this range. For each, write: \
            **English term** — 中文译名 — one-sentence definition. Skip generic English words. \
            Order by appearance in the range.
            """
        ),
    ]

    static func find(key: String) -> PromptPreset? {
        all.first { $0.key == key }
    }
}
