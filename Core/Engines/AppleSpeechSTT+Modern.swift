import Foundation
import AVFoundation
import Speech
import CoreMedia

/// SpeechAnalyzer/SpeechTranscriber path (macOS 26+). Faster and more
/// accurate than SFSpeechRecognizer, fully on-device.
@available(macOS 26.0, *)
extension AppleSpeechSTT {
    static func transcribeModern(audio: AsyncStream<AudioChunk>,
                                 language: String?) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let locale = try await resolvedLocale(for: language)
                    let transcriber = SpeechTranscriber(locale: locale,
                                                        transcriptionOptions: [],
                                                        reportingOptions: [],
                                                        attributeOptions: [])
                    try await ensureAssetsInstalled(for: transcriber)

                    let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                    let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
                    let analyzer = SpeechAnalyzer(inputSequence: inputStream, modules: [transcriber])

                    let resultsTask = Task {
                        for try await result in transcriber.results {
                            guard result.isFinal else { continue }
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard OpenAICompatibleSTT.shouldEmit(text, minChars: 3) else { continue }
                            let startMs = Int64(result.range.start.seconds * 1000)
                            let endMs = Int64((result.range.start + result.range.duration).seconds * 1000)
                            continuation.yield(TranscriptEvent(startMs: startMs, endMs: endMs, text: text, isFinal: true))
                        }
                    }

                    let converter = PCMBufferConverter(targetFormat: format)
                    for await chunk in audio {
                        try Task.checkCancellation()
                        guard let buffer = converter.convert(chunk: chunk) else { continue }
                        inputContinuation.yield(AnalyzerInput(buffer: buffer))
                    }
                    inputContinuation.finish()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    _ = try await resultsTask.value
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func transcribeFileModern(url: URL,
                                     language: String?) -> AsyncThrowingStream<FileTranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let locale = try await resolvedLocale(for: language)
                    let transcriber = SpeechTranscriber(locale: locale,
                                                        transcriptionOptions: [],
                                                        reportingOptions: [],
                                                        attributeOptions: [])
                    try await ensureAssetsInstalled(for: transcriber)

                    let pcm = try await AudioConverter.convertToPCM16Mono16k(inputURL: url)
                    let bytesPerSecond = 16000 * 2
                    continuation.yield(.progress(completed: 0, total: 1))

                    let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                    let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
                    let analyzer = SpeechAnalyzer(inputSequence: inputStream, modules: [transcriber])

                    let resultsTask = Task {
                        for try await result in transcriber.results {
                            guard result.isFinal else { continue }
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard OpenAICompatibleSTT.shouldEmit(text, minChars: 3) else { continue }
                            let startMs = Int64(result.range.start.seconds * 1000)
                            let endMs = Int64((result.range.start + result.range.duration).seconds * 1000)
                            continuation.yield(.segment(TranscriptEvent(startMs: startMs, endMs: endMs, text: text, isFinal: true)))
                        }
                    }

                    let converter = PCMBufferConverter(targetFormat: format)
                    let sliceBytes = bytesPerSecond * 5
                    var offset = 0
                    var elapsedMs: Int64 = 0
                    while offset < pcm.count {
                        try Task.checkCancellation()
                        let end = min(offset + sliceBytes, pcm.count)
                        let slice = Data(pcm[offset..<end])
                        let chunk = AudioChunk(pcmData: slice, sampleRate: 16000, timestamp: elapsedMs)
                        if let buffer = converter.convert(chunk: chunk) {
                            inputContinuation.yield(AnalyzerInput(buffer: buffer))
                        }
                        elapsedMs += Int64(Double(end - offset) / Double(bytesPerSecond) * 1000)
                        offset = end
                    }
                    inputContinuation.finish()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    _ = try await resultsTask.value
                    continuation.yield(.progress(completed: 1, total: 1))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func resolvedLocale(for languageCode: String?) async throws -> Locale {
        let requested = localeFor(languageCode)
        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            return equivalent
        }
        throw EngineError.unsupported("SpeechAnalyzer 不支持语言 \(requested.identifier),请在系统设置 > 键盘 > 听写 中检查支持的语言。")
    }

    static func ensureAssetsInstalled(for transcriber: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .installed else { return }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            if status == .unsupported {
                throw EngineError.unsupported("当前语言的本地语音识别模型不受支持。")
            }
            return
        }
        try await request.downloadAndInstall()
    }
}

/// Converts Int16 mono PCM `AudioChunk`s into whatever `AVAudioFormat`
/// `SpeechAnalyzer` reports as its best-available input format.
final class PCMBufferConverter {
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat?
    private let converter: AVAudioConverter?

    init(targetFormat: AVAudioFormat?) {
        self.sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16000,
                                          channels: 1,
                                          interleaved: true) ?? AVAudioFormat()
        self.targetFormat = targetFormat
        if let targetFormat, targetFormat != self.sourceFormat {
            self.converter = AVAudioConverter(from: self.sourceFormat, to: targetFormat)
        } else {
            self.converter = nil
        }
    }

    func convert(chunk: AudioChunk) -> AVAudioPCMBuffer? {
        guard let sourceBuffer = makeInt16Buffer(from: chunk.pcmData) else { return nil }
        guard let converter, let targetFormat else { return sourceBuffer }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrameCapacity) else { return nil }

        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        guard error == nil else { return nil }
        return outBuffer
    }

    private func makeInt16Buffer(from data: Data) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let channelData = buffer.int16ChannelData else { return nil }
        data.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return }
            channelData[0].update(from: src, count: Int(frameCount))
        }
        return buffer
    }
}
