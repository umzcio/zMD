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
        // Route through MarkdownParser.shared so Print, PDF, HTML, DOCX, RTF, and the live
        // preview all consume the same element tree. Previously this re-implemented markdown
        // parsing line-by-line and diverged from the unified parser — headings capped at H4,
        // no frontmatter support, no Mermaid/math handling, opening fence with language tag
        // could be mis-detected as a closing fence.
        let result = NSMutableAttributedString()
        let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ]

        let elements = MarkdownParser.shared.parse(content)

        for element in elements {
            switch element {
            case .heading1(let text): appendHeading(text: text, level: 1, to: result)
            case .heading2(let text): appendHeading(text: text, level: 2, to: result)
            case .heading3(let text): appendHeading(text: text, level: 3, to: result)
            case .heading4(let text): appendHeading(text: text, level: 4, to: result)
            case .heading5(let text): appendHeading(text: text, level: 4, to: result)  // print caps at 4 sizes
            case .heading6(let text): appendHeading(text: text, level: 4, to: result)
            case .paragraph(let text): appendParagraph(text: text, to: result)
            case .frontmatter: break // skip in print output
            case .list(let items):
                // Per-level ordered counter, seeded by each item's startNumber on first occurrence
                // at that level. Without this, every ordered list printed as `1. 1. 1.`.
                var orderedCounters: [Int: Int] = [:]
                for item in items {
                    var explicitNumber: Int? = nil
                    if item.isOrdered {
                        let counter: Int
                        if let existing = orderedCounters[item.level] {
                            counter = existing + 1
                        } else if let start = item.startNumber {
                            counter = start
                        } else {
                            counter = 1
                        }
                        orderedCounters[item.level] = counter
                        explicitNumber = counter
                    }
                    appendListItem(level: item.level, text: item.text, isOrdered: item.isOrdered, number: explicitNumber, to: result)
                }
            case .codeBlock(let code, _): appendCodeBlock(code: code, to: result)
            case .mermaidBlock(let code): appendCodeBlock(code: "[mermaid]\n" + code, to: result)
            case .displayMath(let latex): appendCodeBlock(code: "[math]\n" + latex, to: result)
            case .table(let rows): appendTable(rows: rows, to: result)
            case .image(let alt, let path):
                appendParagraph(text: "[Image: \(alt.isEmpty ? path : alt)]", to: result)
            case .horizontalRule: appendHorizontalRule(to: result)
            case .blockquote(let text): appendBlockquote(text: text, to: result)
            case .htmlBlock(let html): appendParagraph(text: html, to: result)
            }
            result.append(NSAttributedString(string: "\n", attributes: defaultAttributes))
        }

        return result
    }

    private func appendListItem(level: Int, text: String, isOrdered: Bool, number: Int?, to result: NSMutableAttributedString) {
        // Construct the raw line the old helper expected so bullet/indent math stays identical.
        let indent = String(repeating: "  ", count: level)
        let marker = isOrdered ? "\(number ?? 1). " : "- "
        appendListItem(line: indent + marker + text, to: result)
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
            .foregroundColor: NSColor.labelColor,
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
            .foregroundColor: NSColor.labelColor,
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
        var orderedMarker: String?

        // Remove bullet marker
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            itemText = String(trimmed.dropFirst(2))
        } else if let match = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            orderedMarker = String(trimmed[match]).trimmingCharacters(in: .whitespaces)
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
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]

        let bullets = ["•", "◦", "▪"]
        let marker = orderedMarker ?? bullets[min(nestLevel, bullets.count - 1)]

        result.append(NSAttributedString(string: "\(marker)  ", attributes: attributes))
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
            .foregroundColor: NSColor.labelColor,
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
                .foregroundColor: NSColor.labelColor,
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
        let baseFont = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 11)
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        let result = NSMutableAttributedString()

        for token in InlineMarkdown.tokenize(text) {
            var tokenAttributes = attributes
            let value: String

            switch token {
            case .text(let text):
                value = text
            case .lineBreak:
                value = "\n"
            case .code(let text):
                value = text
                tokenAttributes[.font] = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
                tokenAttributes[.backgroundColor] = NSColor.lightGray.withAlphaComponent(0.2)
            case .math(let text):
                value = "$\(text)$"
            case .strong(let text):
                tokenAttributes[.font] = NSFont.boldSystemFont(ofSize: baseFont.pointSize)
                result.append(formatInlineMarkdown(text, attributes: tokenAttributes))
                continue
            case .emphasis(let text):
                tokenAttributes[.font] = italicFont
                result.append(formatInlineMarkdown(text, attributes: tokenAttributes))
                continue
            case .strikethrough(let text):
                tokenAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                result.append(formatInlineMarkdown(text, attributes: tokenAttributes))
                continue
            case .image(let alt, let source):
                value = "[Image: \(alt.isEmpty ? source : alt)]"
            case .link(let label, _):
                result.append(formatInlineMarkdown(label, attributes: tokenAttributes))
                continue
            }

            result.append(NSAttributedString(string: value, attributes: tokenAttributes))
        }
        return result
    }

}
