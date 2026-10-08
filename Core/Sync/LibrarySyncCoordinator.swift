import AppKit
import Foundation

extension Notification.Name {
    /// Another Mac's changes were applied here. `userInfo["sessionIds"]` lists
    /// the sessions whose rows changed.
    static let librarySyncDidChange = Notification.Name("librarySyncDidChange")
}

/// Runs `LibrarySync` while it is turned on: at launch, every minute, and
/// whenever the app comes to the front.
@MainActor
final class LibrarySyncCoordinator: ObservableObject {
    static let shared = LibrarySyncCoordinator()

    private static let enabledKey = "librarySync.enabled"
    private static let interval: Duration = .seconds(60)

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?

    private var loop: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    var isEnabled: Bool {
        get { AppEnvironment.defaults.bool(forKey: Self.enabledKey) }
        set {
            objectWillChange.send()
            AppEnvironment.defaults.set(newValue, forKey: Self.enabledKey)
            if newValue { start() } else { stop() }
        }
    }

    static var isICloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: LibrarySync.iCloudDriveURL.path)
    }

    /// Called once at launch; does nothing while sync is off.
    func start() {
        guard isEnabled, !AppEnvironment.isRunningTests, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: Self.interval)
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in await LibrarySyncCoordinator.shared.syncNow() }
            }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func syncNow() async {
        guard isEnabled, !isSyncing, let pool = Database.shared.dbPool else { return }
        guard Self.isICloudDriveAvailable else {
            lastError = L10n.t("sync.error.noICloudDrive")
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        let recordingsRoot = AppBootstrap.recordingsURL
        do {
            let report = try await Task.detached(priority: .utility) {
                try LibrarySync(db: pool,
                                root: LibrarySync.defaultRoot,
                                recordingsRoot: recordingsRoot,
                                deviceName: Host.current().localizedName ?? "Mac").run()
            }.value
            lastSyncedAt = Date()
            lastError = report.failures.first
            if !report.failures.isEmpty {
                NSLog("[ClassNote] Sync: %d item(s) failed: %@", report.failures.count,
                      report.failures.joined(separator: "; "))
            }
            if report.changedLibrary {
                NotificationCenter.default.post(name: .librarySyncDidChange, object: nil,
                                                userInfo: ["sessionIds": report.changedSessionIds])
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
