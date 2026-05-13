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
                                Task { await vm.startSession(courseId: selectedCourseId, source: .microphone) }
                            },
                            onImport: { url in
                                Task { await vm.importFile(url: url, courseId: selectedCourseId) }
                            },
                            onDelete: { vm.deleteSession(id: $0) })
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            Group {
                if showingSearchResults {
                    SearchResultsView(query: searchText)
                } else if let sid = selectedSessionId {
                    SessionDetailView(sessionId: sid)
                } else {
                    MainEmptyStateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $searchText, prompt: Text(L10n.t("main.search.prompt")))
        .onSubmit(of: .search) {
            showingSearchResults = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty { showingSearchResults = false }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if appState.isRecording {
                    Button(role: .destructive) {
                        appState.stopRecording()
                    } label: {
                        Label(L10n.t("toolbar.stop"), systemImage: "stop.circle.fill")
                    }
                    .tint(Theme.recording)
                } else {
                    Menu {
                        Button {
                            Task { await vm.startSession(courseId: selectedCourseId, source: .microphone) }
                        } label: {
                            Label(L10n.t("toolbar.record.menu.mic"), systemImage: "mic.fill")
                        }
                        Button {
                            Task { await vm.startSession(courseId: selectedCourseId, source: .system) }
                        } label: {
                            Label(L10n.t("toolbar.record.menu.system"), systemImage: "speaker.wave.3.fill")
                        }
                        Button {
                            Task { await vm.startSession(courseId: selectedCourseId, source: .mixed) }
                        } label: {
                            Label(L10n.t("toolbar.record.menu.mixed"), systemImage: "person.wave.2.fill")
                        }
                    } label: {
                        Label(L10n.t("toolbar.record"), systemImage: "record.circle")
                    } primaryAction: {
                        Task { await vm.startSession(courseId: selectedCourseId, source: .microphone) }
                    }
                    .disabled(appState.apiConfig.apiKey.isEmpty && appState.sttBackend == .openAICompatible)
                    .help(appState.apiConfig.apiKey.isEmpty
                          ? L10n.t("toolbar.help.configureKey")
                          : L10n.t("toolbar.help.recordHint"))
                }

                Button {
                    NotificationCenter.default.post(name: .toggleOverlay, object: nil)
                } label: {
                    Label(L10n.t("toolbar.overlay"), systemImage: "rectangle.on.rectangle")
                }
                .help(L10n.t("toolbar.overlay.help"))
            }
        }
        .task { await vm.refresh() }
        .onChange(of: appState.isRecording) { _, _ in
            Task { await vm.refresh() }
        }
        .alert(L10n.t("common.error"),
               isPresented: Binding(get: { appState.lastError != nil },
                                    set: { if !$0 { appState.lastError = nil } })) {
            Button("OK") { appState.lastError = nil }
        } message: {
            Text(appState.lastError ?? "")
        }
    }
}

struct MainEmptyStateView: View {
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 120, height: 120)
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            Text(L10n.t("main.empty.title"))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(L10n.t("main.empty.description"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }
}

@MainActor
final class MainWindowViewModel: ObservableObject {
    @Published var courses: [Course] = []
    @Published private var sessionsByCourse: [String?: [Session]] = [:]

    func sessions(for courseId: String?) -> [Session] {
        if courseId == nil {
            // "All sessions" entry: flatten everything.
            return sessionsByCourse.values.flatMap { $0 }.sorted { $0.startedAt > $1.startedAt }
        }
        return sessionsByCourse[courseId] ?? []
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

    func startSession(courseId: String?, source: AudioSourceKind = .microphone) async {
        let app = AppState.shared
        if app.isRecording {
            app.stopRecording()
            return
        }
        _ = await app.startNewSession(courseId: courseId, source: source)
        await refresh()
    }

    func importFile(url: URL, courseId: String?) async {
        do {
            let sid = try await AppState.shared.orchestrator.ingestFile(url: url, courseId: courseId)
            NotificationCenter.default.post(name: .openLiveSession, object: sid)
            await refresh()
        } catch {
            AppState.shared.setError(error.localizedDescription)
        }
    }
}
