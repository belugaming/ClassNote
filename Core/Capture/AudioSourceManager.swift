import Foundation
import AVFoundation
@preconcurrency import ScreenCaptureKit

enum AudioSourceKind: String, CaseIterable, Sendable, Identifiable {
    case microphone
    case system
    case mixed
    case file

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .microphone: return "Microphone (Live classroom)"
        case .system: return "System audio (Zoom / Teams / Meet)"
        case .mixed: return "Microphone + System audio"
        case .file: return "Imported file"
        }
    }
}

/// Unified audio source manager.
/// - Mic: AVAudioEngine input tap
/// - System: ScreenCaptureKit audio-only stream
/// - Mixed: both, mixed into a single bus
/// Always writes raw audio to an .m4a file in parallel with emitting chunks.
@MainActor
final class AudioSourceManager: NSObject {
    struct State {
        var startedAt: Date?
        var audioFileURL: URL?
        var source: AudioSourceKind = .microphone
    }

    private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    let chunks: AsyncStream<AudioChunk>
    private(set) var state = State()

    private var engine: AVAudioEngine?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var scStream: SCStream?
    private var scStreamOutputHandler: SCStreamOutputHandler?
    private var scStreamDelegate: SCStreamDelegateAdapter?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat!
    private var startHostTime: AVAudioTime?
    private var writerStarted = false
    private var running = false
    private var totalSamplesEmitted: Int64 = 0

    override init() {
        var cont: AsyncStream<AudioChunk>.Continuation!
        self.chunks = AsyncStream(bufferingPolicy: .unbounded) { c in cont = c }
        self.chunkContinuation = cont
        super.init()
    }

    /// Kicks off capture. For .file, call `ingestFile(url:)` instead.
    func start(source: AudioSourceKind, outputURL: URL) async throws {
        guard !running else { return }
        running = true
        state.source = source
        state.startedAt = Date()
        state.audioFileURL = outputURL

        // Prepare AAC writer for raw recording (44.1k stereo)
        try setupAssetWriter(url: outputURL)

        // 16k mono Int16 for STT
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: 16000,
                                      channels: 1,
                                      interleaved: true)

        switch source {
        case .microphone:
            try startMic()
        case .system:
            try await startSystemAudio()
        case .mixed:
            try startMic()
            try await startSystemAudio()
        case .file:
            throw EngineError.unsupported("Use ingestFile() for .file source")
        }
    }

    func stop() async {
        guard running else { return }
        running = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        if let scStream = scStream {
            do { try await scStream.stopCapture() } catch { NSLog("SCStream stop err: \(error)") }
        }
        scStream = nil
        scStreamOutputHandler = nil
        scStreamDelegate = nil

        if let input = assetWriterInput {
            input.markAsFinished()
        }
        if let writer = assetWriter, writer.status == .writing {
            await writer.finishWriting()
        }
        assetWriter = nil
        assetWriterInput = nil

        chunkContinuation.finish()
    }

    // MARK: - Mic

    private func startMic() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw EngineError.unsupported("Microphone not available (sample rate 0). Check privacy permissions.")
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, when in
            self?.handleMicBuffer(buffer, when: when)
        }
        try engine.start()
    }

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let converter = converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }
        var error: NSError?
        var provided = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            provided = true
            return buffer
        }
        if status == .error { return }

        // Write to asset writer (use mic buffer directly for recording)
        writeMicSampleToFile(buffer, when: when)

        // Emit chunk for STT
        if let data = pcmData(from: outBuffer) {
            let sampleRate = Int(targetFormat.sampleRate)
            let samples = data.count / 2
            let sessionMs: Int64
            if let start = state.startedAt {
                sessionMs = Int64(Date().timeIntervalSince(start) * 1000) - Int64(Double(samples) / Double(sampleRate) * 1000)
            } else {
                sessionMs = 0
            }
            let chunk = AudioChunk(pcmData: data, sampleRate: sampleRate, timestamp: max(0, sessionMs))
            chunkContinuation.yield(chunk)
        }
    }

    private func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let ch = buffer.int16ChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        let bytes = frameLength * channelCount * 2
        return Data(bytes: ch[0], count: bytes)
    }

    // MARK: - System audio (ScreenCaptureKit)

    private var systemAudioSampleCount: Int = 0

    private func startSystemAudio() async throws {
        // Preflight: if the user has never granted Screen Recording permission,
        // SCShareableContent silently returns zero displays. Prompt first.
        if !CGPreflightScreenCaptureAccess() {
            NSLog("[ClassNote] SCK preflight says no permission yet; prompting.")
            _ = CGRequestScreenCaptureAccess()
            throw EngineError.unsupported("需要屏幕录制权限来捕获系统音频。请在系统设置 → 隐私与安全性 → 屏幕录制 里授权 ClassNote,然后重启 App。/ Screen Recording permission required. Grant in System Settings → Privacy & Security → Screen Recording, then relaunch.")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            NSLog("[ClassNote] SCShareableContent error: %@", error.localizedDescription)
            throw EngineError.unsupported("无法访问屏幕录制内容: \(error.localizedDescription) / Cannot access screen content: \(error.localizedDescription)")
        }

        guard let display = content.displays.first else {
            throw EngineError.unsupported("没有找到可用的显示器 / No displays available for ScreenCaptureKit")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 6

        let handler = SCStreamOutputHandler { [weak self] sampleBuffer in
            self?.handleSystemSample(sampleBuffer)
        }
        self.scStreamOutputHandler = handler

        let delegate = SCStreamDelegateAdapter { error in
            NSLog("[ClassNote] SCStream stopped with error: %@", error.localizedDescription)
            Task { @MainActor in
                AppState.shared.setError("系统音频捕获异常 / System audio capture error: \(error.localizedDescription)")
            }
        }
        self.scStreamDelegate = delegate

        let stream = SCStream(filter: filter, configuration: cfg, delegate: delegate)
        do {
            try stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: DispatchQueue(label: "classnote.sck.audio"))
            try await stream.startCapture()
            self.scStream = stream
            NSLog("[ClassNote] SCK startCapture OK")
        } catch {
            NSLog("[ClassNote] SCStream startCapture failed: %@", error.localizedDescription)
            throw EngineError.unsupported("启动系统音频捕获失败 / System audio capture failed to start: \(error.localizedDescription)")
        }

        // Watchdog: if we don't receive any samples within 5s, warn the user.
        systemAudioSampleCount = 0
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                guard let self = self, self.running else { return }
                if self.systemAudioSampleCount == 0 {
                    NSLog("[ClassNote] SCK: no audio samples after 5s — source likely silent or permission not effective")
                    AppState.shared.setError("5 秒内没收到系统音频 — 请检查系统是否有声音在播放,或重新授权屏幕录制权限。/ No system audio received in 5s — check if any audio is playing, or re-grant Screen Recording permission.")
                }
            }
        }
    }

    nonisolated private func handleSystemSample(_ sampleBuffer: CMSampleBuffer) {
        Task { @MainActor [weak self] in
            self?.processSystemSample(sampleBuffer)
        }
    }

    private func processSystemSample(_ sampleBuffer: CMSampleBuffer) {
        systemAudioSampleCount += 1
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
        else { return }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return }

        // SCK typically provides Float32 interleaved at 48k. Convert to Int16 16k mono.
        let inputFormat = AVAudioFormat(streamDescription: withUnsafePointer(to: asbd) { $0 })
        guard let inputFormat = inputFormat else { return }

        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let converter = converter else { return }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
        inBuffer.frameLength = AVAudioFrameCount(sampleCount)
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(sampleCount), into: inBuffer.mutableAudioBufferList)

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(sampleCount) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var err: NSError?
        var provided = false
        _ = converter.convert(to: outBuffer, error: &err) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return inBuffer
        }

        if state.source == .system {
            // We also want to persist system audio to the .m4a file
            appendSampleToWriter(sampleBuffer)
        }

        if let data = pcmData(from: outBuffer) {
            let sampleRate = Int(targetFormat.sampleRate)
            let samples = data.count / 2
            let sessionMs: Int64
            if let start = state.startedAt {
                sessionMs = Int64(Date().timeIntervalSince(start) * 1000) - Int64(Double(samples) / Double(sampleRate) * 1000)
            } else {
                sessionMs = 0
            }
            let chunk = AudioChunk(pcmData: data, sampleRate: sampleRate, timestamp: max(0, sessionMs))
            chunkContinuation.yield(chunk)
        }
    }

    // MARK: - File import

    /// Reads the file once, emits AudioChunks spaced to real-time intervals or as fast as possible.
    func ingestFile(url: URL, realtime: Bool = false) async throws {
        running = true
        state.source = .file
        state.startedAt = Date()
        state.audioFileURL = url

        let pcm = try await AudioConverter.convertToPCM16Mono16k(inputURL: url)
        let sampleRate = 16000
        let chunkSamples = sampleRate   // 1s chunks
        let chunkBytes = chunkSamples * 2
        var offset = 0
        var tsMs: Int64 = 0
        while offset < pcm.count {
            let end = min(offset + chunkBytes, pcm.count)
            let slice = Data(pcm[offset..<end])
            let chunk = AudioChunk(pcmData: slice, sampleRate: sampleRate, timestamp: tsMs)
            chunkContinuation.yield(chunk)
            let ms = Int64(Double(end - offset) / Double(chunkBytes) * 1000)
            tsMs += ms
            offset = end
            if realtime {
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            }
            if !running { break }
        }
        chunkContinuation.finish()
    }

    // MARK: - AVAssetWriter

    private func setupAssetWriter(url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) { writer.add(input) }
        guard writer.startWriting() else {
            throw EngineError.unsupported("AVAssetWriter could not start: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)
        self.assetWriter = writer
        self.assetWriterInput = input
        self.writerStarted = true
    }

    private func writeMicSampleToFile(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let input = assetWriterInput, input.isReadyForMoreMediaData else { return }
        guard let sample = buffer.toCMSampleBuffer(presentationTimeSeconds: totalSeconds(from: buffer)) else { return }
        input.append(sample)
    }

    private func appendSampleToWriter(_ sampleBuffer: CMSampleBuffer) {
        guard let input = assetWriterInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    private func totalSeconds(from buffer: AVAudioPCMBuffer) -> Double {
        let samples = Double(buffer.frameLength)
        let rate = buffer.format.sampleRate
        let dur = samples / rate
        let current = totalSamplesEmitted
        totalSamplesEmitted += Int64(samples)
        return Double(current) / rate + dur
    }
}

final class SCStreamOutputHandler: NSObject, SCStreamOutput {
    let handler: @Sendable (CMSampleBuffer) -> Void
    init(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        handler(sampleBuffer)
    }
}

final class SCStreamDelegateAdapter: NSObject, SCStreamDelegate {
    let onError: @Sendable (Error) -> Void
    init(onError: @escaping @Sendable (Error) -> Void) {
        self.onError = onError
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}

extension AVAudioPCMBuffer {
    /// Convert an Int16 PCM buffer to a CMSampleBuffer for AVAssetWriter.
    func toCMSampleBuffer(presentationTimeSeconds: Double) -> CMSampleBuffer? {
        guard let asbd = format.streamDescription.pointee as CoreAudioBaseTypes.AudioStreamBasicDescription? else { return nil }
        var asbdCopy = asbd
        var formatDesc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    asbd: &asbdCopy,
                                                    layoutSize: 0,
                                                    layout: nil,
                                                    magicCookieSize: 0,
                                                    magicCookie: nil,
                                                    extensions: nil,
                                                    formatDescriptionOut: &formatDesc)
        guard status == noErr, let fmt = formatDesc else { return nil }

        let pts = CMTime(seconds: presentationTimeSeconds, preferredTimescale: 44100)
        var timing = CMSampleTimingInfo(duration: CMTime(value: CMTimeValue(frameLength), timescale: CMTimeScale(format.sampleRate)),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                                 dataBuffer: nil,
                                                 dataReady: false,
                                                 makeDataReadyCallback: nil,
                                                 refcon: nil,
                                                 formatDescription: fmt,
                                                 sampleCount: CMItemCount(frameLength),
                                                 sampleTimingEntryCount: 1,
                                                 sampleTimingArray: &timing,
                                                 sampleSizeEntryCount: 0,
                                                 sampleSizeArray: nil,
                                                 sampleBufferOut: &sampleBuffer)
        guard createStatus == noErr, let sb = sampleBuffer else { return nil }

        let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(sb,
                                                                        blockBufferAllocator: kCFAllocatorDefault,
                                                                        blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                                        flags: 0,
                                                                        bufferList: audioBufferList)
        guard setStatus == noErr else { return nil }
        return sb
    }
}

// CoreAudio base types aren't imported by name in some SDKs; alias for clarity.
enum CoreAudioBaseTypes {
    typealias AudioStreamBasicDescription = CoreAudioTypes.AudioStreamBasicDescription
}
enum CoreAudioTypes {
    typealias AudioStreamBasicDescription = AudioToolbox.AudioStreamBasicDescription
}
