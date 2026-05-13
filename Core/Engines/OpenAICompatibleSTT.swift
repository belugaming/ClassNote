import Foundation
import AVFoundation

/// OpenAI-compatible chunked STT. Implements /v1/audio/transcriptions.
/// For live streaming, buffers incoming PCM into ~3s WAV chunks and posts each.
final class OpenAICompatibleSTT: STTProvider, Sendable {
    private let config: ApiConfig
    private let chunkDurationSec: Double = 3.0
    private let targetSampleRate: Int = 16000

    init(config: ApiConfig) {
        self.config = config
    }

    func transcribe(audio: AsyncStream<AudioChunk>,
                    language: String?) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    var bufferStartMs: Int64 = 0
                    var bufferEndMs: Int64 = 0
                    let chunkBytes = Int(Double(targetSampleRate) * chunkDurationSec) * 2  // Int16 mono

                    for await chunk in audio {
                        if buffer.isEmpty { bufferStartMs = chunk.timestamp }
                        buffer.append(chunk.pcmData)
                        bufferEndMs = chunk.timestamp + Int64(chunk.pcmData.count / 2 * 1000 / chunk.sampleRate)
                        if buffer.count >= chunkBytes {
                            let wav = WavEncoder.encode(pcm16: buffer, sampleRate: targetSampleRate, channels: 1)
                            let (text, _) = try await Self.postTranscription(wav: wav,
                                                                              config: self.config,
                                                                              language: language)
                            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                                continuation.yield(TranscriptEvent(startMs: bufferStartMs,
                                                                    endMs: bufferEndMs,
                                                                    text: text,
                                                                    isFinal: true))
                            }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    // Flush tail
                    if !buffer.isEmpty {
                        let wav = WavEncoder.encode(pcm16: buffer, sampleRate: targetSampleRate, channels: 1)
                        let (text, _) = try await Self.postTranscription(wav: wav,
                                                                          config: self.config,
                                                                          language: language)
                        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                            continuation.yield(TranscriptEvent(startMs: bufferStartMs,
                                                                endMs: bufferEndMs,
                                                                text: text,
                                                                isFinal: true))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func transcribeFile(url: URL, language: String?) async throws -> [TranscriptEvent] {
        // Convert to 16kHz mono WAV first
        let pcm = try await AudioConverter.convertToPCM16Mono16k(inputURL: url)
        // Slice into 30s chunks with verbose_json to get timestamps
        var events: [TranscriptEvent] = []
        let bytesPerSecond = 16000 * 2
        let sliceSec = 30
        let sliceBytes = bytesPerSecond * sliceSec
        var offset = 0
        var baseMs: Int64 = 0
        while offset < pcm.count {
            let end = min(offset + sliceBytes, pcm.count)
            let slice = pcm[offset..<end]
            let wav = WavEncoder.encode(pcm16: Data(slice), sampleRate: 16000, channels: 1)
            let segments = try await Self.postTranscriptionVerbose(wav: wav,
                                                                    config: config,
                                                                    language: language)
            for seg in segments {
                events.append(TranscriptEvent(
                    startMs: baseMs + Int64(seg.start * 1000),
                    endMs: baseMs + Int64(seg.end * 1000),
                    text: seg.text,
                    isFinal: true))
            }
            let ms = Int64(Double(end - offset) / Double(bytesPerSecond) * 1000)
            baseMs += ms
            offset = end
        }
        return events
    }

    // MARK: - HTTP

    struct VerboseSegment: Decodable {
        let id: Int
        let start: Double
        let end: Double
        let text: String
    }

    struct VerboseResponse: Decodable {
        let text: String
        let segments: [VerboseSegment]?
    }

    struct SimpleResponse: Decodable {
        let text: String
    }

    static func postTranscription(wav: Data, config: ApiConfig, language: String?) async throws -> (String, Data) {
        let (resp, data) = try await postMultipart(wav: wav, config: config, language: language, verbose: false)
        if !(200..<300).contains(resp.statusCode) {
            throw EngineError.httpError(status: resp.statusCode,
                                        body: String(data: data, encoding: .utf8) ?? "")
        }
        if let obj = try? JSONDecoder().decode(SimpleResponse.self, from: data) {
            return (obj.text, data)
        }
        return (String(data: data, encoding: .utf8) ?? "", data)
    }

    static func postTranscriptionVerbose(wav: Data, config: ApiConfig, language: String?) async throws -> [VerboseSegment] {
        let (resp, data) = try await postMultipart(wav: wav, config: config, language: language, verbose: true)
        if !(200..<300).contains(resp.statusCode) {
            throw EngineError.httpError(status: resp.statusCode,
                                        body: String(data: data, encoding: .utf8) ?? "")
        }
        let obj = try JSONDecoder().decode(VerboseResponse.self, from: data)
        if let segs = obj.segments { return segs }
        return [VerboseSegment(id: 0, start: 0, end: 0, text: obj.text)]
    }

    static func postMultipart(wav: Data, config: ApiConfig, language: String?, verbose: Bool) async throws -> (HTTPURLResponse, Data) {
        guard !config.apiKey.isEmpty else { throw EngineError.missingApiKey }
        var comps = URLComponents(string: config.baseUrl.hasSuffix("/") ? config.baseUrl + "audio/transcriptions" : config.baseUrl + "/audio/transcriptions")
        guard let url = comps?.url else { throw EngineError.networkError("Invalid base URL") }

        let boundary = "----ClassNote-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField(name: "model", value: config.sttModel)
        if let lang = language, !lang.isEmpty {
            appendField(name: "language", value: lang)
        }
        if verbose {
            appendField(name: "response_format", value: "verbose_json")
        } else {
            appendField(name: "response_format", value: "json")
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.networkError("Response is not HTTP")
        }
        return (http, data)
    }
}

/// Minimal PCM16 mono WAV encoder.
enum WavEncoder {
    static func encode(pcm16: Data, sampleRate: Int, channels: Int) -> Data {
        var wav = Data()
        let byteRate = UInt32(sampleRate * channels * 2)
        let blockAlign = UInt16(channels * 2)
        let subchunk2Size = UInt32(pcm16.count)
        let chunkSize = 36 + subchunk2Size

        wav.append("RIFF".data(using: .ascii)!)
        wav.append(uint32LE(chunkSize))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(uint32LE(16))          // PCM chunk size
        wav.append(uint16LE(1))           // format = PCM
        wav.append(uint16LE(UInt16(channels)))
        wav.append(uint32LE(UInt32(sampleRate)))
        wav.append(uint32LE(byteRate))
        wav.append(uint16LE(blockAlign))
        wav.append(uint16LE(16))          // bits per sample
        wav.append("data".data(using: .ascii)!)
        wav.append(uint32LE(subchunk2Size))
        wav.append(pcm16)
        return wav
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var v = v.littleEndian
        return Data(bytes: &v, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var v = v.littleEndian
        return Data(bytes: &v, count: 2)
    }
}

enum AudioConverter {
    static func convertToPCM16Mono16k(inputURL: URL) async throws -> Data {
        let asset = AVURLAsset(url: inputURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw EngineError.unsupported("No audio track in \(inputURL.lastPathComponent)")
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw EngineError.unsupported("Could not start reading asset")
        }
        var result = Data()
        while let sample = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sample) {
                var length = 0
                var ptr: UnsafeMutablePointer<Int8>? = nil
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
                if let ptr = ptr {
                    result.append(Data(bytes: ptr, count: length))
                }
            }
            CMSampleBufferInvalidate(sample)
        }
        if reader.status == .failed {
            throw reader.error ?? EngineError.unsupported("Asset reader failed")
        }
        return result
    }
}
