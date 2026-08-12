import Foundation

enum LocalASREngineKind: String, Equatable {
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
        // nemotron-asr-mlx requires >= 3.10; macOS's built-in /usr/bin/python3
        // is 3.9 and shows up as "No matching distribution" otherwise.
        case .pythonNotFound: return "需要 Python 3.10 或更高版本。请先安装（推荐：brew install python）后重试。"
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
                        try createVenv(systemPython, continuation)
                    } else if !Self.pythonIsUsable(pythonBinURL.path) {
                        // The venv was created with a too-old interpreter (e.g.
                        // macOS 3.9) and can never satisfy nemotron-asr-mlx.
                        // Rebuild it rather than failing pip forever.
                        continuation.yield(InstallProgress(stage: L10n.t("localASR.creatingVenv"),
                                                          fraction: nil))
                        try FileManager.default.removeItem(at: venvURL)
                        try createVenv(systemPython, continuation)
                    }
                    continuation.yield(InstallProgress(stage: L10n.t("localASR.installDeps"),
                                                      fraction: nil))
                    let reqPath = Bundle.main.path(forResource: "requirements-\(engine.rawValue)", ofType: "txt")
                    guard let reqPath else {
                        throw LocalASREnvironmentError.pipInstallFailed("缺少 requirements 文件")
                    }
                    // Installing torch pulls hundreds of MB and can run for
                    // minutes. Stream pip's progress out so the UI can show
                    // which package is downloading instead of freezing.
                    try Self.run(pythonBinURL.path,
                                 ["-m", "pip", "install", "--progress-bar", "off", "-r", reqPath]) { line in
                        guard let package = Self.installingPackageName(from: line) else { return }
                        continuation.yield(InstallProgress(
                            stage: "\(L10n.t("localASR.installDeps")) \(package)", fraction: nil))
                    }
                    let marker = venvURL.appendingPathComponent(".installed-\(engine.rawValue)")
                    FileManager.default.createFile(atPath: marker.path, contents: nil)
                    continuation.yield(InstallProgress(stage: L10n.t("localASR.installDone"),
                                                      fraction: 1.0))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func createVenv(_ systemPython: String,
                            _ continuation: AsyncThrowingStream<InstallProgress, Error>.Continuation) throws {
        continuation.yield(InstallProgress(stage: L10n.t("localASR.creatingVenv"), fraction: nil))
        try FileManager.default.createDirectory(at: venvURL, withIntermediateDirectories: true)
        try Self.run(systemPython, ["-m", "venv", venvURL.path])
    }

    /// Minimum interpreter version the dependency set supports: nemotron-asr-mlx
    /// requires Python >= 3.10, funasr/torch are fine with 3.10 too.
    private static let minimumPythonVersion = (major: 10, minor: 0)

    /// Locates the newest usable Python 3.10+ interpreter. Searches way beyond
    /// the obvious locations: macOS's built-in /usr/bin/python3 is 3.9 and must
    /// be rejected even though it exists.
    private static func findSystemPython() -> String? {
        var candidates: [String] = []
        let versionedRoots = ["/opt/homebrew/bin", "/usr/local/bin"]
        for root in versionedRoots {
            candidates.append("\(root)/python3")
            for minor in stride(from: 14, through: 10, by: -1) {
                candidates.append("\(root)/python3.\(minor)")
            }
        }
        for minor in stride(from: 14, through: 10, by: -1) {
            candidates.append("/Library/Frameworks/Python.framework/Versions/3.\(minor)/bin/python3")
        }
        candidates.append("/Library/Frameworks/Python.framework/Versions/Current/bin/python3")
        let home = NSHomeDirectory()
        candidates += [
            "\(home)/.pyenv/shims/python3",
            "\(home)/.local/bin/python3",
            "\(home)/miniconda3/bin/python3",
            "\(home)/miniforge3/bin/python3",
            "\(home)/mambaforge/bin/python3",
            "\(home)/anaconda3/bin/python3",
            "/usr/bin/python3",
        ]

        var best: (version: (major: Int, minor: Int), path: String)?
        for path in candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let version = pythonVersion(of: path) else { continue }
            guard version >= minimumPythonVersion else { continue }
            if best == nil || version > best!.version {
                best = (version, path)
            }
        }
        return best?.path
    }

    /// True when the interpreter at `path` satisfies the dependency set.
    private static func pythonIsUsable(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path),
              let version = pythonVersion(of: path) else { return false }
        return version >= minimumPythonVersion
    }

    /// Runs `<python> --version` and parses the major/minor pair, or nil if the
    /// binary isn't runnable. Some builds print to stderr, so both pipes count.
    private static func pythonVersion(of executable: String) -> (major: Int, minor: Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let outputs = [String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                       String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""]
        for text in outputs {
            let parts = text.split(separator: " ")
            guard parts.count >= 2, parts[0].lowercased() == "python" else { continue }
            let numbers = parts[1].split(separator: ".")
            guard numbers.count >= 2,
                  let major = Int(numbers[0]), let minor = Int(numbers[1]) else { continue }
            return (major, minor)
        }
        return nil
    }

    /// Runs a subprocess to completion, forwarding each stdout line to
    /// `onOutput`. Both pipes must be drained while the process runs: pip writes
    /// enough output to fill a pipe buffer and deadlock if nothing reads it.
    private static func run(_ launchPath: String,
                            _ arguments: [String],
                            onOutput: ((String) -> Void)? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe

        let collected = OutputCollector()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where !line.isEmpty {
                onOutput?(String(line))
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collected.append(text)
        }

        try process.run()
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        if process.terminationStatus != 0 {
            let msg = collected.text.isEmpty ? "unknown error" : collected.text
            throw LocalASREnvironmentError.pipInstallFailed(String(msg.suffix(2000)))
        }
    }

    /// Absolute path to the Python executable inside the venv, for LocalASRProcessManager.
    var pythonExecutablePath: String { pythonBinURL.path }

    /// Extracts a package name from pip's "Collecting torch (from ...)" or
    /// "Downloading torch-2.x..." lines, for display during a long install.
    static func installingPackageName(from line: String) -> String? {
        for prefix in ["Collecting ", "Downloading ", "Installing collected packages: "] {
            guard line.hasPrefix(prefix) else { continue }
            let rest = line.dropFirst(prefix.count)
            if prefix.hasPrefix("Installing collected") {
                return String(rest.prefix(60))
            }
            // Stop at the first version specifier or whitespace.
            var name = String(rest.prefix { !" <>=!~(".contains($0) })
            // "Downloading" reports a wheel filename ("torch-2.13.0-cp314.whl"),
            // so trim it back to the distribution name.
            if let dash = name.firstIndex(of: "-"),
               name.hasSuffix(".whl") || name.hasSuffix(".tar.gz") {
                name = String(name[name.startIndex..<dash])
            }
            return name.isEmpty ? nil : name
        }
        return nil
    }
}

/// Thread-safe accumulator for a subprocess's stderr, which arrives on the
/// pipe's callback queue while the caller blocks in `waitUntilExit`.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ text: String) {
        lock.lock()
        buffer += text
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
