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
            translationBackend: "openai"
        )
    }

    var redactedKey: String {
        guard !apiKey.isEmpty else { return "(empty)" }
        let prefix = String(apiKey.prefix(4))
        let suffix = String(apiKey.suffix(4))
        return "\(prefix)…\(suffix)"
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
