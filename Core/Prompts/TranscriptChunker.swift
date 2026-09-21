import Foundation

/// Fits a lecture transcript into a small local model's context.
///
/// A cloud model swallows a 90-minute transcript whole; a 4B MLX model has a
/// few thousand usable tokens, so notes are generated chunk by chunk and the
/// one-shot prompts (Q&A, flashcards, study tools) get a shortened transcript.
/// Both functions are pure — no engine, no config, no isolation — so the
/// policy lives here and the callers only decide when to apply it.
///
/// `maxChars` is a character budget rather than a token budget on purpose:
/// tokenizing would mean loading the sidecar's tokenizer just to decide how to
/// call it. Mixed English/Chinese lecture text runs around three characters
/// per token, which is close enough for a budget that already leaves headroom
/// for the answer.
enum TranscriptChunker {
    /// Splits `text` into pieces of at most `maxChars`, cutting on line
    /// boundaries so a chunk never starts mid-sentence — one transcript line is
    /// one segment. A single line longer than the budget is cut on a space, or
    /// hard if it has none (Chinese lines do not).
    static func split(text: String, maxChars: Int) -> [String] {
        guard maxChars > 0 else { return text.isEmpty ? [] : [text] }
        guard !text.isEmpty else { return [] }

        var chunks: [String] = []
        var current = ""
        // Empty lines are kept so paragraph breaks in the transcript survive.
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            for piece in splitLongLine(String(line), maxChars: maxChars) {
                // +1 for the newline that will rejoin this piece to `current`.
                if !current.isEmpty && current.count + 1 + piece.count > maxChars {
                    chunks.append(current)
                    current = piece
                } else if current.isEmpty {
                    current = piece
                } else {
                    current += "\n" + piece
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Shortens `text` to `maxChars` by keeping its head and its tail with an
    /// elision marker between them. The tail matters: a lecture's summary,
    /// assignment and exam hints all live in the last minutes, and a plain
    /// `prefix` would drop exactly those.
    static func truncate(text: String, maxChars: Int) -> (text: String, wasTruncated: Bool) {
        guard maxChars > 0 else { return ("", !text.isEmpty) }
        guard text.count > maxChars else { return (text, false) }

        let marker = "\n\n[… middle of the transcript omitted to fit the local model …]\n\n"
        // Below this there is no room for a head, a tail and the marker, so
        // keeping the head alone is more honest than emitting only the marker.
        guard maxChars > marker.count + 1 else {
            return (String(text.prefix(maxChars)), true)
        }
        let budget = maxChars - marker.count
        let tailCount = budget / 2
        let headCount = budget - tailCount
        return (String(text.prefix(headCount)) + marker + String(text.suffix(tailCount)), true)
    }

    /// Breaks one over-long line into `maxChars`-sized pieces, preferring the
    /// last space before the cut so a word survives intact.
    private static func splitLongLine(_ line: String, maxChars: Int) -> [String] {
        guard line.count > maxChars else { return [line] }
        var pieces: [String] = []
        var rest = Substring(line)
        while rest.count > maxChars {
            let limit = rest.index(rest.startIndex, offsetBy: maxChars)
            let cut = rest[rest.startIndex..<limit].lastIndex(of: " ").map { rest.index(after: $0) } ?? limit
            pieces.append(String(rest[rest.startIndex..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }
}
