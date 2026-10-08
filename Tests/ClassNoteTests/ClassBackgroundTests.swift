import Foundation
import XCTest
@testable import ClassNote

/// The class background: what kind of class a course is, and what the student
/// says about one session before the AI writes about it.
final class ClassBackgroundTests: XCTestCase {

    // MARK: - Prompt

    func testThePromptCarriesTheKindOfClassAndTheSessionBackground() {
        var course = Course.new(name: "Piano Performance", instructor: "Ms. Kim")
        course.format = CourseFormat.lesson.rawValue
        course.notes = "I have played for eight years; my weak spot is pedalling."
        var session = Session.new(courseId: course.id, title: "Lesson 6")
        session.briefing = "  Pieces I played: Chopin Nocturne Op. 9 No. 2  \n"

        let block = CourseContext(course: course, session: session).promptBlock
        XCTAssertTrue(block.contains("- Course: Piano Performance"))
        XCTAssertTrue(block.contains("one-on-one lesson"), "the kind of class is described, not just named")
        XCTAssertTrue(block.contains("garbled"), "a lesson's transcript is warned to contain music")
        XCTAssertTrue(block.contains("eight years"))
        XCTAssertTrue(block.contains("About this session"))
        XCTAssertTrue(block.contains("Pieces I played: Chopin Nocturne Op. 9 No. 2"))
        XCTAssertFalse(block.contains("Op. 9 No. 2  \n"), "the briefing is trimmed")
    }

    func testABlankBriefingAddsNothing() {
        let course = Course.new(name: "Acoustics")
        var session = Session.new(courseId: course.id, title: "Week 1")
        session.briefing = "   \n "
        let context = CourseContext(course: course, session: session)
        XCTAssertEqual(context, CourseContext(course: course))
        XCTAssertFalse(context.promptBlock.contains("About this session"))

        var onlyBriefing = Session.new(courseId: nil, title: "Unfiled")
        onlyBriefing.briefing = "Guest talk on mastering"
        let unfiled = CourseContext(course: nil, session: onlyBriefing)
        XCTAssertFalse(unfiled.isEmpty, "a session with no course can still say what it was")
        XCTAssertTrue(unfiled.promptBlock.contains("Guest talk on mastering"))
    }

    func testEveryKindOfClassPointsAtARealTemplateAndRealStrings() {
        for format in CourseFormat.allCases {
            XCTAssertEqual(NoteTemplates.find(format.recommendedTemplateId).id, format.recommendedTemplateId,
                           "\(format) recommends a template that does not exist")
            for key in [format.titleKey, format.briefingPlaceholderKey] + format.briefingStarterKeys {
                XCTAssertNotEqual(L10n.t(key), key, "missing string \(key)")
            }
        }
        for key in CourseFormat.generalStarterKeys + ["briefing.placeholder.general", "course.format.none"] {
            XCTAssertNotEqual(L10n.t(key), key, "missing string \(key)")
        }
        for template in NoteTemplates.all {
            XCTAssertNotEqual(L10n.t(template.labelKey), template.labelKey)
        }
        XCTAssertEqual(CourseFormat.lesson.recommendedTemplateId, "lesson")
        XCTAssertEqual(CourseFormat.seminar.recommendedTemplateId, "discussion")
    }

    func testTheDraftUsesTheEditorsLabelsAndTheStudentsLanguage() {
        let chinese = BriefingPrompt.draftInstructions(labels: ["今天弹的曲目：", "老师重点纠正："], chinese: true)
        XCTAssertTrue(chinese.contains("今天弹的曲目： | 老师重点纠正："))
        XCTAssertTrue(chinese.contains("Simplified Chinese"))
        XCTAssertTrue(chinese.contains("(?)"), "guesses are marked rather than stated")
        XCTAssertTrue(BriefingPrompt.draftInstructions(labels: ["Topic: "], chinese: false).contains("in English"))
    }

    // MARK: - Storage

    func testABriefingRoundTripsAndABlankOneClearsIt() async throws {
        try Database.shared.setup()
        let session = Session.new(courseId: nil, title: "Briefing round trip")
        try await SessionRepository.shared.insert(session)
        addTeardownBlock { try? await SessionRepository.shared.delete(id: session.id, force: true) }

        try await SessionRepository.shared.setBriefing(session.id, briefing: "  Pieces I played: Liszt  ")
        var stored = try await SessionRepository.shared.get(id: session.id)
        XCTAssertEqual(stored?.briefing, "Pieces I played: Liszt")

        try await SessionRepository.shared.setBriefing(session.id, briefing: " \n ")
        stored = try await SessionRepository.shared.get(id: session.id)
        XCTAssertNil(stored?.briefing)
    }

    func testCarryOverTakesTheLatestEarlierSessionOfTheSameCourse() async throws {
        try Database.shared.setup()
        let piano = Course.new(name: "Piano")
        let theory = Course.new(name: "Theory")
        try await CourseRepository.shared.insert(piano)
        try await CourseRepository.shared.insert(theory)
        addTeardownBlock {
            try? await CourseRepository.shared.delete(id: piano.id)
            try? await CourseRepository.shared.delete(id: theory.id)
        }

        func lesson(_ course: Course, at startedAt: Int64, _ briefing: String?) async throws -> Session {
            var s = Session.new(courseId: course.id, title: "at \(startedAt)")
            s.startedAt = startedAt
            s.briefing = briefing
            try await SessionRepository.shared.insert(s)
            addTeardownBlock { try? await SessionRepository.shared.delete(id: s.id, force: true) }
            return s
        }
        _ = try await lesson(piano, at: 1_000, "Pieces I played: Bach")
        _ = try await lesson(piano, at: 2_000, "Pieces I played: Chopin")
        _ = try await lesson(piano, at: 2_500, nil)
        _ = try await lesson(theory, at: 2_800, "Topic: cadences")
        let today = try await lesson(piano, at: 3_000, nil)
        _ = try await lesson(piano, at: 4_000, "Pieces I played: Ravel")

        let carried = try await SessionRepository.shared.previousBriefing(courseId: piano.id, before: today)
        XCTAssertEqual(carried, "Pieces I played: Chopin",
                       "the latest earlier one with a background, from this course, never a later one")

        let first = try await SessionRepository.shared.previousBriefing(
            courseId: theory.id, before: Session.new(courseId: theory.id, title: "x"))
        XCTAssertEqual(first, "Topic: cadences")
    }

    func testTheKindOfClassRoundTripsWithoutTouchingTheRestOfTheCourse() async throws {
        try Database.shared.setup()
        var course = Course.new(name: "Orchestra", instructor: "Dr. Park")
        course.glossary = "tutti = 全奏"
        try await CourseRepository.shared.insert(course)
        addTeardownBlock { try? await CourseRepository.shared.delete(id: course.id) }

        try await CourseRepository.shared.setFormat(course.id, format: .ensemble)
        var stored = try await CourseRepository.shared.get(id: course.id)
        XCTAssertEqual(stored?.formatValue, .ensemble)
        XCTAssertEqual(stored?.instructor, "Dr. Park")
        XCTAssertEqual(stored?.glossary, "tutti = 全奏")

        try await CourseRepository.shared.setFormat(course.id, format: nil)
        stored = try await CourseRepository.shared.get(id: course.id)
        XCTAssertNil(stored?.format)

        var unknown = course
        unknown.format = "something-a-later-build-added"
        XCTAssertNil(unknown.formatValue, "an unknown format reads as not set rather than failing")
    }
}
