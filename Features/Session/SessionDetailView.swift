import SwiftUI

/// Right column: one session. A header with what it is and what can be done
/// with it, four tabs, and the audio player along the bottom.
struct SessionDetailView: View {
    let sessionId: String
    var jumpTarget: SegmentJumpTarget?
    var onChanged: () -> Void = {}
    var onDeleted: () -> Void = {}

    @EnvironmentObject var appState: AppState
    @StateObject private var vm = SessionDetailViewModel()
    @State private var tab: DetailTab = .transcript
    @State private var confirmingRetranscribe = false
    @State private var confirmingDelete = false

    enum DetailTab: String, CaseIterable, Identifiable {
        case transcript, notes, study, highlights
        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .transcript: return "session.tab.transcript"
            case .notes: return "session.tab.notes"
            case .study: return "session.tab.study"
            case .highlights: return "session.tab.highlights"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isLive { liveBanner }
            Divider()
            Group {
                switch tab {
                case .transcript: TranscriptView(vm: vm)
                case .notes: NotesView(vm: vm)
                case .study: StudyView(vm: vm)
                case .highlights: HighlightsView(vm: vm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if vm.hasAudio && !vm.isSessionRecording {
                Divider()
                PlayerBar(vm: vm)
            }
        }
        .task(id: sessionId) {
            await vm.load(sessionId: sessionId)
            applyJump(jumpTarget)
        }
        // The target session may already be on screen, in which case the
        // `.task(id:)` does not run again and this is what fires.
        .onChange(of: jumpTarget) { _, target in applyJump(target) }
        // While it records, pick up new lines every few seconds.
        .task(id: vm.isSessionRecording) {
            while vm.isSessionRecording, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await vm.refreshSegments()
            }
        }
        .onDisappear { vm.stopPlayback() }
        .confirmationDialog(L10n.t("session.action.retranscribe"),
                            isPresented: $confirmingRetranscribe, titleVisibility: .visible) {
            Button(L10n.t("session.action.retranscribe"), role: .destructive) {
                guard let s = vm.session?.session else { return }
                Task {
                    await appState.retranscribe(session: s)
                    await vm.load(sessionId: sessionId)
                    onChanged()
                }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("session.retranscribe.confirm.message"))
        }
        .confirmationDialog(L10n.t("main.deleteSession.confirm.title"),
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(L10n.t("common.delete"), role: .destructive) {
                Task {
                    do {
                        try await SessionRepository.shared.delete(id: sessionId)
                        onDeleted()
                    } catch {
                        appState.setError(error.localizedDescription)
                    }
                }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(String(format: L10n.t("main.deleteSession.confirm.message"), vm.session?.session.title ?? ""))
        }
    }

    private var isLive: Bool {
        vm.isSessionRecording && appState.isRecording && appState.currentSessionId == sessionId
    }

    private func applyJump(_ target: SegmentJumpTarget?) {
        vm.applyJump(target)
        if target?.sessionId == sessionId { tab = .transcript }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.session?.session.title ?? " ")
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    metadata
                }
                Spacer(minLength: 12)
                actions
            }
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tabTitle(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func tabTitle(_ tab: DetailTab) -> String {
        let title = L10n.t(tab.titleKey)
        if tab == .highlights, !vm.highlights.isEmpty { return "\(title) \(vm.highlights.count)" }
        return title
    }

    @ViewBuilder
    private var metadata: some View {
        if let s = vm.session?.session {
            HStack(spacing: 6) {
                if let course = vm.course {
                    Label(course.name, systemImage: "book.closed")
                    Text("·")
                }
                Text(DateLabels.dateTime(s.startedDate))
                if s.durationMs > 0 {
                    Text("·")
                    Text(s.durationLabel).monospacedDigit()
                }
                Text("·")
                Label(s.sourceValue.shortTitle, systemImage: s.sourceValue.icon)
                if s.stateValue != .transcribed && s.stateValue != .summarized {
                    Text(s.stateLabel).pill(s.stateColor)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }

    private var hasTranscript: Bool { !(vm.session?.segments.isEmpty ?? true) }

    private var actions: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(NoteTemplates.all) { template in
                    Button(L10n.t(template.labelKey)) {
                        tab = .notes
                        Task { await vm.generateNotes(template: template) }
                    }
                }
            } label: {
                Label(vm.isGeneratingNotes ? L10n.t("session.action.generatingNotes")
                                           : L10n.t("session.action.generateNotes"),
                      systemImage: "sparkles")
            } primaryAction: {
                tab = .notes
                Task { await vm.generateNotes() }
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(vm.isGeneratingNotes || !hasTranscript)

            PopUpMenuButton(entries: moreMenuEntries) {
                if vm.isRetranslating {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .fixedSize()
            .help(L10n.t("record.more"))
        }
    }

    /// The "⋯" menu: translation, re-transcription, export and delete. Read
    /// when the menu opens, so it shows the state at that moment.
    private func moreMenuEntries() -> [PopUpMenuEntry] {
        let busy = vm.isRetranslating || vm.isSessionRecording
        let failed = vm.failedTranslationCount
        let retryTitle = "\(L10n.t("session.action.retranslateFailed")) (\(failed))"

        var exports: [PopUpMenuEntry] = []
        exports.append(.item(L10n.t("session.export.transcriptMd")) { vm.runExport(.transcriptMarkdown) })
        exports.append(.item(L10n.t("session.export.transcriptTxt")) { vm.runExport(.transcriptPlain) })
        exports.append(.item(L10n.t("session.export.transcriptSrt")) { vm.runExport(.transcriptSrt) })
        exports.append(.separator)
        exports.append(.item(L10n.t("session.export.notes"), enabled: vm.note != nil) {
            vm.runExport(.notesMarkdown)
        })
        exports.append(.item(L10n.t("session.export.flashcards"), enabled: !vm.flashcards.isEmpty) {
            vm.runExport(.flashcardsMarkdown)
        })
        exports.append(.item(L10n.t("session.export.studyTools"), enabled: !vm.studyToolResults.isEmpty) {
            vm.runExport(.studyToolsMarkdown)
        })
        exports.append(.item(L10n.t("session.export.audio"), enabled: vm.hasAudio) { vm.runExport(.audio) })
        exports.append(.separator)
        exports.append(.item(L10n.t("session.export.bundle")) { vm.runExport(.bundle) })

        var entries: [PopUpMenuEntry] = []
        entries.append(.header(L10n.t("session.action.translation")))
        entries.append(.item(retryTitle, enabled: failed > 0 && !busy) {
            Task { await vm.retranslate(failedOnly: true) }
        })
        entries.append(.item(L10n.t("session.action.retranslateAll"), enabled: hasTranscript && !busy) {
            Task { await vm.retranslate(failedOnly: false) }
        })
        entries.append(.item(L10n.t("session.action.retranscribe"), enabled: vm.hasAudio && !vm.isSessionRecording) {
            confirmingRetranscribe = true
        })
        entries.append(.separator)
        entries.append(.submenu(L10n.t("session.action.export"), enabled: hasTranscript, exports))
        entries.append(.separator)
        entries.append(.item(L10n.t("main.deleteSession"), enabled: !isLive) {
            confirmingDelete = true
        })
        return entries
    }

    private var liveBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(Theme.recording)
                .symbolEffect(.pulse)
            Text(L10n.t("session.live.banner"))
                .font(.callout)
            Spacer()
            Button(L10n.t("session.live.open")) {
                WindowRouter.shared.openLive(windowId: AppState.liveWindowId)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.recording.opacity(0.08))
    }
}

// MARK: - Player

/// Play/pause, scrubber and position, docked along the bottom.
private struct PlayerBar: View {
    @ObservedObject var vm: SessionDetailViewModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                vm.scrub(to: max(0, vm.playheadMs - 10_000))
            } label: {
                Image(systemName: "gobackward.10")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("player.back10"))

            Button {
                vm.togglePlayPause()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 24)
            }
            .buttonStyle(.borderless)
            .help(L10n.t(vm.isPlaying ? "session.action.pause" : "session.action.play"))

            Button {
                vm.scrub(to: min(vm.playbackDurationMs, vm.playheadMs + 10_000))
            } label: {
                Image(systemName: "goforward.10")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("player.forward10"))

            Text(TimeLabel.string(ms: vm.playheadMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            Slider(value: Binding(get: { Double(vm.playheadMs) },
                                  set: { vm.playheadMs = Int64($0) }),
                   in: 0...max(1, Double(vm.playbackDurationMs))) { editing in
                vm.isScrubbing = editing
                if !editing { vm.scrub(to: vm.playheadMs) }
            }
            .controlSize(.small)
            Text(TimeLabel.string(ms: vm.playbackDurationMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
