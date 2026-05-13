import Foundation
import GRDB

struct Segment: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    var id: Int64?
    var sessionId: String
    var startMs: Int64
    var endMs: Int64
    var speakerId: String?
    var textOriginal: String
    var textTranslated: String
    var isFinal: Bool
    var confidence: Double
    var version: Int64

    enum CodingKeys: String, CodingKey {
        case id, confidence, version
        case sessionId = "session_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case speakerId = "speaker_id"
        case textOriginal = "text_original"
        case textTranslated = "text_translated"
        case isFinal = "is_final"
    }

    static let databaseTableName = "segment"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct Highlight: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    var id: Int64?
    var sessionId: String
    var timestampMs: Int64
    var userNote: String
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case timestampMs = "timestamp_ms"
        case userNote = "user_note"
        case createdAt = "created_at"
    }

    static let databaseTableName = "highlight"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct Note: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    var id: String
    var sessionId: String
    var markdown: String
    var version: Int64
    var generatedAt: Int64
    var model: String?

    enum CodingKeys: String, CodingKey {
        case id, markdown, version, model
        case sessionId = "session_id"
        case generatedAt = "generated_at"
    }

    static let databaseTableName = "note"
}
