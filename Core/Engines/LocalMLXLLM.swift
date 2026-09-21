import Foundation

enum LocalMLXLLMError: Error, LocalizedError {
    case launchFailed(String)
    case readyTimeout
    case engineError(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return "本地大模型启动失败: \(msg)"
        case .readyTimeout: return "本地大模型启动超时"
        case .engineError(let msg): return "本地大模型生成失败: \(msg)"
        }
    }
}

/// Owns the single warm `llm_server.py` child process.
///
/// A sibling of `LocalMLXTranslatorProcess` rather than a second request kind on
/// it: that sidecar's single worker thread is its whole design (MLX state is
/// thread-affine, so a second worker cannot share the first model), and a
/// 30-second notes generation queued there would park every live subtitle
/// translation behind it.
actor LocalMLXLLMProcess {
    static let shared = LocalMLXLLMProcess()

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var pending: [Int: AsyncThrowingStream<String, Error>.Continuation] = [:]
    private var nextId = 1
    private var buffer = Data()
    private var starting: Task<Void, Error>?
    private var idleTask: Task<Void, Never>?

    private init() {}

    var isRunning: Bool { process?.isRunning ?? false }

    /// Repo id kept in sync with `llm_server.py`'s DEFAULT_MODEL.
    static let modelRepo = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    /// See `LocalMLXTranslatorProcess.modelRevision`: nil means unpinned, and an
    /// empty string would look like a pin and resolve to nothing.
    static let modelRevision: String? = "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"

    /// Notes and Q&A are never concurrent with recording in practice, and this
    /// is the *third* resident MLX model on a machine that may already be
    /// holding the ASR and translation ones. So unlike the translator — which
    /// sits on the live path and deliberately has no idle timer — this one gives
    /// its couple of GB back once the user stops asking things.
    static let idleTimeout: TimeInterval = 5 * 60

    /// Ceiling on a single answer. The sidecar clamps this too; sending it keeps
    /// the two halves' idea of "a long answer" in one place.
    static let maxTokens = 2048

    static var isModelDownloaded: Bool {
        HuggingFaceCache.hasCompleteSnapshot(repo: modelRepo, revision: modelRevision)
    }

    static var hasPartialDownload: Bool {
        HuggingFaceCache.hasPartialDownload(repo: modelRepo, revision: modelRevision)
    }

    /// Starts the sidecar purely to download and load the model, so the user can
    /// do it deliberately from Settings rather than on their first question.
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
        // Shares the ASR sidecar's venv: mlx and mlx-lm are already in its
        // requirements, so there is no second environment to manage.
        if !LocalASREnvironment.shared.isReady(engine: .funasr) {
            onProgress?(L10n.t("localASR.installing"))
            for try await progress in LocalASREnvironment.shared.install(engine: .funasr) {
                onProgress?(progress.stage)
            }
        }
        guard let script = Bundle.main.path(forResource: "llm_server", ofType: "py") else {
            throw LocalMLXLLMError.launchFailed("找不到 llm_server.py")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: LocalASREnvironment.shared.pythonExecutablePath)
        var arguments = [script, "--exit-with-parent", "\(getpid())"]
        if let revision = Self.modelRevision {
            arguments += ["--revision", revision]
        }
        proc.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        let activity = SidecarHandshake.ActivityClock()
        // mlx-lm and huggingface_hub write progress to stderr. If nothing drains
        // this pipe its buffer fills and Python blocks on write() forever.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Also feeds the handshake watchdog: a ~2.4 GB first download is
            // otherwise silent on stdout between STAGE heartbeats.
            activity.touch()
            guard let text = String(data: data, encoding: .utf8) else { return }
            NSLog("[llm_server stderr] \(text)")
        }

        do {
            try proc.run()
        } catch {
            throw LocalMLXLLMError.launchFailed(error.localizedDescription)
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
                stageMessage: { _, _ in L10n.t("localASR.stage.llm") },
                onProgress: onProgress)
        } catch {
            SidecarRegistry.shared.unregister(proc.processIdentifier)
            await LocalASRProcessManager.terminateQuickly(proc, name: "llm_server")
            stderr.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            throw Self.mapHandshakeFailure(error)
        }

        // Only start routing responses once READY has been consumed, so the
        // handshake lines never reach the JSON parser.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data) }
        }
        // Whatever shared a read with READY has to go through the parser before
        // the handler above can see anything, or those bytes are lost and the
        // request they belong to never completes.
        if !leftover.isEmpty { ingest(leftover) }
        // A prewarm from Settings never makes a request, so without this nothing
        // would ever start the countdown that gives the model's ~2.4 GB back. A
        // request-driven start cancels it again in `register()`.
        scheduleIdleShutdown()
    }

    private static func mapHandshakeFailure(_ error: Error) -> Error {
        guard let failure = error as? SidecarHandshake.Failure else { return error }
        switch failure {
        case .modelLoadFailed: return LocalMLXLLMError.launchFailed(L10n.t("localASR.modelLoadFailed"))
        case .exitedEarly: return LocalMLXLLMError.launchFailed(L10n.t("localASR.exitedEarly"))
        case .stalled: return LocalMLXLLMError.readyTimeout
        }
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
                continuation.finish(throwing: LocalMLXLLMError.engineError(error))
                scheduleIdleShutdown()
            } else if obj["done"] as? Bool == true {
                pending[id] = nil
                continuation.finish()
                scheduleIdleShutdown()
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
            NSLog("[LocalMLXLLM] write failed: \(error)")
        }
    }

    fileprivate func register(_ continuation: AsyncThrowingStream<String, Error>.Continuation) -> Int {
        idleTask?.cancel()
        idleTask = nil
        let id = nextId
        nextId += 1
        pending[id] = continuation
        return id
    }

    fileprivate func request(id: Int, messages: [ChatMessage], temperature: Double, maxTokens: Int) {
        send(["id": id,
              "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
              "temperature": temperature,
              "max_tokens": maxTokens])
    }

    fileprivate func cancel(id: Int) {
        guard pending[id] != nil else { return }
        pending[id] = nil
        send(["id": id, "cancel": true])
        scheduleIdleShutdown()
    }

    /// Frees the model once nothing has been asked of it for a while. Replaced
    /// by the next request rather than checked against a timestamp, so a busy
    /// session never pays for the timer.
    private func scheduleIdleShutdown() {
        idleTask?.cancel()
        idleTask = nil
        guard pending.isEmpty else { return }
        idleTask = Task { [timeout = Self.idleTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.shutdownIfStillIdle()
        }
    }

    private func shutdownIfStillIdle() async {
        guard pending.isEmpty else { return }
        NSLog("[LocalMLXLLM] idle for \(Int(Self.idleTimeout))s, freeing the model")
        await shutdown()
    }

    func shutdown() async {
        idleTask?.cancel()
        idleTask = nil
        for (_, continuation) in pending { continuation.finish() }
        pending.removeAll()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        stdinPipe = nil
        guard let process else { return }
        self.process = nil
        SidecarRegistry.shared.unregister(process.processIdentifier)
        guard process.isRunning else { return }
        await LocalASRProcessManager.terminateQuickly(process, name: "llm_server")
    }
}

/// `LLMProvider` backed by the local MLX sidecar, so notes and Q&A work with no
/// API key and nothing leaving the Mac.
struct LocalMLXLLM: LLMProvider {
    /// `model` is ignored: the sidecar loads exactly one model, chosen by its
    /// `--model` argument, so the app's model-name setting has nothing to select
    /// here. Kept in the signature because `LLMProvider` is shared with the
    /// cloud engine, where it does choose.
    func chat(messages: [ChatMessage],
              model: String,
              temperature: Double) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let handle = RequestHandle()
            let work = Task {
                do {
                    try await LocalMLXLLMProcess.shared.ensureStarted()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                let id = await LocalMLXLLMProcess.shared.register(continuation)
                handle.id = id
                await LocalMLXLLMProcess.shared.request(id: id,
                                                        messages: messages,
                                                        temperature: temperature,
                                                        maxTokens: LocalMLXLLMProcess.maxTokens)
            }
            continuation.onTermination = { reason in
                work.cancel()
                guard case .cancelled = reason, let id = handle.id else { return }
                // Tell the sidecar to stop generating; otherwise an abandoned
                // answer keeps the model busy for its full length.
                Task { await LocalMLXLLMProcess.shared.cancel(id: id) }
            }
        }
    }

    func chatComplete(messages: [ChatMessage],
                      model: String,
                      temperature: Double) async throws -> String {
        var buf = ""
        for try await d in chat(messages: messages, model: model, temperature: temperature) {
            buf += d
        }
        return buf
    }
}
