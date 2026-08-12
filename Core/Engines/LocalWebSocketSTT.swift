import Foundation

/// STTProvider backed by the local FunASR Python WebSocket sidecar.
///
/// The sidecar process is started lazily on the first call and torn down when
/// the returned stream terminates for any reason. One process per call, so a
/// live session and a file import never share streaming state.
final class LocalWebSocketSTT: STTProvider, Sendable {
    private let engine: LocalASREngineKind
    private let language: String?
    /// Reports setup stages (dependency install, model loading) so the UI can
    /// show why the first start takes a while instead of appearing frozen.
    private let onProgress: (@Sendable (String) -> Void)?

    init(engine: LocalASREngineKind,
         language: String? = nil,
         onProgress: (@Sendable (String) -> Void)? = nil) {
        self.engine = engine
        self.language = language
        self.onProgress = onProgress
    }

    func transcribe(audio: AsyncStream<AudioChunk>,
                    language: String?) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let engine = self.engine
        let lang = language ?? self.language
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let connection = try await LocalASRConnection.connect(engine: engine,
                                                                         language: lang,
                                                                         onProgress: self.onProgress)
                    // Pump audio and receive events concurrently: the sidecar
                    // emits partials while we are still sending, so these must
                    // not be serialized.
                    let sender = Task {
                        for await chunk in audio {
                            try await connection.send(pcm: chunk.pcmData)
                        }
                        // Tell the sidecar to flush its final utterance rather
                        // than just dropping the socket, which would lose the
                        // last segment's offline revision.
                        try? await connection.sendEOF()
                    }
                    defer { sender.cancel() }

                    try await connection.receiveLoop { event in
                        if let transcript = event.asTranscriptEvent() {
                            continuation.yield(transcript)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                // Only the connection ends here. The sidecar stays warm so the
                // next recording does not pay for model loading again.
                task.cancel()
            }
        }
    }

    func transcribeFile(url: URL,
                        language: String?) -> AsyncThrowingStream<FileTranscriptionEvent, Error> {
        let engine = self.engine
        let lang = language ?? self.language
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let connection = try await LocalASRConnection.connect(engine: engine,
                                                                         language: lang,
                                                                         onProgress: self.onProgress)
                    // Release the sidecar hold even if sending the request fails,
                    // otherwise its idle timer would never resume.
                    do {
                        try await connection.sendFile(path: url.path)
                    } catch {
                        await LocalASRWarmPool.shared.endUse()
                        throw error
                    }
                    try await connection.receiveLoop { event in
                        switch event.type {
                        case "progress":
                            continuation.yield(.progress(completed: event.completed ?? 0,
                                                         total: event.total ?? 1))
                        default:
                            if let transcript = event.asTranscriptEvent() {
                                continuation.yield(.segment(transcript))
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                // The sidecar is shared and stays warm; only this connection ends.
            }
        }
    }
}
