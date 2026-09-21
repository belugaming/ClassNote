import Foundation
import GRDB

struct ApiConfig: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    var id: Int64 = 1
    var baseUrl: String
    var apiKey: String
    var sttModel: String
    var translationModel: String
    var llmModel: String
    var sttBackend: String  // "openai" | "whisperkit" | "apple"
    var targetLanguage: String
    var sourceLanguage: String
    var translationBackend: String  // "openai" | "apple"
    var llmBackend: String  // "openai" | "mlx"

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
    }

    static let databaseTableName = "api_config"

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
            llmBackend: "openai"
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
            llmBackend: try c.decodeIfPresent(String.self, forKey: .llmBackend) ?? "openai"
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
}

enum ApiConfigBackupStore {
    private static let key = "classnote.apiConfig.backup.v1"

    static func read() -> ApiConfig? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ApiConfig.self, from: data)
    }

    static func save(_ config: ApiConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
