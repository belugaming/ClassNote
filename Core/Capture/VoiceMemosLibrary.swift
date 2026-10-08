import Foundation
import GRDB

/// One recording in the Voice Memos library, at the path Voice Memos keeps it.
struct VoiceMemo: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let title: String
    let recordedAt: Date
    let durationSeconds: Double?
}

/// Reads the Voice Memos library in place. An imported memo is referenced, not
/// copied, so the recording stays a single file that Voice Memos (and its
/// iCloud sync) owns.
///
/// None of this is public API. The layout is the one macOS 14 and later use;
/// older systems kept the recordings under Application Support. Every database
/// column is read by name and may be missing, and without a readable database
/// the audio files are listed on their own, so a schema change costs the
/// titles, not the import.
enum VoiceMemosLibrary {
    enum LoadResult: Sendable {
        /// `notDownloaded` counts recordings the library lists whose audio is
        /// not on this Mac yet (still in iCloud).
        case memos([VoiceMemo], notDownloaded: Int)
        /// The folder is there but macOS would not list it: ClassNote does not
        /// have Full Disk Access.
        case accessDenied
        case notFound
    }

    static let databaseName = "CloudRecordings.db"
    static let audioExtensions: Set<String> = ["m4a", "qta", "caf", "wav", "aac", "mp3"]

    static var defaultDirectories: [URL] {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
        return [
            library.appendingPathComponent("Group Containers/group.com.apple.VoiceMemos.shared/Recordings",
                                           isDirectory: true),
            library.appendingPathComponent("Application Support/com.apple.voicememos/Recordings",
                                           isDirectory: true),
        ]
    }

    /// System Settings → Privacy & Security → Full Disk Access.
    static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Blocking file and database IO: call it off the main actor.
    static func load(directories: [URL] = defaultDirectories) -> LoadResult {
        var denied = false
        for directory in directories {
            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                    includingPropertiesForKeys: [.creationDateKey],
                                                                    options: [.skipsHiddenFiles])
            } catch {
                if isPermissionError(error) { denied = true }
                continue
            }
            return memos(in: directory, files: files)
        }
        return denied ? .accessDenied : .notFound
    }

    /// Finds a memo by its file name in this Mac's library. Voice Memos syncs
    /// the same file name to every device, so this is how a memo imported on
    /// one Mac is found on another, whose home folder may have a different path.
    static func locate(fileName: String, directories: [URL] = defaultDirectories) -> URL? {
        for directory in directories {
            let url = directory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// True when `url` is inside one of the Voice Memos recording folders.
    static func contains(_ url: URL, directories: [URL] = defaultDirectories) -> Bool {
        let path = url.standardizedFileURL.path
        return directories.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    // MARK: - Listing

    private static func memos(in directory: URL, files: [URL]) -> LoadResult {
        let audio = files.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        guard let rows = try? recordingRows(in: directory) else {
            let memos = audio.map {
                VoiceMemo(url: $0,
                          title: $0.deletingPathExtension().lastPathComponent,
                          recordedAt: creationDate($0),
                          durationSeconds: nil)
            }
            return .memos(memos.sorted { $0.recordedAt > $1.recordedAt }, notDownloaded: 0)
        }

        let byName = Dictionary(audio.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        // A recording in Recently Deleted keeps its row, with an eviction date,
        // until the folder is emptied. If every row has one, the column means
        // something else on this system, and hiding the whole library would be
        // the worse mistake.
        var live = rows.filter { $0["ZEVICTIONDATE"]?.isNull ?? true }
        if live.isEmpty { live = rows }

        var memos: [VoiceMemo] = []
        var notDownloaded = 0
        for row in live {
            let stored = string(row["ZPATH"])
            guard let stored, let url = resolve(stored, byName: byName) else {
                notDownloaded += 1
                continue
            }
            let title = [string(row["ZENCRYPTEDTITLE"]), string(row["ZCUSTOMLABEL"])]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let recordedAt = double(row["ZDATE"]).map(Date.init(timeIntervalSinceReferenceDate:))
            let duration = double(row["ZDURATION"]) ?? double(row["ZLOCALDURATION"])
            memos.append(VoiceMemo(url: url,
                                   title: title ?? url.deletingPathExtension().lastPathComponent,
                                   recordedAt: recordedAt ?? creationDate(url),
                                   durationSeconds: duration.flatMap { $0 > 0 ? $0 : nil }))
        }
        return .memos(memos.sorted { $0.recordedAt > $1.recordedAt }, notDownloaded: notDownloaded)
    }

    /// `ZPATH` is a bare file name on current systems and was an absolute path
    /// on older ones; either way the file is looked up in the folder listed.
    private static func resolve(_ stored: String, byName: [String: URL]) -> URL? {
        if let url = byName[(stored as NSString).lastPathComponent] { return url }
        guard stored.hasPrefix("/"), FileManager.default.fileExists(atPath: stored) else { return nil }
        return URL(fileURLWithPath: stored)
    }

    /// Reads a private copy of the database. Voice Memos keeps it open in WAL
    /// mode; a copy can neither block it nor change under the read. The -shm
    /// is left behind on purpose: the first connection to a WAL database
    /// rebuilds it from the -wal.
    private static func recordingRows(in directory: URL) throws -> [[String: DatabaseValue]]? {
        let fm = FileManager.default
        let source = directory.appendingPathComponent(databaseName)
        guard fm.fileExists(atPath: source.path) else { return nil }
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("classnote-voicememos-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let copy = scratch.appendingPathComponent(databaseName)
        try fm.copyItem(at: source, to: copy)
        let wal = directory.appendingPathComponent(databaseName + "-wal")
        if fm.fileExists(atPath: wal.path) {
            try? fm.copyItem(at: wal, to: scratch.appendingPathComponent(databaseName + "-wal"))
        }
        return try readRows(databaseAt: copy)
    }

    private static func readRows(databaseAt url: URL) throws -> [[String: DatabaseValue]]? {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db -> [[String: DatabaseValue]]? in
            guard try db.tableExists("ZCLOUDRECORDING") else { return nil }
            return try Row.fetchAll(db, sql: "SELECT * FROM ZCLOUDRECORDING").map { row in
                var values: [String: DatabaseValue] = [:]
                for (column, value) in row { values[column.uppercased()] = value }
                return values
            }
        }
    }

    // MARK: - Helpers

    private static func string(_ value: DatabaseValue?) -> String? {
        value.flatMap { String.fromDatabaseValue($0) }
    }

    private static func double(_ value: DatabaseValue?) -> Double? {
        value.flatMap { Double.fromDatabaseValue($0) }
    }

    private static func creationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileReadNoPermission.rawValue { return true }
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError) ?? ns
        return posix.domain == NSPOSIXErrorDomain
            && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }
}
