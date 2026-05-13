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

    func testStreamingSTTBuffersUntilSilence() async throws {
        // The new STT commits on silence boundaries. If we feed 7s of loud audio
        // followed by 1s of silence, we expect exactly one transcription call.
        let requests = RequestCounter()
        await server.setHandler { requestLine, _ in
            await requests.bump()
            if requestLine.contains("/audio/transcriptions") {
                return MockHTTPResponse(status: 200,
                                        headers: ["Content-Type": "application/json"],
                                        body: #"{"text":"This is a full sentence from the lecture."}"#)
            }
            return MockHTTPResponse(status: 404, headers: [:], body: "")
        }

        var config = ApiConfig.default
        config.baseUrl = "http://127.0.0.1:\(port)/v1"
        config.apiKey = "test-key"
        let stt = OpenAICompatibleSTT(config: config)

        // Build synthetic audio: 7s voiced tone + 1.2s silence.
        let stream = AsyncStream<AudioChunk> { continuation in
            Task {
                let sr = 16000
                let chunkMs = 200
                let samplesPerChunk = sr * chunkMs / 1000
                var ts: Int64 = 0
                // Voiced portion: 35 chunks × 200ms = 7s
                for i in 0..<35 {
                    var data = Data(capacity: samplesPerChunk * 2)
                    for j in 0..<samplesPerChunk {
                        let t = Double(i * samplesPerChunk + j) / Double(sr)
                        let s = Int16(sin(2 * .pi * 440 * t) * 0.7 * 32767.0)
                        withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) }
                    }
                    continuation.yield(AudioChunk(pcmData: data, sampleRate: sr, timestamp: ts))
                    ts += Int64(chunkMs)
                }
                // Silent portion: 6 chunks × 200ms = 1.2s, should trigger commit
                for _ in 0..<6 {
                    let data = Data(repeating: 0, count: samplesPerChunk * 2)
                    continuation.yield(AudioChunk(pcmData: data, sampleRate: sr, timestamp: ts))
                    ts += Int64(chunkMs)
                }
                continuation.finish()
            }
        }

        var events: [TranscriptEvent] = []
        for try await evt in stt.transcribe(audio: stream, language: "en") {
            events.append(evt)
        }
        XCTAssertGreaterThanOrEqual(events.count, 1, "Expected at least one transcription event")
        XCTAssertLessThanOrEqual(events.count, 2, "Expected at most 2 events (single sentence + maybe tail flush)")
        XCTAssertTrue(events[0].text.contains("lecture"))
        let calls = await requests.count
        XCTAssertLessThanOrEqual(calls, 2)
    }
}

actor RequestCounter {
    private(set) var count = 0
    func bump() { count += 1 }
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
