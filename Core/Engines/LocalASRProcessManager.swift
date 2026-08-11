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

    init(engine: LocalASREngineKind) {
        self.engine = engine
    }

    /// Spawns the sidecar and waits for its READY marker on stdout, returns the ws URL.
    func start() async throws -> URL {
        guard LocalASREnvironment.shared.isReady(engine: engine) else {
            throw LocalASREnvironmentError.pipInstallFailed("环境未安装")
        }
        guard let scriptPath = Bundle.main.path(forResource: "asr_server", ofType: "py") else {
            throw LocalASRProcessError.launchFailed("找不到 asr_server.py")
        }
        let port = try Self.findFreePort()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: LocalASREnvironment.shared.pythonExecutablePath)
        process.arguments = [scriptPath, "--engine", engine.rawValue, "--port", "\(port)"]
        let stdout = Pipe()
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr
        self.process = process

        do {
            try process.run()
        } catch {
            throw LocalASRProcessError.launchFailed(error.localizedDescription)
        }

        try await Self.waitForReady(pipe: stdout, expectedPort: port)
        return URL(string: "ws://127.0.0.1:\(port)")!
    }

    func shutdown() async {
        process?.terminate()
        process = nil
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
