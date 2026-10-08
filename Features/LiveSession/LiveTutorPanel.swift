import SwiftUI

/// The AI tutor beside the live transcript: explains what the lecturer just
/// said while the lecture is still going, and answers questions about it.
struct LiveTutorPanel: View {
    @ObservedObject var tutor: LiveTutor
    @State private var question = ""

    private var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            notices
            cardList
            Divider()
            askField
        }
        .frame(maxHeight: .infinity)
        .background(Theme.windowBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(L10n.t("liveTutor.title"), systemImage: "sparkles")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 6)
            Picker("", selection: $tutor.pace) {
                ForEach(LiveTutorPace.allCases) { pace in
                    Text(L10n.t(pace.titleKey)).tag(pace)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help(L10n.t("liveTutor.pace.help"))
            Button {
                tutor.explainNow()
            } label: {
                Label(L10n.t("liveTutor.explainNow"), systemImage: "wand.and.stars")
            }
            .disabled(!tutor.hasTranscript || tutor.isMissingCredential)
            .help(L10n.t("liveTutor.explainNow.help"))
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var notices: some View {
        if tutor.isMissingCredential {
            notice(L10n.t("liveTutor.notice.missingKey"), systemImage: "key")
        } else if let paused = tutor.autoPausedMessage {
            VStack(alignment: .leading, spacing: 6) {
                notice(L10n.t("liveTutor.notice.paused") + " " + paused,
                       systemImage: "pause.circle")
                Button(L10n.t("liveTutor.notice.resume")) { tutor.resumeAutomatic() }
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        } else if tutor.usesLocalModel, ProcessInfo.processInfo.physicalMemory < 32 * 1_073_741_824 {
            notice(L10n.t("liveTutor.notice.localMemory"), systemImage: "memorychip")
        }
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(Theme.warning)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    private var cardList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if tutor.cards.isEmpty {
                        emptyState
                    }
                    ForEach(tutor.cards) { card in
                        LiveTutorCardView(card: card,
                                          canSave: tutor.canSave,
                                          onSave: { tutor.save(card.id) },
                                          onRetry: { tutor.retry(card.id) })
                            .equatable()
                    }
                    Color.clear.frame(height: 1).id("tutorBottom")
                }
                .padding(14)
            }
            .onChange(of: tutor.cards.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("tutorBottom", anchor: .bottom) }
            }
            .onChange(of: tutor.cards.last?.markdown) { _, _ in
                proxy.scrollTo("tutorBottom", anchor: .bottom)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L10n.t(tutor.isLive ? "liveTutor.empty.listening" : "liveTutor.empty.title"))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(L10n.t(tutor.pace == .off ? "liveTutor.empty.manual" : "liveTutor.empty.auto"))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if tutor.usesLocalModel {
                Text(L10n.t("liveTutor.empty.local"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var askField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(L10n.t("liveTutor.ask.placeholder"), text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(trimmedQuestion.isEmpty ? Color.secondary : Theme.accent)
            .disabled(trimmedQuestion.isEmpty || tutor.isMissingCredential)
            .help(L10n.t("liveTutor.ask.send"))
        }
        .padding(12)
    }

    private func submit() {
        guard !trimmedQuestion.isEmpty, !tutor.isMissingCredential else { return }
        tutor.ask(trimmedQuestion)
        question = ""
    }
}

/// One explanation or answer. Equatable so the cards above the one still
/// streaming are not re-parsed on every delta.
private struct LiveTutorCardView: View, Equatable {
    let card: LiveTutorCard
    let canSave: Bool
    let onSave: () -> Void
    let onRetry: () -> Void

    nonisolated static func == (lhs: LiveTutorCardView, rhs: LiveTutorCardView) -> Bool {
        lhs.card == rhs.card && lhs.canSave == rhs.canSave
    }

    private var icon: String {
        switch card.kind {
        case .auto: return "sparkles"
        case .manual: return "wand.and.stars"
        case .question: return "questionmark.bubble"
        }
    }

    private var timeLabel: String {
        let start = TimeLabel.string(ms: card.startMs)
        guard card.endMs > card.startMs else { return start }
        return "\(start)–\(TimeLabel.string(ms: card.endMs))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(Theme.accent)
                Text(timeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                actions
            }
            .font(.caption)
            if let asked = card.question {
                Text(asked)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    @ViewBuilder
    private var actions: some View {
        if card.isStreaming {
            ProgressView().controlSize(.mini)
        } else if card.errorMessage != nil {
            Button(action: onRetry) {
                Label(L10n.t("liveTutor.card.retry"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        } else {
            Button {
                Clipboard.copy(card.question.map { "\($0)\n\n\(card.markdown)" } ?? card.markdown)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("liveTutor.card.copy"))
            if canSave {
                Button(action: onSave) {
                    Image(systemName: card.isSaved ? "star.fill" : "star")
                        .foregroundStyle(card.isSaved ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(card.isSaved)
                .help(L10n.t(card.isSaved ? "liveTutor.card.saved" : "liveTutor.card.save"))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = card.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if card.isStreaming && card.markdown.isEmpty {
            Text(L10n.t("liveTutor.card.thinking"))
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            RichMarkdownView(markdown: card.markdown, streaming: card.isStreaming)
        }
    }
}
