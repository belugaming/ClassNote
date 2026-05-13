import Foundation
import AVFoundation

/// OpenAI-compatible chunked STT. Implements /v1/audio/transcriptions.
///
/// Streaming strategy: commit audio on silence boundaries, then let Whisper do
/// its own sentence-level segmentation inside each committed chunk via
/// `response_format=verbose_json`. We emit one TranscriptEvent per Whisper
/// segment rather than per HTTP call, so a 10-second chunk with 3 sentences
/// becomes 3 live-subtitle lines instead of one blob.
///   - minVoicedSec  : keep buffering voiced audio up to this duration
///   - silenceHoldSec: once past `minVoicedSec`, commit after this much trailing silence
///   - maxChunkSec   : hard upper bound so we never hold audio forever
/// We also pass the previous final text as Whisper's `prompt` to get cleaner continuity.
final class OpenAICompatibleSTT: STTProvider, Sendable {
    private let config: ApiConfig
    private let targetSampleRate: Int = 16000
    private let minVoicedSec: Double = 3.0
    private let silenceHoldSec: Double = 0.5
    private let maxChunkSec: Double = 12.0
    private let rmsThreshold: Double = 0.01
    private let minEmitChars: Int = 3

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
                    var voicedBytes = 0
                    var silentTrailBytes = 0
                    var promptCarry: String = ""
                    let bytesPerSec = targetSampleRate * 2
                    let maxBytes = Int(self.maxChunkSec * Double(bytesPerSec))
                    let minVoicedBytes = Int(self.minVoicedSec * Double(bytesPerSec))
                    let silenceHoldBytes = Int(self.silenceHoldSec * Double(bytesPerSec))

                    func flush() async throws {
                        guard !buffer.isEmpty else { return }
                        let wav = WavEncoder.encode(pcm16: buffer, sampleRate: self.targetSampleRate, channels: 1)
                        let startMs = bufferStartMs
                        let endMs = bufferEndMs
                        buffer.removeAll(keepingCapacity: true)
                        voicedBytes = 0
                        silentTrailBytes = 0

                        let segments = try await Self.postTranscriptionVerbose(
                            wav: wav,
                            config: self.config,
                            language: language,
                            prompt: promptCarry.isEmpty ? nil : promptCarry
                        )

                        // Emit each Whisper segment as its own event so the UI
                        // gets sentence-level granularity without us guessing
                        // where the boundaries are.
                        var emittedAny = false
                        for seg in segments {
                            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard Self.shouldEmit(text, minChars: self.minEmitChars) else { continue }
                            let segStart = startMs + Int64(seg.start * 1000)
                            let segEnd = min(endMs, startMs + Int64(seg.end * 1000))
                            continuation.yield(TranscriptEvent(startMs: segStart,
                                                                endMs: segEnd,
                                                                text: text,
                                                                isFinal: true))
                            promptCarry = String((promptCarry + " " + text).suffix(240))
                                .trimmingCharacters(in: .whitespaces)
                            emittedAny = true
                        }
                        // Fallback: if verbose_json returned no segments (rare —
                        // some providers only fill `text`), try to emit the
                        // concatenated text as a single event.
                        if !emittedAny, let joined = Self.joinedText(segments) {
                            let t = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                            if Self.shouldEmit(t, minChars: self.minEmitChars) {
                                continuation.yield(TranscriptEvent(startMs: startMs,
                                                                    endMs: endMs,
                                                                    text: t,
                                                                    isFinal: true))
                                promptCarry = String((promptCarry + " " + t).suffix(240))
                                    .trimmingCharacters(in: .whitespaces)
                            }
                        }
                    }

                    for await chunk in audio {
                        let chunkBytes = chunk.pcmData.count
                        let rms = VADGate.rms(pcm16: chunk.pcmData)
                        let isVoiced = rms >= self.rmsThreshold

                        if buffer.isEmpty {
                            bufferStartMs = chunk.timestamp
                            silentTrailBytes = 0
                        }
                        buffer.append(chunk.pcmData)
                        let chunkDurMs = Int64(Double(chunkBytes) / Double(bytesPerSec) * 1000)
                        bufferEndMs = chunk.timestamp + chunkDurMs

                        if isVoiced {
                            voicedBytes += chunkBytes
                            silentTrailBytes = 0
                        } else {
                            silentTrailBytes += chunkBytes
                        }

                        // Commit conditions (priority order):
                        // 1. Hard cap: max chunk duration reached.
                        // 2. Natural: enough voice collected AND we've hit trailing silence.
                        if buffer.count >= maxBytes {
                            try await flush()
                        } else if voicedBytes >= minVoicedBytes && silentTrailBytes >= silenceHoldBytes {
                            try await flush()
                        }
                    }

                    // End of stream: flush whatever is pending.
                    if !buffer.isEmpty && voicedBytes > bytesPerSec / 2 {
                        try await flush()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reject empty / trivially short / obvious hallucination outputs.
    static func shouldEmit(_ text: String, minChars: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.count < minChars { return false }
        // Common Whisper hallucinations on near-silent audio.
        let junk: Set<String> = [
            "The.", "The", "you", "You.", "you.",
            "Thank you.", "thank you",
            "...", ". . .",
            "Subtitles by the Amara.org community",
            "[BLANK_AUDIO]"
        ]
        if junk.contains(trimmed) { return false }
        // If the whole output is a single word with no spaces or just punctuation noise, reject.
        let lettersAndDigits = trimmed.unicodeScalars.filter { CharacterSet.letters.union(.decimalDigits).contains($0) }
        if lettersAndDigits.count < 3 { return false }
        return true
    }

    /// Fallback used when `segments` comes back empty but the API still
    /// returned something useful in `text`. We stash the full-text on each
    /// VerboseSegment when only one synthetic segment is produced.
    static func joinedText(_ segments: [VerboseSegment]) -> String? {
        let joined = segments.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
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
        let id: Int?
        let start: Double
        let end: Double
        let text: String
    }

    struct VerboseResponse: Decodable {
        // Many OpenAI-compatible providers diverge here: some omit `text` and
        // only return `segments`; others omit `segments` and only return
        // `text`. Make both optional and let the caller reconcile.
        let text: String?
        let segments: [VerboseSegment]?
    }

    struct SimpleResponse: Decodable {
        let text: String
    }

    static func postTranscription(wav: Data, config: ApiConfig, language: String?, prompt: String? = nil) async throws -> (String, Data) {
        let (resp, data) = try await postMultipart(wav: wav, config: config, language: language, verbose: false, prompt: prompt)
        if !(200..<300).contains(resp.statusCode) {
            throw EngineError.httpError(status: resp.statusCode,
                                        body: String(data: data, encoding: .utf8) ?? "")
        }
        if let obj = try? JSONDecoder().decode(SimpleResponse.self, from: data) {
            return (obj.text, data)
        }
        return (String(data: data, encoding: .utf8) ?? "", data)
    }

    static func postTranscriptionVerbose(wav: Data, config: ApiConfig, language: String?, prompt: String? = nil) async throws -> [VerboseSegment] {
        let (resp, data) = try await postMultipart(wav: wav, config: config, language: language, verbose: true, prompt: prompt)
        if !(200..<300).contains(resp.statusCode) {
            throw EngineError.httpError(status: resp.statusCode,
                                        body: String(data: data, encoding: .utf8) ?? "")
        }
        // Try verbose first.
        if let obj = try? JSONDecoder().decode(VerboseResponse.self, from: data) {
            if let segs = obj.segments, !segs.isEmpty {
                return segs
            }
            if let text = obj.text, !text.isEmpty {
                return [VerboseSegment(id: 0, start: 0, end: 0, text: text)]
            }
        }
        // Fallback: provider may have ignored verbose_json and returned the
        // plain `{"text": ...}` shape.
        if let simple = try? JSONDecoder().decode(SimpleResponse.self, from: data),
           !simple.text.isEmpty {
            return [VerboseSegment(id: 0, start: 0, end: 0, text: simple.text)]
        }
        // Last resort: treat the response body as raw text.
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return [] }
        return [VerboseSegment(id: 0, start: 0, end: 0, text: raw)]
    }

    static func postMultipart(wav: Data, config: ApiConfig, language: String?, verbose: Bool, prompt: String? = nil) async throws -> (HTTPURLResponse, Data) {
        guard !config.apiKey.isEmpty else { throw EngineError.missingApiKey }
        let comps = URLComponents(string: config.baseUrl.hasSuffix("/") ? config.baseUrl + "audio/transcriptions" : config.baseUrl + "/audio/transcriptions")
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
        if let p = prompt, !p.isEmpty {
            appendField(name: "prompt", value: p)
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
