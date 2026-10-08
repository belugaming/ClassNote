import XCTest
@testable import ClassNote

final class AnthropicRequestTests: XCTestCase {
    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEndpointAcceptsSDKAndV1StyleBaseUrls() {
        let expected = "https://api.anthropic.com/v1/messages"
        XCTAssertEqual(AnthropicMessagesClient.endpoint(baseUrl: "https://api.anthropic.com")?.absoluteString, expected)
        XCTAssertEqual(AnthropicMessagesClient.endpoint(baseUrl: "https://api.anthropic.com/")?.absoluteString, expected)
        XCTAssertEqual(AnthropicMessagesClient.endpoint(baseUrl: "https://api.anthropic.com/v1")?.absoluteString, expected)
        XCTAssertEqual(AnthropicMessagesClient.endpoint(baseUrl: " https://api.anthropic.com/v1/messages ")?.absoluteString,
                       expected)
        XCTAssertEqual(AnthropicMessagesClient.endpoint(baseUrl: "https://relay.example.test/claude")?.absoluteString,
                       "https://relay.example.test/claude/v1/messages")
    }

    func testRequestMovesSystemToTopLevelAndSendsEffortNotTemperature() throws {
        var config = ApiConfig.default
        config.anthropicApiKey = "sk-ant-test"
        let request = try AnthropicMessagesClient.request(config: config, messages: [
            .init(role: .system, content: "Be brief."),
            .init(role: .user, content: "Lecture transcript: …"),
            .init(role: .assistant, content: "   "),
            .init(role: .user, content: "What was the main idea?"),
        ], model: "claude-opus-5-5")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try bodyJSON(request)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["system"] as? String, "Be brief.")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNotNil(body["max_tokens"] as? Int)
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        // Adaptive is the only thinking mode current models take; disabled or
        // a token budget is a 400. Summarized, so progress can be shown.
        let thinking = try XCTUnwrap(body["thinking"] as? [String: String])
        XCTAssertEqual(thinking, ["type": "adaptive", "display": "summarized"])
        // Rejected by current models.
        XCTAssertNil(body["temperature"])

        // The blank assistant turn is dropped: the API rejects empty text.
        let turns = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(turns.map { $0["role"] }, ["user", "user"])
        XCTAssertEqual(turns.last?["content"], "What was the main idea?")
    }

    func testEmptyEffortIsNotSent() throws {
        var config = ApiConfig.default
        config.anthropicEffort = ""
        let request = try AnthropicMessagesClient.request(config: config,
                                                          messages: [.init(role: .user, content: "hi")],
                                                          model: "claude-haiku-4-5")
        XCTAssertNil(try bodyJSON(request)["output_config"])
        XCTAssertNil(try bodyJSON(request)["thinking"])
    }

    func testCachedPrefixCarriesACacheBreakpoint() throws {
        let request = try AnthropicMessagesClient.request(config: .default, messages: [
            .init(role: .system, content: "Answer about the lecture."),
            .init(role: .user, content: "Lecture transcript: …", endsCachedPrefix: true),
            .init(role: .user, content: "What was the main idea?"),
        ], model: "claude-opus-5-5")
        let turns = try XCTUnwrap(try bodyJSON(request)["messages"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 2)

        let blocks = try XCTUnwrap(turns[0]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
        XCTAssertEqual(blocks[0]["text"] as? String, "Lecture transcript: …")
        XCTAssertEqual((blocks[0]["cache_control"] as? [String: String])?["type"], "ephemeral")
        // The moving part after the breakpoint stays a plain string.
        XCTAssertEqual(turns[1]["content"] as? String, "What was the main idea?")
    }

    func testServerFallbackOnlyOnAnthropicsOwnApiAndKnownModels() throws {
        XCTAssertTrue(AnthropicMessagesClient.usesServerFallback(baseUrl: "https://api.anthropic.com",
                                                                 model: "claude-opus-5-5"))
        XCTAssertFalse(AnthropicMessagesClient.usesServerFallback(baseUrl: "https://relay.example.test",
                                                                  model: "claude-opus-5-5"))
        XCTAssertFalse(AnthropicMessagesClient.usesServerFallback(baseUrl: "https://api.anthropic.com",
                                                                  model: "claude-haiku-4-5"))

        var config = ApiConfig.default
        config.anthropicApiKey = "sk-ant-test"
        let official = try AnthropicMessagesClient.request(config: config,
                                                           messages: [.init(role: .user, content: "hi")],
                                                           model: "claude-opus-5-5")
        XCTAssertEqual(official.value(forHTTPHeaderField: "anthropic-beta"), AnthropicMessagesClient.fallbackBeta)
        XCTAssertEqual(try bodyJSON(official)["fallbacks"] as? String, "default")

        config.anthropicBaseUrl = "https://relay.example.test"
        let relay = try AnthropicMessagesClient.request(config: config,
                                                        messages: [.init(role: .user, content: "hi")],
                                                        model: "claude-opus-5-5")
        XCTAssertNil(relay.value(forHTTPHeaderField: "anthropic-beta"))
        XCTAssertNil(try bodyJSON(relay)["fallbacks"])
    }

    func testCredentialIsOnlyRequiredOffTheLocalNetwork() {
        var config = ApiConfig.default
        XCTAssertTrue(config.isAnthropicCredentialMissing)
        config.anthropicBaseUrl = "http://127.0.0.1:8082"
        XCTAssertFalse(config.isAnthropicCredentialMissing)
    }

    func testActiveModelFollowsTheBackend() {
        var config = ApiConfig.default
        config.llmModel = "gpt-4o-mini"
        config.anthropicModel = "claude-opus-5-5"
        XCTAssertEqual(config.activeLLMModel, "gpt-4o-mini")
        config.llmBackend = LLMBackend.anthropic.rawValue
        XCTAssertEqual(config.activeLLMModel, "claude-opus-5-5")
    }
}

final class AnthropicStreamParserTests: XCTestCase {
    private func feed(_ lines: [String]) -> (AnthropicStreamParser, [AnthropicStreamParser.Event]) {
        var parser = AnthropicStreamParser()
        var events: [AnthropicStreamParser.Event] = []
        for line in lines {
            if let event = parser.feed(line) { events.append(event) }
        }
        return (parser, events)
    }

    func testTextAndThinkingComeOutSeparately() throws {
        let (parser, events) = feed([
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":40,"cache_read_input_tokens":9000,"cache_creation_input_tokens":0}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Reading the transcript"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"Outlining"}}"#,
            #"data: {"type":"ping"}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#,
            ##"data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"# Notes"}}"##,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        XCTAssertEqual(events, [.thinking("Reading the transcript"), .thinking("\n\n"), .thinking("Outlining"),
                                .text("# Notes"), .done])
        XCTAssertEqual(parser.stopReason, "end_turn")
        XCTAssertEqual(parser.inputTokens, 40)
        XCTAssertEqual(parser.cacheReadTokens, 9000)
        XCTAssertEqual(parser.cacheWriteTokens, 0)
        XCTAssertNoThrow(try parser.finish())
    }

    func testRefusalThrowsWithItsCategory() {
        let (parser, _) = feed([
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Partial"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"bio"}}}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        XCTAssertThrowsError(try parser.finish()) { error in
            guard let engineError = error as? EngineError,
                  case .refused(let category) = engineError else {
                return XCTFail("Expected a refusal, got \(error)")
            }
            XCTAssertEqual(category, "bio")
        }
    }

    func testErrorEventEndsTheStreamAndThrows() {
        let (parser, events) = feed([
            "event: error",
            #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        ])
        XCTAssertEqual(events, [.done])
        XCTAssertThrowsError(try parser.finish()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Overloaded"), error.localizedDescription)
        }
    }
}

/// End to end against the local mock server from `OpenAIHTTPIntegrationTests`.
final class AnthropicHTTPIntegrationTests: XCTestCase {
    private var server: MockHTTPServer!
    private var port: UInt16 = 0

    override func setUp() async throws {
        try await super.setUp()
        server = MockHTTPServer()
        port = try await server.start()
    }

    override func tearDown() async throws {
        await server.stop()
        try await super.tearDown()
    }

    private var config: ApiConfig {
        var config = ApiConfig.default
        config.anthropicBaseUrl = "http://127.0.0.1:\(port)"
        config.anthropicApiKey = "sk-ant-test"
        return config
    }

    func testChatStreamsTextFromTheMessagesEndpoint() async throws {
        await server.setHandler { requestLine, _ in
            guard requestLine.hasPrefix("POST /v1/messages ") else {
                return MockHTTPResponse(status: 404, headers: [:], body: "")
            }
            let body = """
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5"}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}

            event: content_block_start
            data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" world"}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

            event: message_stop
            data: {"type":"message_stop"}


            """
            return MockHTTPResponse(status: 200,
                                    headers: ["Content-Type": "text/event-stream"],
                                    body: body)
        }

        let llm = AnthropicLLM(config: config)
        let messages: [ChatMessage] = [.init(role: .system, content: "sys"), .init(role: .user, content: "hi")]
        let out = try await llm.chatComplete(messages: messages, model: "claude-opus-5-5", temperature: 0.3)
        XCTAssertEqual(out, "Hello world")

        var events: [ChatStreamEvent] = []
        for try await event in llm.chatEvents(messages: messages, model: "claude-opus-5-5", temperature: 0.3) {
            events.append(event)
        }
        XCTAssertEqual(events, [.thinking("hmm"), .text("Hello"), .text(" world")])
    }

    func testHTTPErrorSurfacesTheStatus() async throws {
        await server.setHandler { _, _ in
            MockHTTPResponse(status: 401,
                             headers: ["Content-Type": "application/json"],
                             body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        }
        do {
            _ = try await AnthropicLLM(config: config).chatComplete(
                messages: [.init(role: .user, content: "hi")], model: "claude-opus-5-5", temperature: 0)
            XCTFail("Expected an error")
        } catch EngineError.httpError(let status, let body) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("invalid x-api-key"), body)
        }
    }
}

final class ChatEventsDefaultTests: XCTestCase {
    /// An engine with no reasoning to show gets `chatEvents` for free, as text.
    private struct TextOnlyLLM: LLMProvider {
        func chat(messages: [ChatMessage], model: String, temperature: Double) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("a")
                continuation.yield("b")
                continuation.finish()
            }
        }

        func chatComplete(messages: [ChatMessage], model: String, temperature: Double) async throws -> String {
            "ab"
        }
    }

    func testDefaultChatEventsCarriesTheTextOnly() async throws {
        var events: [ChatStreamEvent] = []
        for try await event in TextOnlyLLM().chatEvents(messages: [], model: "m", temperature: 0) {
            events.append(event)
        }
        XCTAssertEqual(events, [.text("a"), .text("b")])
    }
}

final class LecturePromptTests: XCTestCase {
    private let segments: [Segment] = [
        Segment(id: 1, sessionId: "s", startMs: 0, endMs: 900, speakerId: nil,
                textOriginal: "Today: eigenvalues.", textTranslated: "今天：特征值。",
                isFinal: true, confidence: 0, version: 1),
        Segment(id: 2, sessionId: "s", startMs: 61_000, endMs: 62_000, speakerId: nil,
                textOriginal: "A matrix acts on a vector.", textTranslated: "",
                isFinal: true, confidence: 0, version: 1),
    ]

    /// The rendered request body up to and including the cache breakpoint.
    private func cachedPrefix(_ messages: [ChatMessage]) throws -> String {
        let body = AnthropicMessagesClient.requestBody(messages: messages, model: "claude-opus-5-5",
                                                       effort: "medium", serverFallback: false)
        let turns = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let opening: [String: Any] = ["system": body["system"] ?? "", "first": turns[0]]
        let data = try JSONSerialization.data(withJSONObject: opening, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    func testEveryFeatureSharesOneCachedOpening() throws {
        let notes = LecturePrompt.messages(courseContext: "Course: Linear Algebra", instructions: "Write notes.",
                                           legacyUser: "unused", segments: segments, sharedCache: true)
        let highlight = LecturePrompt.messages(courseContext: "Course: Linear Algebra", instructions: "Explain.",
                                               legacyUser: "unused", segments: segments,
                                               task: "The range: …", sharedCache: true)
        let qa = LecturePrompt.messages(courseContext: "Course: Linear Algebra", instructions: "Answer.",
                                        legacyUser: "unused", segments: segments,
                                        followUp: [.init(role: .user, content: "Why?")], sharedCache: true)

        XCTAssertEqual(try cachedPrefix(notes), try cachedPrefix(highlight))
        XCTAssertEqual(try cachedPrefix(notes), try cachedPrefix(qa))

        XCTAssertTrue(notes[1].endsCachedPrefix)
        XCTAssertTrue(notes[1].content.contains("[01:01] A matrix acts on a vector."), notes[1].content)
        XCTAssertTrue(notes[1].content.contains("译文: 今天：特征值。"), notes[1].content)
        XCTAssertEqual(notes[2].content, "Write notes.")
        XCTAssertEqual(highlight[2].content, "Explain.\n\nThe range: …")
        XCTAssertEqual(qa.last?.content, "Why?")
        XCTAssertEqual(notes.filter(\.endsCachedPrefix).count, 1)
    }

    func testEnginesWithoutACacheKeepTheirLayout() {
        let messages = LecturePrompt.messages(courseContext: "Course: Linear Algebra", instructions: "Write notes.",
                                              legacyUser: "Transcript:\n[00:00] Today: eigenvalues.",
                                              segments: segments, sharedCache: false)
        XCTAssertEqual(messages.map(\.role), [.system, .user])
        XCTAssertEqual(messages[0].content, "Course: Linear Algebra\n\nWrite notes.")
        XCTAssertEqual(messages[1].content, "Transcript:\n[00:00] Today: eigenvalues.")
        XCTAssertFalse(messages.contains(where: \.endsCachedPrefix))

        let noCourse = LecturePrompt.messages(courseContext: "", instructions: "Write notes.",
                                              legacyUser: "x", segments: segments, sharedCache: false)
        XCTAssertEqual(noCourse[0].content, "Write notes.")
    }

    func testOnlyClaudeCachesPrompts() {
        XCTAssertTrue(AnthropicLLM(config: .default).cachesPrompts)
        XCTAssertFalse(OpenAICompatibleLLM(config: .default).cachesPrompts)
    }
}
