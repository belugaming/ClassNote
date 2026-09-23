import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settingsTab", store: AppEnvironment.defaults) private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases) { item in
                item.content
                    .tabItem { Label(L10n.t(item.titleKey), systemImage: item.icon) }
                    .tag(item.rawValue)
            }
        }
        .frame(width: 720, height: 620)
        .id(appState.languageRefreshToken)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, engines, models, api, shortcuts, about

    var id: String { rawValue }

    var titleKey: String { "settings.tab.\(rawValue)" }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .engines: return "waveform.circle"
        case .models: return "shippingbox"
        case .api: return "network"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .general: GeneralSettingsView()
        case .engines: EngineSettingsView()
        case .models: ModelsSettingsView()
        case .api: ApiSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .about: AboutView()
        }
    }
}

/// A scrolling settings page with the standard padding.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) { content }
                .padding(Theme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Languages

/// The languages offered for lectures and translation. Codes are what the
/// engines take; names are shown in the interface language.
enum LectureLanguage {
    static let codes = ["en", "zh-Hans", "zh-Hant", "yue", "ja", "ko", "fr", "de", "es", "pt", "it",
                        "ru", "ar", "hi", "th", "vi", "id", "tr", "nl", "pl"]

    static func name(_ code: String) -> String {
        if code == "auto" { return L10n.t("language.auto") }
        let locale = Locale(identifier: L10n.isChinese ? "zh-Hans" : "en")
        return locale.localizedString(forIdentifier: code) ?? code
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var uiLanguage: L10n.LanguageOverride = L10n.override
    @AppStorage("overlayCaptionDisplayMode", store: AppEnvironment.defaults) private var displayModeRaw = OverlayCaptionDisplayMode.bilingual.rawValue
    @AppStorage("overlayCaptionTextSize", store: AppEnvironment.defaults) private var textSizeRaw = OverlayCaptionTextSize.medium.rawValue
    @AppStorage("overlayCaptionRecentCount", store: AppEnvironment.defaults) private var recentCountRaw = OverlayCaptionRecentCount.two.rawValue
    @AppStorage("overlayAlwaysOnTop", store: AppEnvironment.defaults) private var overlayAlwaysOnTop = true

    var body: some View {
        SettingsPage {
            SettingsSection(title: L10n.t("settings.languages.title"),
                            footer: L10n.t("settings.languages.footer")) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text(L10n.t("settings.api.source"))
                        Picker("", selection: languageBinding(\.sourceLanguage)) {
                            Text(LectureLanguage.name("auto")).tag("auto")
                            Divider()
                            ForEach(LectureLanguage.codes, id: \.self) { Text(LectureLanguage.name($0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                        // A new language reloads the local engine, which would
                        // end the transcription of a recording running on it.
                        .disabled(appState.isRecording && appState.sttBackend.isLocalSidecar)
                    }
                    GridRow {
                        Text(L10n.t("settings.api.target"))
                        Picker("", selection: languageBinding(\.targetLanguage)) {
                            ForEach(LectureLanguage.codes, id: \.self) { Text(LectureLanguage.name($0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    }
                }
                Toggle(L10n.t("settings.engines.liveTranslationToggle"), isOn: $appState.translationEnabled)
            }

            SettingsSection(title: L10n.t("settings.audio.input"), footer: L10n.t("settings.audio.inputNote")) {
                HStack {
                    Picker(L10n.t("settings.audio.microphone"), selection: $appState.preferredMicrophoneDeviceID) {
                        ForEach(appState.microphoneDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .frame(maxWidth: 360)
                    Button {
                        appState.refreshMicrophoneDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(L10n.t("settings.audio.refresh"))
                }
            }

            SettingsSection(title: L10n.t("settings.appearance.overlay"),
                            footer: L10n.t("settings.appearance.overlayNote")) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text(L10n.t("overlay.displayMode"))
                        Picker("", selection: $displayModeRaw) {
                            ForEach(OverlayCaptionDisplayMode.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    GridRow {
                        Text(L10n.t("overlay.textSize"))
                        Picker("", selection: $textSizeRaw) {
                            ForEach(OverlayCaptionTextSize.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    GridRow {
                        Text(L10n.t("overlay.recentCount"))
                        Picker("", selection: $recentCountRaw) {
                            ForEach(OverlayCaptionRecentCount.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                }
                Toggle(L10n.t("overlay.alwaysOnTop"), isOn: $overlayAlwaysOnTop)
            }

            SettingsSection(title: L10n.t("settings.appearance.language"),
                            footer: L10n.t("settings.appearance.languageNote")) {
                Picker("", selection: $uiLanguage) {
                    ForEach(L10n.LanguageOverride.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .onChange(of: uiLanguage) { _, value in appState.setLanguage(value) }
            }
        }
        .onAppear { appState.refreshMicrophoneDevices() }
    }

    private func languageBinding(_ keyPath: WritableKeyPath<ApiConfig, String>) -> Binding<String> {
        Binding(get: {
            let value = appState.apiConfig[keyPath: keyPath]
            return value.isEmpty ? "auto" : value
        }, set: { newValue in
            var config = appState.apiConfig
            let old = config[keyPath: keyPath]
            config[keyPath: keyPath] = newValue == "auto" ? "" : newValue
            appState.apiConfig = config
            let isSource = keyPath == \ApiConfig.sourceLanguage
            Task {
                await appState.saveConfig(config)
                // The source language decides what the warm sidecar loaded.
                if isSource, old != config.sourceLanguage, appState.sttBackend.isLocalSidecar {
                    await appState.reloadLocalEngine()
                }
            }
        })
    }
}

// MARK: - Engines

/// One choice in an engine picker.
private struct EngineOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let detail: String
    let isLocal: Bool
    var id: Value { value }
}

/// A column of radio cards: each engine with a line on what it is.
private struct EnginePicker<Value: Hashable>: View {
    let options: [EngineOption<Value>]
    @Binding var selection: Value
    var disabled = false

    var body: some View {
        VStack(spacing: 6) {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selection == option.value ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selection == option.value ? Theme.accent : .secondary)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(option.title).font(.body.weight(.medium))
                                Text(L10n.t(option.isLocal ? "engine.badge.local" : "engine.badge.cloud"))
                                    .pill(option.isLocal ? Theme.success : Theme.accent)
                            }
                            Text(option.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                            .fill(selection == option.value ? Theme.accentSoft : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(disabled)
    }
}

struct EngineSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        SettingsPage {
            SettingsSection(title: L10n.t("settings.engines.stt")) {
                EnginePicker(options: sttOptions, selection: $appState.sttBackend, disabled: appState.isRecording)
                if appState.isRecording {
                    Label(L10n.t("settings.engines.lockedWhileRecording"), systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }
                if appState.sttBackend == .funasr { LocalEngineLatencyRow() }
                if appState.sttBackend.isLocalSidecar { LocalEngineStatusRow() }
            }

            SettingsSection(title: L10n.t("settings.engines.translationSection"),
                            footer: L10n.t("settings.engines.liveHelp")) {
                EnginePicker(options: translationOptions, selection: $appState.translationBackend)
                if appState.translationBackend == .t3po,
                   SimulTranslatorProcess.direction(source: appState.apiConfig.sourceLanguage,
                                                    target: appState.apiConfig.targetLanguage) == nil {
                    Label(L10n.t("settings.engines.t3po.pairFallback"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if appState.translationBackend == .t3po,
                   ProcessInfo.processInfo.physicalMemory < 32 * 1_073_741_824 {
                    Label(L10n.t("settings.engines.t3po.memory"), systemImage: "memorychip")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if appState.translationBackend.isLocalSidecar {
                    ModelsLink(ids: appState.translationBackend == .t3po ? ["t3po", "hymt2"] : ["hymt2"])
                }
            }

            SettingsSection(title: L10n.t("settings.engines.llmSection"), footer: L10n.t("settings.engines.llmHelp")) {
                EnginePicker(options: llmOptions, selection: $appState.llmBackend)
                if appState.llmBackend == .localMLX { ModelsLink(ids: ["qwen3"]) }
            }
        }
        // Skip the write when the picker already matches what is stored: that
        // means loadConfig() just applied it, not the user changing it.
        .onChange(of: appState.sttBackend) { _, backend in
            guard appState.apiConfig.sttBackend != backend.rawValue else { return }
            var config = appState.apiConfig
            config.sttBackend = backend.rawValue
            Task {
                await appState.saveConfig(config)
                await appState.reloadLocalEngine()
            }
        }
        .onChange(of: appState.translationBackend) { _, backend in
            guard appState.apiConfig.translationBackend != backend.rawValue else { return }
            var config = appState.apiConfig
            config.translationBackend = backend.rawValue
            Task { await appState.saveConfig(config) }
        }
        .onChange(of: appState.llmBackend) { _, backend in
            guard appState.apiConfig.llmBackend != backend.rawValue else { return }
            var config = appState.apiConfig
            config.llmBackend = backend.rawValue
            Task { await appState.saveConfig(config) }
        }
    }

    private var sttOptions: [EngineOption<SttBackend>] {
        [
            EngineOption(value: .funasr, title: "Nemotron 3.5", detail: L10n.t("engine.stt.nemotron"), isLocal: true),
            EngineOption(value: .r2t2, title: "Confucius4-R2T2", detail: L10n.t("engine.stt.r2t2"), isLocal: true),
            EngineOption(value: .appleSpeech, title: L10n.t("engine.stt.apple.title"),
                         detail: L10n.t("settings.engines.appleSpeechNote"), isLocal: true),
            EngineOption(value: .openAICompatible, title: L10n.t("engine.cloud.title"),
                         detail: L10n.t("engine.stt.cloud"), isLocal: false),
        ]
    }

    private var translationOptions: [EngineOption<TranslationBackend>] {
        [
            EngineOption(value: .localMLX, title: "Hy-MT2 1.8B", detail: L10n.t("engine.mt.hymt2"), isLocal: true),
            EngineOption(value: .t3po, title: "Confucius4-T3PO 14B", detail: L10n.t("engine.mt.t3po"), isLocal: true),
            EngineOption(value: .appleTranslation, title: L10n.t("engine.mt.apple.title"),
                         detail: L10n.t("settings.engines.appleTranslationNote"), isLocal: true),
            EngineOption(value: .openAICompatible, title: L10n.t("engine.cloud.title"),
                         detail: L10n.t("engine.mt.cloud"), isLocal: false),
        ]
    }

    private var llmOptions: [EngineOption<LLMBackend>] {
        [
            EngineOption(value: .localMLX, title: "Qwen3 4B Instruct", detail: L10n.t("engine.llm.qwen3"), isLocal: true),
            EngineOption(value: .openAICompatible, title: L10n.t("engine.cloud.title"),
                         detail: L10n.t("engine.llm.cloud"), isLocal: false),
        ]
    }
}

/// Size and state of the models an engine uses, with a jump to the Models
/// tab where they are downloaded and deleted.
private struct ModelsLink: View {
    let ids: [String]
    @AppStorage("settingsTab", store: AppEnvironment.defaults) private var tab = SettingsTab.general.rawValue

    var body: some View {
        let models = ids.compactMap { LocalModelCatalog.model(id: $0) }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(models) { model in
                    HStack(spacing: 6) {
                        Text(model.name)
                        Text("≈ " + LocalModelCatalog.formatBytes(model.approxBytes)).foregroundStyle(.secondary)
                        Image(systemName: model.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(model.isInstalled ? Theme.success : .secondary)
                    }
                }
            }
            Spacer()
            Button(L10n.t("settings.engines.manageModels")) { tab = SettingsTab.models.rawValue }
                .controlSize(.small)
        }
        .font(.caption)
    }
}

/// Picks the Nemotron chunk size: how far behind the voice the text runs.
/// Each option is its own ~650 MB export, so a change downloads once and
/// reloads the engine.
struct LocalEngineLatencyRow: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(LocalEngineLatency.storageKey, store: AppEnvironment.defaults) private var raw = LocalEngineLatency.default.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L10n.t("settings.engines.latency"), selection: $raw) {
                ForEach(LocalEngineLatency.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .disabled(appState.isRecording)
            Text(L10n.t("settings.engines.latency.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: raw) { _, _ in Task { await appState.reloadLocalEngine() } }
    }
}

/// Install, load and unload for the local recogniser.
private struct LocalEngineStatusRow: View {
    @EnvironmentObject var appState: AppState
    @State private var installStage = ""
    @State private var installError = ""
    @State private var isInstalling = false

    private var isInstalled: Bool { LocalASREnvironment.shared.isReady() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                status
                Spacer()
                action
            }
            .font(.caption)
            if !installError.isEmpty {
                Text(installError)
                    .font(.caption)
                    .foregroundStyle(Theme.recording)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ModelsLink(ids: appState.sttBackend == .r2t2
                       ? ["r2t2", "runtime"]
                       : [LocalModelCatalog.currentNemotron?.id ?? "", "punctuation", "runtime"])
        }
    }

    @ViewBuilder
    private var status: some View {
        if isInstalling {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(installStage.isEmpty ? L10n.t("localASR.installing") : installStage)
            }
            .foregroundStyle(.secondary)
        } else if !isInstalled {
            Label(L10n.t("settings.engines.notInstalled"), systemImage: "arrow.down.circle")
                .foregroundStyle(Theme.warning)
        } else if appState.isLocalEnginePreloading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(appState.localEngineStatus.isEmpty ? L10n.t("settings.engines.loading")
                                                        : appState.localEngineStatus)
            }
            .foregroundStyle(.secondary)
        } else if appState.isLocalEngineReady {
            Label(L10n.t("settings.engines.ready"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
        } else {
            Label(L10n.t("settings.engines.installedNotLoaded"), systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var action: some View {
        if !isInstalled {
            Button(L10n.t("settings.engines.installNow"), action: install).disabled(isInstalling)
        } else if !appState.isLocalEngineReady {
            Button(L10n.t("settings.engines.loadNow")) {
                Task { await appState.preloadLocalEngine() }
            }
            .disabled(appState.isLocalEnginePreloading)
        } else {
            Button(L10n.t("settings.engines.unload")) {
                Task {
                    // Deferred while a transcription holds it; the flag must
                    // only drop when the models really went.
                    if await LocalASRWarmPool.shared.retire() { appState.isLocalEngineReady = false }
                }
            }
            .disabled(appState.isRecording)
        }
    }

    private func install() {
        isInstalling = true
        installError = ""
        Task {
            do {
                for try await progress in LocalASREnvironment.shared.install() {
                    installStage = progress.stage
                }
                isInstalling = false
                await appState.preloadLocalEngine()
            } catch {
                isInstalling = false
                installError = error.localizedDescription
            }
        }
    }
}

// MARK: - Cloud API

struct ApiSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var testStatus = ""
    @State private var testIsError = false
    @State private var autosaveTask: Task<Void, Never>?
    @State private var localNetworkDenied = false

    private var presets: [ApiConfig.ProviderPreset] { ApiConfig.providerPresets }

    private var activePreset: ApiConfig.ProviderPreset? {
        presets.first { $0.baseUrl == appState.apiConfig.baseUrl }
    }

    var body: some View {
        SettingsPage {
            Text(L10n.t("settings.api.intro"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsSection(title: L10n.t("settings.api.presets")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                    ForEach(presets) { preset in
                        let isActive = appState.apiConfig.baseUrl == preset.baseUrl
                        Button {
                            updateConfig(immediate: true) { config in
                                config.baseUrl = preset.baseUrl
                                // A provider with no transcription endpoint has
                                // no STT model; writing one only 404s later.
                                if let stt = preset.sttModel { config.sttModel = stt }
                                config.translationModel = preset.chatModel
                                config.llmModel = preset.chatModel
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isActive ? Theme.accent : .secondary)
                                Text(preset.label).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 7)
                            .padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: Theme.cornerSmall)
                                .fill(isActive ? Theme.accentSoft : Theme.chrome))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let active = activePreset {
                    if active.sttModel == nil && appState.sttBackend == .openAICompatible {
                        Label(L10n.t("settings.api.preset.noStt"), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    }
                    if !active.requiresApiKey {
                        Label(L10n.t("settings.api.preset.noKeyNeeded"), systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsSection(title: L10n.t("settings.api.endpoint"), footer: L10n.t("settings.api.privacy")) {
                LabeledRow(label: L10n.t("settings.api.baseUrl")) {
                    TextField("https://api.openai.com/v1", text: binding(\.baseUrl))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledRow(label: L10n.t("settings.api.key")) {
                    SecureField("sk-…", text: binding(\.apiKey))
                        .textFieldStyle(.roundedBorder)
                }
                if !appState.apiConfig.requiresApiKey {
                    Text(L10n.t("settings.api.keyOptional")).font(.caption).foregroundStyle(.secondary)
                }
                if localNetworkDenied {
                    HStack {
                        Label(L10n.t("settings.api.localNetworkDenied"), systemImage: "wifi.exclamationmark")
                            .foregroundStyle(Theme.warning)
                        Button(L10n.t("settings.api.openSystemSettings")) { LocalNetworkAccess.openSystemSettings() }
                    }
                    .font(.caption)
                }
            }

            SettingsSection(title: L10n.t("settings.api.models")) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text(L10n.t("settings.api.stt"))
                        TextField("whisper-1", text: binding(\.sttModel)).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text(L10n.t("settings.api.translation"))
                        TextField("gpt-4o-mini", text: binding(\.translationModel)).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text(L10n.t("settings.api.llm"))
                        TextField("gpt-4o-mini", text: binding(\.llmModel)).textFieldStyle(.roundedBorder)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await testConnection() }
                } label: {
                    Label(L10n.t("settings.api.test"), systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(appState.apiConfig.baseUrl.isEmpty || appState.apiConfig.isCloudCredentialMissing)
                if !testStatus.isEmpty {
                    Label(testStatus, systemImage: testIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(testIsError ? Theme.recording : Theme.success)
                        .font(.callout)
                        .lineLimit(2)
                }
                Spacer()
            }
        }
        .onDisappear {
            autosaveTask?.cancel()
            let config = appState.apiConfig
            Task { await appState.saveConfig(config) }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ApiConfig, String>) -> Binding<String> {
        Binding(get: { appState.apiConfig[keyPath: keyPath] },
                set: { value in updateConfig { $0[keyPath: keyPath] = value } })
    }

    /// Edits are saved on their own, half a second after the last keystroke.
    private func updateConfig(immediate: Bool = false, _ update: (inout ApiConfig) -> Void) {
        var config = appState.apiConfig
        update(&config)
        appState.apiConfig = config
        testStatus = ""
        autosaveTask?.cancel()
        let state = appState
        autosaveTask = Task { [config] in
            if !immediate {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await state.saveConfig(config)
            await probeLocalNetwork(config.baseUrl)
        }
    }

    /// A local-network host needs the Local Network permission, which macOS
    /// only asks for on a first connection; this makes that happen now.
    private func probeLocalNetwork(_ baseUrl: String) async {
        guard LocalNetworkAccess.isLocalNetworkHost(baseUrl) else {
            localNetworkDenied = false
            return
        }
        localNetworkDenied = await LocalNetworkAccess.probe(baseUrlString: baseUrl) == .denied
    }

    private func testConnection() async {
        testStatus = L10n.t("settings.api.testing")
        testIsError = false
        let client = OpenAICompatibleLLM(config: appState.apiConfig)
        do {
            let out = try await client.chatComplete(messages: [
                .init(role: .system, content: "Reply with exactly: OK"),
                .init(role: .user, content: "ping"),
            ], model: appState.apiConfig.llmModel, temperature: 0)
            testStatus = "\(L10n.t("settings.api.testOk")) — \(out.prefix(40))"
        } catch {
            testStatus = "\(L10n.t("settings.api.testFail")): \(error.localizedDescription)"
            testIsError = true
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    var body: some View {
        SettingsPage {
            SettingsSection(title: L10n.t("settings.shortcuts.global"), footer: L10n.t("settings.shortcuts.note")) {
                ShortcutRow(label: L10n.t("settings.shortcuts.toggleRecording"), name: .toggleRecording, icon: "record.circle")
                ShortcutRow(label: L10n.t("settings.shortcuts.markHighlight"), name: .markHighlight, icon: "star")
                ShortcutRow(label: L10n.t("settings.shortcuts.toggleTranslation"), name: .toggleTranslation, icon: "character.bubble")
                ShortcutRow(label: L10n.t("settings.shortcuts.toggleOverlay"), name: .toggleOverlay, icon: "captions.bubble")
            }
        }
    }
}

private struct ShortcutRow: View {
    let label: String
    let name: KeyboardShortcuts.Name
    let icon: String

    var body: some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }
}

// MARK: - About

struct AboutView: View {
    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        SettingsPage {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                Text(L10n.t("app.name")).font(.title.weight(.semibold))
                Text(verbatim: "v\(Self.bundleVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(L10n.t("settings.about.tagline"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity)

            SettingsSection(title: L10n.t("settings.engines.storage")) {
                PathRow(label: L10n.t("settings.engines.appSupport"), path: AppBootstrap.applicationSupportURL.path)
                PathRow(label: L10n.t("settings.engines.recordings"), path: AppBootstrap.recordingsURL.path)
                PathRow(label: L10n.t("settings.engines.database"),
                        path: AppBootstrap.applicationSupportURL.appendingPathComponent("classnote.sqlite").path)
                Button {
                    NSWorkspace.shared.open(AppBootstrap.applicationSupportURL)
                } label: {
                    Label(L10n.t("settings.engines.reveal"), systemImage: "folder")
                }
            }
        }
    }
}

private struct PathRow: View {
    let label: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(path)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
