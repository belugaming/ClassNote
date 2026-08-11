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
        .background(Theme.surface.opacity(0.26))
        .id(appState.languageRefreshToken)   // force full re-render on language switch
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: L10n.LanguageOverride = L10n.override
    @AppStorage("overlayCaptionDisplayMode") private var displayModeRaw = OverlayCaptionDisplayMode.bilingual.rawValue
    @AppStorage("overlayCaptionTextSize") private var textSizeRaw = OverlayCaptionTextSize.medium.rawValue
    @AppStorage("overlayCaptionRecentCount") private var recentCountRaw = OverlayCaptionRecentCount.two.rawValue
    @AppStorage("overlayAlwaysOnTop") private var overlayAlwaysOnTop: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
            .padding(20)
        }
        .background(Theme.surface.opacity(0.22))
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

    private let providerPresets: [(label: String, base: String, stt: String, llm: String, color: Color)] = [
        ("OpenAI", "https://api.openai.com/v1", "whisper-1", "gpt-4o-mini", .green),
        ("DeepSeek", "https://api.deepseek.com/v1", "whisper-1", "deepseek-chat", .blue),
        ("Groq", "https://api.groq.com/openai/v1", "whisper-large-v3", "llama-3.1-70b-versatile", .orange),
        ("硅基流动", "https://api.siliconflow.cn/v1", "FunAudioLLM/SenseVoiceSmall", "Qwen/Qwen2.5-7B-Instruct", .purple),
        ("Ollama", "http://localhost:11434/v1", "whisper-1", "llama3.1", .pink),
        ("LM Studio", "http://localhost:1234/v1", "whisper-1", "local-model", .cyan),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: L10n.t("settings.api.presets")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                        ForEach(providerPresets, id: \.label) { preset in
                            Button {
                                updateConfig(immediate: true) { config in
                                    config.baseUrl = preset.base
                                    config.sttModel = preset.stt
                                    config.translationModel = preset.llm
                                    config.llmModel = preset.llm
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(preset.color).frame(width: 7, height: 7)
                                    Text(preset.label)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(preset.color.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(preset.color.opacity(0.25), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
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
                            TextField("en", text: sourceLanguageBinding).textFieldStyle(.roundedBorder)
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
                    .disabled(appState.apiConfig.baseUrl.isEmpty || appState.apiConfig.apiKey.isEmpty)

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
            .padding(20)
        }
        .background(Theme.surface.opacity(0.22))
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

    private var targetLanguageBinding: Binding<String> {
        Binding(get: { appState.apiConfig.targetLanguage },
                set: { newValue in
                    updateConfig { $0.targetLanguage = newValue }
                })
    }
}

private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: - Engines

struct EngineSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: L10n.t("settings.engines.stt")) {
                    Picker(L10n.t("settings.engines.sttPicker"), selection: $appState.sttBackend) {
                        ForEach(SttBackend.allCases) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if appState.sttBackend == .whisperKitLocal {
                        Label(L10n.t("settings.engines.whisperKitNote"), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
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
                        if appState.translationBackend == .appleTranslation {
                            Label(L10n.t("settings.engines.appleTranslationNote"), systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
            .padding(20)
        }
        .background(Theme.surface.opacity(0.22))
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
            Task { await appState.saveConfig(config) }
        }
        .onChange(of: appState.translationBackend) { _, backend in
            guard appState.apiConfig.translationBackend != backend.rawValue else { return }
            var config = appState.apiConfig
            config.translationBackend = backend.rawValue
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
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: L10n.t("settings.shortcuts.global"),
                                footer: L10n.t("settings.shortcuts.note")) {
                    ShortcutRow(label: L10n.t("settings.shortcuts.toggleRecording"), name: .toggleRecording, icon: "record.circle")
                    ShortcutRow(label: L10n.t("settings.shortcuts.markHighlight"), name: .markHighlight, icon: "star.circle")
                    ShortcutRow(label: L10n.t("settings.shortcuts.toggleTranslation"), name: .toggleTranslation, icon: "character.bubble")
                    ShortcutRow(label: L10n.t("settings.shortcuts.toggleOverlay"), name: .toggleOverlay, icon: "rectangle.on.rectangle")
                }
            }
            .padding(20)
        }
        .background(Theme.surface.opacity(0.22))
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
            Text(L10n.t("settings.about.version"))
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
