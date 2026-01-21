import SwiftUI
import AppKit

/// NSTextView-based markdown renderer with full text selection support
struct MarkdownTextView: NSViewRepresentable {
    let content: String
    let baseURL: URL?
    @Binding var scrollToHeadingId: String?
    let searchText: String
    let currentMatchIndex: Int
    let searchMatches: [SearchMatch]
    let fontStyle: SettingsManager.FontStyle
    let initialScrollPosition: CGFloat
    let onScrollPositionChanged: ((CGFloat) -> Void)?
    let onMatchCountChanged: ((Int) -> Void)?

    init(content: String, baseURL: URL?, scrollToHeadingId: Binding<String?>, searchText: String, currentMatchIndex: Int, searchMatches: [SearchMatch], fontStyle: SettingsManager.FontStyle, initialScrollPosition: CGFloat = 0, onScrollPositionChanged: ((CGFloat) -> Void)? = nil, onMatchCountChanged: ((Int) -> Void)? = nil) {
        self.content = content
        self.baseURL = baseURL
        self._scrollToHeadingId = scrollToHeadingId
        self.searchText = searchText
        self.currentMatchIndex = currentMatchIndex
        self.searchMatches = searchMatches
        self.fontStyle = fontStyle
        self.initialScrollPosition = initialScrollPosition
        self.onScrollPositionChanged = onScrollPositionChanged
        self.onMatchCountChanged = onMatchCountChanged
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        // Configure text view
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 50, height: 40)
        textView.isRichText = true
        textView.allowsUndo = false

        // Set max width for content
        textView.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        // Store reference for coordinator
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.onScrollPositionChanged = onScrollPositionChanged
        context.coordinator.onMatchCountChanged = onMatchCountChanged

        // Set up scroll notification
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Check if content changed
        let contentChanged = context.coordinator.lastContent != content
        let searchChanged = context.coordinator.lastSearchText != searchText
        let matchIndexChanged = context.coordinator.lastMatchIndex != currentMatchIndex

        // Build attributed string from markdown (when content or search changes)
        if contentChanged || searchChanged {
            let attributedString = buildAttributedString()
            textView.textStorage?.setAttributedString(attributedString)
            context.coordinator.lastContent = content
            context.coordinator.lastSearchText = searchText

            // Find and store all match ranges in the rendered text
            if !searchText.isEmpty {
                context.coordinator.findMatchRanges(for: searchText, in: textView)
            } else {
                context.coordinator.matchRanges = []
            }

            // Restore scroll position after content is set (only if not searching)
            DispatchQueue.main.async {
                if initialScrollPosition > 10 && searchText.isEmpty {
                    // Restore saved position
                    context.coordinator.restoreScrollPosition(initialScrollPosition, in: scrollView)
                } else if searchText.isEmpty {
                    // Scroll to top for new documents
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }

            // Scroll to first match if searching
            if !searchText.isEmpty && !context.coordinator.matchRanges.isEmpty {
                DispatchQueue.main.async {
                    context.coordinator.scrollToMatch(at: currentMatchIndex, in: textView)
                }
            }
        }

        // Handle match navigation (scroll and update highlight)
        if matchIndexChanged && !searchText.isEmpty {
            context.coordinator.lastMatchIndex = currentMatchIndex
            context.coordinator.updateMatchHighlighting(currentIndex: currentMatchIndex, in: textView, searchText: searchText)
            context.coordinator.scrollToMatch(at: currentMatchIndex, in: textView)
        }

        // Handle scroll to heading
        if let headingId = scrollToHeadingId {
            DispatchQueue.main.async {
                context.coordinator.scrollToHeading(id: headingId, in: textView)
                scrollToHeadingId = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var textView: NSTextView?
        var scrollView: NSScrollView?
        var headingRanges: [String: NSRange] = [:]
        var lastContent: String?
        var lastSearchText: String?
        var lastMatchIndex: Int = -1
        var matchRanges: [NSRange] = []
        var onScrollPositionChanged: ((CGFloat) -> Void)?
        var onMatchCountChanged: ((Int) -> Void)?
        private var scrollDebounceTimer: Timer?

        func scrollToHeading(id: String, in textView: NSTextView) {
            if let range = headingRanges[id] {
                textView.scrollRangeToVisible(range)
                // Briefly highlight the heading
                textView.setSelectedRange(range)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    textView.setSelectedRange(NSRange(location: range.location, length: 0))
                }
            }
        }

        func restoreScrollPosition(_ position: CGFloat, in scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            let maxScroll = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
            let clampedPosition = min(position, maxScroll)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedPosition))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // MARK: - Search Methods

        func findMatchRanges(for searchText: String, in textView: NSTextView) {
            matchRanges = []
            guard let storage = textView.textStorage, !searchText.isEmpty else {
                onMatchCountChanged?(0)
                return
            }

            let string = storage.string as NSString
            var searchRange = NSRange(location: 0, length: string.length)

            while searchRange.location < string.length {
                let range = string.range(of: searchText, options: .caseInsensitive, range: searchRange)
                guard range.location != NSNotFound else { break }

                matchRanges.append(range)
                searchRange.location = range.location + range.length
                searchRange.length = string.length - searchRange.location
            }

            // Report match count back
            onMatchCountChanged?(matchRanges.count)
        }

        func scrollToMatch(at index: Int, in textView: NSTextView) {
            guard index >= 0 && index < matchRanges.count else { return }
            let range = matchRanges[index]

            // Clear any selection so it doesn't override the yellow highlight
            textView.setSelectedRange(NSRange(location: range.location, length: 0))

            // Get the rect for this text range
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                textView.scrollRangeToVisible(range)
                return
            }

            // Get the bounding rect for the match
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let matchRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

            // Adjust for text container inset
            let inset = textView.textContainerInset
            let adjustedRect = NSRect(
                x: matchRect.origin.x + inset.width,
                y: matchRect.origin.y + inset.height,
                width: matchRect.width,
                height: matchRect.height
            )

            // Get the scroll view and its visible height
            guard let scrollView = textView.enclosingScrollView else {
                textView.scrollRangeToVisible(range)
                return
            }

            let visibleHeight = scrollView.contentView.bounds.height

            // Calculate scroll position to center the match vertically
            let targetY = adjustedRect.origin.y - (visibleHeight / 2) + (adjustedRect.height / 2)
            let maxY = max(0, textView.frame.height - visibleHeight)
            let clampedY = min(max(0, targetY), maxY)

            // Scroll to center the match
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func updateMatchHighlighting(currentIndex: Int, in textView: NSTextView, searchText: String) {
            guard let storage = textView.textStorage else { return }

            // Remove all previous yellow highlighting
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.backgroundColor, range: fullRange)

            // Re-apply highlighting to all matches
            for (index, range) in matchRanges.enumerated() {
                let isCurrent = index == currentIndex
                // Use bright orange for current match, light yellow for others
                let bgColor = isCurrent ? NSColor.systemOrange : NSColor.systemYellow.withAlphaComponent(0.5)

                storage.addAttributes([
                    .backgroundColor: bgColor,
                    .foregroundColor: NSColor.black
                ], range: range)
            }
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }

            // Debounce scroll position saving
            scrollDebounceTimer?.invalidate()
            scrollDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                let position = clipView.bounds.origin.y
                self?.onScrollPositionChanged?(position)
            }
        }

        deinit {
            scrollDebounceTimer?.invalidate()
            NotificationCenter.default.removeObserver(self)
        }
    }

    // MARK: - Build Attributed String

    private func buildAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = content.components(separatedBy: .newlines)
        var i = 0
        var listItems: [(level: Int, text: String)] = []
        var headingRanges: [String: NSRange] = [:]

        let baseFont = fontStyle.nsFont(size: 16)
        let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: defaultParagraphStyle()
        ]

        // Check for YAML frontmatter at start of document
        if lines.first == "---" {
            var frontmatterLines: [String] = []
            i = 1
            while i < lines.count && lines[i] != "---" {
                frontmatterLines.append(lines[i])
                i += 1
            }
            if i < lines.count && lines[i] == "---" {
                // Found complete frontmatter block
                appendFrontmatter(lines: frontmatterLines, to: result)
                i += 1  // Skip closing ---
            } else {
                // Incomplete frontmatter, treat as regular content
                i = 0
            }
        }

        while i < lines.count {
            let line = lines[i]

            // End list if we hit a non-list item
            if !isListLine(line) && !listItems.isEmpty {
                appendList(items: listItems, to: result)
                listItems = []
            }

            // Headings
            if line.hasPrefix("#### ") {
                let text = String(line.dropFirst(5))
                let range = NSRange(location: result.length, length: 0)
                appendHeading(text: text, level: 4, to: result)
                headingRanges["heading-\(i)"] = NSRange(location: range.location, length: result.length - range.location)
            } else if line.hasPrefix("### ") {
                let text = String(line.dropFirst(4))
                let range = NSRange(location: result.length, length: 0)
                appendHeading(text: text, level: 3, to: result)
                headingRanges["heading-\(i)"] = NSRange(location: range.location, length: result.length - range.location)
            } else if line.hasPrefix("## ") {
                let text = String(line.dropFirst(3))
                let range = NSRange(location: result.length, length: 0)
                appendHeading(text: text, level: 2, to: result)
                headingRanges["heading-\(i)"] = NSRange(location: range.location, length: result.length - range.location)
            } else if line.hasPrefix("# ") {
                let text = String(line.dropFirst(2))
                let range = NSRange(location: result.length, length: 0)
                appendHeading(text: text, level: 1, to: result)
                headingRanges["heading-\(i)"] = NSRange(location: range.location, length: result.length - range.location)
            }
            // Horizontal rule
            else if isHorizontalRule(line) {
                appendHorizontalRule(to: result)
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
            // List items (supports nesting via indentation)
            else if isListLine(line) {
                let item = extractListItemText(line)
                listItems.append(item)
            }
            // Code block with optional language
            else if line.hasPrefix("```") {
                // Extract language identifier (e.g., ```swift -> "swift")
                let language = line.count > 3 ? String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) : nil
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                appendCodeBlock(code: codeLines.joined(separator: "\n"), language: language, to: result)
            }
            // Empty line
            else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !listItems.isEmpty {
                    appendList(items: listItems, to: result)
                    listItems = []
                }
                result.append(NSAttributedString(string: "\n", attributes: defaultAttributes))
            }
            // Image (show alt text or placeholder)
            else if line.range(of: #"!\[([^\]]*)\]\(([^\)]+)\)"#, options: .regularExpression) != nil {
                appendImage(line: line, to: result)
            }
            // Regular paragraph
            else if !line.isEmpty {
                appendParagraph(text: line, to: result)
            }

            i += 1
        }

        // Add remaining list items
        if !listItems.isEmpty {
            appendList(items: listItems, to: result)
        }

        // Apply search highlighting
        applySearchHighlighting(to: result)

        return result
    }

    // MARK: - Append Methods

    private func appendHeading(text: String, level: Int, to result: NSMutableAttributedString) {
        let sizes: [Int: CGFloat] = [1: 28, 2: 24, 3: 20, 4: 18]
        let size = sizes[level] ?? 16
        let font = fontStyle.nsFont(size: size).withWeight(.semibold)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = level == 1 ? 24 : (level == 2 ? 20 : 16)
        paragraphStyle.paragraphSpacing = level == 1 ? 12 : 8

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle
        ]

        let formatted = formatInlineMarkdown(text, attributes: attributes)
        result.append(formatted)
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendParagraph(text: String, to result: NSMutableAttributedString) {
        let font = fontStyle.nsFont(size: 16)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 10
        paragraphStyle.lineSpacing = 4

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle
        ]

        let formatted = formatInlineMarkdown(text, attributes: attributes)
        result.append(formatted)
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendList(items: [(level: Int, text: String)], to result: NSMutableAttributedString) {
        let font = fontStyle.nsFont(size: 16)

        for (level, text) in items {
            // Calculate indentation based on nesting level
            let baseIndent: CGFloat = 16
            let levelIndent: CGFloat = CGFloat(level) * 20

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.headIndent = baseIndent + levelIndent + 24
            paragraphStyle.firstLineHeadIndent = baseIndent + levelIndent
            paragraphStyle.paragraphSpacing = 3
            paragraphStyle.lineSpacing = 3

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraphStyle
            ]

            // Determine bullet style based on nesting level
            let bullets = ["•", "◦", "▪", "▹"]
            let bullet = bullets[min(level, bullets.count - 1)]

            var bulletPrefix = "\(bullet)  "
            var itemText = text

            // Check for task list items
            if text.hasPrefix("[ ] ") {
                bulletPrefix = "☐  "
                itemText = String(text.dropFirst(4))
            } else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                bulletPrefix = "☑  "
                itemText = String(text.dropFirst(4))
            }

            let bulletAttr = NSAttributedString(string: bulletPrefix, attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle
            ])
            result.append(bulletAttr)

            let formatted = formatInlineMarkdown(itemText, attributes: attributes)
            result.append(formatted)
            result.append(NSAttributedString(string: "\n"))
        }
    }

    private func appendFrontmatter(lines: [String], to result: NSMutableAttributedString) {
        guard !lines.isEmpty else { return }

        let titleFont = fontStyle.nsFont(size: 11).withWeight(.semibold)
        let keyFont = fontStyle.nsFont(size: 12).withWeight(.medium)
        let valueFont = fontStyle.nsFont(size: 12)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 2
        paragraphStyle.lineSpacing = 2

        // Header
        result.append(NSAttributedString(string: "DOCUMENT INFO\n", attributes: [
            .font: titleFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]))

        // Parse and display key-value pairs
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let colonIndex = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

                result.append(NSAttributedString(string: "\(key): ", attributes: [
                    .font: keyFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraphStyle
                ]))
                result.append(NSAttributedString(string: "\(value)\n", attributes: [
                    .font: valueFont,
                    .foregroundColor: NSColor.textColor,
                    .paragraphStyle: paragraphStyle
                ]))
            } else {
                // Line without colon, just display it
                result.append(NSAttributedString(string: "\(trimmed)\n", attributes: [
                    .font: valueFont,
                    .foregroundColor: NSColor.textColor,
                    .paragraphStyle: paragraphStyle
                ]))
            }
        }

        // Add separator line after frontmatter
        let separatorStyle = NSMutableParagraphStyle()
        separatorStyle.paragraphSpacingBefore = 8
        separatorStyle.paragraphSpacing = 16

        result.append(NSAttributedString(string: String(repeating: "─", count: 40) + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.separatorColor,
            .paragraphStyle: separatorStyle
        ]))
    }

    private func appendCodeBlock(code: String, language: String? = nil, to result: NSMutableAttributedString) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = 8
        paragraphStyle.paragraphSpacing = 8

        // Apply syntax highlighting
        let highlighted = SyntaxHighlighter.shared.highlight(code: code, language: language)
        let mutableHighlighted = NSMutableAttributedString(attributedString: highlighted)

        // Add background color and paragraph style to entire block
        let fullRange = NSRange(location: 0, length: mutableHighlighted.length)
        mutableHighlighted.addAttributes([
            .backgroundColor: NSColor.separatorColor.withAlphaComponent(0.08),
            .paragraphStyle: paragraphStyle
        ], range: fullRange)

        result.append(mutableHighlighted)
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendBlockquote(text: String, to result: NSMutableAttributedString) {
        let font = fontStyle.nsFont(size: 16).withTraits(.italic)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.headIndent = 20
        paragraphStyle.firstLineHeadIndent = 20
        paragraphStyle.paragraphSpacingBefore = 8
        paragraphStyle.paragraphSpacing = 8

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]

        result.append(NSAttributedString(string: "  " + text + "\n", attributes: attributes))
    }

    private func appendTable(rows: [[String]], to result: NSMutableAttributedString) {
        let font = fontStyle.nsFont(size: 14)
        let boldFont = font.withWeight(.medium)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = 8
        paragraphStyle.paragraphSpacing = 8

        for (rowIndex, row) in rows.enumerated() {
            let isHeader = rowIndex == 0
            let rowFont = isHeader ? boldFont : font
            let rowText = row.joined(separator: "  |  ")

            let attributes: [NSAttributedString.Key: Any] = [
                .font: rowFont,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraphStyle
            ]

            result.append(NSAttributedString(string: "  " + rowText + "\n", attributes: attributes))

            if isHeader {
                let separator = String(repeating: "─", count: rowText.count)
                result.append(NSAttributedString(string: "  " + separator + "\n", attributes: [
                    .font: font,
                    .foregroundColor: NSColor.separatorColor
                ]))
            }
        }
    }

    private func appendHorizontalRule(to result: NSMutableAttributedString) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = 16
        paragraphStyle.paragraphSpacing = 16

        let rule = String(repeating: "─", count: 60)
        result.append(NSAttributedString(string: rule + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.separatorColor,
            .paragraphStyle: paragraphStyle
        ]))
    }

    private func appendImage(line: String, to result: NSMutableAttributedString) {
        // Extract alt text and path
        if let match = line.range(of: #"!\[([^\]]*)\]\(([^\)]+)\)"#, options: .regularExpression) {
            let matchedString = String(line[match])
            if let altRange = matchedString.range(of: #"\[([^\]]*)\]"#, options: .regularExpression),
               let pathRange = matchedString.range(of: #"\(([^\)]+)\)"#, options: .regularExpression) {
                let alt = String(matchedString[altRange].dropFirst().dropLast())
                let path = String(matchedString[pathRange].dropFirst().dropLast())

                // Try to load and embed the image
                if let image = loadImage(path: path) {
                    let attachment = NSTextAttachment()
                    let maxWidth: CGFloat = 700
                    let scale = min(1.0, maxWidth / image.size.width)
                    let newSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)

                    image.size = newSize
                    attachment.image = image

                    let imageString = NSAttributedString(attachment: attachment)
                    result.append(NSAttributedString(string: "\n"))
                    result.append(imageString)
                    result.append(NSAttributedString(string: "\n\n"))
                } else {
                    // Show placeholder for missing image
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: fontStyle.nsFont(size: 14),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                    result.append(NSAttributedString(string: "[Image: \(alt.isEmpty ? path : alt)]\n", attributes: attributes))
                }
            }
        }
    }

    private func loadImage(path: String) -> NSImage? {
        // Remote URL
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            if let url = URL(string: path), let image = NSImage(contentsOf: url) {
                return image
            }
            return nil
        }

        // Absolute path
        let absoluteURL = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: absoluteURL.path) {
            return NSImage(contentsOf: absoluteURL)
        }

        // Relative to document
        if let base = baseURL?.deletingLastPathComponent() {
            let relativeURL = base.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: relativeURL.path) {
                return NSImage(contentsOf: relativeURL)
            }
        }

        return nil
    }

    // MARK: - Inline Formatting

    private func formatInlineMarkdown(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        let baseFont = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 16)

        // Bold **text**
        applyPattern(#"\*\*(.+?)\*\*"#, to: result, attributes: [.font: baseFont.withWeight(.bold)])

        // Italic *text*
        applyPattern(#"\*(.+?)\*"#, to: result, attributes: [.font: baseFont.withTraits(.italic)])

        // Strikethrough ~~text~~
        applyPattern(#"~~(.+?)~~"#, to: result, attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue])

        // Inline code `text`
        applyPattern(#"`(.+?)`"#, to: result, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular),
            .backgroundColor: NSColor.separatorColor.withAlphaComponent(0.15)
        ])

        // Links [text](url)
        applyLinkPattern(to: result)

        return result
    }

    private func applyPattern(_ pattern: String, to result: NSMutableAttributedString, attributes: [NSAttributedString.Key: Any]) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let string = result.string as NSString

        // Find all matches in reverse order to preserve indices when modifying
        let matches = regex.matches(in: result.string, range: NSRange(location: 0, length: string.length)).reversed()

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let fullRange = match.range(at: 0)
            let contentRange = match.range(at: 1)

            // Get the content text
            let content = string.substring(with: contentRange)

            // Get existing attributes and merge
            var newAttributes = result.attributes(at: contentRange.location, effectiveRange: nil)
            for (key, value) in attributes {
                newAttributes[key] = value
            }

            // Replace the full match with just the content, applying new attributes
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
            let urlRange = match.range(at: 2)

            let text = string.substring(with: textRange)
            let url = string.substring(with: urlRange)

            var attributes = result.attributes(at: textRange.location, effectiveRange: nil)
            attributes[.link] = URL(string: url)
            attributes[.foregroundColor] = NSColor.linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue

            result.replaceCharacters(in: fullRange, with: NSAttributedString(string: text, attributes: attributes))
        }
    }

    // MARK: - Search Highlighting

    private func applySearchHighlighting(to result: NSMutableAttributedString) {
        guard !searchText.isEmpty else { return }

        let string = result.string as NSString
        var searchRange = NSRange(location: 0, length: string.length)
        var matchIndex = 0

        while searchRange.location < string.length {
            let range = string.range(of: searchText, options: .caseInsensitive, range: searchRange)
            guard range.location != NSNotFound else { break }

            let isCurrent = matchIndex == currentMatchIndex
            // Use bright orange for current match, light yellow for others
            let bgColor = isCurrent ? NSColor.systemOrange : NSColor.systemYellow.withAlphaComponent(0.5)

            result.addAttributes([
                .backgroundColor: bgColor,
                .foregroundColor: NSColor.black
            ], range: range)

            searchRange.location = range.location + range.length
            searchRange.length = string.length - searchRange.location
            matchIndex += 1
        }
    }

    // MARK: - Helpers

    private func defaultParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 8
        return style
    }

    private func isListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") ||
               trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil
    }

    private func extractListItemText(_ line: String) -> (level: Int, text: String) {
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
        // Convert spaces to level (every 2-4 spaces = 1 level)
        let nestLevel = level / 2

        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return (nestLevel, String(trimmed.dropFirst(2)))
        }
        if let match = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            return (nestLevel, String(trimmed[match.upperBound...]))
        }
        return (nestLevel, trimmed)
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

// MARK: - NSFont Extensions

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight]
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }

    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: - SettingsManager NSFont Extension

extension SettingsManager.FontStyle {
    func nsFont(size: CGFloat) -> NSFont {
        switch self {
        case .system:
            return NSFont.systemFont(ofSize: size)
        case .serif:
            return NSFont(name: "New York", size: size) ?? NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size)
        case .monospace:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}
