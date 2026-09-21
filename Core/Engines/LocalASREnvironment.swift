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
        // No longer reachable from install(): PythonProvisioner downloads a
        // runtime when the machine has none, so the user is never asked to go
        // install Python themselves. Kept as a distinct case for the paths that
        // only probe for an interpreter.
        case .pythonNotFound: return L10n.t("localASR.python.notFound")
        case .pipInstallFailed(let msg): return "\(L10n.t("localASR.installFailed")): \(msg)"
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

    /// Bumped whenever the requirements files change in a way an existing venv
    /// cannot satisfy, so that install() runs again instead of the sidecar
    /// failing on an import. 2: sherpa-onnx replaced mlx-audio. 3: pinned exact
    /// versions, so a venv built from the floating set is a different program.
    static let requirementsGeneration = 3

    private func installMarkerURL(engine: LocalASREngineKind) -> URL {
        venvURL.appendingPathComponent(".installed-\(engine.rawValue)-v\(Self.requirementsGeneration)")
    }

    func isReady(engine: LocalASREngineKind) -> Bool {
        guard FileManager.default.fileExists(atPath: pythonBinURL.path) else { return false }
        return FileManager.default.fileExists(atPath: installMarkerURL(engine: engine).path)
    }

    func install(engine: LocalASREngineKind) -> AsyncThrowingStream<InstallProgress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Prefer whatever the machine already has; only download a
                    // runtime when there is nothing usable. Telling the user to
                    // go install Python themselves is not an option for a
                    // distributed build.
                    let systemPython: String
                    if let found = Self.findSystemPython() {
                        systemPython = found
                    } else {
                        systemPython = try await PythonProvisioner.shared.provision { stage, fraction in
                            continuation.yield(InstallProgress(stage: stage, fraction: fraction))
                        }
                    }
                    let venvExists = FileManager.default.fileExists(atPath: venvURL.path)
                    if Self.needsRebuild(pythonBinPath: pythonBinURL.path, venvExists: venvExists) {
                        if venvExists {
                            continuation.yield(InstallProgress(stage: L10n.t("localASR.creatingVenv"),
                                                              fraction: nil))
                            try FileManager.default.removeItem(at: venvURL)
                        }
                        try createVenv(systemPython, continuation)
                    }
                    continuation.yield(InstallProgress(stage: L10n.t("localASR.installDeps"),
                                                      fraction: nil))
                    let reqPath = Bundle.main.path(forResource: "requirements-\(engine.rawValue)", ofType: "txt")
                    guard let reqPath else {
                        throw LocalASREnvironmentError.pipInstallFailed("缺少 requirements 文件")
                    }
                    // sherpa-onnx and mlx-lm together pull a few hundred MB and
                    // can run for minutes. Stream pip's progress out so the UI
                    // can show which package is downloading instead of freezing.
                    // --no-input so a prompt (a keyring unlock, an index
                    // credential) can never park the install forever behind a
                    // question nobody can see.
                    try Self.run(pythonBinURL.path,
                                 ["-m", "pip", "install", "--no-input",
                                  "--disable-pip-version-check",
                                  "--progress-bar", "off", "-r", reqPath]) { line in
                        guard let package = Self.installingPackageName(from: line) else { return }
                        continuation.yield(InstallProgress(
                            stage: "\(L10n.t("localASR.installDeps")) \(package)", fraction: nil))
                    }
                    FileManager.default.createFile(atPath: installMarkerURL(engine: engine).path,
                                                   contents: nil)
                    continuation.yield(InstallProgress(stage: L10n.t("localASR.installDone"),
                                                      fraction: 1.0))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Whether the venv has to be thrown away and rebuilt rather than reused.
    ///
    /// A venv's `bin/python3` is a symlink to the interpreter it was built from.
    /// If that interpreter is gone the link dangles, and `python -m venv` over
    /// the existing directory will not repair it — `venv` skips any destination
    /// that is already a symlink, exits 0, and pip then fails with a bare ENOENT
    /// forever. So anything short of a usable interpreter means: remove the
    /// directory and build a new one. `pythonIsUsable` covers missing, dangling
    /// and too-old with one predicate.
    ///
    /// Split out from `install` so the decision is testable without touching the
    /// real Application Support directory.
    static func needsRebuild(pythonBinPath: String, venvExists: Bool) -> Bool {
        guard venvExists else { return true }
        return !pythonIsUsable(pythonBinPath)
    }

    private func createVenv(_ systemPython: String,
                            _ continuation: AsyncThrowingStream<InstallProgress, Error>.Continuation) throws {
        continuation.yield(InstallProgress(stage: L10n.t("localASR.creatingVenv"), fraction: nil))
        try FileManager.default.createDirectory(at: venvURL, withIntermediateDirectories: true)
        // --clear empties an existing environment first, so a directory that a
        // failed removal left half there still converges.
        try Self.run(systemPython, ["-m", "venv", "--clear", venvURL.path])
    }

    /// Minimum interpreter version the pinned dependency set supports:
    /// `websockets==17.1` and `numpy==2.4.6` both require Python >= 3.11 (see
    /// Scripts/requirements-nemotron.txt). Raise this together with the pins.
    ///
    /// This read `(major: 10, minor: 0)` — i.e. "Python 10.0" — while
    /// `pythonVersion(of:)` returns `(3, 14)` for Python 3.14. Tuple comparison
    /// made `(3, anything) >= (10, 0)` false, so *every* Python 3 interpreter was
    /// rejected and the local engine could not be installed on any machine. See
    /// `PythonVersionGateTests`.
    static let minimumPythonVersion = (major: 3, minor: 11)

    /// Whether an interpreter reporting `version` can run the dependency set.
    /// Split out so the gate is testable without a real interpreter on disk.
    static func isVersionSupported(_ version: (major: Int, minor: Int)) -> Bool {
        version >= minimumPythonVersion
    }

    /// Locates the newest usable Python 3.11+ interpreter. Searches way beyond
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
            guard isVersionSupported(version) else { continue }
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
        return isVersionSupported(version)
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
