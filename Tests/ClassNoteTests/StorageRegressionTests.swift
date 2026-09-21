import Foundation
import XCTest
import GRDB
@testable import ClassNote

/// Regressions for storage bugs that were only ever reachable through a
/// specific sequence of writes, so each test reproduces the sequence rather
/// than asserting on the shape of a single call.
final class StorageRegressionTests: XCTestCase {

    // MARK: - C1: a nil audio path means "unknown", not "there is none"

    func testSetEndedWithNilAudioPathKeepsStoredPath() async throws {
        try ClassNote.Database.shared.setup()
        let session = Session.new(courseId: nil, title: "C1 audio path")
        try await SessionRepository.shared.insert(session)
        addTeardownBlock {
            try? await SessionRepository.shared.delete(id: session.id, force: true)
        }

        let path = AppBootstrap.recordingURL(sessionId: session.id).path
        try await SessionRepository.shared.setAudioPath(session.id, audioPath: path)

        // A second, defensive stop() no longer knows the path; it must not blank it.
        try await SessionRepository.shared.setEnded(session.id,
                                                    endedAt: 2_000,
                                                    durationMs: 1_000,
                                                    audioPath: nil)

        let reloaded = try await SessionRepository.shared.get(id: session.id)
        XCTAssertEqual(reloaded?.audioPath, path)
        XCTAssertEqual(reloaded?.state, "transcribed")
    }

    func testOrphanCleanupKeepsFilesNamedAfterALiveSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("classnote-orphans-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let liveId = UUID().uuidString
        let liveURL = root.appendingPathComponent("\(liveId).m4a")
        let orphanURL = root.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("live".utf8).write(to: liveURL)
        try Data("orphan".utf8).write(to: orphanURL)

        // The session row exists but its audio_path was lost, so only the file
        // name ties the recording to it.
        let removed = AppBootstrap.cleanupOrphanedRecordings(referencedPaths: [],
                                                             referencedSessionIds: [liveId],
                                                             recordingsRoot: root)
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    // MARK: - C7: Chinese is indexable at all

    func testChineseSegmentIsFoundByPartialQuery() async throws {
        try ClassNote.Database.shared.setup()
        let session = Session.new(courseId: nil, title: "C7 trigram")
        try await SessionRepository.shared.insert(session)
        addTeardownBlock {
            try? await SessionRepository.shared.delete(id: session.id, force: true)
        }

        let seg = Segment(id: nil, sessionId: session.id, startMs: 0, endMs: 1000,
                          speakerId: nil,
                          textOriginal: "The quick brown fox jumps over the lazy dog",
                          textTranslated: "敏捷的棕色狐狸跳过懒狗",
                          isFinal: true, confidence: 0.9, version: 1)
        let id = try await SegmentRepository.shared.insert(seg)

        // Four characters: long enough for the trigram index.
        let phrase = try await SegmentRepository.shared.searchFTS(query: "棕色狐狸", limit: 10)
        XCTAssertTrue(phrase.contains(where: { $0.segment.id == id }))

        // Two characters: shorter than a trigram, so the LIKE fallback answers.
        let word = try await SegmentRepository.shared.searchFTS(query: "狐狸", limit: 10)
        XCTAssertTrue(word.contains(where: { $0.segment.id == id }))

        // English must keep working after the tokenizer swap.
        let english = try await SegmentRepository.shared.searchFTS(query: "brown", limit: 10)
        XCTAssertTrue(english.contains(where: { $0.segment.id == id }))
    }

    // MARK: - C10: a saved config outranks a stale backup

    func testSavedConfigBeatsAStaleBackup() async throws {
        try ClassNote.Database.shared.setup()
        let previous = try await ApiConfigRepository.shared.load()
        addTeardownBlock {
            try? await ApiConfigRepository.shared.save(previous)
            ApiConfigBackupStore.clear()
        }

        // The user picks the OpenAI preset and types a new key: every field now
        // equals the factory default, which is what used to look "unconfigured".
        var fresh = ApiConfig.default
        fresh.apiKey = "fresh-key-do-not-keep"
        try await ApiConfigRepository.shared.save(fresh)

        var stale = ApiConfig.default
        stale.baseUrl = "https://stale.example.test/v1"
        stale.apiKey = "stale-key-do-not-keep"
        ApiConfigBackupStore.save(stale)

        let reloaded = try await ApiConfigRepository.shared.load()
        XCTAssertEqual(reloaded.apiKey, "fresh-key-do-not-keep")
        XCTAssertEqual(reloaded.baseUrl, ApiConfig.default.baseUrl)
    }

    func testBackupWrittenBeforeTheNewFieldsStillDecodes() throws {
        // A backup produced by a build that predates translation_backend and
        // llm_backend must still load, or it vanishes on the next save.
        let legacy: [String: Any] = [
            "id": 1,
            "base_url": "https://legacy.example.test/v1",
            "api_key": "legacy-key",
            "stt_model": "whisper-1",
            "translation_model": "gpt-4o-mini",
            "llm_model": "gpt-4o-mini",
            "stt_backend": "openai",
            "target_language": "zh-Hans",
            "source_language": "en"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(ApiConfig.self, from: data)
        XCTAssertEqual(decoded.baseUrl, "https://legacy.example.test/v1")
        XCTAssertEqual(decoded.translationBackend, "openai")
        XCTAssertEqual(decoded.llmBackend, "openai")
    }

    // MARK: - C9: a note belongs to its session, not to its id

    func testNoteUpsertNeverRepointsAnotherSessionsNote() async throws {
        try ClassNote.Database.shared.setup()
        let sessionA = Session.new(courseId: nil, title: "C9 A")
        let sessionB = Session.new(courseId: nil, title: "C9 B")
        try await SessionRepository.shared.insert(sessionA)
        try await SessionRepository.shared.insert(sessionB)
        addTeardownBlock {
            try? await SessionRepository.shared.delete(id: sessionA.id, force: true)
            try? await SessionRepository.shared.delete(id: sessionB.id, force: true)
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let noteB = Note(id: UUID().uuidString, sessionId: sessionB.id,
                         markdown: "# B", version: 1, generatedAt: now, model: "test-model")
        try await NoteRepository.shared.upsert(noteB)

        // The C9 shape: a generation started for A while B's note was loaded,
        // so it carries B's note id and A's session id.
        let contaminated = Note(id: noteB.id, sessionId: sessionA.id,
                                markdown: "# A", version: 1, generatedAt: now + 1, model: "test-model")
        try await NoteRepository.shared.upsert(contaminated)

        let storedB = try await NoteRepository.shared.get(sessionId: sessionB.id)
        XCTAssertEqual(storedB?.id, noteB.id)
        XCTAssertEqual(storedB?.markdown, "# B")

        let storedA = try await NoteRepository.shared.get(sessionId: sessionA.id)
        XCTAssertEqual(storedA?.markdown, "# A")
        XCTAssertNotEqual(storedA?.id, noteB.id)
    }

    func testIdenticalNoteMarkdownDoesNotAppendAVersion() async throws {
        try ClassNote.Database.shared.setup()
        let session = Session.new(courseId: nil, title: "C9 versions")
        try await SessionRepository.shared.insert(session)
        addTeardownBlock {
            try? await SessionRepository.shared.delete(id: session.id, force: true)
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let note = Note(id: UUID().uuidString, sessionId: session.id,
                        markdown: "# Same", version: 1, generatedAt: now, model: "test-model")
        try await NoteRepository.shared.upsert(note)
        try await NoteRepository.shared.upsert(note)

        let versions = try await NoteRepository.shared.versions(sessionId: session.id)
        XCTAssertEqual(versions.count, 1)

        var changed = note
        changed.markdown = "# Different"
        changed.version = 2
        changed.generatedAt = now + 1
        try await NoteRepository.shared.upsert(changed)
        let afterChange = try await NoteRepository.shared.versions(sessionId: session.id)
        XCTAssertEqual(afterChange.count, 2)
    }

    // MARK: - C13: a recording session cannot be deleted from under the writer

    func testDeleteRefusesARecordingSessionUnlessForced() async throws {
        try ClassNote.Database.shared.setup()
        let session = Session.new(courseId: nil, title: "C13 live")
        XCTAssertEqual(session.state, "recording")
        try await SessionRepository.shared.insert(session)
        addTeardownBlock {
            try? await SessionRepository.shared.delete(id: session.id, force: true)
        }

        do {
            try await SessionRepository.shared.delete(id: session.id)
            XCTFail("Deleting a session that is still recording must be refused")
        } catch {
            XCTAssertTrue(error is SessionRepository.SessionRepositoryError)
        }

        let survivor = try await SessionRepository.shared.get(id: session.id)
        XCTAssertNotNil(survivor)

        // The start-failure cleanup path still has to be able to remove the row.
        try await SessionRepository.shared.delete(id: session.id, force: true)
        let gone = try await SessionRepository.shared.get(id: session.id)
        XCTAssertNil(gone)
    }

    // MARK: - U7: re-transcription swaps the transcript in one transaction

    func testReplaceAllSwapsSegmentsAndReindexesFTS() async throws {
        try ClassNote.Database.shared.setup()
        let session = Session.new(courseId: nil, title: "U7 replace")
        try await SessionRepository.shared.insert(session)
        addTeardownBlock {
            try? await SessionRepository.shared.delete(id: session.id, force: true)
        }

        let stale = Segment(id: nil, sessionId: session.id, startMs: 0, endMs: 1000,
                            speakerId: nil, textOriginal: "obsoletetranscriptline",
                            textTranslated: "", isFinal: true, confidence: 0.9, version: 1)
        _ = try await SegmentRepository.shared.insert(stale)

        let replacement = [
            Segment(id: nil, sessionId: session.id, startMs: 0, endMs: 500,
                    speakerId: nil, textOriginal: "replacementtranscriptline",
                    textTranslated: "", isFinal: true, confidence: 0.9, version: 1),
            Segment(id: nil, sessionId: session.id, startMs: 500, endMs: 1000,
                    speakerId: nil, textOriginal: "secondreplacementline",
                    textTranslated: "", isFinal: true, confidence: 0.9, version: 1)
        ]
        let ids = try await SegmentRepository.shared.replaceAll(sessionId: session.id,
                                                               with: replacement)
        XCTAssertEqual(ids.count, 2)

        let stored = try await SegmentRepository.shared.all(sessionId: session.id)
        XCTAssertEqual(stored.map(\.textOriginal),
                       ["replacementtranscriptline", "secondreplacementline"])

        let staleHits = try await SegmentRepository.shared.searchFTS(query: "obsoletetranscriptline",
                                                                    limit: 10)
        XCTAssertFalse(staleHits.contains(where: { $0.segment.sessionId == session.id }))

        let freshHits = try await SegmentRepository.shared.searchFTS(query: "replacementtranscriptline",
                                                                    limit: 10)
        XCTAssertTrue(freshHits.contains(where: { $0.segment.id == ids.first }))
    }

    // MARK: - U5: a failed translation is distinguishable from an empty one

    func testTranslationStateSeparatesFailuresFromUntried() async throws {
        try ClassNote.Database.shared.setup()
        let session = Session.new(courseId: nil, title: "U5 translation state")
        try await SessionRepository.shared.insert(session)
        addTeardownBlock {
            try? await SessionRepository.shared.delete(id: session.id, force: true)
        }

        let first = Segment(id: nil, sessionId: session.id, startMs: 0, endMs: 500,
                            speakerId: nil, textOriginal: "first line",
                            textTranslated: "", isFinal: true, confidence: 1, version: 1)
        let second = Segment(id: nil, sessionId: session.id, startMs: 500, endMs: 1000,
                             speakerId: nil, textOriginal: "second line",
                             textTranslated: "", isFinal: true, confidence: 1, version: 1)
        let firstId = try await SegmentRepository.shared.insert(first)
        let secondId = try await SegmentRepository.shared.insert(second)

        var pending = try await SegmentRepository.shared.untranslated(sessionId: session.id)
        XCTAssertEqual(Set(pending.compactMap(\.id)), Set([firstId, secondId]))

        try await SegmentRepository.shared.updateTranslation(id: firstId, textTranslated: "第一行")
        try await SegmentRepository.shared.updateTranslation(id: secondId,
                                                             textTranslated: "第二",
                                                             state: .failed)

        pending = try await SegmentRepository.shared.untranslated(sessionId: session.id)
        XCTAssertEqual(pending.compactMap(\.id), [secondId])

        let stored = try await SegmentRepository.shared.all(sessionId: session.id)
        XCTAssertEqual(stored.first(where: { $0.id == firstId })?.translationState, TranslationState.ok)
        XCTAssertEqual(stored.first(where: { $0.id == secondId })?.translationState, TranslationState.failed)
        // The partial text a cancelled stream produced is kept, not discarded.
        XCTAssertEqual(stored.first(where: { $0.id == secondId })?.textTranslated, "第二")
    }

    func testTranslationStateBackfillMarksAlreadyTranslatedRows() async throws {
        try ClassNote.Database.shared.setup()
        let session = Session.new(courseId: nil, title: "U5 backfill")
        try await SessionRepository.shared.insert(session)
        addTeardownBlock {
            try? await SessionRepository.shared.delete(id: session.id, force: true)
        }

        // A row as an older build left it: translated, but with no state column
        // value of its own. The v10 backfill is the same UPDATE.
        let rowId: Int64 = try await ClassNote.Database.shared.dbPool.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO segment (session_id, start_ms, end_ms, text_original, text_translated, is_final)
                VALUES (?, 0, 1000, 'pre-existing line', '既有译文', 1)
                """, arguments: [session.id])
            return db.lastInsertedRowID
        }
        try await ClassNote.Database.shared.dbPool.write { db in
            try db.execute(sql: "UPDATE segment SET translation_state = 1 WHERE text_translated <> '' AND id = ?",
                           arguments: [rowId])
        }

        let stored = try await SegmentRepository.shared.all(sessionId: session.id)
        XCTAssertEqual(stored.first?.translationState, TranslationState.ok)
        let pending = try await SegmentRepository.shared.untranslated(sessionId: session.id)
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - U10: course glossary round-trips and renders

    func testCourseGlossaryRoundTripsAndRendersPromptBlocks() async throws {
        try ClassNote.Database.shared.setup()
        let course: Course = {
            var draft = Course.new(name: "U10 Thermodynamics")
            draft.instructor = "Dr. Grey"
            draft.glossary = "entropy = 熵\neigenvalue = 特征值"
            return draft
        }()
        try await CourseRepository.shared.insert(course)
        let session = Session.new(courseId: course.id, title: "U10 lecture")
        try await SessionRepository.shared.insert(session)
        let courseId = course.id
        let sessionId = session.id
        addTeardownBlock {
            try? await SessionRepository.shared.delete(id: sessionId, force: true)
            try? await CourseRepository.shared.delete(id: courseId)
        }

        let resolved = try await CourseRepository.shared.forSession(id: session.id)
        XCTAssertEqual(resolved?.id, course.id)
        XCTAssertEqual(resolved?.glossary, "entropy = 熵\neigenvalue = 特征值")

        let context = CourseContext(course: resolved)
        XCTAssertFalse(context.isEmpty)
        XCTAssertTrue(context.promptBlock.contains("Dr. Grey"))
        XCTAssertTrue(context.promptBlock.contains("entropy = 熵"))
        XCTAssertTrue(context.translationGlossaryBlock.contains("eigenvalue = 特征值"))
        XCTAssertTrue(CourseContext.empty.isEmpty)
        XCTAssertEqual(CourseContext(course: nil), CourseContext.empty)
        XCTAssertEqual(CourseContext.empty.promptBlock, "")
        XCTAssertEqual(CourseContext.empty.translationGlossaryBlock, "")
    }

    // MARK: - C14: an endpoint that issues no tokens needs no key

    func testProviderPresetsDescribeKeyRequirements() throws {
        let ollama = try XCTUnwrap(ApiConfig.providerPresets.first(where: { $0.label == "Ollama" }))
        XCTAssertNil(ollama.sttModel)
        XCTAssertFalse(ollama.requiresApiKey)

        var local = ApiConfig.default
        local.baseUrl = "http://localhost:11434/v1"
        local.apiKey = ""
        XCTAssertFalse(local.requiresApiKey)
        XCTAssertFalse(local.isCloudCredentialMissing)

        var cloud = ApiConfig.default
        cloud.apiKey = ""
        XCTAssertTrue(cloud.requiresApiKey)
        XCTAssertTrue(cloud.isCloudCredentialMissing)
    }
}
