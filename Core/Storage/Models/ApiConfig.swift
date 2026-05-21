import Foundation
import GRDB
import Security

struct ApiConfig: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    var id: Int64 = 1
    var baseUrl: String
    var apiKey: String
    var sttModel: String
    var translationModel: String
    var llmModel: String
    var sttBackend: String  // "openai" | "whisperkit"
    var targetLanguage: String
    var sourceLanguage: String

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
            sourceLanguage: "en"
        )
    }

    var redactedKey: String {
        guard !apiKey.isEmpty else { return "(empty)" }
        let prefix = String(apiKey.prefix(4))
        let suffix = String(apiKey.suffix(4))
        return "\(prefix)…\(suffix)"
    }
}

enum APIKeyStore {
    private static var service: String {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return "com.beluga.classnote.openai-compatible.tests"
        }
        return "com.beluga.classnote.openai-compatible"
    }
    private static let account = "api-key"

    static func read() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw APIKeyStoreError.keychainStatus(status)
        }
        guard let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw APIKeyStoreError.invalidStoredKey
        }
        return key
    }

    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete()
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw APIKeyStoreError.invalidStoredKey
        }

        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw APIKeyStoreError.keychainStatus(status)
        }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.keychainStatus(status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum APIKeyStoreError: LocalizedError {
    case invalidStoredKey
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredKey:
            return "The API key stored in Keychain is not readable."
        case .keychainStatus(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}
