import Foundation

actor HighlightExplanationService {
    func generate(rangeStartMs: Int64,
                  rangeEndMs: Int64,
                  allSegments: [Segment],
                  preset: PromptPreset,
                  config: ApiConfig) -> AsyncThrowingStream<String, Error> {
        let fullTranscript = Self.renderSegments(allSegments)
        let rangeSegments = allSegments.filter { seg in
            seg.startMs <= rangeEndMs && seg.endMs >= rangeStartMs
        }
        let rangeText = Self.renderSegments(rangeSegments)

        let userContent = """
        Full transcript (for context only):
        \(fullTranscript)

        The range the student marked (explain THIS):
        ===
        \(rangeText)
        ===
        """

        let system = HighlightPrompts.systemPrefix + "\n\n" + preset.systemBody
        let messages: [ChatMessage] = [
            .init(role: .system, content: system),
            .init(role: .user, content: userContent),
        ]
        return OpenAIChatClient.chatStream(config: config,
                                            messages: messages,
                                            model: config.llmModel,
                                            temperature: 0.3)
    }

    private static func renderSegments(_ segments: [Segment]) -> String {
        segments.map { seg in
            "[\(formatTs(seg.startMs))] \(seg.textOriginal)"
        }.joined(separator: "\n")
    }

    private static func formatTs(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
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
