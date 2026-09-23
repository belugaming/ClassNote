import Foundation

/// One event decoded from the sidecar's JSON protocol. Every field past `type`
/// is optional because the same envelope carries transcripts, progress, status
/// and errors.
struct SidecarEvent: Decodable {
    let type: String
    let segmentId: Int64?
    let startMs: Int64?
    let endMs: Int64?
    let text: String?
    let completed: Int?
    let total: Int?
    let message: String?
    let stage: String?
    /// Machine-readable error kind on `error` frames (`file.missing`,
    /// `file.unreadable`, `file.failed`, `internal`). The sidecar's `message` is
    /// an English developer string; the code is what the UI can localize.
    let code: String?
    /// On `final` frames: false when the line was cut for length and its
    /// sentence goes on. Absent means a sentence end, which is what every
    /// line was before the field existed.
    let sentenceEnd: Bool?

    /// Maps transcript-bearing events onto `TranscriptEvent`. Returns nil for
    /// control frames (status/progress/eof/error), which callers handle
    /// themselves.
    func asTranscriptEvent() -> TranscriptEvent? {
        let start = startMs ?? 0
        let end = endMs ?? start
        guard let text, !text.isEmpty else { return nil }
        switch type {
        case "final":
            return TranscriptEvent(startMs: start, endMs: end, text: text, isFinal: true,
                                   continuesSentence: sentenceEnd == false)
        case "partial":
            return TranscriptEvent(startMs: start, endMs: end, text: text, isFinal: false)
        default:
            return nil
        }
    }
}

enum LocalASRConnectionError: Error, LocalizedError {
    /// An `error` frame from the sidecar. `message` is its developer-facing
    /// detail (a path, an exception); `code` is what decides what the user sees.
    case sidecar(code: String?, message: String)

    /// The codes the sidecar documents. An unknown one means the two halves are
    /// out of step, so the raw message is better than a wrong translation.
    private static let knownCodes: Set<String> = [
        "file.missing", "file.unreadable", "file.failed", "internal",
    ]

    var errorDescription: String? {
        switch self {
        case .sidecar(let code, let message):
            guard let code, Self.knownCodes.contains(code) else { return message }
            return L10n.t("localASR.error.\(code)")
        }
    }
}

/// Holds the URLSession objects outside the actor's isolation.
///
/// `receiveLoop`'s cancellation handler has to close the socket from a
/// `@Sendable` closure that runs outside the actor, and neither
/// `URLSessionWebSocketTask` nor `URLSession` is formally `Sendable`, though
/// both are documented as thread-safe.
private final class ConnectionChannel: @unchecked Sendable {
    let socket: URLSessionWebSocketTask
    let session: URLSession

    init(socket: URLSessionWebSocketTask, session: URLSession) {
        self.socket = socket
        self.session = session
    }

    func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Thin async wrapper over the sidecar WebSocket, owning message framing so
/// both the live and file paths speak the same protocol.
actor LocalASRConnection {
    private nonisolated let channel: ConnectionChannel

    private init(socket: URLSessionWebSocketTask, session: URLSession) {
        self.channel = ConnectionChannel(socket: socket, session: session)
    }

    /// Connects to the shared warm sidecar, starting it if it is not up yet.
    /// The process outlives this connection so the next recording reuses it.
    static func connect(engine: LocalASREngineKind,
                        language: String?,
                        hint: String = "",
                        onProgress: (@Sendable (String) -> Void)? = nil) async throws -> LocalASRConnection {
        let url = try await LocalASRWarmPool.shared.url(engine: engine,
                                                       language: language,
                                                       onProgress: onProgress)
        // Hold the sidecar for the life of this connection so its idle timer
        // cannot free the models mid-recording.
        await LocalASRWarmPool.shared.beginUse()
        let configuration = URLSessionConfiguration.default
        // The sidecar can be quiet for a while during a long silence; don't let
        // URLSession time the socket out underneath us.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        let connection = LocalASRConnection(socket: socket, session: session)
        do {
            try await connection.sendConfig(language: language, hint: hint)
        } catch {
            // This is the first write after `resume()`, so it is exactly what
            // fails when the sidecar died between `url()` and the handshake.
            // Nothing downstream runs if we never hand the connection back, and
            // the `beginUse()` above is balanced by exactly one caller, so the
            // hold has to come off here or the pool stays pinned for good.
            await connection.close()
            await LocalASRWarmPool.shared.endUse()
            throw error
        }
        return connection
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await channel.socket.send(.string(text))
    }

    /// Closes the socket without going through `receiveLoop`'s defer. Callers
    /// that connected but never started receiving must use this, or the
    /// URLSession and the sidecar-side Session both leak — the sidecar stays
    /// parked in its read loop with its thread pool alive.
    ///
    /// Deliberately does not call `endUse()`: `connect()`'s `beginUse()` is
    /// balanced by exactly one caller, and doubling it up here would free the
    /// models under a recording.
    func close() {
        channel.close()
    }

    func sendConfig(language: String?, hint: String = "") async throws {
        var payload: [String: Any] = ["type": "config"]
        if let language, !language.isEmpty { payload["language"] = language }
        if !hint.isEmpty { payload["context"] = hint }
        try await sendJSON(payload)
    }

    func send(pcm: Data) async throws {
        try await channel.socket.send(.data(pcm))
    }

    func sendEOF() async throws {
        try await sendJSON(["type": "eof"])
    }

    /// Asks the sidecar to abandon a running file job. Closing the socket alone
    /// only aborts it at the next slice boundary, and only because the sidecar
    /// notices the peer is gone; this gets there first.
    func sendCancel() async throws {
        try await sendJSON(["type": "cancel"])
    }

    func sendFile(path: String) async throws {
        try await sendJSON(["type": "file", "path": path])
    }

    /// Reads until the sidecar signals `eof`, the socket closes, or the task is
    /// cancelled. Throws on an `error` frame so the failure surfaces in the UI
    /// instead of looking like an empty transcript.
    func receiveLoop(onEvent: (SidecarEvent) -> Void) async throws {
        defer {
            channel.close()
            // Release the warm sidecar so its idle countdown can resume. Paired
            // with the beginUse() in connect().
            Task { await LocalASRWarmPool.shared.endUse() }
        }
        while true {
            try Task.checkCancellation()
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await withTaskCancellationHandler {
                    try await channel.socket.receive()
                } onCancel: {
                    // `URLSessionWebSocketTask.receive()` is a completion-handler
                    // API bridged to async and does not observe task
                    // cancellation, so a pending receive only returns when the
                    // sidecar sends its next frame — which for a cancelled job
                    // may be never. Closing the socket is the only way out.
                    channel.close()
                }
            } catch {
                // A closed socket is the normal end of a session; only report
                // it if the peer died before saying eof.
                if Task.isCancelled { return }
                throw error
            }
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let event = try? JSONDecoder().decode(SidecarEvent.self, from: data) else {
                continue
            }
            switch event.type {
            case "eof":
                return
            case "error":
                throw LocalASRConnectionError.sidecar(code: event.code,
                                                      message: event.message ?? L10n.t("localASR.error.internal"))
            case "status":
                continue
            default:
                onEvent(event)
            }
        }
    }
}
