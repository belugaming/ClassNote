import XCTest
import Network
@testable import ClassNote

/// Integration tests for the OpenAI-compatible HTTP layer using a local mock server.
final class OpenAIHTTPIntegrationTests: XCTestCase {
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

    func testChatStreamYieldsAccumulatedDeltas() async throws {
        await server.setHandler { _, _ in
            let body = """
            data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n
            data: {"choices":[{"delta":{"content":" "}}]}\n\n
            data: {"choices":[{"delta":{"content":"world"}}]}\n\n
            data: [DONE]\n\n
            """
            return MockHTTPResponse(status: 200,
                                    headers: ["Content-Type": "text/event-stream"],
                                    body: body)
        }

        var config = ApiConfig.default
        config.baseUrl = "http://127.0.0.1:\(port)/v1"
        config.apiKey = "test-key"
        let client = OpenAICompatibleLLM(config: config)
        var collected = ""
        let stream = client.chat(messages: [.init(role: .user, content: "hi")],
                                  model: "test-model", temperature: 0)
        for try await delta in stream {
            collected += delta
        }
        XCTAssertEqual(collected, "Hello world")
    }

    func testChatStreamRaisesOnHTTPError() async throws {
        await server.setHandler { _, _ in
            MockHTTPResponse(status: 401,
                             headers: ["Content-Type": "application/json"],
                             body: #"{"error":{"message":"Invalid API key"}}"#)
        }
        var config = ApiConfig.default
        config.baseUrl = "http://127.0.0.1:\(port)/v1"
        config.apiKey = "bad"
        let client = OpenAICompatibleLLM(config: config)
        do {
            _ = try await client.chatComplete(messages: [.init(role: .user, content: "hi")],
                                              model: "x", temperature: 0)
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 401"),
                          "unexpected error: \(error)")
        }
    }

    func testTranscriptionPostsMultipart() async throws {
        let capture = CapturedBody()
        await server.setHandler { _, body in
            await capture.set(body)
            return MockHTTPResponse(status: 200,
                                    headers: ["Content-Type": "application/json"],
                                    body: #"{"text":"hello there"}"#)
        }
        var config = ApiConfig.default
        config.baseUrl = "http://127.0.0.1:\(port)/v1"
        config.apiKey = "test-key"
        let wav = WavEncoder.encode(pcm16: Data(repeating: 0, count: 32000),
                                     sampleRate: 16000, channels: 1)
        let (text, _) = try await OpenAICompatibleSTT.postTranscription(wav: wav,
                                                                         config: config,
                                                                         language: "en")
        XCTAssertEqual(text, "hello there")

        let body = await capture.value ?? Data()
        let riffBytes: [UInt8] = [0x52, 0x49, 0x46, 0x46]  // "RIFF"
        let hasRIFF = body.range(of: Data(riffBytes)) != nil
        let hasModelField = body.range(of: "name=\"model\"".data(using: .utf8)!) != nil
        let hasFileField = body.range(of: "name=\"file\"".data(using: .utf8)!) != nil
        XCTAssertTrue(hasRIFF, "Missing WAV RIFF bytes in body")
        XCTAssertTrue(hasModelField, "Missing model field")
        XCTAssertTrue(hasFileField, "Missing file field")
    }

    func testTranslatorAccumulatesDeltas() async throws {
        await server.setHandler { _, _ in
            let body = """
            data: {"choices":[{"delta":{"content":"你"}}]}\n\n
            data: {"choices":[{"delta":{"content":"好"}}]}\n\n
            data: [DONE]\n\n
            """
            return MockHTTPResponse(status: 200,
                                    headers: ["Content-Type": "text/event-stream"],
                                    body: body)
        }
        var config = ApiConfig.default
        config.baseUrl = "http://127.0.0.1:\(port)/v1"
        config.apiKey = "test-key"
        let translator = OpenAICompatibleTranslator(config: config)
        var collected = ""
        let stream = translator.translate(text: "Hello",
                                           sourceLanguage: "en",
                                           targetLanguage: "zh-Hans",
                                           context: [])
        for try await chunk in stream { collected += chunk }
        XCTAssertEqual(collected, "你好")
    }
}

// MARK: - Tiny mock HTTP server

actor CapturedBody {
    private(set) var value: Data?
    func set(_ d: Data) { value = d }
}

struct MockHTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: String

    var rawData: Data {
        var resp = "HTTP/1.1 \(status) OK\r\n"
        var h = headers
        h["Content-Length"] = String(body.utf8.count)
        h["Connection"] = "close"
        for (k, v) in h { resp += "\(k): \(v)\r\n" }
        resp += "\r\n"
        var data = resp.data(using: .utf8) ?? Data()
        data.append(body.data(using: .utf8) ?? Data())
        return data
    }
}

actor MockHTTPServer {
    private var listener: NWListener?
    private var handler: (@Sendable (String, Data) async -> MockHTTPResponse)?

    func setHandler(_ h: @escaping @Sendable (String, Data) async -> MockHTTPResponse) {
        handler = h
    }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            Task { await self?.handle(conn) }
        }
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        cont.resume(returning: port)
                    } else {
                        cont.resume(throwing: NSError(domain: "MockServer", code: 1))
                    }
                case .failed(let err):
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "mock.server"))
        }
    }

    func stop() async {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) async {
        conn.start(queue: DispatchQueue(label: "mock.conn"))
        var buffer = Data()
        var headerEnd: Int?

        // Read until headers complete
        while headerEnd == nil {
            guard let chunk = await receive(conn) else { conn.cancel(); return }
            buffer.append(chunk)
            if let r = buffer.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) {
                headerEnd = r.lowerBound
            }
            if buffer.count > 50_000_000 { conn.cancel(); return }
        }
        let headerStr = String(data: buffer.subdata(in: 0..<headerEnd!), encoding: .utf8) ?? ""
        let firstLine = headerStr.components(separatedBy: "\r\n").first ?? ""
        var contentLength = 0
        for line in headerStr.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.split(separator: ":")[1]
                                        .trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd! + 4
        var body = buffer.count > bodyStart ? buffer.subdata(in: bodyStart..<buffer.count) : Data()
        while body.count < contentLength {
            guard let chunk = await receive(conn) else { break }
            body.append(chunk)
        }

        let response: MockHTTPResponse
        if let h = handler {
            response = await h(firstLine, body)
        } else {
            response = MockHTTPResponse(status: 200, headers: [:], body: "{}")
        }
        await send(conn, data: response.rawData)
        conn.cancel()
    }

    private func receive(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error = error { NSLog("mock recv err: \(error)"); cont.resume(returning: nil); return }
                cont.resume(returning: data ?? (isComplete ? Data() : nil))
            }
        }
    }

    private func send(_ conn: NWConnection, data: Data) async {
        await withCheckedContinuation { cont in
            conn.send(content: data, completion: .contentProcessed { _ in cont.resume() })
        }
    }
}
