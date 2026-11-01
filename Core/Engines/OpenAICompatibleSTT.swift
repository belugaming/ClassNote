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
    /// Waits before each retry of an upload that failed for a reason that may
    /// pass. Injectable so tests need not sit through the real ones.
    private let retryDelays: [TimeInterval]

    /// Three retries, a few seconds in all: enough to ride out a Wi-Fi
    /// handoff or a brief 503 without holding a chunk for long.
    static let defaultRetryDelays: [TimeInterval] = [1, 2, 4]

    init(config: ApiConfig, retryDelays: [TimeInterval] = OpenAICompatibleSTT.defaultRetryDelays) {
        self.config = config
        self.retryDelays = retryDelays
    }

    /// Audio committed for upload, on the bus's own clock.
    private struct CommittedAudio: Sendable {
        let pcm: Data
        let startMs: Int64
        let endMs: Int64
    }

    func transcribe(audio: AsyncStream<AudioChunk>,
                    language: String?) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            // Intake and upload run apart. The bus's stream keeps only ~40 s
            // and drops the oldest audio past that, so reading it only between
            // uploads lost audio whenever one was slow or being retried.
            // Committed audio waits here, in order, until its upload succeeds.
            let (committed, commit) = AsyncStream<CommittedAudio>.makeStream()

            let uploader = Task {
                do {
                    var promptCarry: String = ""
                    for await chunk in committed {
                        let startMs = chunk.startMs
                        let endMs = chunk.endMs
                        let segments = try await Self.postTranscriptionVerbose(
                            wav: WavEncoder.encode(pcm16: chunk.pcm, sampleRate: self.targetSampleRate, channels: 1),
                            config: self.config,
                            language: language,
                            prompt: promptCarry.isEmpty ? nil : promptCarry,
                            // A reply without timings (plain `json`) becomes one
                            // line spanning the chunk, not a zero-length one.
                            fallbackDurationSec: Double(endMs - startMs) / 1000,
                            retryDelays: self.retryDelays)

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
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            let reader = Task {
                var buffer = Data()
                var bufferStartMs: Int64 = 0
                var bufferEndMs: Int64 = 0
                var voicedBytes = 0
                var silentTrailBytes = 0
                let bytesPerSec = targetSampleRate * 2
                let maxBytes = Int(self.maxChunkSec * Double(bytesPerSec))
                let minVoicedBytes = Int(self.minVoicedSec * Double(bytesPerSec))
                let silenceHoldBytes = Int(self.silenceHoldSec * Double(bytesPerSec))

                func flush() {
                    guard !buffer.isEmpty else { return }
                    commit.yield(CommittedAudio(pcm: buffer, startMs: bufferStartMs, endMs: bufferEndMs))
                    buffer = Data()
                    voicedBytes = 0
                    silentTrailBytes = 0
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
                        flush()
                    } else if voicedBytes >= minVoicedBytes && silentTrailBytes >= silenceHoldBytes {
                        flush()
                    }
                }

                // End of stream: flush whatever is pending.
                if !buffer.isEmpty && voicedBytes > bytesPerSec / 2 {
                    flush()
                }
                commit.finish()
            }

            continuation.onTermination = { _ in
                reader.cancel()
                uploader.cancel()
            }
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

    func transcribeFile(url: URL,
                        language: String?) -> AsyncThrowingStream<FileTranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let pcm = try await AudioConverter.convertToPCM16Mono16k(inputURL: url)
                    let bytesPerSecond = 16000 * 2
                    let sliceSec = 30
                    let sliceBytes = bytesPerSecond * sliceSec
                    let total = max(1, (pcm.count + sliceBytes - 1) / sliceBytes)
                    continuation.yield(.progress(completed: 0, total: total))

                    var offset = 0
                    var baseMs: Int64 = 0
                    var completed = 0
                    var promptCarry: String = ""
                    while offset < pcm.count {
                        try Task.checkCancellation()
                        let end = min(offset + sliceBytes, pcm.count)
                        let slice = pcm[offset..<end]
                        let wav = WavEncoder.encode(pcm16: Data(slice), sampleRate: 16000, channels: 1)
                        let segments = try await Self.postTranscriptionVerbose(
                            wav: wav,
                            config: config,
                            language: language,
                            prompt: promptCarry.isEmpty ? nil : promptCarry,
                            fallbackDurationSec: Double(end - offset) / Double(bytesPerSecond),
                            retryDelays: retryDelays)
                        for seg in segments {
                            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard Self.shouldEmit(text, minChars: minEmitChars) else { continue }
                            let event = TranscriptEvent(
                                startMs: baseMs + Int64(seg.start * 1000),
                                endMs: baseMs + Int64(seg.end * 1000),
                                text: text,
                                isFinal: true)
                            continuation.yield(.segment(event))
                            promptCarry = String((promptCarry + " " + text).suffix(240))
                                .trimmingCharacters(in: .whitespaces)
                        }
                        let ms = Int64(Double(end - offset) / Double(bytesPerSecond) * 1000)
                        baseMs += ms
                        offset = end
                        completed += 1
                        continuation.yield(.progress(completed: completed, total: total))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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

    /// - Parameter fallbackDurationSec: how long the audio in `wav` is. Used
    ///   only for the synthetic segment the fallbacks below produce: a provider
    ///   that ignores `verbose_json` gives no timings at all, and reporting
    ///   0...0 collapses every imported segment onto its slice boundary.
    /// - Parameter retryDelays: waits before each retry of an upload that
    ///   failed for a reason that may pass; empty means no retries.
    static func postTranscriptionVerbose(wav: Data, config: ApiConfig, language: String?, prompt: String? = nil,
                                         fallbackDurationSec: Double = 0,
                                         retryDelays: [TimeInterval] = []) async throws -> [VerboseSegment] {
        let verbose = acceptsVerboseJSON(config)
        var (resp, data) = try await postMultipartRetrying(wav: wav, config: config, language: language,
                                                           verbose: verbose, prompt: prompt,
                                                           retryDelays: retryDelays)
        // gpt-4o-transcribe and its mini take only `json` and `text`, and
        // answer `verbose_json` with a 400 that names the field. Ask again
        // without it, and leave it out for this model from now on; the plain
        // reply comes back as one segment spanning the audio.
        if verbose, [400, 422].contains(resp.statusCode),
           OpenAIRejectedParameters.blames(data, "response_format")
            || OpenAIRejectedParameters.blames(data, "verbose_json") {
            OpenAIRejectedParameters.shared.insert("response_format", baseUrl: config.baseUrl,
                                                   model: config.sttModel)
            (resp, data) = try await postMultipartRetrying(wav: wav, config: config, language: language,
                                                           verbose: false, prompt: prompt,
                                                           retryDelays: retryDelays)
        }
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
                return [VerboseSegment(id: 0, start: 0, end: fallbackDurationSec, text: text)]
            }
        }
        // Fallback: provider may have ignored verbose_json and returned the
        // plain `{"text": ...}` shape.
        if let simple = try? JSONDecoder().decode(SimpleResponse.self, from: data),
           !simple.text.isEmpty {
            return [VerboseSegment(id: 0, start: 0, end: fallbackDurationSec, text: simple.text)]
        }
        // Last resort: treat the response body as raw text.
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return [] }
        return [VerboseSegment(id: 0, start: 0, end: fallbackDurationSec, text: raw)]
    }

    /// Whether to ask for `verbose_json`. The gpt-4o transcribe models are
    /// known not to take it, which saves their first request a 400; any
    /// other model that refuses it is learned from that 400.
    static func acceptsVerboseJSON(_ config: ApiConfig) -> Bool {
        let id = config.sttModel.split(separator: "/").last.map { $0.lowercased() } ?? ""
        if id.hasPrefix("gpt-4o-transcribe") || id.hasPrefix("gpt-4o-mini-transcribe") { return false }
        return !OpenAIRejectedParameters.shared.contains("response_format", baseUrl: config.baseUrl,
                                                         model: config.sttModel)
    }

    /// One upload, retried after a short wait when it failed for a reason that
    /// may pass. Anything else (a bad key, a wrong model, a missing endpoint)
    /// comes back at once, as does the last failure once the retries run out.
    static func postMultipartRetrying(wav: Data, config: ApiConfig, language: String?, verbose: Bool,
                                      prompt: String?,
                                      retryDelays: [TimeInterval]) async throws -> (HTTPURLResponse, Data) {
        var attempt = 0
        while true {
            let wait: TimeInterval
            do {
                let (resp, data) = try await postMultipart(wav: wav, config: config, language: language,
                                                           verbose: verbose, prompt: prompt)
                guard attempt < retryDelays.count, isTransient(status: resp.statusCode) else {
                    return (resp, data)
                }
                wait = retryAfter(resp) ?? retryDelays[attempt]
                NSLog("[OpenAICompatibleSTT] HTTP \(resp.statusCode), retrying in \(wait)s")
            } catch let error as URLError where attempt < retryDelays.count && isTransient(error) {
                wait = retryDelays[attempt]
                NSLog("[OpenAICompatibleSTT] \(error.code.rawValue), retrying in \(wait)s")
            }
            attempt += 1
            try await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
        }
    }

    /// Rate limiting and server-side trouble. 501 and 505 are answers about
    /// the request, not the moment, and do not change on a retry.
    static func isTransient(status: Int) -> Bool {
        if status == 408 || status == 429 { return true }
        return (500...599).contains(status) && status != 501 && status != 505
    }

    /// A timeout or a network that went away, as on a Wi-Fi handoff between
    /// lecture halls. Not cancellation, and not a malformed URL.
    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// The server's own `Retry-After`, in its seconds form, capped so one
    /// answer cannot hold a chunk for minutes.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds >= 0 else { return nil }
        return min(seconds, 30)
    }

    static func postMultipart(wav: Data, config: ApiConfig, language: String?, verbose: Bool, prompt: String? = nil) async throws -> (HTTPURLResponse, Data) {
        let comps = URLComponents(string: config.baseUrl.hasSuffix("/") ? config.baseUrl + "audio/transcriptions" : config.baseUrl + "/audio/transcriptions")
        guard let url = comps?.url else { throw EngineError.networkError("Invalid base URL") }

        let boundary = "----ClassNote-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        // Local servers issue no token and reject one they never issued, so an
        // empty key is a valid configuration -- refusing here meant the user
        // could never find out whether their Ollama endpoint worked.
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
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
