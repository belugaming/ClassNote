import SwiftUI
#if os(macOS)
import KeyboardShortcuts
#endif

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: Tab = .api

    enum Tab: String, CaseIterable, Hashable {
        case api, engines
        #if os(macOS)
        case shortcuts
        #endif
        case appearance, about

        var titleKey: String {
            switch self {
            case .api: return "settings.tab.api"
            case .engines: return "settings.tab.engines"
            #if os(macOS)
            case .shortcuts: return "settings.tab.shortcuts"
            #endif
            case .appearance: return "settings.tab.appearance"
            case .about: return "settings.tab.about"
            }
        }
        var icon: String {
            switch self {
            case .api: return "network"
            case .engines: return "waveform.circle"
            #if os(macOS)
            case .shortcuts: return "keyboard"
            #endif
            case .appearance: return "paintpalette"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            ApiSettingsView()
                .tabItem { Label(L10n.t("settings.tab.api"), systemImage: "network") }
                .tag(Tab.api)
            EngineSettingsView()
                .tabItem { Label(L10n.t("settings.tab.engines"), systemImage: "waveform.circle") }
                .tag(Tab.engines)
            #if os(macOS)
            ShortcutsSettingsView()
                .tabItem { Label(L10n.t("settings.tab.shortcuts"), systemImage: "keyboard") }
                .tag(Tab.shortcuts)
            #endif
            AppearanceSettingsView()
                .tabItem { Label(L10n.t("settings.tab.appearance"), systemImage: "paintpalette") }
                .tag(Tab.appearance)
            AboutView()
                .tabItem { Label(L10n.t("settings.tab.about"), systemImage: "info.circle") }
                .tag(Tab.about)
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 540)
        #endif
        .background(Theme.surface)
        .id(appState.languageRefreshToken)   // force full re-render on language switch
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: L10n.LanguageOverride = L10n.override
    @AppStorage("overlayCaptionDisplayMode", store: AppEnvironment.defaults) private var displayModeRaw = OverlayCaptionDisplayMode.bilingual.rawValue
    @AppStorage("overlayCaptionTextSize", store: AppEnvironment.defaults) private var textSizeRaw = OverlayCaptionTextSize.medium.rawValue
    @AppStorage("overlayCaptionRecentCount", store: AppEnvironment.defaults) private var recentCountRaw = OverlayCaptionRecentCount.two.rawValue
    @AppStorage("overlayAlwaysOnTop", store: AppEnvironment.defaults) private var overlayAlwaysOnTop: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                SettingsSection(title: L10n.t("settings.appearance.language"),
                                footer: L10n.t("settings.appearance.languageNote")) {
                    Picker("", selection: $selection) {
                        ForEach(L10n.LanguageOverride.allCases, id: \.rawValue) { opt in
                            Text(opt.displayName).tag(opt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selection) { _, newValue in
                        appState.setLanguage(newValue)
                    }
                }

                SettingsSection(title: L10n.t("settings.appearance.overlay"),
                                footer: L10n.t("settings.appearance.overlayNote")) {
                    LabeledRow(label: L10n.t("overlay.displayMode")) {
                        Picker("", selection: displayModeBinding) {
                            ForEach(OverlayCaptionDisplayMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    LabeledRow(label: L10n.t("overlay.textSize")) {
                        Picker("", selection: textSizeBinding) {
                            ForEach(OverlayCaptionTextSize.allCases) { size in
                                Text(size.title).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    LabeledRow(label: L10n.t("overlay.recentCount")) {
                        Picker("", selection: recentCountBinding) {
                            ForEach(OverlayCaptionRecentCount.allCases) { count in
                                Text(count.title).tag(count)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Toggle(L10n.t("overlay.alwaysOnTop"), isOn: $overlayAlwaysOnTop)
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                }
            }
            .padding(Theme.pagePadding)
        }
        .background(Theme.surface)
    }

    private var displayMode: OverlayCaptionDisplayMode {
        OverlayCaptionDisplayMode(rawValue: displayModeRaw) ?? .bilingual
    }

    private var textSize: OverlayCaptionTextSize {
        OverlayCaptionTextSize(rawValue: textSizeRaw) ?? .medium
    }

    private var recentCount: OverlayCaptionRecentCount {
        OverlayCaptionRecentCount(rawValue: recentCountRaw) ?? .two
    }

    private var displayModeBinding: Binding<OverlayCaptionDisplayMode> {
        Binding(
            get: { displayMode },
            set: { displayModeRaw = $0.rawValue }
        )
    }

    private var textSizeBinding: Binding<OverlayCaptionTextSize> {
        Binding(
            get: { textSize },
            set: { textSizeRaw = $0.rawValue }
        )
    }

    private var recentCountBinding: Binding<OverlayCaptionRecentCount> {
        Binding(
            get: { recentCount },
            set: { recentCountRaw = $0.rawValue }
        )
    }
}

// MARK: - API

struct ApiSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var testStatus: String = ""
    @State private var testIsError: Bool = false
    @State private var autosaveTask: Task<Void, Never>?
    @State private var localNetworkDenied: Bool = false

    /// Presets carry no per-provider colour: `Theme` documents a monochrome
    /// design language, and six arbitrary hues here made the first thing you see
    /// in Settings look like a swatch test. Which preset is active is shown by
    /// selection state instead, which is information the colours never conveyed.
    ///
    /// The table itself lives on `ApiConfig`, because the same rows answer
    /// "does this endpoint need a key" for every engine — a question this screen
    /// used to answer for itself and get wrong for loopback servers.
    private var providerPresets: [ApiConfig.ProviderPreset] { ApiConfig.providerPresets }

    /// The preset the stored base URL matches, if the user has not edited it.
    private var activePreset: ApiConfig.ProviderPreset? {
        providerPresets.first { $0.baseUrl == appState.apiConfig.baseUrl }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                SettingsSection(title: L10n.t("settings.api.presets")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        ForEach(providerPresets) { preset in
                            let isActive = appState.apiConfig.baseUrl == preset.baseUrl
                            Button {
                                updateConfig(immediate: true) { config in
                                    config.baseUrl = preset.baseUrl
                                    // A provider that serves no transcription
                                    // endpoint has no STT model to offer, and
                                    // writing one only produces a 404 on the
                                    // first recording. Leave the field alone.
                                    if let sttModel = preset.sttModel {
                                        config.sttModel = sttModel
                                    }
                                    config.translationModel = preset.chatModel
                                    config.llmModel = preset.chatModel
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                        .font(.caption)
                                        .foregroundStyle(isActive ? Theme.accent : Color.secondary.opacity(0.5))
                                    Text(preset.label)
                                        .font(.callout.weight(isActive ? .semibold : .regular))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                                        .fill(isActive ? Theme.accentSoft : Theme.chrome)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                                        .stroke(isActive ? Theme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let active = activePreset {
                        if active.sttModel == nil && appState.sttBackend == .openAICompatible {
                            Label(L10n.t("settings.api.preset.noStt"), systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !active.requiresApiKey {
                            Label(L10n.t("settings.api.preset.noKeyNeeded"), systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                SettingsSection(title: L10n.t("settings.api.endpoint"),
                                footer: L10n.t("settings.api.privacy")) {
                    LabeledRow(label: L10n.t("settings.api.baseUrl")) {
                        TextField("https://api.openai.com/v1", text: baseUrlBinding)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: L10n.t("settings.api.key")) {
                        SecureField("sk-…", text: apiKeyBinding)
                            .textFieldStyle(.roundedBorder)
                    }
                    if !appState.apiConfig.requiresApiKey {
                        Text(L10n.t("settings.api.keyOptional"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if localNetworkDenied {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(L10n.t("settings.api.localNetworkDenied"), systemImage: "wifi.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button {
                                LocalNetworkAccess.openSystemSettings()
                            } label: {
                                Text(L10n.t("settings.api.openSystemSettings"))
                                    .font(.caption)
                            }
                        }
                    }
                }

                SettingsSection(title: L10n.t("settings.api.models")) {
                    LabeledRow(label: L10n.t("settings.api.stt")) {
                        TextField("whisper-1", text: sttModelBinding).textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: L10n.t("settings.api.translation")) {
                        TextField("gpt-4o-mini", text: translationModelBinding).textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: L10n.t("settings.api.llm")) {
                        TextField("gpt-4o-mini", text: llmModelBinding).textFieldStyle(.roundedBorder)
                    }
                }

                SettingsSection(title: L10n.t("settings.api.languages"),
                                footer: L10n.t("settings.api.langHelp")) {
                    HStack(spacing: 8) {
                        LabeledRow(label: L10n.t("settings.api.source")) {
                            TextField("en", text: sourceLanguageBinding)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { reloadEngineForLanguageChange() }
                                // Committing a new language retires the warm
                                // sidecar, which would kill the recording that
                                // is streaming through it.
                                .disabled(appState.isRecording && appState.sttBackend.isLocalSidecar)
                        }
                        LabeledRow(label: L10n.t("settings.api.target")) {
                            TextField("zh-Hans", text: targetLanguageBinding).textFieldStyle(.roundedBorder)
                        }
                    }
                }

                HStack {
                    Button {
                        save()
                    } label: {
                        Label(L10n.t("common.save"), systemImage: "checkmark.circle")
                            .frame(minWidth: 100)
                    }
                    .controlSize(.large)
                    .prominentAccentButton()

                    Button {
                        Task { await testConnection() }
                    } label: {
                        Label(L10n.t("settings.api.test"), systemImage: "antenna.radiowaves.left.and.right")
                            .frame(minWidth: 100)
                    }
                    .controlSize(.large)
                    .disabled(appState.apiConfig.baseUrl.isEmpty || appState.apiConfig.isCloudCredentialMissing)

                    if !testStatus.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: testIsError ? "xmark.circle.fill" : "checkmark.seal.fill")
                            Text(testStatus).font(.callout)
                        }
                        .foregroundStyle(testIsError ? Theme.recording : Theme.success)
                    }
                    Spacer()
                }
            }
            .padding(Theme.pagePadding)
        }
        .background(Theme.surface)
        .onDisappear {
            autosaveTask?.cancel()
            Task { await appState.saveConfig(appState.apiConfig) }
        }
    }

    private func save() {
        autosaveTask?.cancel()
        let config = appState.apiConfig
        Task {
            await appState.saveConfig(config)
            testStatus = L10n.t("settings.api.saved")
            testIsError = false
            await probeLocalNetworkIfNeeded(config.baseUrl)
        }
    }

    /// If the base URL points at a local-network host, open a throwaway
    /// connection so macOS surfaces (or we can detect denial of) the Local
    /// Network permission prompt. See `LocalNetworkAccess` for why this is
    /// necessary — declaring the Info.plist key alone never triggers it.
    private func probeLocalNetworkIfNeeded(_ baseUrl: String) async {
        guard LocalNetworkAccess.isLocalNetworkHost(baseUrl) else {
            localNetworkDenied = false
            return
        }
        let result = await LocalNetworkAccess.probe(baseUrlString: baseUrl)
        localNetworkDenied = (result == .denied)
    }

    private func updateConfig(immediate: Bool = false, _ update: (inout ApiConfig) -> Void) {
        var config = appState.apiConfig
        update(&config)
        appState.apiConfig = config
        testStatus = ""
        if immediate {
            autosaveTask?.cancel()
            Task { await appState.saveConfig(config) }
        } else {
            scheduleAutosave(config)
        }
    }

    private func scheduleAutosave(_ config: ApiConfig) {
        autosaveTask?.cancel()
        let state = appState
        autosaveTask = Task { [config, state] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await state.saveConfig(config)
        }
    }

    private func testConnection() async {
        testStatus = L10n.t("settings.api.testing")
        testIsError = false
        let client = OpenAICompatibleLLM(config: appState.apiConfig)
        do {
            let out = try await client.chatComplete(messages: [
                .init(role: .system, content: "Reply with exactly: OK"),
                .init(role: .user, content: "ping")
            ], model: appState.apiConfig.llmModel, temperature: 0)
            testStatus = "\(L10n.t("settings.api.testOk")) — \(out.prefix(40))"
            testIsError = false
        } catch {
            testStatus = "\(L10n.t("settings.api.testFail")): \(error.localizedDescription)"
            testIsError = true
        }
    }

    private var baseUrlBinding: Binding<String> {
        Binding(get: { appState.apiConfig.baseUrl },
                set: { newValue in
                    updateConfig { $0.baseUrl = newValue }
                })
    }

    private var apiKeyBinding: Binding<String> {
        Binding(get: { appState.apiConfig.apiKey },
                set: { newValue in
                    updateConfig { $0.apiKey = newValue }
                })
    }

    private var sttModelBinding: Binding<String> {
        Binding(get: { appState.apiConfig.sttModel },
                set: { newValue in
                    updateConfig { $0.sttModel = newValue }
                })
    }

    private var translationModelBinding: Binding<String> {
        Binding(get: { appState.apiConfig.translationModel },
                set: { newValue in
                    updateConfig { $0.translationModel = newValue }
                })
    }

    private var llmModelBinding: Binding<String> {
        Binding(get: { appState.apiConfig.llmModel },
                set: { newValue in
                    updateConfig { $0.llmModel = newValue }
                })
    }

    private var sourceLanguageBinding: Binding<String> {
        Binding(get: { appState.apiConfig.sourceLanguage },
                set: { newValue in
                    updateConfig { $0.sourceLanguage = newValue }
                })
    }

    /// Reloads a warm local sidecar after the source language settles.
    ///
    /// The language decides which models are loaded, so a change invalidates a
    /// warm process. This runs on commit rather than per keystroke, since typing
    /// "en" would otherwise restart the sidecar on the intermediate "e".
    private func reloadEngineForLanguageChange() {
        guard appState.sttBackend.isLocalSidecar else { return }
        Task { await appState.reloadLocalEngine() }
    }

    private var targetLanguageBinding: Binding<String> {
        Binding(get: { appState.apiConfig.targetLanguage },
                set: { newValue in
                    updateConfig { $0.targetLanguage = newValue }
                })
    }
}

// MARK: - Engines

struct EngineSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                SettingsSection(title: L10n.t("settings.engines.stt")) {
                    Picker(L10n.t("settings.engines.sttPicker"), selection: $appState.sttBackend) {
                        ForEach(SttBackend.selectableCases) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Switching engines retires the warm sidecar, and the live
                    // pipeline is streaming through it: the recording would lose
                    // its transcription for good, with no way back but stop/start.
                    .disabled(appState.isRecording)
                    if appState.sttBackend == .appleSpeech {
                        Label(L10n.t("settings.engines.appleSpeechNote"), systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if appState.sttBackend == .funasr {
                        Label(L10n.t("settings.engines.funasrNote"), systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if appState.sttBackend == .nemotronStreaming {
                        Label(L10n.t("settings.engines.nemotronNote"), systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if appState.isRecording {
                        Label(L10n.t("settings.engines.lockedWhileRecording"), systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if appState.sttBackend.isLocalSidecar {
                        LocalEngineLatencyRow()
                        LocalEngineStatusRow()
                    }
                }

                SettingsSection(title: L10n.t("settings.engines.translationSection"),
                                footer: L10n.t("settings.engines.liveHelp")) {
                    Toggle(L10n.t("settings.engines.liveTranslationToggle"), isOn: $appState.translationEnabled)
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                    if appState.translationEnabled {
                        Picker(L10n.t("settings.engines.translationBackendPicker"), selection: $appState.translationBackend) {
                            ForEach(TranslationBackend.allCases) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }
                        .pickerStyle(.segmented)
                        switch appState.translationBackend {
                        case .appleTranslation:
                            Label(L10n.t("settings.engines.appleTranslationNote"), systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .localMLX:
                            Label(L10n.t("settings.engines.translationBackend.mlxNote"), systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Label(L10n.t("settings.translation.modelList"), systemImage: "shippingbox")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            #if os(macOS)
                            LocalTranslationStatusRow()
                            #endif
                        case .openAICompatible, .t3po:
                            EmptyView()
                        }
                    }
                }

                SettingsSection(title: L10n.t("settings.engines.llmSection"),
                                footer: L10n.t("settings.engines.llmHelp")) {
                    Picker(L10n.t("settings.engines.llmBackendPicker"), selection: $appState.llmBackend) {
                        ForEach(LLMBackend.allCases) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)
                    if appState.llmBackend == .localMLX {
                        Label(L10n.t("settings.engines.llmBackend.mlxNote"), systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        #if os(macOS)
                        LocalLLMStatusRow()
                        #endif
                    }
                }

                SettingsSection(title: L10n.t("settings.audio.input"),
                                footer: L10n.t("settings.audio.inputNote")) {
                    Picker(L10n.t("settings.audio.microphone"), selection: $appState.preferredMicrophoneDeviceID) {
                        ForEach(appState.microphoneDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        appState.refreshMicrophoneDevices()
                    } label: {
                        Label(L10n.t("settings.audio.refresh"), systemImage: "arrow.clockwise")
                    }
                }

                SettingsSection(title: L10n.t("settings.engines.storage")) {
                    PathRow(label: L10n.t("settings.engines.appSupport"),
                            path: AppBootstrap.applicationSupportURL.path)
                    PathRow(label: L10n.t("settings.engines.recordings"),
                            path: AppBootstrap.recordingsURL.path)
                    PathRow(label: L10n.t("settings.engines.database"),
                            path: AppBootstrap.applicationSupportURL.appendingPathComponent("classnote.sqlite").path)
                    #if os(macOS)
                    Button {
                        NSWorkspace.shared.open(AppBootstrap.applicationSupportURL)
                    } label: {
                        Label(L10n.t("settings.engines.reveal"), systemImage: "folder")
                    }
                    #endif
                }
            }
            .padding(Theme.pagePadding)
        }
        .background(Theme.surface)
        .onAppear {
            appState.refreshMicrophoneDevices()
        }
        // Skip the write when the picker already matches what is stored: that
        // means loadConfig() just applied it, not the user changing it. Saving
        // here would race the load and could persist a stale config.
        .onChange(of: appState.sttBackend) { _, backend in
            guard appState.apiConfig.sttBackend != backend.rawValue else { return }
            var config = appState.apiConfig
            config.sttBackend = backend.rawValue
            Task {
                await appState.saveConfig(config)
                // A warm sidecar holds models for the previous engine, so swap
                // it for one matching the new selection.
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
}

private struct PathRow: View {
    let label: String
    let path: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(path)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shortcuts (macOS only — no global hotkeys on iOS)

#if os(macOS)
struct ShortcutsSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                SettingsSection(title: L10n.t("settings.shortcuts.global"),
                                footer: L10n.t("settings.shortcuts.note")) {
                    ShortcutRow(label: L10n.t("settings.shortcuts.toggleRecording"), name: .toggleRecording, icon: "record.circle")
                    ShortcutRow(label: L10n.t("settings.shortcuts.markHighlight"), name: .markHighlight, icon: "star.circle")
                    ShortcutRow(label: L10n.t("settings.shortcuts.toggleTranslation"), name: .toggleTranslation, icon: "character.bubble")
                    ShortcutRow(label: L10n.t("settings.shortcuts.toggleOverlay"), name: .toggleOverlay, icon: "rectangle.on.rectangle")
                }
            }
            .padding(Theme.pagePadding)
        }
        .background(Theme.surface)
    }
}

private struct ShortcutRow: View {
    let label: String
    let name: KeyboardShortcuts.Name
    let icon: String

    var body: some View {
        HStack {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
            KeyboardShortcuts.Recorder(for: name)
        }
    }
}
#endif

// MARK: - About

struct AboutView: View {
    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Theme.accentSoft)
                    .frame(width: 104, height: 104)
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            Text(L10n.t("app.name"))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            // Read from the bundle rather than a localized literal. The string
            // used to hardcode "v0.3.0" in both locales, so it kept claiming
            // 0.3.0 long after the project moved on — About is the one screen
            // where a stale version is actively misleading.
            Text(verbatim: "v\(Self.bundleVersion) · \(L10n.t("settings.about.buildKind"))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L10n.t("settings.about.tagline"))
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .frame(maxWidth: 420)
                .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surfaceElevated.opacity(0.35))
    }
}

/// Install/download and warm-up control for a local ASR sidecar.
///
/// Both are surfaced here on purpose: a first run downloads ~1 GB of models and
/// loading them costs ~30s, and neither should first happen when the user hits
/// record. Once warm, the sidecar stays in memory so recording starts instantly.
private struct LocalEngineStatusRow: View {
    @ObservedObject private var appState = AppState.shared
    @State private var installStage: String = ""
    @State private var installError: String = ""
    @State private var isInstalling = false

    private var engine: LocalASREngineKind {
        appState.sttBackend.localEngine ?? .funasr
    }

    private var isInstalled: Bool {
        LocalASREnvironment.shared.isReady(engine: engine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusLine
            if !installError.isEmpty {
                Text(installError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            actionButton
        }
        .padding(.top, 4)
        // Re-check when the picker or language changes, since each language
        // loads a different model set.
        .onChange(of: appState.sttBackend) { _, _ in installError = "" }
    }
}

extension LocalEngineStatusRow {
    @ViewBuilder
    private var statusLine: some View {
        if isInstalling {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(installStage.isEmpty ? L10n.t("localASR.installing") : installStage)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if !isInstalled {
            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.t("settings.engines.notInstalled"), systemImage: "arrow.down.circle")
                    .foregroundStyle(.orange)
                // Name the weights rather than only their total size: "about
                // 2 GB" says nothing about what is being fetched or from where.
                Label(L10n.t("settings.engines.modelList"), systemImage: "shippingbox")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
        } else if appState.isLocalEnginePreloading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(appState.localEngineStatus.isEmpty
                     ? L10n.t("settings.engines.loading") : appState.localEngineStatus)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if appState.isLocalEngineReady {
            Label(L10n.t("settings.engines.ready"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label(L10n.t("settings.engines.installedNotLoaded"), systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        HStack(spacing: 10) {
            if !isInstalled {
                Button(L10n.t("settings.engines.installNow")) { install() }
                    .disabled(isInstalling)
            } else if !appState.isLocalEngineReady {
                Button(L10n.t("settings.engines.loadNow")) {
                    Task { await appState.preloadLocalEngine() }
                }
                .disabled(appState.isLocalEnginePreloading)
            } else {
                Button(L10n.t("settings.engines.unload")) {
                    Task {
                        await LocalASRWarmPool.shared.retire()
                        appState.isLocalEngineReady = false
                    }
                }
                .disabled(appState.isRecording)
            }
        }
    }

    /// Installs the venv and its dependencies, then downloads the models by
    /// warming the sidecar once -- the same path recording uses, so a success
    /// here means recording will work.
    private func install() {
        isInstalling = true
        installError = ""
        let engine = self.engine
        Task {
            do {
                for try await progress in LocalASREnvironment.shared.install(engine: engine) {
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

#if os(macOS)
/// Download / status control for the local translation model.
///
/// The ASR engine already had one of these; translation shipped without it, so
/// the ~1 GB download only happened implicitly on the first translated sentence
/// — which looked like the app had hung.
struct LocalTranslationStatusRow: View {
    @State private var isPreparing = false
    @State private var stage = ""
    @State private var errorText = ""
    @State private var isReady = LocalMLXTranslatorProcess.isModelDownloaded
    @State private var hasPartial = LocalMLXTranslatorProcess.hasPartialDownload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isPreparing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(stage.isEmpty ? L10n.t("settings.translation.downloading") : stage)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if isReady {
                Label(L10n.t("settings.translation.ready"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.t("settings.translation.notInstalled"), systemImage: "arrow.down.circle")
                        .foregroundStyle(.orange)
                    if hasPartial {
                        Text(L10n.t("settings.translation.partial"))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }

            if !errorText.isEmpty {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !isReady {
                Button(L10n.t(hasPartial ? "settings.translation.resume" : "settings.translation.install")) {
                    prepare()
                }
                .disabled(isPreparing)
            }
        }
        .onAppear { refreshInstallState() }
    }

    /// A `@State` initial value is evaluated once for the view's lifetime, so
    /// without this the row keeps reporting whatever was true when the Engines
    /// tab first appeared — including "ready" for a download that has since been
    /// interrupted.
    private func refreshInstallState() {
        isReady = LocalMLXTranslatorProcess.isModelDownloaded
        hasPartial = LocalMLXTranslatorProcess.hasPartialDownload
    }

    private func prepare() {
        isPreparing = true
        errorText = ""
        Task {
            do {
                try await LocalMLXTranslatorProcess.shared.prewarm { text in
                    Task { @MainActor in stage = text }
                }
                // Trust a successful load over the file probe: a repo layout
                // change must not make a working model look absent.
                isReady = true
                hasPartial = false
            } catch {
                errorText = error.localizedDescription
                refreshInstallState()
            }
            isPreparing = false
        }
    }
}

/// The same control for the notes/Q&A model.
///
/// A sibling rather than a generic row: the two sidecars share no protocol in
/// Swift (each is its own actor with its own static probes), and the strings
/// differ because one download is 1 GB and the other 2.4 GB.
struct LocalLLMStatusRow: View {
    @State private var isPreparing = false
    @State private var stage = ""
    @State private var errorText = ""
    @State private var isReady = LocalMLXLLMProcess.isModelDownloaded
    @State private var hasPartial = LocalMLXLLMProcess.hasPartialDownload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isPreparing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(stage.isEmpty ? L10n.t("settings.llm.downloading") : stage)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if isReady {
                Label(L10n.t("settings.llm.ready"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.t("settings.llm.notInstalled"), systemImage: "arrow.down.circle")
                        .foregroundStyle(.orange)
                    if hasPartial {
                        Text(L10n.t("settings.llm.partial"))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }

            if !errorText.isEmpty {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !isReady {
                Button(L10n.t(hasPartial ? "settings.llm.resume" : "settings.llm.download")) {
                    prepare()
                }
                .disabled(isPreparing)
            }
        }
        .onAppear { refreshInstallState() }
    }

    private func refreshInstallState() {
        isReady = LocalMLXLLMProcess.isModelDownloaded
        hasPartial = LocalMLXLLMProcess.hasPartialDownload
    }

    private func prepare() {
        isPreparing = true
        errorText = ""
        Task {
            do {
                try await LocalMLXLLMProcess.shared.prewarm { text in
                    Task { @MainActor in stage = text }
                }
                isReady = true
                hasPartial = false
            } catch {
                errorText = error.localizedDescription
                refreshInstallState()
            }
            isPreparing = false
        }
    }
}
#endif

#if os(macOS)
/// Picks the streaming model's chunk size, which is the latency of the text
/// behind the voice. Each option is a separate ~650 MB export of the same
/// model, so changing it downloads once and reloads the engine.
struct LocalEngineLatencyRow: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(LocalEngineLatency.storageKey, store: AppEnvironment.defaults) private var raw = LocalEngineLatency.default.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L10n.t("settings.engines.latency"), selection: $raw) {
                ForEach(LocalEngineLatency.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            // Same reason as the engine picker: a new chunk size means a new
            // model export, which means retiring the process mid-recording.
            .disabled(appState.isRecording)

            Text(L10n.t("settings.engines.latency.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: raw) { _, _ in
            // A running sidecar holds the old export, so it has to be replaced.
            Task { await appState.reloadLocalEngine() }
        }
    }
}
#endif
