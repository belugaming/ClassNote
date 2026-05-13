import Foundation

/// OpenAI-compatible streaming translator built on /v1/chat/completions with SSE.
/// Returns a stream of delta strings that the caller accumulates.
final class OpenAICompatibleTranslator: TranslationProvider, Sendable {
    private let config: ApiConfig

    init(config: ApiConfig) {
        self.config = config
    }

    func translate(text: String,
                   sourceLanguage: String,
                   targetLanguage: String,
                   context: [String]) -> AsyncThrowingStream<String, Error> {

        let cfg = self.config
        let trimmedContext = Array(context.suffix(4))

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let system = """
                    You are a professional translator for college lectures. Translate the user's text from \(sourceLanguage) to \(targetLanguage).
                    Return ONLY the translated sentence, no explanations, no quotes, no language tags.
                    Preserve technical terms and proper nouns. Keep punctuation natural for \(targetLanguage).
                    """
                    var messages: [ChatMessage] = [.init(role: .system, content: system)]
                    if !trimmedContext.isEmpty {
                        let ctx = "Recent context:\n" + trimmedContext.joined(separator: "\n") + "\n\nNow translate the next line."
                        messages.append(.init(role: .user, content: ctx))
                        messages.append(.init(role: .assistant, content: "Understood. Send the line."))
                    }
                    messages.append(.init(role: .user, content: text))

                    let stream = OpenAIChatClient.chatStream(config: cfg,
                                                              messages: messages,
                                                              model: cfg.translationModel,
                                                              temperature: 0.2)
                    for try await delta in stream {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
