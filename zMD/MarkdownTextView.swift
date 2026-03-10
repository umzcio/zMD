import SwiftUI
import AppKit

/// NSTextView-based markdown renderer with full text selection support
struct MarkdownTextView: NSViewRepresentable {
    let content: String
    let baseURL: URL?
    let directoryBookmark: Data?
    @Binding var scrollToHeadingId: String?
    let searchText: String
    let currentMatchIndex: Int
    let searchMatches: [SearchMatch]
    let fontStyle: SettingsManager.FontStyle
    let zoomLevel: CGFloat
    let initialScrollPosition: CGFloat
    let onScrollPositionChanged: ((CGFloat) -> Void)?
    let onMatchCountChanged: ((Int) -> Void)?
    var onScrollPercentChanged: ((CGFloat) -> Void)?
    var scrollToPercent: CGFloat?

    init(content: String, baseURL: URL?, directoryBookmark: Data? = nil, scrollToHeadingId: Binding<String?>, searchText: String, currentMatchIndex: Int, searchMatches: [SearchMatch], fontStyle: SettingsManager.FontStyle, zoomLevel: CGFloat = 1.0, initialScrollPosition: CGFloat = 0, onScrollPositionChanged: ((CGFloat) -> Void)? = nil, onMatchCountChanged: ((Int) -> Void)? = nil, onScrollPercentChanged: ((CGFloat) -> Void)? = nil, scrollToPercent: CGFloat? = nil) {
        self.content = content
        self.baseURL = baseURL
        self.directoryBookmark = directoryBookmark
        self._scrollToHeadingId = scrollToHeadingId
        self.searchText = searchText
        self.currentMatchIndex = currentMatchIndex
        self.searchMatches = searchMatches
        self.fontStyle = fontStyle
        self.zoomLevel = zoomLevel
        self.initialScrollPosition = initialScrollPosition
        self.onScrollPositionChanged = onScrollPositionChanged
        self.onMatchCountChanged = onMatchCountChanged
        self.onScrollPercentChanged = onScrollPercentChanged
        self.scrollToPercent = scrollToPercent
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

        // Enable link clicking
        textView.isAutomaticLinkDetectionEnabled = false
        textView.delegate = context.coordinator

        // Store reference for coordinator
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.baseURL = baseURL
        context.coordinator.onScrollPositionChanged = onScrollPositionChanged
        context.coordinator.onMatchCountChanged = onMatchCountChanged
        context.coordinator.onScrollPercentChanged = onScrollPercentChanged

        // Set up scroll notification
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Listen for diagram render completions
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.diagramDidRender),
            name: .diagramRendered,
            object: nil
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Check if content changed
        let contentChanged = context.coordinator.lastContent != content
        let searchChanged = context.coordinator.lastSearchText != searchText
        let matchIndexChanged = context.coordinator.lastMatchIndex != currentMatchIndex
        let zoomChanged = context.coordinator.lastZoomLevel != zoomLevel

        // Full rebuild when content or zoom changes
        if contentChanged || zoomChanged {
            context.coordinator.lastZoomLevel = zoomLevel
            let (attributedString, headingRanges) = buildAttributedString(coordinator: context.coordinator)
            textView.textStorage?.setAttributedString(attributedString)
            context.coordinator.headingRanges = headingRanges
            context.coordinator.lastContent = content
            context.coordinator.lastSearchText = searchText

            // Find and store all match ranges in the rendered text
            if !searchText.isEmpty {
                context.coordinator.findMatchRanges(for: searchText, in: textView)
            } else {
                context.coordinator.matchRanges = []
            }

            // Restore scroll position after content is set (only on content change, not zoom)
            if contentChanged {
                DispatchQueue.main.async {
                    if initialScrollPosition > 10 && searchText.isEmpty {
                        context.coordinator.restoreScrollPosition(initialScrollPosition, in: scrollView)
                    } else if searchText.isEmpty {
                        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                }
            }

            // Scroll to first match if searching
            if !searchText.isEmpty && !context.coordinator.matchRanges.isEmpty {
                DispatchQueue.main.async {
                    context.coordinator.scrollToMatch(at: currentMatchIndex, in: textView)
                }
            }
        }
        // Lightweight search update — no full rebuild needed
        else if searchChanged {
            context.coordinator.lastSearchText = searchText

            // Clear old highlighting
            if let storage = textView.textStorage {
                storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
            }

            if !searchText.isEmpty {
                context.coordinator.findMatchRanges(for: searchText, in: textView)
                context.coordinator.updateMatchHighlighting(currentIndex: currentMatchIndex, in: textView, searchText: searchText)
                if !context.coordinator.matchRanges.isEmpty {
                    DispatchQueue.main.async {
                        context.coordinator.scrollToMatch(at: currentMatchIndex, in: textView)
                    }
                }
            } else {
                context.coordinator.matchRanges = []
                context.coordinator.onMatchCountChanged?(0)
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

        // Handle programmatic scroll from sync
        context.coordinator.onScrollPercentChanged = onScrollPercentChanged
        if let percent = scrollToPercent, !context.coordinator.isUserScrolling {
            context.coordinator.scrollToPercent(percent)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var textView: NSTextView?
        var scrollView: NSScrollView?
        var baseURL: URL?
        var headingRanges: [String: NSRange] = [:]
        var lastContent: String?
        var lastSearchText: String?
        var lastZoomLevel: CGFloat = 1.0
        var lastMatchIndex: Int = -1
        var matchRanges: [NSRange] = []
        var onScrollPositionChanged: ((CGFloat) -> Void)?
        var onMatchCountChanged: ((Int) -> Void)?
        var onScrollPercentChanged: ((CGFloat) -> Void)?
        var isProgrammaticScroll = false
        var isUserScrolling = false
        private var scrollDebounceTimer: Timer?
        private var syncDebounceTimer: Timer?
        // Image cache shared across renders
        static var imageCache: NSCache<NSString, NSImage> = {
            let cache = NSCache<NSString, NSImage>()
            cache.countLimit = 100
            cache.totalCostLimit = 100 * 1024 * 1024
            return cache
        }()
        // Diagram/math cache
        static var diagramCache: NSCache<NSString, NSImage> = {
            let cache = NSCache<NSString, NSImage>()
            cache.countLimit = 100
            cache.totalCostLimit = 100 * 1024 * 1024
            return cache
        }()
        // Element-level rendering cache for incremental updates
        var elementCache: [String: NSAttributedString] = [:]
        var lastZoomKey: String = ""

        func scrollToHeading(id: String, in textView: NSTextView) {
            guard let range = headingRanges[id],
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let scrollView = textView.enclosingScrollView else { return }

            // Calculate target position
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let headingRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let inset = textView.textContainerInset
            let targetY = headingRect.origin.y + inset.height - 20 // 20px above heading
            let maxY = max(0, textView.frame.height - scrollView.contentView.bounds.height)
            let clampedY = min(max(0, targetY), maxY)

            // Animate the scroll
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: clampedY))
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)

            // Briefly highlight the heading
            textView.setSelectedRange(range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                textView.setSelectedRange(NSRange(location: range.location, length: 0))
            }
        }

        func restoreScrollPosition(_ position: CGFloat, in scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            let maxScroll = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
            let clampedPosition = min(position, maxScroll)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedPosition))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // MARK: - Link Handling

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            if let linkURL = link as? URL {
                url = linkURL
            } else if let linkString = link as? String {
                url = URL(string: linkString)
            } else {
                return false
            }

            guard let url = url else { return false }

            // Handle relative .md links by opening as a new tab
            if ["md", "markdown"].contains(url.pathExtension.lowercased()),
               let base = baseURL?.deletingLastPathComponent() {
                let resolved = base.appendingPathComponent(url.relativeString)
                if FileManager.default.fileExists(atPath: resolved.path) {
                    DocumentManager.shared.loadDocument(from: resolved)
                    return true
                }
            }

            // Open external URLs in default browser
            if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                NSWorkspace.shared.open(url)
                return true
            }

            return false
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

        @objc func diagramDidRender() {
            // Force rebuild by clearing lastContent and element cache
            lastContent = nil
            elementCache.removeAll()
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }

            // Debounce scroll position saving
            scrollDebounceTimer?.invalidate()
            scrollDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                let position = clipView.bounds.origin.y
                self?.onScrollPositionChanged?(position)
            }

            // Scroll sync percent reporting
            if !isProgrammaticScroll, let sv = scrollView, let docView = sv.documentView {
                let contentHeight = docView.frame.height
                let viewportHeight = sv.contentView.bounds.height
                let scrollableHeight = contentHeight - viewportHeight
                if scrollableHeight > 0 {
                    let percent = min(1.0, max(0.0, clipView.bounds.origin.y / scrollableHeight))
                    isUserScrolling = true
                    syncDebounceTimer?.invalidate()
                    syncDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                        self?.isUserScrolling = false
                    }
                    onScrollPercentChanged?(percent)
                }
            }
        }

        func scrollToPercent(_ percent: CGFloat) {
            guard let scrollView = scrollView, let documentView = scrollView.documentView else { return }
            let contentHeight = documentView.frame.height
            let viewportHeight = scrollView.contentView.bounds.height
            let scrollableHeight = contentHeight - viewportHeight
            guard scrollableHeight > 0 else { return }

            let targetY = percent * scrollableHeight

            isProgrammaticScroll = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
            }) { [weak self] in
                self?.isProgrammaticScroll = false
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        deinit {
            scrollDebounceTimer?.invalidate()
            NotificationCenter.default.removeObserver(self)
        }
    }

    // MARK: - Build Attributed String

    private func buildAttributedString(coordinator: Coordinator) -> (NSAttributedString, [String: NSRange]) {
        let parser = MarkdownParser.shared
        let elements = parser.parse(content)
        let headings = parser.extractHeadings(content)
        let result = NSMutableAttributedString()
        var headingRanges: [String: NSRange] = [:]
        var headingIndex = 0

        // Manage element cache — invalidate on zoom or font change
        let zoomKey = "\(zoomLevel)-\(fontStyle.rawValue)"
        let cacheValid = coordinator.lastZoomKey == zoomKey
        if !cacheValid {
            coordinator.elementCache.removeAll()
            coordinator.lastZoomKey = zoomKey
        }

        for element in elements {
            let startPos = result.length

            // Use cached fragment if available, otherwise render and cache
            if cacheValid, let cached = coordinator.elementCache[element.id] {
                result.append(cached)
            } else {
                renderElement(element, to: result)
                let endPos = result.length
                if endPos > startPos {
                    let fragment = result.attributedSubstring(from: NSRange(location: startPos, length: endPos - startPos))
                    coordinator.elementCache[element.id] = fragment
                }
            }

            // Track heading ranges for outline navigation
            if element.isHeading, headingIndex < headings.count {
                headingRanges[headings[headingIndex].id] = NSRange(location: startPos, length: result.length - startPos)
                headingIndex += 1
            }
        }

        // Apply search highlighting (not cached — depends on current search state)
        applySearchHighlighting(to: result)

        return (result, headingRanges)
    }

    /// Dispatch a parsed element to the appropriate append method
    private func renderElement(_ element: MarkdownParser.Element, to result: NSMutableAttributedString) {
        switch element {
        case .heading1(let text): appendHeading(text: text, level: 1, to: result)
        case .heading2(let text): appendHeading(text: text, level: 2, to: result)
        case .heading3(let text): appendHeading(text: text, level: 3, to: result)
        case .heading4(let text): appendHeading(text: text, level: 4, to: result)
        case .heading5(let text): appendHeading(text: text, level: 5, to: result)
        case .heading6(let text): appendHeading(text: text, level: 6, to: result)
        case .paragraph(let text): appendParagraph(text: text, to: result)
        case .frontmatter(let lines): appendFrontmatter(lines: lines, to: result)
        case .list(let items): appendList(items: items, to: result)
        case .codeBlock(let code, let language): appendCodeBlock(code: code, language: language, to: result)
        case .mermaidBlock(let code): appendMermaidBlock(code: code, to: result)
        case .displayMath(let latex): appendDisplayMath(latex: latex, to: result)
        case .table(let rows): appendTable(rows: rows, to: result)
        case .image(let alt, let path): appendImage(alt: alt, path: path, to: result)
        case .horizontalRule: appendHorizontalRule(to: result)
        case .blockquote(let text): appendBlockquote(text: text, to: result)
        case .htmlBlock(let html): appendHTMLBlock(html: html, to: result)
        }
    }

    // MARK: - Append Methods

    private func appendHeading(text: String, level: Int, to result: NSMutableAttributedString) {
        let sizes: [Int: CGFloat] = [1: 28, 2: 24, 3: 20, 4: 18, 5: 16, 6: 15]
        let size = (sizes[level] ?? 16) * zoomLevel
        let font = fontStyle.nsFont(size: size).withWeight(.semibold)

        // Heading color hierarchy
        let headingColors: [Int: NSColor] = [
            1: NSColor.controlAccentColor,
            2: NSColor.controlAccentColor.withAlphaComponent(0.8),
            3: NSColor.textColor,
            4: NSColor.secondaryLabelColor,
            5: NSColor.secondaryLabelColor,
            6: NSColor.secondaryLabelColor
        ]
        let color = headingColors[level] ?? NSColor.textColor

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = level == 1 ? 24 : (level == 2 ? 20 : 16)
        paragraphStyle.paragraphSpacing = (level <= 2) ? 4 : 8

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]

        let formatted = formatInlineMarkdown(text, attributes: attributes)
        result.append(formatted)
        result.append(NSAttributedString(string: "\n"))

        // H1 and H2 get a subtle underline divider
        if level <= 2 {
            let dividerStyle = NSMutableParagraphStyle()
            dividerStyle.paragraphSpacing = 10
            let dividerLength = level == 1 ? 50 : 35
            let dividerColor = NSColor.controlAccentColor.withAlphaComponent(level == 1 ? 0.4 : 0.25)
            result.append(NSAttributedString(string: String(repeating: "─", count: dividerLength) + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 6),
                .foregroundColor: dividerColor,
                .paragraphStyle: dividerStyle
            ]))
        }
    }

    private func appendParagraph(text: String, to result: NSMutableAttributedString) {
        let font = fontStyle.nsFont(size: 16 * zoomLevel)
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

    private func appendList(items: [(level: Int, text: String, isOrdered: Bool)], to result: NSMutableAttributedString) {
        let font = fontStyle.nsFont(size: 16 * zoomLevel)

        // Track ordered list counters per nesting level
        var orderedCounters: [Int: Int] = [:]

        for (level, text, isOrdered) in items {
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

            var bulletPrefix: String
            var itemText = text

            // Check for task list items
            if text.hasPrefix("[ ] ") {
                bulletPrefix = "☐  "
                itemText = String(text.dropFirst(4))
                orderedCounters[level] = nil
            } else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                bulletPrefix = "☑  "
                itemText = String(text.dropFirst(4))
                orderedCounters[level] = nil
            } else if isOrdered {
                let counter = (orderedCounters[level] ?? 0) + 1
                orderedCounters[level] = counter
                bulletPrefix = "\(counter).  "
            } else {
                // Determine bullet style based on nesting level
                let bullets = ["•", "◦", "▪", "▹"]
                let bullet = bullets[min(level, bullets.count - 1)]
                bulletPrefix = "\(bullet)  "
                orderedCounters[level] = nil
            }

            let bulletColor = NSColor.controlAccentColor.withAlphaComponent(0.7)
            let bulletAttr = NSAttributedString(string: bulletPrefix, attributes: [
                .font: font,
                .foregroundColor: bulletColor,
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

        let titleFont = fontStyle.nsFont(size: 11 * zoomLevel).withWeight(.semibold)
        let keyFont = fontStyle.nsFont(size: 12 * zoomLevel).withWeight(.medium)
        let valueFont = fontStyle.nsFont(size: 12 * zoomLevel)

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
        // Warp-style code block: dark background, rounded corners feel, language label

        // Code block background color - adapt to current appearance
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let codeBackground = isDarkMode
            ? NSColor(calibratedWhite: 0.12, alpha: 1.0)
            : NSColor(calibratedWhite: 0.95, alpha: 1.0)

        // Top border with padding
        let topBorder = "  ╭" + String(repeating: "─", count: 76) + "╮\n"
        result.append(NSAttributedString(string: topBorder, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11 * zoomLevel, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]))

        // Add background and left border to each line (with per-line syntax highlighting)
        let codeLines = code.components(separatedBy: .newlines)
        let result2 = NSMutableAttributedString()

        for line in codeLines {
            // Add left border
            result2.append(NSAttributedString(string: "  │ ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11 * zoomLevel, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]))

            // Add highlighted code line
            let highlightedLine = SyntaxHighlighter.shared.highlight(code: line, language: language)
            let mutableLine = NSMutableAttributedString(attributedString: highlightedLine)

            // Add background to the line
            let lineRange = NSRange(location: 0, length: mutableLine.length)
            mutableLine.addAttribute(.backgroundColor, value: codeBackground, range: lineRange)

            result2.append(mutableLine)
            result2.append(NSAttributedString(string: "\n", attributes: [
                .backgroundColor: codeBackground
            ]))
        }

        result.append(result2)

        // Bottom border with language label
        let langLabel = language?.lowercased() ?? "text"
        let labelPadding = 76 - langLabel.count - 1
        let bottomBorder = "  ╰" + String(repeating: "─", count: labelPadding) + " " + langLabel + "╯\n"
        result.append(NSAttributedString(string: bottomBorder, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11 * zoomLevel, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]))

        // Add spacing after code block
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendBlockquote(text: String, to result: NSMutableAttributedString) {
        let font = fontStyle.nsFont(size: 16 * zoomLevel).withTraits(.italic)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.headIndent = 24
        paragraphStyle.firstLineHeadIndent = 24
        paragraphStyle.paragraphSpacingBefore = 8
        paragraphStyle.paragraphSpacing = 8

        // Accent-colored bar character
        let barAttr = NSAttributedString(string: "  ┃ ", attributes: [
            .font: NSFont.systemFont(ofSize: 16 * zoomLevel),
            .foregroundColor: NSColor.controlAccentColor.withAlphaComponent(0.5),
            .paragraphStyle: paragraphStyle
        ])
        result.append(barAttr)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]

        result.append(NSAttributedString(string: text + "\n", attributes: attributes))
    }

    private func appendTable(rows: [[String]], to result: NSMutableAttributedString) {
        guard !rows.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: 13 * zoomLevel, weight: .regular)
        let boldFont = NSFont.systemFont(ofSize: 13 * zoomLevel, weight: .semibold)
        let columnCount = rows.map { $0.count }.max() ?? 1

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.setContentWidth(100, type: .percentageValueType)
        table.hidesEmptyCells = false

        let borderColor = NSColor.separatorColor

        for (rowIndex, row) in rows.enumerated() {
            let isHeader = rowIndex == 0

            for colIndex in 0..<columnCount {
                let cellText = colIndex < row.count ? row[colIndex] : ""

                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: colIndex, columnSpan: 1)

                block.setBorderColor(borderColor)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)

                if isHeader {
                    block.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12)
                } else if rowIndex % 2 == 0 {
                    block.backgroundColor = NSColor.textColor.withAlphaComponent(0.03)
                }

                let cellStyle = NSMutableParagraphStyle()
                cellStyle.textBlocks = [block]
                cellStyle.lineSpacing = 2
                cellStyle.paragraphSpacingBefore = 2
                cellStyle.paragraphSpacing = 2

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: isHeader ? boldFont : font,
                    .foregroundColor: NSColor.textColor,
                    .paragraphStyle: cellStyle
                ]

                let formattedCell = formatInlineMarkdown(cellText, attributes: attrs)
                result.append(formattedCell)
                result.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }

        // Spacing after table
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendHorizontalRule(to result: NSMutableAttributedString) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = 16
        paragraphStyle.paragraphSpacing = 16

        // Gradient-like rule: accent fading to transparent
        let accentColor = NSColor.controlAccentColor
        let segments = 40
        let ruleStr = NSMutableAttributedString()
        for i in 0..<segments {
            let progress = CGFloat(i) / CGFloat(segments)
            // Bell curve: strong in center, fading at edges
            let intensity = sin(progress * .pi)
            let color = accentColor.withAlphaComponent(intensity * 0.5)
            ruleStr.append(NSAttributedString(string: "─", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]))
        }
        ruleStr.append(NSAttributedString(string: "\n"))
        result.append(ruleStr)
    }

    private func appendImage(alt: String, path: String, to result: NSMutableAttributedString) {
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
                .font: fontStyle.nsFont(size: 14 * zoomLevel),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            result.append(NSAttributedString(string: "[Image: \(alt.isEmpty ? path : alt)]\n", attributes: attributes))
        }
    }

    private func loadImage(path: String) -> NSImage? {
        // Check cache first
        if let cached = Coordinator.imageCache.object(forKey: path as NSString) {
            return cached
        }

        // Remote URL — return nil (placeholder) and load asynchronously
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            if let url = URL(string: path) {
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let image = NSImage(contentsOf: url) else { return }
                    DispatchQueue.main.async {
                        Coordinator.imageCache.setObject(image, forKey: path as NSString)
                        // Trigger re-render by posting notification (content hasn't changed,
                        // but the view should rebuild to include the now-cached image)
                    }
                }
            }
            return nil
        }

        // Activate directory security scope for relative image access
        var accessingDirectory = false
        var dirURL: URL?
        if let bookmark = directoryBookmark {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                dirURL = resolved
                accessingDirectory = resolved.startAccessingSecurityScopedResource()
            }
        }
        defer {
            if accessingDirectory, let dir = dirURL {
                dir.stopAccessingSecurityScopedResource()
            }
        }

        // Local file — synchronous is fine for local disk I/O
        let resolvedURL: URL?

        let absoluteURL = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: absoluteURL.path) {
            resolvedURL = absoluteURL
        } else if let base = baseURL?.deletingLastPathComponent() {
            let relativeURL = base.appendingPathComponent(path)
            resolvedURL = FileManager.default.fileExists(atPath: relativeURL.path) ? relativeURL : nil
        } else {
            resolvedURL = nil
        }

        if let url = resolvedURL, let image = NSImage(contentsOf: url) {
            Coordinator.imageCache.setObject(image, forKey: path as NSString)
            return image
        }

        return nil
    }

    // MARK: - Mermaid & Math

    private func appendMermaidBlock(code: String, to result: NSMutableAttributedString) {
        let cacheKey = "mermaid-" + code
        if let cached = Coordinator.diagramCache.object(forKey: cacheKey as NSString) {
            // Embed cached image
            let attachment = NSTextAttachment()
            let maxWidth: CGFloat = 700
            let scale = min(1.0, maxWidth / cached.size.width)
            let newSize = NSSize(width: cached.size.width * scale, height: cached.size.height * scale)
            let resized = NSImage(size: newSize)
            resized.lockFocus()
            cached.draw(in: NSRect(origin: .zero, size: newSize))
            resized.unlockFocus()
            attachment.image = resized
            result.append(NSAttributedString(string: "\n"))
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "\n\n"))
        } else {
            // Show styled loading placeholder
            let placeholderStyle = NSMutableParagraphStyle()
            placeholderStyle.alignment = .center
            placeholderStyle.paragraphSpacingBefore = 12
            placeholderStyle.paragraphSpacing = 12

            let placeholder = NSMutableAttributedString()
            placeholder.append(NSAttributedString(string: "\n", attributes: [:]))
            placeholder.append(NSAttributedString(string: "    Rendering diagram...\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13 * zoomLevel, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: placeholderStyle
            ]))
            placeholder.append(NSAttributedString(string: "\n", attributes: [:]))
            result.append(placeholder)

            Task { @MainActor in
                WebRenderer.shared.renderMermaid(code) { image in
                    guard let image = image else { return }
                    Coordinator.diagramCache.setObject(image, forKey: cacheKey as NSString)
                    NotificationCenter.default.post(name: .diagramRendered, object: nil)
                }
            }
        }
    }

    private func appendDisplayMath(latex: String, to result: NSMutableAttributedString) {
        let cacheKey = "math-display-" + latex
        if let cached = Coordinator.diagramCache.object(forKey: cacheKey as NSString) {
            let attachment = NSTextAttachment()
            attachment.image = cached
            result.append(NSAttributedString(string: "\n"))
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "\n\n"))
        } else {
            // Show styled loading placeholder
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            paragraphStyle.paragraphSpacing = 8
            result.append(NSAttributedString(string: "  Rendering math...\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13 * zoomLevel, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraphStyle
            ]))

            Task { @MainActor in
                WebRenderer.shared.renderMath(latex, displayMode: true) { image in
                    guard let image = image else { return }
                    Coordinator.diagramCache.setObject(image, forKey: cacheKey as NSString)
                    NotificationCenter.default.post(name: .diagramRendered, object: nil)
                }
            }
        }
    }

    // MARK: - HTML Block Support

    private func appendHTMLBlock(html: String, to result: NSMutableAttributedString) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let textColor = isDark ? "#e0e0e0" : "#1a1a1a"
        let bgColor = isDark ? "#1e1e1e" : "#ffffff"
        let linkColor = isDark ? "#6cb4ee" : "#0066cc"
        let fontSize = 16 * zoomLevel

        // Resolve relative image src paths to absolute file paths
        let baseDir = baseURL?.deletingLastPathComponent()
        var resolvedHTML = html
        if let baseDir = baseDir {
            let imgPattern = #"(<img\s[^>]*src\s*=\s*")([^"]+)("[^>]*>)"#
            if let regex = try? NSRegularExpression(pattern: imgPattern, options: .caseInsensitive) {
                let nsHTML = resolvedHTML as NSString
                let matches = regex.matches(in: resolvedHTML, range: NSRange(location: 0, length: nsHTML.length)).reversed()
                for match in matches {
                    guard match.numberOfRanges >= 4 else { continue }
                    let srcRange = match.range(at: 2)
                    let src = nsHTML.substring(with: srcRange)
                    // Skip URLs that are already absolute
                    if src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("file://") { continue }
                    let resolved = baseDir.appendingPathComponent(src)
                    if FileManager.default.fileExists(atPath: resolved.path) {
                        resolvedHTML = (resolvedHTML as NSString).replacingCharacters(in: srcRange, with: resolved.absoluteString)
                    }
                }
            }
        }

        // Wrap HTML with styling that matches the app theme
        let styledHTML = """
        <html><head><style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif;
               font-size: \(fontSize)px; color: \(textColor); background: \(bgColor);
               line-height: 1.5; margin: 0; padding: 0; }
        a { color: \(linkColor); }
        img { max-width: 100%; height: auto; }
        h1, h2, h3, h4, h5, h6 { margin-top: 0.5em; margin-bottom: 0.3em; }
        p { margin: 0.3em 0; }
        </style></head><body>\(resolvedHTML)</body></html>
        """

        guard let data = styledHTML.data(using: .utf8),
              let attributed = NSAttributedString(
                html: data,
                baseURL: baseDir ?? URL(fileURLWithPath: "/"),
                documentAttributes: nil
              ) else {
            // Fallback: render as plain text
            let font = fontStyle.nsFont(size: fontSize)
            result.append(NSAttributedString(string: html + "\n", attributes: [
                .font: font,
                .foregroundColor: NSColor.textColor
            ]))
            return
        }

        result.append(attributed)
        // Ensure trailing newline
        if !attributed.string.hasSuffix("\n") {
            result.append(NSAttributedString(string: "\n"))
        }
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

        // Inline math $...$
        applyInlineMathPattern(to: result)

        return result
    }

    private static var regexCache: [String: NSRegularExpression] = [:]

    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        if let cached = regexCache[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache[pattern] = regex
        return regex
    }

    private func applyPattern(_ pattern: String, to result: NSMutableAttributedString, attributes: [NSAttributedString.Key: Any]) {
        guard let regex = Self.cachedRegex(pattern) else { return }
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
        guard let regex = Self.cachedRegex(pattern) else { return }
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

    private func applyInlineMathPattern(to result: NSMutableAttributedString) {
        // Match $...$ but not $$, and not $ preceded/followed by space
        let pattern = #"(?<!\$)\$(?!\$)(?! )(.+?)(?<! )\$(?!\$)"#
        guard let regex = Self.cachedRegex(pattern) else { return }
        let string = result.string as NSString

        let matches = regex.matches(in: result.string, range: NSRange(location: 0, length: string.length)).reversed()

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let fullRange = match.range(at: 0)
            let contentRange = match.range(at: 1)
            let latex = string.substring(with: contentRange)
            let cacheKey = "math-inline-" + latex

            if let cached = Coordinator.diagramCache.object(forKey: cacheKey as NSString) {
                // Replace with image attachment
                let attachment = NSTextAttachment()
                attachment.image = cached
                let replacement = NSAttributedString(attachment: attachment)
                result.replaceCharacters(in: fullRange, with: replacement)
            } else {
                // Style as code-like placeholder and trigger async render
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 13 * zoomLevel, weight: .regular),
                    .foregroundColor: NSColor.systemPurple
                ]
                result.replaceCharacters(in: fullRange, with: NSAttributedString(string: latex, attributes: attributes))

                Task { @MainActor in
                    WebRenderer.shared.renderMath(latex, displayMode: false) { image in
                        guard let image = image else { return }
                        Coordinator.diagramCache.setObject(image, forKey: cacheKey as NSString)
                        NotificationCenter.default.post(name: .diagramRendered, object: nil)
                    }
                }
            }
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
