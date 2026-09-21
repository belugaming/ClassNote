import Foundation
import GRDB

struct Course: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var semester: String?
    var instructor: String?
    var notes: String?
    /// One "term = 译名" per line, pasted from the syllabus. Fed to the
    /// translator and to every AI prompt so course jargon renders consistently.
    var glossary: String?
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, semester, instructor, notes, glossary
        case createdAt = "created_at"
    }

    static let databaseTableName = "course"

    static func new(name: String, semester: String? = nil, instructor: String? = nil) -> Course {
        Course(id: UUID().uuidString,
               name: name,
               semester: semester,
               instructor: instructor,
               notes: nil,
               glossary: nil,
               createdAt: Int64(Date().timeIntervalSince1970 * 1000))
    }
}
