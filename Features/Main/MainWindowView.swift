import SwiftUI
import UniformTypeIdentifiers
import Combine

/// Which sessions the middle column lists.
enum LibraryFilter: Hashable {
    case all
    case unfiled
    case course(String)
}

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = MainWindowViewModel()
    @ObservedObject private var prefs = RecordingPreferences.shared
    @State private var filter: LibraryFilter? = .all
    @State private var selectedSessionId: String?
    @State private var searchText = ""
    @State private var showingSearchResults = false
    /// Set when a search hit is clicked, so the detail view knows which line
    /// to scroll to. Carries a token, so clicking the same hit twice re-fires.
    @State private var jumpTarget: SegmentJumpTarget?
    @State private var showingTaskCenter = false
    @State private var showingDiagnostics = false
    @State private var showingFirstLaunchGuide = false
    @State private var importingInto: ImportRequest?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage("hasCompletedFirstLaunchTutorial.v1", store: AppEnvironment.defaults)
    private var hasCompletedFirstLaunchTutorial = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(filter: $filter, vm: vm,
                           onRecord: { courseId in RecordingLauncher.start(appState, courseId: courseId) },
                           onImport: { courseId in importingInto = ImportRequest(courseId: courseId) })
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } content: {
            SessionListView(title: filterTitle,
                            sessions: visibleSessions,
                            courses: vm.courses,
                            selection: $selectedSessionId,
                            recordingSessionId: appState.isRecording ? appState.currentSessionId : nil,
                            vm: vm,
                            onRecord: { RecordingLauncher.start(appState, courseId: currentCourseId) },
                            onImport: { importingInto = ImportRequest(courseId: currentCourseId) },
                            onDropFiles: { urls in Task { await vm.importFiles(urls: urls, courseId: currentCourseId) } })
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
        } detail: {
            VStack(spacing: 0) {
                if let interrupted = appState.interruptedSessions.first {
                    RecoveryBanner(session: interrupted,
                                   recover: { Task { await recover(interrupted, retranscribe: false) } },
                                   recoverAndRetranscribe: { Task { await recover(interrupted, retranscribe: true) } },
                                   dismiss: {
                                       Task {
                                           await appState.dismissInterruptedSession(interrupted)
                                           await vm.refresh()
                                       }
                                   })
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: Text(L10n.t("main.search.prompt")))
        .onSubmit(of: .search) {
            showingSearchResults = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty { showingSearchResults = false }
        }
        // A jump belongs to the click that produced it; opening the session
        // another way later must not scroll to the old hit.
        .onChange(of: selectedSessionId) { _, newValue in
            if let target = jumpTarget, target.sessionId != newValue { jumpTarget = nil }
            if newValue != nil { showingSearchResults = false }
        }
        .toolbar { toolbar }
        .task { await vm.refresh() }
        .task { await appState.refreshInterruptedSessions() }
        .onAppear {
            if !hasCompletedFirstLaunchTutorial { showingFirstLaunchGuide = true }
        }
        .onChange(of: appState.isRecording) { _, recording in
            Task {
                await vm.refresh()
                // A new recording shows up selected, so its row is easy to find.
                if recording, let id = appState.currentSessionId { selectedSessionId = id }
            }
        }
        // An import or re-transcription adds or changes sessions when it
        // finishes; refresh on that, not on every progress tick.
        .onReceive(appState.taskCenter.$items
            .map { items in items.filter { $0.status == .running }.count }
            .removeDuplicates()) { _ in Task { await vm.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .requestImportFile)) { _ in
            importingInto = ImportRequest(courseId: currentCourseId)
        }
        .fileImporter(isPresented: Binding(get: { importingInto != nil },
                                           set: { if !$0 { importingInto = nil } }),
                      allowedContentTypes: [.movie, .audio, .mpeg4Movie, .audiovisualContent],
                      allowsMultipleSelection: true) { result in
            let courseId = importingInto?.courseId
            switch result {
            case .success(let urls):
                Task { await vm.importFiles(urls: urls, courseId: courseId) }
            case .failure(let err):
                appState.setError(err.localizedDescription)
            }
        }
        .alert(L10n.t("common.error"),
               isPresented: Binding(get: { appState.lastError != nil },
                                    set: { if !$0 { appState.lastError = nil } })) {
            Button(L10n.t("common.ok")) { appState.lastError = nil }
        } message: {
            Text(appState.lastError ?? "")
        }
        .sheet(isPresented: $showingTaskCenter) {
            TaskCenterSheet(taskCenter: appState.taskCenter)
        }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsSheet().environmentObject(appState)
        }
        .sheet(isPresented: $showingFirstLaunchGuide) {
            FirstLaunchGuideSheet {
                hasCompletedFirstLaunchTutorial = true
                showingFirstLaunchGuide = false
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if showingSearchResults {
            SearchResultsView(query: searchText) { target in
                jumpTarget = target
                selectedSessionId = target.sessionId
                showingSearchResults = false
            }
        } else if let sid = selectedSessionId {
            // .id(sid) gives every session its own view model, so a generation
            // started for one session can never publish into the next one.
            SessionDetailView(sessionId: sid, jumpTarget: jumpTarget,
                              onChanged: { Task { await vm.refresh() } },
                              onDeleted: {
                                  selectedSessionId = nil
                                  Task { await vm.refresh() }
                              })
                .id(sid)
        } else {
            WelcomeView(hasSessions: vm.totalSessionCount > 0,
                        isCredentialMissing: appState.isMissingCloudCredentialForRecording,
                        onRecord: { RecordingLauncher.start(appState, courseId: currentCourseId) },
                        onImport: { importingInto = ImportRequest(courseId: currentCourseId) })
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                RecordingOptionsMenuContent(source: $prefs.source,
                                            intent: $prefs.intent,
                                            translationEnabled: $appState.translationEnabled)
            } label: {
                Label(appState.isRecording ? L10n.t("record.stop") : L10n.t("record.start"),
                      systemImage: appState.isRecording ? "stop.circle.fill" : "record.circle")
            } primaryAction: {
                RecordingLauncher.toggle(appState, courseId: currentCourseId)
            }
            .disabled(appState.isStartingRecording
                      || (!appState.isRecording && appState.isMissingCloudCredentialForRecording))
            .help(appState.isMissingCloudCredentialForRecording && !appState.isRecording
                  ? L10n.t("toolbar.help.configureKey")
                  : L10n.t("toolbar.record.help"))

            Button {
                WindowRouter.shared.toggleOverlay()
            } label: {
                Label(L10n.t("toolbar.overlay"), systemImage: "captions.bubble")
            }
            .help(L10n.t("toolbar.overlay.help"))

            TaskCenterButton(taskCenter: appState.taskCenter) { showingTaskCenter = true }

            Menu {
                Button {
                    importingInto = ImportRequest(courseId: currentCourseId)
                } label: {
                    Label(L10n.t("toolbar.import"), systemImage: "square.and.arrow.down")
                }
                Divider()
                Button {
                    showingDiagnostics = true
                } label: {
                    Label(L10n.t("diagnostics.title"), systemImage: "stethoscope")
                }
                Button {
                    showingFirstLaunchGuide = true
                } label: {
                    Label(L10n.t("onboarding.replay"), systemImage: "questionmark.circle")
                }
                Button {
                    NSWorkspace.shared.open(AppBootstrap.applicationSupportURL)
                } label: {
                    Label(L10n.t("settings.engines.reveal"), systemImage: "folder")
                }
            } label: {
                Label(L10n.t("record.more"), systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Helpers

    private var currentCourseId: String? {
        if case .course(let id) = filter { return id }
        return nil
    }

    private var filterTitle: String {
        switch filter ?? .all {
        case .all: return L10n.t("library.all")
        case .unfiled: return L10n.t("main.unfiled")
        case .course(let id): return vm.courses.first { $0.id == id }?.name ?? L10n.t("library.all")
        }
    }

    private var visibleSessions: [Session] {
        let base: [Session]
        switch filter ?? .all {
        case .all: base = vm.sessions
        case .unfiled: base = vm.sessions.filter { $0.courseId == nil }
        case .course(let id): base = vm.sessions.filter { $0.courseId == id }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func recover(_ session: Session, retranscribe: Bool) async {
        // Recovering is instant, re-transcribing takes minutes: refresh and
        // select before the long half, so the banner does not linger.
        await appState.recoverInterruptedSession(session)
        await vm.refresh()
        selectedSessionId = session.id
        guard retranscribe else { return }
        let refreshed = (try? await SessionRepository.shared.get(id: session.id)) ?? session
        await appState.retranscribe(session: refreshed)
        await vm.refresh()
    }
}

private struct ImportRequest: Equatable {
    let courseId: String?
}

// MARK: - Welcome

private struct WelcomeView: View {
    let hasSessions: Bool
    let isCredentialMissing: Bool
    let onRecord: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: hasSessions ? "text.book.closed" : "waveform.badge.mic")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 8) {
                Text(L10n.t(hasSessions ? "main.pick.title" : "main.empty.title"))
                    .font(.title.weight(.semibold))
                Text(L10n.t(hasSessions ? "main.pick.description" : "main.empty.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            HStack(spacing: 10) {
                Button(action: onRecord) {
                    Label(L10n.t("record.start"), systemImage: "record.circle")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isCredentialMissing)
                Button(action: onImport) {
                    Label(L10n.t("toolbar.import"), systemImage: "square.and.arrow.down")
                        .frame(minWidth: 100)
                }
                .controlSize(.large)
            }
            if isCredentialMissing {
                Label(L10n.t("toolbar.help.configureKey"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Recovery banner

private struct RecoveryBanner: View {
    let session: Session
    let recover: () -> Void
    let recoverAndRetranscribe: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("recovery.banner.title")).font(.headline)
                Text("\(session.title) · \(L10n.t("recovery.banner.subtitle"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(L10n.t("recovery.action.dismiss"), action: dismiss)
            Button(L10n.t("recovery.action.recoverAndRetranscribe"), action: recoverAndRetranscribe)
            Button(L10n.t("recovery.action.recover"), action: recover)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.warning.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - First launch guide

private struct FirstLaunchGuideSheet: View {
    let onFinish: () -> Void
    @State private var index = 0

    private struct Step {
        let icon: String
        let titleKey: String
        let bodyKey: String
        let points: [String]
    }

    private let steps: [Step] = [
        Step(icon: "gearshape.2", titleKey: "onboarding.step.setup.title", bodyKey: "onboarding.step.setup.body",
             points: ["onboarding.step.setup.point.api", "onboarding.step.setup.point.permissions",
                      "onboarding.step.setup.point.diagnostics"]),
        Step(icon: "waveform.badge.mic", titleKey: "onboarding.step.capture.title",
             bodyKey: "onboarding.step.capture.body",
             points: ["onboarding.step.capture.point.record", "onboarding.step.capture.point.import",
                      "onboarding.step.capture.point.translateOnly"]),
        Step(icon: "sparkles", titleKey: "onboarding.step.study.title", bodyKey: "onboarding.step.study.body",
             points: ["onboarding.step.study.point.notes", "onboarding.step.study.point.qa",
                      "onboarding.step.study.point.flashcards"]),
        Step(icon: "checklist", titleKey: "onboarding.step.control.title", bodyKey: "onboarding.step.control.body",
             points: ["onboarding.step.control.point.tasks", "onboarding.step.control.point.saveTemporary",
                      "onboarding.step.control.point.export"]),
    ]

    var body: some View {
        let step = steps[index]
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                Image(systemName: step.icon)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .frame(height: 60)
                Text(L10n.t(step.titleKey))
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(L10n.t(step.bodyKey))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(step.points, id: \.self) { point in
                        Label {
                            Text(L10n.t(point)).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        }
                        .font(.callout)
                    }
                }
                .padding(16)
                .frame(maxWidth: 480, alignment: .leading)
                .cardBackground()
            }
            .padding(32)
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                Button(L10n.t("onboarding.skip"), action: onFinish)
                    .buttonStyle(.borderless)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(steps.indices, id: \.self) { i in
                        Circle()
                            .fill(i == index ? Theme.accent : Theme.hairline)
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                Button(L10n.t("onboarding.back")) { index = max(0, index - 1) }
                    .disabled(index == 0)
                Button(index == steps.count - 1 ? L10n.t("onboarding.finish") : L10n.t("onboarding.next")) {
                    if index == steps.count - 1 { onFinish() } else { index += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 540)
        .interactiveDismissDisabled()
    }
}

// MARK: - View model

@MainActor
final class MainWindowViewModel: ObservableObject {
    @Published var courses: [Course] = []
    @Published private(set) var sessions: [Session] = []

    var totalSessionCount: Int { sessions.count }

    func count(for filter: LibraryFilter) -> Int {
        switch filter {
        case .all: return sessions.count
        case .unfiled: return sessions.filter { $0.courseId == nil }.count
        case .course(let id): return sessions.filter { $0.courseId == id }.count
        }
    }

    func refresh() async {
        do {
            courses = try await CourseRepository.shared.all()
            sessions = try await SessionRepository.shared.all()
        } catch {
            NSLog("[ClassNote] refresh failed: \(error)")
        }
    }

    func createCourse(name: String) async -> Course? {
        let course = Course.new(name: name)
        do {
            try await CourseRepository.shared.insert(course)
            await refresh()
            return course
        } catch {
            AppState.shared.setError(error.localizedDescription)
            return nil
        }
    }

    func updateCourse(_ course: Course) async {
        do {
            try await CourseRepository.shared.update(course)
        } catch {
            AppState.shared.setError(error.localizedDescription)
        }
        await refresh()
    }

    func deleteCourse(id: String) async {
        do {
            try await CourseRepository.shared.delete(id: id)
        } catch {
            AppState.shared.setError(error.localizedDescription)
        }
        await refresh()
    }

    func deleteSession(id: String) async {
        do {
            // The repository refuses to delete a session that is recording;
            // that refusal is the message the user needs.
            try await SessionRepository.shared.delete(id: id)
        } catch {
            AppState.shared.setError(error.localizedDescription)
        }
        await refresh()
    }

    func renameSession(id: String, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await SessionRepository.shared.setTitle(id, title: trimmed)
        } catch {
            AppState.shared.setError(error.localizedDescription)
        }
        await refresh()
    }

    func moveSession(id: String, courseId: String?) async {
        do {
            try await SessionRepository.shared.move(id: id, toCourseId: courseId)
        } catch {
            AppState.shared.setError(error.localizedDescription)
        }
        await refresh()
    }

    func importFiles(urls: [URL], courseId: String?) async {
        await AppState.shared.importFiles(urls: urls, courseId: courseId)
        await refresh()
    }
}
