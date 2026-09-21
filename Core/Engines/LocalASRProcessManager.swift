import Foundation

enum LocalASRProcessError: Error, LocalizedError {
    case launchFailed(String)
    case readyTimeout
    case portUnavailable
    /// A sidecar is loaded for a different engine/latency and a recording is
    /// streaming through it. Refusing is the point: the alternative is killing
    /// the process that recording depends on.
    case busyWithDifferentConfiguration

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return "本地引擎启动失败: \(msg)"
        case .readyTimeout: return "本地引擎启动超时"
        case .portUnavailable: return "无法找到可用端口"
        case .busyWithDifferentConfiguration: return L10n.t("localASR.busy")
        }
    }
}

/// Owns the lifecycle of one asr_server.py child process. One instance per
/// live session using a local engine; not shared/reused across sessions.
actor LocalASRProcessManager {
    private let engine: LocalASREngineKind
    private var process: Process?
    private var stderrPipe: Pipe?
    /// Kept only so the drain handler installed after READY can be removed on
    /// shutdown; nothing reads from it again.
    private var stdoutPipe: Pipe?

    init(engine: LocalASREngineKind) {
        self.engine = engine
    }

    /// Spawns the sidecar and waits for its READY marker on stdout, returns the ws URL.
    ///
    /// `onProgress` reports setup stages (dependency install, model download,
    /// loading) so the caller can show progress: a first run installs packages
    /// and downloads ~650 MB of weights, which otherwise looks like the app
    /// has hung.
    func start(language: String? = nil,
               onProgress: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        NSLog("[LocalASRProcessManager] start() called for engine=\(engine.rawValue)")

        // Install on demand rather than failing. Nothing else in the app ever
        // called install(), so a fresh machine could only ever get an error.
        if !LocalASREnvironment.shared.isReady(engine: engine) {
            NSLog("[LocalASRProcessManager] environment not ready, installing")
            onProgress?(L10n.t("localASR.installing"))
            for try await progress in LocalASREnvironment.shared.install(engine: engine) {
                NSLog("[LocalASRProcessManager] install: \(progress.stage)")
                onProgress?(progress.stage)
            }
            guard LocalASREnvironment.shared.isReady(engine: engine) else {
                throw LocalASREnvironmentError.pipInstallFailed(L10n.t("localASR.installIncomplete"))
            }
        }
        guard let scriptPath = Bundle.main.path(forResource: "asr_server", ofType: "py") else {
            NSLog("[LocalASRProcessManager] asr_server.py not found in bundle")
            throw LocalASRProcessError.launchFailed("找不到 asr_server.py")
        }
        NSLog("[LocalASRProcessManager] script path: \(scriptPath)")
        let port = try Self.findFreePort()
        NSLog("[LocalASRProcessManager] assigned port: \(port)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: LocalASREnvironment.shared.pythonExecutablePath)
        // --chunk-ms selects which nemotron export the sidecar loads; each
        // chunk size is a separate ~650 MB model file.
        var arguments = [scriptPath, "--port", "\(port)",
                         "--chunk-ms", LocalEngineLatency.current.rawValue]
        // The model is multilingual, so this is only the default language hint
        // for connections that do not send their own `config` frame.
        if let language, !language.isEmpty, language != "auto" {
            arguments += ["--language", language]
        }
        // Force unbuffered stdout so the READY marker arrives as soon as the
        // model finishes loading rather than sitting in Python's block buffer.
        // Weights live in the default ~/.cache/huggingface location.
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr
        self.process = process
        self.stderrPipe = stderr
        self.stdoutPipe = stdout

        let activity = SidecarHandshake.ActivityClock()
        // asr_server.py's dependencies (torch/FunASR model loading, tqdm
        // progress bars, library warnings) write heavily to stderr. If
        // nothing reads this pipe, its buffer fills up and the Python
        // process blocks on write() forever — which looks like a dead
        // socket on the Swift side minutes later. Drain it continuously.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Feeds the handshake watchdog: while the first-run weights come
            // down, huggingface_hub's progress bars are the only traffic
            // anywhere, and a silent 950 MB fetch must not read as a stall.
            activity.touch()
            guard let text = String(data: data, encoding: .utf8) else { return }
            NSLog("[asr_server stderr] \(text)")
        }

        // The sidecar now outlives a single recording, so a crash or force-quit
        // of the app would otherwise leave it running with several GB of models
        // resident. Have it watch for its parent disappearing and exit, which
        // covers the paths applicationWillTerminate cannot.
        process.arguments = arguments + ["--exit-with-parent", "\(getpid())"]

        NSLog("[LocalASRProcessManager] launching process...")
        do {
            try process.run()
            NSLog("[LocalASRProcessManager] process.run() succeeded, pid=\(process.processIdentifier)")
        } catch {
            NSLog("[LocalASRProcessManager] process.run() failed: \(error)")
            throw LocalASRProcessError.launchFailed(error.localizedDescription)
        }
        SidecarRegistry.shared.register(process.processIdentifier)

        NSLog("[LocalASRProcessManager] waiting for READY marker...")
        do {
            _ = try await SidecarHandshake.waitForReady(
                pipe: stdout,
                readyLine: "READY port=\(port)",
                process: process,
                activity: activity,
                stageMessage: { counter, key in
                    "\(L10n.t("localASR.stage.\(key)")) (\(counter))"
                },
                onProgress: onProgress)
        } catch {
            // Nothing else can reap this child: the warm pool only adopts the
            // manager once start() returns, so a throw here used to leave a
            // ~2 GB Python process running for the life of the app.
            SidecarRegistry.shared.unregister(process.processIdentifier)
            await Self.terminateQuickly(process, name: "asr_server")
            stderr.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.stderrPipe = nil
            self.stdoutPipe = nil
            throw Self.mapHandshakeFailure(error)
        }
        // The handshake reader is gone, so keep stdout drained by hand: a late
        // print from a library would otherwise fill the 64 KB pipe and block
        // the sidecar in write() forever, looking exactly like a dead engine.
        stdout.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        NSLog("[LocalASRProcessManager] sidecar ready at \(url)")
        return url
    }

    private static func mapHandshakeFailure(_ error: Error) -> Error {
        guard let failure = error as? SidecarHandshake.Failure else { return error }
        switch failure {
        case .modelLoadFailed: return LocalASRProcessError.launchFailed(L10n.t("localASR.modelLoadFailed"))
        case .exitedEarly: return LocalASRProcessError.launchFailed(L10n.t("localASR.exitedEarly"))
        case .stalled: return LocalASRProcessError.readyTimeout
        }
    }

    /// Whether the sidecar is still alive. The warm pool checks this before
    /// handing out its URL, since the process can die between recordings.
    var isRunning: Bool {
        process?.isRunning ?? false
    }

    func shutdown() async {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        guard let process else { return }
        self.process = nil
        SidecarRegistry.shared.unregister(process.processIdentifier)
        guard process.isRunning else { return }
        await Self.terminateQuickly(process, name: "asr_server")
    }

    /// SIGTERM, a short grace period, then SIGKILL. The sidecar holds nothing
    /// that needs flushing, so there is no reason to wait for it: this used to
    /// sleep a fixed two seconds, and with the translator doing the same, ⌘Q
    /// blocked the app for four seconds and people force-quit it.
    static func terminateQuickly(_ process: Process, name: String) async {
        process.terminate()
        for _ in 0..<6 where process.isRunning {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            NSLog("[\(name)] did not exit on SIGTERM within 300ms, sending SIGKILL")
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func findFreePort() throws -> UInt16 {
        // Bind to port 0 to let the OS assign a free ephemeral port, then close and reuse the number.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalASRProcessError.portUnavailable }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw LocalASRProcessError.portUnavailable }
        var actualAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &actualAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard gotName == 0 else { throw LocalASRProcessError.portUnavailable }
        return UInt16(bigEndian: actualAddr.sin_port)
    }
}
