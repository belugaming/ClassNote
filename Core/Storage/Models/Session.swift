import Foundation
import GRDB

enum SessionState: String, Codable, Sendable {
    case recording
    case transcribing
    case transcribed
    case summarizing
    case summarized
    case interrupted
    case failed

    init(storedValue: String) {
        if storedValue == "ready" {
            self = .transcribed
        } else {
            self = SessionState(rawValue: storedValue) ?? .transcribed
        }
    }
}

struct Session: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    var id: String
    var courseId: String?
    var title: String
    var startedAt: Int64
    var endedAt: Int64?
    var audioPath: String?
    var sourceKind: String   // "mic" | "system" | "mixed" | "file"
    var state: String        // See SessionState.
    var sttModel: String?
    var llmModel: String?
    var durationMs: Int64

    enum CodingKeys: String, CodingKey {
        case id, title, state
        case courseId = "course_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case audioPath = "audio_path"
        case sourceKind = "source_kind"
        case sttModel = "stt_model"
        case llmModel = "llm_model"
        case durationMs = "duration_ms"
    }

    static let databaseTableName = "session"

    static func new(courseId: String?, title: String, sourceKind: String = "mic") -> Session {
        Session(id: UUID().uuidString,
                courseId: courseId,
                title: title,
                startedAt: Int64(Date().timeIntervalSince1970 * 1000),
                endedAt: nil,
                audioPath: nil,
                sourceKind: sourceKind,
                state: "recording",
                sttModel: nil,
                llmModel: nil,
                durationMs: 0)
    }
}
