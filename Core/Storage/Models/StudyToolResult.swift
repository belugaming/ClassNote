import Foundation
import GRDB

struct StudyToolResult: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    var id: String
    var sessionId: String
    var toolId: String
    var markdown: String
    var model: String?
    var generatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, markdown, model
        case sessionId = "session_id"
        case toolId = "tool_id"
        case generatedAt = "generated_at"
    }

    static let databaseTableName = "study_tool_result"
}

struct QAMessage: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var id: String
    var sessionId: String
    var role: Role
    var content: String
    var model: String?
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, role, content, model
        case sessionId = "session_id"
        case createdAt = "created_at"
    }

    static let databaseTableName = "qa_message"
}
