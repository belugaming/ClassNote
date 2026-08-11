import Foundation

enum LocalASRProcessError: Error, LocalizedError {
    case launchFailed(String)
    case readyTimeout
    case portUnavailable

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return "本地引擎启动失败: \(msg)"
        case .readyTimeout: return "本地引擎启动超时"
        case .portUnavailable: return "无法找到可用端口"
        }
    }
}

/// Owns the lifecycle of one asr_server.py child process. One instance per
/// live session using a local engine; not shared/reused across sessions.
actor LocalASRProcessManager {
    private let engine: LocalASREngineKind
    private var process: Process?
    private var stderrPipe: Pipe?

    init(engine: LocalASREngineKind) {
        self.engine = engine
    }

    /// Spawns the sidecar and waits for its READY marker on stdout, returns the ws URL.
    func start() async throws -> URL {
        NSLog("[LocalASRProcessManager] start() called for engine=\(engine.rawValue)")
        guard LocalASREnvironment.shared.isReady(engine: engine) else {
            NSLog("[LocalASRProcessManager] environment not ready")
            throw LocalASREnvironmentError.pipInstallFailed("环境未安装")
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
        // --device auto lets the sidecar pick MPS for the streaming pass when
        // the GPU is available; it keeps the offline pass on CPU, which measured
        // faster for short utterances.
        process.arguments = [scriptPath, "--engine", engine.rawValue, "--port", "\(port)",
                             "--device", "auto"]
        // Force unbuffered stdout so the READY marker arrives as soon as the
        // models finish loading rather than sitting in Python's block buffer.
        // Model weights stay in the default ~/.cache/modelscope location, which
        // is shared with any other FunASR install the user already has.
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr
        self.process = process
        self.stderrPipe = stderr

        // asr_server.py's dependencies (torch/FunASR model loading, tqdm
        // progress bars, library warnings) write heavily to stderr. If
        // nothing reads this pipe, its buffer fills up and the Python
        // process blocks on write() forever — which looks like a dead
        // socket on the Swift side minutes later. Drain it continuously.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            NSLog("[asr_server stderr] \(text)")
        }

        NSLog("[LocalASRProcessManager] launching process...")
        do {
            try process.run()
            NSLog("[LocalASRProcessManager] process.run() succeeded, pid=\(process.processIdentifier)")
        } catch {
            NSLog("[LocalASRProcessManager] process.run() failed: \(error)")
            throw LocalASRProcessError.launchFailed(error.localizedDescription)
        }

        NSLog("[LocalASRProcessManager] waiting for READY marker...")
        try await Self.waitForReady(pipe: stdout, expectedPort: port)
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        NSLog("[LocalASRProcessManager] sidecar ready at \(url)")
        return url
    }

    func shutdown() async {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        self.process = nil
        process.terminate()
        // SIGTERM can be swallowed while Python sits inside a blocking torch
        // call, leaving an orphan holding a port and several GB of weights.
        // Give it a moment, then make sure it is gone.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if process.isRunning {
            NSLog("[LocalASRProcessManager] sidecar ignored SIGTERM, sending SIGKILL")
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

    private static func waitForReady(pipe: Pipe, expectedPort: UInt16) async throws {
        let handle = pipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(20)
        var pending = Data()
        while Date() < deadline {
            let chunk = handle.availableData
            if !chunk.isEmpty {
                pending.append(chunk)
                if let text = String(data: pending, encoding: .utf8),
                   text.contains("READY port=\(expectedPort)") {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LocalASRProcessError.readyTimeout
    }
}
