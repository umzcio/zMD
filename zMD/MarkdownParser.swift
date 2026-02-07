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
        case paragraph(String)
        case list(items: [String])
        case codeBlock(code: String, language: String?)
        case mermaidBlock(code: String)
        case displayMath(latex: String)
        case table(rows: [[String]])
        case image(alt: String, path: String)
        case horizontalRule
        case blockquote(String)

        var id: String {
            switch self {
            case .heading1(let text): return "h1-\(text.hashValue)"
            case .heading2(let text): return "h2-\(text.hashValue)"
            case .heading3(let text): return "h3-\(text.hashValue)"
            case .heading4(let text): return "h4-\(text.hashValue)"
            case .paragraph(let text): return "p-\(text.hashValue)"
            case .list(let items): return "list-\(items.joined().hashValue)"
            case .codeBlock(let code, _): return "code-\(code.hashValue)"
            case .mermaidBlock(let code): return "mermaid-\(code.hashValue)"
            case .displayMath(let latex): return "math-\(latex.hashValue)"
            case .table(let rows): return "table-\(rows.flatMap { $0 }.joined().hashValue)"
            case .image(let alt, let path): return "img-\(alt.hashValue)-\(path.hashValue)"
            case .horizontalRule: return "hr-\(UUID().uuidString)"
            case .blockquote(let text): return "quote-\(text.hashValue)"
            }
        }

        var textContent: String {
            switch self {
            case .heading1(let text), .heading2(let text), .heading3(let text),
                 .heading4(let text), .paragraph(let text), .blockquote(let text):
                return text
            case .list(let items):
                return items.joined(separator: "\n")
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
            }
        }

        var isHeading: Bool {
            switch self {
            case .heading1, .heading2, .heading3, .heading4:
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
        var listItems: [String] = []

        while i < lines.count {
            let line = lines[i]

            // End list if we hit a non-list item
            if !isListLine(line) && !listItems.isEmpty {
                elements.append(.list(items: listItems))
                listItems = []
            }

            // Horizontal rule (---, ___, ***)
            if isHorizontalRule(line) {
                elements.append(.horizontalRule)
                i += 1
                continue
            }

            // Headings
            if line.hasPrefix("#### ") {
                elements.append(.heading4(String(line.dropFirst(5))))
            } else if line.hasPrefix("### ") {
                elements.append(.heading3(String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                elements.append(.heading2(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                elements.append(.heading1(String(line.dropFirst(2))))
            }
            // Table
            else if line.hasPrefix("|") && line.hasSuffix("|") {
                var tableRows: [[String]] = []

                while i < lines.count && lines[i].hasPrefix("|") {
                    let currentLine = lines[i].trimmingCharacters(in: .whitespaces)

                    // Skip separator row (contains dashes)
                    if isTableSeparator(currentLine) {
                        i += 1
                        continue
                    }

                    let cells = currentLine
                        .split(separator: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }

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
            // Bullet/task lists
            else if isListLine(line) {
                let itemText = extractListItemText(line)
                listItems.append(itemText)
            }
            // Display math $$...$$
            else if line.trimmingCharacters(in: .whitespaces) == "$$" {
                var mathLines: [String] = []
                i += 1
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "$$" {
                    mathLines.append(lines[i])
                    i += 1
                }
                elements.append(.displayMath(latex: mathLines.joined(separator: "\n")))
            }
            // Code block
            else if line.hasPrefix("```") {
                let language = line.count > 3 ? String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) : nil
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if language?.lowercased() == "mermaid" {
                    elements.append(.mermaidBlock(code: codeLines.joined(separator: "\n")))
                } else {
                    elements.append(.codeBlock(code: codeLines.joined(separator: "\n"), language: language.flatMap { $0.isEmpty ? nil : $0 }))
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
            else if line.trimmingCharacters(in: .whitespaces).isEmpty {
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
            // Regular paragraph
            else if !line.isEmpty {
                elements.append(.paragraph(line))
            }

            i += 1
        }

        // Add any remaining list items
        if !listItems.isEmpty {
            elements.append(.list(items: listItems))
        }

        return elements
    }

    // MARK: - Helper Methods

    private func isListLine(_ line: String) -> Bool {
        return line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") ||
               line.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil
    }

    private func extractListItemText(_ line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return String(line.dropFirst(2))
        }
        if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            return String(line[match.upperBound...])
        }
        return line
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"^([-_*])\1{2,}$"#, options: .regularExpression) != nil
    }

    private func isTableSeparator(_ line: String) -> Bool {
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
            html += "\n    <script src=\"https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js\"></script>"
            html += "\n    <script>mermaid.initialize({startOnLoad: true});</script>"
        }

        if hasMath {
            html += "\n    <link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css\">"
            html += "\n    <script src=\"https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js\"></script>"
            html += "\n    <script src=\"https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js\"></script>"
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
        case .paragraph(let text):
            return "<p>\(formatInlineHTML(text))</p>\n"
        case .list(let items):
            var html = "<ul>\n"
            for item in items {
                if item.hasPrefix("[ ] ") {
                    html += "<li>☐ \(formatInlineHTML(String(item.dropFirst(4))))</li>\n"
                } else if item.hasPrefix("[x] ") || item.hasPrefix("[X] ") {
                    html += "<li>☑ \(formatInlineHTML(String(item.dropFirst(4))))</li>\n"
                } else {
                    html += "<li>\(formatInlineHTML(item))</li>\n"
                }
            }
            html += "</ul>\n"
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

    /// Extract headings for outline view
    func extractHeadings(_ markdown: String) -> [(id: String, level: Int, text: String, lineIndex: Int)] {
        var headings: [(id: String, level: Int, text: String, lineIndex: Int)] = []
        let lines = markdown.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            if line.hasPrefix("#") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                var level = 0

                for char in trimmed {
                    if char == "#" {
                        level += 1
                    } else {
                        break
                    }
                }

                if level > 0 && level <= 4 {
                    let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    headings.append((id: "heading-\(index)", level: level, text: text, lineIndex: index))
                }
            }
        }

        return headings
    }
}
