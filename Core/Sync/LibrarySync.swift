import Foundation
import GRDB

/// One lecture as written to the sync folder: the session and everything that
/// hangs off it. Its audio sits next to it, or is found in Voice Memos.
struct SessionSnapshot: Codable {
    var format: Int
    var revision: String
    var modifiedAt: Int64
    var writtenBy: String
    /// Without `audioPath` and `audioBookmark`, which only mean something on
    /// the Mac that wrote them; `audio` says where the recording is instead.
    var session: Session
    var audio: SyncedAudio?
    var segments: [Segment]
    var highlights: [Highlight]
    var notes: [Note]
    var noteVersions: [NoteVersion]
    var flashcards: [Flashcard]
    var studyToolResults: [StudyToolResult]
    var qaMessages: [QAMessage]
}

struct CourseSnapshot: Codable {
    var format: Int
    var revision: String
    var modifiedAt: Int64
    var writtenBy: String
    var course: Course
}

/// Where a lecture's recording is, in terms every Mac can resolve.
enum SyncedAudio: Codable, Equatable {
    /// In the lecture's own folder in the sync folder.
    case synced(fileName: String)
    /// In Voice Memos, which syncs it itself. Found by file name on each Mac.
    case voiceMemo(fileName: String)
    /// Imported from elsewhere and left there; only a Mac with the same path has it.
    case external(path: String)
}

/// A deletion, kept in the sync folder so a Mac that was away hears of it.
struct SyncTombstone: Codable {
    var kind: String
    var id: String
    var deletedAt: Int64
}

/// Syncs the library between Macs through a shared folder, iCloud Drive/ClassNote.
///
/// Each Mac keeps its own SQLite database: a database file in iCloud Drive is
/// corrupted by two Macs writing it, and its -wal and -shm files sync on their
/// own. Instead each lecture is written as `Sessions/<id>/session.json`, with
/// its recording beside it, and each course as `Courses/<id>.json`; every Mac
/// merges what the others wrote.
///
/// - Local changes are seen through `modified_at`, which triggers keep (v16);
///   remote ones through the file changing (date and size, then its revision).
/// - Changed on one side: that side wins. Changed on both: the later
///   `modifiedAt` wins, for the whole lecture.
/// - A deletion leaves a tombstone in `Deleted/`, and loses to an edit made after it.
/// - A lecture being recorded or transcribed on this Mac is left alone until done.
/// - A finished recording moves into its lecture's folder, so iCloud holds the one copy.
/// - Settings and API keys stay on each Mac.
///
/// Blocking file and database IO throughout: run it off the main actor.
struct LibrarySync: Sendable {
    static let format = 1
    /// This Mac is still writing a lecture in these states.
    static let busyStates: Set<String> = [SessionState.recording.rawValue,
                                          SessionState.transcribing.rawValue,
                                          SessionState.interrupted.rawValue]

    /// iCloud Drive's own folder. Present when iCloud Drive is on.
    static var iCloudDriveURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static var defaultRoot: URL {
        iCloudDriveURL.appendingPathComponent("ClassNote", isDirectory: true)
    }

    let db: any DatabaseWriter
    let root: URL
    /// Where this Mac records to (Application Support). Finished recordings
    /// are moved from here into the sync folder.
    let recordingsRoot: URL
    let deviceName: String
    var voiceMemoDirectories: [URL] = VoiceMemosLibrary.defaultDirectories

    struct Report: Sendable {
        var pushed = 0
        var pulled = 0
        var deleted = 0
        /// Sessions whose rows changed under the app: pulled, deleted, or
        /// whose recording moved.
        var changedSessionIds: Set<String> = []
        var coursesChanged = false
        var failures: [String] = []

        var changedLibrary: Bool { !changedSessionIds.isEmpty || coursesChanged }
    }

    var sessionsDirectory: URL { root.appendingPathComponent("Sessions", isDirectory: true) }
    var coursesDirectory: URL { root.appendingPathComponent("Courses", isDirectory: true) }
    var deletedDirectory: URL { root.appendingPathComponent("Deleted", isDirectory: true) }

    func sessionDirectory(_ id: String) -> URL {
        sessionsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    func sessionFile(_ id: String) -> URL {
        sessionDirectory(id).appendingPathComponent("session.json")
    }

    func courseFile(_ id: String) -> URL {
        coursesDirectory.appendingPathComponent("\(id).json")
    }

    func tombstoneFile(kind: String, id: String) -> URL {
        deletedDirectory.appendingPathComponent("\(kind)-\(id).json")
    }

    /// One pass. A failure on one item is reported and the rest carry on.
    func run() throws -> Report {
        for directory in [sessionsDirectory, coursesDirectory, deletedDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var report = Report()
        let remoteTombstones = readRemoteTombstones(into: &report)
        applyRemoteTombstones(remoteTombstones, into: &report)
        pushLocalTombstones(into: &report)
        // Courses first: a lecture's course must exist before the lecture.
        syncCourses(remoteTombstones, into: &report)
        syncSessions(remoteTombstones, into: &report)
        return report
    }

    // MARK: - Deletions

    private func readRemoteTombstones(into report: inout Report) -> [String: SyncTombstone] {
        var result: [String: SyncTombstone] = [:]
        for file in files(in: deletedDirectory, withExtension: "json") {
            do {
                let tombstone = try readJSON(SyncTombstone.self, at: file)
                result["\(tombstone.kind)-\(tombstone.id)"] = tombstone
            } catch {
                report.failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// What applying a deletion removed here.
    private struct Removal {
        var audioPath: String?
        var unfiledSessionIds: [String]
    }

    private func applyRemoteTombstones(_ tombstones: [String: SyncTombstone], into report: inout Report) {
        // Most tombstones are for things long gone here; only these need a write.
        let present: Set<String>
        do {
            present = try db.read { db -> Set<String> in
                Set(try String.fetchAll(db, sql: "SELECT 'session-' || id FROM session UNION ALL SELECT 'course-' || id FROM course"))
            }
        } catch {
            report.failures.append(error.localizedDescription)
            return
        }
        for (key, tombstone) in tombstones where present.contains(key) {
            do {
                let table = tombstone.kind
                let removal = try db.write { db -> Removal? in
                    guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id = ?",
                                                     arguments: [tombstone.id]) else { return nil }
                    let modifiedAt: Int64 = row["modified_at"]
                    // Edited here after it was deleted there: the edit wins and is pushed back.
                    guard modifiedAt <= tombstone.deletedAt else { return nil }
                    if table == "session", let state: String = row["state"], Self.busyStates.contains(state) {
                        return nil
                    }
                    var audioPath: String?
                    if table == "session" { audioPath = row["audio_path"] }
                    var unfiled: [(id: String, modifiedAt: Int64)] = []
                    if table == "course" {
                        for lecture in try Row.fetchAll(db, sql: "SELECT id, modified_at FROM session WHERE course_id = ?",
                                                        arguments: [tombstone.id]) {
                            let id: String = lecture["id"]
                            let modifiedAt: Int64 = lecture["modified_at"]
                            unfiled.append((id, modifiedAt))
                        }
                    }
                    try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [tombstone.id])
                    // Unfiling the course's lectures is the other Mac's deletion
                    // replayed, not an edit made here: if they looked changed they
                    // would overwrite that Mac's newer versions of them.
                    for lecture in unfiled {
                        try db.execute(sql: "UPDATE session SET modified_at = ? WHERE id = ?",
                                       arguments: [lecture.modifiedAt, lecture.id])
                    }
                    // Already in the sync folder; must not come back as this Mac's own deletion.
                    try forget(kind: table, id: tombstone.id, in: db)
                    return Removal(audioPath: audioPath, unfiledSessionIds: unfiled.map(\.id))
                }
                guard let removal else { continue }
                if let path = removal.audioPath, isUnder(path, recordingsRoot) {
                    try? FileManager.default.removeItem(atPath: path)
                }
                report.deleted += 1
                if table == "session" {
                    report.changedSessionIds.insert(tombstone.id)
                } else {
                    report.coursesChanged = true
                    report.changedSessionIds.formUnion(removal.unfiledSessionIds)
                }
            } catch {
                report.failures.append("\(tombstone.kind) \(tombstone.id): \(error.localizedDescription)")
            }
        }
    }

    private struct PendingDeletion {
        var kind: String
        var id: String
        var deletedAt: Int64
        /// Was ever written to the sync folder.
        var synced: Bool
    }

    private func pushLocalTombstones(into report: inout Report) {
        let pending: [PendingDeletion]
        do {
            pending = try db.read { db -> [PendingDeletion] in
                try Row.fetchAll(db, sql: """
                    SELECT t.kind, t.id, t.deleted_at, s.id IS NOT NULL AS synced
                    FROM sync_tombstone t
                    LEFT JOIN sync_state s ON s.kind = t.kind AND s.id = t.id
                    """).map { row in
                        PendingDeletion(kind: row["kind"], id: row["id"],
                                        deletedAt: row["deleted_at"], synced: row["synced"])
                    }
            }
        } catch {
            report.failures.append(error.localizedDescription)
            return
        }
        for item in pending {
            do {
                let remote = item.kind == "session" ? sessionFile(item.id) : courseFile(item.id)
                let remoteExists = FileManager.default.fileExists(atPath: remote.path)
                if remoteExists {
                    let header = try readJSON(SnapshotHeader.self, at: remote)
                    if header.modifiedAt > item.deletedAt {
                        // Edited on another Mac after it was deleted here: the
                        // edit wins, and the pass below brings it back.
                        try db.write { db in try forget(kind: item.kind, id: item.id, in: db) }
                        continue
                    }
                    try removeCoordinated(item.kind == "session" ? sessionDirectory(item.id) : remote)
                }
                // Never synced: nothing anywhere needs to hear of it.
                if remoteExists || item.synced {
                    try writeJSON(SyncTombstone(kind: item.kind, id: item.id, deletedAt: item.deletedAt),
                                  to: tombstoneFile(kind: item.kind, id: item.id))
                }
                try db.write { db in try forget(kind: item.kind, id: item.id, in: db) }
            } catch {
                report.failures.append("\(item.kind) \(item.id): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Courses

    private func syncCourses(_ remoteTombstones: [String: SyncTombstone], into report: inout Report) {
        let remoteIds = files(in: coursesDirectory, withExtension: "json")
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { UUID(uuidString: $0) != nil }
        let local: [String: Int64]
        let states: [String: ItemState]
        let localTombstones: [String: Int64]
        do {
            local = try db.read { db -> [String: Int64] in
                var result: [String: Int64] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT id, modified_at FROM course") {
                    result[row["id"]] = row["modified_at"]
                }
                return result
            }
            states = try loadStates(kind: "course")
            localTombstones = try loadLocalTombstones(kind: "course")
        } catch {
            report.failures.append(error.localizedDescription)
            return
        }
        for id in Set(remoteIds).union(local.keys).sorted() {
            do {
                let action = try decide(localModifiedAt: local[id], file: courseFile(id), state: states[id],
                                        deletedAt: max(remoteTombstones["course-\(id)"]?.deletedAt ?? .min,
                                                       localTombstones[id] ?? .min),
                                        kind: "course", id: id)
                switch action {
                case .push:
                    try pushCourse(id)
                    report.pushed += 1
                case .pull:
                    if try pullCourse(id, expectedLocalModifiedAt: local[id]) {
                        report.pulled += 1
                        report.coursesChanged = true
                    }
                case .none:
                    break
                }
            } catch {
                report.failures.append("course \(id): \(error.localizedDescription)")
            }
        }
    }

    private func pushCourse(_ id: String) throws {
        guard let stored = try db.read({ db -> (course: Course, modifiedAt: Int64)? in
            guard let course = try Course.fetchOne(db, key: id) else { return nil }
            let modifiedAt = try Int64.fetchOne(db, sql: "SELECT modified_at FROM course WHERE id = ?",
                                                arguments: [id]) ?? 0
            return (course, modifiedAt)
        }) else { return }
        let (course, modifiedAt) = stored
        let snapshot = CourseSnapshot(format: Self.format, revision: UUID().uuidString,
                                      modifiedAt: modifiedAt, writtenBy: deviceName, course: course)
        let file = courseFile(id)
        try writeJSON(snapshot, to: file)
        try db.write { db in
            try saveState(kind: "course", id: id, localModifiedAt: modifiedAt, revision: snapshot.revision,
                          fingerprint: Self.fingerprint(of: file) ?? "", in: db)
        }
    }

    private func pullCourse(_ id: String, expectedLocalModifiedAt: Int64?) throws -> Bool {
        let file = courseFile(id)
        // Taken before the read, so a change after it is seen next time.
        let fingerprint = Self.fingerprint(of: file) ?? ""
        let snapshot = try readJSON(CourseSnapshot.self, at: file)
        guard snapshot.format <= Self.format, snapshot.course.id == id else { return false }
        return try db.write { db -> Bool in
            let current = try Int64.fetchOne(db, sql: "SELECT modified_at FROM course WHERE id = ?", arguments: [id])
            // Changed here since the decision: the next pass decides again.
            guard current == expectedLocalModifiedAt else { return false }
            if current == nil {
                try snapshot.course.insert(db)
            } else {
                try snapshot.course.update(db)
            }
            try db.execute(sql: "UPDATE course SET modified_at = ? WHERE id = ?",
                           arguments: [snapshot.modifiedAt, id])
            try db.execute(sql: "DELETE FROM sync_tombstone WHERE kind = 'course' AND id = ?", arguments: [id])
            try saveState(kind: "course", id: id, localModifiedAt: snapshot.modifiedAt,
                          revision: snapshot.revision, fingerprint: fingerprint, in: db)
            return true
        }
    }

    // MARK: - Sessions

    private func syncSessions(_ remoteTombstones: [String: SyncTombstone], into report: inout Report) {
        let remoteIds = directories(in: sessionsDirectory)
            .map(\.lastPathComponent)
            .filter { UUID(uuidString: $0) != nil }
        let local: [String: (modifiedAt: Int64, state: String)]
        let states: [String: ItemState]
        let localTombstones: [String: Int64]
        do {
            local = try db.read { db -> [String: (modifiedAt: Int64, state: String)] in
                var result: [String: (modifiedAt: Int64, state: String)] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT id, modified_at, state FROM session") {
                    let id: String = row["id"]
                    let modifiedAt: Int64 = row["modified_at"]
                    let state: String = row["state"]
                    result[id] = (modifiedAt, state)
                }
                return result
            }
            states = try loadStates(kind: "session")
            localTombstones = try loadLocalTombstones(kind: "session")
        } catch {
            report.failures.append(error.localizedDescription)
            return
        }
        for id in Set(remoteIds).union(local.keys).sorted() {
            if let state = local[id]?.state, Self.busyStates.contains(state) { continue }
            do {
                let action = try decide(localModifiedAt: local[id]?.modifiedAt, file: sessionFile(id),
                                        state: states[id],
                                        deletedAt: max(remoteTombstones["session-\(id)"]?.deletedAt ?? .min,
                                                       localTombstones[id] ?? .min),
                                        kind: "session", id: id)
                switch action {
                case .push:
                    if try moveRecordingIntoSyncFolder(id) { report.changedSessionIds.insert(id) }
                    try pushSession(id)
                    report.pushed += 1
                case .pull:
                    if try pullSession(id, expectedLocalModifiedAt: local[id]?.modifiedAt,
                                       remoteTombstones: remoteTombstones) {
                        report.pulled += 1
                        report.changedSessionIds.insert(id)
                    }
                case .none:
                    break
                }
            } catch {
                report.failures.append("session \(id): \(error.localizedDescription)")
            }
        }
    }

    /// A finished recording still in Application Support moves into the
    /// lecture's folder, so the copy in iCloud is the only one. Done inside a
    /// write so the session cannot start being transcribed halfway through.
    private func moveRecordingIntoSyncFolder(_ id: String) throws -> Bool {
        let fm = FileManager.default
        let folder = sessionDirectory(id)
        return try db.write { db -> Bool in
            guard let row = try Row.fetchOne(db, sql: "SELECT audio_path, state FROM session WHERE id = ?",
                                             arguments: [id]),
                  let path: String = row["audio_path"],
                  let state: String = row["state"],
                  !Self.busyStates.contains(state),
                  isUnder(path, recordingsRoot),
                  fm.fileExists(atPath: path) else { return false }
            let source = URL(fileURLWithPath: path)
            let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
            let destination = folder.appendingPathComponent("audio.\(ext)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try coordinateWriting(destination, options: .forReplacing) { url in
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                try fm.moveItem(at: source, to: url)
            }
            do {
                try db.execute(sql: "UPDATE session SET audio_path = ? WHERE id = ?",
                               arguments: [destination.path, id])
            } catch {
                try? fm.moveItem(at: destination, to: source)
                throw error
            }
            return true
        }
    }

    private func pushSession(_ id: String) throws {
        guard let snapshot = try db.read({ db in try sessionSnapshot(id, in: db) }) else { return }
        try FileManager.default.createDirectory(at: sessionDirectory(id), withIntermediateDirectories: true)
        let file = sessionFile(id)
        try writeJSON(snapshot, to: file)
        try db.write { db in
            try saveState(kind: "session", id: id, localModifiedAt: snapshot.modifiedAt,
                          revision: snapshot.revision, fingerprint: Self.fingerprint(of: file) ?? "", in: db)
        }
    }

    private func sessionSnapshot(_ id: String, in db: GRDB.Database) throws -> SessionSnapshot? {
        guard var session = try Session.fetchOne(db, key: id) else { return nil }
        let modifiedAt = try Int64.fetchOne(db, sql: "SELECT modified_at FROM session WHERE id = ?",
                                            arguments: [id]) ?? 0
        let audio = syncedAudio(for: session.audioPath, sessionId: id)
        session.audioPath = nil
        session.audioBookmark = nil
        let owned = Column("session_id") == id
        return SessionSnapshot(
            format: Self.format,
            revision: UUID().uuidString,
            modifiedAt: modifiedAt,
            writtenBy: deviceName,
            session: session,
            audio: audio,
            segments: try Segment.filter(owned).order(Column("start_ms"), Column("id")).fetchAll(db),
            highlights: try Highlight.filter(owned).order(Column("timestamp_ms"), Column("id")).fetchAll(db),
            notes: try Note.filter(owned).order(Column("generated_at")).fetchAll(db),
            noteVersions: try NoteVersion.filter(owned).order(Column("generated_at")).fetchAll(db),
            flashcards: try Flashcard.filter(owned).order(Column("sort_order"), Column("id")).fetchAll(db),
            studyToolResults: try StudyToolResult.filter(owned).order(Column("generated_at")).fetchAll(db),
            qaMessages: try QAMessage.filter(owned).order(Column("created_at")).fetchAll(db))
    }

    private func syncedAudio(for path: String?, sessionId: String) -> SyncedAudio? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        if isUnder(path, sessionDirectory(sessionId)) { return .synced(fileName: url.lastPathComponent) }
        if VoiceMemosLibrary.contains(url, directories: voiceMemoDirectories) {
            return .voiceMemo(fileName: url.lastPathComponent)
        }
        return .external(path: path)
    }

    private func localAudioPath(for audio: SyncedAudio?, sessionId: String) -> String? {
        switch audio {
        case .synced(let fileName)?:
            return sessionDirectory(sessionId).appendingPathComponent((fileName as NSString).lastPathComponent).path
        case .voiceMemo(let fileName)?:
            let name = (fileName as NSString).lastPathComponent
            // Not on this Mac yet: point where Voice Memos will put it.
            return (VoiceMemosLibrary.locate(fileName: name, directories: voiceMemoDirectories)
                    ?? voiceMemoDirectories.first?.appendingPathComponent(name))?.path
        case .external(let path)?:
            return path
        case nil:
            return nil
        }
    }

    private func pullSession(_ id: String, expectedLocalModifiedAt: Int64?,
                             remoteTombstones: [String: SyncTombstone]) throws -> Bool {
        let file = sessionFile(id)
        let fingerprint = Self.fingerprint(of: file) ?? ""
        let snapshot = try readJSON(SessionSnapshot.self, at: file)
        guard snapshot.format <= Self.format, snapshot.session.id == id else { return false }
        let audioPath = localAudioPath(for: snapshot.audio, sessionId: id)
        return try db.write { db -> Bool in
            let currentModifiedAt = try Int64.fetchOne(db, sql: "SELECT modified_at FROM session WHERE id = ?",
                                                       arguments: [id])
            guard currentModifiedAt == expectedLocalModifiedAt else { return false }

            var session = snapshot.session
            if let courseId = session.courseId, try !Course.exists(db, key: courseId) {
                // Deleted: the lecture is unfiled, as it was on the Mac that
                // deleted it. Not arrived yet: wait for it.
                guard remoteTombstones["course-\(courseId)"] != nil else { return false }
                session.courseId = nil
            }
            let existing = try Session.fetchOne(db, key: id)
            if case .external? = snapshot.audio, let existing {
                // This Mac knows better where an imported file is on this Mac.
                session.audioPath = existing.audioPath
                session.audioBookmark = existing.audioBookmark
            } else {
                session.audioPath = audioPath
                session.audioBookmark = nil
            }
            if existing == nil {
                try session.insert(db)
            } else {
                try session.update(db)
            }

            for table in ["segment", "highlight", "note_version", "note", "flashcard",
                          "study_tool_result", "qa_message"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE session_id = ?", arguments: [id])
            }
            // Row ids are this Mac's own; the others' would collide.
            for var segment in snapshot.segments {
                segment.id = nil
                segment.sessionId = id
                try segment.insert(db)
            }
            for var highlight in snapshot.highlights {
                highlight.id = nil
                highlight.sessionId = id
                try highlight.insert(db)
            }
            for note in snapshot.notes { try note.insert(db) }
            for version in snapshot.noteVersions { try version.insert(db) }
            for var card in snapshot.flashcards {
                card.id = nil
                card.sessionId = id
                try card.insert(db)
            }
            for result in snapshot.studyToolResults { try result.insert(db) }
            for message in snapshot.qaMessages { try message.insert(db) }

            // Last, over what the triggers set while the rows went in.
            try db.execute(sql: "UPDATE session SET modified_at = ? WHERE id = ?",
                           arguments: [snapshot.modifiedAt, id])
            try db.execute(sql: "DELETE FROM sync_tombstone WHERE kind = 'session' AND id = ?", arguments: [id])
            try saveState(kind: "session", id: id, localModifiedAt: snapshot.modifiedAt,
                          revision: snapshot.revision, fingerprint: fingerprint, in: db)
            return true
        }
    }

    // MARK: - Deciding

    enum Action { case none, push, pull }

    struct ItemState {
        var localModifiedAt: Int64
        var remoteRevision: String
        var remoteFingerprint: String
    }

    /// The fields every snapshot shares, read without decoding the rest.
    private struct SnapshotHeader: Decodable {
        var format: Int
        var revision: String
        var modifiedAt: Int64
    }

    /// `deletedAt` is the latest deletion of this item known anywhere.
    private func decide(localModifiedAt: Int64?, file: URL, state: ItemState?, deletedAt: Int64,
                        kind: String, id: String) throws -> Action {
        let fingerprint = Self.fingerprint(of: file)
        switch (localModifiedAt, fingerprint) {
        case (nil, nil):
            return .none
        case (let local?, nil):
            // Synced before and untouched here since: the file is gone because
            // another Mac deleted it, and its tombstone has not arrived yet.
            // Pushing would bring the lecture back.
            if let state, state.localModifiedAt == local { return .none }
            return .push
        case (nil, _?):
            let header = try readJSON(SnapshotHeader.self, at: file)
            guard header.format <= Self.format else { return .none }
            // Deleted after this version was written: the file is a leftover.
            return header.modifiedAt > deletedAt ? .pull : .none
        case (let local?, let current?):
            let localChanged = state?.localModifiedAt != local
            var remoteChanged = state?.remoteFingerprint != current
            guard localChanged || remoteChanged else { return .none }
            var header: SnapshotHeader?
            if remoteChanged {
                let read = try readJSON(SnapshotHeader.self, at: file)
                // Written by a newer ClassNote: neither overwrite nor misread it.
                guard read.format <= Self.format else { return .none }
                if let state, read.revision == state.remoteRevision {
                    // Same version, new file date (iCloud rewrote it): remember
                    // the date so the file is not read again.
                    remoteChanged = false
                    try db.write { db in
                        try saveState(kind: kind, id: id, localModifiedAt: state.localModifiedAt,
                                      revision: state.remoteRevision, fingerprint: current, in: db)
                    }
                }
                header = read
            }
            switch (localChanged, remoteChanged) {
            case (true, false): return .push
            case (false, true): return .pull
            case (true, true): return (header?.modifiedAt ?? .min) > local ? .pull : .push
            case (false, false): return .none
            }
        }
    }

    private func loadStates(kind: String) throws -> [String: ItemState] {
        try db.read { db -> [String: ItemState] in
            var result: [String: ItemState] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT id, local_modified_at, remote_revision, remote_fingerprint
                FROM sync_state WHERE kind = ?
                """, arguments: [kind]) {
                result[row["id"]] = ItemState(localModifiedAt: row["local_modified_at"],
                                              remoteRevision: row["remote_revision"],
                                              remoteFingerprint: row["remote_fingerprint"])
            }
            return result
        }
    }

    private func loadLocalTombstones(kind: String) throws -> [String: Int64] {
        try db.read { db -> [String: Int64] in
            var result: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, deleted_at FROM sync_tombstone WHERE kind = ?",
                                        arguments: [kind]) {
                result[row["id"]] = row["deleted_at"]
            }
            return result
        }
    }

    private func saveState(kind: String, id: String, localModifiedAt: Int64, revision: String,
                           fingerprint: String, in db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO sync_state(kind, id, local_modified_at, remote_revision, remote_fingerprint)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [kind, id, localModifiedAt, revision, fingerprint])
    }

    private func forget(kind: String, id: String, in db: GRDB.Database) throws {
        try db.execute(sql: "DELETE FROM sync_tombstone WHERE kind = ? AND id = ?", arguments: [kind, id])
        try db.execute(sql: "DELETE FROM sync_state WHERE kind = ? AND id = ?", arguments: [kind, id])
    }

    // MARK: - Files

    /// Date and size: enough to notice another Mac's write without reading it.
    static func fingerprint(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate else { return nil }
        return "\(date.timeIntervalSince1970)-\(values.fileSize ?? -1)"
    }

    private func files(in directory: URL, withExtension ext: String) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension == ext }
    }

    private func directories(in directory: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func isUnder(_ path: String, _ directory: URL) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    // Coordinated, so iCloud never hands over a half-written file, and a
    // file that is only in the cloud is downloaded before it is read.

    private func readJSON<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        var result: Result<T, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [],
                                                         error: &coordinationError) { url in
            result = Result { try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try coordinateWriting(url, options: .forReplacing) { url in
            try data.write(to: url, options: .atomic)
        }
    }

    private func removeCoordinated(_ url: URL) throws {
        try coordinateWriting(url, options: .forDeleting) { url in
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                return
            }
        }
    }

    private func coordinateWriting(_ url: URL, options: NSFileCoordinator.WritingOptions,
                                   _ body: (URL) throws -> Void) throws {
        var bodyError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options,
                                                         error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let bodyError { throw bodyError }
    }
}
