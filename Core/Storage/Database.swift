import Foundation
import GRDB

final class Database: @unchecked Sendable {
    static let shared = Database()

    // `_dbPool` is written once, by `setup()`, and read from every repository
    // actor; the lock is what makes the `@unchecked` above honest. It also
    // doubles as the idempotence flag, so a `setup()` that throws installs
    // nothing and a later retry runs the whole migration again instead of
    // leaving a half-migrated pool behind.
    private let lock = NSLock()
    private var _dbPool: DatabasePool?

    var dbPool: DatabasePool! { lock.withLock { _dbPool } }

    private init() {}

    func setup() throws {
        lock.lock()
        defer { lock.unlock() }
        guard _dbPool == nil else { return }
        let dbURL = AppBootstrap.applicationSupportURL.appendingPathComponent("classnote.sqlite")
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }
        let pool = try DatabasePool(path: dbURL.path, configuration: config)
        try migrator.migrate(pool)
        _dbPool = pool
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

        migrator.registerMigration("v7_translation_backend") { db in
            try db.alter(table: "api_config") { t in
                t.add(column: "translation_backend", .text).notNull().defaults(to: "openai")
            }
        }

        migrator.registerMigration("v8_segment_fts_trigram") { db in
            // unicode61 classifies Han ideographs as letters, so a whole Chinese
            // sentence indexes as a single token and no Chinese query can ever
            // match it. trigram indexes every 3-character substring instead,
            // which is how FTS5 covers CJK without an ICU build. The tokenizer
            // arrived in SQLite 3.34; every supported macOS is far past that,
            // but skip rather than fail the migration on an older engine.
            let version = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "0"
            let parts = version.split(separator: ".").compactMap { Int($0) }
            let major = parts.count > 0 ? parts[0] : 0
            let minor = parts.count > 1 ? parts[1] : 0
            guard major > 3 || (major == 3 && minor >= 34) else { return }

            try db.execute(sql: "DROP TRIGGER IF EXISTS segment_ai;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS segment_ad;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS segment_au;")
            try db.execute(sql: "DROP TABLE IF EXISTS segment_fts;")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE segment_fts USING fts5(
                    text_original, text_translated,
                    content='segment', content_rowid='id',
                    tokenize='trigram'
                );
            """)
            // Recreated verbatim from v1_initial: SQLite re-resolves the table
            // name on every fire, so keeping them here makes v8 self-contained.
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
            try db.execute(sql: "INSERT INTO segment_fts(segment_fts) VALUES('rebuild');")
        }

        migrator.registerMigration("v9_api_config_provenance") { db in
            try db.alter(table: "api_config") { t in
                t.add(column: "configured_at", .integer)
            }
            // Seed provenance once with the heuristic this column replaces: a
            // row that already differs from the factory row really was saved by
            // hand. A pristine row stays NULL so a wiped database can still be
            // recovered from the UserDefaults backup.
            try db.execute(sql: """
                UPDATE api_config SET configured_at = ?
                WHERE id = 1 AND (api_key <> ''
                               OR base_url <> 'https://api.openai.com/v1'
                               OR stt_model <> 'whisper-1'
                               OR translation_model <> 'gpt-4o-mini'
                               OR llm_model <> 'gpt-4o-mini'
                               OR stt_backend <> 'openai'
                               OR target_language <> 'zh-Hans'
                               OR source_language <> 'en'
                               OR translation_backend <> 'openai')
                """, arguments: [Int64(Date().timeIntervalSince1970 * 1000)])
        }

        migrator.registerMigration("v10_segment_translation_state") { db in
            try db.alter(table: "segment") { t in
                // See TranslationState: 0 = not attempted, 1 = ok, 2 = failed.
                t.add(column: "translation_state", .integer).notNull().defaults(to: 0)
            }
            // Anything already translated was, by definition, a success. The
            // AFTER UPDATE trigger re-indexes each touched row; correct, and a
            // one-off cost on a large library.
            try db.execute(sql: "UPDATE segment SET translation_state = 1 WHERE text_translated <> ''")
        }

        migrator.registerMigration("v11_course_glossary") { db in
            try db.alter(table: "course") { t in
                // One "term = 译名" per line. Free text on purpose: a student
                // pastes the syllabus glossary, they do not fill in a form.
                t.add(column: "glossary", .text)
            }
        }

        migrator.registerMigration("v12_llm_backend") { db in
            try db.alter(table: "api_config") { t in
                t.add(column: "llm_backend", .text).notNull().defaults(to: "openai")
            }
        }

        return migrator
    }
}
