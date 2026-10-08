import Foundation
import XCTest
import GRDB
@testable import ClassNote

/// The Voice Memos library is read from a fixture laid out like the real one:
/// audio files next to a Core Data store with a `ZCLOUDRECORDING` table.
final class VoiceMemosLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicememos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private struct Fixture {
        var path: String?
        var title: String? = nil
        var label: String? = nil
        var date: Double? = nil
        var duration: Double? = nil
        var evicted: Double? = nil
    }

    @discardableResult
    private func touch(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        return url
    }

    /// Returns the open queue: in WAL mode the rows stay in the -wal only while
    /// it is open.
    @discardableResult
    private func makeDatabase(_ rows: [Fixture], wal: Bool = false) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: root.appendingPathComponent(VoiceMemosLibrary.databaseName).path)
        if wal {
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
        }
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE ZCLOUDRECORDING (
                    Z_PK INTEGER PRIMARY KEY, ZPATH VARCHAR, ZENCRYPTEDTITLE VARCHAR,
                    ZCUSTOMLABEL VARCHAR, ZDATE TIMESTAMP, ZDURATION FLOAT, ZEVICTIONDATE TIMESTAMP)
                """)
            for row in rows {
                try db.execute(sql: """
                    INSERT INTO ZCLOUDRECORDING (ZPATH, ZENCRYPTEDTITLE, ZCUSTOMLABEL, ZDATE, ZDURATION, ZEVICTIONDATE)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [row.path, row.title, row.label, row.date, row.duration, row.evicted])
            }
        }
        return queue
    }

    private func memos(_ result: VoiceMemosLibrary.LoadResult,
                       file: StaticString = #filePath, line: UInt = #line) -> ([VoiceMemo], Int) {
        guard case .memos(let memos, let notDownloaded) = result else {
            XCTFail("expected memos, got \(result)", file: file, line: line)
            return ([], 0)
        }
        return (memos, notDownloaded)
    }

    func testListsLibraryTitlesDatesAndDurationsNewestFirst() throws {
        let lecture = try touch("20260901 090000-AAAA.m4a")
        let seminar = try touch("20260902 140000-BBBB.m4a")
        try touch("20260903 100000-CCCC.m4a")
        try makeDatabase([
            Fixture(path: lecture.lastPathComponent, title: "Linear Algebra", date: 800_000_000, duration: 3_000),
            // No title: the older label column is the fallback.
            Fixture(path: seminar.lastPathComponent, label: "Seminar room", date: 800_100_000, duration: 1_200),
            // In Recently Deleted.
            Fixture(path: "20260903 100000-CCCC.m4a", title: "Deleted", date: 800_200_000, evicted: 800_300_000),
            // Listed by the library but not downloaded to this Mac.
            Fixture(path: "20260904 100000-DDDD.m4a", title: "Still in iCloud", date: 800_400_000),
        ])

        let (list, notDownloaded) = memos(VoiceMemosLibrary.load(directories: [root]))

        XCTAssertEqual(list.map(\.title), ["Seminar room", "Linear Algebra"])
        XCTAssertEqual(list.map(\.url.lastPathComponent), [seminar.lastPathComponent, lecture.lastPathComponent])
        XCTAssertEqual(list.last?.recordedAt, Date(timeIntervalSinceReferenceDate: 800_000_000))
        XCTAssertEqual(list.last?.durationSeconds, 3_000)
        XCTAssertEqual(notDownloaded, 1)
    }

    func testReadsRowsThatAreStillInTheWriteAheadLog() throws {
        let file = try touch("20260901 090000-AAAA.m4a")
        // Kept open, as Voice Memos keeps it, so the row is not checkpointed.
        let open = try makeDatabase([Fixture(path: file.lastPathComponent, title: "From the WAL")], wal: true)

        let (list, _) = memos(VoiceMemosLibrary.load(directories: [root]))

        XCTAssertEqual(list.map(\.title), ["From the WAL"])
        _ = open
    }

    func testListsAudioFilesWhenThereIsNoDatabase() throws {
        try touch("20260901 090000-AAAA.m4a")
        try touch("20260902 090000-BBBB.qta")
        try touch("notes.txt")

        let (list, notDownloaded) = memos(VoiceMemosLibrary.load(directories: [root]))

        XCTAssertEqual(Set(list.map(\.title)), ["20260901 090000-AAAA", "20260902 090000-BBBB"])
        XCTAssertEqual(notDownloaded, 0)
    }

    func testMissingFolderIsNotFound() {
        let result = VoiceMemosLibrary.load(directories: [root.appendingPathComponent("absent")])
        guard case .notFound = result else { return XCTFail("expected notFound, got \(result)") }
    }

    func testUnreadableFolderIsAccessDenied() throws {
        try XCTSkipIf(getuid() == 0, "root reads any folder")
        try touch("20260901 090000-AAAA.m4a")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)

        let result = VoiceMemosLibrary.load(directories: [root])

        guard case .accessDenied = result else { return XCTFail("expected accessDenied, got \(result)") }
    }

    func testLocatesAMemoByFileName() throws {
        let file = try touch("20260901 090000-AAAA.m4a")
        let elsewhere = root.appendingPathComponent("absent")

        XCTAssertEqual(VoiceMemosLibrary.locate(fileName: file.lastPathComponent, directories: [elsewhere, root])?.path,
                       file.path)
        XCTAssertNil(VoiceMemosLibrary.locate(fileName: "missing.m4a", directories: [root]))
        XCTAssertTrue(VoiceMemosLibrary.contains(file, directories: [root]))
        XCTAssertFalse(VoiceMemosLibrary.contains(FileManager.default.temporaryDirectory.appendingPathComponent("x.m4a"),
                                                  directories: [root]))
    }
}
