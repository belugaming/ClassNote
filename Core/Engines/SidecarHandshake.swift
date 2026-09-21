import Foundation

/// The startup handshake every Python sidecar speaks on stdout, read without
/// blocking a thread.
///
/// The three sidecars print `STAGE <step>/<total> <key>` lines while they load,
/// then exactly one `READY…` line, or `FATAL …` if loading failed. Waiting for
/// that used to be a deadline loop around `FileHandle.availableData`, which is a
/// blocking read: the deadline was only re-evaluated when the child printed
/// something, so the one case it existed for — a silent child — could never
/// time out, and the parked read held a cooperative-pool thread and the calling
/// actor for as long as the child lived.
enum SidecarHandshake {
    /// Why a handshake ended without READY. Each sidecar maps these onto its own
    /// error type, so the wording stays the one its users already see.
    enum Failure: Error {
        /// The sidecar printed FATAL: it started but could not load its models.
        case modelLoadFailed
        /// stdout reached EOF, or the process is gone.
        case exitedEarly
        /// Nothing was written on either pipe for `stallTimeout`, or the whole
        /// startup ran past `hardTimeout`.
        case stalled
    }

    /// Last-activity timestamp shared by stdout and stderr.
    ///
    /// The stall watchdog must be fed from stderr as well: during a first-run
    /// model download huggingface_hub's progress bars are the only traffic
    /// there, and a single download stage easily outlives the stall timeout.
    final class ActivityClock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()

        func touch() {
            lock.lock()
            last = Date()
            lock.unlock()
        }

        var idle: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return Date().timeIntervalSince(last)
        }
    }

    /// No traffic at all on either pipe for this long means the sidecar is stuck
    /// rather than working.
    static let stallTimeout: TimeInterval = 180
    /// Backstop for a sidecar that keeps printing but never becomes ready (a
    /// download retry loop, say). Generous because a cold first run on a slow
    /// connection legitimately takes tens of minutes.
    static let hardTimeout: TimeInterval = 60 * 60

    /// Waits for `readyLine` on `pipe`, reporting STAGE lines through
    /// `onProgress` as they arrive.
    ///
    /// Returns whatever bytes followed the READY line in the same read. The
    /// NDJSON sidecars must feed those to their line parser before installing
    /// their own `readabilityHandler`, or a response that shared a read with the
    /// handshake would be dropped and its request would hang forever.
    ///
    /// - Parameter stageMessage: renders a `STAGE <counter> <key>` line for the
    ///   status line; each sidecar names its stages differently.
    static func waitForReady(pipe: Pipe,
                             readyLine: String,
                             process: Process,
                             activity: ActivityClock,
                             stageMessage: @escaping @Sendable (String, String) -> String,
                             onProgress: (@Sendable (String) -> Void)?) async throws -> Data {
        let handle = pipe.fileHandleForReading
        let state = HandshakeState()
        let lines = LineBuffer()
        let startedAt = Date()

        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                // EOF: the child closed stdout, which for these sidecars only
                // happens when it is on its way out.
                fileHandle.readabilityHandler = nil
                state.finish(.failure(Failure.exitedEarly))
                return
            }
            activity.touch()
            let parsed = lines.append(data)
            for (index, line) in parsed.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == readyLine {
                    // Stop reading here: everything after READY belongs to the
                    // caller's own handler, and the bytes already buffered go
                    // back with the result.
                    fileHandle.readabilityHandler = nil
                    var leftover = Data()
                    for rest in parsed[(index + 1)...] {
                        leftover.append(contentsOf: Array(rest.utf8))
                        leftover.append(UInt8(ascii: "\n"))
                    }
                    leftover.append(lines.drain())
                    state.finish(.success(leftover))
                    return
                }
                if trimmed.hasPrefix("FATAL") {
                    fileHandle.readabilityHandler = nil
                    state.finish(.failure(Failure.modelLoadFailed))
                    return
                }
                guard trimmed.hasPrefix("STAGE ") else { continue }
                // "STAGE 2/4 download" — parsed per line rather than by
                // rescanning the accumulated text, which used to re-report every
                // stage on every read.
                let parts = trimmed.split(separator: " ", maxSplits: 2,
                                          omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 3 else { continue }
                onProgress?(stageMessage(parts[1], parts[2]))
            }
        }

        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                if !process.isRunning {
                    // The last bytes may still be in the pipe; give the reader a
                    // moment to turn a trailing FATAL into the better message.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    state.finish(.failure(Failure.exitedEarly))
                    return
                }
                if activity.idle > stallTimeout || Date().timeIntervalSince(startedAt) > hardTimeout {
                    state.finish(.failure(Failure.stalled))
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        do {
            // A checked continuation does not observe cancellation on its own,
            // and the warm pool cancels its start task on retire — without this
            // an abandoned warm-up would sit here until the watchdog fired.
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    state.attach(continuation)
                }
            } onCancel: {
                state.finish(.failure(CancellationError()))
            }
        } catch {
            handle.readabilityHandler = nil
            throw error
        }
    }
}

/// Resolves the handshake exactly once, whichever of the pipe callback and the
/// watchdog gets there first. Both run outside any actor, hence the lock.
private final class HandshakeState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var settled: Result<Data, Error>?
    private var finished = false

    /// The handler and the watchdog are installed before the continuation
    /// exists, so a result that arrives first is held until it can be delivered.
    func attach(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let settled {
            lock.unlock()
            continuation.resume(with: settled)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let waiting = continuation
        continuation = nil
        if waiting == nil { settled = result }
        lock.unlock()
        waiting?.resume(with: result)
    }
}

/// Splits a pipe's byte stream into lines, holding the trailing partial line
/// until the rest of it arrives.
///
/// `readabilityHandler` callbacks arrive on the pipe's own queue, so the buffer
/// needs a lock. Splitting on bytes rather than decoding each read also keeps a
/// multi-byte character that straddles two reads from being dropped.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var result: [String] = []
        while let index = data.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = data[data.startIndex..<index]
            data.removeSubrange(data.startIndex...index)
            result.append(String(decoding: lineData, as: UTF8.self))
        }
        return result
    }

    /// The incomplete tail, handed to the caller when the handshake ends.
    func drain() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let rest = data
        data.removeAll()
        return rest
    }
}
