import Foundation
import GRDB

struct ApiConfig: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    var id: Int64 = 1
    var baseUrl: String
    var apiKey: String
    var sttModel: String
    var translationModel: String
    var llmModel: String
    var sttBackend: String  // "openai" | "apple" | "funasr" (see SttBackend.resolve)
    var targetLanguage: String
    var sourceLanguage: String
    var translationBackend: String  // "openai" | "apple"
    var llmBackend: String  // "openai" | "mlx" | "anthropic"
    /// The Anthropic Messages API endpoint, separate from `baseUrl` so notes
    /// can go to Claude while transcription stays on Whisper or a local engine.
    var anthropicBaseUrl: String
    var anthropicApiKey: String
    var anthropicModel: String
    /// `output_config.effort`: how much Claude thinks before answering, the
    /// only thinking control on current models. Empty sends nothing, for a
    /// model or relay that rejects the field.
    var anthropicEffort: String

    enum CodingKeys: String, CodingKey {
        case id
        case baseUrl = "base_url"
        case apiKey = "api_key"
        case sttModel = "stt_model"
        case translationModel = "translation_model"
        case llmModel = "llm_model"
        case sttBackend = "stt_backend"
        case targetLanguage = "target_language"
        case sourceLanguage = "source_language"
        case translationBackend = "translation_backend"
        case llmBackend = "llm_backend"
        case anthropicBaseUrl = "anthropic_base_url"
        case anthropicApiKey = "anthropic_api_key"
        case anthropicModel = "anthropic_model"
        case anthropicEffort = "anthropic_effort"
    }

    static let databaseTableName = "api_config"

    static let defaultAnthropicBaseUrl = "https://api.anthropic.com"
    static let defaultAnthropicModel = "claude-opus-5-5"
    /// Opus 5.5's own default, sent explicitly: other models default higher,
    /// so leaving it out would change behaviour with the model name.
    static let defaultAnthropicEffort = "medium"
    static let anthropicEffortLevels = ["low", "medium", "high", "xhigh", "max"]

    static var `default`: ApiConfig {
        ApiConfig(
            id: 1,
            baseUrl: "https://api.openai.com/v1",
            apiKey: "",
            sttModel: "whisper-1",
            translationModel: "gpt-4o-mini",
            llmModel: "gpt-4o-mini",
            sttBackend: "openai",
            targetLanguage: "zh-Hans",
            sourceLanguage: "en",
            translationBackend: "openai",
            llmBackend: "openai",
            anthropicBaseUrl: defaultAnthropicBaseUrl,
            anthropicApiKey: "",
            anthropicModel: defaultAnthropicModel,
            anthropicEffort: defaultAnthropicEffort
        )
    }

    var redactedKey: String {
        guard !apiKey.isEmpty else { return "(empty)" }
        let prefix = String(apiKey.prefix(4))
        let suffix = String(apiKey.suffix(4))
        return "\(prefix)…\(suffix)"
    }
}

extension ApiConfig {
    // Declared in an extension so the memberwise initializer survives.
    // `ApiConfigBackupStore` decodes JSON written by an older build, and the
    // synthesized decoder would reject every one of those blobs the moment a
    // field is added — silently discarding the backup this store exists for.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(Int64.self, forKey: .id) ?? 1,
            baseUrl: try c.decode(String.self, forKey: .baseUrl),
            apiKey: try c.decode(String.self, forKey: .apiKey),
            sttModel: try c.decode(String.self, forKey: .sttModel),
            translationModel: try c.decode(String.self, forKey: .translationModel),
            llmModel: try c.decode(String.self, forKey: .llmModel),
            sttBackend: try c.decode(String.self, forKey: .sttBackend),
            targetLanguage: try c.decode(String.self, forKey: .targetLanguage),
            sourceLanguage: try c.decode(String.self, forKey: .sourceLanguage),
            translationBackend: try c.decodeIfPresent(String.self, forKey: .translationBackend) ?? "openai",
            llmBackend: try c.decodeIfPresent(String.self, forKey: .llmBackend) ?? "openai",
            anthropicBaseUrl: try c.decodeIfPresent(String.self, forKey: .anthropicBaseUrl)
                ?? Self.defaultAnthropicBaseUrl,
            anthropicApiKey: try c.decodeIfPresent(String.self, forKey: .anthropicApiKey) ?? "",
            anthropicModel: try c.decodeIfPresent(String.self, forKey: .anthropicModel)
                ?? Self.defaultAnthropicModel,
            anthropicEffort: try c.decodeIfPresent(String.self, forKey: .anthropicEffort)
                ?? Self.defaultAnthropicEffort
        )
    }
}

extension ApiConfig {
    /// A known OpenAI-compatible endpoint and the models it actually serves.
    struct ProviderPreset: Identifiable, Hashable, Sendable {
        var id: String { label }
        let label: String
        let baseUrl: String
        /// nil when the provider exposes no OpenAI-compatible
        /// /audio/transcriptions endpoint at all, so there is no STT model to
        /// pick and the user needs a local engine for transcription.
        let sttModel: String?
        let chatModel: String
        /// Loopback providers authenticate by not being reachable from outside
        /// the machine; they reject a bearer token they never issued.
        let requiresApiKey: Bool
    }

    static let providerPresets: [ProviderPreset] = [
        .init(label: "OpenAI",
              baseUrl: "https://api.openai.com/v1",
              sttModel: "whisper-1",
              chatModel: "gpt-4o-mini",
              requiresApiKey: true),
        .init(label: "DeepSeek",
              baseUrl: "https://api.deepseek.com/v1",
              sttModel: nil,
              chatModel: "deepseek-chat",
              requiresApiKey: true),
        .init(label: "Groq",
              baseUrl: "https://api.groq.com/openai/v1",
              sttModel: "whisper-large-v3",
              chatModel: "llama-3.3-70b-versatile",
              requiresApiKey: true),
        .init(label: "硅基流动",
              baseUrl: "https://api.siliconflow.cn/v1",
              sttModel: "FunAudioLLM/SenseVoiceSmall",
              chatModel: "Qwen/Qwen2.5-7B-Instruct",
              requiresApiKey: true),
        .init(label: "Ollama",
              baseUrl: "http://localhost:11434/v1",
              sttModel: nil,
              chatModel: "llama3.1",
              requiresApiKey: false),
        .init(label: "LM Studio",
              baseUrl: "http://localhost:1234/v1",
              sttModel: nil,
              chatModel: "local-model",
              requiresApiKey: false)
    ]

    /// True when this endpoint authenticates with a bearer token. A loopback or
    /// LAN host does not, so an empty key there is a valid configuration rather
    /// than a setup the app should refuse to use.
    var requiresApiKey: Bool {
        if let preset = Self.providerPresets.first(where: { $0.baseUrl == baseUrl }) {
            return preset.requiresApiKey
        }
        return !LocalNetworkAccess.isLocalNetworkHost(baseUrl)
    }

    /// The precondition the cloud engines and the empty-state gates should test,
    /// instead of "the key happens to be empty".
    var isCloudCredentialMissing: Bool {
        requiresApiKey && apiKey.isEmpty
    }

    /// The same test for the Anthropic endpoint. A relay on this machine or the
    /// LAN may take no key; Anthropic's own API always does.
    var isAnthropicCredentialMissing: Bool {
        anthropicApiKey.isEmpty && !LocalNetworkAccess.isLocalNetworkHost(anthropicBaseUrl)
    }

    /// The model the notes & Q&A engine runs, for the request and for the
    /// label stored with what it wrote.
    var activeLLMModel: String {
        LLMBackend(rawValue: llmBackend) == .anthropic ? anthropicModel : llmModel
    }
}

/// The settings in UserDefaults, so a lost or reset database does not take
/// them along (see `ApiConfigRepository.load`). Never the API keys: UserDefaults
/// is a plain-text plist, and the keys live only in the database.
enum ApiConfigBackupStore {
    static let key = "classnote.apiConfig.backup.v1"
    /// Blanked rather than left out, so a build whose decoder requires
    /// `api_key` still reads the backup.
    private static let keyFields = [ApiConfig.CodingKeys.apiKey.rawValue,
                                    ApiConfig.CodingKeys.anthropicApiKey.rawValue]

    static func read(from defaults: UserDefaults = AppEnvironment.defaults) -> ApiConfig? {
        guard let data = defaults.data(forKey: key),
              let backup = try? JSONDecoder().decode(ApiConfig.self, from: data) else { return nil }
        return withoutKeys(backup)
    }

    static func save(_ config: ApiConfig, to defaults: UserDefaults = AppEnvironment.defaults) {
        guard let data = try? JSONEncoder().encode(withoutKeys(config)) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(in defaults: UserDefaults = AppEnvironment.defaults) {
        defaults.removeObject(forKey: key)
    }

    /// Earlier builds wrote the keys into the backup in plain text. Edits the
    /// JSON itself, so a backup the decoder cannot read is cleaned too.
    static func scrubKeys(in defaults: UserDefaults = AppEnvironment.defaults) {
        guard let data = defaults.data(forKey: key) else { return }
        guard var fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Unreadable, so no use as a backup, and it may hold a key.
            defaults.removeObject(forKey: key)
            return
        }
        guard keyFields.contains(where: { fields[$0] != nil && (fields[$0] as? String) != "" }) else { return }
        for field in keyFields where fields[field] != nil { fields[field] = "" }
        guard let scrubbed = try? JSONSerialization.data(withJSONObject: fields) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(scrubbed, forKey: key)
    }

    private static func withoutKeys(_ config: ApiConfig) -> ApiConfig {
        var copy = config
        copy.apiKey = ""
        copy.anthropicApiKey = ""
        return copy
    }
}
