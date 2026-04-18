import Foundation

/// Unified markdown parser used by ExportManager (export) and MarkdownTextView (rendering)
/// This is the single source of truth for markdown parsing in zMD
class MarkdownParser {
    static let shared = MarkdownParser()

    private init() {}

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
        case list(items: [(level: Int, text: String, isOrdered: Bool)])
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
                let joined = items.map { "\($0.level)\(unit)\($0.isOrdered ? "1" : "0")\(unit)\($0.text)" }.joined(separator: "\u{1E}")
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

        var textContent: String {
            switch self {
            case .heading1(let text), .heading2(let text), .heading3(let text),
                 .heading4(let text), .heading5(let text), .heading6(let text),
                 .paragraph(let text), .blockquote(let text):
                return text
            case .frontmatter(let lines):
                return lines.joined(separator: "\n")
            case .list(let items):
                return items.map(\.text).joined(separator: "\n")
            case .codeBlock(let code, _):
                return code
            case .mermaidBlock(let code):
                return code
            case .displayMath(let latex):
                return latex
            case .table(let rows):
                return rows.flatMap { $0 }.joined(separator: " ")
            case .image(let alt, _):
                return alt
            case .horizontalRule:
                return ""
            case .htmlBlock(let html):
                return html
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

        var headingLevel: Int? {
            switch self {
            case .heading1: return 1
            case .heading2: return 2
            case .heading3: return 3
            case .heading4: return 4
            case .heading5: return 5
            case .heading6: return 6
            default: return nil
            }
        }
    }

    // MARK: - Parsing

    /// Parse markdown string into array of elements
    func parse(_ markdown: String) -> [Element] {
        var elements: [Element] = []
        let lines = markdown.components(separatedBy: .newlines)
        var i = 0
        var listItems: [(level: Int, text: String, isOrdered: Bool)] = []
        var paragraphLines: [String] = []

        // Check for YAML frontmatter at start of document
        if lines.first == "---" {
            var frontmatterLines: [String] = []
            i = 1
            while i < lines.count && lines[i] != "---" {
                frontmatterLines.append(lines[i])
                i += 1
            }
            if i < lines.count && lines[i] == "---" {
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
            let isPlainText = !line.isEmpty && !trimmedLine.isEmpty
                && !line.hasPrefix("#")
                && !trimmedLine.hasPrefix("|")
                && !line.hasPrefix("> ")
                && !isListLine(line)
                && !trimmedLine.hasPrefix("```")
                && !isHorizontalRule(line)
                && !isHTMLLine(line)
                && trimmedLine != "$$"
                && line.range(of: #"!\[([^\]]*)\]\(([^\)]+)\)"#, options: .regularExpression) == nil
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
            // Code block (supports indented fences). CommonMark requires the closing fence to have
            // at least as many backticks as the opening fence — so ````swift blocks aren't closed
            // prematurely by a three-backtick line embedded in the code.
            else if trimmedLine.hasPrefix("```") {
                let trimmed = trimmedLine
                let openLen = trimmed.prefix { $0 == "`" }.count
                let language = trimmed.count > openLen ? String(trimmed.dropFirst(openLen)).trimmingCharacters(in: .whitespaces) : ""
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
            // Blockquote
            else if line.hasPrefix("> ") {
                var quoteLines: [String] = []
                while i < lines.count && lines[i].hasPrefix("> ") {
                    quoteLines.append(String(lines[i].dropFirst(2)))
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
            // Image
            else if let imageMatch = line.range(of: #"!\[([^\]]*)\]\(([^\)]+)\)"#, options: .regularExpression) {
                let matchedString = String(line[imageMatch])
                if let altRange = matchedString.range(of: #"\[([^\]]*)\]"#, options: .regularExpression),
                   let pathRange = matchedString.range(of: #"\(([^\)]+)\)"#, options: .regularExpression) {
                    let alt = String(matchedString[altRange]).dropFirst().dropLast()
                    let path = String(matchedString[pathRange]).dropFirst().dropLast()
                    elements.append(.image(alt: String(alt), path: String(path)))
                }
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

    private func isOrderedListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil
    }

    func extractListItemText(_ line: String) -> (level: Int, text: String, isOrdered: Bool) {
        // Count leading spaces/tabs to determine nesting level
        var level = 0
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == " " {
                level += 1
            } else if char == "\t" {
                level += 4  // Treat tab as 4 spaces
            } else {
                break
            }
            index = line.index(after: index)
        }
        // Convert spaces to level (every 2 spaces = 1 level)
        let nestLevel = level / 2

        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return (nestLevel, String(trimmed.dropFirst(2)), false)
        }
        if let match = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            return (nestLevel, String(trimmed[match.upperBound...]), true)
        }
        return (nestLevel, trimmed, false)
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

    func isHTMLBalanced(_ html: String) -> Bool {
        let pattern = #"<(/?)([a-zA-Z][a-zA-Z0-9]*)[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return true }
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
            || markdown.range(of: #"(?<!\$)\$(?!\$)(?! )(.+?)(?<! )\$(?!\$)"#, options: .regularExpression) != nil

        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
        """

        if hasMermaid {
            html += "\n    <script src=\"\(CDN.mermaidJS)\"></script>"
            html += "\n    <script>mermaid.initialize({startOnLoad: true});</script>"
        }

        if hasMath {
            html += "\n    <link rel=\"stylesheet\" href=\"\(CDN.katexCSS)\">"
            html += "\n    <script src=\"\(CDN.katexJS)\"></script>"
            html += "\n    <script src=\"\(CDN.katexAutoRenderJS)\"></script>"
            html += "\n    <script>document.addEventListener('DOMContentLoaded', function() { renderMathInElement(document.body, { delimiters: [{left: '$$', right: '$$', display: true}, {left: '$', right: '$', display: false}] }); });</script>"
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
            let firstTag = (items.first?.isOrdered ?? false) ? "ol" : "ul"
            var html = "<\(firstTag)>\n"
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
            return "<div class=\"math-display\">$$\(escapeHTML(latex))$$</div>\n"
        case .table(let rows):
            var html = "<table>\n"
            for (rowIndex, row) in rows.enumerated() {
                html += "<tr>"
                for cell in row {
                    let tag = rowIndex == 0 ? "th" : "td"
                    html += "<\(tag)>\(formatInlineHTML(cell))</\(tag)>"
                }
                html += "</tr>\n"
            }
            html += "</table>\n"
            return html
        case .image(let alt, let path):
            return "<img src=\"\(escapeHTML(path))\" alt=\"\(escapeHTML(alt))\">\n"
        case .horizontalRule:
            return "<hr>\n"
        case .blockquote(let text):
            return "<blockquote>\(formatInlineHTML(text))</blockquote>\n"
        case .htmlBlock(let html):
            return html + "\n"
        }
    }

    // MARK: - Inline Formatting

    /// Format inline markdown (bold, italic, code, links) to HTML
    func formatInlineHTML(_ text: String) -> String {
        var result = escapeHTML(text)

        // Bold **text** (must come before italic)
        result = result.replacingOccurrences(
            of: #"\*\*([^\*]+)\*\*"#,
            with: "<strong>$1</strong>",
            options: .regularExpression
        )

        // Italic *text*
        result = result.replacingOccurrences(
            of: #"\*([^\*]+)\*"#,
            with: "<em>$1</em>",
            options: .regularExpression
        )

        // Inline code `text`
        result = result.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: "<code>$1</code>",
            options: .regularExpression
        )

        // Links [text](url)
        result = result.replacingOccurrences(
            of: #"\[([^\]]+)\]\(([^\)]+)\)"#,
            with: "<a href=\"$2\">$1</a>",
            options: .regularExpression
        )

        // Strikethrough ~~text~~
        result = result.replacingOccurrences(
            of: #"~~([^~]+)~~"#,
            with: "<del>$1</del>",
            options: .regularExpression
        )

        return result
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

    /// Escape XML special characters
    func escapeXML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
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
        let lines = markdown.components(separatedBy: .newlines)
        var slugCounts: [String: Int] = [:]
        var inCodeFence = false
        var i = 0

        // Skip YAML frontmatter: if the file opens with `---` and has a matching closer, jump past it.
        if lines.first == "---" {
            var j = 1
            while j < lines.count && lines[j] != "---" { j += 1 }
            if j < lines.count && lines[j] == "---" {
                i = j + 1
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inCodeFence.toggle()
                i += 1
                continue
            }
            if inCodeFence {
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
                    if !headingBody.isEmpty && (trimmed.dropFirst(level).first == " " || trimmed.count == level) {
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
