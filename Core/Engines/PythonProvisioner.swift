import Foundation

enum PythonProvisionError: Error, LocalizedError {
    case unsupportedArchitecture
    case downloadFailed(String)
    case checksumMismatch
    case extractFailed(String)
    case unusableAfterInstall

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return L10n.t("localASR.python.intelUnsupported")
        case .downloadFailed(let msg):
            return "\(L10n.t("localASR.python.downloadFailed")): \(msg)"
        case .checksumMismatch:
            return L10n.t("localASR.python.checksumMismatch")
        case .extractFailed(let msg):
            return "\(L10n.t("localASR.python.extractFailed")): \(msg)"
        case .unusableAfterInstall:
            return L10n.t("localASR.python.unusableAfterInstall")
        }
    }
}

/// Downloads a self-contained CPython into Application Support when the machine
/// has no usable system interpreter.
///
/// The app previously told the user to go run `brew install python` and try
/// again, which is fine for a developer and useless for anyone the app is
/// distributed to. Provisioning a runtime is the app's job, not theirs.
///
/// Uses astral-sh/python-build-standalone: relocatable, self-contained builds
/// with no dependency on Homebrew or the Xcode command line tools. Pinned to an
/// exact release and verified by SHA-256 — this writes an executable to disk and
/// then runs it, so an unpinned "latest" URL would mean trusting whatever that
/// tag happens to point at later.
struct PythonProvisioner {
    static let shared = PythonProvisioner()

    // Pinned release. Bump both fields together; the digest comes from the
    // release asset's own `digest` field on the GitHub API.
    private static let releaseTag = "20260814"
    private static let archiveName =
        "cpython-3.12.14+20260814-aarch64-apple-darwin-install_only.tar.gz"
    private static let sha256 =
        "4572133a5542f306b9bdb155da5800f9e38950cd0a98d469b832ce256fe299ea"
    private static let expectedBytes: Int64 = 25_151_480

    private static var downloadURL: URL {
        URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/"
            + "\(releaseTag)/\(archiveName)")!
    }

    /// Where the extracted runtime lives. Kept beside the venv so removing
    /// Application Support cleans up everything the app provisioned.
    private var rootURL: URL {
        AppBootstrap.applicationSupportURL
            .appendingPathComponent("python-runtime", isDirectory: true)
    }

    var interpreterURL: URL {
        rootURL.appendingPathComponent("python/bin/python3")
    }

    /// True once a previously provisioned runtime is present and runnable.
    var isProvisioned: Bool {
        FileManager.default.isExecutableFile(atPath: interpreterURL.path)
    }

    /// Returns a usable interpreter path, downloading one if needed.
    func provision(onProgress: @escaping @Sendable (String, Double?) -> Void) async throws -> String {
        if isProvisioned { return interpreterURL.path }

        #if arch(arm64)
        #else
        // MLX needs Apple Silicon anyway, so there is no useful x86_64 build to
        // fall back to — say so plainly rather than downloading 24 MB first.
        throw PythonProvisionError.unsupportedArchitecture
        #endif

        let archive = try await download(onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: archive) }

        onProgress(L10n.t("localASR.python.verifying"), nil)
        try verify(archive)

        onProgress(L10n.t("localASR.python.extracting"), nil)
        try extract(archive)

        guard isProvisioned else { throw PythonProvisionError.unusableAfterInstall }
        return interpreterURL.path
    }

    private func download(onProgress: @escaping @Sendable (String, Double?) -> Void) async throws -> URL {
        onProgress(L10n.t("localASR.python.downloading"), 0)
        let (temp, response) = try await URLSession.shared.download(from: Self.downloadURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PythonProvisionError.downloadFailed("HTTP \(http.statusCode)")
        }
        // The download lands in a temp dir that URLSession may reap; move it
        // somewhere we control before hashing.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("classnote-python-\(UUID().uuidString).tar.gz")
        try FileManager.default.moveItem(at: temp, to: staged)
        onProgress(L10n.t("localASR.python.downloading"), 1.0)
        return staged
    }

    private func verify(_ archive: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
        guard size == Self.expectedBytes else {
            throw PythonProvisionError.checksumMismatch
        }
        // Hash in chunks: loading 24 MB into memory just to digest it is wasteful
        // and the file only grows with future pins.
        guard let digest = Self.sha256OfFile(archive) else {
            throw PythonProvisionError.checksumMismatch
        }
        guard digest == Self.sha256 else {
            NSLog("[PythonProvisioner] checksum mismatch: got \(digest)")
            throw PythonProvisionError.checksumMismatch
        }
    }

    private func extract(_ archive: URL) throws {
        try? FileManager.default.removeItem(at: rootURL)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", rootURL.path]
        let err = Pipe()
        process.standardError = err
        do { try process.run() } catch {
            throw PythonProvisionError.extractFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8) ?? ""
            throw PythonProvisionError.extractFailed(text.isEmpty ? "tar failed" : text)
        }
    }

    /// Streams the file through `shasum` rather than pulling in CryptoKit's
    /// incremental API, keeping this file free of extra imports.
    static func sha256OfFile(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        return text.split(separator: " ").first.map(String.init)
    }
}
