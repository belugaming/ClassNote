import Foundation

final class OpenAICompatibleLLM: LLMProvider, Sendable {
    private let config: ApiConfig

    init(config: ApiConfig) {
        self.config = config
    }

    func chat(messages: [ChatMessage],
              model: String,
              temperature: Double) -> AsyncThrowingStream<String, Error> {
        OpenAIChatClient.chatStream(config: config, messages: messages, model: model, temperature: temperature)
    }

    func chatComplete(messages: [ChatMessage],
                      model: String,
                      temperature: Double) async throws -> String {
        var buf = ""
        for try await d in chat(messages: messages, model: model, temperature: temperature) {
            buf += d
        }
        return buf
    }
}

/// Low-level OpenAI-compatible chat client with SSE streaming.
enum OpenAIChatClient {
    static func chatStream(config: ApiConfig,
                           messages: [ChatMessage],
                           model: String,
                           temperature: Double) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !config.apiKey.isEmpty else { throw EngineError.missingApiKey }
                    let base = config.baseUrl.hasSuffix("/") ? String(config.baseUrl.dropLast()) : config.baseUrl
                    guard let url = URL(string: base + "/chat/completions") else {
                        throw EngineError.networkError("Invalid base URL")
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let payload: [String: Any] = [
                        "model": model,
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                        "temperature": temperature,
                        "stream": true
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (stream, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        throw EngineError.networkError("Non-HTTP response")
                    }
                    if !(200..<300).contains(http.statusCode) {
                        // Drain for error body
                        var data = Data()
                        for try await b in stream { data.append(b) }
                        throw EngineError.httpError(status: http.statusCode,
                                                    body: String(data: data, encoding: .utf8) ?? "")
                    }

                    var buffered = ""
                    for try await line in stream.lines {
                        // SSE frames: lines starting with "data: "
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { continue }
                        if !trimmed.hasPrefix("data:") { continue }
                        let payloadStr = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                        if payloadStr == "[DONE]" { break }

                        guard let data = payloadStr.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let first = choices.first,
                              let delta = first["delta"] as? [String: Any],
                              let content = delta["content"] as? String
                        else { continue }
                        if !content.isEmpty {
                            buffered += content
                            continuation.yield(content)
                        }
                    }
                    _ = buffered
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
