import SwiftUI
import MarkdownView

/// Every piece of Markdown the app shows (notes, Q&A, study tools, highlight
/// explanations, live tutor cards), rendered by the MarkdownView package:
/// CommonMark + GFM through swift-markdown, nested lists, GitHub-style tables
/// and quotes, syntax-highlighted code, and LaTeX through SwiftMath, where a
/// `$` followed by a digit does not close a formula, so prices stay text.
///
/// `streaming` is for text a model is still writing. It goes through the
/// package's streaming reader, which parses incrementally off the main thread
/// and coalesces updates, so a long set of notes is not re-parsed whole on
/// every token.
struct RichMarkdownView: View {
    let markdown: String
    var streaming = false

    var body: some View {
        RichMarkdownBody(markdown: markdown, streaming: streaming)
            // The views around it re-render often (a recording's segment
            // refresh, the playhead); the document only when its text does.
            .equatable()
            .markdownMathRenderingEnabled()
            .markdownTableStyle(.github)
            .markdownBlockQuoteStyle(.github)
    }
}

private struct RichMarkdownBody: View, Equatable {
    let markdown: String
    let streaming: Bool

    nonisolated static func == (lhs: RichMarkdownBody, rhs: RichMarkdownBody) -> Bool {
        lhs.markdown == rhs.markdown && lhs.streaming == rhs.streaming
    }

    var body: some View {
        if streaming {
            StreamingRichMarkdown(markdown: markdown)
        } else {
            MarkdownView(markdown)
        }
    }
}

/// Text still being written. A display formula that has not closed yet is held
/// back as plain source until its closing `$$` arrives, rather than showing up
/// as raw `$$` in the middle of the rendered text and then jumping.
private struct StreamingRichMarkdown: View {
    let markdown: String
    @State private var source = StreamingMarkdownSource()

    var body: some View {
        let parts = MarkdownStreamingSplit.split(markdown)
        VStack(alignment: .leading, spacing: 8) {
            StreamingMarkdownReader(source) { result in
                MarkdownView(result)
            }
            if !parts.pending.isEmpty {
                Text(parts.pending)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { source.text = parts.settled }
        .onChange(of: parts.settled) { _, settled in source.text = settled }
    }
}

/// Splits text a model is still writing into what can be rendered now and a
/// display formula that has not closed yet.
enum MarkdownStreamingSplit {
    static func split(_ markdown: String) -> (settled: String, pending: String) {
        let fences = markdown.components(separatedBy: "$$").count - 1
        guard fences % 2 == 1, let open = markdown.range(of: "$$", options: .backwards) else {
            return (markdown, "")
        }
        return (String(markdown[..<open.lowerBound]), String(markdown[open.lowerBound...]))
    }
}

/// The model's reasoning summary while it works, before the answer starts, so
/// a long think does not look like a hang. Only the tail is shown: the
/// summary runs long, and only where the model is now is worth reading.
struct ThinkingPreview: View {
    let text: String

    private static let maxChars = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("llm.thinking")).font(.callout.weight(.medium))
            }
            .foregroundStyle(.secondary)
            if !tail.isEmpty {
                Text(Self.inlineMarkdown(tail))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The last `maxChars` characters, starting at a word boundary.
    private var tail: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > Self.maxChars else { return trimmed }
        let cut = trimmed.suffix(Self.maxChars)
        guard let boundary = cut.firstIndex(where: { $0 == " " || $0 == "\n" }) else {
            return "…" + String(cut)
        }
        return "…" + String(cut[cut.index(after: boundary)...])
    }

    /// A summary is prose with the odd bold phrase, and its tail starts
    /// mid-document, so inline formatting is all it gets; line breaks are kept.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

#if DEBUG
/// A note in the shape the app's models write: Chinese prose with inline math
/// next to bold text, a price that is not math, a nested list, a display
/// formula, a table, a quote and a code block.
private enum RichMarkdownPreviewSample {
    static let markdown = #"""
    ## 压缩器（Compressor）

    **正在讲**：老师在讲**压缩器**怎么控制音量的动态范围，接着上节课的 *EQ*。

    **关键概念**
    - **Threshold**（阈值）— 音量超过这条线，压缩器才开始工作。
    - **Ratio**（压缩比）— 超过阈值的部分被压多少，比如 4:1：
      - 超出 8 dB → 只剩 2 dB
      - 超出 4 dB → 只剩 1 dB
    - **Attack / Release**（启动 / 释放时间）— 压缩多快开始、多快松开。

    **帮你理解**：分贝和振幅的关系是 $L = 20\log_{10}(A/A_0)$，所以振幅翻倍约等于多 **6 dB**。插件从 $5 涨到 $10 这种价格不会被当成公式。

    $$
    L_{out} = T + \frac{L_{in} - T}{R}
    $$

    | 参数 | 常见取值 | 听感 |
    |---|---|---|
    | Ratio | 2:1 – 4:1 | 自然 |
    | Ratio | 10:1 以上 | 接近限制器 |

    > 老师原话：“Don't over-compress the vocals.”

    ```python
    gain_db = threshold + (level_db - threshold) / ratio
    ```
    """#
}

#Preview("Markdown rendering") {
    ScrollView {
        RichMarkdownView(markdown: RichMarkdownPreviewSample.markdown)
            .textSelection(.enabled)
            .frame(maxWidth: Theme.readingWidth, alignment: .leading)
            .padding(24)
    }
    .frame(width: 720, height: 760)
}
#endif
