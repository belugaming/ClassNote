import Foundation

/// Keeps one local ASR sidecar alive across recordings.
///
/// Model loading costs a few seconds (plus a ~650 MB first-run download), and
/// the sidecar creates a fresh Session per WebSocket connection while sharing
/// the loaded model. So the process is worth keeping: starting it once at
/// launch makes every later recording begin immediately.
///
/// A sidecar is bound to the chunk size it loaded, so a latency or engine
/// change retires the old process and starts a new one. The model itself is
/// multilingual; the language is only a per-connection hint.
actor LocalASRWarmPool {
    static let shared = LocalASRWarmPool()

    struct Key: Equatable {
        let engine: LocalASREngineKind
        /// Normalized source language; nil means the sidecar's own default.
        let language: String?
        /// Which chunk-size export is loaded. Part of the identity: each is a
        /// different model file, so a warm sidecar cannot serve another one.
        let latency: LocalEngineLatency
    }

    /// A loaded sidecar holds ~2 GB resident (measured), which is a lot to keep
    /// for a user who is not recording. Retire it after this long with no
    /// connection; the next recording reloads it, paying a few seconds once.
    static let idleTimeout: TimeInterval = 30 * 60

    private var key: Key?
    private var idleTimer: Task<Void, Never>?
    private var activeConnections = 0
    /// Set when a retire was asked for while a connection was open. The sidecar
    /// goes away as soon as the last connection closes instead of being killed
    /// out from under a recording.
    private var retireWhenIdle = false
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
        let wanted = Key(engine: engine, language: Self.normalize(language),
                         latency: LocalEngineLatency.current)

        if let key, key != wanted {
            // Different language or engine: the loaded models cannot serve it.
            // Refuse rather than kill — a file import asking for another
            // configuration must not SIGKILL the sidecar a live recording is
            // streaming through.
            guard activeConnections == 0 else {
                throw LocalASRProcessError.busyWithDifferentConfiguration
            }
            await retire(force: true)
        }

        if let socketURL, let manager, await manager.isRunning {
            return socketURL
        }
        if let warmTask {
            return try await warmTask.value
        }
        // The configuration still matches but the process is gone (it crashed,
        // was killed, or died while the Mac slept). Drop the stale manager so a
        // fresh sidecar is started instead of handing out a URL that nothing is
        // listening on.
        if manager != nil {
            await retire(force: true)
        }

        let task = Task<URL, Error> { [wanted] in
            let manager = LocalASRProcessManager(engine: wanted.engine)
            let url = try await manager.start(language: wanted.language,
                                             onProgress: onProgress)
            // No `await`: `Task` inherits this actor's isolation, so `adopt`
            // is a synchronous call on the same actor.
            self.adopt(key: wanted, manager: manager, url: url)
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
        guard let key, key == Key(engine: engine, language: Self.normalize(language),
                                  latency: LocalEngineLatency.current),
              let manager else { return false }
        return await manager.isRunning
    }

    /// Whether a connection is currently streaming through the sidecar.
    var isInUse: Bool { activeConnections > 0 }

    /// Shuts down the current sidecar, e.g. on quit or a settings change.
    ///
    /// Returns false and defers when a connection is open: Settings, a language
    /// change and the "Unload from memory" button are all reachable while
    /// recording, and killing the process there ends the recording's
    /// transcription for good. `force` is for quit, where an orphaned 2 GB
    /// sidecar holding its port is the worse outcome.
    @discardableResult
    func retire(force: Bool = false) async -> Bool {
        guard force || activeConnections == 0 else {
            retireWhenIdle = true
            return false
        }
        retireWhenIdle = false
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
        return true
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

    func endUse() async {
        activeConnections = max(0, activeConnections - 1)
        guard activeConnections == 0 else { return }
        if retireWhenIdle {
            await retire()
        } else {
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
