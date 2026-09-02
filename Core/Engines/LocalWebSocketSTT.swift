import Foundation

/// STTProvider backed by the local sherpa-onnx (Nemotron) Python WebSocket
/// sidecar.
///
/// The sidecar process is shared and kept warm (see `LocalASRWarmPool`); each
/// call opens its own WebSocket connection, and the sidecar gives every
/// connection its own stream, so a live session and a file import never share
/// decoding state.
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
                    // The sidecar only reads 16 kHz mono WAV; AVFoundation here
                    // handles every container macOS can play (m4a, mp4, mov,
                    // mp3…), so the conversion happens on this side.
                    let wavURL: URL
                    do {
                        let pcm = try await AudioConverter.convertToPCM16Mono16k(inputURL: url)
                        let wav = WavEncoder.encode(pcm16: pcm, sampleRate: 16000, channels: 1)
                        wavURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("classnote-import-\(UUID().uuidString).wav")
                        try wav.write(to: wavURL)
                    } catch {
                        await LocalASRWarmPool.shared.endUse()
                        throw error
                    }
                    defer { try? FileManager.default.removeItem(at: wavURL) }
                    // Release the sidecar hold even if sending the request fails,
                    // otherwise its idle timer would never resume.
                    do {
                        try await connection.sendFile(path: wavURL.path)
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
