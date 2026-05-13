import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            ApiSettingsView()
                .tabItem { Label("API", systemImage: "network") }
            EngineSettingsView()
                .tabItem { Label("Engines", systemImage: "waveform.circle") }
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(16)
    }
}

struct ApiSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var baseUrl: String = ""
    @State private var apiKey: String = ""
    @State private var sttModel: String = ""
    @State private var translationModel: String = ""
    @State private var llmModel: String = ""
    @State private var sourceLanguage: String = ""
    @State private var targetLanguage: String = ""
    @State private var testStatus: String = ""
    @State private var loaded = false

    private let providerPresets: [(label: String, base: String, stt: String, llm: String)] = [
        ("OpenAI official", "https://api.openai.com/v1", "whisper-1", "gpt-4o-mini"),
        ("DeepSeek", "https://api.deepseek.com/v1", "whisper-1", "deepseek-chat"),
        ("Groq", "https://api.groq.com/openai/v1", "whisper-large-v3", "llama-3.1-70b-versatile"),
        ("SiliconFlow", "https://api.siliconflow.cn/v1", "FunAudioLLM/SenseVoiceSmall", "Qwen/Qwen2.5-7B-Instruct"),
        ("Ollama (local)", "http://localhost:11434/v1", "whisper-1", "llama3.1"),
        ("LM Studio", "http://localhost:1234/v1", "whisper-1", "local-model"),
    ]

    var body: some View {
        Form {
            Section("Provider presets") {
                HStack {
                    ForEach(providerPresets, id: \.label) { preset in
                        Button(preset.label) {
                            baseUrl = preset.base
                            sttModel = preset.stt
                            translationModel = preset.llm
                            llmModel = preset.llm
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Section("Endpoint & key") {
                TextField("Base URL", text: $baseUrl, prompt: Text("https://api.openai.com/v1"))
                SecureField("API Key", text: $apiKey, prompt: Text("sk-…"))
                Text("Stored locally in SQLite. Never transmitted except to the endpoint you specify.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Per-capability model IDs") {
                TextField("STT model", text: $sttModel, prompt: Text("whisper-1"))
                TextField("Translation model", text: $translationModel, prompt: Text("gpt-4o-mini"))
                TextField("Note / QA model", text: $llmModel, prompt: Text("gpt-4o-mini"))
            }

            Section("Languages") {
                HStack {
                    TextField("Source (lecture)", text: $sourceLanguage, prompt: Text("en"))
                    TextField("Target (translation)", text: $targetLanguage, prompt: Text("zh-Hans"))
                }
                Text("ISO 639-1 codes. Leave source blank for auto-detect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Save") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Test connection") {
                        Task { await testConnection() }
                    }
                    .disabled(baseUrl.isEmpty || apiKey.isEmpty)
                    if !testStatus.isEmpty {
                        Text(testStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !loaded else { return }
            let c = appState.apiConfig
            baseUrl = c.baseUrl
            apiKey = c.apiKey
            sttModel = c.sttModel
            translationModel = c.translationModel
            llmModel = c.llmModel
            sourceLanguage = c.sourceLanguage
            targetLanguage = c.targetLanguage
            loaded = true
        }
    }

    private func save() {
        var c = appState.apiConfig
        c.baseUrl = baseUrl
        c.apiKey = apiKey
        c.sttModel = sttModel
        c.translationModel = translationModel
        c.llmModel = llmModel
        c.sourceLanguage = sourceLanguage
        c.targetLanguage = targetLanguage
        Task {
            await appState.saveConfig(c)
            testStatus = "Saved."
        }
    }

    private func testConnection() async {
        testStatus = "Testing…"
        var c = appState.apiConfig
        c.baseUrl = baseUrl
        c.apiKey = apiKey
        c.llmModel = llmModel
        let client = OpenAICompatibleLLM(config: c)
        do {
            let out = try await client.chatComplete(messages: [
                .init(role: .system, content: "You are a test bot. Reply with exactly: OK"),
                .init(role: .user, content: "ping")
            ], model: llmModel, temperature: 0)
            testStatus = "OK — got \(out.prefix(40))"
        } catch {
            testStatus = "Failed: \(error.localizedDescription)"
        }
    }
}

struct EngineSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Speech-to-text backend") {
                Picker("STT engine", selection: $appState.sttBackend) {
                    ForEach(SttBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                if appState.sttBackend == .whisperKitLocal {
                    Text("Local WhisperKit is planned for v1.1 via CoreML. For now, switch to OpenAI Compatible.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Default audio source for new sessions can be chosen at record time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Translation") {
                Toggle("Enable live translation", isOn: $appState.translationEnabled)
                Text("When off, only the English transcript is captured. You can retranslate any session later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Application Support", value: AppBootstrap.applicationSupportURL.path)
                LabeledContent("Recordings", value: AppBootstrap.recordingsURL.path)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.open(AppBootstrap.applicationSupportURL)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section("Global shortcuts") {
                KeyboardShortcuts.Recorder("Toggle recording", name: .toggleRecording)
                KeyboardShortcuts.Recorder("Mark highlight", name: .markHighlight)
                KeyboardShortcuts.Recorder("Toggle translation", name: .toggleTranslation)
                KeyboardShortcuts.Recorder("Toggle overlay window", name: .toggleOverlay)
            }
            Section {
                Text("These work anywhere on macOS, even when ClassNote is hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("ClassNote")
                .font(.title.weight(.semibold))
            Text("v0.1.0 — personal build")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Record, transcribe, translate, and organize your US lectures. Your data stays local.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
