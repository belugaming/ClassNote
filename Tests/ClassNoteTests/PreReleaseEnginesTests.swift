import XCTest
@testable import ClassNote

/// Regressions for the engine bugs fixed before release: live STT losing a
/// chunk to one transient HTTP error, request parameters current OpenAI models
/// reject, mid-stream error frames read as a normal end, the ASR warm pool
/// handing out the wrong engine or orphaning a sidecar, and concurrent
/// first-run installs over one venv.
///
/// No real network and no sidecars: HTTP goes to the loopback `MockHTTPServer`
/// and the warm pool launches stubs.

// MARK: - Helpers

/// 200 ms bus chunks of a 440 Hz tone or silence, on an absolute clock.
private enum SyntheticAudio {
    static let chunkMs: Int64 = 200

    static func chunk(voiced: Bool, at timestamp: Int64) -> AudioChunk {
        let rate = 16000
        let samples = rate * Int(chunkMs) / 1000
        var data = Data(capacity: samples * 2)
        for j in 0..<samples {
            let value: Int16 = voiced
                ? Int16(sin(2 * .pi * 440 * Double(j) / Double(rate)) * 0.7 * 32767)
                : 0
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return AudioChunk(pcmData: data, sampleRate: rate, timestamp: timestamp)
    }

    /// Voiced and silent runs laid end to end from `startMs`.
    static func timeline(startMs: Int64, _ runs: [(voiced: Bool, seconds: Double)]) -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        var ts = startMs
        for run in runs {
            for _ in 0..<Int((run.seconds * 1000 / Double(chunkMs)).rounded()) {
                chunks.append(chunk(voiced: run.voiced, at: ts))
                ts += chunkMs
            }
        }
        return chunks
    }

    /// Feeds `chunks` into a stream shaped like the bus's: `buffering` set
    /// keeps only the newest that many, as `makeChunkStream` does.
    static func stream(_ chunks: [AudioChunk], buffering: Int? = nil,
                       pacingMs: UInt64 = 0) -> AsyncStream<AudioChunk> {
        let policy: AsyncStream<AudioChunk>.Continuation.BufferingPolicy =
            buffering.map { .bufferingNewest($0) } ?? .unbounded
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: policy)
        Task {
            for chunk in chunks {
                continuation.yield(chunk)
                if pacingMs > 0 { try? await Task.sleep(nanoseconds: pacingMs * 1_000_000) }
            }
            continuation.finish()
        }
        return stream
    }
}

private actor CapturedBodies {
    private(set) var all: [Data] = []
    func append(_ body: Data) -> Int {
        all.append(body)
        return all.count
    }
}

private extension Data {
    func mentions(_ text: String) -> Bool { range(of: Data(text.utf8)) != nil }
}

class PreReleaseMockServerTestCase: XCTestCase {
    var server: MockHTTPServer!
    var port: UInt16 = 0

    override func setUp() async throws {
        try await super.setUp()
        server = MockHTTPServer()
        port = try await server.start()
    }

    override func tearDown() async throws {
        await server.stop()
        try await super.tearDown()
    }

    /// A model id no other test uses, so what one test teaches
    /// `OpenAIRejectedParameters` cannot leak into another.
    func config(sttModel: String = "whisper-\(UUID().uuidString)",
                llmModel: String = "model-\(UUID().uuidString)") -> ApiConfig {
        var config = ApiConfig.default
        config.baseUrl = "http://127.0.0.1:\(port)/v1"
        config.apiKey = "test-key"
        config.sttModel = sttModel
        config.llmModel = llmModel
        return config
    }
}

// MARK: - E3: live STT retries a transient failure without losing audio

final class OpenAISTTRetryTests: PreReleaseMockServerTestCase {
    private static let fast: [TimeInterval] = [0.05, 0.05, 0.05]

    private static func ok(_ text: String) -> MockHTTPResponse {
        MockHTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                         body: #"{"text":"\#(text)"}"#)
    }

    private static let busy = MockHTTPResponse(status: 503, headers: ["Content-Type": "application/json"],
                                               body: #"{"error":{"message":"overloaded"}}"#)

    func testTransientFailureIsRetriedWithTheSameAudio() async throws {
        let bodies = CapturedBodies()
        await server.setHandler { _, body in
            let n = await bodies.append(body)
            return n == 1 ? OpenAISTTRetryTests.busy : OpenAISTTRetryTests.ok("A full sentence from the lecture.")
        }
        let stt = OpenAICompatibleSTT(config: config(), retryDelays: OpenAISTTRetryTests.fast)
        // Starts two minutes in: events must stay on the bus's absolute clock.
        let audio = SyntheticAudio.timeline(startMs: 120_000, [(true, 4), (false, 1)])

        var events: [TranscriptEvent] = []
        for try await event in stt.transcribe(audio: SyntheticAudio.stream(audio), language: "en") {
            events.append(event)
        }

        XCTAssertEqual(events.map(\.text), ["A full sentence from the lecture."])
        XCTAssertEqual(events.first?.startMs, 120_000)
        // A plain `json` reply spans the committed chunk (4 s voice + the
        // 0.6 s of silence that committed it) instead of collapsing to 0 ms.
        XCTAssertEqual(Double(events.first?.endMs ?? 0), 124_600, accuracy: 1)
        let sent = await bodies.all
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first?.count, sent.last?.count, "the retry must carry the same audio")
    }

    /// The bus's stream keeps only the newest frames. While an upload waited
    /// to retry, nothing read it, so the next utterance's start was dropped.
    func testAudioKeepsFlowingWhileARetryWaits() async throws {
        let bodies = CapturedBodies()
        await server.setHandler { _, body in
            switch await bodies.append(body) {
            case 1, 2: return OpenAISTTRetryTests.busy
            case 3: return OpenAISTTRetryTests.ok("First sentence of the lecture.")
            default: return OpenAISTTRetryTests.ok("Second sentence of the lecture.")
            }
        }
        let stt = OpenAICompatibleSTT(config: config(), retryDelays: [0.3, 0.3, 0.3])
        let base: Int64 = 60_000
        let audio = SyntheticAudio.timeline(startMs: base, [(true, 4), (false, 0.6), (true, 4), (false, 1)])
        // Eight frames of buffer, fed far faster than real time: the whole
        // second utterance arrives while the first upload is still retrying.
        let stream = SyntheticAudio.stream(audio, buffering: 8, pacingMs: 10)

        var events: [TranscriptEvent] = []
        for try await event in stt.transcribe(audio: stream, language: "en") {
            events.append(event)
        }

        XCTAssertEqual(events.map(\.text), ["First sentence of the lecture.",
                                            "Second sentence of the lecture."])
        XCTAssertEqual(events.first?.startMs, base)
        XCTAssertEqual(events.last?.startMs, base + 4_600, "the second utterance lost its start")
        let sent = await bodies.all.count
        XCTAssertEqual(sent, 4)
    }

    func testNonTransientErrorFailsFast() async throws {
        let requests = RequestCounter()
        await server.setHandler { _, _ in
            await requests.bump()
            return MockHTTPResponse(status: 401, headers: ["Content-Type": "application/json"],
                                    body: #"{"error":{"message":"Invalid API key"}}"#)
        }
        let stt = OpenAICompatibleSTT(config: config(), retryDelays: OpenAISTTRetryTests.fast)
        let audio = SyntheticAudio.timeline(startMs: 0, [(true, 4), (false, 1)])
        do {
            for try await _ in stt.transcribe(audio: SyntheticAudio.stream(audio), language: "en") {}
            XCTFail("expected the 401 to end the stream")
        } catch EngineError.httpError(let status, _) {
            XCTAssertEqual(status, 401)
        }
        let count = await requests.count
        XCTAssertEqual(count, 1)
    }

    func testRetriesRunOut() async throws {
        let requests = RequestCounter()
        await server.setHandler { _, _ in
            await requests.bump()
            return OpenAISTTRetryTests.busy
        }
        do {
            _ = try await OpenAICompatibleSTT.postTranscriptionVerbose(
                wav: WavEncoder.encode(pcm16: Data(count: 32000), sampleRate: 16000, channels: 1),
                config: config(), language: "en", retryDelays: OpenAISTTRetryTests.fast)
            XCTFail("expected the 503 to surface once the retries ran out")
        } catch EngineError.httpError(let status, _) {
            XCTAssertEqual(status, 503)
        }
        let count = await requests.count
        XCTAssertEqual(count, 4, "one attempt plus three retries")
    }

    func testTransientClassification() {
        XCTAssertTrue(OpenAICompatibleSTT.isTransient(status: 429))
        XCTAssertTrue(OpenAICompatibleSTT.isTransient(status: 503))
        XCTAssertTrue(OpenAICompatibleSTT.isTransient(status: 500))
        XCTAssertFalse(OpenAICompatibleSTT.isTransient(status: 400))
        XCTAssertFalse(OpenAICompatibleSTT.isTransient(status: 401))
        XCTAssertFalse(OpenAICompatibleSTT.isTransient(status: 404))
        XCTAssertFalse(OpenAICompatibleSTT.isTransient(status: 501))
        XCTAssertTrue(OpenAICompatibleSTT.isTransient(URLError(.timedOut)))
        XCTAssertTrue(OpenAICompatibleSTT.isTransient(URLError(.networkConnectionLost)))
        XCTAssertFalse(OpenAICompatibleSTT.isTransient(URLError(.cancelled)))
        XCTAssertFalse(OpenAICompatibleSTT.isTransient(URLError(.badURL)))
    }

    func testRetryAfterIsHonouredInSecondsAndCapped() throws {
        func response(_ value: String) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: URL(string: "http://127.0.0.1")!, statusCode: 429,
                                          httpVersion: nil, headerFields: ["Retry-After": value]))
        }
        XCTAssertEqual(OpenAICompatibleSTT.retryAfter(try response("3")), 3)
        XCTAssertEqual(OpenAICompatibleSTT.retryAfter(try response("600")), 30)
        XCTAssertNil(OpenAICompatibleSTT.retryAfter(try response("Wed, 21 Oct 2026 07:28:00 GMT")))
    }
}

// MARK: - E4: parameters current OpenAI models reject

final class OpenAIRejectedParameterTests: PreReleaseMockServerTestCase {
    func testVerboseJSONRejectionFallsBackToJSON() async throws {
        let bodies = CapturedBodies()
        await server.setHandler { _, body in
            _ = await bodies.append(body)
            if body.mentions("verbose_json") {
                return MockHTTPResponse(status: 400, headers: ["Content-Type": "application/json"], body: #"""
                {"error":{"message":"response_format 'verbose_json' is not compatible with model 'x'. Use 'json' or 'text' instead.","type":"invalid_request_error","param":"response_format","code":"unsupported_value"}}
                """#)
            }
            return MockHTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                                    body: #"{"text":"Plain json reply from the model."}"#)
        }
        let config = config(sttModel: "custom-transcribe-\(UUID().uuidString)")
        let wav = WavEncoder.encode(pcm16: Data(count: 32000), sampleRate: 16000, channels: 1)

        let segments = try await OpenAICompatibleSTT.postTranscriptionVerbose(
            wav: wav, config: config, language: "en", fallbackDurationSec: 3)
        XCTAssertEqual(segments.map(\.text), ["Plain json reply from the model."])
        XCTAssertEqual(segments.first?.end, 3, "one segment spanning the audio")
        var sent = await bodies.all.count
        XCTAssertEqual(sent, 2)

        // Remembered: the next chunk asks for json straight away.
        _ = try await OpenAICompatibleSTT.postTranscriptionVerbose(wav: wav, config: config, language: "en")
        let all = await bodies.all
        sent = all.count
        XCTAssertEqual(sent, 3)
        XCTAssertFalse(all.last?.mentions("verbose_json") ?? true)
    }

    func testKnownJSONOnlyModelsSkipVerbose() {
        XCTAssertFalse(OpenAICompatibleSTT.acceptsVerboseJSON(config(sttModel: "gpt-4o-transcribe")))
        XCTAssertFalse(OpenAICompatibleSTT.acceptsVerboseJSON(config(sttModel: "gpt-4o-mini-transcribe")))
        XCTAssertFalse(OpenAICompatibleSTT.acceptsVerboseJSON(config(sttModel: "openai/gpt-4o-transcribe-diarize")))
        XCTAssertTrue(OpenAICompatibleSTT.acceptsVerboseJSON(config(sttModel: "whisper-1")))
    }

    func testTemperatureRejectionIsRetriedWithoutIt() async throws {
        let bodies = CapturedBodies()
        await server.setHandler { _, body in
            _ = await bodies.append(body)
            if body.mentions("\"temperature\"") {
                return MockHTTPResponse(status: 400, headers: ["Content-Type": "application/json"], body: #"""
                {"error":{"message":"Unsupported value: 'temperature' does not support 0.2 with this model. Only the default (1) value is supported.","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}
                """#)
            }
            return MockHTTPResponse(status: 200, headers: ["Content-Type": "text/event-stream"], body: """
            data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n
            data: [DONE]\n\n
            """)
        }
        let model = "custom-reasoner-\(UUID().uuidString)"
        let client = OpenAICompatibleLLM(config: config(llmModel: model))
        let first = try await client.chatComplete(messages: [.init(role: .user, content: "hi")],
                                                  model: model, temperature: 0.2)
        XCTAssertEqual(first, "Hello")
        var sent = await bodies.all.count
        XCTAssertEqual(sent, 2)

        let second = try await client.chatComplete(messages: [.init(role: .user, content: "hi")],
                                                   model: model, temperature: 0.2)
        XCTAssertEqual(second, "Hello")
        sent = await bodies.all.count
        XCTAssertEqual(sent, 3, "the rejection is remembered for the model")
    }

    func testOtherBadRequestsAreNotRetried() async throws {
        let requests = RequestCounter()
        await server.setHandler { _, _ in
            await requests.bump()
            return MockHTTPResponse(status: 400, headers: ["Content-Type": "application/json"],
                                    body: #"{"error":{"message":"The model does not exist"}}"#)
        }
        let client = OpenAICompatibleLLM(config: config())
        do {
            _ = try await client.chatComplete(messages: [.init(role: .user, content: "hi")],
                                              model: "missing-\(UUID().uuidString)", temperature: 0.2)
            XCTFail("expected a 400")
        } catch EngineError.httpError(let status, _) {
            XCTAssertEqual(status, 400)
        }
        let count = await requests.count
        XCTAssertEqual(count, 1)
    }

    func testReasoningModelsAreSentNoTemperature() async throws {
        let bodies = CapturedBodies()
        await server.setHandler { _, body in
            _ = await bodies.append(body)
            return MockHTTPResponse(status: 200, headers: ["Content-Type": "text/event-stream"], body: """
            data: {"choices":[{"delta":{"content":"ok"}}]}\n\n
            data: [DONE]\n\n
            """)
        }
        let client = OpenAICompatibleLLM(config: config())
        _ = try await client.chatComplete(messages: [.init(role: .user, content: "hi")],
                                          model: "gpt-5-mini", temperature: 0.3)
        let body = await bodies.all.first ?? Data()
        XCTAssertFalse(body.mentions("temperature"))
    }

    func testReasoningModelClassification() {
        for id in ["o1", "o3", "o3-mini", "o4-mini", "gpt-5", "gpt-5-mini", "gpt-5.1", "openai/o3"] {
            XCTAssertTrue(OpenAIChatClient.isReasoningModel(id), id)
        }
        for id in ["gpt-4o", "gpt-4.1-mini", "gpt-5-chat-latest", "qwen3:8b", "ollama", "deepseek-chat"] {
            XCTAssertFalse(OpenAIChatClient.isReasoningModel(id), id)
        }
    }
}

// MARK: - E7: error frames mid-stream

final class OpenAIStreamErrorFrameTests: PreReleaseMockServerTestCase {
    private func stream(_ body: String) async throws -> String {
        await server.setHandler { _, _ in
            MockHTTPResponse(status: 200, headers: ["Content-Type": "text/event-stream"], body: body)
        }
        let client = OpenAICompatibleLLM(config: config())
        return try await client.chatComplete(messages: [.init(role: .user, content: "hi")],
                                             model: "m", temperature: 0)
    }

    func testOpenRouterErrorFrameFailsTheStream() async throws {
        do {
            _ = try await stream("""
            data: {"choices":[{"delta":{"content":"Partial note"}}]}\n\n
            data: {"id":"gen-1","provider":"openai","error":{"code":"server_error","message":"Provider disconnected unexpectedly"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}\n\n
            data: [DONE]\n\n
            """)
            XCTFail("a truncated answer must not end as a success")
        } catch EngineError.networkError(let message) {
            XCTAssertTrue(message.contains("Provider disconnected unexpectedly"), message)
        }
    }

    func testVLLMErrorFrameFailsTheStream() async throws {
        do {
            _ = try await stream("""
            data: {"choices":[{"delta":{"content":"Partial"}}]}\n\n
            data: {"error":{"object":"error","message":"out of KV cache","type":"InternalServerError","param":null,"code":500}}\n\n
            """)
            XCTFail("a truncated answer must not end as a success")
        } catch EngineError.networkError(let message) {
            XCTAssertEqual(message, "500: out of KV cache")
        }
    }

    func testOrdinaryFramesAreNotFailures() {
        XCTAssertNil(OpenAIChatClient.streamFailure(in: ["choices": [["delta": ["content": "hi"]]]]))
        XCTAssertNil(OpenAIChatClient.streamFailure(in: ["error": NSNull(),
                                                         "choices": [["finish_reason": "stop"]]]))
        XCTAssertNotNil(OpenAIChatClient.streamFailure(in: ["choices": [["finish_reason": "error"]]]))
    }
}

// MARK: - E5: the warm pool's key and identity bookkeeping

private actor StubWarmSidecar: WarmASRSidecar {
    private(set) var isRunning = true
    private(set) var shutdownCount = 0

    func shutdown() async {
        isRunning = false
        shutdownCount += 1
    }
}

/// Starts nothing: records each launch and holds it until the test lets it
/// finish. Ignores cancellation, as a start that is past its handshake does.
private actor StubSidecarLauncher {
    private(set) var keys: [LocalASRWarmPool.Key] = []
    private(set) var sidecars: [StubWarmSidecar] = []
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []

    nonisolated static func url(_ index: Int) -> URL {
        URL(string: "ws://127.0.0.1:\(41000 + index)")!
    }

    func launch(_ key: LocalASRWarmPool.Key) async -> (any WarmASRSidecar, URL) {
        let index = keys.count
        let sidecar = StubWarmSidecar()
        keys.append(key)
        sidecars.append(sidecar)
        if !released.contains(index) {
            await withCheckedContinuation { gates[index] = $0 }
        }
        return (sidecar, Self.url(index))
    }

    func release(_ index: Int) {
        released.insert(index)
        gates.removeValue(forKey: index)?.resume()
    }

    func waitForLaunches(_ count: Int) async {
        for _ in 0..<500 where keys.count < count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

final class LocalASRWarmPoolKeyTests: XCTestCase {
    private var launcher: StubSidecarLauncher!
    private var pool: LocalASRWarmPool!

    override func setUp() {
        super.setUp()
        let launcher = StubSidecarLauncher()
        self.launcher = launcher
        pool = LocalASRWarmPool(launch: { key, _ in await launcher.launch(key) })
    }

    override func tearDown() async throws {
        await pool.retire(force: true)
        try await super.tearDown()
    }

    /// Settings → Download on R2T2 warms R2T2; a recording started before it
    /// finished joined that warm-up and recorded with R2T2.
    func testWarmUpForAnotherEngineIsNotHandedOut() async throws {
        let pool = pool!, launcher = launcher!
        let download = Task { try await pool.url(engine: .r2t2, language: "en") }
        await launcher.waitForLaunches(1)
        let recording = Task { try await pool.url(engine: .funasr, language: "en") }
        await launcher.waitForLaunches(2)
        await launcher.release(0)
        await launcher.release(1)

        let url = try await recording.value
        XCTAssertEqual(url, StubSidecarLauncher.url(1))
        let engines = await launcher.keys.map(\.engine)
        XCTAssertEqual(engines, [.r2t2, .funasr])
        do {
            _ = try await download.value
            XCTFail("the superseded warm-up must not succeed")
        } catch {}
        let superseded = await launcher.sidecars[0].shutdownCount
        XCTAssertEqual(superseded, 1, "a superseded sidecar is shut down, not adopted")
        let ready = await pool.isReady(engine: .funasr, language: "en")
        XCTAssertTrue(ready)
    }

    /// A settings change during the launch preload: the first warm-up's
    /// caller erased the second one's slot, a recording then started a third
    /// sidecar, and the second (~2 GB) was never retired.
    func testSupersededWarmUpDoesNotOrphanItsReplacement() async throws {
        let pool = pool!, launcher = launcher!
        // A third launch would be the bug; let it finish at once so the
        // assertions below catch it instead of the test hanging.
        await launcher.release(2)

        let launchPreload = Task { await pool.preload(engine: .funasr, language: "en") }
        await launcher.waitForLaunches(1)
        await pool.retire()
        let reload = Task { await pool.preload(engine: .r2t2, language: "en") }
        await launcher.waitForLaunches(2)
        await launcher.release(0)
        await launchPreload.value

        let recording = Task { try await pool.url(engine: .r2t2, language: "en") }
        // Let the recording either join the warm-up in flight or start its own.
        try await Task.sleep(nanoseconds: 50_000_000)
        await launcher.release(1)
        let url = try await recording.value
        await reload.value

        XCTAssertEqual(url, StubSidecarLauncher.url(1))
        let launches = await launcher.keys.count
        XCTAssertEqual(launches, 2, "the recording must join the warm-up in flight")
        let sidecars = await launcher.sidecars
        let firstShutdowns = await sidecars[0].shutdownCount
        let secondShutdowns = await sidecars[1].shutdownCount
        XCTAssertEqual(firstShutdowns, 1)
        XCTAssertEqual(secondShutdowns, 0)
        let ready = await pool.isReady(engine: .r2t2, language: "en")
        XCTAssertTrue(ready)
    }

    func testMatchingCallersShareOneWarmUp() async throws {
        let pool = pool!, launcher = launcher!
        let first = Task { try await pool.url(engine: .funasr, language: "en") }
        await launcher.waitForLaunches(1)
        let second = Task { try await pool.url(engine: .funasr, language: "en-US") }
        try await Task.sleep(nanoseconds: 50_000_000)
        await launcher.release(0)
        let urls = try await [first.value, second.value]
        XCTAssertEqual(urls, [StubSidecarLauncher.url(0), StubSidecarLauncher.url(0)])
        let launches = await launcher.keys.count
        XCTAssertEqual(launches, 1)
    }

    /// A recording is streaming through the sidecar while a crashed one is
    /// being restarted for it: another configuration must not cancel that.
    func testWarmUpForAnotherEngineIsRefusedWhileInUse() async throws {
        let pool = pool!, launcher = launcher!
        let warm = Task { try await pool.url(engine: .funasr, language: "en") }
        await launcher.waitForLaunches(1)
        await pool.beginUse()
        do {
            _ = try await pool.url(engine: .r2t2, language: "en")
            XCTFail("expected busyWithDifferentConfiguration")
        } catch LocalASRProcessError.busyWithDifferentConfiguration {}
        await launcher.release(0)
        let url = try await warm.value
        XCTAssertEqual(url, StubSidecarLauncher.url(0))
        await pool.endUse()
    }
}

// MARK: - E6: one install at a time

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

final class SingleFlightTests: XCTestCase {
    private struct Failed: Error {}

    /// Joins at once: the stream's build closure runs as it is created.
    private static func watch(_ flight: SingleFlight<Int>,
                              _ work: @escaping SingleFlight<Int>.Work) -> AsyncThrowingStream<Int, Error> {
        AsyncThrowingStream { continuation in flight.join(continuation, work: work) }
    }

    private static func collect(_ stream: AsyncThrowingStream<Int, Error>) async throws -> [Int] {
        var values: [Int] = []
        for try await value in stream { values.append(value) }
        return values
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testConcurrentCallersShareOneRun() async throws {
        let flight = SingleFlight<Int>()
        let runs = RequestCounter()
        let gate = AsyncGate()
        let work: SingleFlight<Int>.Work = { report in
            await runs.bump()
            report(1)
            await gate.wait()
            report(2)
        }
        let first = Self.watch(flight, work)
        let firstValues = Task { try await Self.collect(first) }
        await waitUntil { await runs.count == 1 }
        let second = Self.watch(flight, work)
        let secondValues = Task { try await Self.collect(second) }
        await gate.open()

        let a = try await firstValues.value
        let b = try await secondValues.value
        XCTAssertEqual(a, [1, 2])
        XCTAssertEqual(b, [1, 2], "a late caller sees the step in progress, then the rest")
        let count = await runs.count
        XCTAssertEqual(count, 1)
    }

    /// A cancelled warm-up stops listening; the install goes on, and the next
    /// caller joins it rather than starting a second one over the same venv.
    func testCallerLeavingDoesNotStopTheRun() async throws {
        let flight = SingleFlight<Int>()
        let runs = RequestCounter()
        let gate = AsyncGate()
        let work: SingleFlight<Int>.Work = { report in
            await runs.bump()
            await gate.wait()
            report(7)
        }
        let abandonedStream = Self.watch(flight, work)
        let abandoned = Task { try await Self.collect(abandonedStream) }
        await waitUntil { await runs.count == 1 }
        abandoned.cancel()
        _ = try? await abandoned.value

        let nextStream = Self.watch(flight, work)
        let next = Task { try await Self.collect(nextStream) }
        await gate.open()
        let values = try await next.value
        XCTAssertEqual(values, [7])
        let count = await runs.count
        XCTAssertEqual(count, 1)
    }

    func testFailureReachesEveryCallerAndTheNextCallStartsAgain() async throws {
        let flight = SingleFlight<Int>()
        let runs = RequestCounter()
        let gate = AsyncGate()
        let failing: SingleFlight<Int>.Work = { _ in
            await runs.bump()
            await gate.wait()
            throw Failed()
        }
        let firstStream = Self.watch(flight, failing)
        let first = Task { try await Self.collect(firstStream) }
        await waitUntil { await runs.count == 1 }
        let secondStream = Self.watch(flight, failing)
        let second = Task { try await Self.collect(secondStream) }
        await gate.open()
        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("expected the failure")
            } catch is Failed {}
        }

        let retry = try await Self.collect(Self.watch(flight) { report in
            await runs.bump()
            report(1)
        })
        XCTAssertEqual(retry, [1])
        let count = await runs.count
        XCTAssertEqual(count, 2)
    }
}
