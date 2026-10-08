import Foundation

/// A file in iCloud Drive may be only in the cloud ("Optimize Mac Storage", or
/// not arrived yet). Reading it then blocks until it has downloaded, so callers
/// on the main actor download it first.
enum CloudFile {
    static func needsDownload(_ url: URL) -> Bool {
        // A fresh URL: resource values are cached per URL instance.
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                               .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    /// Returns once the file is on this Mac; a file not in iCloud returns at once.
    static func ensureDownloaded(_ url: URL, timeout: Duration = .seconds(900)) async throws {
        guard needsDownload(url) else { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while needsDownload(url) {
            guard clock.now < deadline else { throw CocoaError(.ubiquitousFileUnavailable) }
            try await Task.sleep(for: .milliseconds(500))
        }
    }
}
