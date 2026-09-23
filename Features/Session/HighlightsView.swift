import SwiftUI

/// The moments bookmarked while recording, each with the lines around it and
/// an AI explanation on request.
struct HighlightsView: View {
    @ObservedObject var vm: SessionDetailViewModel

    var body: some View {
        if vm.highlights.isEmpty {
            EmptyStateView(systemImage: "star",
                           title: L10n.t("session.empty.highlights.title"),
                           message: L10n.t("highlights.empty.desc"))
        } else {
            HStack(spacing: 0) {
                List(selection: Binding(get: { vm.selectedHighlightId },
                                        set: { vm.selectHighlight($0) })) {
                    ForEach(vm.highlights) { h in
                        HighlightRow(highlight: h)
                            .tag(h.id ?? -1)
                            .contextMenu {
                                Button(L10n.t("common.delete"), role: .destructive) {
                                    Task { await vm.deleteHighlight(h) }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 240)
                Divider()
                HighlightDetail(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear {
                if vm.selectedHighlightId == nil { vm.selectHighlight(vm.highlights.first?.id) }
            }
        }
    }
}

private struct HighlightRow: View {
    let highlight: Highlight

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(TimeLabel.string(ms: highlight.timestampMs)).font(.callout.monospacedDigit().weight(.medium))
                if !highlight.userNote.isEmpty {
                    Text(highlight.userNote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if highlight.explanationMd != nil {
                    Text(L10n.t("highlights.explained")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct HighlightDetail: View {
    @ObservedObject var vm: SessionDetailViewModel
    @State private var noteDraft = ""

    var body: some View {
        if let h = vm.selectedHighlight {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(h)
                    TextField(L10n.t("highlights.notePlaceholder"), text: $noteDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .onSubmit { Task { await vm.setHighlightNote(h, note: noteDraft) } }
                    context(h)
                    presets(h)
                    explanation(h)
                }
                .frame(maxWidth: Theme.readingWidth, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .id(h.id)
            .onAppear { noteDraft = h.userNote }
            .onChange(of: vm.selectedHighlightId) { _, _ in noteDraft = vm.selectedHighlight?.userNote ?? "" }
            .onDisappear {
                if noteDraft != h.userNote { Task { await vm.setHighlightNote(h, note: noteDraft) } }
            }
        } else {
            EmptyStateView(systemImage: "star", title: L10n.t("highlight.detail.empty"))
        }
    }

    private func header(_ h: Highlight) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(TimeLabel.string(ms: h.timestampMs))
                .font(.title2.monospacedDigit().weight(.semibold))
            if let range = currentRange(h) {
                Text("\(TimeLabel.string(ms: range.start)) – \(TimeLabel.string(ms: range.end))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ControlGroup {
                Button {
                    vm.shrinkRange(h)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help(L10n.t("highlight.detail.shrinkRange"))
                Button {
                    vm.expandRange(h)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help(L10n.t("highlight.detail.expandRange"))
            }
            .fixedSize()
            .disabled(!vm.canAdjustRange(h))
            if vm.hasAudio {
                Button {
                    vm.seek(to: currentRange(h)?.start ?? h.timestampMs)
                } label: {
                    Label(L10n.t("session.action.play"), systemImage: "play.fill")
                }
            }
            Button(role: .destructive) {
                Task { await vm.deleteHighlight(h) }
            } label: {
                Image(systemName: "trash")
            }
            .help(L10n.t("common.delete"))
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func context(_ h: Highlight) -> some View {
        let lines = vm.segmentsForRange(h)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("highlight.detail.rangePreview"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(lines.sentenceBlocks) { block in
                    SentenceBlockView(block: block, fontSize: 14, canSeek: vm.hasAudio,
                                      onSeek: { vm.seek(to: $0.startMs) })
                }
            }
            .padding(10)
            .cardBackground()
        }
    }

    @ViewBuilder
    private func presets(_ h: Highlight) -> some View {
        if vm.session?.segments.isEmpty == true {
            Label(L10n.t("highlight.error.noSegments"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.warning)
        } else {
            HStack(spacing: 8) {
                ForEach(HighlightPrompts.all) { preset in
                    Button(L10n.t(preset.labelKey)) {
                        Task { await vm.runPreset(preset, on: h) }
                    }
                    .buttonStyle(.bordered)
                    .tint(h.explanationPrompt == preset.key ? Theme.accent : nil)
                }
                Spacer()
                if h.explanationPrompt != nil {
                    Button {
                        Task { await vm.regenerate(h) }
                    } label: {
                        Label(L10n.t("highlight.action.regenerate"), systemImage: "arrow.clockwise")
                    }
                    Button {
                        Task { await vm.clearExplanation(h) }
                    } label: {
                        Label(L10n.t("highlight.action.clear"), systemImage: "xmark")
                    }
                }
            }
            .controlSize(.small)
            .disabled(vm.streamingHighlightId != nil)
        }
    }

    @ViewBuilder
    private func explanation(_ h: Highlight) -> some View {
        if vm.streamingHighlightId == h.id {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView().controlSize(.small)
                StreamingMarkdownPreview(markdown: vm.streamingBuffer).textSelection(.enabled)
            }
        } else if let md = h.explanationMd, !md.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownView(markdown: md).textSelection(.enabled)
                if let footer = footer(h) {
                    Text(footer).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } else {
            Text(L10n.t("highlight.detail.pickPreset"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func footer(_ h: Highlight) -> String? {
        guard let model = h.explanationModel, let key = h.explanationPrompt,
              let ts = h.explanationGeneratedAt else { return nil }
        let preset = HighlightPrompts.find(key: key).map { L10n.t($0.labelKey) } ?? key
        return "\(model) · \(DateLabels.dateTime(Date(timeIntervalSince1970: TimeInterval(ts) / 1000))) · \(preset)"
    }

    private func currentRange(_ h: Highlight) -> (start: Int64, end: Int64)? {
        if let s = h.rangeStartMs, let e = h.rangeEndMs { return (s, e) }
        return vm.previewRange(for: h)
    }
}
