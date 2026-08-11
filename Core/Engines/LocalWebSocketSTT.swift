import Foundation

/// STTProvider backed by a local Python WebSocket sidecar (FunASR / Nemotron).
/// The sidecar process is started lazily on the first `transcribe(...)` call
/// and torn down when the returned stream terminates for any reason.
final class LocalWebSocketSTT: STTProvider, Sendable {
    private let engine: LocalASREngineKind

    init(engine: LocalASREngineKind) {
        self.engine = engine
    }

    func transcribe(audio: AsyncStream<AudioChunk>,
                    language: String?) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let engine = self.engine
        return AsyncThrowingStream { continuation in
            let processManager = LocalASRProcessManager(engine: engine)
            let task = Task {
                do {
                    let wsURL = try await processManager.start()
                    let session = URLSession(configuration: .default)
                    let socket = session.webSocketTask(with: wsURL)
                    socket.resume()

                    let sender = Task {
                        for await chunk in audio {
                            try? await socket.send(.data(chunk.pcmData))
                        }
                        socket.cancel(with: .goingAway, reason: nil)
                    }

                    while true {
                        let message = try await socket.receive()
                        guard case .string(let text) = message,
                              let data = text.data(using: .utf8),
                              let json = try? JSONDecoder().decode(SidecarEvent.self, from: data) else {
                            continue
                        }
                        continuation.yield(json.toTranscriptEvent())
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await processManager.shutdown() }
            }
        }
    }

    func transcribeFile(url: URL,
                        language: String?) -> AsyncThrowingStream<FileTranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: EngineError.unsupported("本地流式引擎不支持文件导入"))
        }
    }
}

struct SidecarEvent: Decodable {
    let type: String
    let segmentId: Int64
    let startMs: Int64
    let endMs: Int64
    let text: String

    func toTranscriptEvent() -> TranscriptEvent {
        switch type {
        case "final":
            return TranscriptEvent(startMs: startMs, endMs: endMs, text: text, isFinal: true,
                                    engineSegmentId: segmentId, isRevision: false)
        case "revised":
            return TranscriptEvent(startMs: startMs, endMs: endMs, text: text, isFinal: true,
                                    engineSegmentId: segmentId, isRevision: true)
        default: // "partial"
            return TranscriptEvent(startMs: startMs, endMs: endMs, text: text, isFinal: false,
                                    engineSegmentId: segmentId, isRevision: false)
        }
    }
}
