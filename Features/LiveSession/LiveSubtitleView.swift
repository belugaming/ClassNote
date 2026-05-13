import SwiftUI

struct LiveSubtitleView: View {
    @ObservedObject var buffer: TranscriptBuffer

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(buffer.segments) { seg in
                        SubtitleBubble(segment: seg)
                            .id(seg.rowId)
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: buffer.segments.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct SubtitleBubble: View {
    let segment: LiveSegment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(segment.startTimeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(segment.original)
                    .font(.title3)
                    .textSelection(.enabled)
                if !segment.translated.isEmpty {
                    Text(segment.translated)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("—")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}
