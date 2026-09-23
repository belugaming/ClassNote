import Foundation

/// Every model (and the Python runtime) the local engines put on disk, with
/// what it is for, how big it is and how to get rid of it.
///
/// Settings lists these so a user can see what "Download" is about to fetch
/// and reclaim the space afterwards; before this the app downloaded several
/// gigabytes under names nobody was shown and offered no way to remove them.
struct LocalModel: Identifiable, Sendable, Hashable {
    enum Role: String, Sendable, CaseIterable {
        case recognition, punctuation, translation, notes, runtime
    }

    let id: String
    /// Human name, e.g. "Confucius4-R2T2 1.7B".
    let name: String
    /// Where it comes from: a Hugging Face repo, or what it was built from.
    let source: String
    let role: Role
    /// Roughly how much it takes on disk, for before it is there.
    let approxBytes: Int64
    /// Everything that belongs to it. Deleting the model removes these.
    let locations: [URL]
    /// One line on what uses it, localized key.
    let usageKey: String

    var isInstalled: Bool {
        locations.contains { url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
            guard isDir.boolValue else { return true }
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return !contents.isEmpty
        }
    }
}

enum LocalModelCatalog {
    static let nemotronRepoTemplate =
        "csukuangfj2/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-%@ms-int8-2026-06-11"
    static let punctuationRepo = "csukuangfj/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12"
    static let r2t2Repo = "mlx-community/Confucius4-R2T2-8bit"

    private static let gb: Int64 = 1_000_000_000
    private static let mb: Int64 = 1_000_000

    static var all: [LocalModel] {
        var models: [LocalModel] = []
        for latency in LocalEngineLatency.allCases {
            let repo = String(format: nemotronRepoTemplate, latency.rawValue)
            models.append(LocalModel(
                id: "nemotron-\(latency.rawValue)",
                name: "Nemotron 3.5 Streaming ASR 0.6B · \(latency.title)",
                source: repo,
                role: .recognition,
                approxBytes: 650 * mb,
                locations: [HuggingFaceCache.repoURL(repo)],
                usageKey: "models.usage.nemotron"))
        }
        models.append(LocalModel(
            id: "punctuation",
            name: "CT-Transformer Punctuation (zh/en)",
            source: punctuationRepo,
            role: .punctuation,
            approxBytes: 300 * mb,
            locations: [HuggingFaceCache.repoURL(punctuationRepo)],
            usageKey: "models.usage.punctuation"))
        models.append(LocalModel(
            id: "r2t2",
            name: "Confucius4-R2T2 1.7B · 8-bit",
            source: r2t2Repo,
            role: .recognition,
            approxBytes: 2_400 * mb,
            locations: [HuggingFaceCache.repoURL(r2t2Repo)],
            usageKey: "models.usage.r2t2"))
        models.append(LocalModel(
            id: "hymt2",
            name: "Hy-MT2 1.8B · 4-bit",
            source: LocalMLXTranslatorProcess.modelRepo,
            role: .translation,
            approxBytes: 1 * gb,
            locations: [HuggingFaceCache.repoURL(LocalMLXTranslatorProcess.modelRepo)],
            usageKey: "models.usage.hymt2"))
        models.append(LocalModel(
            id: "t3po",
            name: "Confucius4-T3PO 14B · 4-bit",
            source: SimulTranslatorProcess.sourceRepo,
            role: .translation,
            approxBytes: 8_300 * mb,
            // The converted model, plus the bf16 download in case a
            // conversion was interrupted and left it behind.
            locations: [SimulTranslatorProcess.modelDirectory,
                         URL(fileURLWithPath: SimulTranslatorProcess.modelDirectory.path + ".partial"),
                         HuggingFaceCache.repoURL(SimulTranslatorProcess.sourceRepo)],
            usageKey: "models.usage.t3po"))
        models.append(LocalModel(
            id: "qwen3",
            name: "Qwen3 4B Instruct 2507 · 4-bit",
            source: LocalMLXLLMProcess.modelRepo,
            role: .notes,
            approxBytes: 2_400 * mb,
            locations: [HuggingFaceCache.repoURL(LocalMLXLLMProcess.modelRepo)],
            usageKey: "models.usage.qwen3"))
        models.append(LocalModel(
            id: "runtime",
            name: "Python runtime + packages",
            source: "sherpa-onnx, mlx, mlx-lm, mlx-audio",
            role: .runtime,
            approxBytes: 1_200 * mb,
            locations: [AppBootstrap.applicationSupportURL.appendingPathComponent("pyenv", isDirectory: true),
                        AppBootstrap.applicationSupportURL.appendingPathComponent("python-runtime",
                                                                                   isDirectory: true)],
            usageKey: "models.usage.runtime"))
        return models
    }

    static func model(id: String) -> LocalModel? {
        all.first { $0.id == id }
    }

    /// The Nemotron export the current latency setting loads.
    static var currentNemotron: LocalModel? {
        model(id: "nemotron-\(LocalEngineLatency.current.rawValue)")
    }

    /// Bytes on disk, following the Hugging Face cache's symlinks into its
    /// blob store so a snapshot is not counted as a few kilobytes of links.
    static func diskSize(of model: LocalModel) async -> Int64 {
        await Task.detached(priority: .utility) {
            model.locations.reduce(Int64(0)) { $0 + directorySize($1) }
        }.value
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                             options: []) else { return 0 }
        var total: Int64 = 0
        var seen = Set<String>()
        for case let file as URL in enumerator {
            // Snapshots link into blobs/; counting both would double the size,
            // so only real files are summed, each once.
            let resolved = file.resolvingSymlinksInPath()
            guard seen.insert(resolved.path).inserted,
                  let values = try? resolved.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    enum DeleteError: Error, LocalizedError {
        case recording
        case inUse

        var errorDescription: String? {
            switch self {
            case .recording: return L10n.t("models.delete.recording")
            case .inUse: return L10n.t("models.delete.inUse")
            }
        }
    }

    /// Stops whatever has the model loaded, then removes it from disk.
    @MainActor
    static func delete(_ model: LocalModel) async throws {
        guard !AppState.shared.isRecording else { throw DeleteError.recording }
        // An import still needs its engines; stopping one under it would just
        // relaunch it and download the model that is being deleted.
        guard !AppState.shared.hasActiveImports else { throw DeleteError.inUse }
        try await stopUsers(of: model)
        if model.role == .recognition || model.role == .punctuation || model.role == .runtime {
            AppState.shared.isLocalEngineReady = false
        }
        for url in model.locations where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    @MainActor
    private static func stopUsers(of model: LocalModel) async throws {
        switch model.role {
        case .recognition, .punctuation:
            guard await LocalASRWarmPool.shared.retire() else { throw DeleteError.inUse }
        case .translation:
            if model.id == "t3po" {
                await SimulTranslatorProcess.shared.shutdown()
            } else {
                await LocalMLXTranslatorProcess.shared.shutdown()
            }
        case .notes:
            await LocalMLXLLMProcess.shared.shutdown()
        case .runtime:
            guard await LocalASRWarmPool.shared.retire() else { throw DeleteError.inUse }
            await LocalMLXTranslatorProcess.shared.shutdown()
            await SimulTranslatorProcess.shared.shutdown()
            await LocalMLXLLMProcess.shared.shutdown()
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
