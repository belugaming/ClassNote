import Foundation
import Combine

extension Notification.Name {
    /// A long job on a lecture (notes, an answer, flashcards, a study tool, a
    /// translation pass, a highlight explanation) has ended and saved what it
    /// made. `userInfo["sessionId"]` names the lecture; `object` is the view
    /// model that ran it.
    static let sessionContentDidChange = Notification.Name("sessionContentDidChange")
}

/// The long jobs running on one lecture, and what they have streamed so far.
///
/// The detail view builds a new view model for every lecture it shows, but a
/// job started on one keeps running after the user moves on. Held here, by
/// lecture, its state outlives the view model that started it: coming back
/// shows it still running, and the buttons that would start it a second time
/// stay disabled.
@MainActor
final class SessionJobState: ObservableObject {
    let sessionId: String

    @Published var isGeneratingNotes = false
    @Published var streamingNoteMarkdown = ""
    @Published var streamingNoteThinking = ""

    @Published var isAnsweringQuestion = false
    @Published var streamingQAResponse = ""
    @Published var streamingQAThinking = ""

    @Published var isGeneratingFlashcards = false
    @Published var streamingFlashcardsRaw = ""

    @Published var isGeneratingStudyTool = false
    @Published var streamingStudyToolId: String?
    @Published var streamingStudyToolMarkdown = ""

    @Published var isRetranslating = false
    @Published var retranslateProgress: (done: Int, total: Int)?

    /// Set while a local-model job runs on a shortened transcript.
    @Published var transcriptTruncatedNotice = ""

    init(sessionId: String) {
        self.sessionId = sessionId
    }
}

@MainActor
final class SessionJobs {
    static let shared = SessionJobs()

    /// One small object per lecture opened, kept for the life of the app so
    /// every view model of a lecture watches the same one.
    private var states: [String: SessionJobState] = [:]

    func state(for sessionId: String) -> SessionJobState {
        if let state = states[sessionId] { return state }
        let state = SessionJobState(sessionId: sessionId)
        states[sessionId] = state
        return state
    }

    /// Tells every view of the lecture to reload what a job saved, the one
    /// on screen now included, which is not the view model that ran it when
    /// the user switched away and back.
    func jobDidFinish(sessionId: String, by owner: AnyObject?) {
        NotificationCenter.default.post(name: .sessionContentDidChange,
                                        object: owner,
                                        userInfo: ["sessionId": sessionId])
    }
}
