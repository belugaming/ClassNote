import Foundation

/// What kind of class a course is. It changes what is worth writing down: a
/// lecture's notes are its concepts, a piano lesson's are the teacher's
/// feedback on each piece and what to practise before the next one.
enum CourseFormat: String, CaseIterable, Identifiable, Sendable {
    case lecture
    case seminar
    case lab
    case lesson
    case ensemble

    var id: String { rawValue }

    var titleKey: String { "course.format.\(rawValue)" }

    /// How a prompt describes the class, including what the recording of one
    /// sounds like when that matters for reading its transcript.
    var promptDescription: String {
        switch self {
        case .lecture:
            return "a lecture: one instructor presenting to a class"
        case .seminar:
            return "a seminar or discussion section: several voices, arguments and assigned readings"
        case .lab:
            return "a lab or studio session: hands-on work, procedures, equipment and results"
        case .lesson:
            return "a one-on-one lesson (for example an instrument or voice lesson): the teacher works with "
                + "this student on their own pieces and technique. Stretches where the student plays or sings "
                + "come out of speech recognition as garbled or repeated text; skip them"
        case .ensemble:
            return "a rehearsal, masterclass or ensemble session: a conductor or teacher working with "
                + "players on repertoire. Stretches of music come out of speech recognition as garbled "
                + "or repeated text; skip them"
        }
    }

    /// The note template that fits this kind of class best.
    var recommendedTemplateId: String {
        switch self {
        case .lecture, .lab: return "study"
        case .seminar: return "discussion"
        case .lesson, .ensemble: return "lesson"
        }
    }

    /// Sentence starters the session background offers, so a student facing an
    /// empty box knows what is worth saying.
    var briefingStarterKeys: [String] {
        switch self {
        case .lecture:
            return ["briefing.starter.topic", "briefing.starter.exam", "briefing.starter.confused",
                    "briefing.starter.homework"]
        case .seminar:
            return ["briefing.starter.readings", "briefing.starter.myView", "briefing.starter.homework"]
        case .lab:
            return ["briefing.starter.experiment", "briefing.starter.tools", "briefing.starter.problems"]
        case .lesson:
            return ["briefing.starter.pieces", "briefing.starter.feedback", "briefing.starter.practice",
                    "briefing.starter.feeling"]
        case .ensemble:
            return ["briefing.starter.repertoire", "briefing.starter.myPart", "briefing.starter.feedback",
                    "briefing.starter.practice"]
        }
    }

    var briefingPlaceholderKey: String { "briefing.placeholder.\(rawValue)" }

    /// Starters for a course with no format yet, or a session with no course.
    static let generalStarterKeys = ["briefing.starter.topic", "briefing.starter.confused",
                                     "briefing.starter.homework"]
}
