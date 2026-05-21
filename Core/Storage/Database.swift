import Foundation
import GRDB

final class Database {
    static let shared = Database()

    private(set) var dbPool: DatabasePool!
    private var isSetup = false

    private init() {}

    func setup() throws {
        guard !isSetup else { return }
        let dbURL = AppBootstrap.applicationSupportURL.appendingPathComponent("classnote.sqlite")
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }
        dbPool = try DatabasePool(path: dbURL.path, configuration: config)
        try migrator.migrate(dbPool)
        isSetup = true
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "course") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("semester", .text)
                t.column("instructor", .text)
                t.column("notes", .text)
                t.column("created_at", .integer).notNull()
            }
            try db.create(table: "session") { t in
                t.column("id", .text).primaryKey()
                t.column("course_id", .text).references("course", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("started_at", .integer).notNull()
                t.column("ended_at", .integer)
                t.column("audio_path", .text)
                t.column("source_kind", .text).notNull().defaults(to: "mic")
                t.column("state", .text).notNull().defaults(to: "recording")
                t.column("stt_model", .text)
                t.column("llm_model", .text)
                t.column("duration_ms", .integer).defaults(to: 0)
            }
            try db.create(table: "segment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .text).notNull().references("session", onDelete: .cascade)
                t.column("start_ms", .integer).notNull()
                t.column("end_ms", .integer).notNull()
                t.column("speaker_id", .text)
                t.column("text_original", .text).notNull().defaults(to: "")
                t.column("text_translated", .text).notNull().defaults(to: "")
                t.column("is_final", .integer).notNull().defaults(to: 0)
                t.column("confidence", .double).defaults(to: 0)
                t.column("version", .integer).defaults(to: 1)
            }
            try db.create(index: "idx_segment_session", on: "segment", columns: ["session_id", "start_ms"])

            try db.execute(sql: """
                CREATE VIRTUAL TABLE segment_fts USING fts5(
                    text_original, text_translated,
                    content='segment', content_rowid='id',
                    tokenize='porter unicode61'
                );
            """)
            try db.execute(sql: """
                CREATE TRIGGER segment_ai AFTER INSERT ON segment BEGIN
                    INSERT INTO segment_fts(rowid, text_original, text_translated)
                    VALUES (new.id, new.text_original, new.text_translated);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER segment_ad AFTER DELETE ON segment BEGIN
                    INSERT INTO segment_fts(segment_fts, rowid, text_original, text_translated)
                    VALUES('delete', old.id, old.text_original, old.text_translated);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER segment_au AFTER UPDATE ON segment BEGIN
                    INSERT INTO segment_fts(segment_fts, rowid, text_original, text_translated)
                    VALUES('delete', old.id, old.text_original, old.text_translated);
                    INSERT INTO segment_fts(rowid, text_original, text_translated)
                    VALUES (new.id, new.text_original, new.text_translated);
                END;
            """)

            try db.create(table: "highlight") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .text).notNull().references("session", onDelete: .cascade)
                t.column("timestamp_ms", .integer).notNull()
                t.column("user_note", .text).defaults(to: "")
                t.column("created_at", .integer).notNull()
            }

            try db.create(table: "note") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull().references("session", onDelete: .cascade)
                t.column("markdown", .text).notNull().defaults(to: "")
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("generated_at", .integer).notNull()
                t.column("model", .text)
            }

            try db.create(table: "api_config") { t in
                t.column("id", .integer).primaryKey()
                t.column("base_url", .text).notNull().defaults(to: "https://api.openai.com/v1")
                t.column("api_key", .text).notNull().defaults(to: "")
                t.column("stt_model", .text).notNull().defaults(to: "whisper-1")
                t.column("translation_model", .text).notNull().defaults(to: "gpt-4o-mini")
                t.column("llm_model", .text).notNull().defaults(to: "gpt-4o-mini")
                t.column("stt_backend", .text).notNull().defaults(to: "openai")
                t.column("target_language", .text).notNull().defaults(to: "zh-Hans")
                t.column("source_language", .text).notNull().defaults(to: "en")
            }
            try db.execute(sql: "INSERT OR IGNORE INTO api_config(id) VALUES (1);")
        }

        migrator.registerMigration("v2_highlight_explanation") { db in
            try db.alter(table: "highlight") { t in
                t.add(column: "range_start_ms", .integer)
                t.add(column: "range_end_ms", .integer)
                t.add(column: "explanation_md", .text)
                t.add(column: "explanation_prompt", .text)
                t.add(column: "explanation_model", .text)
                t.add(column: "explanation_generated_at", .integer)
            }
        }

        migrator.registerMigration("v3_note_history") { db in
            try db.create(table: "note_version") { t in
                t.column("id", .text).primaryKey()
                t.column("note_id", .text).notNull().references("note", onDelete: .cascade)
                t.column("session_id", .text).notNull().references("session", onDelete: .cascade)
                t.column("markdown", .text).notNull().defaults(to: "")
                t.column("version", .integer).notNull()
                t.column("template", .text).notNull().defaults(to: "study")
                t.column("model", .text)
                t.column("generated_at", .integer).notNull()
            }
            try db.create(index: "idx_note_version_session",
                          on: "note_version",
                          columns: ["session_id", "generated_at"])
        }

        migrator.registerMigration("v4_flashcards") { db in
            try db.create(table: "flashcard") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .text).notNull().references("session", onDelete: .cascade)
                t.column("front", .text).notNull()
                t.column("back", .text).notNull()
                t.column("source_model", .text)
                t.column("created_at", .integer).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_flashcard_session",
                          on: "flashcard",
                          columns: ["session_id", "sort_order"])
        }

        migrator.registerMigration("v5_study_tool_results") { db in
            try db.create(table: "study_tool_result") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull().references("session", onDelete: .cascade)
                t.column("tool_id", .text).notNull()
                t.column("markdown", .text).notNull().defaults(to: "")
                t.column("model", .text)
                t.column("generated_at", .integer).notNull()
            }
            try db.create(index: "idx_study_tool_result_session",
                          on: "study_tool_result",
                          columns: ["session_id", "generated_at"])
            try db.create(index: "idx_study_tool_result_unique_tool",
                          on: "study_tool_result",
                          columns: ["session_id", "tool_id"],
                          unique: true)
        }

        migrator.registerMigration("v6_qa_messages") { db in
            try db.create(table: "qa_message") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull().references("session", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull().defaults(to: "")
                t.column("model", .text)
                t.column("created_at", .integer).notNull()
            }
            try db.create(index: "idx_qa_message_session",
                          on: "qa_message",
                          columns: ["session_id", "created_at"])
        }

        return migrator
    }
}
