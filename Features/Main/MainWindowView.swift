import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = MainWindowViewModel()
    @State private var selectedCourseId: String? = nil
    @State private var selectedSessionId: String? = nil
    @State private var searchText: String = ""
    @State private var showingSearchResults = false

    var body: some View {
        NavigationSplitView {
            CourseListView(selection: $selectedCourseId,
                           courses: vm.courses,
                           onCreate: { vm.createCourse(name: $0) },
                           onDelete: { vm.deleteCourse(id: $0) })
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            SessionListView(courseId: selectedCourseId,
                            selection: $selectedSessionId,
                            sessions: vm.sessions(for: selectedCourseId),
                            onStartSession: {
                                Task { await vm.startSession(courseId: selectedCourseId) }
                            },
                            onImport: { url in
                                Task { await vm.importFile(url: url, courseId: selectedCourseId) }
                            },
                            onDelete: { vm.deleteSession(id: $0) })
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            if showingSearchResults {
                SearchResultsView(query: searchText)
            } else if let sid = selectedSessionId {
                SessionDetailView(sessionId: sid)
            } else {
                EmptyStateView(message: "Select a session or create a new one to start.")
            }
        }
        .searchable(text: $searchText, prompt: "Search transcripts (FTS)…")
        .onSubmit(of: .search) {
            showingSearchResults = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty { showingSearchResults = false }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await vm.startSession(courseId: selectedCourseId) }
                } label: {
                    Label(appState.isRecording ? "Stop" : "Record",
                          systemImage: appState.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .disabled(appState.apiConfig.apiKey.isEmpty && appState.sttBackend == .openAICompatible)
                .help(appState.apiConfig.apiKey.isEmpty ? "Configure API key in Settings first" : "")
            }
        }
        .task {
            await vm.refresh()
        }
        .onChange(of: appState.isRecording) { _, _ in
            Task { await vm.refresh() }
        }
    }
}

struct EmptyStateView: View {
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("⌘N starts a new session · ⌘⇧N adds a course · ⌘⇧R toggles recording globally")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

@MainActor
final class MainWindowViewModel: ObservableObject {
    @Published var courses: [Course] = []
    @Published private var sessionsByCourse: [String?: [Session]] = [:]

    func sessions(for courseId: String?) -> [Session] {
        sessionsByCourse[courseId] ?? []
    }

    func refresh() async {
        do {
            courses = try await CourseRepository.shared.all()
            let allSessions = try await SessionRepository.shared.all()
            var grouped: [String?: [Session]] = [:]
            grouped[nil] = []
            for c in courses { grouped[c.id] = [] }
            for s in allSessions {
                grouped[s.courseId, default: []].append(s)
            }
            self.sessionsByCourse = grouped
        } catch {
            NSLog("[ClassNote] refresh failed: \(error)")
        }
    }

    func createCourse(name: String) {
        Task {
            let course = Course.new(name: name)
            try? await CourseRepository.shared.insert(course)
            await refresh()
        }
    }

    func deleteCourse(id: String) {
        Task {
            try? await CourseRepository.shared.delete(id: id)
            await refresh()
        }
    }

    func deleteSession(id: String) {
        Task {
            try? await SessionRepository.shared.delete(id: id)
            await refresh()
        }
    }

    func startSession(courseId: String?) async {
        let app = AppState.shared
        if app.isRecording {
            app.stopRecording()
        } else {
            do {
                let sid = try await app.orchestrator.startNewSession(courseId: courseId)
                app.currentSessionId = sid
                app.isRecording = true
                await refresh()
            } catch {
                app.setError(error.localizedDescription)
            }
        }
    }

    func importFile(url: URL, courseId: String?) async {
        do {
            _ = try await AppState.shared.orchestrator.ingestFile(url: url, courseId: courseId)
            await refresh()
        } catch {
            AppState.shared.setError(error.localizedDescription)
        }
    }
}
