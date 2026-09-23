import Foundation

/// One thing the simultaneous translator said about the text fed so far.
enum SimulTranslationEvent: Sendable, Equatable {
    /// It heard enough: `text` translates `source`, everything fed since the
    /// previous translation.
    case translation(source: String, text: String)
    /// Not enough context yet; the input is held for the next call.
    case wait
}

enum SimulTranslatorError: Error, LocalizedError {
    case launchFailed(String)
    case readyTimeout
    case engineError(String)
    /// T3PO translates between Chinese and English only.
    case unsupportedPair

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return "\(L10n.t("simt.error.launch")): \(msg)"
        case .readyTimeout: return L10n.t("simt.error.timeout")
        case .engineError(let msg): return "\(L10n.t("simt.error.engine")): \(msg)"
        case .unsupportedPair: return L10n.t("simt.error.pair")
        }
    }
}

/// Owns the single warm `simt_server.py` child process (Confucius4-T3PO).
///
/// Request/response over newline-delimited JSON, like the Hy-MT2 sidecar, but
/// stateful: the sidecar keeps each session's translation history, so the
/// requests of one session must arrive in order. `LocalSimulSession` makes
/// sure they do.
actor SimulTranslatorProcess {
    static let shared = SimulTranslatorProcess()

    /// The upstream checkpoint, quantized to 4 bits on first use.
    static let sourceRepo = "netease-youdao/Confucius4-T3PO"

    /// Where the quantized model lives. Outside the Hugging Face cache on
    /// purpose: it is built here, not downloaded, and the download it was built
    /// from is deleted afterwards.
    static var modelDirectory: URL {
        AppBootstrap.applicationSupportURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("Confucius4-T3PO-4bit", isDirectory: true)
    }

    static var isModelInstalled: Bool {
        FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("config.json").path)
    }

    /// Whether T3PO can translate `source` into `target`. It was trained on
    /// Chinese <-> English only.
    static func direction(source: String, target: String) -> String? {
        let s = source.lowercased(), t = target.lowercased()
        if s.hasPrefix("en") && t.hasPrefix("zh") { return "en2zh" }
        if s.hasPrefix("zh") && t.hasPrefix("en") { return "zh2en" }
        return nil
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var pending: [Int: CheckedContinuation<[SimulTranslationEvent], Error>] = [:]
    private var nextId = 1
    private var buffer = Data()
    private var starting: Task<Void, Error>?

    private init() {}

    var isRunning: Bool { process?.isRunning ?? false }

    /// Starts the sidecar ahead of use: on a first run that means a ~28 GB
    /// download and a conversion, which should happen from Settings rather
    /// than when a lecture starts.
    func prewarm(onProgress: @escaping @Sendable (String) -> Void) async throws {
        try await ensureStarted(onProgress: onProgress)
    }

    func ensureStarted(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        if isRunning { return }
        if let starting {
            try await starting.value
            return
        }
        let task = Task { try await self.launch(onProgress: onProgress) }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch(onProgress: (@Sendable (String) -> Void)?) async throws {
        if !LocalASREnvironment.shared.isReady() {
            onProgress?(L10n.t("localASR.installing"))
            for try await progress in LocalASREnvironment.shared.install() {
                onProgress?(progress.stage)
            }
        }
        guard let script = Bundle.main.path(forResource: "simt_server", ofType: "py") else {
            throw SimulTranslatorError.launchFailed("simt_server.py missing")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: LocalASREnvironment.shared.pythonExecutablePath)
        proc.arguments = [script,
                          "--model-dir", Self.modelDirectory.path,
                          "--exit-with-parent", "\(getpid())"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        let activity = SidecarHandshake.ActivityClock()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            activity.touch()
            guard let text = String(data: data, encoding: .utf8) else { return }
            NSLog("[simt_server stderr] \(text)")
        }

        do {
            try proc.run()
        } catch {
            throw SimulTranslatorError.launchFailed(error.localizedDescription)
        }
        SidecarRegistry.shared.register(proc.processIdentifier)
        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        let leftover: Data
        do {
            leftover = try await SidecarHandshake.waitForReady(
                pipe: stdout,
                readyLine: "READY",
                process: proc,
                activity: activity,
                stageMessage: { _, key in L10n.t("simt.stage.\(key)") },
                onProgress: onProgress)
        } catch {
            SidecarRegistry.shared.unregister(proc.processIdentifier)
            await LocalASRProcessManager.terminateQuickly(proc, name: "simt_server")
            stderr.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            if let failure = error as? SidecarHandshake.Failure {
                switch failure {
                case .modelLoadFailed: throw SimulTranslatorError.launchFailed(L10n.t("localASR.modelLoadFailed"))
                case .exitedEarly: throw SimulTranslatorError.launchFailed(L10n.t("localASR.exitedEarly"))
                case .stalled: throw SimulTranslatorError.readyTimeout
                }
            }
            throw error
        }

        // One ordered stream of stdout chunks, drained by one task: a Task per
        // chunk may reach the actor out of order, and a JSON line split
        // across two reads would then be reassembled wrongly and lost.
        let (chunks, sink) = AsyncStream<Data>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                sink.finish()
            } else {
                sink.yield(data)
            }
        }
        if !leftover.isEmpty { ingest(leftover) }
        Task { [weak self] in
            for await chunk in chunks { await self?.ingest(chunk) }
            // stdout closed: the sidecar is gone, and nothing will answer.
            await self?.processEnded()
        }
        proc.terminationHandler = { [weak self] _ in
            Task { await self?.processEnded() }
        }
    }

    /// Fails every request still waiting: a crashed sidecar (the 14B model
    /// running out of memory, say) must not leave Stop or Quit waiting on an
    /// answer that is never coming.
    private func processEnded() {
        failPending(SimulTranslatorError.engineError(L10n.t("localASR.exitedEarly")))
        if let process, !process.isRunning {
            SidecarRegistry.shared.unregister(process.processIdentifier)
            self.process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe = nil
        }
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }

    private func cancelRequest(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = obj["id"] as? Int,
                  let continuation = pending.removeValue(forKey: id)
            else { continue }
            if let error = obj["error"] as? String {
                continuation.resume(throwing: SimulTranslatorError.engineError(error))
                continue
            }
            let events = (obj["events"] as? [[String: Any]] ?? []).compactMap { event -> SimulTranslationEvent? in
                switch event["type"] as? String {
                case "translation":
                    return .translation(source: event["source"] as? String ?? "",
                                        text: event["text"] as? String ?? "")
                case "wait":
                    return .wait
                default:
                    return nil
                }
            }
            continuation.resume(returning: events)
        }
    }

    /// Sends one request and waits for its answer.
    func request(_ payload: [String: Any]) async throws -> [SimulTranslationEvent] {
        try await ensureStarted()
        guard let stdinPipe, isRunning else {
            throw SimulTranslatorError.launchFailed(L10n.t("localASR.exitedEarly"))
        }
        let id = nextId
        nextId += 1
        var body = payload
        body["id"] = id
        guard var data = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        data.append(UInt8(ascii: "\n"))
        // Cancellable: Stop gives up on a request after a timeout, and that
        // has to actually end the wait.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                do {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: data)
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    func shutdown() async {
        failPending(CancellationError())
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        stdinPipe = nil
        guard let process else { return }
        self.process = nil
        SidecarRegistry.shared.unregister(process.processIdentifier)
        guard process.isRunning else { return }
        await LocalASRProcessManager.terminateQuickly(process, name: "simt_server")
    }
}

/// One lecture's simultaneous translation: transcript lines go in, in order,
/// and come back as translations that each cover every line fed since the
/// previous one.
///
/// Lines are fed through a serial queue: the sidecar keeps the history, so a
/// line that overtook another would be translated in the wrong context.
@MainActor
final class LocalSimulSession {
    typealias Handler = @MainActor (_ rowIds: [Int64], _ translation: String) -> Void

    private let id = UUID().uuidString
    private let direction: String
    private let terms: [[String]]
    /// Rows fed since the last translation; the next translation covers them.
    private var waitingRows: [Int64] = []
    private var queue: [(rowId: Int64?, text: String?)] = []
    private var worker: Task<Void, Never>?
    private var started = false
    private let onTranslation: Handler
    private let onError: @MainActor (Error) -> Void

    init?(source: String, target: String, glossary: TranslationGlossary,
          onTranslation: @escaping Handler,
          onError: @escaping @MainActor (Error) -> Void) {
        guard let direction = SimulTranslatorProcess.direction(source: source, target: target) else {
            return nil
        }
        self.direction = direction
        self.terms = glossary.pairs.map { [$0.0, $0.1] }
        self.onTranslation = onTranslation
        self.onError = onError
    }

    /// Queues a committed transcript line.
    func feed(rowId: Int64, text: String) {
        queue.append((rowId, text))
        pump()
    }

    /// Queues a flush: whatever is held gets translated. Awaits everything
    /// queued before it.
    func finish() async {
        queue.append((nil, nil))
        pump()
        await worker?.value
        guard !abandoned else { return }
        _ = try? await SimulTranslatorProcess.shared.request(["op": "end", "session": id])
    }

    /// Drops whatever is still queued and stops the request in flight. For a
    /// stop that has run out of time.
    func abandon() {
        abandoned = true
        queue.removeAll()
        worker?.cancel()
    }

    private var abandoned = false

    private func pump() {
        guard worker == nil, !abandoned else { return }
        worker = Task { @MainActor [weak self] in
            while let self, !self.queue.isEmpty, !Task.isCancelled {
                let item = self.queue.removeFirst()
                await self.process(item)
            }
            self?.worker = nil
        }
    }

    private func process(_ item: (rowId: Int64?, text: String?)) async {
        do {
            if !started {
                _ = try await SimulTranslatorProcess.shared.request([
                    "op": "start", "session": id, "direction": direction,
                    "latency": "native", "terms": terms,
                ])
                started = true
            }
            let events: [SimulTranslationEvent]
            if let rowId = item.rowId, let text = item.text {
                waitingRows.append(rowId)
                events = try await SimulTranslatorProcess.shared.request([
                    "op": "feed", "session": id, "text": text,
                ])
            } else {
                events = try await SimulTranslatorProcess.shared.request([
                    "op": "flush", "session": id,
                ])
            }
            for event in events {
                guard case .translation(_, let text) = event, !waitingRows.isEmpty else { continue }
                let rows = waitingRows
                waitingRows.removeAll()
                onTranslation(rows, text)
            }
        } catch is CancellationError {
            // Abandoned by a stop that ran out of time.
        } catch {
            onError(error)
        }
    }
}
