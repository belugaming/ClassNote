import SwiftUI

/// The transcript, one block per sentence: its lines (each one plays the
/// recording from where it starts) and the sentence's translation under them.
struct TranscriptView: View {
    @ObservedObject var vm: SessionDetailViewModel
    @AppStorage("transcriptFontSize", store: AppEnvironment.defaults) private var fontSize: Double = 16
    @AppStorage("transcriptShowTranslation", store: AppEnvironment.defaults) private var showTranslation = true
    @AppStorage("transcriptFollowPlayback", store: AppEnvironment.defaults) private var followPlayback = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let segments = vm.session?.segments, !segments.isEmpty {
                transcript(segments)
            } else {
                EmptyStateView(systemImage: "captions.bubble",
                               title: L10n.t("session.empty.transcript.title"),
                               message: L10n.t("session.empty.transcript.desc"))
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Toggle(isOn: $showTranslation) {
                Label(L10n.t("transcript.showTranslation"), systemImage: "character.bubble")
            }
            .toggleStyle(.checkbox)
            if vm.hasAudio {
                Toggle(isOn: $followPlayback) {
                    Label(L10n.t("transcript.follow"), systemImage: "arrow.down.to.line")
                }
                .toggleStyle(.checkbox)
            }
            Spacer()
            if vm.failedTranslationCount > 0 {
                Label(String(format: L10n.t("transcript.failedCount"), vm.failedTranslationCount),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                    .font(.caption)
            }
            ControlGroup {
                Button {
                    fontSize = max(12, fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help(L10n.t("transcript.smaller"))
                Button {
                    fontSize = min(28, fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help(L10n.t("transcript.larger"))
            }
            .fixedSize()
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func transcript(_ segments: [Segment]) -> some View {
        let blocks = segments.sentenceBlocks
        let highlightStarts = Set(vm.highlights.map(\.timestampMs))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(blocks) { block in
                        SentenceBlockView(block: block,
                                          fontSize: fontSize,
                                          showTranslation: showTranslation,
                                          playingId: vm.playingSegmentId,
                                          flashId: vm.flashSegmentId,
                                          hasHighlight: containsHighlight(block, highlightStarts),
                                          retrying: block.lines.contains { vm.retryingSegmentIds.contains($0.rowKey) },
                                          canSeek: vm.hasAudio && !vm.isSessionRecording,
                                          onSeek: { vm.seek(to: $0.startMs) },
                                          onRetry: { line in Task { await vm.retryTranslation(for: line) } })
                        .id(block.lines[0].rowKey)
                    }
                }
                .frame(maxWidth: Theme.readingWidth, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: vm.pendingScrollSegmentId) { _, _ in consumePendingScroll(proxy, blocks) }
            .onAppear { consumePendingScroll(proxy, blocks) }
            .onChange(of: vm.playingSegmentId) { _, id in
                guard followPlayback, vm.isPlaying, let id,
                      let block = blocks.first(where: { $0.lines.contains { $0.rowKey == id } }) else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(block.lines[0].rowKey, anchor: .center)
                }
            }
        }
    }

    private func containsHighlight(_ block: SentenceBlock<Segment>, _ starts: Set<Int64>) -> Bool {
        guard let first = block.lines.first, let last = block.lines.last else { return false }
        return starts.contains { $0 >= first.startMs && $0 <= last.endMs }
    }

    /// Scrolls to a search hit and flashes it, then clears the request so the
    /// same hit can be opened again.
    private func consumePendingScroll(_ proxy: ScrollViewProxy, _ blocks: [SentenceBlock<Segment>]) {
        guard let id = vm.pendingScrollSegmentId else { return }
        let target = blocks.first { $0.lines.contains { $0.rowKey == id } }?.lines[0].rowKey ?? id
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(target, anchor: .center)
        }
        vm.pendingScrollSegmentId = nil
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if vm.flashSegmentId == id { vm.flashSegmentId = nil }
        }
    }
}

/// One sentence of a saved transcript.
struct SentenceBlockView: View {
    let block: SentenceBlock<Segment>
    var fontSize: Double = 16
    var showTranslation = true
    var playingId: Int64?
    var flashId: Int64?
    var hasHighlight = false
    var retrying = false
    var canSeek = true
    var onSeek: (Segment) -> Void = { _ in }
    var onRetry: (Segment) -> Void = { _ in }

    @State private var hovering = false

    private var last: Segment { block.lines[block.lines.count - 1] }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Button {
                onSeek(block.lines[0])
            } label: {
                Text(TimeLabel.string(ms: block.lines[0].startMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isActive ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSeek)
            .frame(width: 56, alignment: .trailing)
            .help(canSeek ? L10n.t("transcript.playFromHere") : "")

            VStack(alignment: .leading, spacing: 6) {
                original
                if showTranslation { translation }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "star.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
                .opacity(hasHighlight ? 1 : 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                .fill(background)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: isActive)
    }

    private var isActive: Bool {
        block.lines.contains { $0.rowKey == playingId || $0.rowKey == flashId }
    }

    private var background: Color {
        if isActive { return Theme.accentSoft }
        if hovering { return Theme.rowHover }
        return .clear
    }

    /// The sentence's lines as one paragraph. Each line is its own run, so a
    /// click plays from that line, and the one playing is marked.
    private var original: some View {
        let joined = block.lines.enumerated().reduce(Text("")) { text, item in
            let (index, line) = item
            var run = Text(line.textOriginal)
            if line.rowKey == playingId || line.rowKey == flashId {
                run = run.foregroundColor(Theme.accent)
            }
            let separator = index == 0 ? Text("") : Text(needsSpace(before: line, index: index) ? " " : "")
            return text + separator + run
        }
        return joined
            .font(.system(size: fontSize))
            .lineSpacing(3)
            .textSelection(.enabled)
            .contextMenu {
                if canSeek {
                    ForEach(block.lines, id: \.rowKey) { line in
                        Button(String(format: L10n.t("transcript.playFrom"), TimeLabel.string(ms: line.startMs))) {
                            onSeek(line)
                        }
                    }
                }
                Button(L10n.t("transcript.copy")) {
                    Clipboard.copy(([SentenceGroups.join(block.lines.map(\.textOriginal))]
                                    + (last.textTranslated.isEmpty ? [] : [last.textTranslated]))
                        .joined(separator: "\n"))
                }
            }
    }

    private func needsSpace(before line: Segment, index: Int) -> Bool {
        let previous = block.lines[index - 1].textOriginal
        guard let a = previous.unicodeScalars.last, let b = line.textOriginal.unicodeScalars.first else { return false }
        return !(SentenceGroups.isCJK(a) || SentenceGroups.isCJK(b))
    }

    @ViewBuilder
    private var translation: some View {
        if !last.textTranslated.isEmpty {
            Text(last.textTranslated)
                .font(.system(size: max(12, fontSize - 1)))
                .foregroundStyle(Theme.translation)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        if last.translationState == .failed {
            HStack(spacing: 8) {
                Label(L10n.t("session.translation.failed"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                Button {
                    onRetry(last)
                } label: {
                    if retrying {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label(L10n.t("session.translation.retry"), systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(retrying)
            }
        }
    }
}
