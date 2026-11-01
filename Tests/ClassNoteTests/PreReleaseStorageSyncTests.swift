import Foundation
import XCTest
import GRDB
@testable import ClassNote

/// Storage and sync bugs found before a release, each reproduced as the
/// sequence of events that lost data. Two Macs are two in-memory libraries
/// sharing a temporary sync folder, as in LibrarySyncTests.
final class PreReleaseStorageSyncTests: XCTestCase {
    private var workspace: URL!

    private var root: URL { workspace.appendingPathComponent("iCloud Drive/ClassNote", isDirectory: true) }

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("prerelease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    private struct Mac {
        let db: DatabaseQueue
        let sync: LibrarySync
        let recordings: URL
    }

    private func mac(_ name: String) throws -> Mac {
        let db = try DatabaseQueue()
        try ClassNote.Database.migrator.migrate(db)
        let recordings = workspace.appendingPathComponent("\(name)/recordings", isDirectory: true)
        let voiceMemos = workspace.appendingPathComponent("\(name)/VoiceMemos", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: voiceMemos, withIntermediateDirectories: true)
        var sync = LibrarySync(db: db, root: root, recordingsRoot: recordings, deviceName: name)
        sync.voiceMemoDirectories = [voiceMemos]
        return Mac(db: db, sync: sync, recordings: recordings)
    }

    @discardableResult
    private func addLecture(on mac: Mac, id: String = UUID().uuidString, title: String,
                            audioPath: String? = nil) throws -> String {
        var draft = Session.new(courseId: nil, title: title)
        draft.id = id
        draft.state = SessionState.transcribed.rawValue
        draft.audioPath = audioPath
        let session = draft
        try mac.db.write { db in
            try session.insert(db)
            var segment = Segment(id: nil, sessionId: session.id, startMs: 0, endMs: 1_000, speakerId: nil,
                                  textOriginal: "Eigenvalues", textTranslated: "特征值", isFinal: true,
                                  confidence: 1, version: 1, translationState: .ok)
            try segment.insert(db)
        }
        return session.id
    }

    /// As `SessionRepository.delete` does it: the row, then the recording.
    private func deleteLecture(_ id: String, on mac: Mac) throws {
        let audioPath = try mac.db.write { db -> String? in
            let path = try String.fetchOne(db, sql: "SELECT audio_path FROM session WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM session WHERE id = ?", arguments: [id])
            return path
        }
        AppBootstrap.deleteManagedRecording(path: audioPath)
    }

    private func session(_ id: String, on mac: Mac) throws -> Session? {
        try mac.db.read { db in try Session.fetchOne(db, key: id) }
    }

    private func setTitle(_ title: String, of id: String, on mac: Mac) throws {
        try mac.db.write { db in
            try db.execute(sql: "UPDATE session SET title = ? WHERE id = ?", arguments: [title, id])
        }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func assertIdle(_ mac: Mac, file: StaticString = #filePath, line: UInt = #line) throws {
        let report = try mac.sync.run()
        XCTAssertEqual(report.pushed + report.pulled + report.deleted, 0, "not idle: \(report)", file: file, line: line)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)", file: file, line: line)
    }

    /// The same Mac once the grace period for deleted recordings is over.
    private func afterGracePeriod(_ mac: Mac) -> LibrarySync {
        var sync = mac.sync
        sync.recordingGracePeriod = 0
        return sync
    }

    // MARK: - S1: a deletion that an edit undoes keeps the recording

    func testALectureAnEditBringsBackAfterADeletionStillHasItsRecording() throws {
        let a = try mac("A"), b = try mac("B")
        let recording = a.recordings.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: recording)
        let id = try addLecture(on: a, title: "Week 1", audioPath: recording.path)
        _ = try a.sync.run()
        _ = try b.sync.run()
        let synced = a.sync.sessionDirectory(id).appendingPathComponent("audio.m4a")
        XCTAssertEqual(try session(id, on: b)?.audioPath, synced.path)

        // A deletes it; B edits it before the deletion reaches B.
        try deleteLecture(id, on: a)
        XCTAssertTrue(exists(synced), "deleting a lecture must not delete its synced recording")
        Thread.sleep(forTimeInterval: 0.01)
        try setTitle("Still needed", of: id, on: b)

        _ = try a.sync.run()
        XCTAssertFalse(exists(a.sync.sessionFile(id)))
        XCTAssertTrue(exists(synced), "the tombstone push must leave the recording")
        _ = try b.sync.run()
        _ = try a.sync.run()

        XCTAssertEqual(try session(id, on: a)?.title, "Still needed")
        XCTAssertEqual(try session(id, on: a)?.audioPath, synced.path)
        XCTAssertEqual(try session(id, on: b)?.audioPath, synced.path)
        XCTAssertTrue(exists(synced))

        // A lecture that came back keeps its recording past the grace period.
        Thread.sleep(forTimeInterval: 0.01)
        _ = try afterGracePeriod(a).run()
        _ = try afterGracePeriod(b).run()
        XCTAssertTrue(exists(synced))
        try assertIdle(a)
        try assertIdle(b)
    }

    func testADeletedLecturesRecordingGoesOnlyOnceTheGracePeriodIsOver() throws {
        let a = try mac("A"), b = try mac("B")
        let recording = a.recordings.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: recording)
        let id = try addLecture(on: a, title: "Week 1", audioPath: recording.path)
        _ = try a.sync.run()
        _ = try b.sync.run()
        let synced = a.sync.sessionDirectory(id).appendingPathComponent("audio.m4a")

        try deleteLecture(id, on: a)
        _ = try a.sync.run()
        XCTAssertEqual(try b.sync.run().deleted, 1)
        XCTAssertNil(try session(id, on: b))
        XCTAssertTrue(exists(synced))

        // Neither the orphan sweep, which only looks at Application Support,
        // nor a sync pass within the grace period removes it.
        AppBootstrap.cleanupOrphanedRecordings(referencedPaths: [], recordingsRoot: a.recordings)
        AppBootstrap.cleanupOrphanedRecordings(referencedPaths: [], recordingsRoot: b.recordings)
        try assertIdle(a)
        try assertIdle(b)
        XCTAssertTrue(exists(synced))

        Thread.sleep(forTimeInterval: 0.01)
        let report = try afterGracePeriod(b).run()
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertFalse(exists(a.sync.sessionDirectory(id)))
        try assertIdle(a)
    }

    func testDeletingALectureRemovesOnlyARecordingInApplicationSupport() async throws {
        try ClassNote.Database.shared.setup()
        var local = Session.new(courseId: nil, title: "local recording")
        local.state = SessionState.transcribed.rawValue
        let localFile = AppBootstrap.recordingURL(sessionId: local.id)
        local.audioPath = localFile.path
        var synced = Session.new(courseId: nil, title: "synced recording")
        synced.state = SessionState.transcribed.rawValue
        let folder = root.appendingPathComponent("Sessions/\(synced.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let syncedFile = folder.appendingPathComponent("audio.m4a")
        synced.audioPath = syncedFile.path
        try Data("local".utf8).write(to: localFile)
        try Data("synced".utf8).write(to: syncedFile)
        try await SessionRepository.shared.insert(local)
        try await SessionRepository.shared.insert(synced)

        try await SessionRepository.shared.delete(id: local.id)
        try await SessionRepository.shared.delete(id: synced.id)

        XCTAssertFalse(exists(localFile))
        XCTAssertTrue(exists(syncedFile))
    }

    // MARK: - S2: an older edit written last does not overwrite a later one

    func testAnOlderEditPushedLastDoesNotOverwriteALaterOne() throws {
        let a = try mac("A"), b = try mac("B")
        let id = try addLecture(on: a, title: "Week 1")
        _ = try a.sync.run()
        _ = try b.sync.run()
        let lastSeenByA = try Data(contentsOf: a.sync.sessionFile(id))

        try setTitle("A, before it slept", of: id, on: a)
        Thread.sleep(forTimeInterval: 0.01)
        try setTitle("B, later", of: id, on: b)
        XCTAssertEqual(try b.sync.run().pushed, 1)

        // A wakes before iCloud has brought it B's file and pushes its older
        // edit; iCloud keeps the file written last, A's.
        try lastSeenByA.write(to: a.sync.sessionFile(id))
        XCTAssertEqual(try a.sync.run().pushed, 1)

        // Unchanged on B since, but the file was not made from B's version.
        let onB = try b.sync.run()
        XCTAssertEqual(onB.pulled, 0)
        XCTAssertEqual(onB.pushed, 1)
        XCTAssertEqual(try a.sync.run().pulled, 1)

        XCTAssertEqual(try session(id, on: a)?.title, "B, later")
        XCTAssertEqual(try session(id, on: b)?.title, "B, later")
        try assertIdle(a)
        try assertIdle(b)
    }

    func testTheSameVersionWrittenAgainSettlesInsteadOfBouncing() throws {
        let a = try mac("A"), b = try mac("B")
        let id = try addLecture(on: a, title: "Week 1")
        _ = try a.sync.run()
        _ = try b.sync.run()

        // B loses what it last exchanged (a restored database) and, meeting the
        // lecture as if for the first time, writes the same version again.
        try b.db.write { db in try db.execute(sql: "DELETE FROM sync_state") }
        XCTAssertEqual(try b.sync.run().pushed, 1)
        // Same modifiedAt, new revision: A takes it rather than pushing back.
        XCTAssertEqual(try a.sync.run().pulled, 1)

        XCTAssertEqual(try session(id, on: a)?.title, "Week 1")
        try assertIdle(a)
        try assertIdle(b)
    }

    func testOnAFirstSyncTheLaterVersionWinsEitherWay() throws {
        let a = try mac("A"), b = try mac("B")
        let changedOnA = try addLecture(on: a, title: "Week 1")
        let changedOnB = try addLecture(on: a, title: "Week 2")
        _ = try a.sync.run()
        _ = try b.sync.run()

        // B forgets the sync; meanwhile A changes one lecture and B the other.
        try b.db.write { db in try db.execute(sql: "DELETE FROM sync_state") }
        try setTitle("Changed on A", of: changedOnA, on: a)
        Thread.sleep(forTimeInterval: 0.01)
        try setTitle("Changed on B", of: changedOnB, on: b)
        _ = try a.sync.run()
        _ = try b.sync.run()
        _ = try a.sync.run()

        XCTAssertEqual(try session(changedOnA, on: b)?.title, "Changed on A")
        XCTAssertEqual(try session(changedOnB, on: a)?.title, "Changed on B")
        try assertIdle(a)
        try assertIdle(b)
    }

    // MARK: - S3: a busy state never freezes a lecture on another Mac

    func testALectureThatBecomesBusyDuringAPassIsNotPushedBusy() throws {
        let a = try mac("A"), b = try mac("B")
        // Sorted, as the pass takes them: `first` is handled before `later`.
        let first = "00000000-0000-0000-0000-000000000001"
        let later = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        try addLecture(on: a, id: later, title: "Week 2")
        _ = try a.sync.run()
        _ = try b.sync.run()
        try setTitle("Week 2, renamed", of: later, on: a)

        // The pass has read both lectures; while it moves the first one's
        // recording, a re-transcription of the later one starts.
        let recording = a.recordings.appendingPathComponent("\(first).m4a")
        try Data("audio".utf8).write(to: recording)
        try addLecture(on: a, id: first, title: "Week 1", audioPath: recording.path)
        try a.db.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER start_retranscription AFTER UPDATE OF audio_path ON session
                WHEN new.id = '\(first)' BEGIN
                    UPDATE session SET state = 'transcribing' WHERE id = '\(later)';
                END
                """)
        }
        _ = try a.sync.run()
        _ = try b.sync.run()
        XCTAssertNotNil(try session(first, on: b))
        XCTAssertEqual(try session(later, on: b)?.title, "Week 2")
        XCTAssertEqual(try session(later, on: b)?.state, SessionState.transcribed.rawValue)

        // Once it is done, the next pass sends it.
        try a.db.write { db in
            try db.execute(sql: "DROP TRIGGER start_retranscription")
            try db.execute(sql: "UPDATE session SET state = 'transcribed' WHERE id = ?", arguments: [later])
        }
        _ = try a.sync.run()
        _ = try b.sync.run()
        XCTAssertEqual(try session(later, on: b)?.title, "Week 2, renamed")
        XCTAssertEqual(try session(later, on: b)?.state, SessionState.transcribed.rawValue)
    }

    func testABusyStatePushedByAnOlderClassNoteIsNotBusyHere() throws {
        let a = try mac("A"), b = try mac("B")
        let id = try addLecture(on: a, title: "Week 1")
        _ = try a.sync.run()

        // An older ClassNote on A pushed it mid re-transcription.
        let file = a.sync.sessionFile(id)
        var snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: file))
        snapshot.session.state = SessionState.transcribing.rawValue
        snapshot.modifiedAt += 1
        snapshot.revision = UUID().uuidString
        try JSONEncoder().encode(snapshot).write(to: file)

        XCTAssertEqual(try b.sync.run().pulled, 1)
        XCTAssertEqual(try session(id, on: b)?.state, SessionState.transcribed.rawValue)

        // Later changes still arrive, and so does a deletion.
        _ = try a.sync.run()
        try setTitle("Week 1, renamed", of: id, on: a)
        _ = try a.sync.run()
        XCTAssertEqual(try b.sync.run().pulled, 1)
        XCTAssertEqual(try session(id, on: b)?.title, "Week 1, renamed")
        try deleteLecture(id, on: a)
        _ = try a.sync.run()
        XCTAssertEqual(try b.sync.run().deleted, 1)
    }

    func testALectureLeftBusyByAnOlderPullIsUpdatedAndDeletedAgain() throws {
        let a = try mac("A"), b = try mac("B")
        let renamed = try addLecture(on: a, title: "Week 1")
        let deleted = try addLecture(on: a, title: "Week 2")
        _ = try a.sync.run()
        _ = try b.sync.run()

        // As an older build left them on B: pulled busy, unchanged here since.
        try b.db.write { db in
            for id in [renamed, deleted] {
                try db.execute(sql: """
                    UPDATE session SET state = 'transcribing', modified_at = modified_at + 1 WHERE id = ?
                    """, arguments: [id])
                try db.execute(sql: """
                    UPDATE sync_state SET local_modified_at = local_modified_at + 1
                    WHERE kind = 'session' AND id = ?
                    """, arguments: [id])
            }
        }
        Thread.sleep(forTimeInterval: 0.01)
        try setTitle("Week 1, renamed", of: renamed, on: a)
        try deleteLecture(deleted, on: a)
        _ = try a.sync.run()
        let report = try b.sync.run()

        XCTAssertEqual(report.pulled, 1)
        XCTAssertEqual(report.deleted, 1)
        XCTAssertEqual(try session(renamed, on: b)?.title, "Week 1, renamed")
        XCTAssertEqual(try session(renamed, on: b)?.state, SessionState.transcribed.rawValue)
        XCTAssertNil(try session(deleted, on: b))
    }

    func testALectureBusyOnThisMacIsStillLeftAlone() throws {
        let a = try mac("A"), b = try mac("B")
        let id = try addLecture(on: a, title: "Week 1")
        _ = try a.sync.run()
        _ = try b.sync.run()

        // B starts re-transcribing it; meanwhile A renames it, then deletes it.
        try b.db.write { db in
            try db.execute(sql: "UPDATE session SET state = 'transcribing' WHERE id = ?", arguments: [id])
        }
        try setTitle("Week 1, renamed", of: id, on: a)
        _ = try a.sync.run()
        XCTAssertEqual(try b.sync.run().pulled, 0)
        XCTAssertEqual(try session(id, on: b)?.title, "Week 1")

        try deleteLecture(id, on: a)
        _ = try a.sync.run()
        XCTAssertEqual(try b.sync.run().deleted, 0)
        XCTAssertNotNil(try session(id, on: b))
    }

    // MARK: - S4: a deletion is stamped after the change it removes

    func testDeletingALectureFromAMacWhoseClockRunsAheadSticks() throws {
        let a = try mac("A"), b = try mac("B")
        let id = try addLecture(on: b, title: "Week 1")
        // B's clock runs ten minutes ahead.
        try b.db.write { db in
            try db.execute(sql: "UPDATE session SET modified_at = modified_at + 600000 WHERE id = ?", arguments: [id])
        }
        _ = try b.sync.run()
        _ = try a.sync.run()
        XCTAssertNotNil(try session(id, on: a))

        try deleteLecture(id, on: a)
        _ = try a.sync.run()
        XCTAssertNil(try session(id, on: a), "the deletion was undone by B's future modified_at")
        XCTAssertFalse(exists(a.sync.sessionFile(id)))
        XCTAssertEqual(try b.sync.run().deleted, 1)
        XCTAssertNil(try session(id, on: b))
        try assertIdle(a)
        try assertIdle(b)
    }

    func testTheDeletionTriggersAreReplacedInAnExistingLibrary() throws {
        let db = try DatabaseQueue()
        try ClassNote.Database.migrator.migrate(db, upTo: "v17_library_sync")
        try ClassNote.Database.migrator.migrate(db)

        let future = Int64(Date().timeIntervalSince1970 * 1000) + 600_000
        let session = Session.new(courseId: nil, title: "From a Mac ahead")
        let course = Course.new(name: "Linear Algebra")
        let past = Session.new(courseId: nil, title: "Ordinary")
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        try db.write { db in
            try session.insert(db)
            try course.insert(db)
            try past.insert(db)
            try db.execute(sql: "UPDATE session SET modified_at = ? WHERE id = ?", arguments: [future, session.id])
            try db.execute(sql: "UPDATE course SET modified_at = ? WHERE id = ?", arguments: [future, course.id])
            try db.execute(sql: "DELETE FROM session")
            try db.execute(sql: "DELETE FROM course")
        }
        let after = Int64(Date().timeIntervalSince1970 * 1000)

        try db.read { db in
            func deletedAt(_ kind: String, _ id: String) throws -> Int64? {
                try Int64.fetchOne(db, sql: "SELECT deleted_at FROM sync_tombstone WHERE kind = ? AND id = ?",
                                   arguments: [kind, id])
            }
            XCTAssertEqual(try deletedAt("session", session.id), future + 1)
            XCTAssertEqual(try deletedAt("course", course.id), future + 1)
            let ordinary = try XCTUnwrap(try deletedAt("session", past.id))
            XCTAssertGreaterThanOrEqual(ordinary, before)
            XCTAssertLessThanOrEqual(ordinary, after + 1)
        }
    }

    // MARK: - S5: the translation glossary keeps whole lines

    func testTheTranslationGlossaryIsCutAtALineEnd() {
        let line = "eigenvector = 特征向量"
        var raw = ""
        while raw.count <= TranslationGlossary.promptLimit + 40 { raw += line + "\n" }

        let kept = TranslationGlossary.wholeLines(of: raw, upTo: TranslationGlossary.promptLimit)
        XCTAssertLessThanOrEqual(kept.count, TranslationGlossary.promptLimit)
        XCTAssertGreaterThan(kept.count, TranslationGlossary.promptLimit - line.count - 1)
        XCTAssertEqual(Set(kept.split(whereSeparator: \.isNewline).map(String.init)), [line])
        let block = TranslationGlossary(raw: raw).promptBlock
        XCTAssertTrue(block.hasSuffix("\n" + line), block)
    }

    func testTheGlossaryCutKeepsALineThatEndsExactlyAtTheLimit() {
        let first = String(repeating: "a", count: 9)
        XCTAssertEqual(TranslationGlossary.wholeLines(of: first + "\nb = c", upTo: 9), first)
        XCTAssertEqual(TranslationGlossary.wholeLines(of: "a = b\nc = d", upTo: 100), "a = b\nc = d")
        // No whole line fits: nothing is sent rather than half a rendering.
        XCTAssertEqual(TranslationGlossary.wholeLines(of: "eigenvector = 特征向量", upTo: 16), "")
        let long = TranslationGlossary(raw: String(repeating: "x", count: TranslationGlossary.promptLimit + 1))
        XCTAssertEqual(long.promptBlock, "")
    }

    // MARK: - S6: no API key in UserDefaults

    private func scratchDefaults() throws -> (UserDefaults, String) {
        let name = "com.beluga.classnote.tests.prerelease.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (defaults, name)
    }

    /// The suite's own value: a read through the suite falls through to the
    /// host app's domain when the suite has none.
    private func storedBackup(in defaults: UserDefaults, suite: String) -> Data? {
        defaults.persistentDomain(forName: suite)?[ApiConfigBackupStore.key] as? Data
    }

    func testAnOlderBackupHasItsKeysScrubbedAndKeepsTheRest() throws {
        let (defaults, suite) = try scratchDefaults()
        var old = ApiConfig.default
        old.baseUrl = "https://backup.example.test/v1"
        old.llmModel = "backup-llm"
        old.apiKey = "sk-old-backup-do-not-keep"
        old.anthropicApiKey = "sk-ant-old-backup-do-not-keep"
        // As builds before this one wrote it.
        defaults.set(try JSONEncoder().encode(old), forKey: ApiConfigBackupStore.key)

        ApiConfigBackupStore.scrubKeys(in: defaults)

        let stored = try XCTUnwrap(storedBackup(in: defaults, suite: suite))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("do-not-keep"))
        let restored = try XCTUnwrap(ApiConfigBackupStore.read(from: defaults))
        XCTAssertEqual(restored.baseUrl, "https://backup.example.test/v1")
        XCTAssertEqual(restored.llmModel, "backup-llm")
        XCTAssertEqual(restored.apiKey, "")
        XCTAssertEqual(restored.anthropicApiKey, "")
    }

    func testAnUnreadableBackupIsRemovedRatherThanKept() throws {
        let (defaults, suite) = try scratchDefaults()
        defaults.set(Data("api_key=sk-garbled-do-not-keep".utf8), forKey: ApiConfigBackupStore.key)
        ApiConfigBackupStore.scrubKeys(in: defaults)
        XCTAssertNil(storedBackup(in: defaults, suite: suite))
    }

    func testSavingTheBackupLeavesTheKeysOut() throws {
        let (defaults, suite) = try scratchDefaults()
        var config = ApiConfig.default
        config.baseUrl = "https://example.test/v1"
        config.apiKey = "sk-new-do-not-keep"
        config.anthropicApiKey = "sk-ant-new-do-not-keep"
        ApiConfigBackupStore.save(config, to: defaults)

        let stored = try XCTUnwrap(storedBackup(in: defaults, suite: suite))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("do-not-keep"))
        XCTAssertEqual(ApiConfigBackupStore.read(from: defaults)?.baseUrl, "https://example.test/v1")
    }

    func testLoadingTheConfigAtLaunchScrubsAnOlderBackup() async throws {
        try ClassNote.Database.shared.setup()
        let previous = try await ApiConfigRepository.shared.load()
        addTeardownBlock {
            try? await ApiConfigRepository.shared.save(previous)
            ApiConfigBackupStore.clear()
        }
        // A saved row, so the backup is not restored over it.
        var saved = ApiConfig.default
        saved.apiKey = "sk-database-do-not-keep"
        try await ApiConfigRepository.shared.save(saved)

        var old = ApiConfig.default
        old.apiKey = "sk-old-backup-do-not-keep"
        AppEnvironment.defaults.set(try JSONEncoder().encode(old), forKey: ApiConfigBackupStore.key)

        let loaded = try await ApiConfigRepository.shared.load()
        XCTAssertEqual(loaded.apiKey, "sk-database-do-not-keep")
        let stored = try XCTUnwrap(AppEnvironment.defaults.data(forKey: ApiConfigBackupStore.key))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("do-not-keep"))
    }
}
