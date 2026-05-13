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

                    var filter = ThinkTagFilter()
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
