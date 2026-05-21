import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = MainWindowViewModel()
    @State private var selectedCourse: CourseSidebarSelection? = .all
    @State private var selectedSessionId: String? = nil
    @State private var searchText: String = ""
    @State private var showingSearchResults = false
    @State private var showingTaskCenter = false
    @State private var showingDiagnostics = false
    @State private var showingFirstLaunchGuide = false
    @AppStorage("hasCompletedFirstLaunchTutorial.v1") private var hasCompletedFirstLaunchTutorial = false

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
                            onImport: { urls in
                                Task { await vm.importFiles(urls: urls, courseId: selectedCourseId) }
                            },
                            onDelete: { vm.deleteSession(id: $0) },
                            onMove: { sessionId, courseId in
                                Task {
                                    await vm.moveSession(id: sessionId, courseId: courseId)
                                    syncSelectedSessionWithVisibleList()
                                }
                            },
                            onRevealStorage: {
                                NSWorkspace.shared.open(AppBootstrap.applicationSupportURL)
                            })
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            VStack(spacing: 0) {
                if let interrupted = appState.interruptedSessions.first {
                    RecoveryBanner(session: interrupted,
                                   recover: {
                                       Task {
                                           await appState.recoverInterruptedSession(interrupted)
                                           await vm.refresh()
                                           selectedSessionId = interrupted.id
                                       }
                                   },
                                   dismiss: {
                                       Task {
                                           await appState.dismissInterruptedSession(interrupted)
                                           await vm.refresh()
                                       }
                                   })
                }

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
                        classroomModeButton(.recordMicrophone)
                        classroomModeButton(.recordSystem)
                        classroomModeButton(.recordMixed)
                        Divider()
                        classroomModeButton(.transcribeOnlyMicrophone)
                        Divider()
                        classroomModeButton(.temporaryMicrophone)
                        classroomModeButton(.temporarySystem)
                        classroomModeButton(.temporaryMixed)
                    } label: {
                        Label(L10n.t("toolbar.classroomMode"), systemImage: "rectangle.grid.1x2")
                    } primaryAction: {
                        Task { await vm.startSession(courseId: selectedCourseId, source: .microphone, translationEnabled: true) }
                    }
                    .disabled(appState.apiConfig.apiKey.isEmpty && appState.sttBackend == .openAICompatible)
                    .help(appState.apiConfig.apiKey.isEmpty
                          ? L10n.t("toolbar.help.configureKey")
                          : L10n.t("toolbar.classroomMode.help"))
                }

                Button {
                    NotificationCenter.default.post(name: .toggleOverlay, object: nil)
                } label: {
                    Label(L10n.t("toolbar.overlay"), systemImage: "rectangle.on.rectangle")
                }
                .help(L10n.t("toolbar.overlay.help"))

                TaskCenterButton(taskCenter: appState.taskCenter) {
                    showingTaskCenter = true
                }

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
                .help(L10n.t("onboarding.replay.help"))
            }
        }
        .task { await vm.refresh() }
        .task { await appState.refreshInterruptedSessions() }
        .onAppear {
            if !hasCompletedFirstLaunchTutorial {
                showingFirstLaunchGuide = true
            }
        }
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
        .sheet(isPresented: $showingTaskCenter) {
            TaskCenterSheet(taskCenter: appState.taskCenter)
        }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingFirstLaunchGuide) {
            FirstLaunchGuideSheet {
                hasCompletedFirstLaunchTutorial = true
                showingFirstLaunchGuide = false
            }
        }
    }

    private func syncSelectedSessionWithVisibleList() {
        guard let selectedSessionId else { return }
        let visibleSessionIds = Set(vm.sessions(for: selectedCourseId).map(\.id))
        if !visibleSessionIds.contains(selectedSessionId) {
            self.selectedSessionId = nil
        }
    }

    @ViewBuilder
    private func classroomModeButton(_ mode: ClassroomMode) -> some View {
        Button {
            Task {
                switch mode {
                case .recordMicrophone, .recordSystem, .recordMixed, .transcribeOnlyMicrophone:
                    await vm.startSession(courseId: selectedCourseId,
                                          source: mode.source,
                                          translationEnabled: mode.translationEnabled)
                case .temporaryMicrophone, .temporarySystem, .temporaryMixed:
                    await vm.startEphemeralTranslation(source: mode.source)
                }
            }
        } label: {
            Label(mode.title, systemImage: mode.icon)
        }
    }
}

private enum ClassroomMode: CaseIterable {
    case recordMicrophone
    case recordSystem
    case recordMixed
    case transcribeOnlyMicrophone
    case temporaryMicrophone
    case temporarySystem
    case temporaryMixed

    var source: AudioSourceKind {
        switch self {
        case .recordMicrophone, .transcribeOnlyMicrophone, .temporaryMicrophone:
            return .microphone
        case .recordSystem, .temporarySystem:
            return .system
        case .recordMixed, .temporaryMixed:
            return .mixed
        }
    }

    var translationEnabled: Bool {
        switch self {
        case .transcribeOnlyMicrophone:
            return false
        default:
            return true
        }
    }

    var title: String {
        switch self {
        case .recordMicrophone: return L10n.t("toolbar.mode.recordMic")
        case .recordSystem: return L10n.t("toolbar.mode.recordSystem")
        case .recordMixed: return L10n.t("toolbar.mode.recordMixed")
        case .transcribeOnlyMicrophone: return L10n.t("toolbar.mode.transcribeOnly")
        case .temporaryMicrophone: return L10n.t("toolbar.mode.temporaryMic")
        case .temporarySystem: return L10n.t("toolbar.mode.temporarySystem")
        case .temporaryMixed: return L10n.t("toolbar.mode.temporaryMixed")
        }
    }

    var icon: String {
        switch self {
        case .recordMicrophone: return "mic.fill"
        case .recordSystem: return "speaker.wave.3.fill"
        case .recordMixed: return "person.wave.2.fill"
        case .transcribeOnlyMicrophone: return "text.badge.checkmark"
        case .temporaryMicrophone: return "character.bubble"
        case .temporarySystem: return "speaker.wave.2"
        case .temporaryMixed: return "bubble.left.and.text.bubble.right"
        }
    }
}

private struct FirstLaunchGuideSheet: View {
    let onFinish: () -> Void
    @State private var selectedIndex = 0

    private var steps: [FirstLaunchGuideStep] {
        [
            .init(icon: "key.fill",
                  tint: Theme.warning,
                  titleKey: "onboarding.step.setup.title",
                  bodyKey: "onboarding.step.setup.body",
                  points: [
                      "onboarding.step.setup.point.api",
                      "onboarding.step.setup.point.permissions",
                      "onboarding.step.setup.point.diagnostics"
                  ]),
            .init(icon: "waveform.badge.mic",
                  tint: Theme.accent,
                  titleKey: "onboarding.step.capture.title",
                  bodyKey: "onboarding.step.capture.body",
                  points: [
                      "onboarding.step.capture.point.record",
                      "onboarding.step.capture.point.import",
                      "onboarding.step.capture.point.translateOnly"
                  ]),
            .init(icon: "sparkles",
                  tint: Theme.success,
                  titleKey: "onboarding.step.study.title",
                  bodyKey: "onboarding.step.study.body",
                  points: [
                      "onboarding.step.study.point.notes",
                      "onboarding.step.study.point.qa",
                      "onboarding.step.study.point.flashcards"
                  ]),
            .init(icon: "checklist",
                  tint: Theme.translation,
                  titleKey: "onboarding.step.control.title",
                  bodyKey: "onboarding.step.control.body",
                  points: [
                      "onboarding.step.control.point.tasks",
                      "onboarding.step.control.point.saveTemporary",
                      "onboarding.step.control.point.export"
                  ])
        ]
    }

    private var step: FirstLaunchGuideStep {
        steps[min(max(selectedIndex, 0), steps.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("onboarding.title"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(selectedIndex + 1)/\(steps.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 12)

            Divider()

            VStack(spacing: 22) {
                Image(systemName: step.icon)
                    .font(.system(size: 50, weight: .semibold))
                    .foregroundStyle(step.tint)
                    .frame(width: 96, height: 96)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                            .fill(step.tint.opacity(0.12))
                    )

                VStack(spacing: 8) {
                    Text(L10n.t(step.titleKey))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text(L10n.t(step.bodyKey))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 520)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(step.points, id: \.self) { point in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(step.tint)
                                .font(.callout)
                            Text(L10n.t(point))
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 520, alignment: .leading)
                .cardBackground()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Divider()

            HStack(spacing: 10) {
                Button(L10n.t("onboarding.skip")) {
                    onFinish()
                }
                .buttonStyle(.borderless)

                Spacer()

                HStack(spacing: 6) {
                    ForEach(steps.indices, id: \.self) { index in
                        Circle()
                            .fill(index == selectedIndex ? Theme.accent : Theme.hairline)
                            .frame(width: 7, height: 7)
                    }
                }

                Spacer()

                Button {
                    selectedIndex = max(selectedIndex - 1, 0)
                } label: {
                    Label(L10n.t("onboarding.back"), systemImage: "chevron.left")
                }
                .disabled(selectedIndex == 0)

                Button {
                    if selectedIndex == steps.count - 1 {
                        onFinish()
                    } else {
                        selectedIndex += 1
                    }
                } label: {
                    Label(selectedIndex == steps.count - 1 ? L10n.t("onboarding.finish") : L10n.t("onboarding.next"),
                          systemImage: selectedIndex == steps.count - 1 ? "checkmark.circle" : "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            .padding(18)
        }
        .frame(width: 680, height: 560)
        .interactiveDismissDisabled()
    }
}

private struct FirstLaunchGuideStep {
    let icon: String
    let tint: Color
    let titleKey: String
    let bodyKey: String
    let points: [String]
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

private struct RecoveryBanner: View {
    let session: Session
    let recover: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("recovery.banner.title"))
                    .font(.headline)
                Text("\(session.title) · \(L10n.t("recovery.banner.subtitle"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Label(L10n.t("recovery.action.dismiss"), systemImage: "xmark")
            }
            Button {
                recover()
            } label: {
                Label(L10n.t("recovery.action.recover"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.warning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.warning.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.warning.opacity(0.20))
                .frame(height: 1)
        }
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

    func startSession(courseId: String?,
                      source: AudioSourceKind = .microphone,
                      translationEnabled: Bool? = nil) async {
        let app = AppState.shared
        if app.isRecording {
            app.stopRecording()
            return
        }
        _ = await app.startNewSession(courseId: courseId,
                                      source: source,
                                      translationEnabled: translationEnabled)
        await refresh()
    }

    func startEphemeralTranslation(source: AudioSourceKind = .microphone) async {
        let app = AppState.shared
        if app.isRecording {
            app.stopRecording()
            return
        }
        _ = await app.startEphemeralTranslation(source: source)
    }

    func importFiles(urls: [URL], courseId: String?) async {
        await AppState.shared.importFiles(urls: urls, courseId: courseId)
        await refresh()
    }
}
