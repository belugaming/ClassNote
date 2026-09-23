import SwiftUI
import AppKit

/// Floating always-on-top translation widget. Designed to sit next to a YouTube /
/// video window while you study. Shows the latest 2-3 transcript segments with
/// both original + translation.
struct OverlayView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        InnerOverlayView(appState: appState, orchestrator: appState.orchestrator)
    }
}

private struct InnerOverlayView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var orchestrator: SessionOrchestrator
    @AppStorage("overlayCaptionDisplayMode", store: AppEnvironment.defaults) private var displayModeRaw = OverlayCaptionDisplayMode.bilingual.rawValue
    @AppStorage("overlayCaptionTextSize", store: AppEnvironment.defaults) private var textSizeRaw = OverlayCaptionTextSize.medium.rawValue
    @AppStorage("overlayCaptionRecentCount", store: AppEnvironment.defaults) private var recentCountRaw = OverlayCaptionRecentCount.two.rawValue
    @AppStorage("overlayAlwaysOnTop", store: AppEnvironment.defaults) private var alwaysOnTop: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.15)).padding(.vertical, 6)
            content
                .frame(maxHeight: .infinity)
        }
        .padding(12)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 180, idealHeight: preferredHeight)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.78))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [
                        Color.accentColor.opacity(0.08),
                        Color.clear
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .background(
            OverlayWindowConfigurator(level: alwaysOnTop ? .floating : .normal)
        )
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        // Tracked here, so the toggle is right however the overlay was closed.
        .onAppear { WindowRouter.shared.isOverlayVisible = true }
        .onDisappear { WindowRouter.shared.isOverlayVisible = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.isRecording ? Theme.recording : Color.gray)
                .frame(width: 8, height: 8)
                .scaleEffect(appState.isRecording ? 1.0 : 0.85)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: appState.isRecording)
            Text(appState.isRecording ? L10n.t("live.statusLive") : L10n.t("live.statusIdle"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()

            Menu {
                Picker(L10n.t("overlay.displayMode"), selection: displayModeBinding) {
                    ForEach(OverlayCaptionDisplayMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
            } label: {
                Image(systemName: displayMode.systemImage)
                    .foregroundStyle(.white.opacity(0.74))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .help(L10n.t("overlay.displayMode"))

            Menu {
                Picker(L10n.t("overlay.textSize"), selection: textSizeBinding) {
                    ForEach(OverlayCaptionTextSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                Divider()
                Picker(L10n.t("overlay.recentCount"), selection: recentCountBinding) {
                    ForEach(OverlayCaptionRecentCount.allCases) { count in
                        Text(count.title).tag(count)
                    }
                }
            } label: {
                Image(systemName: "textformat.size")
                    .foregroundStyle(.white.opacity(0.74))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .help(L10n.t("overlay.textSize"))

            Button {
                alwaysOnTop.toggle()
            } label: {
                Image(systemName: alwaysOnTop ? "pin.fill" : "pin")
                    .foregroundStyle(alwaysOnTop ? Theme.accent : .white.opacity(0.62))
            }
            .buttonStyle(.plain)
            .help(alwaysOnTop ? L10n.t("overlay.unpin") : L10n.t("overlay.pin"))

            if !appState.isRecording {
                Button {
                    RecordingLauncher.start(appState)
                } label: {
                    Image(systemName: "record.circle")
                        .foregroundStyle(Theme.recording)
                }
                .buttonStyle(.plain)
                .help(L10n.t("record.start"))
            } else {
                Button {
                    appState.stopRecording()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(Theme.recording)
                }
                .buttonStyle(.plain)
                .help(L10n.t("record.stop"))
            }
            Button {
                WindowRouter.shared.toggleOverlay()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white.opacity(0.7))
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(L10n.t("overlay.close"))
        }
    }

    @ViewBuilder
    private var content: some View {
        // Whole sentences: a line cut mid-sentence has no translation of its
        // own, which used to show as "translating…" forever.
        let segs = Array(orchestrator.transcript.segments.sentenceBlocks.suffix(recentCount.rawValue))
            .map(OverlaySentence.init)
        // The in-progress line, so the overlay fills in as you speak instead of
        // only jumping a whole sentence at a time once one is committed.
        let draft = orchestrator.transcript.draftText
        let draftTranslated = orchestrator.transcript.draftTranslated
        if segs.isEmpty && draft.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("overlay.empty.title"))
                    .foregroundStyle(.white.opacity(0.85))
                    .font(.system(size: textSize.primaryPointSize, weight: .medium))
                // A local engine takes ~30s to load its models (longer on a
                // first run that installs them), so say what it is doing rather
                // than leaving the overlay looking dead.
                if !appState.localEngineStatus.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(appState.localEngineStatus)
                            .foregroundStyle(.white.opacity(0.7))
                            .font(.caption)
                    }
                } else {
                    Text(L10n.t("overlay.empty.tip"))
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.caption)
                }
            }
            .padding(.vertical, 8)
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: displayMode == .bilingual ? 14 : 10) {
                        ForEach(segs) { seg in
                            OverlayCaptionSegmentView(segment: seg,
                                                      displayMode: displayMode,
                                                      textSize: textSize,
                                                      lineLimit: lineLimit)
                            .id(seg.id)
                            .transition(.opacity)
                        }
                        if !draft.isEmpty {
                            OverlayDraftCaptionView(text: draft,
                                                    translated: draftTranslated,
                                                    displayMode: displayMode,
                                                    textSize: textSize,
                                                    lineLimit: lineLimit)
                                .id("overlay-draft")
                                .transition(.opacity)
                        }
                        Color.clear.frame(height: 1).id("overlay-bottom")
                    }
                }
                .onChange(of: orchestrator.transcript.segments.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("overlay-bottom", anchor: .bottom)
                    }
                }
                // Keep the newest text visible while the draft grows, not just
                // when a sentence is committed.
                .onChange(of: draft) { _, _ in
                    proxy.scrollTo("overlay-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var displayMode: OverlayCaptionDisplayMode {
        OverlayCaptionDisplayMode(rawValue: displayModeRaw) ?? .bilingual
    }

    private var textSize: OverlayCaptionTextSize {
        OverlayCaptionTextSize(rawValue: textSizeRaw) ?? .medium
    }

    private var recentCount: OverlayCaptionRecentCount {
        OverlayCaptionRecentCount(rawValue: recentCountRaw) ?? .two
    }

    private var lineLimit: Int {
        displayMode == .bilingual ? 2 : max(2, 5 - recentCount.rawValue)
    }

    private var preferredHeight: CGFloat {
        let rowHeight = displayMode == .bilingual
            ? textSize.primaryPointSize * 1.35 + textSize.secondaryPointSize * 1.3 + 14
            : textSize.primaryPointSize * CGFloat(lineLimit) * 1.25
        return min(max(180, rowHeight * CGFloat(recentCount.rawValue) + 72), 520)
    }

    private var displayModeBinding: Binding<OverlayCaptionDisplayMode> {
        Binding(
            get: { displayMode },
            set: { displayModeRaw = $0.rawValue }
        )
    }

    private var textSizeBinding: Binding<OverlayCaptionTextSize> {
        Binding(
            get: { textSize },
            set: { textSizeRaw = $0.rawValue }
        )
    }

    private var recentCountBinding: Binding<OverlayCaptionRecentCount> {
        Binding(
            get: { recentCount },
            set: { recentCountRaw = $0.rawValue }
        )
    }
}

/// The sentence currently being spoken. Rendered dimmer than committed
/// segments, since a local engine's second pass may still rewrite it.
private struct OverlayDraftCaptionView: View {
    let text: String
    let translated: String
    let displayMode: OverlayCaptionDisplayMode
    let textSize: OverlayCaptionTextSize
    let lineLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if displayMode != .translation {
                draftText(text,
                          pointSize: displayMode == .original
                              ? textSize.primaryPointSize : textSize.secondaryPointSize,
                          color: .white.opacity(0.55))
            }
            if displayMode != .original, !translated.isEmpty {
                draftText(translated,
                          pointSize: textSize.primaryPointSize,
                          color: Theme.translation.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func draftText(_ value: String, pointSize: CGFloat, color: Color) -> some View {
        Text(value.overlayCaptionTail(maxLines: lineLimit))
            .font(.system(size: pointSize, weight: .medium))
            .foregroundStyle(color)
            .lineSpacing(3)
            .lineLimit(lineLimit)
            .truncationMode(.head)
            .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
    }
}

/// A sentence as the overlay shows it.
private struct OverlaySentence: Identifiable {
    let id: Int64
    let original: String
    let translated: String
    let isOpen: Bool

    init(_ block: SentenceBlock<LiveSegment>) {
        id = block.lines[0].rowId
        original = SentenceGroups.join(block.lines.map(\.original))
        translated = block.lines.last?.translated ?? ""
        isOpen = block.lines.last?.continuesNext ?? false
    }
}

private struct OverlayCaptionSegmentView: View {
    let segment: OverlaySentence
    let displayMode: OverlayCaptionDisplayMode
    let textSize: OverlayCaptionTextSize
    let lineLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch displayMode {
            case .original:
                captionText(segment.original,
                            pointSize: textSize.primaryPointSize,
                            weight: .semibold,
                            color: .white,
                            lineLimit: lineLimit)
            case .bilingual:
                captionText(segment.original,
                            pointSize: textSize.secondaryPointSize,
                            weight: .medium,
                            color: .white.opacity(0.72),
                            lineLimit: lineLimit)
                captionText(translationText,
                            pointSize: textSize.primaryPointSize,
                            weight: .semibold,
                            color: Theme.translation,
                            lineLimit: lineLimit)
            case .translation:
                captionText(translationText,
                            pointSize: textSize.primaryPointSize,
                            weight: .semibold,
                            color: Theme.translation,
                            lineLimit: lineLimit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var translationText: String {
        if !segment.translated.isEmpty { return segment.translated }
        return segment.isOpen ? "…" : L10n.t("overlay.translationPending")
    }

    private func captionText(_ text: String,
                             pointSize: CGFloat,
                             weight: Font.Weight,
                             color: Color,
                             lineLimit: Int) -> some View {
        Text(text.overlayCaptionTail(maxLines: lineLimit))
            .font(.system(size: pointSize, weight: weight))
            .foregroundStyle(color)
            .lineSpacing(3)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
            .textSelection(.enabled)
    }
}

/// Applies the overlay's window chrome, and keeps its level in sync.
///
/// This used to be a general-purpose `WindowAccessor` that re-ran a caller
/// closure from `updateNSView` on a `DispatchQueue.main.async` hop. That closure
/// reassigned `level` and re-inserted into `styleMask` on *every* SwiftUI update,
/// and mutating either one re-orders the window with the window server, which
/// cancels any menu that is currently tracking.
///
/// The visible symptom was that the caption text-size menu could be opened but
/// never used: clicking the button re-rendered the view, the deferred write
/// landed a moment later, and the popup closed before an item could be picked.
///
/// So: static chrome is applied exactly once per window, `level` is written only
/// when it actually changes, and nothing is deferred.
struct OverlayWindowConfigurator: NSViewRepresentable {
    let level: NSWindow.Level

    final class Coordinator {
        weak var configured: NSWindow?
        var appliedLevel: NSWindow.Level?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view has no window yet at make time, so this first resolve has to
        // wait a turn. Subsequent updates run synchronously. The hop stays on
        // the main actor — `NSView` and `Coordinator` must not cross out of it.
        let coordinator = context.coordinator
        Task { @MainActor in apply(to: view, coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView, context.coordinator)
    }

    private func apply(to view: NSView, _ coordinator: Coordinator) {
        guard let window = view.window else { return }

        // Keyed on the window itself rather than a Bool, so a rebuilt window
        // (SwiftUI can recreate one) still gets configured.
        if coordinator.configured !== window {
            coordinator.configured = window
            window.isMovableByWindowBackground = true
            window.hasShadow = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }

        if coordinator.appliedLevel != level {
            coordinator.appliedLevel = level
            window.level = level
        }
    }
}
