import SwiftUI
import MarkdownRendering

/// Every piece of Markdown the app shows (notes, Q&A, study tools, highlight
/// explanations, live tutor cards), rendered by the MarkdownView package:
/// CommonMark + GFM through swift-markdown, nested lists, tables and quotes
/// drawn in the app's own colors, syntax-highlighted code, and LaTeX through
/// SwiftMath, where a `$` followed by a digit does not close a formula, so
/// prices stay text.
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
            .markdownTableStyle(ClassNoteTableStyle())
            .markdownBlockQuoteStyle(ClassNoteBlockQuoteStyle())
            // The package sets quotes in a serif face, which in Chinese reads
            // as a different document pasted in.
            .font(NSFont.preferredFont(forTextStyle: .body), for: .blockQuote)
    }
}

/// Tables in the colors of the text around them. The package's GitHub style
/// paints GitHub's own near-black and white behind every row, which stands
/// out against the app's grey surfaces; here the rows have no fill, so a table
/// sits on whatever the text sits on (the window, a card), with a faint header
/// and the system separator between rows.
struct ClassNoteTableStyle: MarkdownTableStyle {
    func makeBody(configuration: Configuration) -> some View {
        ClassNoteTable(configuration: configuration)
    }
}

private struct ClassNoteTable: View {
    let configuration: MarkdownTableStyleConfiguration

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            configuration.table.header
                .markdownTableRowBackgroundStyle(Theme.chrome)
            ForEach(Array(configuration.table.rows.enumerated()), id: \.offset) { _, row in
                Divider()
                row
            }
        }
        .markdownTableCellPadding(.vertical, 6)
        .markdownTableCellPadding(.horizontal, 12)
        .overlay {
            Rectangle().strokeBorder(Theme.separator)
        }
    }
}

/// A quote as a bar beside text in the body face, a step quieter than the
/// text around it.
struct ClassNoteBlockQuoteStyle: MarkdownBlockQuoteStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.quoteBar).frame(width: 3)
            }
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

/// A long finished document (notes, a study tool's output), rendered one
/// top-level block at a time in a lazy stack.
///
/// One `MarkdownView` over a whole set of notes lays out every block at once:
/// consecutive paragraphs become a single tall `Text`, and every formula is its
/// own AppKit view (SwiftMath), so scrolling drags all of it along. Here only
/// the blocks near the screen exist. A selection no longer runs across blocks,
/// which the notes' Copy button covers.
struct RichMarkdownDocument: View {
    let markdown: String

    var body: some View {
        RichMarkdownDocumentBody(markdown: markdown)
            .equatable()
    }
}

private struct RichMarkdownDocumentBody: View, Equatable {
    let markdown: String

    nonisolated static func == (lhs: RichMarkdownDocumentBody, rhs: RichMarkdownDocumentBody) -> Bool {
        lhs.markdown == rhs.markdown
    }

    var body: some View {
        let blocks = MarkdownBlocks.split(markdown)
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { index in
                RichMarkdownView(markdown: blocks[index])
            }
        }
    }
}

/// Splits Markdown into top-level blocks that each render the same on their
/// own as they do in the whole document. A split is made only at a blank line
/// followed by an unindented line, outside a code fence and outside an open
/// `$$` display formula, so an indented list continuation, a fenced block with
/// blank lines in it and a multi-line formula all stay whole. A list is never
/// split between its items either: MarkdownView numbers every ordered list
/// from 1, whatever number it starts at.
enum MarkdownBlocks {
    static func split(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring] = []
        var fence: Substring?
        var openDisplayMath = false
        var sawBlankLine = false
        var inList = false

        func flush() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(text) }
            current.removeAll()
            inList = false
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                current.append(line)
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sawBlankLine = true
                current.append(line)
                continue
            }
            let indented = line.first == " " || line.first == "\t"
            let listItem = !indented && isListItem(line)
            if sawBlankLine, !indented, !openDisplayMath, !(inList && listItem), !current.isEmpty {
                flush()
            }
            sawBlankLine = false
            current.append(line)
            if listItem { inList = true }
            if line.prefix(while: { $0 == " " }).count <= 3,
               let marker = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                fence = Substring(marker)
            } else if line.components(separatedBy: "$$").count % 2 == 0 {
                openDisplayMath.toggle()
            }
        }
        flush()
        return blocks
    }

    /// `- item`, `* item`, `+ item`, `1. item` or `1) item`.
    private static func isListItem(_ line: Substring) -> Bool {
        if let first = line.first, "-*+".contains(first) {
            let rest = line.dropFirst()
            return rest.isEmpty || rest.first == " " || rest.first == "\t"
        }
        let digits = line.prefix(while: \.isASCII).prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9 else { return false }
        let rest = line.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return false }
        let after = rest.dropFirst()
        return after.isEmpty || after.first == " " || after.first == "\t"
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
