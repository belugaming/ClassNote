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
    /// True when the engine broke this line only to keep it short and its
    /// sentence carries on in the next final (the local engine's soft cut).
    /// Translation waits for the rest instead of translating half a sentence.
    let continuesSentence: Bool

    init(startMs: Int64, endMs: Int64, text: String, isFinal: Bool, speakerId: String? = nil,
         continuesSentence: Bool = false) {
        self.id = UUID()
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.isFinal = isFinal
        self.speakerId = speakerId
        self.continuesSentence = continuesSentence
    }
}

/// Events emitted during file import. `progress` updates fire on every slice
/// boundary (including before the first slice, with completed=0) so the UI can
/// draw a determinate progress bar without polling.
enum FileTranscriptionEvent: Sendable {
    case progress(completed: Int, total: Int)
    case segment(TranscriptEvent)
}

protocol STTProvider: Sendable {
    /// Streams transcript events. The caller is expected to feed audio chunks into the provider.
    /// For cloud chunked providers this will internally batch audio and call REST; the local
    /// sidecar streams the audio over a WebSocket and runs inference as it arrives.
    func transcribe(audio: AsyncStream<AudioChunk>,
                    language: String?) -> AsyncThrowingStream<TranscriptEvent, Error>

    /// Streaming transcription for file imports. Emits a `.progress` after each
    /// slice and a `.segment` per Whisper segment within that slice, so the UI
    /// can show incremental subtitles and a determinate progress bar.
    func transcribeFile(url: URL,
                        language: String?) -> AsyncThrowingStream<FileTranscriptionEvent, Error>
}

protocol TranslationProvider: Sendable {
    /// - Parameter context: the sentences just before this one, oldest first,
    ///   for the translator to read but not translate.
    /// - Parameter glossary: the course's fixed renderings. Kept separate from
    ///   `context` on purpose: a glossary smuggled in there becomes text to
    ///   translate instead of an instruction.
    func translate(text: String,
                   sourceLanguage: String,
                   targetLanguage: String,
                   context: [String],
                   glossary: TranslationGlossary) -> AsyncThrowingStream<String, Error>
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
        case .missingApiKey: return L10n.t("engine.error.missingApiKey")
        case .networkError(let m): return Self.localized("engine.error.networkError", m)
        case .decodingError(let m): return Self.localized("engine.error.decodingError", m)
        case .httpError(let s, let b): return Self.localized("engine.error.httpError", "\(s)", String(b.prefix(200)))
        case .unsupported(let m): return Self.localized("engine.error.unsupported", m)
        }
    }

    /// Fills a localized template's `%@` placeholders left to right. These are
    /// the only strings in the app that need arguments, so this stays local
    /// rather than becoming a general L10n facility.
    private static func localized(_ key: String, _ arguments: String...) -> String {
        var out = L10n.t(key)
        for argument in arguments {
            guard let range = out.range(of: "%@") else { break }
            out.replaceSubrange(range, with: argument)
        }
        return out
    }
}

struct EngineFactory {
    /// Routes local-engine setup stages into the app's status line. The sidecar
    /// spends ~30s loading models (much longer on a first run that installs
    /// dependencies and downloads them), so without this the app looks hung.
    private static func localEngineProgressSink() -> @Sendable (String) -> Void {
        { stage in
            Task { @MainActor in
                AppState.shared.localEngineStatus = stage
            }
        }
    }

    /// - Parameter hint: what the course is about and its terms, for an engine
    ///   that takes a text prompt (R2T2). The others ignore it.
    @MainActor
    static func makeSTT(config: ApiConfig, backend: SttBackend, hint: String = "") -> STTProvider {
        switch backend {
        case .openAICompatible:
            return OpenAICompatibleSTT(config: config)
        case .appleSpeech:
            return AppleSpeechSTT()
        case .funasr, .nemotronStreaming:
            return LocalWebSocketSTT(engine: .funasr,
                                     language: config.sourceLanguage,
                                     onProgress: Self.localEngineProgressSink())
        case .r2t2:
            return LocalWebSocketSTT(engine: .r2t2,
                                     language: config.sourceLanguage,
                                     hint: hint,
                                     onProgress: Self.localEngineProgressSink())
        }
    }

    @MainActor
    static func makeTranslator(config: ApiConfig, backend: TranslationBackend = .openAICompatible) -> TranslationProvider {
        switch backend {
        case .openAICompatible:
            return OpenAICompatibleTranslator(config: config)
        case .appleTranslation:
            if #available(macOS 15.0, iOS 18.0, *) {
                return AppleTranslationEngine()
            }
            return OpenAICompatibleTranslator(config: config)
        #if os(macOS)
        case .localMLX:
            return LocalMLXTranslator()
        case .t3po:
            // T3PO translates a stream, not single sentences; the orchestrator
            // drives it through `LocalSimulSession`. Anything that needs one
            // sentence translated on its own (a draft line, a language pair
            // T3PO does not cover) gets the local sentence model.
            return LocalMLXTranslator()
        #else
        case .localMLX, .t3po:
            // The sidecar is a Python process, so there is nothing to run on iOS.
            return OpenAICompatibleTranslator(config: config)
        #endif
        }
    }

    @MainActor
    static func makeLLM(config: ApiConfig, backend: LLMBackend = .openAICompatible) -> LLMProvider {
        switch backend {
        case .openAICompatible:
            return OpenAICompatibleLLM(config: config)
        #if os(macOS)
        case .localMLX:
            return LocalMLXLLM()
        #else
        case .localMLX:
            // The sidecar is a Python process, so there is nothing to run on iOS.
            return OpenAICompatibleLLM(config: config)
        #endif
        }
    }
}
