import SwiftUI
import AppKit

class ExportManager {
    static let shared = ExportManager()

    private init() {}

    // MARK: - PDF Export
    func exportToPDF(content: String, fileName: String) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = fileName.replacingOccurrences(of: ".md", with: ".pdf")
        savePanel.title = "Export as PDF"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            DispatchQueue.main.async {
                do {
                    // Create PDF using NSAttributedString (sandbox-friendly)
                    let html = self.markdownToHTML(content)

                    guard let htmlData = html.data(using: .utf8) else {
                        print("Failed to convert HTML to data")
                        return
                    }

                    // Convert HTML to attributed string
                    let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                        .documentType: NSAttributedString.DocumentType.html,
                        .characterEncoding: String.Encoding.utf8.rawValue
                    ]

                    guard let attributedString = NSAttributedString(html: htmlData, options: options, documentAttributes: nil) else {
                        print("Failed to create attributed string")
                        return
                    }

                    // Create PDF context
                    let pageSize = CGSize(width: 8.5 * 72, height: 11 * 72) // Letter size
                    let pageRect = CGRect(origin: .zero, size: pageSize)
                    let printInfo = NSPrintInfo()
                    printInfo.paperSize = pageSize
                    printInfo.leftMargin = 54 // 0.75 inches
                    printInfo.rightMargin = 54
                    printInfo.topMargin = 54
                    printInfo.bottomMargin = 54

                    // Calculate text bounds
                    let textRect = NSRect(
                        x: printInfo.leftMargin,
                        y: printInfo.bottomMargin,
                        width: pageSize.width - printInfo.leftMargin - printInfo.rightMargin,
                        height: pageSize.height - printInfo.topMargin - printInfo.bottomMargin
                    )

                    let pdfData = NSMutableData()
                    guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return }

                    var mediaBox = pageRect
                    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }

                    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
                    NSGraphicsContext.current = nsContext

                    // Calculate total height needed
                    let layoutManager = NSLayoutManager()
                    let textContainer = NSTextContainer(size: CGSize(width: textRect.width, height: .greatestFiniteMagnitude))
                    let textStorage = NSTextStorage(attributedString: attributedString)

                    layoutManager.addTextContainer(textContainer)
                    textStorage.addLayoutManager(layoutManager)

                    layoutManager.glyphRange(for: textContainer)
                    let usedRect = layoutManager.usedRect(for: textContainer)

                    // Draw pages
                    var currentY: CGFloat = 0
                    let pageHeight = textRect.height

                    while currentY < usedRect.height {
                        context.beginPage(mediaBox: &mediaBox)

                        let drawRect = NSRect(
                            x: textRect.minX,
                            y: textRect.minY,
                            width: textRect.width,
                            height: min(pageHeight, usedRect.height - currentY)
                        )

                        context.saveGState()
                        context.translateBy(x: 0, y: pageSize.height)
                        context.scaleBy(x: 1.0, y: -1.0)
                        context.translateBy(x: 0, y: -currentY)

                        attributedString.draw(in: drawRect)

                        context.restoreGState()
                        context.endPage()

                        currentY += pageHeight
                    }

                    context.closePDF()

                    try pdfData.write(to: url)
                    print("PDF exported successfully to \(url.path)")
                } catch {
                    print("Error exporting PDF: \(error)")
                }
            }
        }
    }

    // MARK: - HTML Export
    func exportToHTML(content: String, fileName: String, includeStyles: Bool = true) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.html]
        savePanel.nameFieldStringValue = fileName.replacingOccurrences(of: ".md", with: ".html")
        savePanel.title = includeStyles ? "Export as HTML" : "Export as HTML (without styles)"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            let html = includeStyles ? self.markdownToHTML(content) : self.markdownToHTMLWithoutStyles(content)

            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("Failed to export HTML: \(error)")
            }
        }
    }

    // MARK: - Word/RTF Export
    func exportToWord(content: String, fileName: String) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.rtf]
        savePanel.nameFieldStringValue = fileName.replacingOccurrences(of: ".md", with: ".rtf")
        savePanel.title = "Export as RTF (Word Compatible)"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            DispatchQueue.main.async {
                // Convert markdown to HTML first, then to attributed string, then to RTF
                let html = self.markdownToHTML(content)

                guard let data = html.data(using: .utf8) else {
                    print("Failed to convert HTML to data")
                    return
                }

                guard let attributedString = NSAttributedString(
                    html: data,
                    options: [
                        .documentType: NSAttributedString.DocumentType.html,
                        .characterEncoding: String.Encoding.utf8.rawValue
                    ],
                    documentAttributes: nil
                ) else {
                    print("Failed to create attributed string from HTML")
                    return
                }

                do {
                    let rtfData = try attributedString.data(
                        from: NSRange(location: 0, length: attributedString.length),
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                    )
                    try rtfData.write(to: url)
                    print("RTF exported successfully to \(url.path)")
                } catch {
                    print("Failed to export RTF: \(error)")
                }
            }
        }
    }

    // MARK: - Markdown to HTML Conversion
    private func markdownToHTML(_ markdown: String) -> String {
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
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
                strong {
                    font-weight: 600;
                }
                em {
                    font-style: italic;
                }
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
                li {
                    margin: 4pt 0;
                }
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
        </head>
        <body>
        """

        html += convertMarkdownToHTMLBody(markdown)
        html += "\n</body>\n</html>"

        return html
    }

    private func markdownToHTMLWithoutStyles(_ markdown: String) -> String {
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
        </head>
        <body>
        """

        html += convertMarkdownToHTMLBody(markdown)
        html += "\n</body>\n</html>"

        return html
    }

    private func convertMarkdownToHTMLBody(_ markdown: String) -> String {
        var html = ""
        let lines = markdown.components(separatedBy: .newlines)
        var i = 0
        var inList = false
        var inCodeBlock = false

        while i < lines.count {
            let line = lines[i]

            // Code blocks
            if line.hasPrefix("```") {
                if inCodeBlock {
                    html += "</code></pre>\n"
                    inCodeBlock = false
                } else {
                    if inList {
                        html += "</ul>\n"
                        inList = false
                    }
                    html += "<pre><code>"
                    inCodeBlock = true
                }
                i += 1
                continue
            }

            if inCodeBlock {
                html += escapeHTML(line) + "\n"
                i += 1
                continue
            }

            // Tables
            if line.hasPrefix("|") && line.hasSuffix("|") {
                if inList {
                    html += "</ul>\n"
                    inList = false
                }

                html += "<table>\n"
                var isFirstRow = true

                while i < lines.count && lines[i].hasPrefix("|") {
                    let currentLine = lines[i].trimmingCharacters(in: .whitespaces)

                    // Skip separator row
                    if currentLine.contains("---") || currentLine.contains("--") {
                        i += 1
                        isFirstRow = false
                        continue
                    }

                    let cells = currentLine
                        .split(separator: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }

                    if !cells.isEmpty {
                        html += "<tr>"
                        for cell in cells {
                            let tag = isFirstRow ? "th" : "td"
                            html += "<\(tag)>\(formatInlineMarkdown(cell))</\(tag)>"
                        }
                        html += "</tr>\n"
                    }

                    i += 1
                }
                html += "</table>\n"
                i -= 1
            }
            // Headings
            else if line.hasPrefix("# ") {
                if inList { html += "</ul>\n"; inList = false }
                html += "<h1>\(formatInlineMarkdown(String(line.dropFirst(2))))</h1>\n"
            }
            else if line.hasPrefix("## ") {
                if inList { html += "</ul>\n"; inList = false }
                html += "<h2>\(formatInlineMarkdown(String(line.dropFirst(3))))</h2>\n"
            }
            else if line.hasPrefix("### ") {
                if inList { html += "</ul>\n"; inList = false }
                html += "<h3>\(formatInlineMarkdown(String(line.dropFirst(4))))</h3>\n"
            }
            else if line.hasPrefix("#### ") {
                if inList { html += "</ul>\n"; inList = false }
                html += "<h4>\(formatInlineMarkdown(String(line.dropFirst(5))))</h4>\n"
            }
            // Lists
            else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                if !inList {
                    html += "<ul>\n"
                    inList = true
                }
                let itemText = String(line.dropFirst(2))

                // Handle checkboxes
                if itemText.hasPrefix("[ ] ") {
                    html += "<li>☐ \(formatInlineMarkdown(String(itemText.dropFirst(4))))</li>\n"
                } else if itemText.hasPrefix("[x] ") || itemText.hasPrefix("[X] ") {
                    html += "<li>☑ \(formatInlineMarkdown(String(itemText.dropFirst(4))))</li>\n"
                } else {
                    html += "<li>\(formatInlineMarkdown(itemText))</li>\n"
                }
            }
            // Empty line
            else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if inList {
                    html += "</ul>\n"
                    inList = false
                }
            }
            // Regular paragraph
            else if !line.isEmpty {
                if inList {
                    html += "</ul>\n"
                    inList = false
                }
                html += "<p>\(formatInlineMarkdown(line))</p>\n"
            }

            i += 1
        }

        // Close any open tags
        if inList {
            html += "</ul>\n"
        }
        if inCodeBlock {
            html += "</code></pre>\n"
        }

        return html
    }

    private func formatInlineMarkdown(_ text: String) -> String {
        var result = text

        // Bold **text**
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

        return result
    }

    private func escapeHTML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
