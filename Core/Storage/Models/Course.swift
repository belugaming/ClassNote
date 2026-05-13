import Foundation
import GRDB

struct Course: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var semester: String?
    var instructor: String?
    var notes: String?
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, semester, instructor, notes
        case createdAt = "created_at"
    }

    static let databaseTableName = "course"

    static func new(name: String, semester: String? = nil, instructor: String? = nil) -> Course {
        Course(id: UUID().uuidString,
               name: name,
               semester: semester,
               instructor: instructor,
               notes: nil,
               createdAt: Int64(Date().timeIntervalSince1970 * 1000))
    }
}
