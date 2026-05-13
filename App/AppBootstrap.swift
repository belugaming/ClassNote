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
}
