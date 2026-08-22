import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = MainWindowViewModel()
    @State private var selectedSessionId: String? = nil
    @State private var searchText: String = ""
    @State private var showingSearchResults = false
    @State private var showingTaskCenter = false
    @State private var showingDiagnostics = false
    @State private var showingFirstLaunchGuide = false
    #if os(iOS)
    @State private var showingSettings = false
    #endif
    @AppStorage("hasCompletedFirstLaunchTutorial.v1") private var hasCompletedFirstLaunchTutorial = false
    private let launcher = RecordingLauncher()

    var body: some View {
        NavigationSplitView {
            CourseSessionSidebarView(selectedSessionId: $selectedSessionId,
                                      totalSessionCount: vm.totalSessionCount,
                                      courses: vm.courses,
                                      allSessions: vm.sessions(for: nil),
                                      onCreateCourse: { vm.createCourse(name: $0) },
                                      onDeleteCourse: { id in
                                          vm.deleteCourse(id: id)
                                      },
                                      onStartSession: { courseId in
                                          Task { await vm.startSession(courseId: courseId, source: .microphone) }
                                      },
                                      onImport: { urls, courseId in
                                          Task { await vm.importFiles(urls: urls, courseId: courseId) }
                                      },
                                      onDeleteSession: { vm.deleteSession(id: $0) },
                                      onMoveSession: { sessionId, courseId in
                                          Task { await vm.moveSession(id: sessionId, courseId: courseId) }
                                      },
                                      onRevealStorage: {
                                          #if os(macOS)
                                          NSWorkspace.shared.open(AppBootstrap.applicationSupportURL)
                                          #endif
                                      })
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
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
                                               Task { await vm.startSession(courseId: nil, source: .microphone) }
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
                // One start/stop control with a menu for the options, rather than
                // the seven fixed mode entries this toolbar used to duplicate
                // from the menu bar.
                Menu {
                    RecordingOptionsView(source: sourceBinding,
                                         intent: intentBinding,
                                         translationEnabled: $appState.translationEnabled)
                        .padding(8)
                        .frame(width: 240)
                } label: {
                    Label(appState.isRecording ? L10n.t("record.stop") : L10n.t("record.start"),
                          systemImage: appState.isRecording ? "stop.circle.fill" : "record.circle")
                } primaryAction: {
                    launcher.toggle(appState)
                    Task { await vm.refresh() }
                }
                .tint(appState.isRecording ? Theme.recording : Theme.accent)
                .disabled(isEngineUnconfigured)
                .help(isEngineUnconfigured
                      ? L10n.t("toolbar.help.configureKey")
                      : L10n.t("toolbar.classroomMode.help"))

                Button {
                    NotificationCenter.default.post(name: .toggleOverlay, object: nil)
                } label: {
                    Label(L10n.t("toolbar.overlay"), systemImage: "rectangle.on.rectangle")
                }
                .help(L10n.t("toolbar.overlay.help"))

                TaskCenterButton(taskCenter: appState.taskCenter) {
                    showingTaskCenter = true
                }

                // Diagnostics and the tutorial are rare, so they move out of the
                // always-visible row and into an overflow menu.
                Menu {
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
                    #if os(iOS)
                    Button {
                        showingSettings = true
                    } label: {
                        Label(L10n.t("settings.title"), systemImage: "gearshape")
                    }
                    #endif
                } label: {
                    Label(L10n.t("record.more"), systemImage: "ellipsis.circle")
                }
            }
        }
        .task { await vm.refresh() }
        .task { await appState.refreshInterruptedSessions() }
        .onAppear {
            if !hasCompletedFirstLaunchTutorial {
                showingFirstLaunchGuide = true
            }
        }
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
        #if os(iOS)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle(L10n.t("settings.title"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.t("common.close")) { showingSettings = false }
                        }
                    }
            }
            .environmentObject(appState)
        }
        #endif
    }

    private var isEngineUnconfigured: Bool {
        appState.apiConfig.apiKey.isEmpty && appState.sttBackend == .openAICompatible
    }

    private var sourceBinding: Binding<AudioSourceKind> {
        Binding(get: { launcher.source }, set: { launcher.source = $0 })
    }

    private var intentBinding: Binding<RecordingIntent> {
        Binding(get: { launcher.intent }, set: { launcher.intent = $0 })
    }
}

private struct FirstLaunchGuideSheet: View {
    let onFinish: () -> Void
    @State private var selectedIndex = 0

    private var steps: [FirstLaunchGuideStep] {
        [
            .init(icon: "key.fill",
                  tint: Theme.accent,
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
                  tint: Theme.accent,
                  titleKey: "onboarding.step.study.title",
                  bodyKey: "onboarding.step.study.body",
                  points: [
                      "onboarding.step.study.point.notes",
                      "onboarding.step.study.point.qa",
                      "onboarding.step.study.point.flashcards"
                  ]),
            .init(icon: "checklist",
                  tint: Theme.accent,
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

            ScrollView {
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
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                .prominentAccentButton()
            }
            .padding(18)
        }
        #if os(macOS)
        .frame(width: 680, height: 560)
        #endif
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
                .prominentAccentButton()
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
        .background(Theme.surface)
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
