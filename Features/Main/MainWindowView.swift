import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = MainWindowViewModel()
    @State private var selectedCourse: CourseSidebarSelection? = .all
    @State private var selectedSessionId: String? = nil
    @State private var searchText: String = ""
    @State private var showingSearchResults = false

    private var selectedCourseId: String? {
        selectedCourse?.courseId
    }

    var body: some View {
        NavigationSplitView {
            CourseListView(selection: $selectedCourse,
                           totalSessionCount: vm.totalSessionCount,
                           courses: vm.courses,
                           onCreate: { vm.createCourse(name: $0) },
                           onDelete: { id in
                               vm.deleteCourse(id: id)
                               if selectedCourse == .course(id: id) {
                                   selectedCourse = .all
                                   selectedSessionId = nil
                               }
                           })
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            SessionListView(courseId: selectedCourseId,
                            selection: $selectedSessionId,
                            courses: vm.courses,
                            sessions: vm.sessions(for: selectedCourseId),
                            onStartSession: {
                                Task { await vm.startSession(courseId: selectedCourseId, source: .microphone) }
                            },
                            onImport: { url in
                                Task { await vm.importFile(url: url, courseId: selectedCourseId) }
                            },
                            onDelete: { vm.deleteSession(id: $0) },
                            onMove: { sessionId, courseId in
                                Task {
                                    await vm.moveSession(id: sessionId, courseId: courseId)
                                    syncSelectedSessionWithVisibleList()
                                }
                            })
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            Group {
                if showingSearchResults {
                    SearchResultsView(query: searchText)
                } else if let sid = selectedSessionId {
                    SessionDetailView(sessionId: sid)
                } else {
                    MainEmptyStateView(isApiKeyMissing: appState.apiConfig.apiKey.isEmpty && appState.sttBackend == .openAICompatible,
                                       onStart: {
                                           Task { await vm.startSession(courseId: selectedCourseId, source: .microphone) }
                                       },
                                       onImport: {
                                           NotificationCenter.default.post(name: .requestImportFile, object: nil)
                                       })
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
        .onChange(of: selectedCourse) { _, _ in
            syncSelectedSessionWithVisibleList()
        }
        .onChange(of: appState.isRecording) { _, _ in
            Task {
                await vm.refresh()
                syncSelectedSessionWithVisibleList()
            }
        }
        .alert(L10n.t("common.error"),
               isPresented: Binding(get: { appState.lastError != nil },
                                    set: { if !$0 { appState.lastError = nil } })) {
            Button("OK") { appState.lastError = nil }
        } message: {
            Text(appState.lastError ?? "")
        }
    }

    private func syncSelectedSessionWithVisibleList() {
        guard let selectedSessionId else { return }
        let visibleSessionIds = Set(vm.sessions(for: selectedCourseId).map(\.id))
        if !visibleSessionIds.contains(selectedSessionId) {
            self.selectedSessionId = nil
        }
    }
}

struct MainEmptyStateView: View {
    let isApiKeyMissing: Bool
    let onStart: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Theme.accentSoft)
                        .frame(width: 96, height: 96)
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                VStack(spacing: 8) {
                    Text(L10n.t("main.empty.title"))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text(L10n.t("main.empty.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 460)
                }
            }

            HStack(spacing: 10) {
                Button {
                    onStart()
                } label: {
                    Label(L10n.t("toolbar.newSession"), systemImage: "mic.circle.fill")
                        .frame(minWidth: 116)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(isApiKeyMissing)

                Button {
                    onImport()
                } label: {
                    Label(L10n.t("toolbar.import"), systemImage: "square.and.arrow.down")
                        .frame(minWidth: 96)
                }
                .controlSize(.large)
            }

            if isApiKeyMissing {
                Label(L10n.t("toolbar.help.configureKey"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.warning.opacity(0.12)))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surfaceElevated.opacity(0.35))
    }
}

@MainActor
final class MainWindowViewModel: ObservableObject {
    @Published var courses: [Course] = []
    @Published private var allSessions: [Session] = []
    @Published private var sessionsByCourse: [String: [Session]] = [:]

    var totalSessionCount: Int { allSessions.count }

    func sessions(for courseId: String?) -> [Session] {
        guard let courseId else {
            return allSessions
        }
        return sessionsByCourse[courseId] ?? []
    }

    func refresh() async {
        do {
            courses = try await CourseRepository.shared.all()
            let sessions = try await SessionRepository.shared.all()
            var grouped: [String: [Session]] = [:]
            for c in courses { grouped[c.id] = [] }
            for s in sessions {
                guard let courseId = s.courseId else { continue }
                grouped[courseId, default: []].append(s)
            }
            self.allSessions = sessions
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

    func moveSession(id: String, courseId: String?) async {
        do {
            try await SessionRepository.shared.move(id: id, toCourseId: courseId)
            await refresh()
        } catch {
            AppState.shared.setError(error.localizedDescription)
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
