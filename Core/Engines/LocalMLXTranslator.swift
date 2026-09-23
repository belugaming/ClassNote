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

/// Where `huggingface_hub` keeps downloaded weights, and whether what it has is
/// actually usable.
///
/// Shared by both MLX sidecars. The old probe ("the snapshots directory is not
/// empty") reported a model as ready from the first second of a multi-hundred-MB
/// download: `hf_hub_download` creates `snapshots/<revision>/` before the first
/// byte arrives and parks the transfer in `blobs/<etag>.incomplete`.
enum HuggingFaceCache {
    /// Files a usable mlx-lm snapshot must contain besides the weights. The
    /// tokenizer is deliberately not on the list: repos ship it as
    /// tokenizer.json, tokenizer.model or a tiktoken file depending on the
    /// family, and requiring one spelling would report a good model as missing.
    static let requiredFiles = ["config.json"]

    /// Honours the same environment variables `huggingface_hub` reads: a user
    /// with HF_HOME set would otherwise be told "not installed" forever.
    static var hubURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["HUGGINGFACE_HUB_CACHE"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        if let home = env["HF_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("hub", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// `huggingface_hub` maps `a/b` onto `models--a--b`.
    static func repoURL(_ repo: String) -> URL {
        hubURL.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"),
                                      isDirectory: true)
    }

    /// Whether one revision directory holds a complete model.
    ///
    /// `fileExists` resolves the pointer symlink, so a link whose blob never
    /// landed reads as missing — which is exactly what we want.
    static func snapshotIsComplete(at dir: URL) -> Bool {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        guard names.contains(where: { $0.hasSuffix(".safetensors") }) else { return false }
        return requiredFiles.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// `revision` narrows the check to the pinned commit; nil accepts any
    /// complete snapshot of the repo.
    static func hasCompleteSnapshot(repo: String, revision: String? = nil) -> Bool {
        let fm = FileManager.default
        let root = repoURL(repo)
        let blobs = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("blobs").path)) ?? []
        if blobs.contains(where: { $0.hasSuffix(".incomplete") }) { return false }
        let snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        if let revision {
            return snapshotIsComplete(at: snapshots.appendingPathComponent(revision, isDirectory: true))
        }
        let revisions = (try? fm.contentsOfDirectory(atPath: snapshots.path)) ?? []
        return revisions.contains { revision in
            snapshotIsComplete(at: snapshots.appendingPathComponent(revision, isDirectory: true))
        }
    }

    /// Something is cached for this repo, but not a usable snapshot: the
    /// download was interrupted and re-entering it will resume from the
    /// `.incomplete` blob.
    static func hasPartialDownload(repo: String, revision: String? = nil) -> Bool {
        FileManager.default.fileExists(atPath: repoURL(repo).path)
            && !hasCompleteSnapshot(repo: repo, revision: revision)
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
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var pending: [Int: AsyncThrowingStream<String, Error>.Continuation] = [:]
    private var nextId = 1
    private var buffer = Data()
    private var starting: Task<Void, Error>?

    private init() {}

    var isRunning: Bool { process?.isRunning ?? false }

    /// Repo id kept in sync with `translate_server.py`'s DEFAULT_MODEL.
    static let modelRepo = "mlx-community/Hy-MT2-1.8B-4bit"

    /// Commit to pin the download to, mirroring `--revision` on the sidecar.
    /// nil means "whatever main points at" — the same default the script uses,
    /// and the only sane value until a revision has actually been picked and
    /// tested. Passing an empty string would look like a pin and fetch nothing.
    static let modelRevision: String? = "e5c6fe56c7b3bc77fae5ae92db31f2178f1e6912"

    /// Whether the weights are already in the Hugging Face cache, so Settings can
    /// offer a download instead of silently stalling on first use while ~1 GB
    /// comes down.
    static var isModelDownloaded: Bool {
        HuggingFaceCache.hasCompleteSnapshot(repo: modelRepo, revision: modelRevision)
    }

    /// True when the cache holds something for this repo but not a usable
    /// snapshot — an interrupted download that `prewarm` will resume.
    static var hasPartialDownload: Bool {
        HuggingFaceCache.hasPartialDownload(repo: modelRepo, revision: modelRevision)
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
            // Also feeds the handshake watchdog: a ~1 GB download is otherwise
            // silent on stdout for minutes at a time.
            activity.touch()
            guard let text = String(data: data, encoding: .utf8) else { return }
            NSLog("[translate_server stderr] \(text)")
        }

        do {
            try proc.run()
        } catch {
            throw LocalMLXTranslatorError.launchFailed(error.localizedDescription)
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
                stageMessage: { _, _ in L10n.t("localASR.stage.translation") },
                onProgress: onProgress)
        } catch {
            // `ensureStarted`'s defer only clears the flag, so without this the
            // failed child stays resident for the life of the app.
            SidecarRegistry.shared.unregister(proc.processIdentifier)
            await LocalASRProcessManager.terminateQuickly(proc, name: "translate_server")
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
    }

    private static func mapHandshakeFailure(_ error: Error) -> Error {
        guard let failure = error as? SidecarHandshake.Failure else { return error }
        switch failure {
        case .modelLoadFailed: return LocalMLXTranslatorError.launchFailed(L10n.t("localASR.modelLoadFailed"))
        case .exitedEarly: return LocalMLXTranslatorError.launchFailed(L10n.t("localASR.exitedEarly"))
        case .stalled: return LocalMLXTranslatorError.readyTimeout
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

    fileprivate func request(id: Int, text: String, source: String, target: String,
                             context: [String], terms: [[String]]) {
        var payload: [String: Any] = ["id": id, "text": text, "source": source, "target": target]
        if !context.isEmpty { payload["context"] = context }
        if !terms.isEmpty { payload["terms"] = terms }
        send(payload)
    }

    fileprivate func cancel(id: Int) {
        guard pending[id] != nil else { return }
        pending[id] = nil
        send(["id": id, "cancel": true])
    }

    func shutdown() async {
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
        await LocalASRProcessManager.terminateQuickly(process, name: "translate_server")
    }
}

/// Carries the in-flight request id from the setup task out to `onTermination`.
///
/// `onTermination` has to be installed synchronously, before the id exists, so it
/// cannot simply capture it. Assigning the handler twice instead does not work:
/// the later assignment replaces the earlier one, so whichever cleanup was
/// registered first silently stops running.
///
/// Internal rather than private so the LLM sidecar, which multiplexes requests
/// the same way, can use it instead of carrying its own copy.
final class RequestHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?

    var id: Int? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// `TranslationProvider` backed by the local MLX sidecar.
///
/// `context` and `glossary` go to the sidecar as data, not text: it puts them
/// into Hy-MT2's own background-information and terminology templates, which
/// the model was trained to read rather than translate. (Prepending them to
/// the sentence, as an earlier version tried, got them translated too.)
struct LocalMLXTranslator: TranslationProvider {
    func translate(text: String,
                   sourceLanguage: String,
                   targetLanguage: String,
                   context: [String],
                   glossary: TranslationGlossary) -> AsyncThrowingStream<String, Error> {
        let terms = glossary.pairs.map { [$0.0, $0.1] }
        return AsyncThrowingStream { continuation in
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
                await LocalMLXTranslatorProcess.shared.request(id: id,
                                                               text: text,
                                                               source: sourceLanguage,
                                                               target: targetLanguage,
                                                               context: context,
                                                               terms: terms)
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
