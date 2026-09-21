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

    /// The course a session is filed under, resolved in one query so prompt
    /// builders do not have to carry the course id around.
    func forSession(id sessionId: String) async throws -> Course? {
        try await Database.shared.dbPool.read { db in
            try Course.fetchOne(db, sql: """
                SELECT c.* FROM course c
                JOIN session s ON s.course_id = c.id
                WHERE s.id = ?
                """, arguments: [sessionId])
        }
    }
}

actor SessionRepository {
    static let shared = SessionRepository()

    enum SessionRepositoryError: LocalizedError {
        case sessionIsRecording

        var errorDescription: String? {
            switch self {
            case .sessionIsRecording:
                return L10n.t("main.deleteSession.recordingError")
            }
        }
    }

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

    // The writes below run inside an unstructured `Task` so that cancelling the
    // caller — `SessionOrchestrator.stop()` cancels several tasks that end up
    // here — cannot roll the write back and lose the session's own bookkeeping.
    func setState(_ id: String, state: String) async throws {
        try await Task {
            try await Database.shared.dbPool.write { db in
                try db.execute(sql: "UPDATE session SET state=? WHERE id=?", arguments: [state, id])
            }
        }.value
    }

    func setAudioPath(_ id: String, audioPath: String) async throws {
        try await Task {
            try await Database.shared.dbPool.write { db in
                try db.execute(sql: "UPDATE session SET audio_path=? WHERE id=?",
                               arguments: [audioPath, id])
            }
        }.value
    }

    func setEnded(_ id: String, endedAt: Int64, durationMs: Int64, audioPath: String?) async throws {
        try await Task {
            try await Database.shared.dbPool.write { db in
                // COALESCE, because a nil argument means "the caller cannot see
                // the path from here", not "this session has no recording". A
                // second, defensive stop() would otherwise blank a finished
                // session's audio_path and orphan its .m4a at the next launch.
                try db.execute(sql: """
                    UPDATE session
                    SET ended_at=?, duration_ms=?, audio_path=COALESCE(?, audio_path), state='transcribed'
                    WHERE id=?
                    """, arguments: [endedAt, durationMs, audioPath, id])
            }
        }.value
    }

    func recoverInterrupted(_ id: String, endedAt: Int64, durationMs: Int64) async throws {
        try await Task {
            try await Database.shared.dbPool.write { db in
                try db.execute(sql: """
                    UPDATE session
                    SET ended_at=?, duration_ms=?, state='transcribed'
                    WHERE id=?
                    """, arguments: [endedAt, durationMs, id])
            }
        }.value
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

    /// Deleting a live session unlinks the .m4a the capture writer still holds
    /// open and makes every later segment insert fail its foreign key, so refuse
    /// unless the caller is the one cleaning up after a failed start.
    func delete(id: String, force: Bool = false) async throws {
        let audioPath = try await Database.shared.dbPool.write { db -> String? in
            if !force {
                let state = try String.fetchOne(db,
                                                sql: "SELECT state FROM session WHERE id=?",
                                                arguments: [id])
                guard state != SessionState.recording.rawValue else {
                    throw SessionRepositoryError.sessionIsRecording
                }
            }
            let audioPath = try String.fetchOne(db,
                                                sql: "SELECT audio_path FROM session WHERE id=?",
                                                arguments: [id])
            try Session.deleteOne(db, key: id)
            return audioPath
        }
        AppBootstrap.deleteManagedRecording(path: audioPath)
    }

    func allReferencedAudioPaths() async throws -> (paths: Set<String>, sessionIds: Set<String>) {
        try await Database.shared.dbPool.read { db -> (paths: Set<String>, sessionIds: Set<String>) in
            let paths = try String.fetchAll(db, sql: """
                SELECT audio_path
                FROM session
                WHERE audio_path IS NOT NULL AND audio_path != ''
                """)
            let ids = try String.fetchAll(db, sql: "SELECT id FROM session")
            return (paths: Set(paths), sessionIds: Set(ids))
        }
    }

    func cleanupOrphanedRecordings() async throws -> Int {
        let referenced = try await allReferencedAudioPaths()
        // The file name is the session id, so a recording that belongs to a row
        // is never an orphan even if that row's audio_path was lost.
        return AppBootstrap.cleanupOrphanedRecordings(referencedPaths: referenced.paths,
                                                      referencedSessionIds: referenced.sessionIds)
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

    // Like the session bookkeeping above, these run inside an unstructured
    // `Task`: a segment that reached the database must stay there even when the
    // task that produced it is cancelled on Stop.
    func insert(_ segment: Segment) async throws -> Int64 {
        try await Task {
            return try await Database.shared.dbPool.write { db -> Int64 in
                var s = segment
                try s.insert(db)
                return s.id ?? 0
            }
        }.value
    }

    func insertMany(_ segments: [Segment]) async throws {
        try await Task {
            try await Database.shared.dbPool.write { db in
                for segment in segments {
                    var s = segment
                    try s.insert(db)
                }
            }
        }.value
    }

    func updateText(id: Int64, textOriginal: String, textTranslated: String, isFinal: Bool) async throws {
        // Deliberately leaves translation_state alone: a revised transcript does
        // not tell us anything new about whether its translation landed.
        try await Task {
            try await Database.shared.dbPool.write { db in
                try db.execute(sql: """
                    UPDATE segment SET text_original=?, text_translated=?, is_final=?, version=version+1
                    WHERE id=?
                """, arguments: [textOriginal, textTranslated, isFinal ? 1 : 0, id])
            }
        }.value
    }

    func updateTranslation(id: Int64, textTranslated: String, state: TranslationState = .ok) async throws {
        try await Task {
            try await Database.shared.dbPool.write { db in
                try db.execute(sql: """
                    UPDATE segment SET text_translated=?, translation_state=?, version=version+1
                    WHERE id=?
                    """, arguments: [textTranslated, state.rawValue, id])
            }
        }.value
    }

    /// Segments whose translation never landed — what a retry should cover.
    func untranslated(sessionId: String) async throws -> [Segment] {
        try await Database.shared.dbPool.read { db in
            try Segment
                .filter(Column("session_id") == sessionId)
                .filter(Column("translation_state") != TranslationState.ok.rawValue)
                .filter(Column("text_original") != "")
                .order(Column("start_ms"))
                .fetchAll(db)
        }
    }

    /// Replaces every segment of a session in one transaction, returning the new
    /// row ids in insertion order. A re-transcription that fails halfway must not
    /// be able to leave the session with neither the old transcript nor a
    /// complete new one. The FTS delete/insert triggers keep the index in step.
    func replaceAll(sessionId: String, with segments: [Segment]) async throws -> [Int64] {
        try await Database.shared.dbPool.write { db -> [Int64] in
            try db.execute(sql: "DELETE FROM segment WHERE session_id=?", arguments: [sessionId])
            var ids: [Int64] = []
            for segment in segments {
                var s = segment
                // Always mint a fresh rowid: a caller that re-submits segments
                // it read back would otherwise insert an explicit primary key
                // and collide, rolling the whole replacement back.
                s.id = nil
                s.sessionId = sessionId
                try s.insert(db)
                ids.append(s.id ?? 0)
            }
            return ids
        }
    }

    func searchFTS(query: String, limit: Int = 100) async throws -> [(segment: Segment, sessionTitle: String)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // The trigram tokenizer indexes 3-character substrings, so a shorter
        // query can never produce a matching token. Two-character Chinese words
        // are the common case, so scan for those instead of returning nothing.
        guard trimmed.count >= 3 else { return try await searchLike(trimmed, limit: limit) }

        return try await Database.shared.dbPool.read { db in
            // Quoting makes the whole query one FTS5 phrase, which is what stops
            // a user typing AND / NEAR / * from producing a syntax error.
            let safeQuery = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
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

    /// Substring scan for queries too short for the trigram index.
    private func searchLike(_ needle: String, limit: Int) async throws -> [(segment: Segment, sessionTitle: String)] {
        try await Database.shared.dbPool.read { db in
            let escaped = needle
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.*, sess.title AS sess_title
                FROM segment s
                JOIN session sess ON sess.id = s.session_id
                WHERE s.text_original LIKE ? ESCAPE '\\'
                   OR s.text_translated LIKE ? ESCAPE '\\'
                ORDER BY sess.started_at DESC, s.start_ms
                LIMIT ?
            """, arguments: [pattern, pattern, limit])
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
        try await Task {
            try await Database.shared.dbPool.write { db in
                guard try Session.fetchOne(db, key: note.sessionId) != nil else {
                    throw NoteRepositoryError.missingSession(note.sessionId)
                }

                // Keyed on the session, never on the note id, and session_id is
                // not in the UPDATE set: a generation that started before the
                // user switched sessions carries the other session's note id,
                // and keying on it used to re-parent that note and wipe it.
                let existing = try Note.filter(Column("session_id") == note.sessionId).fetchOne(db)
                let storedId: String
                if let existing {
                    storedId = existing.id
                    try db.execute(sql: """
                        UPDATE note
                        SET markdown=?, version=?, generated_at=?, model=?
                        WHERE id=?
                        """, arguments: [
                            note.markdown,
                            note.version,
                            note.generatedAt,
                            note.model,
                            existing.id
                        ])
                } else {
                    var fresh = note
                    if try Note.fetchOne(db, key: fresh.id) != nil {
                        // That id belongs to another session's note. Mint a new
                        // one rather than collide on the primary key.
                        fresh.id = UUID().uuidString
                    }
                    try fresh.insert(db)
                    storedId = fresh.id
                }

                // A regeneration that produced exactly the same markdown — a
                // retry, or a second click — is not a new version worth keeping.
                let latestMarkdown = try String.fetchOne(db, sql: """
                    SELECT markdown FROM note_version
                    WHERE session_id=?
                    ORDER BY generated_at DESC, rowid DESC
                    LIMIT 1
                    """, arguments: [note.sessionId])
                guard latestMarkdown != note.markdown else { return }

                let version = NoteVersion(id: UUID().uuidString,
                                          noteId: storedId,
                                          sessionId: note.sessionId,
                                          markdown: note.markdown,
                                          version: note.version,
                                          template: template,
                                          model: note.model,
                                          generatedAt: note.generatedAt)
                try version.insert(db)
            }
        }.value
    }

    func delete(sessionId: String) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: "DELETE FROM note WHERE session_id=?", arguments: [sessionId])
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

actor QAMessageRepository {
    static let shared = QAMessageRepository()

    func all(sessionId: String) async throws -> [QAMessage] {
        try await Database.shared.dbPool.read { db in
            try QAMessage
                .filter(Column("session_id") == sessionId)
                .order(Column("created_at"), Column("id"))
                .fetchAll(db)
        }
    }

    func insert(_ message: QAMessage) async throws {
        try await Database.shared.dbPool.write { db in
            try message.insert(db)
        }
    }

    func delete(id: String) async throws {
        try await Database.shared.dbPool.write { db in
            try QAMessage.deleteOne(db, key: id)
        }
    }

    func deleteAll(sessionId: String) async throws {
        try await Database.shared.dbPool.write { db in
            try db.execute(sql: "DELETE FROM qa_message WHERE session_id=?", arguments: [sessionId])
        }
    }
}

actor ApiConfigRepository {
    static let shared = ApiConfigRepository()

    func load() async throws -> ApiConfig {
        let (cfg, isConfigured) = try await Database.shared.dbPool.read { db -> (ApiConfig, Bool) in
            let cfg = try ApiConfig.fetchOne(db, key: 1) ?? .default
            let configuredAt = try Int64.fetchOne(
                db, sql: "SELECT configured_at FROM api_config WHERE id=1")
            return (cfg, configuredAt != nil)
        }
        // Only a row the user never saved — a fresh install, or a database that
        // was lost — may be replaced by the UserDefaults backup. Settings the
        // user saved are authoritative even when every field happens to equal
        // the factory default, which is exactly what picking the OpenAI preset
        // produces.
        guard !isConfigured, let backup = ApiConfigBackupStore.read() else { return cfg }
        var restored = backup
        restored.id = 1
        if restored.apiKey.isEmpty {
            restored.apiKey = cfg.apiKey
        }
        try await save(restored)
        return restored
    }

    /// Saving is unconditional. `AppState.saveConfig`'s `hasLoadedConfig` guard
    /// is now the only thing keeping a startup-time `.default` from landing on
    /// top of real settings, so leave it in place.
    func save(_ cfg: ApiConfig) async throws {
        ApiConfigBackupStore.save(cfg)
        var stored = cfg
        stored.id = 1
        let databaseConfig = stored
        try await Database.shared.dbPool.write { db in
            try databaseConfig.insert(db, onConflict: .replace)
            // REPLACE is DELETE+INSERT and ApiConfig's CodingKeys do not cover
            // configured_at, so the provenance stamp has to be rewritten after
            // the insert, inside the same transaction.
            try db.execute(sql: "UPDATE api_config SET configured_at=? WHERE id=1",
                           arguments: [Int64(Date().timeIntervalSince1970 * 1000)])
        }
    }
}
