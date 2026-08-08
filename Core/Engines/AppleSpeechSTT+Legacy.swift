import Foundation
import AVFoundation
import Speech

/// SFSpeechRecognizer path for macOS 14-25. Forces on-device recognition
/// whenever the recognizer supports it so audio never leaves the machine;
/// silently falls back to server-assisted recognition on locales/OS versions
/// that don't support on-device mode (matches Apple's own dictation behavior).
extension AppleSpeechSTT {
    /// `SFSpeechAudioBufferRecognitionRequest` only reports `isFinal == true`
    /// once, when `endAudio()` finishes processing — using a single request
    /// for the whole session would delay every subtitle until the user stops
    /// recording. So we restart the request on silence boundaries, mirroring
    /// the commit strategy `OpenAICompatibleSTT` uses for cloud chunking.
    static func transcribeLegacy(audio: AsyncStream<AudioChunk>,
                                 language: String?) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await requestAuthorizationIfNeeded()
                    guard let recognizer = SFSpeechRecognizer(locale: localeFor(language)),
                          recognizer.isAvailable else {
                        throw EngineError.unsupported("系统语音识别当前不可用,请检查系统设置 > 隐私与安全性 > 语音识别。")
                    }
                    let onDevice = recognizer.supportsOnDeviceRecognition
                    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
                        ?? AVAudioFormat()

                    let chunker = SilenceChunker()
                    var activeRequest: SFSpeechAudioBufferRecognitionRequest?
                    var activeSink: LegacyRecognitionSink?
                    var activeTask: SFSpeechRecognitionTask?

                    func openRequest(baseMs: Int64) {
                        let request = SFSpeechAudioBufferRecognitionRequest()
                        request.shouldReportPartialResults = true
                        if onDevice { request.requiresOnDeviceRecognition = true }
                        let sink = LegacyRecognitionSink(continuation: continuation, baseMs: baseMs)
                        let rtask = recognizer.recognitionTask(with: request) { result, error in
                            sink.handle(result: result, error: error)
                        }
                        activeRequest = request
                        activeSink = sink
                        activeTask = rtask
                    }

                    func closeRequest() async {
                        guard let request = activeRequest, let sink = activeSink, let rtask = activeTask else { return }
                        request.endAudio()
                        await sink.waitUntilFinished()
                        rtask.cancel()
                        activeRequest = nil
                        activeSink = nil
                        activeTask = nil
                    }

                    for await chunk in audio {
                        try Task.checkCancellation()
                        if activeRequest == nil { openRequest(baseMs: chunk.timestamp) }
                        guard let buffer = Self.makeBuffer(from: chunk.pcmData, format: format) else { continue }
                        activeRequest?.append(buffer)

                        if chunker.shouldCommit(chunk: chunk) {
                            await closeRequest()
                        }
                    }
                    await closeRequest()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func transcribeFileLegacy(url: URL,
                                     language: String?) -> AsyncThrowingStream<FileTranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await requestAuthorizationIfNeeded()
                    guard let recognizer = SFSpeechRecognizer(locale: localeFor(language)),
                          recognizer.isAvailable else {
                        throw EngineError.unsupported("系统语音识别当前不可用,请检查系统设置 > 隐私与安全性 > 语音识别。")
                    }

                    continuation.yield(.progress(completed: 0, total: 1))
                    let request = SFSpeechURLRecognitionRequest(url: url)
                    request.shouldReportPartialResults = true
                    if recognizer.supportsOnDeviceRecognition {
                        request.requiresOnDeviceRecognition = true
                    }

                    let sink = LegacyFileRecognitionSink(continuation: continuation)
                    let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                        sink.handle(result: result, error: error)
                    }

                    await sink.waitUntilFinished()
                    recognitionTask.cancel()
                    continuation.yield(.progress(completed: 1, total: 1))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func requestAuthorizationIfNeeded() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return }
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { newStatus in
                cont.resume(returning: newStatus == .authorized)
            }
        }
        guard granted else {
            throw EngineError.unsupported("语音识别权限被拒绝,请在系统设置 > 隐私与安全性 > 语音识别 中允许 ClassNote。")
        }
    }

    private static func makeBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let channelData = buffer.int16ChannelData else { return nil }
        data.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return }
            channelData[0].update(from: src, count: Int(frameCount))
        }
        return buffer
    }
}

/// Tracks voiced/silent run lengths to decide when to cut over to a fresh
/// `SFSpeechAudioBufferRecognitionRequest`, using the same thresholds as the
/// cloud engine's chunking so live-subtitle cadence feels consistent
/// regardless of which STT backend is selected.
private final class SilenceChunker {
    private let minVoicedSec: Double = 3.0
    private let silenceHoldSec: Double = 0.5
    private let maxChunkSec: Double = 12.0
    private let rmsThreshold: Double = 0.01

    private var voicedSec: Double = 0
    private var silentTrailSec: Double = 0
    private var totalSec: Double = 0

    func shouldCommit(chunk: AudioChunk) -> Bool {
        let sampleCount = chunk.pcmData.count / 2
        guard sampleCount > 0 else { return false }
        let durationSec = Double(sampleCount) / Double(chunk.sampleRate)
        totalSec += durationSec

        let rms = VADGate.rms(pcm16: chunk.pcmData)
        if rms >= rmsThreshold {
            voicedSec += durationSec
            silentTrailSec = 0
        } else {
            silentTrailSec += durationSec
        }

        let shouldCommit = totalSec >= maxChunkSec || (voicedSec >= minVoicedSec && silentTrailSec >= silenceHoldSec)
        if shouldCommit {
            voicedSec = 0
            silentTrailSec = 0
            totalSec = 0
        }
        return shouldCommit
    }
}

/// SFSpeechRecognizer's completion handler fires repeatedly (partial results,
/// then a final result, then again with `isFinal` for the same utterance) —
/// this tracks the last emitted text per result generation so we only yield
/// once a segment is truly final, then unblocks the feeding loop.
private final class LegacyRecognitionSink: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    private let baseMs: Int64
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var emittedSegmentCount = 0

    init(continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation, baseMs: Int64) {
        self.continuation = continuation
        self.baseMs = baseMs
    }

    func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        if let error {
            continuation.finish(throwing: error)
            markFinished()
            return
        }
        guard let result else { return }

        let segments = result.bestTranscription.segments
        if result.isFinal {
            for seg in segments.dropFirst(emittedSegmentCount) {
                emit(seg)
            }
            emittedSegmentCount = segments.count
            markFinished()
        } else {
            emitDraft(result.bestTranscription.formattedString)
        }
    }

    private func emit(_ segment: SFTranscriptionSegment) {
        let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OpenAICompatibleSTT.shouldEmit(text, minChars: 3) else { return }
        let startMs = baseMs + Int64(segment.timestamp * 1000)
        let endMs = baseMs + Int64((segment.timestamp + segment.duration) * 1000)
        continuation.yield(TranscriptEvent(startMs: startMs, endMs: endMs, text: text, isFinal: true))
    }

    private func emitDraft(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        continuation.yield(TranscriptEvent(startMs: baseMs, endMs: baseMs, text: trimmed, isFinal: false))
    }

    private func markFinished() {
        finished = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    /// `NSLock.lock()/unlock()` are unavailable from async contexts under
    /// Swift 6 mode, so each lock/unlock pair here is fully synchronous —
    /// only the continuation's suspension itself crosses an await.
    func waitUntilFinished() async {
        let alreadyFinished: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }()
        guard !alreadyFinished else { return }

        await withCheckedContinuation { cont in
            lock.lock()
            defer { lock.unlock() }
            if finished {
                cont.resume()
            } else {
                waiters.append(cont)
            }
        }
    }
}

private final class LegacyFileRecognitionSink: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<FileTranscriptionEvent, Error>.Continuation
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var emittedSegmentCount = 0

    init(continuation: AsyncThrowingStream<FileTranscriptionEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        if let error {
            continuation.finish(throwing: error)
            markFinished()
            return
        }
        guard let result else { return }

        let segments = result.bestTranscription.segments
        if result.isFinal {
            for seg in segments.dropFirst(emittedSegmentCount) {
                emit(seg)
            }
            emittedSegmentCount = segments.count
            markFinished()
        }
    }

    private func emit(_ segment: SFTranscriptionSegment) {
        let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OpenAICompatibleSTT.shouldEmit(text, minChars: 3) else { return }
        let startMs = Int64(segment.timestamp * 1000)
        let endMs = Int64((segment.timestamp + segment.duration) * 1000)
        continuation.yield(.segment(TranscriptEvent(startMs: startMs, endMs: endMs, text: text, isFinal: true)))
    }

    private func markFinished() {
        finished = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    /// `NSLock.lock()/unlock()` are unavailable from async contexts under
    /// Swift 6 mode, so each lock/unlock pair here is fully synchronous —
    /// only the continuation's suspension itself crosses an await.
    func waitUntilFinished() async {
        let alreadyFinished: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }()
        guard !alreadyFinished else { return }

        await withCheckedContinuation { cont in
            lock.lock()
            defer { lock.unlock() }
            if finished {
                cont.resume()
            } else {
                waiters.append(cont)
            }
        }
    }
}
