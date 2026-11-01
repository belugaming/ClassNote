import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreAudio
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

    /// `.system`/`.mixed` need ScreenCaptureKit, which iOS doesn't have.
    /// UI source pickers should use this instead of `allCases`.
    static var availableCases: [AudioSourceKind] {
        return Self.allCases
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
    /// Asks coreaudiod, and waits for as long as it takes to answer: forever if
    /// it is deadlocked. Keep it off the main thread; the app goes through
    /// `AppState.refreshMicrophoneDevices()`.
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

    private var mic: MicrophoneCapture?
    private var scStream: SCStream?
    private var scStreamOutputHandler: SCStreamOutputHandler?
    private var scStreamDelegate: SCStreamDelegateAdapter?
    private var targetFormat: AVAudioFormat!
    private var running = false
    /// The bus clock as `stop()` left it, so the length of the recording can
    /// still be read once the bus is gone.
    private var finalRecordedMs: Int64 = 0
    /// False only in tests: no device is opened, the bus's timer does not run,
    /// and the test feeds audio through `feedForTesting`.
    private let capturesDevices: Bool

    /// What the microphone watchdog and restarts report, on the main actor.
    /// Capture keeps running through all of it, so this is the only sign.
    var onMicrophoneEvent: ((MicrophoneCapture.Event) -> Void)?

    // Only ever touched from the mix bus's own serial queue (and from `stop()`
    // once the bus has been finished), which is what makes its lock uncontended.
    private var writer: FileWriter?
    private let microphoneDeviceID: String?

    init(microphoneDeviceID: String? = nil, capturesDevices: Bool = true) {
        self.microphoneDeviceID = microphoneDeviceID
        self.capturesDevices = capturesDevices
        super.init()
    }

    /// How much audio the recording holds, in ms: the bus clock, which is the
    /// timeline of the file and of every chunk timestamp. Unlike wall time it
    /// stands still while no source has data.
    var recordedMs: Int64 { mixBus?.emittedMs ?? finalRecordedMs }

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

    /// A chunk stream that also says where on the bus clock its consumer
    /// started; see `ChunkStreamOrigin`.
    func makeChunkSubscription() -> ChunkSubscription {
        let origin = ChunkStreamOrigin()
        let source = ChunkIterator(makeChunkStream())
        let stream = AsyncStream<AudioChunk>(unfolding: {
            guard let chunk = await source.next() else { return nil }
            origin.note(chunk)
            return chunk
        })
        return ChunkSubscription(stream: stream, origin: origin)
    }

    /// Tests only: hands `pcm16` to the bus as microphone audio and runs it
    /// until every whole chunk is out, which is what its timer would do. A
    /// chunk at a time, as a device delivers: in one piece, all but the jitter
    /// buffer's cap would be dropped.
    func feedForTesting(_ pcm16: Data) {
        guard let bus = mixBus else { return }
        let step = bus.frameChunk * 2
        var offset = pcm16.startIndex
        while offset < pcm16.endIndex {
            let end = min(offset + step, pcm16.endIndex)
            bus.submit(pcm16.subdata(in: offset..<end), from: .microphone)
            while bus.tick() {}
            offset = end
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
        guard capturesDevices else {
            bus.activate(.microphone)
            return
        }
        bus.start()

        switch source {
        case .microphone:
            bus.activate(.microphone)
            try startMic()
        case .system:
            bus.activate(.system)
            try await startSystemAudio()
        case .mixed:
            bus.activate(.microphone)
            bus.activate(.system)
            try startMic()
            try await startSystemAudio()
        case .file:
            throw EngineError.unsupported("Use ingestFile() for .file source")
        }
    }

    func stop() async {
        guard running else { return }
        running = false
        mic?.stop()
        mic = nil

        if let scStream = scStream {
            do { try await scStream.stopCapture() } catch { NSLog("[ClassNote] SCStream stop err: \(error)") }
        }
        scStream = nil
        scStreamOutputHandler = nil
        scStreamDelegate = nil

        // Flush the bus before closing the writer, or the last tick's audio is
        // captured and then thrown away.
        mixBus?.finish()
        finalRecordedMs = mixBus?.emittedMs ?? finalRecordedMs
        mixBus = nil

        await writer?.finish()
        writer = nil

        subscribers.finishAll()
    }

    // MARK: - Mic

    private func startMic() throws {
        let mic = MicrophoneCapture(preferredDeviceID: microphoneDeviceID,
                                    target: targetFormat,
                                    bus: mixBus) { [weak self] event in
            Task { @MainActor [weak self] in self?.onMicrophoneEvent?(event) }
        }
        try mic.start()
        self.mic = mic
    }

    // MARK: - System audio (ScreenCaptureKit, macOS only)

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
        let resampler = StreamingResampler(target: targetFormat)
        let sampleCounter = SampleCounter()

        let handler = SCStreamOutputHandler { sampleBuffer in
            sampleCounter.increment()
            // Converted here and submitted to the bus; the bus tick is the only
            // thing that writes the file, so system and mic audio cannot end up
            // on two different timelines.
            guard let data = resampler.convert(sampleBuffer) else { return }
            bus?.submit(data, from: .system)
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

// MARK: - Microphone

/// The microphone half of capture: one AVAudioEngine with its tap and
/// resampler, rebuilt in place when macOS changes the input under it.
///
/// AVAudioEngine stops and uninitialises itself when the input device or its
/// format changes (AirPods connected mid-lecture, the selected USB mic
/// unplugged, another input picked in System Settings) and posts
/// `AVAudioEngineConfigurationChange`. Nothing restarted it, so a mic-only
/// recording silently stopped growing while the timer ran on. A watchdog backs
/// the notification up: a device that dies without one is found by its
/// samples stopping, and is retried until it comes back.
///
/// Everything that touches the engine runs on `queue`, so a restart cannot
/// interleave with the start or stop the main actor drives.
final class MicrophoneCapture: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        /// The selected microphone is gone; capture goes on from the system
        /// default input.
        case fellBackToDefault
        /// Nothing is reaching the bus from the microphone and ClassNote is
        /// trying to get it back. `restartError` is set when it is because a
        /// restart threw.
        case silent(restartError: String?)
        /// Samples are arriving again after `silent`.
        case recovered
    }

    private let queue = DispatchQueue(label: "classnote.mic")
    private let preferredDeviceID: String?
    private let target: AVAudioFormat
    private let bus: AudioMixBus?
    private let onEvent: @Sendable (Event) -> Void
    /// Written by the tap, read by the watchdog.
    private let lastSample = SampleClock()

    // Only touched on `queue`.
    private var engine: AVAudioEngine?
    private var tapFormat: AVAudioFormat?
    private var observer: NSObjectProtocol?
    private var running = false
    private var restartScheduled = false
    private var onFallback = false
    private var watchdog = MicrophoneWatchdog()
    private var watchdogTimer: DispatchSourceTimer?

    init(preferredDeviceID: String?,
         target: AVAudioFormat,
         bus: AudioMixBus?,
         onEvent: @escaping @Sendable (Event) -> Void) {
        self.preferredDeviceID = preferredDeviceID
        self.target = target
        self.bus = bus
        self.onEvent = onEvent
    }

    /// Throws when the microphone cannot be opened at all, which fails the
    /// start of the recording. Later failures are reported through `onEvent`.
    func start() throws {
        try queue.sync {
            try startEngine(isRestart: false)
            running = true
            lastSample.mark()
            startWatchdog()
        }
    }

    func stop() {
        queue.sync {
            running = false
            watchdogTimer?.cancel()
            watchdogTimer = nil
            tearDownEngine()
        }
    }

    private func startEngine(isRestart: Bool) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var fallingBack = false
        if let preferredDeviceID {
            if let deviceID = Self.audioDeviceID(for: preferredDeviceID) {
                try Self.select(deviceID, on: input, uniqueID: preferredDeviceID)
            } else if isRestart {
                // Unplugged mid-lecture: the rest of the lecture from the
                // default input beats none of it. A later restart goes back to
                // the selected one if it has returned.
                fallingBack = true
            } else {
                throw EngineError.unsupported("Selected microphone is not available: \(MicrophoneDeviceCatalog.name(for: preferredDeviceID))")
            }
        }
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw EngineError.unsupported("Microphone not available (sample rate 0). Check privacy permissions.")
        }

        // A new resampler for the new format; the bus, which owns the clock
        // and every downstream consumer, just sees the samples resume.
        let resampler = StreamingResampler(target: target)
        let bus = self.bus
        let lastSample = self.lastSample
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let data = resampler.convert(buffer) else { return }
            bus?.submit(data, from: .microphone)
            lastSample.mark()
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        self.tapFormat = inputFormat
        let source = ObjectIdentifier(engine)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine,
                                                          queue: nil) { [weak self] _ in
            self?.configurationChanged(source: source)
        }
        // Said once, and only once the default input is actually running.
        if fallingBack, !onFallback { onEvent(.fellBackToDefault) }
        onFallback = fallingBack
    }

    private func tearDownEngine() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        tapFormat = nil
    }

    /// Posted on an engine thread. Run a moment later and coalesced: a device
    /// switch posts several in a row while its format settles.
    private func configurationChanged(source: ObjectIdentifier) {
        queue.async { [self] in
            guard running, !restartScheduled,
                  let engine, ObjectIdentifier(engine) == source else { return }
            restartScheduled = true
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [self] in
                restartScheduled = false
                guard let error = restart(force: false) else { return }
                if watchdog.restartFailed(at: ProcessInfo.processInfo.systemUptime) {
                    onEvent(.silent(restartError: error))
                }
            }
        }
    }

    /// Rebuilds the engine on whatever input there is now. Returns why it
    /// failed, or nil.
    @discardableResult
    private func restart(force: Bool) -> String? {
        guard running else { return nil }
        // A change on the output side, or one that settled back, leaves the
        // input this engine reads untouched.
        if !force, inputIsUnchanged() { return nil }
        tearDownEngine()
        do {
            try startEngine(isRestart: true)
            NSLog("[ClassNote] Microphone restarted")
            return nil
        } catch {
            NSLog("[ClassNote] Microphone restart failed: \(error)")
            return error.localizedDescription
        }
    }

    private func inputIsUnchanged() -> Bool {
        guard let engine, engine.isRunning, let tapFormat,
              engine.inputNode.inputFormat(forBus: 0) == tapFormat else { return false }
        // Still on the selected device, which must still exist; on the
        // fallback the default input is whatever macOS says it is.
        guard let preferredDeviceID, !onFallback else { return true }
        return Self.audioDeviceID(for: preferredDeviceID) != nil
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.checkSamples() }
        timer.resume()
        watchdogTimer = timer
    }

    private func checkSamples() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch watchdog.check(now: now, lastSample: lastSample.lastMark) {
        case .none:
            break
        case .reportSilence:
            NSLog("[ClassNote] Microphone: no samples for \(Int(MicrophoneWatchdog.stallAfter))s, restarting")
            onEvent(.silent(restartError: restart(force: true)))
        case .retry:
            restart(force: true)
        case .reportRecovered:
            NSLog("[ClassNote] Microphone: samples are back")
            onEvent(.recovered)
        }
    }

    private static func select(_ deviceID: AudioDeviceID, on input: AVAudioInputNode, uniqueID: String) throws {
        var mutableID = deviceID
        let status = AudioUnitSetProperty(input.audioUnit!,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &mutableID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw EngineError.unsupported("Could not switch to microphone \(MicrophoneDeviceCatalog.name(for: uniqueID)) (OSStatus \(status)).")
        }
    }

    private static func audioDeviceID(for uniqueID: String) -> AudioDeviceID? {
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
}

/// Decides, from when the last microphone buffer reached the bus, when the
/// microphone has gone quiet in a way only a fault explains (the tap delivers
/// a buffer every ~85 ms, silence included), when to try restarting it again,
/// and when it is back. Pure, so it can be tested without a device.
struct MicrophoneWatchdog {
    static let stallAfter: TimeInterval = 5
    static let retryEvery: TimeInterval = 5

    enum Action: Equatable {
        case none
        /// Tell the user and restart the engine.
        case reportSilence
        /// Still nothing: restart again, quietly.
        case retry
        case reportRecovered
    }

    /// When the silence was reported; nil while the microphone is healthy.
    private(set) var silentSince: TimeInterval?
    private var lastRetry: TimeInterval = 0

    /// Called about once a second; times are on one monotonic clock.
    mutating func check(now: TimeInterval, lastSample: TimeInterval) -> Action {
        if let silentSince {
            // Recovered only by a sample that arrived after the fault: the
            // last one from before it is no sign of life.
            if lastSample > silentSince {
                self.silentSince = nil
                return .reportRecovered
            }
            guard now - lastRetry >= Self.retryEvery else { return .none }
            lastRetry = now
            return .retry
        }
        guard now - lastSample >= Self.stallAfter else { return .none }
        silentSince = now
        lastRetry = now
        return .reportSilence
    }

    /// A restart after a configuration change threw. Returns whether to tell
    /// the user now, rather than once `stallAfter` has passed.
    mutating func restartFailed(at now: TimeInterval) -> Bool {
        lastRetry = now
        guard silentSince == nil else { return false }
        silentSince = now
        return true
    }
}

// MARK: - Converter input

/// One-shot flag for an `AVAudioConverter` input block, which must hand its
/// source buffer over exactly once and answer `.noDataNow` from then on.
///
/// A local `var` cannot do that any more: `AVAudioConverterInputBlock` is
/// `@Sendable`, so capturing and mutating one is a data-race warning. No lock
/// is needed either — `convert(to:error:withInputFrom:)` calls the block
/// synchronously on the calling thread and returns before that thread moves
/// on, so the flag is only ever touched by that one thread.
private final class OneShot: @unchecked Sendable {
    private(set) var fired = false

    /// True the first time only.
    func take() -> Bool {
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: - Resampling

/// Converts one capture stream to the bus format (16 kHz mono Int16) through
/// a single `AVAudioConverter` kept for the whole stream. A converter holds
/// back its filter tail and the fractional frame between calls; the system
/// audio path used to create one per ~20 ms ScreenCaptureKit buffer and throw
/// both away each time, which left micro-gaps in the track and the ASR input
/// and made the bus clock run slow. Rebuilt only when the input format changes.
///
/// No lock: each instance is fed from one serial queue (the SCK sample queue,
/// or the mic tap's), and the converter is created lazily on it.
final class StreamingResampler: @unchecked Sendable {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?
    /// Converters made so far: one unless the input format changed.
    private(set) var converterCount = 0

    init(target: AVAudioFormat) {
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.frameLength > 0 else { return nil }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterCount += 1
        }
        guard let converter else { return nil }
        // Room for what this buffer yields plus what the last one held back.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var error: NSError?
        let provided = OneShot()
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            guard provided.take() else { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return Self.pcmData(from: out)
    }

    /// A ScreenCaptureKit audio buffer.
    func convert(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer,
                                                           at: 0,
                                                           frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr
        else { return nil }
        return convert(buffer)
    }

    private static func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let ch = buffer.int16ChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        let bytes = frameLength * channelCount * 2
        return Data(bytes: ch[0], count: bytes)
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

/// A chunk stream handed to one STT attempt, with where it started.
struct ChunkSubscription: Sendable {
    let stream: AsyncStream<AudioChunk>
    let origin: ChunkStreamOrigin
}

/// The bus timestamp of the first chunk the stream's consumer actually took.
/// The local sidecars and Apple Speech count time from the first sample they
/// are sent, so this is the origin their event times are rebased onto. Read
/// off the chunk rather than off the bus at subscription time: a tick can be
/// in flight while subscribing, and a consumer slow to start (a sidecar that
/// reloads its model after a restart) loses the oldest buffered chunks.
final class ChunkStreamOrigin: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Int64?

    /// Nil until the consumer has taken a chunk.
    var startMs: Int64? { lock.withLock { first } }

    fileprivate func note(_ chunk: AudioChunk) {
        lock.withLock {
            if first == nil { first = chunk.timestamp }
        }
    }
}

/// Lets `makeChunkSubscription` pull from a chunk stream inside the
/// `@Sendable` unfolding closure. Unlocked because a stream has one consumer,
/// which never calls `next()` twice at once.
private final class ChunkIterator: @unchecked Sendable {
    private var iterator: AsyncStream<AudioChunk>.AsyncIterator

    init(_ stream: AsyncStream<AudioChunk>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> AudioChunk? {
        await iterator.next()
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

    /// The bus clock in ms: the timeline of the file and of every chunk.
    var emittedMs: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return emittedFrames * 1000 / Int64(sampleRate)
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
            // AAC-LC's encoder only accepts a bit rate within the range it
            // supports for the sample rate and channel count; 64 kbps is above
            // the range for 16 kHz mono and made codec initialisation fail
            // ("Cannot Encode Media"). 32 kbps is the usual figure for speech
            // at this rate.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(sampleRate),
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000
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

/// When the microphone last got a buffer to the bus, on the uptime clock.
/// Starts at creation, so a fresh engine gets a full `stallAfter` of grace.
final class SampleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ProcessInfo.processInfo.systemUptime

    var lastMark: TimeInterval { lock.withLock { last } }

    func mark() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { last = now }
    }
}

// MARK: - SCK adapters (macOS only)

/// Handed to ScreenCaptureKit, which calls it on the sample handler queue it
/// was given, so it leaves the main actor. There is no mutable state to guard:
/// the class is final and its one stored property is an immutable `@Sendable`
/// closure — which is what makes the `@unchecked` honest.
final class SCStreamOutputHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    let handler: @Sendable (CMSampleBuffer) -> Void
    init(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        handler(sampleBuffer)
    }
}

/// See `SCStreamOutputHandler`: final, one immutable `@Sendable` closure, no
/// mutable state, so nothing to lock.
final class SCStreamDelegateAdapter: NSObject, SCStreamDelegate, @unchecked Sendable {
    let onError: @Sendable (Error) -> Void
    init(onError: @escaping @Sendable (Error) -> Void) {
        self.onError = onError
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}
