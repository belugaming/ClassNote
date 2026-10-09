import SwiftUI

/// How a session is described on screen, in one place so the list, the
/// detail header and the menu bar agree.
extension Session {
    var stateValue: SessionState { SessionState(storedValue: state) }

    var stateLabel: String {
        switch stateValue {
        case .recording: return L10n.t("session.state.recording")
        case .transcribing: return L10n.t("session.state.transcribing")
        case .transcribed: return L10n.t("session.state.transcribed")
        case .summarizing: return L10n.t("session.state.summarizing")
        case .summarized: return L10n.t("session.state.summarized")
        case .interrupted: return L10n.t("session.state.interrupted")
        case .failed: return L10n.t("session.state.failed")
        }
    }

    var stateColor: Color {
        switch stateValue {
        case .recording: return Theme.recording
        case .transcribing, .summarizing: return Theme.accent
        case .summarized: return Theme.success
        case .interrupted: return Theme.warning
        case .failed: return Theme.recording
        case .transcribed: return .secondary
        }
    }

    var sourceValue: AudioSourceKind {
        switch sourceKind {
        case "system": return .system
        case "mixed": return .mixed
        case "file": return .file
        default: return .microphone
        }
    }

    var startedDate: Date { Date(timeIntervalSince1970: TimeInterval(startedAt) / 1000) }

    var durationLabel: String { TimeLabel.string(ms: durationMs) }
}

extension AudioSourceKind {
    /// Short label for pickers and metadata.
    var shortTitle: String {
        switch self {
        case .microphone: return L10n.t("session.source.mic")
        case .system: return L10n.t("session.source.system")
        case .mixed: return L10n.t("session.source.mixed")
        case .file: return L10n.t("session.source.file")
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic"
        case .system: return "speaker.wave.2"
        case .mixed: return "person.wave.2"
        case .file: return "doc"
        }
    }

    /// The three sources a live recording can use.
    static var liveCases: [AudioSourceKind] { [.microphone, .system, .mixed] }
}

@MainActor
enum DateLabels {
    /// "Today", "Yesterday", or the date, for grouping a session list.
    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L10n.t("date.today") }
        if calendar.isDateInYesterday(date) { return L10n.t("date.yesterday") }
        let template = calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "MMMMdEEEE" : "yMMMMd"
        return formatter(template).string(from: date)
    }

    static func time(_ date: Date) -> String {
        formatter("jmm").string(from: date)
    }

    static func dateTime(_ date: Date) -> String {
        formatter("yMMMdjmm").string(from: date)
    }

    /// One formatter per template and language, made once. Building a
    /// formatter from a template is slow, and the session list built one for
    /// every row as it scrolled into view.
    private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ template: String) -> DateFormatter {
        let chinese = L10n.isChinese
        let key = "\(chinese ? "zh" : "en")|\(template)"
        if let cached = formatters[key] { return cached }
        let f = DateFormatter()
        f.locale = chinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        f.timeZone = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = f
        return f
    }
}

/// Lines grouped into the sentences they belong to, for display. A line the
/// engine cut mid-sentence carries no translation of its own; the sentence's
/// translation is on its last line and shows once, under the whole sentence.
struct SentenceBlock<Line: Identifiable>: Identifiable {
    let lines: [Line]
    var id: Line.ID { lines[0].id }
}

/// So the rows' nonisolated `==` can read a block off a main-actor view.
extension SentenceBlock: Sendable where Line: Sendable {}

extension Array where Element == Segment {
    var sentenceBlocks: [SentenceBlock<Segment>] {
        SentenceGroups.group(self).map { SentenceBlock(lines: $0) }
    }
}

extension Array where Element == LiveSegment {
    var sentenceBlocks: [SentenceBlock<LiveSegment>] {
        var blocks: [SentenceBlock<LiveSegment>] = []
        var current: [LiveSegment] = []
        for line in self {
            current.append(line)
            if !line.continuesNext {
                blocks.append(SentenceBlock(lines: current))
                current = []
            }
        }
        if !current.isEmpty { blocks.append(SentenceBlock(lines: current)) }
        return blocks
    }
}

extension Segment {
    /// Non-optional identity for `ForEach`/`ScrollViewProxy`. Unsaved rows
    /// collapse to -1; they are never a scroll target.
    var rowKey: Int64 { id ?? -1 }
}
