import Foundation
import XCTest
import GRDB
@testable import ClassNote

/// Two Macs: two independent libraries sharing one sync folder.
final class LibrarySyncTests: XCTestCase {
    private var workspace: URL!

    private var root: URL { workspace.appendingPathComponent("iCloud Drive/ClassNote", isDirectory: true) }

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("librarysync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    private struct Mac {
        let db: DatabaseQueue
        let sync: LibrarySync
        let recordings: URL
        let voiceMemos: URL
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
        return Mac(db: db, sync: sync, recordings: recordings, voiceMemos: voiceMemos)
    }

    @discardableResult
    private func addLecture(on mac: Mac, title: String, courseId: String? = nil,
                            audioPath: String? = nil, state: SessionState = .transcribed) throws -> String {
        var draft = Session.new(courseId: courseId, title: title)
        draft.state = state.rawValue
        draft.audioPath = audioPath
        let session = draft
        try mac.db.write { db in
            try session.insert(db)
            var segment = Segment(id: nil, sessionId: session.id, startMs: 0, endMs: 1_000, speakerId: nil,
                                  textOriginal: "Eigenvalues", textTranslated: "特征值", isFinal: true,
                                  confidence: 1, version: 1, translationState: .ok)
            try segment.insert(db)
            try Note(id: UUID().uuidString, sessionId: session.id, markdown: "# Notes", version: 1,
                     generatedAt: 1, model: nil).insert(db)
            var card = Flashcard(id: nil, sessionId: session.id, front: "Q", back: "A", sourceModel: nil,
                                 createdAt: 1, sortOrder: 0)
            try card.insert(db)
        }
        return session.id
    }

    private func session(_ id: String, on mac: Mac) throws -> Session? {
        try mac.db.read { db in try Session.fetchOne(db, key: id) }
    }

    private func setTitle(_ title: String, of id: String, on mac: Mac) throws {
        try mac.db.write { db in
            try db.execute(sql: "UPDATE session SET title = ? WHERE id = ?", arguments: [title, id])
        }
    }

    private func assertIdle(_ mac: Mac, file: StaticString = #filePath, line: UInt = #line) throws {
        let report = try mac.sync.run()
        XCTAssertEqual(report.pushed + report.pulled + report.deleted, 0, "not idle: \(report)", file: file, line: line)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)", file: file, line: line)
    }

    // MARK: -

    func testALectureReachesTheOtherMacWithEverythingInIt() throws {
        let a = try mac("A"), b = try mac("B")
        let course = Course.new(name: "Linear Algebra")
        try a.db.write { db in try course.insert(db) }
        let id = try addLecture(on: a, title: "Week 1", courseId: course.id)

        let pushed = try a.sync.run()
        XCTAssertEqual(pushed.pushed, 2)
        XCTAssertTrue(pushed.failures.isEmpty, "\(pushed.failures)")
        let pulled = try b.sync.run()
        XCTAssertEqual(pulled.pulled, 2)
        XCTAssertTrue(pulled.failures.isEmpty, "\(pulled.failures)")

        try b.db.read { db in
            let session = try XCTUnwrap(Session.fetchOne(db, key: id))
            XCTAssertEqual(session.title, "Week 1")
            XCTAssertEqual(session.courseId, course.id)
            XCTAssertEqual(try Course.fetchOne(db, key: course.id)?.name, "Linear Algebra")
            XCTAssertEqual(try Segment.filter(Column("session_id") == id).fetchAll(db).map(\.textTranslated), ["特征值"])
            XCTAssertEqual(try Note.filter(Column("session_id") == id).fetchOne(db)?.markdown, "# Notes")
            XCTAssertEqual(try Flashcard.filter(Column("session_id") == id).fetchCount(db), 1)
        }
        // Nothing changed since: neither side echoes the other.
        try assertIdle(a)
        try assertIdle(b)
    }

    func testAnEditOnOneMacReachesTheOther() throws {
        let a = try mac("A"), b = try mac("B")
        let id = try addLecture(on: a, title: "Week 1")
        _ = try a.sync.run()
        _ = try b.sync.run()

        try setTitle("Week 1: Eigenvalues", of: id, on: b)
        XCTAssertEqual(try b.sync.run().pushed, 1)
        XCTAssertEqual(try a.sync.run().pulled, 1)

        XCTAssertEqual(try session(id, on: a)?.title, "Week 1: Eigenvalues")
        try assertIdle(a)
        try assertIdle(b)
    }

    func testWhenBothMacsChangedALectureTheLaterChangeWins() throws {
        let a = try mac("A"), b = try mac("B")
        let id = try addLecture(on: a, title: "Week 1")
        _ = try a.sync.run()
        _ = try b.sync.run()

        try setTitle("Edited on A", of: id, on: a)
        Thread.sleep(forTimeInterval: 0.01)
        try setTitle("Edited on B", of: id, on: b)
        _ = try a.sync.run()
        XCTAssertEqual(try b.sync.run().pushed, 1)
        XCTAssertEqual(try a.sync.run().pulled, 1)

        XCTAssertEqual(try session(id, on: a)?.title, "Edited on B")
        XCTAssertEqual(try session(id, on: b)?.title, "Edited on B")
    }

    func testADeletionReachesTheOtherMac() throws {
        let a = try mac("A"), b = try mac("B")
        let id = try addLecture(on: a, title: "Week 1")
        _ = try a.sync.run()
        _ = try b.sync.run()

        try a.db.write { db in try db.execute(sql: "DELETE FROM session WHERE id = ?", arguments: [id]) }
        _ = try a.sync.run()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.sync.sessionDirectory(id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.sync.tombstoneFile(kind: "session", id: id).path))

        XCTAssertEqual(try b.sync.run().deleted, 1)
        XCTAssertNil(try session(id, on: b))
        try assertIdle(a)
        try assertIdle(b)
    }

    func testAnEditMadeAfterADeletionBringsTheLectureBack() throws {
        let a = try mac("A"), b = try mac("B")
        let id = try addLecture(on: a, title: "Week 1")
        _ = try a.sync.run()
        _ = try b.sync.run()

        try a.db.write { db in try db.execute(sql: "DELETE FROM session WHERE id = ?", arguments: [id]) }
        Thread.sleep(forTimeInterval: 0.01)
        try setTitle("Still needed", of: id, on: b)
        _ = try a.sync.run()
        _ = try b.sync.run()
        _ = try a.sync.run()

        XCTAssertEqual(try session(id, on: a)?.title, "Still needed")
        XCTAssertEqual(try session(id, on: b)?.title, "Still needed")
    }

    func testADeletedCourseUnfilesItsLecturesWithoutLosingAnEditFromTheSameMac() throws {
        let a = try mac("A"), b = try mac("B")
        let course = Course.new(name: "Linear Algebra")
        try a.db.write { db in try course.insert(db) }
        let id = try addLecture(on: a, title: "Week 1", courseId: course.id)
        _ = try a.sync.run()
        _ = try b.sync.run()

        try setTitle("Week 1, renamed", of: id, on: a)
        try a.db.write { db in try db.execute(sql: "DELETE FROM course WHERE id = ?", arguments: [course.id]) }
        _ = try a.sync.run()
        _ = try b.sync.run()

        try b.db.read { db in
            XCTAssertNil(try Course.fetchOne(db, key: course.id))
            let session = try XCTUnwrap(Session.fetchOne(db, key: id))
            XCTAssertNil(session.courseId)
            XCTAssertEqual(session.title, "Week 1, renamed")
        }
        try assertIdle(a)
        try assertIdle(b)
    }

    func testAFinishedRecordingMovesIntoTheSyncFolder() throws {
        let a = try mac("A"), b = try mac("B")
        let recording = a.recordings.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: recording)
        let id = try addLecture(on: a, title: "Week 1", audioPath: recording.path)

        XCTAssertTrue(try a.sync.run().changedSessionIds.contains(id))

        let synced = a.sync.sessionDirectory(id).appendingPathComponent("audio.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: synced.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path))
        XCTAssertEqual(try session(id, on: a)?.audioPath, synced.path)

        _ = try b.sync.run()
        XCTAssertEqual(try session(id, on: b)?.audioPath, synced.path)
        try assertIdle(a)
        try assertIdle(b)
    }

    func testALectureStillBeingRecordedIsLeftAlone() throws {
        let a = try mac("A")
        let recording = a.recordings.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: recording)
        let id = try addLecture(on: a, title: "Live", audioPath: recording.path, state: .recording)

        XCTAssertEqual(try a.sync.run().pushed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.sync.sessionFile(id).path))
    }

    func testAVoiceMemoIsFoundInTheOtherMacsOwnVoiceMemos() throws {
        let a = try mac("A"), b = try mac("B")
        let name = "20260901 090000-AAAA.m4a"
        try Data("memo".utf8).write(to: a.voiceMemos.appendingPathComponent(name))
        try Data("memo".utf8).write(to: b.voiceMemos.appendingPathComponent(name))
        let id = try addLecture(on: a, title: "Week 1", audioPath: a.voiceMemos.appendingPathComponent(name).path)

        _ = try a.sync.run()
        _ = try b.sync.run()

        // Left where Voice Memos keeps it on A, and found in B's own library.
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.voiceMemos.appendingPathComponent(name).path))
        XCTAssertEqual(try session(id, on: b)?.audioPath, b.voiceMemos.appendingPathComponent(name).path)
    }

    func testALectureWrittenByANewerClassNoteIsLeftAlone() throws {
        let a = try mac("A"), b = try mac("B")
        let id = try addLecture(on: a, title: "Week 1")
        _ = try a.sync.run()

        let file = a.sync.sessionFile(id)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["format"] = LibrarySync.format + 1
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        XCTAssertEqual(try b.sync.run().pulled, 0)
        XCTAssertNil(try session(id, on: b))
        // And A does not overwrite it with the older format.
        try setTitle("Edited on A", of: id, on: a)
        XCTAssertEqual(try a.sync.run().pushed, 0)
    }
}
