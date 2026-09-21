import Foundation

/// The pids of the running Python sidecars, readable from any thread without
/// awaiting an actor.
///
/// `applicationWillTerminate` runs on the main thread and blocks it, so a Task
/// created there — which inherits the main actor — can never be scheduled
/// before the process exits. Quit-time teardown therefore cannot go through the
/// concurrency runtime at all, which is what this exists for: the owning actors
/// (`LocalASRProcessManager`, `LocalMLXTranslatorProcess`, `LocalMLXLLMProcess`)
/// keep doing the orderly shutdown everywhere else.
final class SidecarRegistry: @unchecked Sendable {
    static let shared = SidecarRegistry()

    private let lock = NSLock()
    private var pids: Set<pid_t> = []

    private init() {}

    /// Only ever called after a successful `process.run()`: `processIdentifier`
    /// is 0 until then, and 0 addresses the whole process group.
    func register(_ pid: pid_t) {
        guard pid > 0 else { return }
        lock.lock()
        pids.insert(pid)
        lock.unlock()
    }

    func unregister(_ pid: pid_t) {
        lock.lock()
        pids.remove(pid)
        lock.unlock()
    }

    /// SIGTERM everything, then SIGKILL whatever is still there ~250 ms later.
    /// Synchronous on purpose: safe to call from `applicationWillTerminate`.
    ///
    /// A child that has exited but has not been reaped by `Process`'s own
    /// waitpid still answers `kill(pid, 0) == 0`, so the wait below usually runs
    /// its full 250 ms and then sends a no-op SIGKILL to a zombie. That is
    /// harmless — do not "optimise" it into `process.isRunning`, which is what
    /// forces the actor hop this type exists to avoid.
    func terminateAll() {
        lock.lock()
        let snapshot = pids
        pids.removeAll()
        lock.unlock()
        guard !snapshot.isEmpty else { return }

        for pid in snapshot { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline, snapshot.contains(where: { kill($0, 0) == 0 }) {
            usleep(20_000)
        }
        for pid in snapshot where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}
