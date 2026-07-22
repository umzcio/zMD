import Foundation

/// Unified markdown parser used by ExportManager (export) and MarkdownTextView (rendering)
/// This is the single source of truth for markdown parsing in zMD
class MarkdownParser {
    static let shared = MarkdownParser()

    private init() {}

    /// C7: Single source of truth for inline-math detection, shared by the preview renderer
    /// (MarkdownTextView), the exporters (ExportManager), and the HTML script-injection check
    /// (toHTML). Pandoc-style restrictions:
    ///   - opening `$` not preceded by `$` (so `$$` is display math), not followed by `$`, a space,
    ///     or a digit (so `$1`, `$10.50` are money, not math openers);
    ///   - content cannot cross an interior `$` (`[^\n$]`) and is capped at 200 chars to bound
    ///     runaway lazy matches;
    ///   - closing `$` not preceded by space, not followed by `$` or a digit.
    /// Capture group 1 is the LaTeX body. Previously three divergent copies disagreed (`[^\n]` vs
    /// `[^\n$]`, and a loose `.+?` with no digit guard) so preview and export classified the same
    /// text differently.
    static let inlineMathPattern = #"(?<!\$)\$(?!\$)(?! )(?![0-9])([^\n$]{1,200}?)(?<! )\$(?!\$)(?![0-9])"#

    // MARK: - Element Types

    enum Element: Identifiable {
        case heading1(String)
        case heading2(String)
        case heading3(String)
        case heading4(String)
        case heading5(String)
        case heading6(String)
        case paragraph(String)
        case frontmatter(lines: [String])
        case list(items: [(level: Int, text: String, isOrdered: Bool, startNumber: Int?)])
        case codeBlock(code: String, language: String?)
        case mermaidBlock(code: String)
        case displayMath(latex: String)
        case table(rows: [[String]])
        case image(alt: String, path: String)
        case horizontalRule
        case blockquote(String)
        case htmlBlock(String)

        /// Content-addressed identity used as the element cache key.
        /// MUST be collision-free across distinct content: MarkdownTextView caches NSAttributedString
        /// by this key, so a collision would render one element's visuals in place of another's.
        /// `String.hashValue` is 64-bit and randomized per-process — it was replaced with raw content
        /// to eliminate birthday-collision risk on large documents.
        var id: String {
            let unit = "\u{1F}" // separator between composite fields
            switch self {
            case .heading1(let text): return "h1\(unit)\(text)"
            case .heading2(let text): return "h2\(unit)\(text)"
            case .heading3(let text): return "h3\(unit)\(text)"
            case .heading4(let text): return "h4\(unit)\(text)"
            case .heading5(let text): return "h5\(unit)\(text)"
            case .heading6(let text): return "h6\(unit)\(text)"
            case .paragraph(let text): return "p\(unit)\(text)"
            case .frontmatter(let lines): return "fm\(unit)\(lines.joined(separator: "\n"))"
            case .list(let items):
                let joined = items.map { "\($0.level)\(unit)\($0.isOrdered ? "1" : "0")\(unit)\($0.startNumber.map(String.init) ?? "")\(unit)\($0.text)" }.joined(separator: "\u{1E}")
                return "list\(unit)\(joined)"
            case .codeBlock(let code, let lang): return "code\(unit)\(lang ?? "")\(unit)\(code)"
            case .mermaidBlock(let code): return "mermaid\(unit)\(code)"
            case .displayMath(let latex): return "math\(unit)\(latex)"
            case .table(let rows): return "table\(unit)\(rows.map { $0.joined(separator: "\u{1D}") }.joined(separator: "\u{1E}"))"
            case .image(let alt, let path): return "img\(unit)\(alt)\(unit)\(path)"
            case .horizontalRule: return "hr"
            case .blockquote(let text): return "quote\(unit)\(text)"
            case .htmlBlock(let html): return "html\(unit)\(html)"
            }
        }

        var isHeading: Bool {
            switch self {
            case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Parsing

    /// C1: Split into lines after normalizing CRLF/CR to LF. `CharacterSet.newlines` splits on `\r`
    /// and `\n` individually, so every CRLF pair yields a phantom empty line — which shatters
    /// tables (each row becomes a one-row table styled as a header), lists (flush per item),
    /// blockquotes (split per line) and code blocks (double-spaced) in any Windows-authored file.
    private func splitLines(_ markdown: String) -> [String] {
        return markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Parse markdown string into array of elements
    func parse(_ markdown: String) -> [Element] {
        var elements: [Element] = []
        let lines = splitLines(markdown)
        var i = 0
        var listItems: [(level: Int, text: String, isOrdered: Bool, startNumber: Int?)] = []
        var paragraphLines: [String] = []

        // Check for YAML frontmatter at start of document. Trim trailing whitespace on the
        // delimiter so a stray space after `---` doesn't defeat detection (L6).
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var frontmatterLines: [String] = []
            i = 1
            while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "---" {
                frontmatterLines.append(lines[i])
                i += 1
            }
            if i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                elements.append(.frontmatter(lines: frontmatterLines))
                i += 1
            } else {
                // Incomplete frontmatter, treat as regular content
                i = 0
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // End list if we hit a non-list item
            if !isListLine(line) && !listItems.isEmpty {
                elements.append(.list(items: listItems))
                listItems = []
            }

            // Flush accumulated paragraph if we hit a block-level element
            // C4: use trimmedLine for the heading/blockquote checks so they match the block
            // branches below (which test trimmedLine). With `line`, an indented "  ## H" or a
            // space-less ">quote" was treated as plain text, so the buffered paragraph was not
            // flushed and the heading/blockquote was emitted ABOVE the text that preceded it.
            let isPlainText = !line.isEmpty && !trimmedLine.isEmpty
                && !trimmedLine.hasPrefix("#")
                && !trimmedLine.hasPrefix("|")
                && !trimmedLine.hasPrefix(">")
                && !isListLine(line)
                && !trimmedLine.hasPrefix("```")
                && !isHorizontalRule(line)
                && !isHTMLLine(line)
                && trimmedLine != "$$"
                && !(trimmedLine.hasPrefix("$$") && trimmedLine.hasSuffix("$$") && trimmedLine.count > 4)
                && trimmedLine.range(of: #"^!\[([^\]]*)\]\(([^\)]+)\)$"#, options: .regularExpression) == nil
            if !isPlainText && !paragraphLines.isEmpty {
                elements.append(.paragraph(paragraphLines.joined(separator: " ")))
                paragraphLines = []
            }

            // Horizontal rule (---, ___, ***)
            if isHorizontalRule(line) {
                elements.append(.horizontalRule)
                i += 1
                continue
            }

            // Headings — CommonMark allows up to 3 leading spaces before `#`.
            // Use trimmedLine so indented headings like "  ## Foo" parse correctly.
            if trimmedLine.hasPrefix("###### ") {
                elements.append(.heading6(String(trimmedLine.dropFirst(7))))
            } else if trimmedLine.hasPrefix("##### ") {
                elements.append(.heading5(String(trimmedLine.dropFirst(6))))
            } else if trimmedLine.hasPrefix("#### ") {
                elements.append(.heading4(String(trimmedLine.dropFirst(5))))
            } else if trimmedLine.hasPrefix("### ") {
                elements.append(.heading3(String(trimmedLine.dropFirst(4))))
            } else if trimmedLine.hasPrefix("## ") {
                elements.append(.heading2(String(trimmedLine.dropFirst(3))))
            } else if trimmedLine.hasPrefix("# ") {
                elements.append(.heading1(String(trimmedLine.dropFirst(2))))
            }
            // Table (supports leading whitespace)
            else if trimmedLine.hasPrefix("|") && trimmedLine.hasSuffix("|") {
                var tableRows: [[String]] = []

                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let currentLine = lines[i].trimmingCharacters(in: .whitespaces)

                    // Skip separator row (contains dashes)
                    if isTableSeparator(currentLine) {
                        i += 1
                        continue
                    }

                    // Split by pipe while preserving interior empty cells (e.g. "| a |  | c |" has 3 columns).
                    // `split(separator:omittingEmptySubsequences:)` with false keeps them; then we
                    // strip only the leading/trailing empties that come from the outer pipes.
                    var cells = currentLine
                        .split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if currentLine.hasPrefix("|"), cells.first == "" { cells.removeFirst() }
                    if currentLine.hasSuffix("|"), cells.last == "" { cells.removeLast() }

                    if !cells.isEmpty {
                        tableRows.append(cells)
                    }

                    i += 1
                }

                if !tableRows.isEmpty {
                    elements.append(.table(rows: tableRows))
                }
                i -= 1 // Adjust because we'll increment at the end of the loop
            }
            // List items (supports nesting via indentation)
            else if isListLine(line) {
                let item = extractListItemText(line)
                listItems.append(item)
            }
            // Display math $$...$$
            else if trimmedLine == "$$" {
                var mathLines: [String] = []
                i += 1
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "$$" {
                    mathLines.append(lines[i])
                    i += 1
                }
                elements.append(.displayMath(latex: mathLines.joined(separator: "\n")))
            }
            // Single-line display math: $$...$$ on one line
            else if trimmedLine.hasPrefix("$$") && trimmedLine.hasSuffix("$$") && trimmedLine.count > 4 {
                let inner = String(trimmedLine.dropFirst(2).dropLast(2))
                elements.append(.displayMath(latex: inner))
            }
            // Code block (supports indented fences). CommonMark requires the closing fence to have
            // at least as many backticks as the opening fence — so ````swift blocks aren't closed
            // prematurely by a three-backtick line embedded in the code.
            else if trimmedLine.hasPrefix("```") {
                let trimmed = trimmedLine
                let openLen = trimmed.prefix { $0 == "`" }.count
                let infoString = trimmed.count > openLen ? String(trimmed.dropFirst(openLen)).trimmingCharacters(in: .whitespaces) : ""
                // C2: CommonMark uses only the first word of the info string as the language.
                // Taking the whole string fed an arbitrarily long label to the renderer (crash on
                // >75 chars) and defeated the syntax highlighter's language match for "```bash extra".
                let language = infoString.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    let closeLen = candidate.prefix { $0 == "`" }.count
                    if closeLen >= openLen && candidate.allSatisfy({ $0 == "`" }) {
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                let normalizedLang = language.isEmpty ? nil : language
                if normalizedLang?.lowercased() == "mermaid" {
                    elements.append(.mermaidBlock(code: codeLines.joined(separator: "\n")))
                } else {
                    elements.append(.codeBlock(code: codeLines.joined(separator: "\n"), language: normalizedLang))
                }
            }
            // Blockquote — accept "> text", bare ">" (paragraph separator inside the quote), and
            // indented "  > text" forms. Previously only `hasPrefix("> ")` matched, so a bare `>`
            // line ended the block (CommonMark calls this a "lazy continuation") and indented
            // blockquotes weren't recognized at all.
            else if trimmedLine.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let lineTrim = lines[i].trimmingCharacters(in: .whitespaces)
                    guard lineTrim.hasPrefix(">") else { break }
                    let stripped = lineTrim.dropFirst() // drop the leading >
                    // Drop optional single space after > (per CommonMark)
                    let body = stripped.hasPrefix(" ") ? String(stripped.dropFirst()) : String(stripped)
                    quoteLines.append(body)
                    i += 1
                }
                elements.append(.blockquote(quoteLines.joined(separator: "\n")))
                i -= 1 // Adjust because we'll increment at the end
            }
            // Empty line
            else if trimmedLine.isEmpty {
                if !paragraphLines.isEmpty {
                    elements.append(.paragraph(paragraphLines.joined(separator: " ")))
                    paragraphLines = []
                }
                if !listItems.isEmpty {
                    elements.append(.list(items: listItems))
                    listItems = []
                }
            }
            // Image — read alt/path from the anchored pattern's own capture groups. Re-searching
            // the matched string for `\(...\)` grabbed the FIRST parenthesized run, so an alt
            // containing parens (`![chart (2024)](img.png)`) yielded path "2024" — broken image
            // in preview and every export.
            else if let imageRegex = Self.imageLineRegex,
                    let m = imageRegex.firstMatch(in: trimmedLine, range: NSRange(trimmedLine.startIndex..., in: trimmedLine)),
                    let altRange = Range(m.range(at: 1), in: trimmedLine),
                    let pathRange = Range(m.range(at: 2), in: trimmedLine) {
                elements.append(.image(alt: String(trimmedLine[altRange]), path: String(trimmedLine[pathRange])))
            }
            // HTML block — close as soon as tags balance, including mid-line self-closing single-liners.
            // Previously the balance check only ran on blank lines, so a balanced one-line tag like
            // `<div>x</div>` would swallow every paragraph up to the next blank line.
            else if isHTMLLine(line) {
                var htmlLines: [String] = [line]
                if isHTMLBalanced(line) {
                    elements.append(.htmlBlock(line))
                } else {
                    i += 1
                    while i < lines.count {
                        htmlLines.append(lines[i])
                        if isHTMLBalanced(htmlLines.joined(separator: "\n")) {
                            break
                        }
                        i += 1
                    }
                    elements.append(.htmlBlock(htmlLines.joined(separator: "\n")))
                }
            }
            // Regular paragraph (accumulate consecutive lines)
            else if !line.isEmpty {
                paragraphLines.append(line)
            }

            i += 1
        }

        // Flush remaining accumulated paragraph
        if !paragraphLines.isEmpty {
            elements.append(.paragraph(paragraphLines.joined(separator: " ")))
        }

        // Add any remaining list items
        if !listItems.isEmpty {
            elements.append(.list(items: listItems))
        }

        return elements
    }

    // MARK: - Helper Methods

    func isListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") ||
               trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil
    }

    func extractListItemText(_ line: String) -> (level: Int, text: String, isOrdered: Bool, startNumber: Int?) {
        // Count leading spaces/tabs to determine nesting level
        var level = 0
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == " " {
                level += 1
            } else if char == "\t" {
                // C5: one tab = one nesting level (nestLevel = level / 2 below), matching a
                // 2-space indent. Previously a tab added 4, making one tab jump TWO levels, so
                // tab- and space-indented versions of the same list rendered at different depths.
                level += 2
            } else {
                break
            }
            index = line.index(after: index)
        }
        // Convert spaces to level (every 2 spaces = 1 level)
        let nestLevel = level / 2

        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return (nestLevel, String(trimmed.dropFirst(2)), false, nil)
        }
        if let match = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            // Capture the leading integer so renderers/exporters can preserve a list that starts
            // at e.g. `4.` instead of always renumbering from 1.
            let leading = String(trimmed[match]).prefix(while: { $0.isNumber })
            let start = Int(leading)
            return (nestLevel, String(trimmed[match.upperBound...]), true, start)
        }
        return (nestLevel, trimmed, false, nil)
    }

    func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"^([-_*])\1{2,}$"#, options: .regularExpression) != nil
    }

    private static let htmlBlockTags: Set<String> = [
        "div", "p", "h1", "h2", "h3", "h4", "h5", "h6",
        "table", "thead", "tbody", "tr", "th", "td",
        "ul", "ol", "li", "dl", "dt", "dd",
        "pre", "blockquote", "section", "article", "nav",
        "header", "footer", "main", "aside", "figure",
        "figcaption", "details", "summary", "hr", "br", "img", "a",
        "strong", "em", "b", "i", "u", "s", "sub", "sup", "span",
        "center", "caption", "colgroup", "col"
    ]

    func isHTMLLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<") else { return false }
        let pattern = #"^</?([a-zA-Z][a-zA-Z0-9]*)"#
        guard let match = trimmed.range(of: pattern, options: .regularExpression) else { return false }
        let tagContent = trimmed[match].dropFirst(trimmed.hasPrefix("</") ? 2 : 1)
        let tagName = String(tagContent).lowercased()
        return Self.htmlBlockTags.contains(tagName)
    }

    /// Compiled once — this runs per appended line while accumulating an HTML block (the parse
    /// hot path); recompiling it per call was measurable on long unbalanced blocks.
    private static let htmlTagRegex = try? NSRegularExpression(pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)[^>]*>"#)

    /// Anchored image-line pattern; group 1 = alt text, group 2 = path.
    static let imageLineRegex = try? NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(([^\)]+)\)$"#)

    func isHTMLBalanced(_ html: String) -> Bool {
        guard let regex = Self.htmlTagRegex else { return true }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var depth = 0
        let selfClosing: Set<String> = ["br", "hr", "img", "input", "meta", "link", "col"]
        for match in matches {
            guard let tagRange = Range(match.range(at: 2), in: html) else { continue }
            let tag = String(html[tagRange]).lowercased()
            if selfClosing.contains(tag) { continue }
            if let fullRange = Range(match.range, in: html) {
                let fullTag = String(html[fullRange])
                if fullTag.hasSuffix("/>") { continue }
            }
            if let slashRange = Range(match.range(at: 1), in: html), !html[slashRange].isEmpty {
                depth -= 1
            } else {
                depth += 1
            }
        }
        return depth <= 0
    }

    func isTableSeparator(_ line: String) -> Bool {
        // A table separator contains mostly dashes, pipes, and colons
        let withoutPipes = line.replacingOccurrences(of: "|", with: "")
        let withoutDashes = withoutPipes.replacingOccurrences(of: "-", with: "")
        let withoutColons = withoutDashes.replacingOccurrences(of: ":", with: "")
        let withoutSpaces = withoutColons.trimmingCharacters(in: .whitespaces)
        return withoutSpaces.isEmpty && line.contains("-")
    }

    // MARK: - HTML Conversion

    /// Convert markdown to full HTML document with styles
    func toHTML(_ markdown: String, includeStyles: Bool = true) -> String {
        let elements = parse(markdown)
        let hasMermaid = elements.contains(where: { if case .mermaidBlock = $0 { return true } else { return false } })
        let hasMath = elements.contains(where: { if case .displayMath = $0 { return true } else { return false } })
            || markdown.range(of: Self.inlineMathPattern, options: .regularExpression) != nil

        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
        """

        if hasMermaid {
            html += "\n    <script src=\"\(CDN.mermaidJS)\" integrity=\"\(CDN.mermaidJSIntegrity)\" crossorigin=\"anonymous\"></script>"
            html += "\n    <script>mermaid.initialize({startOnLoad: true});</script>"
        }

        if hasMath {
            html += "\n    <link rel=\"stylesheet\" href=\"\(CDN.katexCSS)\" integrity=\"\(CDN.katexCSSIntegrity)\" crossorigin=\"anonymous\">"
            html += "\n    <script src=\"\(CDN.katexJS)\" integrity=\"\(CDN.katexJSIntegrity)\" crossorigin=\"anonymous\"></script>"
            html += "\n    <script src=\"\(CDN.katexAutoRenderJS)\" integrity=\"\(CDN.katexAutoRenderJSIntegrity)\" crossorigin=\"anonymous\"></script>"
            // Auto-render handles inline `$...$` (we only emit those for inline math). For
            // display math we use <script type="math/tex; mode=display"> tags (H16) — read each
            // one and call katex.render so the body LaTeX isn't subject to HTML parsing.
            html += "\n    <script>document.addEventListener('DOMContentLoaded', function() {"
            html += " renderMathInElement(document.body, { delimiters: [{left: '$', right: '$', display: false}] });"
            html += " var mathScripts = document.querySelectorAll('script[type=\"math/tex; mode=display\"]');"
            html += " mathScripts.forEach(function(s) { var span = document.createElement('span'); try { katex.render(s.textContent, span, { displayMode: true }); s.parentNode.insertBefore(span, s); } catch(e) { span.textContent = s.textContent; s.parentNode.insertBefore(span, s); } });"
            html += " });</script>"
        }

        if includeStyles {
            html += """

                <style>
                    @page {
                        margin: 0.75in;
                        size: letter;
                    }
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
                        font-size: 11pt;
                        line-height: 1.5;
                        color: #000;
                        margin: 0;
                        padding: 0;
                    }
                    h1 {
                        font-size: 24pt;
                        font-weight: 600;
                        margin-top: 18pt;
                        margin-bottom: 12pt;
                        padding-bottom: 8pt;
                        border-bottom: 2px solid #333;
                        page-break-after: avoid;
                    }
                    h2 {
                        font-size: 18pt;
                        font-weight: 600;
                        margin-top: 16pt;
                        margin-bottom: 8pt;
                        page-break-after: avoid;
                    }
                    h3 {
                        font-size: 14pt;
                        font-weight: 600;
                        margin-top: 12pt;
                        margin-bottom: 6pt;
                        page-break-after: avoid;
                    }
                    h4 {
                        font-size: 12pt;
                        font-weight: 600;
                        margin-top: 10pt;
                        margin-bottom: 4pt;
                        page-break-after: avoid;
                    }
                    p {
                        margin-top: 0;
                        margin-bottom: 10pt;
                        text-align: justify;
                    }
                    strong { font-weight: 600; }
                    em { font-style: italic; }
                    code {
                        background-color: #f0f0f0;
                        padding: 2px 4px;
                        font-family: 'Menlo', 'Monaco', 'Courier New', monospace;
                        font-size: 10pt;
                    }
                    pre {
                        background-color: #f5f5f5;
                        padding: 10pt;
                        margin: 10pt 0;
                        border: 1px solid #ddd;
                        page-break-inside: avoid;
                        overflow-x: auto;
                    }
                    pre code {
                        background: none;
                        padding: 0;
                        font-size: 9pt;
                    }
                    ul, ol {
                        margin: 10pt 0;
                        padding-left: 24pt;
                    }
                    li { margin: 4pt 0; }
                    table {
                        border-collapse: collapse;
                        width: 100%;
                        margin: 12pt 0;
                        page-break-inside: auto;
                    }
                    tr {
                        page-break-inside: avoid;
                        page-break-after: auto;
                    }
                    th, td {
                        border: 1px solid #666;
                        padding: 6pt 10pt;
                        text-align: left;
                        font-size: 10pt;
                    }
                    th {
                        background-color: #e8e8e8;
                        font-weight: 600;
                    }
                    blockquote {
                        border-left: 3px solid #999;
                        padding-left: 12pt;
                        margin: 12pt 0;
                        color: #555;
                        font-style: italic;
                    }
                    hr {
                        border: none;
                        border-top: 1px solid #999;
                        margin: 18pt 0;
                    }
                    .frontmatter {
                        background-color: #f8f8f8;
                        border: 1px solid #ddd;
                        padding: 8pt;
                        margin-bottom: 16pt;
                        font-size: 10pt;
                    }
                    .frontmatter table {
                        border: none;
                        margin: 0;
                    }
                    .frontmatter td {
                        border: none;
                        padding: 2pt 6pt;
                    }
                </style>
            """
        }

        html += """

        </head>
        <body>
        """

        html += toHTMLBody(markdown)
        html += "\n</body>\n</html>"

        return html
    }

    /// Convert markdown to HTML body content only (no wrapper)
    func toHTMLBody(_ markdown: String) -> String {
        let elements = parse(markdown)
        return elements.map { elementToHTML($0) }.joined()
    }

    private func elementToHTML(_ element: Element) -> String {
        switch element {
        case .heading1(let text):
            return "<h1>\(formatInlineHTML(text))</h1>\n"
        case .heading2(let text):
            return "<h2>\(formatInlineHTML(text))</h2>\n"
        case .heading3(let text):
            return "<h3>\(formatInlineHTML(text))</h3>\n"
        case .heading4(let text):
            return "<h4>\(formatInlineHTML(text))</h4>\n"
        case .heading5(let text):
            return "<h5>\(formatInlineHTML(text))</h5>\n"
        case .heading6(let text):
            return "<h6>\(formatInlineHTML(text))</h6>\n"
        case .paragraph(let text):
            return "<p>\(formatInlineHTML(text))</p>\n"
        case .frontmatter(let lines):
            var html = "<div class=\"frontmatter\"><table>\n"
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if let colonIndex = trimmed.firstIndex(of: ":") {
                    let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                    html += "<tr><td><strong>\(escapeHTML(key))</strong></td><td>\(formatInlineHTML(value))</td></tr>\n"
                } else {
                    html += "<tr><td colspan=\"2\">\(formatInlineHTML(trimmed))</td></tr>\n"
                }
            }
            html += "</table></div>\n"
            return html
        case .list(let items):
            let isOrdered = items.first?.isOrdered ?? false
            let firstTag = isOrdered ? "ol" : "ul"
            // Honor an explicit start number on the first item (e.g. `4. ...` should render as
            // `<ol start="4">`, not `<ol>` which always restarts at 1). Skipping start=1 keeps
            // the common case clean.
            var openTag = "<\(firstTag)"
            if isOrdered, let start = items.first?.startNumber, start != 1 {
                openTag += " start=\"\(start)\""
            }
            openTag += ">"
            var html = "\(openTag)\n"
            for item in items {
                let style = item.level > 0 ? " style=\"margin-left: \(item.level * 20)px\"" : ""
                if item.text.hasPrefix("[ ] ") {
                    html += "<li\(style)>☐ \(formatInlineHTML(String(item.text.dropFirst(4))))</li>\n"
                } else if item.text.hasPrefix("[x] ") || item.text.hasPrefix("[X] ") {
                    html += "<li\(style)>☑ \(formatInlineHTML(String(item.text.dropFirst(4))))</li>\n"
                } else {
                    html += "<li\(style)>\(formatInlineHTML(item.text))</li>\n"
                }
            }
            html += "</\(firstTag)>\n"
            return html
        case .codeBlock(let code, _):
            return "<pre><code>\(escapeHTML(code))</code></pre>\n"
        case .mermaidBlock(let code):
            return "<pre class=\"mermaid\">\(escapeHTML(code))</pre>\n"
        case .displayMath(let latex):
            // H16: place the LaTeX inside a <script type="math/tex; mode=display"> tag.
            // Script tag contents aren't parsed as HTML, so `a < b` and `\&` survive intact —
            // previously HTML-escaping turned those into entities that KaTeX rendered literally.
            // The companion init script (added to the head when hasMath is true) reads these
            // tags and calls katex.render on each.
            // S1: neutralize any "</script>" breakout. A browser ends a <script> element on the
            // literal bytes "</" regardless of context, so raw LaTeX containing "</script>" would
            // otherwise inject markup into the exported HTML. The backslash is ignored by KaTeX's
            // TeX parser, so the rendered math is unchanged.
            let safeLatex = latex.replacingOccurrences(of: "</", with: "<\\/")
            return "<div class=\"math-display\"><script type=\"math/tex; mode=display\">\(safeLatex)</script></div>\n"
        case .table(let rows):
            var html = "<table>\n"
            for (rowIndex, row) in rows.enumerated() {
                html += "<tr>"
                let tag = rowIndex == 0 ? "th" : "td"
                // Detect "populated first cell, all others empty" rows (a common convention for
                // summary/footer rows that span the full width). Emit colspan so the populated
                // cell visually fills the row in HTML/PDF/RTF output. CommonMark doesn't have
                // syntax for this; we infer it.
                let trimmed = row.map { $0.trimmingCharacters(in: .whitespaces) }
                if row.count > 1, !trimmed[0].isEmpty,
                   trimmed.dropFirst().allSatisfy({ $0.isEmpty }) {
                    html += "<\(tag) colspan=\"\(row.count)\">\(formatInlineHTML(row[0]))</\(tag)>"
                } else {
                    for cell in row {
                        html += "<\(tag)>\(formatInlineHTML(cell))</\(tag)>"
                    }
                }
                html += "</tr>\n"
            }
            html += "</table>\n"
            return html
        case .image(let alt, let path):
            // C3: also clean image src — javascript: / vbscript: are not normally seen for
            // <img> but defense-in-depth. Allows http/https/file/relative/data:image.
            return "<img src=\"\(escapeHTML(Self.sanitizeURLScheme(path)))\" alt=\"\(escapeHTML(alt))\">\n"
        case .horizontalRule:
            return "<hr>\n"
        case .blockquote(let text):
            return "<blockquote>\(formatInlineHTML(text))</blockquote>\n"
        case .htmlBlock(let html):
            // Raw HTML blocks are user-controlled. Export them as visible text rather than
            // attempting regex sanitization of browser HTML.
            return escapeHTML(html) + "\n"
        }
    }

    private static func escapeHTMLAttribute(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// C3: Allow only safe URL schemes in markdown link `href`. Anything else is rewritten
    /// to `#` so an exported HTML can't execute `javascript:` / `data:text/html` payloads
    /// when opened in a browser. Relative paths and fragment links pass through unchanged.
    static func sanitizeURLScheme(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "#" }
        // Schemeless / fragment / relative paths are fine.
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") {
            return trimmed
        }
        // No colon = no scheme = relative.
        guard let colon = trimmed.firstIndex(of: ":") else { return trimmed }
        let scheme = trimmed[..<colon].lowercased()
        // No `/` before the colon = file or filename with `:` in it = let it pass.
        if scheme.contains("/") { return trimmed }
        let allowed: Set<String> = ["http", "https", "mailto", "tel", "ftp", "file"]
        if allowed.contains(scheme) { return trimmed }
        // Allow data:image/* but not data:text/html or other arbitrary data: payloads.
        if scheme == "data" {
            let rest = trimmed[trimmed.index(after: colon)...].lowercased()
            if rest.hasPrefix("image/") && !rest.hasPrefix("image/svg+xml") { return trimmed }
        }
        return "#"
    }

    // MARK: - Inline Formatting

    /// Format inline markdown (bold, italic, code, links) to HTML
    func formatInlineHTML(_ text: String) -> String {
        InlineMarkdown.tokenize(text).map { token in
            switch token {
            case .text(let value):
                return escapeHTML(value)
            case .lineBreak:
                return "<br>"
            case .code(let value):
                return "<code>\(escapeHTML(value))</code>"
            case .math(let value):
                return "$\(escapeHTML(value))$"
            case .strong(let value):
                return "<strong>\(formatInlineHTML(value))</strong>"
            case .emphasis(let value):
                return "<em>\(formatInlineHTML(value))</em>"
            case .strikethrough(let value):
                return "<del>\(formatInlineHTML(value))</del>"
            case .highlight(let value):
                return "<mark>\(formatInlineHTML(value))</mark>"
            case .image(let alt, let source):
                let safeSource = Self.sanitizeURLScheme(source)
                return "<img src=\"\(Self.escapeHTMLAttribute(safeSource))\" alt=\"\(Self.escapeHTMLAttribute(alt))\">"
            case .link(let label, let destination):
                let safeDestination = Self.sanitizeURLScheme(destination)
                return "<a href=\"\(Self.escapeHTMLAttribute(safeDestination))\">\(formatInlineHTML(label))</a>"
            }
        }.joined()
    }

    /// Escape HTML special characters
    func escapeHTML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Outline Extraction

    /// Convert heading text to a GitHub-style slug for stable IDs that survive edits above the heading.
    /// - lowercased, non-alphanumerics → "-", collapsed dashes, trimmed
    static func slugify(_ text: String) -> String {
        let lowered = text.lowercased()
        var slug = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        if slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "section" : slug
    }

    /// Extract headings for outline view with stable slug IDs.
    /// Skips lines inside fenced code blocks and YAML frontmatter so shell comments like `# echo`
    /// inside ```bash``` blocks don't appear in the outline. Duplicate slugs get a -2, -3 suffix
    /// matching GitHub's anchor-generation convention.
    func extractHeadings(_ markdown: String) -> [(id: String, level: Int, text: String, lineIndex: Int)] {
        var headings: [(id: String, level: Int, text: String, lineIndex: Int)] = []
        let lines = splitLines(markdown)
        var slugCounts: [String: Int] = [:]
        var i = 0

        // Skip YAML frontmatter: if the file opens with `---` and has a matching closer, jump
        // past it. Tolerate trailing whitespace on the delimiter (L6).
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var j = 1
            while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces) != "---" { j += 1 }
            if j < lines.count && lines[j].trimmingCharacters(in: .whitespaces) == "---" {
                i = j + 1
            }
        }

        // Track open fence width so a `` ``` `` line inside a 4-backtick block doesn't end it.
        // M1: previously toggling on any 3-backtick line emitted phantom "headings" from `#`
        // lines that lived inside ` ```` `-fenced blocks containing nested ` ``` ` examples.
        var openFenceLen: Int = 0
        // Track HTML block: accumulate lines from the open until isHTMLBalanced returns true,
        // then exit. Mirrors parse()'s loop so a `# X` line inside a `<div>...</div>` block
        // doesn't get counted as a heading (M4).
        var htmlBuffer: [String]? = nil
        // C3: track open `$$` display-math blocks, mirroring parse()'s consumption, so a `# X` line
        // inside one isn't emitted as a phantom heading — which would desync the positional
        // heading↔slug pairing in MarkdownTextView and shift every later heading by one.
        var inDisplayMath = false

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fence enter/exit
            if trimmed.hasPrefix("```") && htmlBuffer == nil {
                let fenceLen = trimmed.prefix { $0 == "`" }.count
                if openFenceLen == 0 {
                    openFenceLen = fenceLen
                } else if fenceLen >= openFenceLen && trimmed.allSatisfy({ $0 == "`" }) {
                    openFenceLen = 0
                }
                i += 1
                continue
            }
            if openFenceLen > 0 {
                i += 1
                continue
            }

            // C3: display-math block enter/exit ($$ ... $$). A bare `$$` line toggles the block;
            // lines inside are not headings. Single-line `$$...$$` is self-contained (no enclosed
            // lines) so it needs no handling here.
            if trimmed == "$$" && htmlBuffer == nil {
                inDisplayMath.toggle()
                i += 1
                continue
            }
            if inDisplayMath {
                i += 1
                continue
            }

            // Inside an open HTML block — keep accumulating until balanced.
            if var buf = htmlBuffer {
                buf.append(line)
                if isHTMLBalanced(buf.joined(separator: "\n")) {
                    htmlBuffer = nil
                } else {
                    htmlBuffer = buf
                }
                i += 1
                continue
            }

            // New HTML block entry: only if line opens a recognized block tag and isn't
            // immediately balanced on its own line.
            if isHTMLLine(line) {
                if !isHTMLBalanced(line) {
                    htmlBuffer = [line]
                }
                // Either way, an HTML-block-opening line is not a heading.
                i += 1
                continue
            }

            if trimmed.hasPrefix("#") {
                var level = 0
                for char in trimmed {
                    if char == "#" { level += 1 } else { break }
                }
                if level > 0 && level <= 6 {
                    let headingBody = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    // Heading must have whitespace between # chars and body (CommonMark requirement).
                    if !headingBody.isEmpty && trimmed.dropFirst(level).first == " " {
                        let baseSlug = Self.slugify(headingBody)
                        let count = (slugCounts[baseSlug] ?? 0) + 1
                        slugCounts[baseSlug] = count
                        let slug = count == 1 ? baseSlug : "\(baseSlug)-\(count)"
                        headings.append((id: slug, level: level, text: headingBody, lineIndex: i))
                    }
                }
            }
            i += 1
        }

        return headings
    }
}
