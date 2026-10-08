import Foundation
import XCTest
@testable import ClassNote

/// The live tutor: when it explains on its own, what it is given, and how it
/// behaves when the model fails.
final class LiveTutorTests: XCTestCase {

    // MARK: - Helpers

    private static let sentence = "The compressor reduces the dynamic range of the signal."

    private func line(_ id: Int, _ startS: Int, _ endS: Int, _ text: String = LiveTutorTests.sentence,
                      continues: Bool = false) -> LiveSegment {
        var segment = LiveSegment(rowId: Int64(id), startMs: Int64(startS) * 1000,
                                  endMs: Int64(endS) * 1000, original: text,
                                  translated: "", isFinal: true)
        segment.continuesNext = continues
        return segment
    }

    @MainActor
    private func makeTutor(_ llm: ScriptedLLM, pace: LiveTutorPace = .normal) -> (LiveTutor, TranscriptBuffer) {
        let buffer = TranscriptBuffer()
        let tutor = LiveTutor(transcript: buffer)
        tutor.llmOverride = llm
        tutor.pace = pace
        tutor.begin(sessionId: nil, courseContext: .empty)
        return (tutor, buffer)
    }

    /// Appends lines of 10 s each, from `fromS` to `toS`, telling the tutor
    /// about every one the way the orchestrator does.
    @MainActor
    private func speak(_ buffer: TranscriptBuffer, _ tutor: LiveTutor, from fromS: Int, to toS: Int,
                       continues: Bool = false) {
        var start = fromS
        while start < toS {
            let id = buffer.segments.count + 1
            buffer.appendFinal(rowId: Int64(id), startMs: Int64(start) * 1000,
                               endMs: Int64(start + 10) * 1000, original: Self.sentence,
                               continuesNext: continues)
            tutor.transcriptDidAdvance()
            start += 10
        }
    }

    @MainActor
    private func waitUntilIdle(_ tutor: LiveTutor, file: StaticString = #filePath, line: UInt = #line) async throws {
        var waited = 0
        while tutor.cards.contains(where: \.isStreaming), waited < 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertFalse(tutor.cards.contains(where: \.isStreaming), "tutor never finished", file: file, line: line)
    }

    // MARK: - Schedule

    func testNothingIsDueBeforeTheStretchCoversTheInterval() {
        let segments = [line(1, 0, 20), line(2, 20, 40), line(3, 40, 55)]
        XCTAssertNil(LiveTutorSchedule.dueStretch(segments, coveredCount: 0, intervalMs: 60_000))
    }

    func testAStretchIsDueOnceItCoversTheInterval() {
        let segments = [line(1, 0, 20), line(2, 20, 40), line(3, 40, 61)]
        XCTAssertEqual(LiveTutorSchedule.dueStretch(segments, coveredCount: 0, intervalMs: 60_000), 0..<3)
    }

    func testOnlyLinesNotYetExplainedCount() {
        let segments = [line(1, 0, 30), line(2, 30, 61), line(3, 61, 90), line(4, 90, 110)]
        XCTAssertNil(LiveTutorSchedule.dueStretch(segments, coveredCount: 2, intervalMs: 60_000))
        let more = segments + [line(5, 110, 125)]
        XCTAssertEqual(LiveTutorSchedule.dueStretch(more, coveredCount: 2, intervalMs: 60_000), 2..<5)
    }

    func testASentenceStillBeingSpokenWaitsForItsEnd() {
        let segments = [line(1, 0, 30), line(2, 30, 62), line(3, 62, 70, continues: true)]
        XCTAssertEqual(LiveTutorSchedule.dueStretch(segments, coveredCount: 0, intervalMs: 60_000), 0..<2,
                       "the open sentence is left for the next stretch")

        let open = [line(1, 0, 30, continues: true), line(2, 30, 70, continues: true)]
        XCTAssertNil(LiveTutorSchedule.dueStretch(open, coveredCount: 0, intervalMs: 60_000))
    }

    func testALecturerWhoNeverEndsASentenceIsExplainedAnyway() {
        let open = [line(1, 0, 60, continues: true), line(2, 60, 121, continues: true)]
        XCTAssertEqual(LiveTutorSchedule.dueStretch(open, coveredCount: 0, intervalMs: 60_000), 0..<2)
    }

    func testAFewWordsAcrossAPauseAreNotWorthARequest() {
        let segments = [line(1, 0, 2, "OK."), line(2, 70, 72, "So.")]
        XCTAssertNil(LiveTutorSchedule.dueStretch(segments, coveredCount: 0, intervalMs: 60_000))
    }

    func testExplainNowReachesBackAMinuteWhenLittleIsNew() {
        let segments = (0..<12).map { line($0 + 1, $0 * 10, $0 * 10 + 10) }   // 0–120 s
        let range = LiveTutorSchedule.manualStretch(segments, coveredCount: 11)
        XCTAssertEqual(range.upperBound, 12)
        XCTAssertEqual(segments[range.lowerBound].startMs, 60_000,
                       "reaches back to the last minute of lecture")

        XCTAssertEqual(LiveTutorSchedule.manualStretch(segments, coveredCount: 2), 2..<12,
                       "a long unexplained stretch is covered whole")
        XCTAssertEqual(LiveTutorSchedule.manualStretch(segments, coveredCount: 12).upperBound, 12)
        XCTAssertTrue(LiveTutorSchedule.manualStretch([], coveredCount: 0).isEmpty)
    }

    // MARK: - Prompts

    func testTheTutorAnswersInTheTranslationTargetLanguage() {
        let simplified = LiveTutorPrompts.Voice(targetLanguage: "zh-Hans")
        XCTAssertTrue(simplified.languageName.contains("简体中文"))
        XCTAssertEqual(simplified.ideasLabel, "关键概念")
        XCTAssertEqual(LiveTutorPrompts.Voice(targetLanguage: "zh-Hant").ideasLabel, "關鍵概念")
        XCTAssertEqual(LiveTutorPrompts.Voice(targetLanguage: "").ideasLabel, "关键概念")

        let english = LiveTutorPrompts.Voice(targetLanguage: "en")
        XCTAssertEqual(english.languageName, "English")
        XCTAssertEqual(english.ideasLabel, "Key ideas")
    }

    func testAnExplanationFencesTheNewStretchAndKeepsTheRestAsBackground() {
        let background = [line(1, 0, 10, "Last week we covered EQ.")]
        let stretch = [line(2, 10, 20, "Today, compression and the ratio knob.")]
        let messages = LiveTutorPrompts.explainMessages(
            stretch: stretch,
            draft: "and the threshold",
            background: background,
            previous: ["**正在讲**: EQ basics."],
            voice: .init(targetLanguage: "zh-Hans"),
            courseBlock: "Course context (authoritative — prefer it over your own guesses):\n- Course: Audio Engineering",
            budget: .cloud)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertTrue(messages[0].content.hasPrefix("Course context"), "the course comes first")
        XCTAssertTrue(messages[0].content.contains("**关键概念**"))
        XCTAssertTrue(messages[0].content.contains("简体中文"))

        let user = messages[1].content
        let fence = user.components(separatedBy: "===")
        XCTAssertEqual(fence.count, 3, "exactly one fenced stretch")
        XCTAssertTrue(fence[1].contains("[00:10] Today, compression and the ratio knob."))
        XCTAssertTrue(fence[1].contains("[still speaking] and the threshold"))
        XCTAssertFalse(fence[1].contains("Last week"), "background stays outside the fence")
        XCTAssertTrue(fence[0].contains("Last week we covered EQ."))
        XCTAssertTrue(fence[0].contains("EQ basics."), "earlier explanations are shown so they are not repeated")
        XCTAssertTrue(fence[0].contains("[00:10–00:20]"))
    }

    func testAQuestionKeepsEarlierQuestionsAsConversation() {
        let messages = LiveTutorPrompts.questionMessages(
            question: "And the knee?",
            transcript: [line(1, 0, 10, "The ratio sets how hard it squashes.")],
            draft: "",
            history: [(question: "What is the ratio?", answer: "How much the level is reduced.")],
            voice: .init(targetLanguage: "zh-Hans"),
            courseBlock: "",
            budget: .cloud)

        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertTrue(messages[1].content.contains("[00:00] The ratio sets how hard it squashes."))
        XCTAssertEqual(messages.map(\.role), [.system, .user, .assistant, .user, .assistant, .user])
        XCTAssertEqual(messages[3].content, "What is the ratio?")
        XCTAssertEqual(messages.last?.content, "And the knee?")
    }

    func testTailKeepsTheEndAndCutsAtALineStart() {
        let text = "[00:00] first line\n[00:10] second line\n[00:20] third line"
        XCTAssertEqual(LiveTutorPrompts.tail(text, maxChars: 500), text)
        let cut = LiveTutorPrompts.tail(text, maxChars: 30)
        XCTAssertTrue(cut.hasSuffix("[00:20] third line"))
        XCTAssertFalse(cut.contains("first"))
        XCTAssertTrue(cut.hasPrefix("…\n["), "no line arrives without its timestamp")
    }

    // MARK: - The tutor

    @MainActor
    func testExplainsOnItsOwnOnceAMinuteOfLectureHasPassed() async throws {
        let llm = ScriptedLLM(replies: [.success("**正在讲**: compression.")])
        let (tutor, buffer) = makeTutor(llm)

        speak(buffer, tutor, from: 0, to: 50)
        XCTAssertTrue(tutor.cards.isEmpty, "50 s is not a minute")

        speak(buffer, tutor, from: 50, to: 60)
        XCTAssertEqual(tutor.cards.count, 1)
        try await waitUntilIdle(tutor)

        let card = try XCTUnwrap(tutor.cards.first)
        XCTAssertEqual(card.kind, .auto)
        XCTAssertEqual(card.markdown, "**正在讲**: compression.")
        XCTAssertEqual(card.startMs, 0)
        XCTAssertEqual(card.endMs, 60_000)
        XCTAssertNil(card.errorMessage)

        // The next stretch starts where this one ended.
        speak(buffer, tutor, from: 60, to: 100)
        XCTAssertEqual(tutor.cards.count, 1)
        XCTAssertEqual(llm.requestCount, 1)
    }

    @MainActor
    func testOnlyWhenAskedNeverExplainsOnItsOwn() async throws {
        let llm = ScriptedLLM(replies: [.success("the last minute")])
        let (tutor, buffer) = makeTutor(llm, pace: .off)

        speak(buffer, tutor, from: 0, to: 300)
        XCTAssertTrue(tutor.cards.isEmpty)
        XCTAssertTrue(tutor.hasTranscript)

        tutor.explainNow()
        try await waitUntilIdle(tutor)
        XCTAssertEqual(tutor.cards.map(\.kind), [.manual])
        XCTAssertEqual(tutor.cards.first?.markdown, "the last minute")
    }

    @MainActor
    func testStopsExplainingOnItsOwnWhenTheRecordingEnds() async throws {
        let llm = ScriptedLLM(replies: [])
        let (tutor, buffer) = makeTutor(llm)
        tutor.end()

        speak(buffer, tutor, from: 0, to: 120)
        XCTAssertTrue(tutor.cards.isEmpty)
        XCTAssertFalse(tutor.isLive)
    }

    @MainActor
    func testRepeatedFailuresPauseAutomaticExplanations() async throws {
        let offline: Result<String, Error> = .failure(EngineError.networkError("offline"))
        let llm = ScriptedLLM(replies: [offline, offline, offline, .success("back")])
        let (tutor, buffer) = makeTutor(llm)

        for minute in 0..<3 {
            speak(buffer, tutor, from: minute * 60, to: minute * 60 + 60)
            try await waitUntilIdle(tutor)
        }
        XCTAssertEqual(tutor.cards.count, 3)
        XCTAssertTrue(tutor.cards.allSatisfy { $0.errorMessage != nil })
        XCTAssertNotNil(tutor.autoPausedMessage)

        speak(buffer, tutor, from: 180, to: 240)
        XCTAssertEqual(tutor.cards.count, 3, "paused: nothing new on its own")

        tutor.resumeAutomatic()
        try await waitUntilIdle(tutor)
        XCTAssertEqual(tutor.cards.count, 4)
        XCTAssertEqual(tutor.cards.last?.markdown, "back")
        XCTAssertNil(tutor.autoPausedMessage)
    }

    @MainActor
    func testRetrySendsTheSameRequestAgain() async throws {
        let offline: Result<String, Error> = .failure(EngineError.networkError("offline"))
        let llm = ScriptedLLM(replies: [offline, .success("second try")])
        let (tutor, buffer) = makeTutor(llm)

        speak(buffer, tutor, from: 0, to: 60)
        try await waitUntilIdle(tutor)
        let failed = try XCTUnwrap(tutor.cards.first)
        XCTAssertNotNil(failed.errorMessage)

        tutor.retry(failed.id)
        try await waitUntilIdle(tutor)
        XCTAssertEqual(tutor.cards.count, 1)
        XCTAssertEqual(tutor.cards.first?.markdown, "second try")
        XCTAssertNil(tutor.cards.first?.errorMessage)
        XCTAssertEqual(llm.requests.count, 2)
        XCTAssertEqual(llm.requests[0].map(\.content), llm.requests[1].map(\.content))
    }

    @MainActor
    func testAQuestionIsAnsweredFromTheTranscriptSoFar() async throws {
        let llm = ScriptedLLM(replies: [.success("It is how much the level drops."), .success("The bend.")])
        let (tutor, buffer) = makeTutor(llm, pace: .off)
        speak(buffer, tutor, from: 0, to: 30)

        tutor.ask("  What is the ratio?  ")
        try await waitUntilIdle(tutor)
        tutor.ask("And the knee?")
        try await waitUntilIdle(tutor)

        XCTAssertEqual(tutor.cards.map(\.question), ["What is the ratio?", "And the knee?"])
        XCTAssertEqual(tutor.cards.last?.markdown, "The bend.")
        let second = try XCTUnwrap(llm.requests.last)
        XCTAssertTrue(second[1].content.contains(Self.sentence))
        XCTAssertTrue(second.contains { $0.role == .assistant && $0.content == "It is how much the level drops." },
                      "the earlier answer is kept as conversation")
        XCTAssertEqual(second.last?.content, "And the knee?")

        tutor.ask("   ")
        XCTAssertEqual(tutor.cards.count, 2, "a blank question is not sent")
    }

    @MainActor
    func testANewRecordingStartsWithAClearPanel() async throws {
        let llm = ScriptedLLM(replies: [.success("first lecture")])
        let (tutor, buffer) = makeTutor(llm)
        speak(buffer, tutor, from: 0, to: 60)
        try await waitUntilIdle(tutor)
        XCTAssertEqual(tutor.cards.count, 1)

        buffer.reset()
        tutor.begin(sessionId: "next", courseContext: .empty)
        XCTAssertTrue(tutor.cards.isEmpty)
        XCTAssertFalse(tutor.hasTranscript)
        XCTAssertTrue(tutor.canSave)
    }

    @MainActor
    func testAnUnsavedTranslationHasNothingToSaveCardsTo() {
        let (tutor, _) = makeTutor(ScriptedLLM(replies: []))
        XCTAssertFalse(tutor.canSave)
    }
}

/// Answers each request with the next scripted reply, streamed word by word.
private final class ScriptedLLM: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<String, Error>]
    private var recorded: [[ChatMessage]] = []

    init(replies: [Result<String, Error>]) {
        self.replies = replies
    }

    var requests: [[ChatMessage]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var requestCount: Int { requests.count }

    func chat(messages: [ChatMessage],
              model: String,
              temperature: Double) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        recorded.append(messages)
        let reply: Result<String, Error> = replies.isEmpty ? .success("ok") : replies.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            switch reply {
            case .success(let text):
                let words = text.split(separator: " ", omittingEmptySubsequences: false)
                for (index, word) in words.enumerated() {
                    continuation.yield(index == 0 ? String(word) : " " + String(word))
                }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    func chatComplete(messages: [ChatMessage],
                      model: String,
                      temperature: Double) async throws -> String {
        var text = ""
        for try await delta in chat(messages: messages, model: model, temperature: temperature) {
            text += delta
        }
        return text
    }
}
