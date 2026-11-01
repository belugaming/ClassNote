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
                    let base = config.baseUrl.hasSuffix("/") ? String(config.baseUrl.dropLast()) : config.baseUrl
                    guard let url = URL(string: base + "/chat/completions") else {
                        throw EngineError.networkError("Invalid base URL")
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    // Loopback servers (Ollama, LM Studio, llama.cpp, vLLM
                    // without --api-key) issue no token and reject one they
                    // never issued, so an empty key is a valid configuration
                    // rather than something to refuse before trying.
                    if !config.apiKey.isEmpty {
                        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let stream = try await open(req, config: config, messages: messages,
                                                model: model, temperature: temperature)

                    var filter = ThinkTagFilter()
                    for try await line in stream.lines {
                        // SSE frames: lines starting with "data: "
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { continue }
                        if !trimmed.hasPrefix("data:") { continue }
                        let payloadStr = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                        if payloadStr == "[DONE]" { break }

                        guard let data = payloadStr.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        // A failure after the 200 has gone out arrives as a
                        // frame. Ending normally there saved a truncated note
                        // as if it were complete.
                        if let failure = streamFailure(in: obj) { throw failure }
                        guard let choices = obj["choices"] as? [[String: Any]],
                              let first = choices.first,
                              let delta = first["delta"] as? [String: Any]
                        else { continue }
                        // Ignore OpenAI-style separate reasoning field (DeepSeek-R1, etc.):
                        // `delta.reasoning_content` is the model's internal thinking and
                        // must not end up in the note body.
                        if let content = delta["content"] as? String, !content.isEmpty {
                            let cleaned = filter.feed(content)
                            if !cleaned.isEmpty {
                                continuation.yield(cleaned)
                            }
                        }
                    }
                    let tail = filter.flush()
                    if !tail.isEmpty { continuation.yield(tail) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sends the request and returns the event stream once it is a 2xx.
    ///
    /// Reasoning models (the o-series, gpt-5) take only the default
    /// temperature and answer any other with a 400 that names it. Those known
    /// to are sent none; any other that refuses it gets one retry without it,
    /// and none from then on.
    private static func open(_ request: URLRequest,
                             config: ApiConfig,
                             messages: [ChatMessage],
                             model: String,
                             temperature: Double) async throws -> URLSession.AsyncBytes {
        var request = request
        var sendsTemperature = !isReasoningModel(model)
            && !OpenAIRejectedParameters.shared.contains("temperature", baseUrl: config.baseUrl, model: model)
        while true {
            var payload: [String: Any] = [
                "model": model,
                "messages": messages.mergingConsecutiveRoles.map {
                    ["role": $0.role.rawValue, "content": $0.content]
                },
                "stream": true
            ]
            if sendsTemperature { payload["temperature"] = temperature }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (stream, resp) = try await URLSession.shared.bytes(for: request)
            guard let http = resp as? HTTPURLResponse else {
                throw EngineError.networkError("Non-HTTP response")
            }
            if (200..<300).contains(http.statusCode) { return stream }
            // Drain for error body
            var data = Data()
            for try await b in stream { data.append(b) }
            if sendsTemperature, [400, 422].contains(http.statusCode),
               OpenAIRejectedParameters.blames(data, "temperature") {
                OpenAIRejectedParameters.shared.insert("temperature", baseUrl: config.baseUrl, model: model)
                sendsTemperature = false
                continue
            }
            throw EngineError.httpError(status: http.statusCode,
                                        body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// OpenAI's reasoning models, which reject a non-default temperature.
    /// `gpt-5-chat` is the non-reasoning variant and takes one. Provider
    /// prefixes (`openai/o3` on OpenRouter) are ignored.
    static func isReasoningModel(_ model: String) -> Bool {
        let id = model.split(separator: "/").last.map { $0.lowercased() } ?? ""
        if id.hasPrefix("gpt-5") { return !id.contains("chat") }
        guard id.count >= 2, id.first == "o" else { return false }
        return id.dropFirst().first?.isNumber == true
    }

    /// The error an SSE frame reports, if it reports one.
    ///
    /// OpenRouter sends `{"error":{…},"choices":[{…,"finish_reason":"error"}]}`
    /// when the upstream provider fails mid-answer; vLLM sends a bare
    /// `{"error":{…}}`.
    static func streamFailure(in frame: [String: Any]) -> EngineError? {
        let choices = frame["choices"] as? [[String: Any]] ?? []
        let finishedOnError = choices.contains { $0["finish_reason"] as? String == "error" }
        var detail: String?
        let error: Any = frame["error"] ?? NSNull()
        switch error {
        case let object as [String: Any]:
            let message = object["message"] as? String ?? ""
            let kind = (object["code"] as? String)
                ?? (object["code"] as? Int).map(String.init)
                ?? (object["type"] as? String)
            switch (kind, message.isEmpty) {
            case (let kind?, false): detail = "\(kind): \(message)"
            case (let kind?, true): detail = kind
            case (nil, false): detail = message
            case (nil, true): detail = "error"
            }
        case let message as String where !message.isEmpty:
            detail = message
        default:
            break
        }
        guard detail != nil || finishedOnError else { return nil }
        return .networkError(detail ?? "finish_reason: error")
    }
}

/// Request parameters a provider has refused for a model, remembered for the
/// rest of the run so later requests leave them out instead of failing first.
/// Keyed by base URL and model, since one model id can mean different things
/// on two providers.
final class OpenAIRejectedParameters: @unchecked Sendable {
    static let shared = OpenAIRejectedParameters()

    private let lock = NSLock()
    private var rejected: Set<String> = []

    func contains(_ parameter: String, baseUrl: String, model: String) -> Bool {
        let key = Self.key(parameter, baseUrl, model)
        return lock.withLock { rejected.contains(key) }
    }

    func insert(_ parameter: String, baseUrl: String, model: String) {
        let key = Self.key(parameter, baseUrl, model)
        _ = lock.withLock { rejected.insert(key) }
    }

    private static func key(_ parameter: String, _ baseUrl: String, _ model: String) -> String {
        "\(parameter)\u{1F}\(baseUrl)\u{1F}\(model)"
    }

    /// Whether an error body blames `parameter`. OpenAI names it in
    /// `error.param`; other servers only in the message, so the whole body is
    /// searched.
    static func blames(_ body: Data, _ parameter: String) -> Bool {
        guard let text = String(data: body, encoding: .utf8) else { return false }
        return text.range(of: parameter, options: .caseInsensitive) != nil
    }
}

/// Streaming filter that strips reasoning blocks embedded in `delta.content`.
/// Qwen / QwQ / Ollama wrappers emit raw `<think>…</think>` (and variants) in
/// the normal content channel — without stripping, the model's chain-of-thought
/// lands in the user's note markdown.
struct ThinkTagFilter {
    private var buffer: String = ""
    private var inside: Bool = false

    // Open/close pairs we want to drop entirely. Order matters: longest first so
    // `<|begin_of_thinking|>` wins over any shorter prefix collision.
    private static let pairs: [(open: String, close: String)] = [
        ("<|begin_of_thinking|>", "<|end_of_thinking|>"),
        ("<think>", "</think>"),
        ("<thinking>", "</thinking>"),
        ("<reasoning>", "</reasoning>"),
    ]

    mutating func feed(_ chunk: String) -> String {
        buffer += chunk
        var out = ""
        while !buffer.isEmpty {
            if inside {
                // Look for any close tag; if none fully arrived, hold the buffer.
                if let (close, range) = firstMatch(of: Self.pairs.map { $0.close }) {
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    inside = false
                    _ = close
                } else if let partial = trailingPartialMatch(of: Self.pairs.map { $0.close }) {
                    // Potential close tag is still streaming in — keep buffering.
                    _ = partial
                    return out
                } else {
                    // No close tag in sight; keep discarding but retain a short
                    // tail so we don't miss a boundary that lands on the next chunk.
                    let safeKeep = 32
                    if buffer.count > safeKeep {
                        buffer.removeFirst(buffer.count - safeKeep)
                    }
                    return out
                }
            } else {
                if let (_, range) = firstMatch(of: Self.pairs.map { $0.open }) {
                    out += buffer[buffer.startIndex..<range.lowerBound]
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    inside = true
                } else if let partial = trailingPartialMatch(of: Self.pairs.map { $0.open }) {
                    // Flush what precedes the potential-open prefix; keep the
                    // prefix buffered until we know whether it becomes a tag.
                    let keepFrom = buffer.index(buffer.endIndex, offsetBy: -partial.count)
                    out += buffer[buffer.startIndex..<keepFrom]
                    buffer = String(buffer[keepFrom...])
                    return out
                } else {
                    out += buffer
                    buffer.removeAll(keepingCapacity: true)
                    return out
                }
            }
        }
        return out
    }

    mutating func flush() -> String {
        // Stream ended mid-tag: drop unterminated thinking; emit any tail otherwise.
        if inside {
            buffer.removeAll(keepingCapacity: true)
            inside = false
            return ""
        }
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        return out
    }

    private func firstMatch(of needles: [String]) -> (String, Range<String.Index>)? {
        var best: (String, Range<String.Index>)?
        for n in needles {
            if let r = buffer.range(of: n) {
                if best == nil || r.lowerBound < best!.1.lowerBound {
                    best = (n, r)
                }
            }
        }
        return best
    }

    /// Longest suffix of `buffer` that is a strict prefix of some needle.
    private func trailingPartialMatch(of needles: [String]) -> String? {
        var longest: String?
        for n in needles {
            let maxK = min(n.count - 1, buffer.count)
            if maxK <= 0 { continue }
            for k in stride(from: maxK, through: 1, by: -1) {
                let suffix = String(buffer.suffix(k))
                if n.hasPrefix(suffix) {
                    if longest == nil || suffix.count > longest!.count {
                        longest = suffix
                    }
                    break
                }
            }
        }
        return longest
    }
}
