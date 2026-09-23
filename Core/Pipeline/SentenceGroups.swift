import Foundation

/// Transcript lines grouped into the sentences they belong to.
///
/// The local ASR engine breaks a line that runs past a few seconds without a
/// sentence end ("soft cut"), purely so it stays readable; such a line carries
/// `continuesNext`. Translating it on its own hands the translator half a
/// sentence, which is where most unreadable translations came from. So
/// translation works on whole sentences: every line of a group except the last
/// is marked `.merged`, and the last line carries the group's translation.
enum SentenceGroups {
    /// Consecutive segments chained by `continuesNext`, in order. A trailing
    /// chain with no closing line (a recording stopped mid-sentence) is still a
    /// group: there is nothing left to wait for.
    static func group(_ segments: [Segment]) -> [[Segment]] {
        var groups: [[Segment]] = []
        var current: [Segment] = []
        for segment in segments {
            current.append(segment)
            if !segment.continuesNext {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Joins the lines of one sentence. No space where either side is CJK:
    /// Chinese and Japanese take none between their own characters.
    static func join(_ texts: [String]) -> String {
        var out = ""
        for raw in texts {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = out.unicodeScalars.last, let first = text.unicodeScalars.first,
               !(isCJK(last) || isCJK(first)) {
                out += " "
            }
            out += text
        }
        return out
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK punctuation
             0x3040...0x30FF,   // kana
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK unified ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFF00...0xFFEF:   // fullwidth forms
            return true
        default:
            return false
        }
    }
}
