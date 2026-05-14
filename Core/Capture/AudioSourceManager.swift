import Foundation
@preconcurrency import AVFoundation
import CoreMedia
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
/// Writes raw audio to an .m4a file in parallel with emitting STT chunks.
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
    private var scStream: SCStream?
    private var scStreamOutputHandler: SCStreamOutputHandler?
    private var scStreamDelegate: SCStreamDelegateAdapter?
    private var micConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat!
    private var running = false

    // Writer is shared between the SCK audio queue and the mic callback queue.
    // Access only via `writer.queue.sync` / async.
    private var writer: FileWriter?

    override init() {
        var cont: AsyncStream<AudioChunk>.Continuation!
        self.chunks = AsyncStream(bufferingPolicy: .unbounded) { c in cont = c }
        self.chunkContinuation = cont
        super.init()
    }

    func start(source: AudioSourceKind, outputURL: URL?) async throws {
        guard !running else { return }
        running = true
        state.source = source
        state.startedAt = Date()
        state.audioFileURL = outputURL

        if let outputURL, FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: 16000,
                                      channels: 1,
                                      interleaved: true)

        writer = outputURL.map { FileWriter(url: $0) }

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
            do { try await scStream.stopCapture() } catch { NSLog("[ClassNote] SCStream stop err: \(error)") }
        }
        scStream = nil
        scStreamOutputHandler = nil
        scStreamDelegate = nil

        await writer?.finish()
        writer = nil

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
        micConverter = AVAudioConverter(from: inputFormat, to: targetFormat)

        let isOnlyMicSource = (state.source == .microphone)
        let startedAt = state.startedAt
        let targetSampleRate = Int(targetFormat.sampleRate)
        let writer = self.writer
        let cont = self.chunkContinuation
        let converter = self.micConverter
        let target = self.targetFormat!

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            // In mic-only mode, mic drives the recording file. In mixed mode,
            // system audio is the file source so we skip writing here.
            if isOnlyMicSource {
                writer?.appendPCMBuffer(buffer)
            }

            // Convert to 16k mono Int16 and emit chunk.
            guard let converter = converter else { return }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return }
            var error: NSError?
            var provided = false
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if provided { outStatus.pointee = .noDataNow; return nil }
                outStatus.pointee = .haveData
                provided = true
                return buffer
            }
            if status == .error { return }

            guard let data = Self.pcmData(from: outBuffer) else { return }
            let samples = data.count / 2
            let sessionMs: Int64
            if let start = startedAt {
                sessionMs = Int64(Date().timeIntervalSince(start) * 1000) - Int64(Double(samples) / Double(targetSampleRate) * 1000)
            } else {
                sessionMs = 0
            }
            cont.yield(AudioChunk(pcmData: data, sampleRate: targetSampleRate, timestamp: max(0, sessionMs)))
        }
        try engine.start()
    }

    nonisolated private static func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let ch = buffer.int16ChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        let bytes = frameLength * channelCount * 2
        return Data(bytes: ch[0], count: bytes)
    }

    // MARK: - System audio (ScreenCaptureKit)

    private var systemAudioSampleCount: Int = 0

    private func startSystemAudio() async throws {
        // Preflight: SCShareableContent silently returns zero displays without
        // Screen Recording permission. Prompt first if needed.
        if !CGPreflightScreenCaptureAccess() {
            NSLog("[ClassNote] SCK preflight: no permission yet; prompting.")
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
        // SCK requires a video config even for audio-only; keep minimal.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 6

        let targetSampleRate = Int(targetFormat.sampleRate)
        let startedAt = state.startedAt
        let isOnlySystemSource = (state.source == .system)
        let writer = self.writer
        let cont = self.chunkContinuation
        let target = self.targetFormat!
        let sampleCounter = SampleCounter()

        let handler = SCStreamOutputHandler { sampleBuffer in
            sampleCounter.increment()

            // Path A: write the raw CMSampleBuffer to the .m4a file. This is the
            // OBS-style path — no PCM conversion, AVAssetWriter handles it.
            if isOnlySystemSource {
                writer?.appendSampleBuffer(sampleBuffer)
            }

            // Path B: also produce 16k mono Int16 PCM for the STT pipeline.
            Self.emitSTTChunk(from: sampleBuffer,
                              target: target,
                              startedAt: startedAt,
                              targetSampleRate: targetSampleRate,
                              continuation: cont)
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

        systemAudioSampleCount = 0
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                guard let self = self, self.running else { return }
                if sampleCounter.value == 0 {
                    NSLog("[ClassNote] SCK: no audio samples after 5s — source likely silent or permission not effective")
                    AppState.shared.setError("5 秒内没收到系统音频 — 请检查系统是否有声音在播放,或重新授权屏幕录制权限。/ No system audio received in 5s — check if any audio is playing, or re-grant Screen Recording permission.")
                }
            }
        }
    }

    /// Converts an SCK audio CMSampleBuffer to 16k mono Int16 and yields it as
    /// an `AudioChunk` for the STT pipeline. Runs on the SCK audio queue.
    nonisolated private static func emitSTTChunk(from sampleBuffer: CMSampleBuffer,
                                     target: AVAudioFormat,
                                     startedAt: Date?,
                                     targetSampleRate: Int,
                                     continuation: AsyncStream<AudioChunk>.Continuation) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else { return }
        let asbd = asbdPtr.pointee
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return }

        var asbdCopy = asbd
        guard let inputFormat = AVAudioFormat(streamDescription: &asbdCopy) else { return }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                              frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
        inBuffer.frameLength = AVAudioFrameCount(sampleCount)
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer,
                                                     at: 0,
                                                     frameCount: Int32(sampleCount),
                                                     into: inBuffer.mutableAudioBufferList)

        guard let converter = AVAudioConverter(from: inputFormat, to: target) else { return }
        let ratio = target.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(sampleCount) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return }

        var err: NSError?
        var provided = false
        _ = converter.convert(to: outBuffer, error: &err) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return inBuffer
        }

        guard let data = pcmData(from: outBuffer) else { return }
        let samples = data.count / 2
        let sessionMs: Int64
        if let start = startedAt {
            sessionMs = Int64(Date().timeIntervalSince(start) * 1000) - Int64(Double(samples) / Double(targetSampleRate) * 1000)
        } else {
            sessionMs = 0
        }
        continuation.yield(AudioChunk(pcmData: data, sampleRate: targetSampleRate, timestamp: max(0, sessionMs)))
    }

    // MARK: - File import

    func ingestFile(url: URL, realtime: Bool = false) async throws {
        running = true
        state.source = .file
        state.startedAt = Date()
        state.audioFileURL = url

        let pcm = try await AudioConverter.convertToPCM16Mono16k(inputURL: url)
        let sampleRate = 16000
        let chunkSamples = sampleRate
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
}

// MARK: - File writer

/// Thread-safe AVAssetWriter wrapper. SCK delivers CMSampleBuffers we can
/// append directly; mic produces AVAudioPCMBuffers we wrap into CMSampleBuffers.
/// The writer's start time is anchored to the first sample we receive so the
/// .m4a timeline starts at 0.
final class FileWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private var startPTS: CMTime = .invalid
    private var sourceFormatHint: CMAudioFormatDescription?
    private var micSampleCount: Int64 = 0
    private var failed = false

    init(url: URL) {
        self.url = url
    }

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { return }

        if writer == nil {
            guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            sourceFormatHint = desc
            if !openWriter(with: desc) { return }
        }
        guard let input = input, input.isReadyForMoreMediaData else { return }
        if !started {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer?.startSession(atSourceTime: pts)
            startPTS = pts
            started = true
        }
        if !input.append(sampleBuffer) {
            NSLog("[ClassNote] FileWriter: append(sampleBuffer) failed: %@", writer?.error?.localizedDescription ?? "?")
            failed = true
        }
    }

    func appendPCMBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { return }

        if writer == nil {
            guard let desc = makeFormatDescription(from: buffer.format) else { return }
            sourceFormatHint = desc
            if !openWriter(with: desc) { return }
        }
        guard let input = input, input.isReadyForMoreMediaData else { return }

        let frames = Int64(buffer.frameLength)
        let rate = buffer.format.sampleRate
        let pts = CMTime(value: micSampleCount, timescale: CMTimeScale(rate))
        micSampleCount += frames

        guard let sb = makeSampleBuffer(from: buffer, pts: pts) else { return }
        if !started {
            writer?.startSession(atSourceTime: pts)
            startPTS = pts
            started = true
        }
        if !input.append(sb) {
            NSLog("[ClassNote] FileWriter: append(mic sb) failed: %@", writer?.error?.localizedDescription ?? "?")
            failed = true
        }
    }

    func finish() async {
        let (w, i): (AVAssetWriter?, AVAssetWriterInput?) = {
            lock.lock()
            defer { lock.unlock() }
            let pair = (writer, input)
            writer = nil
            input = nil
            return pair
        }()
        guard let writer = w else { return }
        i?.markAsFinished()
        if writer.status == .writing {
            await writer.finishWriting()
        }
    }

    private func openWriter(with sourceFormat: CMAudioFormatDescription) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormat)?.pointee
            let sampleRate = asbd?.mSampleRate ?? 48000
            let channels = Int(asbd?.mChannelsPerFrame ?? 2)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128_000
            ]
            let inp = AVAssetWriterInput(mediaType: .audio,
                                         outputSettings: settings,
                                         sourceFormatHint: sourceFormat)
            inp.expectsMediaDataInRealTime = true
            guard w.canAdd(inp) else {
                NSLog("[ClassNote] FileWriter: cannot add audio input")
                failed = true
                return false
            }
            w.add(inp)
            guard w.startWriting() else {
                NSLog("[ClassNote] FileWriter: startWriting failed: %@", w.error?.localizedDescription ?? "?")
                failed = true
                return false
            }
            self.writer = w
            self.input = inp
            return true
        } catch {
            NSLog("[ClassNote] FileWriter: open failed: %@", error.localizedDescription)
            failed = true
            return false
        }
    }

    private func makeFormatDescription(from format: AVAudioFormat) -> CMAudioFormatDescription? {
        var asbd = format.streamDescription.pointee
        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    asbd: &asbd,
                                                    layoutSize: 0,
                                                    layout: nil,
                                                    magicCookieSize: 0,
                                                    magicCookie: nil,
                                                    extensions: nil,
                                                    formatDescriptionOut: &desc)
        return status == noErr ? desc : nil
    }

    private func makeSampleBuffer(from buffer: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        guard let formatDesc = makeFormatDescription(from: buffer.format) else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(buffer.frameLength),
                             timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                                dataBuffer: nil,
                                                dataReady: false,
                                                makeDataReadyCallback: nil,
                                                refcon: nil,
                                                formatDescription: formatDesc,
                                                sampleCount: CMItemCount(buffer.frameLength),
                                                sampleTimingEntryCount: 1,
                                                sampleTimingArray: &timing,
                                                sampleSizeEntryCount: 0,
                                                sampleSizeArray: nil,
                                                sampleBufferOut: &sb)
        guard createStatus == noErr, let sb = sb else { return nil }
        let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sb,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )
        return setStatus == noErr ? sb : nil
    }
}

// MARK: - Sample counter (thread-safe for watchdog)

final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); _value += 1; lock.unlock()
    }
}

// MARK: - SCK adapters

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
