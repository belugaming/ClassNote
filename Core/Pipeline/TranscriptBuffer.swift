import Foundation
import Combine

/// Live state for the LiveSession view. Aggregates segments as they arrive,
/// supports rolling translation updates, and exposes them as a published
/// list ordered by start time.
@MainActor
final class TranscriptBuffer: ObservableObject {
    @Published private(set) var segments: [LiveSegment] = []
    @Published var translationEnabled: Bool = true

    /// The in-progress line for the sentence currently being spoken — only
    /// ever populated by backends that report volatile/partial results
    /// (currently the on-device Apple STT engines). Cleared as soon as that
    /// sentence lands as a committed `LiveSegment`.
    @Published private(set) var draftText: String = ""

    /// Translation of `draftText`, refreshed on a debounce while the draft is
    /// still changing. Always cleared together with `draftText`.
    @Published private(set) var draftTranslated: String = ""

    /// Locally-known mapping from row id (database) to index in the array.
    private var indexById: [Int64: Int] = [:]

    func appendFinal(rowId: Int64, startMs: Int64, endMs: Int64, original: String) {
        let item = LiveSegment(rowId: rowId, startMs: startMs, endMs: endMs,
                               original: original, translated: "", isFinal: true)
        segments.append(item)
        indexById[rowId] = segments.count - 1
        draftText = ""
        draftTranslated = ""
    }

    func updateDraft(_ text: String) {
        draftText = text
    }

    /// Only applied if `text` still matches the current draft — guards
    /// against a stale debounced translation overwriting a newer draft's
    /// translation after the user kept talking past the debounce window.
    func updateDraftTranslation(_ translated: String, forDraft text: String) {
        guard draftText == text else { return }
        draftTranslated = translated
    }

    func updateTranslation(rowId: Int64, translated: String) {
        guard let idx = indexById[rowId], idx < segments.count else { return }
        segments[idx].translated = translated
    }

    /// Replaces an already-committed segment's text with a more accurate
    /// result from a 2-pass local ASR engine's offline correction pass.
    func reviseFinal(rowId: Int64, newText: String) {
        guard let idx = indexById[rowId], idx < segments.count else { return }
        segments[idx].original = newText
        segments[idx].wasRevised = true
    }

    func clearRevisedFlag(rowId: Int64) {
        guard let idx = indexById[rowId], idx < segments.count else { return }
        segments[idx].wasRevised = false
    }

    func translatedText(rowId: Int64) -> String {
        guard let idx = indexById[rowId], idx < segments.count else { return "" }
        return segments[idx].translated
    }

    func appendTranslationDelta(rowId: Int64, delta: String) {
        guard let idx = indexById[rowId], idx < segments.count else { return }
        segments[idx].translated += delta
    }

    func reset() {
        segments.removeAll()
        indexById.removeAll()
        draftText = ""
        draftTranslated = ""
    }

    func recent(_ count: Int = 4) -> [String] {
        Array(segments.suffix(count).map { $0.original })
    }
}

struct LiveSegment: Identifiable, Hashable {
    let id: Int64       // = rowId
    let rowId: Int64
    let startMs: Int64
    let endMs: Int64
    var original: String
    var translated: String
    var isFinal: Bool
    /// Set briefly when a 2-pass local ASR engine replaces this segment's
    /// text with a more accurate offline result, so the UI can flash a highlight.
    var wasRevised: Bool = false

    init(rowId: Int64, startMs: Int64, endMs: Int64, original: String, translated: String, isFinal: Bool) {
        self.id = rowId
        self.rowId = rowId
        self.startMs = startMs
        self.endMs = endMs
        self.original = original
        self.translated = translated
        self.isFinal = isFinal
    }

    var startTimeLabel: String {
        let s = Int(startMs / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}
