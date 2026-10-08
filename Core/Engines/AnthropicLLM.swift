import Foundation

/// Notes, Q&A and highlight explanations through Anthropic's Messages API
/// (`POST /v1/messages`), against Anthropic itself or a relay that speaks the
/// same protocol. There is no official Anthropic SDK for Swift, so this is raw
/// HTTP + SSE like `OpenAIChatClient`.
final class AnthropicLLM: LLMProvider, Sendable {
    private let config: ApiConfig

    init(config: ApiConfig) {
        self.config = config
    }

    /// `temperature` is not sent: current Claude models reject sampling
    /// parameters with a 400, and the callers' 0.2–0.3 is only a nudge.
    /// Thinking is not configured either: on current models it is always on
    /// (disabling it or giving it a token budget is a 400), and effort,
    /// sent from the settings, is what decides how much of it there is.
    func chat(messages: [ChatMessage],
              model: String,
              temperature: Double) -> AsyncThrowingStream<String, Error> {
        AnthropicMessagesClient.stream(config: config, messages: messages, model: model)
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

/// Low-level Anthropic Messages client with SSE streaming.
enum AnthropicMessagesClient {
    static let apiVersion = "2023-06-01"
    /// A whole lecture's notes come back in one reply, and the cap covers the
    /// thinking as well as the text, so leave plenty of room.
    static let maxTokens = 64_000

    /// Models that take server-side refusal fallback on Anthropic's own API: a
    /// declined request is re-run on the model Anthropic recommends for that
    /// refusal category, inside the same stream. A relay or another model may
    /// reject the parameter, so it is only sent where it is known to work.
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    private static let fallbackModels: Set<String> = [
        "claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5",
    ]

    /// `https://api.anthropic.com` (what the SDKs take) and `…/v1` (what
    /// OpenAI-style settings look like) both resolve to `…/v1/messages`.
    static func endpoint(baseUrl: String) -> URL? {
        var base = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1/messages") { return URL(string: base) }
        if !base.hasSuffix("/v1") { base += "/v1" }
        return URL(string: base + "/messages")
    }

    static func usesServerFallback(baseUrl: String, model: String) -> Bool {
        URL(string: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines))?.host == "api.anthropic.com"
            && fallbackModels.contains(model)
    }

    /// System messages become the top-level `system` field; the API takes only
    /// user and assistant turns, and rejects one with no text in it.
    static func requestBody(messages: [ChatMessage],
                            model: String,
                            effort: String,
                            serverFallback: Bool) -> [String: Any] {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let turns = messages.filter {
            $0.role != .system && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": turns.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        if !system.isEmpty { body["system"] = system }
        if !effort.isEmpty { body["output_config"] = ["effort": effort] }
        if serverFallback { body["fallbacks"] = "default" }
        return body
    }

    static func request(config: ApiConfig, messages: [ChatMessage], model: String) throws -> URLRequest {
        guard let url = endpoint(baseUrl: config.anthropicBaseUrl) else {
            throw EngineError.networkError("Invalid base URL")
        }
        let serverFallback = usesServerFallback(baseUrl: config.anthropicBaseUrl, model: model)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Idle time between bytes, not the whole reply: thinking over a long
        // transcript can go quiet for a while before the first text.
        req.timeoutInterval = 300
        // A relay on this machine may issue no key at all.
        if !config.anthropicApiKey.isEmpty {
            req.setValue(config.anthropicApiKey, forHTTPHeaderField: "x-api-key")
        }
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        if serverFallback {
            req.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(messages: messages,
                                        model: model,
                                        effort: config.anthropicEffort,
                                        serverFallback: serverFallback))
        return req
    }

    static func stream(config: ApiConfig,
                       messages: [ChatMessage],
                       model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try request(config: config, messages: messages, model: model)
                    let (stream, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        throw EngineError.networkError("Non-HTTP response")
                    }
                    if !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await b in stream { data.append(b) }
                        throw EngineError.httpError(status: http.statusCode,
                                                    body: String(data: data, encoding: .utf8) ?? "")
                    }

                    var parser = AnthropicStreamParser()
                    for try await line in stream.lines {
                        guard let event = parser.feed(line) else { continue }
                        guard case .text(let text) = event else { break }
                        continuation.yield(text)
                    }
                    try parser.finish()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Reads the Messages API's SSE stream one line at a time. Only `text_delta`s
/// reach the caller: thinking blocks are the model's reasoning and must not
/// end up in the note, and the `fallback` marker a server-side fallback leaves
/// is bookkeeping (the new model continues the same text).
struct AnthropicStreamParser {
    enum Event: Equatable {
        case text(String)
        case done
    }

    private(set) var stopReason: String?
    private(set) var refusalCategory: String?
    private var streamError: EngineError?

    mutating func feed(_ line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }

        switch type {
        case "content_block_delta":
            guard let delta = obj["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty
            else { return nil }
            return .text(text)
        case "message_delta":
            if let delta = obj["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                stopReason = reason
                refusalCategory = (delta["stop_details"] as? [String: Any])?["category"] as? String
            }
            return nil
        case "message_stop":
            return .done
        case "error":
            // An overload or similar after the 200 has gone out arrives here
            // rather than as an HTTP status.
            let error = obj["error"] as? [String: Any]
            let kind = error?["type"] as? String ?? "error"
            let message = error?["message"] as? String ?? ""
            streamError = EngineError.networkError(message.isEmpty ? kind : "\(kind): \(message)")
            return .done
        default:
            return nil
        }
    }

    /// Throws for a stream that ended on an error event or a refusal. A
    /// refusal can come after some text has streamed; that partial answer is
    /// not one to keep.
    func finish() throws {
        if let streamError { throw streamError }
        if stopReason == "refusal" { throw EngineError.refused(category: refusalCategory) }
    }
}
