import SwiftUI

/// Every local model on one page: what it is, what uses it, how big it is,
/// and buttons to download or delete it.
struct ModelsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sizes: [String: Int64] = [:]
    @State private var installed: Set<String> = []
    @State private var busy: Set<String> = []
    @State private var progress: [String: String] = [:]
    @State private var confirmDelete: LocalModel?
    @State private var error: String?

    private var models: [LocalModel] { LocalModelCatalog.all }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                header
                ForEach(LocalModel.Role.allCases, id: \.self) { role in
                    let group = models.filter { $0.role == role }
                    if !group.isEmpty {
                        SettingsSection(title: L10n.t("models.role.\(role.rawValue)")) {
                            ForEach(group) { model in
                                row(model)
                                if model.id != group.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
        .task { await refresh() }
        .alert(L10n.t("models.delete.title"), isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button(L10n.t("common.delete"), role: .destructive) {
                if let model = confirmDelete { Task { await delete(model) } }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            if let model = confirmDelete {
                Text(String(format: L10n.t("models.delete.message"), model.name))
            }
        }
        .alert(L10n.t("common.error"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.t("common.ok")) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("models.title")).font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                Text(L10n.t("models.subtitle"))
                Spacer()
                let total = sizes.values.reduce(0, +)
                if total > 0 {
                    Text(String(format: L10n.t("models.total"), LocalModelCatalog.formatBytes(total)))
                        .monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func row(_ model: LocalModel) -> some View {
        let isInstalled = installed.contains(model.id)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(model.role))
                .font(.system(size: 18))
                .foregroundStyle(isInstalled ? Theme.accent : .secondary)
                .frame(width: 26)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).font(.body.weight(.medium))
                    if isActive(model) {
                        Text(L10n.t("models.inUse")).pill(Theme.accent)
                    }
                }
                Text(L10n.t(model.usageKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.source)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                if let stage = progress[model.id] {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(stage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Text(isInstalled
                     ? LocalModelCatalog.formatBytes(sizes[model.id] ?? 0)
                     : "≈ " + LocalModelCatalog.formatBytes(model.approxBytes))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(isInstalled ? .primary : .secondary)
                if busy.contains(model.id) {
                    ProgressView().controlSize(.small)
                } else if isInstalled {
                    Button(L10n.t("common.delete"), role: .destructive) { confirmDelete = model }
                        .controlSize(.small)
                } else if canDownload(model) {
                    Button(L10n.t("models.download")) { Task { await download(model) } }
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(_ role: LocalModel.Role) -> String {
        switch role {
        case .recognition: return "waveform"
        case .punctuation: return "textformat"
        case .translation: return "character.bubble"
        case .notes: return "text.book.closed"
        case .runtime: return "shippingbox"
        }
    }

    /// Whether the model is the one the current settings would load.
    private func isActive(_ model: LocalModel) -> Bool {
        switch model.id {
        case "r2t2": return appState.sttBackend == .r2t2
        case "punctuation": return appState.sttBackend.localEngine == .funasr
        case "hymt2": return appState.translationBackend == .localMLX || appState.translationBackend == .t3po
        case "t3po": return appState.translationBackend == .t3po
        case "qwen3": return appState.llmBackend == .localMLX
        case "runtime":
            return appState.sttBackend.isLocalSidecar || appState.translationBackend.isLocalSidecar
                || appState.llmBackend.isLocalSidecar
        default:
            return appState.sttBackend.localEngine == .funasr
                && model.id == LocalModelCatalog.currentNemotron?.id
        }
    }

    /// The runtime installs with any model; Nemotron exports other than the
    /// selected latency are only fetched by choosing that latency.
    private func canDownload(_ model: LocalModel) -> Bool {
        switch model.role {
        case .runtime: return false
        case .recognition, .punctuation:
            return model.id == "r2t2" || model.id == "punctuation"
                || model.id == LocalModelCatalog.currentNemotron?.id
        default: return true
        }
    }

    private func refresh() async {
        var sizes: [String: Int64] = [:]
        var installed: Set<String> = []
        for model in models where model.isInstalled {
            installed.insert(model.id)
            sizes[model.id] = await LocalModelCatalog.diskSize(of: model)
        }
        self.sizes = sizes
        self.installed = installed
    }

    private func delete(_ model: LocalModel) async {
        busy.insert(model.id)
        defer { busy.remove(model.id) }
        do {
            try await LocalModelCatalog.delete(model)
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    /// Downloads a model by starting the engine that uses it, which fetches
    /// and loads it the same way a first recording would.
    private func download(_ model: LocalModel) async {
        busy.insert(model.id)
        defer {
            busy.remove(model.id)
            progress[model.id] = nil
        }
        let id = model.id
        let report: @Sendable (String) -> Void = { stage in
            Task { @MainActor in progress[id] = stage }
        }
        do {
            switch model.id {
            case "hymt2":
                try await LocalMLXTranslatorProcess.shared.prewarm(onProgress: report)
            case "t3po":
                try await SimulTranslatorProcess.shared.prewarm(onProgress: report)
            case "qwen3":
                try await LocalMLXLLMProcess.shared.prewarm(onProgress: report)
            case "r2t2":
                await LocalASRWarmPool.shared.preload(engine: .r2t2,
                                                      language: appState.apiConfig.sourceLanguage,
                                                      onProgress: report)
            default:
                await LocalASRWarmPool.shared.preload(engine: .funasr,
                                                      language: appState.apiConfig.sourceLanguage,
                                                      onProgress: report)
            }
        } catch {
            self.error = error.localizedDescription
        }
        await appState.preloadLocalEngine()
        await refresh()
    }
}
