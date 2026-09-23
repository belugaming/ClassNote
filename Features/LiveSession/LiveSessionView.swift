import SwiftUI

/// The window a recording, a live translation or a file import runs in.
struct LiveSessionView: View {
    let windowId: String
    @EnvironmentObject var appState: AppState
    /// Resolved once per window. An import's orchestrator leaves the registry
    /// as soon as it finishes, and re-resolving on every render would re-bind
    /// this window to the live recording.
    @State private var resolved: SessionOrchestrator?

    var body: some View {
        Group {
            if let orchestrator = resolved ?? appState.orchestrator(for: windowId) {
                LiveContent(windowId: windowId, orchestrator: orchestrator)
            } else {
                EmptyStateView(systemImage: "checkmark.circle", title: L10n.t("live.finished"))
            }
        }
        .onAppear {
            if resolved == nil { resolved = appState.orchestrator(for: windowId) }
        }
    }
}

private struct LiveContent: View {
    let windowId: String
    @EnvironmentObject var appState: AppState
    @ObservedObject var orchestrator: SessionOrchestrator
    @AppStorage("liveFontSize", store: AppEnvironment.defaults) private var fontSize: Double = 22
    @AppStorage("liveDisplayMode", store: AppEnvironment.defaults) private var displayModeRaw = OverlayCaptionDisplayMode.bilingual.rawValue
    @State private var savedTemporary = false
    @State private var showHighlightConfirmation = false

    private var isLiveWindow: Bool { windowId == AppState.liveWindowId }
    /// Whether this window's work is running. An import window must not read
    /// the app-wide recording flag: that belongs to the live window.
    private var isActive: Bool {
        isLiveWindow ? appState.isRecording : orchestrator.isImporting
    }
    private var displayMode: OverlayCaptionDisplayMode {
        OverlayCaptionDisplayMode(rawValue: displayModeRaw) ?? .bilingual
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if orchestrator.isImporting { importProgress }
            Divider()
            LiveTranscript(buffer: orchestrator.transcript,
                           fontSize: fontSize,
                           displayMode: displayMode,
                           engineStatus: appState.localEngineStatus)
        }
        .navigationTitle(title)
        .overlay(alignment: .top) {
            if showHighlightConfirmation {
                Label(L10n.t("live.highlight.saved"), systemImage: "star.fill")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: appState.lastHighlightAt) { _, _ in
            guard isLiveWindow else { return }
            withAnimation { showHighlightConfirmation = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation { showHighlightConfirmation = false }
            }
        }
    }

    private var title: String {
        if orchestrator.isEphemeralTranslation { return L10n.t("live.ephemeral.title") }
        return orchestrator.currentSession?.title ?? L10n.t("live.title")
    }

    private var header: some View {
        HStack(spacing: 14) {
            status
            Spacer(minLength: 12)
            displayControls
            actions
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var status: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isActive ? (orchestrator.isImporting ? Theme.accent : Theme.recording) : Color.secondary)
                .frame(width: 10, height: 10)
                .opacity(isActive ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline).lineLimit(1)
                    if orchestrator.isEphemeralTranslation {
                        Text(L10n.t("live.ephemeral.badge")).pill(Theme.translation)
                    }
                }
                HStack(spacing: 6) {
                    Text(statusLabel)
                    if isLiveWindow {
                        Text("·")
                        Text(TimeLabel.string(ms: orchestrator.currentTimestampMs)).monospacedDigit()
                        Text("·")
                        Label(orchestrator.source.shortTitle, systemImage: orchestrator.source.icon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var statusLabel: String {
        if orchestrator.isImporting { return L10n.t("live.statusImporting") }
        guard isActive else { return L10n.t("live.statusIdle") }
        if orchestrator.isEphemeralTranslation { return L10n.t("live.statusEphemeral") }
        return L10n.t("live.statusLive")
    }

    private var displayControls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $displayModeRaw) {
                ForEach(OverlayCaptionDisplayMode.allCases) { mode in
                    Image(systemName: mode.systemImage).tag(mode.rawValue).help(mode.title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            ControlGroup {
                Button {
                    fontSize = max(14, fontSize - 2)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                Button {
                    fontSize = min(40, fontSize + 2)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
            }
            .fixedSize()
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if isLiveWindow {
                Toggle(isOn: $appState.translationEnabled) {
                    Image(systemName: "character.bubble")
                }
                .toggleStyle(.button)
                .help(L10n.t("live.translation.toggle"))

                Button {
                    WindowRouter.shared.toggleOverlay()
                } label: {
                    Image(systemName: "captions.bubble")
                }
                .help(L10n.t("menubar.toggleOverlay"))
            }

            if isLiveWindow && isActive && !orchestrator.isEphemeralTranslation {
                Button {
                    appState.markHighlight()
                } label: {
                    Label(L10n.t("live.highlight"), systemImage: "star")
                }
                .help(L10n.t("live.highlight.help"))
            }

            if orchestrator.isEphemeralTranslation {
                Button {
                    Task {
                        if await appState.saveTemporaryTranslationAsSession() != nil { savedTemporary = true }
                    }
                } label: {
                    Label(savedTemporary ? L10n.t("live.ephemeral.saved") : L10n.t("live.ephemeral.save"),
                          systemImage: savedTemporary ? "checkmark" : "tray.and.arrow.down")
                }
                // Saving twice made two copies of the same lecture.
                .disabled(savedTemporary || orchestrator.transcript.segments.isEmpty)
            }

            if orchestrator.isImporting {
                Button(role: .destructive) {
                    Task { await appState.stopImport(windowId: windowId) }
                } label: {
                    Label(L10n.t("live.import.cancel"), systemImage: "xmark")
                }
            } else if isLiveWindow && isActive {
                Button(role: .destructive) {
                    appState.stopRecording()
                } label: {
                    Label(L10n.t("live.stop"), systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.recording)
                .keyboardShortcut(".", modifiers: .command)
            } else if isLiveWindow {
                Button {
                    RecordingLauncher.start(appState)
                } label: {
                    Label(L10n.t("live.start"), systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isStartingRecording)
            }
        }
        .controlSize(.regular)
    }

    private var importProgress: some View {
        HStack(spacing: 10) {
            ProgressView(value: orchestrator.importProgress ?? 0)
                .progressViewStyle(.linear)
            Text(importLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var importLabel: String {
        guard orchestrator.importTotal > 0, let f = orchestrator.importProgress else {
            return L10n.t("live.import.preparing")
        }
        return "\(Int(f * 100))%"
    }
}

/// Transcript as it arrives: committed sentences, then the line still being
/// spoken, dimmed.
struct LiveTranscript: View {
    @ObservedObject var buffer: TranscriptBuffer
    var fontSize: Double
    var displayMode: OverlayCaptionDisplayMode
    var engineStatus: String

    var body: some View {
        if buffer.segments.isEmpty && buffer.draftText.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tertiary)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text(L10n.t("live.empty.title")).font(.title3).foregroundStyle(.secondary)
                if !engineStatus.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(engineStatus).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.t("live.empty.subtitle")).font(.callout).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(buffer.segments.sentenceBlocks) { block in
                            LiveSentenceView(block: block, fontSize: fontSize, displayMode: displayMode)
                        }
                        if !buffer.draftText.isEmpty {
                            draft
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: buffer.segments.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: buffer.draftText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: buffer.draftTranslated) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var draft: some View {
        VStack(alignment: .leading, spacing: 6) {
            if displayMode != .translation {
                Text(buffer.draftText)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if displayMode != .original, !buffer.draftTranslated.isEmpty {
                Text(buffer.draftTranslated)
                    .font(.system(size: fontSize * 0.85))
                    .foregroundStyle(Theme.translation.opacity(0.7))
            }
        }
        .lineSpacing(4)
        .textSelection(.enabled)
    }
}

private struct LiveSentenceView: View {
    let block: SentenceBlock<LiveSegment>
    let fontSize: Double
    let displayMode: OverlayCaptionDisplayMode

    private var original: String { SentenceGroups.join(block.lines.map(\.original)) }
    private var translation: String { block.lines.last?.translated ?? "" }
    /// The sentence is still being spoken: its lines so far are committed but
    /// its last line has not arrived, so no translation is coming yet.
    private var isOpen: Bool { block.lines.last?.continuesNext ?? false }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(block.lines[0].startTimeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                if displayMode != .translation {
                    Text(original)
                        .font(.system(size: displayMode == .original ? fontSize : fontSize * 0.9,
                                      weight: displayMode == .original ? .medium : .regular))
                        .foregroundStyle(displayMode == .original ? .primary : .secondary)
                }
                if displayMode != .original {
                    if !translation.isEmpty {
                        Text(translation)
                            .font(.system(size: fontSize, weight: .medium))
                            .foregroundStyle(Theme.translation)
                    } else if !isOpen {
                        TranslationPendingDots()
                    }
                }
            }
            .lineSpacing(4)
            .textSelection(.enabled)
        }
    }
}

/// Three dots that pulse while a translation is on its way.
struct TranslationPendingDots: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.translation)
                    .frame(width: 5, height: 5)
                    .opacity(phase ? 0.9 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: phase)
            }
        }
        .padding(.vertical, 4)
        .onAppear { phase = true }
    }
}
