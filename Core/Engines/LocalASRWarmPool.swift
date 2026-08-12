import Foundation

/// Keeps one local ASR sidecar alive across recordings.
///
/// Model loading costs ~30s (plus a multi-minute first-run download), and the
/// sidecar creates a fresh Session per WebSocket connection while sharing the
/// loaded models. So the process is worth keeping: starting it once at launch
/// makes every later recording begin immediately.
///
/// A sidecar is bound to the language it loaded models for, so a language or
/// engine change retires the old process and starts a new one.
actor LocalASRWarmPool {
    static let shared = LocalASRWarmPool()

    struct Key: Equatable {
        let engine: LocalASREngineKind
        /// Normalized source language; nil means the sidecar's own default.
        let language: String?
    }

    /// A loaded sidecar holds ~4.6 GB resident (measured), which is a lot to keep
    /// for a user who is not recording. Retire it after this long with no
    /// connection; the next recording reloads it, paying ~30s once.
    static let idleTimeout: TimeInterval = 30 * 60

    private var key: Key?
    private var idleTimer: Task<Void, Never>?
    private var activeConnections = 0
    private var manager: LocalASRProcessManager?
    private var socketURL: URL?
    /// The in-flight warm-up, so concurrent callers await one start instead of
    /// racing to spawn duplicate processes.
    private var warmTask: Task<URL, Error>?

    private init() {}

    /// Returns a ws URL for a ready sidecar, starting or reusing one as needed.
    func url(engine: LocalASREngineKind,
             language: String?,
             onProgress: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        let wanted = Key(engine: engine, language: Self.normalize(language))

        if let key, key != wanted {
            // Different language or engine: the loaded models cannot serve it.
            await retire()
        }

        if let socketURL, let manager, await manager.isRunning {
            return socketURL
        }
        if let warmTask {
            return try await warmTask.value
        }

        let task = Task<URL, Error> { [wanted] in
            let manager = LocalASRProcessManager(engine: wanted.engine)
            let url = try await manager.start(language: wanted.language,
                                             onProgress: onProgress)
            await self.adopt(key: wanted, manager: manager, url: url)
            return url
        }
        warmTask = task
        do {
            let url = try await task.value
            warmTask = nil
            return url
        } catch {
            warmTask = nil
            await retire()
            throw error
        }
    }

    /// Starts a sidecar ahead of time, ignoring failures. Used at launch and
    /// after a settings change so the first recording does not pay for loading.
    func preload(engine: LocalASREngineKind,
                 language: String?,
                 onProgress: (@Sendable (String) -> Void)? = nil) async {
        _ = try? await url(engine: engine, language: language, onProgress: onProgress)
    }

    /// True when a sidecar for exactly this configuration is up.
    func isReady(engine: LocalASREngineKind, language: String?) async -> Bool {
        guard let key, key == Key(engine: engine, language: Self.normalize(language)),
              let manager else { return false }
        return await manager.isRunning
    }

    /// Shuts down the current sidecar, e.g. on quit or a settings change.
    func retire() async {
        idleTimer?.cancel()
        idleTimer = nil
        warmTask?.cancel()
        warmTask = nil
        if let manager {
            await manager.shutdown()
        }
        manager = nil
        socketURL = nil
        key = nil
    }

    private func adopt(key: Key, manager: LocalASRProcessManager, url: URL) {
        self.key = key
        self.manager = manager
        self.socketURL = url
        scheduleIdleRetire()
    }

    /// Marks a connection as open, suspending the idle countdown for its
    /// duration. Callers must pair this with `endUse()`.
    func beginUse() {
        activeConnections += 1
        idleTimer?.cancel()
        idleTimer = nil
    }

    func endUse() {
        activeConnections = max(0, activeConnections - 1)
        if activeConnections == 0 {
            scheduleIdleRetire()
        }
    }

    private func scheduleIdleRetire() {
        idleTimer?.cancel()
        guard activeConnections == 0 else { return }
        idleTimer = Task { [timeout = Self.idleTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            NSLog("[LocalASRWarmPool] idle for \(Int(timeout))s, freeing models")
            await self.retireIfStillIdle()
        }
    }

    private func retireIfStillIdle() async {
        guard activeConnections == 0 else { return }
        await retire()
    }

    /// Treats "", "auto" and equivalent spellings as one value, so a cosmetic
    /// settings change does not needlessly restart a healthy sidecar.
    private static func normalize(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty || trimmed == "auto" { return nil }
        // Only the language family selects a model set (zh-Hans and zh-CN both
        // load the Chinese models), so collapse regional variants.
        if trimmed.hasPrefix("zh") { return "zh" }
        if trimmed.hasPrefix("en") { return "en" }
        return trimmed
    }
}
