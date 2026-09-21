import Foundation
@preconcurrency import AVFoundation
import CoreMedia
#if os(macOS)
import CoreAudio
@preconcurrency import ScreenCaptureKit
#endif

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

    /// `.system`/`.mixed` need ScreenCaptureKit, which iOS doesn't have.
    /// UI source pickers should use this instead of `allCases`.
    static var availableCases: [AudioSourceKind] {
        #if os(macOS)
        return Self.allCases
        #else
        return [.microphone, .file]
        #endif
    }
}

struct MicrophoneInputDevice: Identifiable, Equatable, Hashable {
    static let systemDefaultID = "system-default"

    let id: String
    let name: String
    let uniqueID: String?

    static var systemDefault: MicrophoneInputDevice {
        MicrophoneInputDevice(id: systemDefaultID,
                              name: L10n.t("settings.audio.mic.systemDefault"),
                              uniqueID: nil)
    }
}

enum MicrophoneDeviceCatalog {
    static func availableInputDevices() -> [MicrophoneInputDevice] {
        let devices = audioDevices().map {
            MicrophoneInputDevice(id: $0.uniqueID,
                                  name: $0.localizedName,
                                  uniqueID: $0.uniqueID)
        }
        return [MicrophoneInputDevice.systemDefault] + devices.sorted { $0.name < $1.name }
    }

    static func name(for uniqueID: String?) -> String {
        guard let uniqueID else { return MicrophoneInputDevice.systemDefault.name }
        return availableInputDevices().first { $0.uniqueID == uniqueID }?.name ?? uniqueID
    }

    private static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio,
                                         position: .unspecified).devices
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

    /// Every live chunk stream handed out by `makeChunkStream()`. A registry
    /// rather than one stored continuation because the STT pipeline has to be
    /// able to restart — after an engine crash — without restarting capture,
    /// and a terminated `AsyncStream` can never be revived.
    private let subscribers = ChunkSubscribers()
    /// The single producer for both the file and the chunk streams. See
    /// `AudioMixBus`.
    private var mixBus: AudioMixBus?
    private(set) var state = State()

    private var engine: AVAudioEngine?
    #if os(macOS)
    private var scStream: SCStream?
    private var scStreamOutputHandler: SCStreamOutputHandler?
    private var scStreamDelegate: SCStreamDelegateAdapter?
    #endif
    private var micConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat!
    private var running = false

    // Only ever touched from the mix bus's own serial queue (and from `stop()`
    // once the bus has been finished), which is what makes its lock uncontended.
    private var writer: FileWriter?
    private let microphoneDeviceID: String?

    init(microphoneDeviceID: String? = nil) {
        self.microphoneDeviceID = microphoneDeviceID
        super.init()
    }

    /// A fresh chunk stream. Each caller gets its own; the mix bus feeds all of
    /// them. `bufferingNewest` rather than `.unbounded`: a consumer that dies
    /// (an STT engine crash) must drop audio, not grow by ~32 KB/s for the rest
    /// of the lecture. 400 frames ≈ 40 s at the bus's 100 ms cadence.
    func makeChunkStream() -> AsyncStream<AudioChunk> {
        let subs = subscribers
        return AsyncStream<AudioChunk>(bufferingPolicy: .bufferingNewest(400)) { cont in
            let token = subs.add(cont)
            cont.onTermination = { _ in subs.remove(token) }
        }
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

        // One bus, one timeline: the capture callbacks only submit into it, and
        // its tick is the only thing that ever reaches the file or the chunk
        // streams. Mixed mode used to write no file at all because each callback
        // wrote only when it believed it was the sole source.
        let fileWriter = self.writer
        let subs = self.subscribers
        let bus = AudioMixBus(sampleRate: Int(targetFormat.sampleRate)) { pcm16, ptsFrames, sampleRate in
            fileWriter?.append(pcm16: pcm16, sampleRate: sampleRate, ptsFrames: ptsFrames)
            subs.yield(AudioChunk(pcmData: pcm16,
                                  sampleRate: sampleRate,
                                  timestamp: ptsFrames * 1000 / Int64(sampleRate)))
        }
        self.mixBus = bus
        bus.start()

        switch source {
        case .microphone:
            bus.activate(.microphone)
            try startMic()
        #if os(macOS)
        case .system:
            bus.activate(.system)
            try await startSystemAudio()
        case .mixed:
            bus.activate(.microphone)
            bus.activate(.system)
            try startMic()
            try await startSystemAudio()
        #else
        case .system, .mixed:
            throw EngineError.unsupported("System audio capture is only available on macOS.")
        #endif
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

        #if os(macOS)
        if let scStream = scStream {
            do { try await scStream.stopCapture() } catch { NSLog("[ClassNote] SCStream stop err: \(error)") }
        }
        scStream = nil
        scStreamOutputHandler = nil
        scStreamDelegate = nil
        #endif

        // Flush the bus before closing the writer, or the last tick's audio is
        // captured and then thrown away.
        mixBus?.finish()
        mixBus = nil

        await writer?.finish()
        writer = nil

        subscribers.finishAll()
    }

    // MARK: - Mic

    private func startMic() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        try configurePreferredInputDevice(on: input)
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw EngineError.unsupported("Microphone not available (sample rate 0). Check privacy permissions.")
        }
        micConverter = AVAudioConverter(from: inputFormat, to: targetFormat)

        let bus = self.mixBus
        let converter = self.micConverter
        let target = self.targetFormat!

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            // Convert to 16k mono Int16 and hand it to the bus, which owns both
            // the clock and every downstream consumer.
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
            bus?.submit(data, from: .microphone)
        }
        try engine.start()
    }

    private func configurePreferredInputDevice(on input: AVAudioInputNode) throws {
        #if os(macOS)
        guard let microphoneDeviceID, !microphoneDeviceID.isEmpty else { return }
        guard let deviceID = Self.audioDeviceID(for: microphoneDeviceID) else {
            throw EngineError.unsupported("Selected microphone is not available: \(MicrophoneDeviceCatalog.name(for: microphoneDeviceID))")
        }

        var mutableID = deviceID
        let status = AudioUnitSetProperty(input.audioUnit!,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &mutableID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw EngineError.unsupported("Could not switch to microphone \(MicrophoneDeviceCatalog.name(for: microphoneDeviceID)) (OSStatus \(status)).")
        }
        #endif
        // iOS has no per-device AVAudioEngine input selection API; the system
        // default input (managed via AVAudioSession) is always used.
    }

    #if os(macOS)
    nonisolated private static func audioDeviceID(for uniqueID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address,
                                             0,
                                             nil,
                                             &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address,
                                         0,
                                         nil,
                                         &dataSize,
                                         &deviceIDs) == noErr else { return nil }

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var unmanagedUID: Unmanaged<CFString>?
            let status = withUnsafeMutablePointer(to: &unmanagedUID) { pointer in
                AudioObjectGetPropertyData(deviceID,
                                           &uidAddress,
                                           0,
                                           nil,
                                           &uidSize,
                                           pointer)
            }
            if status == noErr, let unmanagedUID {
                let uid = unmanagedUID.takeRetainedValue() as String
                if uid == uniqueID {
                    return deviceID
                }
            }
        }
        return nil
    }
    #endif

    nonisolated private static func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let ch = buffer.int16ChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        let bytes = frameLength * channelCount * 2
        return Data(bytes: ch[0], count: bytes)
    }

    // MARK: - System audio (ScreenCaptureKit, macOS only)

    #if os(macOS)
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

        let bus = self.mixBus
        let target = self.targetFormat!
        let sampleCounter = SampleCounter()

        let handler = SCStreamOutputHandler { sampleBuffer in
            sampleCounter.increment()
            // Converted here and submitted to the bus; the bus tick is the only
            // thing that writes the file, so system and mic audio cannot end up
            // on two different timelines.
            Self.emitSTTChunk(from: sampleBuffer,
                              target: target,
                              submit: { data in bus?.submit(data, from: .system) })
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

    /// Converts an SCK audio CMSampleBuffer to 16k mono Int16 and hands it to
    /// `submit`. Runs on the SCK audio queue, so it must never touch `self`.
    nonisolated private static func emitSTTChunk(from sampleBuffer: CMSampleBuffer,
                                     target: AVAudioFormat,
                                     submit: @Sendable (Data) -> Void) {
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
        submit(data)
    }
    #endif

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
            subscribers.yield(chunk)
            let ms = Int64(Double(end - offset) / Double(chunkBytes) * 1000)
            tsMs += ms
            offset = end
            if realtime {
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            }
            if !running { break }
        }
        subscribers.finishAll()
    }
}

// MARK: - Chunk fan-out

/// The live `makeChunkStream()` consumers, so the mix bus can feed several at
/// once. Lock-guarded because it is written from the MainActor (subscribe) and
/// read from the bus queue (yield).
final class ChunkSubscribers: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [Int: AsyncStream<AudioChunk>.Continuation] = [:]
    private var nextToken = 0
    private var finished = false

    func add(_ continuation: AsyncStream<AudioChunk>.Continuation) -> Int {
        lock.lock()
        // Subscribing after capture stopped must not hand out a stream that
        // never ends; finish it immediately instead.
        if finished {
            lock.unlock()
            continuation.finish()
            return -1
        }
        nextToken += 1
        let token = nextToken
        continuations[token] = continuation
        lock.unlock()
        return token
    }

    func remove(_ token: Int) {
        lock.lock()
        continuations[token] = nil
        lock.unlock()
    }

    func yield(_ chunk: AudioChunk) {
        lock.lock()
        let live = Array(continuations.values)
        lock.unlock()
        for continuation in live { continuation.yield(chunk) }
    }

    func finishAll() {
        lock.lock()
        let live = Array(continuations.values)
        continuations.removeAll()
        finished = true
        lock.unlock()
        for continuation in live { continuation.finish() }
    }
}

// MARK: - Mix bus

/// Sums the mic and ScreenCaptureKit streams onto one 16 kHz mono Int16
/// timeline. Both capture callbacks already convert to that format, so mixing
/// is sample-wise addition with clipping. Each source gets its own jitter
/// buffer because the two callbacks run on different queues at different
/// cadences (AVAudioEngine ~85 ms at 4096 frames/48 kHz; SCK variable).
///
/// The bus is also the single producer for the recording file and for every
/// chunk stream, which is what makes the file's timeline and the subtitle
/// timestamps the same clock — both are derived from the emitted frame count
/// rather than from `Date()`.
final class AudioMixBus: @unchecked Sendable {
    enum Source: Int, CaseIterable, Sendable {
        case microphone = 0
        case system = 1
    }

    /// (pcm16, ptsFrames, sampleRate)
    typealias Sink = @Sendable (Data, Int64, Int) -> Void

    private let lock = NSLock()
    private var pending: [[Int16]] = [[], []]
    private var activeSources: Set<Source> = []
    private var emittedFrames: Int64 = 0
    private var didLogBacklogDrop = false
    private var timer: DispatchSourceTimer?
    /// Owned by the bus rather than created in `start()`, so `finish()` can
    /// drain *on it* and thereby wait out a tick that is still in flight.
    private let queue = DispatchQueue(label: "classnote.mix")

    private let sampleRate: Int
    private let frameMs: Int
    /// Frames emitted per tick.
    let frameChunk: Int
    /// Per-source jitter-buffer ceiling. A wedged source must not grow memory.
    private let backlogCap: Int
    private let sink: Sink

    init(sampleRate: Int = 16000, frameMs: Int = 100, backlogMs: Int = 400, sink: @escaping Sink) {
        self.sampleRate = max(sampleRate, 1)
        self.frameMs = max(frameMs, 1)
        self.frameChunk = max(self.sampleRate * self.frameMs / 1000, 1)
        self.backlogCap = max(self.sampleRate * max(backlogMs, frameMs) / 1000, self.frameChunk)
        self.sink = sink
    }

    func activate(_ source: Source) {
        lock.lock()
        activeSources.insert(source)
        lock.unlock()
    }

    func submit(_ pcm16: Data, from source: Source) {
        guard pcm16.count >= 2 else { return }
        let samples = pcm16.withUnsafeBytes { raw -> [Int16] in
            Array(raw.bindMemory(to: Int16.self))
        }
        lock.lock()
        pending[source.rawValue].append(contentsOf: samples)
        lock.unlock()
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(frameMs),
                        repeating: .milliseconds(frameMs),
                        leeway: .milliseconds(10))
        source.setEventHandler { [weak self] in
            // Drain rather than emit one chunk per fire. Dispatch coalesces a
            // missed fire (a stalled encoder, a busy machine), and a bus capped
            // at one chunk per fire can never catch up: the backlog would grow
            // to `backlogCap` and then start dropping audio out of the middle
            // of the recording, while the PTS clock fell behind wall time.
            guard let self else { return }
            while self.tick() {}
        }
        source.resume()
        timer = source
    }

    /// Stops the timer and drains whatever is still buffered, so the tail of a
    /// recording is not lost between the last tick and `stop()`.
    func finish() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
        // On the mix queue, not the caller's thread: `cancel()` does not wait
        // for a handler that is already running, and `tick` calls `sink`
        // outside the lock. Draining here would otherwise be able to overtake
        // an in-flight tick and hand the writer a PTS lower than the one it
        // just appended, which latches `failed` and truncates the file.
        //
        // Bounded: every flushing tick consumes at least one sample from a
        // non-empty buffer, and the loop stops once all buffers are empty.
        queue.sync { while self.tick(flushPartial: true) {} }
    }

    /// One mix step. Internal (not private) so tests can drive the bus without
    /// waiting on a timer. Returns false when there was nothing to emit.
    ///
    /// `flushPartial` is for `finish()` only: during capture a tick waits until
    /// some source has a whole chunk, because the callbacks' cadence does not
    /// divide the tick interval and padding the shortfall would splice silence
    /// into the middle of the recording. A source that is genuinely stalled is
    /// still zero-filled, since the other one has its chunk ready.
    @discardableResult
    func tick(flushPartial: Bool = false) -> Bool {
        lock.lock()
        let sources = activeSources.sorted { $0.rawValue < $1.rawValue }
        let ready = sources.contains { source in
            let count = pending[source.rawValue].count
            return flushPartial ? count > 0 : count >= frameChunk
        }
        guard ready else {
            // Nothing captured yet (or ever again): do not emit silence and do
            // not advance the clock — the engines would be fed a silent stream
            // for as long as the bus lives.
            lock.unlock()
            return false
        }
        // Starting from zeros makes the single-source case an exact
        // pass-through: summing with silence is the identity, so a mic-only
        // recording keeps its full level (dividing by the source count would
        // halve it).
        var mixed = [Int16](repeating: 0, count: frameChunk)
        for source in sources {
            let index = source.rawValue
            let take = min(frameChunk, pending[index].count)
            if take > 0 {
                for i in 0..<take {
                    mixed[i] = Int16(clamping: Int32(mixed[i]) + Int32(pending[index][i]))
                }
                pending[index].removeFirst(take)
            }
            if pending[index].count > backlogCap {
                pending[index].removeFirst(pending[index].count - backlogCap)
                if !didLogBacklogDrop {
                    didLogBacklogDrop = true
                    NSLog("[ClassNote] AudioMixBus: dropping backlog from source \(index)")
                }
            }
        }
        let pts = emittedFrames
        emittedFrames += Int64(frameChunk)
        lock.unlock()

        let data = mixed.withUnsafeBufferPointer { Data(buffer: $0) }
        sink(data, pts, sampleRate)
        return true
    }
}

// MARK: - File writer

/// Thread-safe AVAssetWriter wrapper with one entry point.
///
/// Everything reaching it now comes from `AudioMixBus`, so it is always 16 kHz
/// mono Int16 PCM with a frame-accurate PTS — which means every recording is
/// archived as 16 kHz mono AAC, including system-audio ones that used to be
/// kept at 48 kHz stereo. That is exactly what the ASR hears, it halves the
/// file size, and it removes the two divergent writer paths whose "am I the
/// only source?" guards left mixed recordings with no file at all.
final class FileWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private var failed = false
    /// Latched by `finish()`. The mix bus's timer handler can still be in
    /// flight when capture stops, and a late append would otherwise re-open the
    /// writer and truncate the recording that was just finalised.
    private var closed = false
    /// Frames the encoder was too busy to take. The bus has already advanced
    /// its PTS clock past them, so they are an unannounced hole in the track —
    /// worth a line in the log rather than silence.
    private var droppedFrames = 0
    private var didLogNotReady = false

    init(url: URL) {
        self.url = url
    }

    /// Appends mixed PCM. `ptsFrames` is the frame index of the first sample,
    /// so the file's timeline matches the AudioChunk timestamps exactly.
    func append(pcm16: Data, sampleRate: Int, ptsFrames: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed, !closed, pcm16.count >= 2 else { return }

        if writer == nil {
            guard openWriter(sampleRate: sampleRate) else { return }
        }
        guard let input = input else { return }
        guard input.isReadyForMoreMediaData else {
            // Appending anyway is illegal, so the block has to go; both sources
            // now ride this one entry point, so say it happened at least once
            // instead of letting the recording quietly develop gaps under load.
            droppedFrames += pcm16.count / 2
            if !didLogNotReady {
                didLogNotReady = true
                NSLog("[ClassNote] FileWriter: encoder not ready, dropping audio")
            }
            return
        }
        guard let sampleBuffer = Self.makeSampleBuffer(pcm16,
                                                        sampleRate: sampleRate,
                                                        ptsFrames: ptsFrames) else { return }
        if !started {
            writer?.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        if !input.append(sampleBuffer) {
            NSLog("[ClassNote] FileWriter: append failed: %@", writer?.error?.localizedDescription ?? "?")
            failed = true
        }
    }

    func finish() async {
        let (w, i): (AVAssetWriter?, AVAssetWriterInput?) = {
            lock.lock()
            defer { lock.unlock() }
            closed = true
            if droppedFrames > 0 {
                NSLog("[ClassNote] FileWriter: \(droppedFrames) frames never reached the encoder")
            }
            let result = (writer, input)
            writer = nil
            input = nil
            return result
        }()
        guard let writer = w else { return }
        i?.markAsFinished()
        if writer.status == .writing {
            await writer.finishWriting()
        }
    }

    /// Wraps one mixed frame block as a CMSampleBuffer. Static and internal so
    /// the PTS/sample-count arithmetic can be tested without a real writer.
    static func makeSampleBuffer(_ pcm16: Data, sampleRate: Int, ptsFrames: Int64) -> CMSampleBuffer? {
        guard pcm16.count >= 2, sampleRate > 0 else { return nil }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0)
        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: &asbd,
                                             layoutSize: 0,
                                             layout: nil,
                                             magicCookieSize: 0,
                                             magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &formatDesc) == noErr,
              let formatDesc else { return nil }

        let byteCount = pcm16.count
        let frames = byteCount / 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: byteCount,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: byteCount,
                                                 flags: 0,
                                                 blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = pcm16.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                 blockBuffer: block,
                                                 offsetIntoDestination: 0,
                                                 dataLength: byteCount)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: ptsFrames, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid)
        var sampleSize = 2
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                        dataBuffer: block,
                                        formatDescription: formatDesc,
                                        sampleCount: frames,
                                        sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    private func openWriter(sampleRate: Int) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .m4a)
            // Flush a self-contained fragment every 5s so a crash or a force
            // quit leaves a playable prefix instead of a file with no moov
            // atom. Both have to be set before startWriting().
            w.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
            w.initialMovieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(sampleRate),
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ]
            // Do not pass the PCM source format as a hint while asking
            // AVAssetWriter to encode AAC. On newer macOS releases this can
            // raise an Objective-C exception inside AVAssetWriterInput's
            // initializer, which bypasses Swift error handling and aborts the
            // app from the realtime audio callback.
            let inp = AVAssetWriterInput(mediaType: .audio,
                                         outputSettings: settings)
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

// MARK: - SCK adapters (macOS only)

#if os(macOS)
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
#endif
