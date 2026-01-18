import AppKit

class PrintManager {
    static let shared = PrintManager()

    private init() {}

    func print(content: String, fileName: String) {
        // Create an attributed string from the markdown content
        let attributedString = buildPrintableAttributedString(from: content)

        // Create a text view for printing
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648)) // US Letter minus 1" margins
        textView.textStorage?.setAttributedString(attributedString)
        textView.textContainerInset = NSSize(width: 0, height: 0)

        // Size to fit content
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            let usedRect = layoutManager.usedRect(for: textContainer)
            textView.frame = NSRect(x: 0, y: 0, width: 468, height: max(648, usedRect.height + 40))
        }

        // Configure print info
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.topMargin = 72
        printInfo.bottomMargin = 72
        printInfo.leftMargin = 72
        printInfo.rightMargin = 72
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false

        // Set job name
        printInfo.jobDisposition = .spool
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobDisposition] = NSPrintInfo.JobDisposition.spool

        // Create print operation
        let printOperation = NSPrintOperation(view: textView, printInfo: printInfo)
        printOperation.jobTitle = fileName
        printOperation.showsPrintPanel = true
        printOperation.showsProgressPanel = true

        // Run the print operation
        printOperation.run()
    }

    private func buildPrintableAttributedString(from content: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = content.components(separatedBy: .newlines)
        var i = 0

        let baseFont = NSFont.systemFont(ofSize: 11)
        let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.black
        ]

        // Skip YAML frontmatter if present
        if lines.first == "---" {
            i = 1
            while i < lines.count && lines[i] != "---" {
                i += 1
            }
            if i < lines.count && lines[i] == "---" {
                i += 1
            } else {
                i = 0
            }
        }

        while i < lines.count {
            let line = lines[i]

            // Headings
            if line.hasPrefix("#### ") {
                appendHeading(text: String(line.dropFirst(5)), level: 4, to: result)
            } else if line.hasPrefix("### ") {
                appendHeading(text: String(line.dropFirst(4)), level: 3, to: result)
            } else if line.hasPrefix("## ") {
                appendHeading(text: String(line.dropFirst(3)), level: 2, to: result)
            } else if line.hasPrefix("# ") {
                appendHeading(text: String(line.dropFirst(2)), level: 1, to: result)
            }
            // Horizontal rule
            else if isHorizontalRule(line) {
                appendHorizontalRule(to: result)
            }
            // Blockquote
            else if line.hasPrefix("> ") {
                var quoteLines: [String] = []
                while i < lines.count && lines[i].hasPrefix("> ") {
                    quoteLines.append(String(lines[i].dropFirst(2)))
                    i += 1
                }
                appendBlockquote(text: quoteLines.joined(separator: "\n"), to: result)
                i -= 1
            }
            // List items
            else if isListLine(line) {
                appendListItem(line: line, to: result)
            }
            // Code block
            else if line.hasPrefix("```") {
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                appendCodeBlock(code: codeLines.joined(separator: "\n"), to: result)
            }
            // Table
            else if line.hasPrefix("|") && line.hasSuffix("|") {
                var tableRows: [[String]] = []
                while i < lines.count && lines[i].hasPrefix("|") {
                    let currentLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if !isTableSeparator(currentLine) {
                        let cells = currentLine
                            .split(separator: "|")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        if !cells.isEmpty {
                            tableRows.append(cells)
                        }
                    }
                    i += 1
                }
                if !tableRows.isEmpty {
                    appendTable(rows: tableRows, to: result)
                }
                i -= 1
            }
            // Empty line
            else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(NSAttributedString(string: "\n", attributes: defaultAttributes))
            }
            // Regular paragraph
            else if !line.isEmpty {
                appendParagraph(text: line, to: result)
            }

            i += 1
        }

        return result
    }

    private func appendHeading(text: String, level: Int, to result: NSMutableAttributedString) {
        let sizes: [Int: CGFloat] = [1: 18, 2: 16, 3: 14, 4: 12]
        let size = sizes[level] ?? 11
        let font = NSFont.boldSystemFont(ofSize: size)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = level == 1 ? 16 : (level == 2 ? 12 : 8)
        paragraphStyle.paragraphSpacing = 4

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle
        ]

        let formatted = formatInlineMarkdown(text, attributes: attributes)
        result.append(formatted)
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendParagraph(text: String, to result: NSMutableAttributedString) {
        let font = NSFont.systemFont(ofSize: 11)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 6
        paragraphStyle.lineSpacing = 2

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle
        ]

        let formatted = formatInlineMarkdown(text, attributes: attributes)
        result.append(formatted)
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendListItem(line: String, to result: NSMutableAttributedString) {
        let font = NSFont.systemFont(ofSize: 11)

        // Count leading spaces for indentation level
        var level = 0
        for char in line {
            if char == " " {
                level += 1
            } else if char == "\t" {
                level += 4
            } else {
                break
            }
        }
        let nestLevel = level / 2

        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        var itemText = trimmed

        // Remove bullet marker
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            itemText = String(trimmed.dropFirst(2))
        } else if let match = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            itemText = String(trimmed[match.upperBound...])
        }

        let baseIndent: CGFloat = 18
        let levelIndent: CGFloat = CGFloat(nestLevel) * 14

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.headIndent = baseIndent + levelIndent + 16
        paragraphStyle.firstLineHeadIndent = baseIndent + levelIndent
        paragraphStyle.paragraphSpacing = 2

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle
        ]

        let bullets = ["•", "◦", "▪"]
        let bullet = bullets[min(nestLevel, bullets.count - 1)]

        result.append(NSAttributedString(string: "\(bullet)  ", attributes: attributes))
        let formatted = formatInlineMarkdown(itemText, attributes: attributes)
        result.append(formatted)
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendCodeBlock(code: String, to result: NSMutableAttributedString) {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = 4
        paragraphStyle.paragraphSpacing = 4

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .backgroundColor: NSColor.lightGray.withAlphaComponent(0.2),
            .paragraphStyle: paragraphStyle
        ]

        result.append(NSAttributedString(string: code + "\n", attributes: attributes))
    }

    private func appendBlockquote(text: String, to result: NSMutableAttributedString) {
        let font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.headIndent = 18
        paragraphStyle.firstLineHeadIndent = 18
        paragraphStyle.paragraphSpacingBefore = 4
        paragraphStyle.paragraphSpacing = 4

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.darkGray,
            .paragraphStyle: paragraphStyle
        ]

        result.append(NSAttributedString(string: text + "\n", attributes: attributes))
    }

    private func appendTable(rows: [[String]], to result: NSMutableAttributedString) {
        let font = NSFont.systemFont(ofSize: 10)
        let boldFont = NSFont.boldSystemFont(ofSize: 10)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = 4
        paragraphStyle.paragraphSpacing = 4

        for (rowIndex, row) in rows.enumerated() {
            let isHeader = rowIndex == 0
            let rowFont = isHeader ? boldFont : font
            let rowText = row.joined(separator: "  |  ")

            let attributes: [NSAttributedString.Key: Any] = [
                .font: rowFont,
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraphStyle
            ]

            result.append(NSAttributedString(string: "  " + rowText + "\n", attributes: attributes))

            if isHeader {
                let separator = String(repeating: "─", count: rowText.count)
                result.append(NSAttributedString(string: "  " + separator + "\n", attributes: [
                    .font: font,
                    .foregroundColor: NSColor.gray
                ]))
            }
        }
    }

    private func appendHorizontalRule(to result: NSMutableAttributedString) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = 8
        paragraphStyle.paragraphSpacing = 8

        let rule = String(repeating: "─", count: 50)
        result.append(NSAttributedString(string: rule + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.gray,
            .paragraphStyle: paragraphStyle
        ]))
    }

    private func formatInlineMarkdown(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        let baseFont = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 11)

        // Bold **text**
        applyPattern(#"\*\*(.+?)\*\*"#, to: result, attributes: [.font: NSFont.boldSystemFont(ofSize: baseFont.pointSize)])

        // Italic *text*
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        applyPattern(#"\*(.+?)\*"#, to: result, attributes: [.font: italicFont])

        // Strikethrough ~~text~~
        applyPattern(#"~~(.+?)~~"#, to: result, attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue])

        // Inline code `text`
        applyPattern(#"`(.+?)`"#, to: result, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular),
            .backgroundColor: NSColor.lightGray.withAlphaComponent(0.2)
        ])

        // Links [text](url) - just show the text
        applyLinkPattern(to: result)

        return result
    }

    private func applyPattern(_ pattern: String, to result: NSMutableAttributedString, attributes: [NSAttributedString.Key: Any]) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let string = result.string as NSString

        let matches = regex.matches(in: result.string, range: NSRange(location: 0, length: string.length)).reversed()

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let fullRange = match.range(at: 0)
            let contentRange = match.range(at: 1)

            let content = string.substring(with: contentRange)
            var newAttributes = result.attributes(at: contentRange.location, effectiveRange: nil)
            for (key, value) in attributes {
                newAttributes[key] = value
            }

            result.replaceCharacters(in: fullRange, with: NSAttributedString(string: content, attributes: newAttributes))
        }
    }

    private func applyLinkPattern(to result: NSMutableAttributedString) {
        let pattern = #"\[(.+?)\]\((.+?)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let string = result.string as NSString

        let matches = regex.matches(in: result.string, range: NSRange(location: 0, length: string.length)).reversed()

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let fullRange = match.range(at: 0)
            let textRange = match.range(at: 1)

            let text = string.substring(with: textRange)
            var attributes = result.attributes(at: textRange.location, effectiveRange: nil)
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue

            result.replaceCharacters(in: fullRange, with: NSAttributedString(string: text, attributes: attributes))
        }
    }

    private func isListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") ||
               trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"^([-_*])\1{2,}$"#, options: .regularExpression) != nil
    }

    private func isTableSeparator(_ line: String) -> Bool {
        let withoutPipes = line.replacingOccurrences(of: "|", with: "")
        let withoutDashes = withoutPipes.replacingOccurrences(of: "-", with: "")
        let withoutColons = withoutDashes.replacingOccurrences(of: ":", with: "")
        let withoutSpaces = withoutColons.trimmingCharacters(in: .whitespaces)
        return withoutSpaces.isEmpty && line.contains("-")
    }
}
