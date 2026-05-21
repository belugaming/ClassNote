import Foundation
import GRDB

actor CourseRepository {
    static let shared = CourseRepository()

    func all() async throws -> [Course] {
        try await Database.shared.dbPool.read { db in
            try Course.order(Column("created_at").desc).fetchAll(db)
        }
    }

    func get(id: String) async throws -> Course? {
        try await Database.shared.dbPool.read { db in
            try Course.fetchOne(db, key: id)
        }
    }

    func insert(_ course: Course) async throws {
        try await Database.shared.dbPool.write { db in
            try course.insert(db)
        }
    }

    func update(_ course: Course) async throws {
        try await Database.shared.dbPool.write { db in
            try course.update(db)
        }
    }

    func delete(id: String) async throws {
        _ = try await Database.shared.dbPool.write { db in
            try Course.deleteOne(db, key: id)
        }
    }
}

actor SessionRepository {
    static let shared = SessionRepository()

    func all() async throws -> [Session] {
        try await Database.shared.dbPool.read { db in
            try Session.order(Column("started_at").desc).fetchAll(db)
        }
    }

    func byCourse(courseId: String?) async throws -> [Session] {
        try await Database.shared.dbPool.read { db in
            if let cid = courseId {
                return try Session
                    .filter(Column("course_id") == cid)
                    .order(Column("started_at").desc)
                    .fetchAll(db)
            } else {
                return try Session
                    .filter(Column("course_id") == nil)
                    .order(Column("started_at").desc)
                    .fetchAll(db)
            }
        }
    }

    func get(id: String) async throws -> Session? {
        try await Database.shared.dbPool.read { db in
            try Session.fetchOne(db, key: id)
        }
    }

    func insert(_ session: Session) async throws {
        try await Database.shared.dbPool.write { db in
            try session.insert(db)
        }
    }

    func update(_ session: Session) async throws {
        try await Database.shared.dbPool.write { db in
            try session.update(db)
        }
    }

    func setState(_ id: String, state: String) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: "UPDATE session SET state=? WHERE id=?", arguments: [state, id])
        }
    }

    func setAudioPath(_ id: String, audioPath: String) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: "UPDATE session SET audio_path=? WHERE id=?",
                           arguments: [audioPath, id])
        }
    }

    func setEnded(_ id: String, endedAt: Int64, durationMs: Int64, audioPath: String?) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: "UPDATE session SET ended_at=?, duration_ms=?, audio_path=?, state='transcribed' WHERE id=?",
                           arguments: [endedAt, durationMs, audioPath, id])
        }
    }

    func recoverInterrupted(_ id: String, endedAt: Int64, durationMs: Int64) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: """
                UPDATE session
                SET ended_at=?, duration_ms=?, state='transcribed'
                WHERE id=?
                """, arguments: [endedAt, durationMs, id])
        }
    }

    func markInterrupted(_ id: String) async throws {
        try await setState(id, state: SessionState.interrupted.rawValue)
    }

    func setFailed(_ id: String) async throws {
        try await setState(id, state: SessionState.failed.rawValue)
    }

    func interruptedCandidates() async throws -> [Session] {
        try await Database.shared.dbPool.read { db in
            try Session
                .filter(["recording", "transcribing", "summarizing", "interrupted"].contains(Column("state")))
                .filter(Column("ended_at") == nil)
                .filter(Column("source_kind") != "file")
                .order(Column("started_at").desc)
                .fetchAll(db)
        }
    }

    func setTitle(_ id: String, title: String) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: "UPDATE session SET title=? WHERE id=?", arguments: [title, id])
        }
    }

    func move(id: String, toCourseId courseId: String?) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: "UPDATE session SET course_id=? WHERE id=?",
                           arguments: [courseId, id])
        }
    }

    func delete(id: String) async throws {
        let audioPath = try await Database.shared.dbPool.write { db in
            let audioPath = try String.fetchOne(db,
                                                sql: "SELECT audio_path FROM session WHERE id=?",
                                                arguments: [id])
            try Session.deleteOne(db, key: id)
            return audioPath
        }
        AppBootstrap.deleteManagedRecording(path: audioPath)
    }

    func allReferencedAudioPaths() async throws -> Set<String> {
        try await Database.shared.dbPool.read { db in
            let paths = try String.fetchAll(db, sql: """
                SELECT audio_path
                FROM session
                WHERE audio_path IS NOT NULL AND audio_path != ''
                """)
            return Set(paths)
        }
    }

    func cleanupOrphanedRecordings() async throws -> Int {
        let paths = try await allReferencedAudioPaths()
        return AppBootstrap.cleanupOrphanedRecordings(referencedPaths: paths)
    }

    func audioPath(id: String) async throws -> String? {
        try await Database.shared.dbPool.read { db in
            try String.fetchOne(db,
                                sql: "SELECT audio_path FROM session WHERE id=?",
                                arguments: [id])
        }
    }
}

actor SegmentRepository {
    static let shared = SegmentRepository()

    func all(sessionId: String) async throws -> [Segment] {
        try await Database.shared.dbPool.read { db in
            try Segment
                .filter(Column("session_id") == sessionId)
                .order(Column("start_ms"))
                .fetchAll(db)
        }
    }

    func insert(_ segment: Segment) async throws -> Int64 {
        try await Database.shared.dbPool.write { db in
            var s = segment
            try s.insert(db)
            return s.id ?? 0
        }
    }

    func insertMany(_ segments: [Segment]) async throws {
        try await Database.shared.dbPool.write { db in
            for segment in segments {
                var s = segment
                try s.insert(db)
            }
        }
    }

    func updateText(id: Int64, textOriginal: String, textTranslated: String, isFinal: Bool) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: """
                UPDATE segment SET text_original=?, text_translated=?, is_final=?, version=version+1
                WHERE id=?
            """, arguments: [textOriginal, textTranslated, isFinal ? 1 : 0, id])
        }
    }

    func updateTranslation(id: Int64, textTranslated: String) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: "UPDATE segment SET text_translated=?, version=version+1 WHERE id=?",
                           arguments: [textTranslated, id])
        }
    }

    func searchFTS(query: String, limit: Int = 100) async throws -> [(segment: Segment, sessionTitle: String)] {
        try await Database.shared.dbPool.read { db in
            let safeQuery = query.replacingOccurrences(of: "\"", with: "\"\"")
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.*, sess.title AS sess_title
                FROM segment_fts f
                JOIN segment s ON s.id = f.rowid
                JOIN session sess ON sess.id = s.session_id
                WHERE segment_fts MATCH ?
                ORDER BY rank
                LIMIT ?
            """, arguments: ["\"\(safeQuery)\"", limit])
            return try rows.map { row in
                let seg = try Segment(row: row)
                let title: String = row["sess_title"] ?? ""
                return (seg, title)
            }
        }
    }
}

actor HighlightRepository {
    static let shared = HighlightRepository()

    func mark(sessionId: String, timestampMs: Int64, note: String = "") async throws {
        try await Database.shared.dbPool.write { db in
            var h = Highlight(id: nil,
                              sessionId: sessionId,
                              timestampMs: timestampMs,
                              userNote: note,
                              createdAt: Int64(Date().timeIntervalSince1970 * 1000))
            try h.insert(db)
        }
    }

    func all(sessionId: String) async throws -> [Highlight] {
        try await Database.shared.dbPool.read { db in
            try Highlight
                .filter(Column("session_id") == sessionId)
                .order(Column("timestamp_ms"))
                .fetchAll(db)
        }
    }

    func updateExplanation(id: Int64,
                           rangeStartMs: Int64,
                           rangeEndMs: Int64,
                           promptKey: String,
                           model: String,
                           markdown: String,
                           generatedAt: Int64) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: """
                UPDATE highlight
                SET range_start_ms=?, range_end_ms=?,
                    explanation_md=?, explanation_prompt=?, explanation_model=?,
                    explanation_generated_at=?
                WHERE id=?
                """,
                arguments: [rangeStartMs, rangeEndMs,
                            markdown, promptKey, model,
                            generatedAt, id])
        }
    }

    func updateRange(id: Int64, rangeStartMs: Int64, rangeEndMs: Int64) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: "UPDATE highlight SET range_start_ms=?, range_end_ms=? WHERE id=?",
                           arguments: [rangeStartMs, rangeEndMs, id])
        }
    }

    func clearExplanation(id: Int64) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: """
                UPDATE highlight
                SET range_start_ms=NULL, range_end_ms=NULL,
                    explanation_md=NULL, explanation_prompt=NULL, explanation_model=NULL,
                    explanation_generated_at=NULL
                WHERE id=?
                """, arguments: [id])
        }
    }
}

actor NoteRepository {
    static let shared = NoteRepository()

    enum NoteRepositoryError: LocalizedError {
        case missingSession(String)

        var errorDescription: String? {
            switch self {
            case .missingSession:
                return "The session for this note no longer exists. Refresh the session list and open the session again."
            }
        }
    }

    func get(sessionId: String) async throws -> Note? {
        try await Database.shared.dbPool.read { db in
            try Note.filter(Column("session_id") == sessionId).fetchOne(db)
        }
    }

    func versions(sessionId: String) async throws -> [NoteVersion] {
        try await Database.shared.dbPool.read { db in
            try NoteVersion
                .filter(Column("session_id") == sessionId)
                .order(Column("generated_at").desc)
                .fetchAll(db)
        }
    }

    func upsert(_ note: Note, template: String = "study") async throws {
        try await Database.shared.dbPool.write { db in
            guard try Session.fetchOne(db, key: note.sessionId) != nil else {
                throw NoteRepositoryError.missingSession(note.sessionId)
            }

            if try Note.fetchOne(db, key: note.id) != nil {
                try db.execute(sql: """
                    UPDATE note
                    SET session_id=?, markdown=?, version=?, generated_at=?, model=?
                    WHERE id=?
                    """, arguments: [
                        note.sessionId,
                        note.markdown,
                        note.version,
                        note.generatedAt,
                        note.model,
                        note.id
                    ])
            } else {
                try note.insert(db)
            }

            let version = NoteVersion(id: UUID().uuidString,
                                      noteId: note.id,
                                      sessionId: note.sessionId,
                                      markdown: note.markdown,
                                      version: note.version,
                                      template: template,
                                      model: note.model,
                                      generatedAt: note.generatedAt)
            try version.insert(db)
        }
    }
}

actor FlashcardRepository {
    static let shared = FlashcardRepository()

    func all(sessionId: String) async throws -> [Flashcard] {
        try await Database.shared.dbPool.read { db in
            try Flashcard
                .filter(Column("session_id") == sessionId)
                .order(Column("sort_order"), Column("id"))
                .fetchAll(db)
        }
    }

    func replace(sessionId: String, cards: [Flashcard]) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: "DELETE FROM flashcard WHERE session_id=?", arguments: [sessionId])
            for var card in cards.enumerated().map({ index, card in
                var next = card
                next.sessionId = sessionId
                next.sortOrder = index
                return next
            }) {
                try card.insert(db)
            }
        }
    }
}

actor StudyToolResultRepository {
    static let shared = StudyToolResultRepository()

    func all(sessionId: String) async throws -> [StudyToolResult] {
        try await Database.shared.dbPool.read { db in
            try StudyToolResult
                .filter(Column("session_id") == sessionId)
                .order(Column("generated_at").desc)
                .fetchAll(db)
        }
    }

    func get(sessionId: String, toolId: String) async throws -> StudyToolResult? {
        try await Database.shared.dbPool.read { db in
            try StudyToolResult
                .filter(Column("session_id") == sessionId && Column("tool_id") == toolId)
                .fetchOne(db)
        }
    }

    func upsert(_ result: StudyToolResult) async throws {
        try await Database.shared.dbPool.write { db in
            if try StudyToolResult.fetchOne(db, key: result.id) != nil {
                try result.update(db)
            } else if let existing = try StudyToolResult
                .filter(Column("session_id") == result.sessionId && Column("tool_id") == result.toolId)
                .fetchOne(db) {
                var replacement = result
                replacement.id = existing.id
                try replacement.update(db)
            } else {
                try result.insert(db)
            }
        }
    }
}

actor ApiConfigRepository {
    static let shared = ApiConfigRepository()

    func load() async throws -> ApiConfig {
        var cfg = try await Database.shared.dbPool.read { db in
            try ApiConfig.fetchOne(db, key: 1) ?? .default
        }
        if !cfg.apiKey.isEmpty {
            try? APIKeyStore.save(cfg.apiKey)
        } else if let keychainKey = try? APIKeyStore.read(), !keychainKey.isEmpty {
            cfg.apiKey = keychainKey
            try await save(cfg)
        }
        return cfg
    }

    func save(_ cfg: ApiConfig) async throws {
        try? APIKeyStore.save(cfg.apiKey)
        let databaseConfig = cfg
        try await Database.shared.dbPool.write { db in
            try databaseConfig.insert(db, onConflict: .replace)
        }
    }
}
