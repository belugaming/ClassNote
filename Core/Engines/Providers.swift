import Foundation

struct AudioChunk: Sendable {
    let pcmData: Data    // Int16 little-endian, mono
    let sampleRate: Int  // typically 16000
    let timestamp: Int64 // ms since session start
}

struct TranscriptEvent: Sendable, Identifiable, Hashable {
    let id: UUID
    let startMs: Int64
    let endMs: Int64
    let text: String
    let isFinal: Bool
    let speakerId: String?

    init(startMs: Int64, endMs: Int64, text: String, isFinal: Bool, speakerId: String? = nil) {
        self.id = UUID()
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.isFinal = isFinal
        self.speakerId = speakerId
    }
}

protocol STTProvider: Sendable {
    /// Streams transcript events. The caller is expected to feed audio chunks into the provider.
    /// For cloud chunked providers this will internally batch audio and call REST; for WhisperKit
    /// it will run streaming inference.
    func transcribe(audio: AsyncStream<AudioChunk>,
                    language: String?) -> AsyncThrowingStream<TranscriptEvent, Error>

    /// One-shot transcription for file imports.
    func transcribeFile(url: URL, language: String?) async throws -> [TranscriptEvent]
}

protocol TranslationProvider: Sendable {
    func translate(text: String,
                   sourceLanguage: String,
                   targetLanguage: String,
                   context: [String]) -> AsyncThrowingStream<String, Error>
}

struct ChatMessage: Sendable {
    enum Role: String, Sendable { case system, user, assistant }
    let role: Role
    let content: String
}

protocol LLMProvider: Sendable {
    func chat(messages: [ChatMessage],
              model: String,
              temperature: Double) -> AsyncThrowingStream<String, Error>

    func chatComplete(messages: [ChatMessage],
                      model: String,
                      temperature: Double) async throws -> String
}

enum EngineError: Error, LocalizedError {
    case missingApiKey
    case networkError(String)
    case decodingError(String)
    case httpError(status: Int, body: String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .missingApiKey: return "API key is not configured. Please set it in Settings."
        case .networkError(let m): return "Network error: \(m)"
        case .decodingError(let m): return "Decoding error: \(m)"
        case .httpError(let s, let b): return "HTTP \(s): \(b.prefix(200))"
        case .unsupported(let m): return "Unsupported: \(m)"
        }
    }
}

struct EngineFactory {
    @MainActor
    static func makeSTT(config: ApiConfig, backend: SttBackend) -> STTProvider {
        switch backend {
        case .openAICompatible:
            return OpenAICompatibleSTT(config: config)
        case .whisperKitLocal:
            return OpenAICompatibleSTT(config: config)  // fallback until WhisperKit wired
        }
    }

    @MainActor
    static func makeTranslator(config: ApiConfig) -> TranslationProvider {
        OpenAICompatibleTranslator(config: config)
    }

    @MainActor
    static func makeLLM(config: ApiConfig) -> LLMProvider {
        OpenAICompatibleLLM(config: config)
    }
}
