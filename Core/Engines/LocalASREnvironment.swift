import Foundation

enum LocalASREngineKind: String {
    case funasr, nemotron
}

struct InstallProgress: Sendable {
    let stage: String
    let fraction: Double?
}

enum LocalASREnvironmentError: Error, LocalizedError {
    case pythonNotFound
    case pipInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound: return "未找到 python3。请先安装 Python 3。"
        case .pipInstallFailed(let msg): return "依赖安装失败: \(msg)"
        }
    }
}

/// Manages a dedicated venv under Application Support for local ASR sidecars.
/// Keeps ClassNote's own dependency set isolated from any system Python.
struct LocalASREnvironment {
    static let shared = LocalASREnvironment()

    private var venvURL: URL {
        AppBootstrap.applicationSupportURL.appendingPathComponent("pyenv", isDirectory: true)
    }

    var pythonBinURL: URL {
        venvURL.appendingPathComponent("bin/python3")
    }

    func isReady(engine: LocalASREngineKind) -> Bool {
        guard FileManager.default.fileExists(atPath: pythonBinURL.path) else { return false }
        let marker = venvURL.appendingPathComponent(".installed-\(engine.rawValue)")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    func install(engine: LocalASREngineKind) -> AsyncThrowingStream<InstallProgress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let systemPython = Self.findSystemPython() else {
                        throw LocalASREnvironmentError.pythonNotFound
                    }
                    if !FileManager.default.fileExists(atPath: pythonBinURL.path) {
                        continuation.yield(InstallProgress(stage: "创建虚拟环境…", fraction: nil))
                        try FileManager.default.createDirectory(at: venvURL, withIntermediateDirectories: true)
                        try Self.run(systemPython, ["-m", "venv", venvURL.path])
                    }
                    continuation.yield(InstallProgress(stage: "安装依赖包…", fraction: nil))
                    let reqPath = Bundle.main.path(forResource: "requirements-\(engine.rawValue)", ofType: "txt")
                    guard let reqPath else {
                        throw LocalASREnvironmentError.pipInstallFailed("缺少 requirements 文件")
                    }
                    try Self.run(pythonBinURL.path, ["-m", "pip", "install", "-r", reqPath])
                    let marker = venvURL.appendingPathComponent(".installed-\(engine.rawValue)")
                    FileManager.default.createFile(atPath: marker.path, contents: nil)
                    continuation.yield(InstallProgress(stage: "完成", fraction: 1.0))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func findSystemPython() -> String? {
        for candidate in ["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func run(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            throw LocalASREnvironmentError.pipInstallFailed(msg)
        }
    }

    /// Absolute path to the Python executable inside the venv, for LocalASRProcessManager.
    var pythonExecutablePath: String { pythonBinURL.path }
}
