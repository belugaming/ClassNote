import XCTest
import AVFoundation
@testable import ClassNote

/// End-to-end: create course & session, feed a real WAV file through the orchestrator
/// against a MockHTTPServer that plays the role of an OpenAI-compatible endpoint,
/// and verify segments + translations land in the database.
final class EndToEndFlowTests: XCTestCase {
    private var server: MockHTTPServer!
    private var port: UInt16 = 0

    override func setUp() async throws {
        try await super.setUp()
        try Database.shared.setup()
        server = MockHTTPServer()
        port = try await server.start()
    }

    override func tearDown() async throws {
        await server.stop()
        try await super.tearDown()
    }

    func testFileImportPopulatesSegmentsAndTranslations() async throws {
        // Route all requests. Transcription -> simple JSON. Chat (translation) -> SSE deltas.
        await server.setHandler { requestLine, body in
            if requestLine.contains("/audio/transcriptions") {
                let payload: [String: Any] = [
                    "text": "Hello everyone, welcome to our lecture on linear algebra.",
                    "segments": [
                        ["id": 0, "start": 0.0, "end": 2.0,
                         "text": "Hello everyone, welcome to our lecture."],
                        ["id": 1, "start": 2.0, "end": 4.0,
                         "text": "Today we'll cover linear algebra."]
                    ]
                ]
                let data = try! JSONSerialization.data(withJSONObject: payload)
                return MockHTTPResponse(status: 200,
                                        headers: ["Content-Type": "application/json"],
                                        body: String(data: data, encoding: .utf8) ?? "")
            }
            // chat completions
            let sse = """
            data: {"choices":[{"delta":{"content":"你"}}]}\n\n
            data: {"choices":[{"delta":{"content":"好"}}]}\n\n
            data: [DONE]\n\n
            """
            return MockHTTPResponse(status: 200,
                                    headers: ["Content-Type": "text/event-stream"],
                                    body: sse)
        }

        // Configure API to point at mock server
        var cfg = ApiConfig.default
        cfg.baseUrl = "http://127.0.0.1:\(port)/v1"
        cfg.apiKey = "test-key"
        cfg.sttModel = "whisper-1"
        cfg.translationModel = "test-translate"
        cfg.llmModel = "test-llm"
        try await ApiConfigRepository.shared.save(cfg)
        // Force AppState to reload from DB so test cfg sticks (avoids race with init Task)
        await AppState.shared.loadConfig()
        let live = await MainActor.run { AppState.shared.apiConfig.baseUrl }
        XCTAssertTrue(live.contains("\(port)"), "AppState didn't pick up test cfg, got: \(live)")
        await MainActor.run { AppState.shared.translationEnabled = true }

        // Create course
        let course = Course.new(name: "Linear Algebra 101")
        try await CourseRepository.shared.insert(course)

        // Write test WAV file
        let tempDir = FileManager.default.temporaryDirectory
        let wavURL = tempDir.appendingPathComponent("test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        try Self.makeTestWav(to: wavURL, seconds: 4)

        // Run import via orchestrator
        let orch = await AppState.shared.orchestrator
        let sessionId = try await orch.ingestFile(url: wavURL, courseId: course.id)

        // Poll for completion - we need both segments inserted and translations done
        var segments: [Segment] = []
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 200_000_000)
            segments = try await SegmentRepository.shared.all(sessionId: sessionId)
            let allTranslated = !segments.isEmpty && segments.allSatisfy { !$0.textTranslated.isEmpty }
            if allTranslated { break }
        }

        XCTAssertFalse(segments.isEmpty, "No segments landed in DB")
        XCTAssertTrue(segments.contains { $0.textOriginal.contains("linear algebra") },
                      "Expected transcript text not found")
        XCTAssertTrue(segments.allSatisfy { !$0.textTranslated.isEmpty },
                      "All segments should have a translation")
        for seg in segments {
            XCTAssertEqual(seg.textTranslated, "你好")
        }

        // Search via FTS must find it across the inserted segment.
        let hits = try await SegmentRepository.shared.searchFTS(query: "algebra", limit: 10)
        XCTAssertTrue(hits.contains { $0.segment.sessionId == sessionId })

        // Mark a highlight
        try await HighlightRepository.shared.mark(sessionId: sessionId, timestampMs: 1000, note: "important")
        let hl = try await HighlightRepository.shared.all(sessionId: sessionId)
        XCTAssertEqual(hl.count, 1)

        // Cleanup
        try await SessionRepository.shared.delete(id: sessionId)
        try await CourseRepository.shared.delete(id: course.id)
        try await ApiConfigRepository.shared.save(.default)
    }

    static func makeTestWav(to url: URL, seconds: Int) throws {
        let sampleRate = 16000
        let count = sampleRate * seconds
        var data = Data(capacity: count * 2)
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            let v = sin(2 * .pi * 440 * t) * 0.3
            let s = Int16(v * 32767.0)
            withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) }
        }
        let wav = WavEncoder.encode(pcm16: data, sampleRate: sampleRate, channels: 1)
        try wav.write(to: url)
    }
}
