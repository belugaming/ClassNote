import Foundation

actor HighlightExplanationService {
    /// - Parameter llm: the chat engine to run this on. Passed in rather than
    ///   built here so the explainer follows the notes/Q&A backend setting,
    ///   including the local sidecar, which has no API key to be missing.
    /// - Parameter courseContext: the course's own facts (glossary, instructor,
    ///   notes), already rendered as a prompt block, or empty.
    /// - Parameter transcript: the whole lecture as every feature's prompt
    ///   opens with it (see `LecturePrompt`), fitted to the engine.
    func generate(rangeStartMs: Int64,
                  rangeEndMs: Int64,
                  allSegments: [Segment],
                  transcript: String,
                  preset: PromptPreset,
                  config: ApiConfig,
                  llm: LLMProvider,
                  courseContext: String = "") -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let rangeSegments = allSegments.filter { seg in
            seg.startMs <= rangeEndMs && seg.endMs >= rangeStartMs
        }
        // The whole transcript is the opening every feature shares, so only
        // the range follows, in the same rendering.
        let range = """
        The range the student marked (explain THIS):
        ===
        \(StudyTools.transcriptForLLM(rangeSegments))
        ===
        """
        let messages = LecturePrompt.messages(courseContext: courseContext,
                                              transcript: transcript,
                                              instructions: HighlightPrompts.systemPrefix + "\n\n" + preset.systemBody,
                                              task: range)
        return llm.chatEvents(messages: messages, model: config.activeLLMModel, temperature: 0.3)
    }
}

enum HighlightRange {
    static func compute(timestampMs: Int64,
                        segments: [Segment],
                        radius: Int = Highlight.defaultRangeRadius) -> (start: Int64, end: Int64)? {
        guard !segments.isEmpty else { return nil }
        let anchor = anchorIndex(for: timestampMs, in: segments)
        let lo = max(0, anchor - radius)
        let hi = min(segments.count - 1, anchor + radius)
        return (segments[lo].startMs, segments[hi].endMs)
    }

    static func expand(currentRange: (start: Int64, end: Int64),
                       segments: [Segment],
                       step: Int = 1) -> (start: Int64, end: Int64) {
        guard !segments.isEmpty else { return currentRange }
        let lo = segments.firstIndex { $0.endMs >= currentRange.start } ?? 0
        let hi = segments.lastIndex { $0.startMs <= currentRange.end } ?? (segments.count - 1)
        let newLo = max(0, lo - step)
        let newHi = min(segments.count - 1, hi + step)
        return (segments[newLo].startMs, segments[newHi].endMs)
    }

    static func shrink(currentRange: (start: Int64, end: Int64),
                       segments: [Segment],
                       step: Int = 1) -> (start: Int64, end: Int64) {
        guard !segments.isEmpty else { return currentRange }
        let lo = segments.firstIndex { $0.endMs >= currentRange.start } ?? 0
        let hi = segments.lastIndex { $0.startMs <= currentRange.end } ?? (segments.count - 1)
        guard hi - lo >= 2 * step else { return currentRange }
        let newLo = lo + step
        let newHi = hi - step
        return (segments[newLo].startMs, segments[newHi].endMs)
    }

    private static func anchorIndex(for ts: Int64, in segments: [Segment]) -> Int {
        if let containing = segments.firstIndex(where: { $0.startMs <= ts && ts <= $0.endMs }) {
            return containing
        }
        var bestIdx = 0
        var bestDist = Int64.max
        for (i, seg) in segments.enumerated() {
            let d = min(abs(seg.startMs - ts), abs(seg.endMs - ts))
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        return bestIdx
    }
}
