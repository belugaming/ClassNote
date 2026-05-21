import Foundation
import AppKit

/// Produces user-facing artifacts (Markdown / plain text / SRT / audio copy /
/// full bundle) from a SessionDetail. Caller is responsible for prompting the
/// user with NSSavePanel and passing the chosen destination URL.
enum SessionExporter {
    enum Kind: String, CaseIterable, Identifiable {
        case transcriptMarkdown
        case transcriptPlain
        case transcriptSrt
        case notesMarkdown
        case flashcardsMarkdown
        case studyToolsMarkdown
        case audio
        case bundle
        var id: String { rawValue }
    }

    struct Input {
        let session: Session
        let segments: [Segment]
        let note: Note?
        let highlights: [Highlight]
        let flashcards: [Flashcard]
        let studyToolResults: [StudyToolResult]
    }

    enum ExportError: LocalizedError {
        case noAudio
        case noNotes
        case noTranscript
        case ioFailure(String)
        var errorDescription: String? {
            switch self {
            case .noAudio: return L10n.t("session.export.unavailable.audio")
            case .noNotes: return L10n.t("session.export.unavailable.notes")
            case .noTranscript: return L10n.t("session.export.unavailable.transcript")
            case .ioFailure(let s): return s
            }
        }
    }

    /// Render Markdown view of the bilingual transcript.
    static func transcriptMarkdown(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("# \(input.session.title)")
        lines.append("")
        lines.append("- Started: \(formatDate(input.session.startedAt))")
        lines.append("- Duration: \(formatDuration(input.session.durationMs))")
        lines.append("- Source: \(input.session.sourceKind)")
        lines.append("")
        lines.append("---")
        lines.append("")
        for seg in input.segments {
            let ts = formatTimecode(seg.startMs)
            lines.append("**[\(ts)]** \(seg.textOriginal)")
            let tr = seg.textTranslated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tr.isEmpty {
                lines.append("> \(tr)")
            }
            lines.append("")
        }
        if !input.highlights.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append("## Highlights")
            lines.append("")
            for h in input.highlights {
                let ts = formatTimecode(h.timestampMs)
                let note = h.userNote.isEmpty ? "(no note)" : h.userNote
                lines.append("- **[\(ts)]** \(note)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func flashcardsMarkdown(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("# \(input.session.title) Flashcards")
        lines.append("")
        lines.append("- Generated cards: \(input.flashcards.count)")
        lines.append("")
        for (idx, card) in input.flashcards.enumerated() {
            lines.append("## Card \(idx + 1)")
            lines.append("")
            lines.append("**Front:** \(card.front)")
            lines.append("")
            lines.append("**Back:** \(card.back)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func flashcardsTSV(_ input: Input) -> String {
        input.flashcards.map { card in
            "\(tsvEscaped(card.front))\t\(tsvEscaped(card.back))"
        }.joined(separator: "\n")
    }

    static func studyToolsMarkdown(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("# \(input.session.title) Study Tools")
        lines.append("")
        for result in input.studyToolResults {
            let title = StudyTools.find(result.toolId).map { L10n.t($0.labelKey) } ?? result.toolId
            lines.append("## \(title)")
            lines.append("")
            lines.append(result.markdown)
            lines.append("")
            lines.append("---")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Plain-text dump: just original text, one line per segment with a leading timecode.
    static func transcriptPlain(_ input: Input) -> String {
        input.segments.map { seg in
            "[\(formatTimecode(seg.startMs))] \(seg.textOriginal)"
        }.joined(separator: "\n")
    }

    /// SRT subtitle format. Uses original on line 1 and translation (if any) on line 2.
    static func transcriptSRT(_ input: Input) -> String {
        var out = ""
        for (i, seg) in input.segments.enumerated() {
            let idx = i + 1
            let start = srtTime(seg.startMs)
            let end = srtTime(max(seg.endMs, seg.startMs + 1))
            out += "\(idx)\n\(start) --> \(end)\n\(seg.textOriginal)\n"
            let tr = seg.textTranslated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tr.isEmpty { out += "\(tr)\n" }
            out += "\n"
        }
        return out
    }

    // MARK: - File writers (single-artifact). Caller picks destination.

    static func writeText(_ text: String, to url: URL) throws {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.ioFailure(error.localizedDescription)
        }
    }

    static func copyAudio(from input: Input, to url: URL) throws {
        guard let path = input.session.audioPath,
              FileManager.default.fileExists(atPath: path) else {
            throw ExportError.noAudio
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
        } catch {
            throw ExportError.ioFailure(error.localizedDescription)
        }
    }

    /// Bundle export: writes a directory at `folderURL` containing transcript.md,
    /// transcript.srt, notes.md (if available) and the audio file (if available).
    static func writeBundle(_ input: Input, to folderURL: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: folderURL.path) {
                try fm.removeItem(at: folderURL)
            }
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

            try transcriptMarkdown(input)
                .write(to: folderURL.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            try transcriptSRT(input)
                .write(to: folderURL.appendingPathComponent("transcript.srt"), atomically: true, encoding: .utf8)
            if let note = input.note, !note.markdown.isEmpty {
                try note.markdown
                    .write(to: folderURL.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
            }
            if !input.flashcards.isEmpty {
                try flashcardsMarkdown(input)
                    .write(to: folderURL.appendingPathComponent("flashcards.md"), atomically: true, encoding: .utf8)
            }
            if !input.studyToolResults.isEmpty {
                try studyToolsMarkdown(input)
                    .write(to: folderURL.appendingPathComponent("study-tools.md"), atomically: true, encoding: .utf8)
            }
            if let path = input.session.audioPath, fm.fileExists(atPath: path) {
                let ext = (path as NSString).pathExtension.isEmpty ? "m4a" : (path as NSString).pathExtension
                let dest = folderURL.appendingPathComponent("audio.\(ext)")
                try fm.copyItem(at: URL(fileURLWithPath: path), to: dest)
            }
        } catch let e as ExportError {
            throw e
        } catch {
            throw ExportError.ioFailure(error.localizedDescription)
        }
    }

    /// Sensible default filename for a single-file export.
    static func suggestedFilename(_ input: Input, ext: String) -> String {
        let safe = input.session.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe).\(ext)"
    }

    // MARK: - Formatting helpers

    private static func formatTimecode(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    private static func formatDuration(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private static func formatDate(_ ms: Int64) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private static func tsvEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func srtTime(_ ms: Int64) -> String {
        let totalMs = max(0, ms)
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1000
        let mil = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, mil)
    }
}
