import SwiftUI

struct LiveSubtitleView: View {
    @ObservedObject var buffer: TranscriptBuffer

    var body: some View {
        if buffer.segments.isEmpty {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 54))
                    .foregroundStyle(Theme.accent.opacity(0.6))
                Text(L10n.t("live.empty.title"))
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(L10n.t("live.empty.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(buffer.segments) { seg in
                            SubtitleBubble(segment: seg)
                                .id(seg.rowId)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        if !buffer.draftText.isEmpty {
                            DraftSubtitleBubble(text: buffer.draftText, translated: buffer.draftTranslated)
                                .id("live-draft")
                        }
                        Color.clear.frame(height: 12).id("live-bottom")
                    }
                    .padding(16)
                    .animation(.easeOut(duration: 0.2), value: buffer.segments.count)
                }
                .onChange(of: buffer.segments.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("live-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: buffer.draftText) { _, _ in
                    proxy.scrollTo("live-bottom", anchor: .bottom)
                }
            }
        }
    }
}

struct SubtitleBubble: View {
    let segment: LiveSegment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(segment.startTimeLabel)
                .font(.caption.monospacedDigit().weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.accentSoft))
                .foregroundStyle(Theme.accent)
                .frame(width: 68, alignment: .leading)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(segment.original)
                    .font(.title3)
                    .textSelection(.enabled)
                if !segment.translated.isEmpty {
                    Text(segment.translated)
                        .font(.body)
                        .foregroundStyle(Theme.translation)
                        .textSelection(.enabled)
                } else {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { i in
                            Circle()
                                .fill(Theme.translation.opacity(0.6))
                                .frame(width: 5, height: 5)
                                .scaleEffect(1.0)
                                .opacity(0.6)
                                .animation(
                                    .easeInOut(duration: 0.8)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(i) * 0.15),
                                    value: segment.translated.isEmpty
                                )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Spacer()
        }
        .padding(12)
        .cardBackground(radius: Theme.cornerMedium)
    }
}

/// The sentence currently being spoken, before the STT engine has committed
/// it as final. Only ever populated by backends that report volatile
/// results (on-device Apple STT) — dimmed/italic to read as "still typing".
struct DraftSubtitleBubble: View {
    let text: String
    let translated: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear
                .frame(width: 68, height: 1)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.title3.italic())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !translated.isEmpty {
                    Text(translated)
                        .font(.body.italic())
                        .foregroundStyle(Theme.translation.opacity(0.7))
                        .textSelection(.enabled)
                }
            }

            Spacer()
        }
        .padding(12)
    }
}
