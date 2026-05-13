import SwiftUI
import LaTeXSwiftUI

/// Block-level Markdown renderer for AI notes.
///
/// SwiftUI's built-in `Text(AttributedString(markdown:))` only handles inline
/// syntax (bold/italic/links/code), so headers, lists, code fences, quotes,
/// tables, and horizontal rules render as raw `#` / `-` / `|` characters.
/// This view parses block structure ourselves and emits styled SwiftUI views,
/// while delegating inline formatting on each line back to AttributedString.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownParser.parse(markdown).enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .padding(.top, level == 1 ? 4 : 2)
                .padding(.bottom, 2)
        case .paragraph(let text):
            inlineText(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.accent)
                        inlineText(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).")
                            .monospacedDigit()
                            .foregroundStyle(Theme.accent)
                        inlineText(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .codeBlock(let code, let lang):
            VStack(alignment: .leading, spacing: 4) {
                if let lang, !lang.isEmpty {
                    Text(lang)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
        case .quote(let text):
            HStack(spacing: 10) {
                Rectangle().fill(Theme.accent.opacity(0.5)).frame(width: 3)
                inlineText(text)
                    .foregroundStyle(.secondary)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let headers, let rows):
            renderTable(headers: headers, rows: rows)
        case .mathBlock(let tex):
            HStack {
                Spacer()
                LaTeX("$$\(tex)$$")
                    .parsingMode(.all)
                    .blockMode(.blockViews)
                    .textSelection(.enabled)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func renderTable(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        VStack(alignment: .leading, spacing: 0) {
            tableRow(cells: headers, columnCount: columnCount, isHeader: true)
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                tableRow(cells: row, columnCount: columnCount, isHeader: false)
                if idx < rows.count - 1 { Divider().opacity(0.4) }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func tableRow(cells: [String], columnCount: Int, isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { i in
                let cell = i < cells.count ? cells[i] : ""
                inlineText(cell)
                    .font(isHeader ? .callout.weight(.semibold) : .callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
    }

    private func inlineText(_ raw: String) -> some View {
        // LaTeX handles `$...$`, `\(...\)`, `$$...$$`, `\[...\]` and passes
        // the rest through its own Markdown-aware text rendering (bold, italic,
        // inline code, links). That covers both math and inline Markdown.
        LaTeX(raw)
            .parsingMode(.all)
            .blockMode(.blockViews)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.weight(.semibold)
        case 2: return .title2.weight(.semibold)
        case 3: return .title3.weight(.semibold)
        case 4: return .headline
        case 5: return .subheadline.weight(.semibold)
        default: return .body.weight(.semibold)
        }
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case orderedList([String])
    case codeBlock(code: String, language: String?)
    case quote(String)
    case rule
    case table(headers: [String], rows: [[String]])
    case mathBlock(String)
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        // Normalize line endings; keep blank lines as paragraph separators.
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Display math block: $$ ... $$ (may be single-line or multi-line).
            // Strip the fences and pass the body to the LaTeX renderer.
            if trimmed.hasPrefix("$$") {
                let firstBody = String(trimmed.dropFirst(2))
                if let closeIdx = firstBody.range(of: "$$") {
                    // Single-line: $$ ... $$
                    let tex = String(firstBody[firstBody.startIndex..<closeIdx.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    blocks.append(.mathBlock(tex))
                    i += 1
                    continue
                } else {
                    // Multi-line: collect until a line containing "$$".
                    var body: [String] = []
                    if !firstBody.trimmingCharacters(in: .whitespaces).isEmpty {
                        body.append(firstBody)
                    }
                    i += 1
                    while i < lines.count {
                        let l = lines[i]
                        if let r = l.range(of: "$$") {
                            let pre = String(l[l.startIndex..<r.lowerBound])
                            if !pre.trimmingCharacters(in: .whitespaces).isEmpty {
                                body.append(pre)
                            }
                            i += 1
                            break
                        }
                        body.append(l)
                        i += 1
                    }
                    let tex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    blocks.append(.mathBlock(tex))
                    continue
                }
            }

            // Fenced code block: ``` or ~~~
            if let fence = codeFence(trimmed) {
                var lang: String? = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                if lang?.isEmpty == true { lang = nil }
                i += 1
                var body: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix(fence) { i += 1; break }
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(code: body.joined(separator: "\n"), language: lang))
                continue
            }

            // ATX heading: # ... up to ######
            if let h = atxHeading(trimmed) {
                blocks.append(.heading(level: h.level, text: h.text))
                i += 1
                continue
            }

            // Horizontal rule: ---, ***, ___ (>=3 chars, possibly spaced)
            if isHorizontalRule(trimmed) {
                blocks.append(.rule)
                i += 1
                continue
            }

            // Blockquote (consecutive `>` lines)
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if !t.hasPrefix(">") { break }
                    var s = String(t.dropFirst())
                    if s.hasPrefix(" ") { s.removeFirst() }
                    quoted.append(s)
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: " ")))
                continue
            }

            // Table: header line containing `|`, next line is separator with `---`
            if line.contains("|"),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1]) {
                let headers = splitTableRow(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let row = lines[i]
                    if row.trimmingCharacters(in: .whitespaces).isEmpty || !row.contains("|") {
                        break
                    }
                    rows.append(splitTableRow(row))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // Bullet list: lines starting with -, *, +
            if isBullet(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if !isBullet(t) { break }
                    items.append(stripBullet(t))
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Ordered list: 1. item, 2. item, …
            if isOrdered(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if !isOrdered(t) { break }
                    items.append(stripOrdered(t))
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Setext heading: next line is === or ---
            if i + 1 < lines.count {
                let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if !next.isEmpty, next.allSatisfy({ $0 == "=" }) {
                    blocks.append(.heading(level: 1, text: trimmed))
                    i += 2
                    continue
                }
                if !next.isEmpty, next.allSatisfy({ $0 == "-" }), next.count >= 2 {
                    blocks.append(.heading(level: 2, text: trimmed))
                    i += 2
                    continue
                }
            }

            // Paragraph: collect consecutive non-empty non-special lines.
            var paragraph: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("$$") { break }
                if atxHeading(t) != nil { break }
                if codeFence(t) != nil { break }
                if isHorizontalRule(t) { break }
                if t.hasPrefix(">") { break }
                if isBullet(t) || isOrdered(t) { break }
                paragraph.append(t)
                i += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
        }
        return blocks
    }

    private static func codeFence(_ s: String) -> String? {
        if s.hasPrefix("```") { return "```" }
        if s.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func atxHeading(_ s: String) -> (level: Int, text: String)? {
        guard s.hasPrefix("#") else { return nil }
        var level = 0
        for c in s {
            if c == "#" { level += 1 } else { break }
            if level > 6 { return nil }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = s.dropFirst(level)
        guard rest.first == " " || rest.isEmpty else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func isHorizontalRule(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        let c = stripped.first!
        guard c == "-" || c == "*" || c == "_" else { return false }
        return stripped.allSatisfy { $0 == c }
    }

    private static func isBullet(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        guard first == "-" || first == "*" || first == "+" else { return false }
        return s.count >= 2 && s.dropFirst().first == " "
    }

    private static func stripBullet(_ s: String) -> String {
        String(s.dropFirst(2))
    }

    private static func isOrdered(_ s: String) -> Bool {
        var idx = s.startIndex
        var sawDigit = false
        while idx < s.endIndex, s[idx].isNumber {
            sawDigit = true
            idx = s.index(after: idx)
        }
        guard sawDigit, idx < s.endIndex else { return false }
        if s[idx] != "." && s[idx] != ")" { return false }
        let after = s.index(after: idx)
        return after < s.endIndex && s[after] == " "
    }

    private static func stripOrdered(_ s: String) -> String {
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isNumber {
            idx = s.index(after: idx)
        }
        // skip "." or ")" + space
        if idx < s.endIndex { idx = s.index(after: idx) }
        if idx < s.endIndex { idx = s.index(after: idx) }
        return String(s[idx...])
    }

    private static func isTableSeparator(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix("-") else { return false }
        let allowed: Set<Character> = ["|", "-", ":", " "]
        return !t.isEmpty && t.allSatisfy { allowed.contains($0) }
    }

    private static func splitTableRow(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
