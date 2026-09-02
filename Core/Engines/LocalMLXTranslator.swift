import Foundation

enum LocalMLXTranslatorError: Error, LocalizedError {
    case launchFailed(String)
    case readyTimeout
    case engineError(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return "本地翻译引擎启动失败: \(msg)"
        case .readyTimeout: return "本地翻译引擎启动超时"
        case .engineError(let msg): return "本地翻译失败: \(msg)"
        }
    }
}

/// Owns the single warm `translate_server.py` child process.
///
/// Unlike the ASR sidecar this speaks newline-delimited JSON over a pipe rather
/// than a WebSocket: translation is request/response, so there is nothing to
/// stream *in*, and a pipe avoids allocating a port. Responses are multiplexed by
/// request id, which is also what lets a superseded request be cancelled without
/// tearing the process down.
///
/// One process for the whole app, kept warm: the model takes ~2.5s to load and
/// under a second to translate a sentence, so a per-request process would be
/// almost entirely startup cost.
actor LocalMLXTranslatorProcess {
    static let shared = LocalMLXTranslatorProcess()

    private var process: Process?
    private var stdinPipe: Pipe?
    private var pending: [Int: AsyncThrowingStream<String, Error>.Continuation] = [:]
    private var nextId = 1
    private var buffer = Data()
    private var starting: Task<Void, Error>?

    private init() {}

    var isRunning: Bool { process?.isRunning ?? false }

    /// Repo id kept in sync with `translate_server.py`'s DEFAULT_MODEL.
    static let modelRepo = "mlx-community/Hy-MT2-1.8B-4bit"

    /// Whether the weights are already in the Hugging Face cache, so Settings can
    /// offer a download instead of silently stalling on first use while ~1 GB
    /// comes down. `huggingface_hub` maps `a/b` onto `models--a--b`.
    static var isModelDownloaded: Bool {
        let dir = "models--" + modelRepo.replacingOccurrences(of: "/", with: "--")
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/huggingface/hub/\(dir)/snapshots", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        // A snapshot dir exists only once a revision has been fully materialized.
        return !entries.isEmpty
    }

    /// Starts the sidecar purely to download and load the model, so the user can
    /// do it deliberately from Settings rather than on their first sentence.
    func prewarm(onProgress: @escaping @Sendable (String) -> Void) async throws {
        try await ensureStarted(onProgress: onProgress)
    }

    /// Starts the sidecar if it isn't already up. Concurrent callers share one
    /// start attempt rather than racing to spawn several processes.
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
        // The translation model lives in the same venv as the ASR sidecar, so
        // reuse its environment rather than managing a second one.
        if !LocalASREnvironment.shared.isReady(engine: .funasr) {
            onProgress?(L10n.t("localASR.installing"))
            for try await progress in LocalASREnvironment.shared.install(engine: .funasr) {
                onProgress?(progress.stage)
            }
        }
        guard let script = Bundle.main.path(forResource: "translate_server", ofType: "py") else {
            throw LocalMLXTranslatorError.launchFailed("找不到 translate_server.py")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: LocalASREnvironment.shared.pythonExecutablePath)
        proc.arguments = [script, "--exit-with-parent", "\(getpid())"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // mlx-lm and huggingface_hub write progress to stderr. If nothing drains
        // this pipe its buffer fills and Python blocks on write() forever.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            NSLog("[translate_server stderr] \(text)")
        }

        do {
            try proc.run()
        } catch {
            throw LocalMLXTranslatorError.launchFailed(error.localizedDescription)
        }
        self.process = proc
        self.stdinPipe = stdin

        try await Self.waitForReady(pipe: stdout, process: proc, onProgress: onProgress)

        // Only start routing responses once READY has been consumed, so the
        // handshake lines never reach the JSON parser.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data) }
        }
    }

    private static func waitForReady(pipe: Pipe,
                                     process: Process,
                                     onProgress: (@Sendable (String) -> Void)?) async throws {
        let handle = pipe.fileHandleForReading
        // A first run downloads ~1 GB of weights, so the deadline covers a stall
        // rather than the whole download; visible progress extends it.
        var deadline = Date().addingTimeInterval(180)
        var pending = Data()

        while Date() < deadline {
            if !process.isRunning, pending.isEmpty {
                throw LocalMLXTranslatorError.launchFailed(L10n.t("localASR.exitedEarly"))
            }
            let chunk = handle.availableData
            if !chunk.isEmpty {
                pending.append(chunk)
                guard let text = String(data: pending, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") where line.hasPrefix("STAGE ") {
                    onProgress?(L10n.t("localASR.stage.translation"))
                    deadline = Date().addingTimeInterval(180)
                }
                if text.contains("FATAL") {
                    throw LocalMLXTranslatorError.launchFailed(L10n.t("localASR.modelLoadFailed"))
                }
                if text.contains("READY") { return }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LocalMLXTranslatorError.readyTimeout
    }

    /// Splits the stdout stream into lines and routes each response to its
    /// request. Partial lines are held until the rest arrives.
    private func ingest(_ data: Data) {
        buffer.append(data)
        while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = obj["id"] as? Int,
                  let continuation = pending[id]
            else { continue }

            if let error = obj["error"] as? String {
                pending[id] = nil
                continuation.finish(throwing: LocalMLXTranslatorError.engineError(error))
            } else if obj["done"] as? Bool == true {
                pending[id] = nil
                continuation.finish()
            } else if let delta = obj["delta"] as? String {
                continuation.yield(delta)
            }
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let stdinPipe,
              var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(UInt8(ascii: "\n"))
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            NSLog("[LocalMLXTranslator] write failed: \(error)")
        }
    }

    fileprivate func register(_ continuation: AsyncThrowingStream<String, Error>.Continuation) -> Int {
        let id = nextId
        nextId += 1
        pending[id] = continuation
        return id
    }

    fileprivate func request(id: Int, text: String, source: String, target: String) {
        send(["id": id, "text": text, "source": source, "target": target])
    }

    fileprivate func cancel(id: Int) {
        guard pending[id] != nil else { return }
        pending[id] = nil
        send(["id": id, "cancel": true])
    }

    func shutdown() async {
        for (_, continuation) in pending { continuation.finish() }
        pending.removeAll()
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        self.process = nil
        self.stdinPipe = nil
        await LocalASRProcessManager.terminateQuickly(process, name: "translate_server")
    }
}

/// Carries the in-flight request id from the setup task out to `onTermination`.
///
/// `onTermination` has to be installed synchronously, before the id exists, so it
/// cannot simply capture it. Assigning the handler twice instead does not work:
/// the later assignment replaces the earlier one, so whichever cleanup was
/// registered first silently stops running.
private final class RequestHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?

    var id: Int? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// `TranslationProvider` backed by the local MLX sidecar.
struct LocalMLXTranslator: TranslationProvider {
    func translate(text: String,
                   sourceLanguage: String,
                   targetLanguage: String,
                   context: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let handle = RequestHandle()
            let work = Task {
                do {
                    try await LocalMLXTranslatorProcess.shared.ensureStarted()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                let id = await LocalMLXTranslatorProcess.shared.register(continuation)
                handle.id = id
                // `context` is deliberately unused: Hy-MT2 is a sentence-level
                // translation model, and prepending neighbouring lines made it
                // translate them too rather than use them as context.
                await LocalMLXTranslatorProcess.shared.request(id: id,
                                                               text: text,
                                                               source: sourceLanguage,
                                                               target: targetLanguage)
            }
            continuation.onTermination = { reason in
                work.cancel()
                guard case .cancelled = reason, let id = handle.id else { return }
                // Tell the sidecar to stop generating; otherwise a superseded
                // retranslate keeps the model busy for the full response.
                Task { await LocalMLXTranslatorProcess.shared.cancel(id: id) }
            }
        }
    }
}
