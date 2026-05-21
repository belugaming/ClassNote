import Foundation

enum AppBootstrap {
    static func run() {
        do {
            try Database.shared.setup()
        } catch {
            NSLog("[ClassNote] Database setup failed: \(error)")
        }
        GlobalShortcuts.register()
    }

    static var applicationSupportURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("ClassNote", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
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
        guard isManagedRecording(url) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            NSLog("[ClassNote] Failed to delete recording %@: %@", path, error.localizedDescription)
        }
    }

    @discardableResult
    static func cleanupOrphanedRecordings(referencedPaths: Set<String>,
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
