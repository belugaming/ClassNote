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

    /// Maps transcript-bearing events onto `TranscriptEvent`. Returns nil for
    /// control frames (status/progress/eof/error), which callers handle
    /// themselves.
    func asTranscriptEvent() -> TranscriptEvent? {
        let start = startMs ?? 0
        let end = endMs ?? start
        // The sidecar sends `listening` when it is capturing speech but cannot
        // produce partials — FunASR has no English streaming model, so English
        // would otherwise show nothing at all until the sentence completes.
        if type == "listening" {
            return TranscriptEvent(startMs: start, endMs: end,
                                   text: L10n.t("localASR.recognizing"), isFinal: false,
                                   engineSegmentId: segmentId, isRevision: false)
        }
        guard let text, !text.isEmpty else { return nil }
        switch type {
        case "final":
            return TranscriptEvent(startMs: start, endMs: end, text: text, isFinal: true,
                                   engineSegmentId: segmentId, isRevision: false)
        case "revised":
            return TranscriptEvent(startMs: start, endMs: end, text: text, isFinal: true,
                                   engineSegmentId: segmentId, isRevision: true)
        case "partial":
            return TranscriptEvent(startMs: start, endMs: end, text: text, isFinal: false,
                                   engineSegmentId: segmentId, isRevision: false)
        default:
            return nil
        }
    }
}

enum LocalASRConnectionError: Error, LocalizedError {
    case sidecar(String)

    var errorDescription: String? {
        switch self {
        case .sidecar(let message): return message
        }
    }
}

/// Thin async wrapper over the sidecar WebSocket, owning message framing so
/// both the live and file paths speak the same protocol.
actor LocalASRConnection {
    private let socket: URLSessionWebSocketTask
    private let session: URLSession

    private init(socket: URLSessionWebSocketTask, session: URLSession) {
        self.socket = socket
        self.session = session
    }

    static func connect(manager: LocalASRProcessManager,
                        language: String?,
                        onProgress: (@Sendable (String) -> Void)? = nil) async throws -> LocalASRConnection {
        let url = try await manager.start(language: language, onProgress: onProgress)
        let configuration = URLSessionConfiguration.default
        // The sidecar can be quiet for a while during a long silence; don't let
        // URLSession time the socket out underneath us.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        let connection = LocalASRConnection(socket: socket, session: session)
        try await connection.sendConfig(language: language)
        return connection
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await socket.send(.string(text))
    }

    func sendConfig(language: String?) async throws {
        var payload: [String: Any] = ["type": "config"]
        if let language, !language.isEmpty { payload["language"] = language }
        try await sendJSON(payload)
    }

    func send(pcm: Data) async throws {
        try await socket.send(.data(pcm))
    }

    func sendEOF() async throws {
        try await sendJSON(["type": "eof"])
    }

    func sendFile(path: String) async throws {
        try await sendJSON(["type": "file", "path": path])
    }

    /// Reads until the sidecar signals `eof`, the socket closes, or the task is
    /// cancelled. Throws on an `error` frame so the failure surfaces in the UI
    /// instead of looking like an empty transcript.
    func receiveLoop(onEvent: (SidecarEvent) -> Void) async throws {
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        while true {
            try Task.checkCancellation()
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
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
                throw LocalASRConnectionError.sidecar(event.message ?? "本地引擎错误")
            case "status":
                continue
            default:
                onEvent(event)
            }
        }
    }
}
