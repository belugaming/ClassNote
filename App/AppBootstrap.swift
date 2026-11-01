import AppKit
import Foundation

enum AppBootstrap {
    /// Under test the host app must not touch the user's data: the test bundle
    /// is injected into the real app, so this would otherwise open their
    /// database and bind their global hotkeys on every ⌘U. Tests that need the
    /// database call `Database.shared.setup()` themselves.
    @MainActor
    static func run() {
        // The test host is the real app, so its windows still hit the
        // repositories (MainWindowViewModel.refresh runs on first render) and
        // would trap on a nil pool. The database itself is already redirected
        // to the throwaway test directory, so opening it is harmless; only the
        // global hotkeys must stay unregistered under test.
        do {
            try Database.shared.setup()
        } catch {
            NSLog("[ClassNote] Database setup failed: \(error)")
            // Every repository force-unwraps the pool, so carrying on only
            // turned this into a crash at the first query, at every launch.
            if !AppEnvironment.isRunningTests { quitForUnopenableDatabase(error) }
        }
        guard !AppEnvironment.isRunningTests else { return }
        GlobalShortcuts.register()
    }

    /// Where `Database.setup()` opens the library.
    private static var databaseURL: URL {
        applicationSupportURL.appendingPathComponent("classnote.sqlite")
    }

    /// Says why ClassNote cannot run, offers to show the file, and quits.
    /// Before any scene exists, so nothing can reach the missing pool first.
    @MainActor
    private static func quitForUnopenableDatabase(_ error: Error) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.t("database.error.title")
        alert.informativeText = String(format: L10n.t("database.error.message"), error.localizedDescription)
        alert.addButton(withTitle: L10n.t("menubar.quit"))
        alert.addButton(withTitle: L10n.t("database.error.reveal"))
        if alert.runModal() == .alertSecondButtonReturn {
            let file = databaseURL
            let target = FileManager.default.fileExists(atPath: file.path) ? file : applicationSupportURL
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
        exit(EXIT_FAILURE)
    }

    /// The one place that answers "where does ClassNote keep its data" — the
    /// database, the recordings, the venv and the provisioned interpreter all
    /// hang off it, so redirecting it redirects them together. Resolved once:
    /// whichever caller asks first fixes the path for the whole process, which
    /// is what keeps a mid-run change from splitting the data across two roots.
    static let applicationSupportURL: URL = {
        if let override = AppEnvironment.dataDirectoryOverride { return ensuredDirectory(override) }
        if AppEnvironment.isRunningTests { return ensuredDirectory(AppEnvironment.testDataDirectory) }
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        return ensuredDirectory(base.appendingPathComponent("ClassNote", isDirectory: true))
    }()

    private static func ensuredDirectory(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static var recordingsURL: URL {
        let url = applicationSupportURL.appendingPathComponent("recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func recordingURL(sessionId: String) -> URL {
        recordingsURL.appendingPathComponent("\(sessionId).m4a")
    }

    static func deleteManagedRecording(path: String?) {
        guard let path, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard isManagedRecording(url) || isSyncedRecording(url) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            NSLog("[ClassNote] Failed to delete recording %@: %@", path, error.localizedDescription)
        }
    }

    /// `referencedSessionIds` is a safety net: the file name of a managed
    /// recording *is* its session id, so a file that names a live row is never
    /// an orphan even when that row's `audio_path` was lost.
    @discardableResult
    static func cleanupOrphanedRecordings(referencedPaths: Set<String>,
                                          referencedSessionIds: Set<String> = [],
                                          recordingsRoot: URL = recordingsURL) -> Int {
        let fm = FileManager.default
        let root = recordingsRoot
        let referenced = Set(referencedPaths.compactMap {
            normalizedManagedRecordingPath($0, recordingsRoot: root)
        })
        guard let files = try? fm.contentsOfDirectory(at: root,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            return 0
        }

        var removed = 0
        for file in files where file.pathExtension.lowercased() == "m4a" {
            let sessionId = file.deletingPathExtension().lastPathComponent
            guard !referencedSessionIds.contains(sessionId) else { continue }
            guard normalizedManagedRecordingPath(file.path, recordingsRoot: root)
                .map({ !referenced.contains($0) }) == true else { continue }
            do {
                try fm.removeItem(at: file)
                removed += 1
            } catch {
                NSLog("[ClassNote] Failed to remove orphan recording %@: %@", file.path, error.localizedDescription)
            }
        }
        if removed > 0 {
            NSLog("[ClassNote] Removed %d orphan recording file(s)", removed)
        }
        return removed
    }

    /// A recording LibrarySync moved into the sync folder is still ClassNote's
    /// own. Never swept as an orphan, though: another Mac's library owns the
    /// rest of that folder.
    private static func isSyncedRecording(_ url: URL) -> Bool {
        let root = LibrarySync.defaultRoot.appendingPathComponent("Sessions", isDirectory: true)
        return url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    private static func isManagedRecording(_ url: URL) -> Bool {
        normalizedManagedRecordingPath(url.path) != nil
    }

    private static func normalizedManagedRecordingPath(_ path: String,
                                                       recordingsRoot: URL = recordingsURL) -> String? {
        guard !path.isEmpty else { return nil }
        let rootPath = recordingsRoot.standardizedFileURL.path
        let filePath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        return filePath
    }
}
