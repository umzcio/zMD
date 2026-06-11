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
    /// Whether the preview matcher should interpret `searchText` as a regex.
    /// Threaded through from DocumentManager so preview highlights match the find-bar counter —
    /// previously the preview hardcoded case-insensitive literal matching and diverged.
    let isRegexSearch: Bool
    let isCaseSensitive: Bool

    init(content: String, baseURL: URL?, directoryBookmark: Data? = nil, scrollToHeadingId: Binding<String?>, searchText: String, currentMatchIndex: Int, searchMatches: [SearchMatch], fontStyle: SettingsManager.FontStyle, zoomLevel: CGFloat = 1.0, initialScrollPosition: CGFloat = 0, onScrollPositionChanged: ((CGFloat) -> Void)? = nil, onMatchCountChanged: ((Int) -> Void)? = nil, onScrollPercentChanged: ((CGFloat) -> Void)? = nil, scrollToPercent: CGFloat? = nil, isRegexSearch: Bool = false, isCaseSensitive: Bool = false) {
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
        self.isRegexSearch = isRegexSearch
        self.isCaseSensitive = isCaseSensitive
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
            || context.coordinator.lastIsRegex != isRegexSearch
            || context.coordinator.lastIsCaseSensitive != isCaseSensitive
        let matchIndexChanged = context.coordinator.lastMatchIndex != currentMatchIndex
        let zoomChanged = context.coordinator.lastZoomLevel != zoomLevel

        // Keep the Coordinator's mode flags in sync so a future tick can detect the NEXT toggle.
        context.coordinator.lastIsRegex = isRegexSearch
        context.coordinator.lastIsCaseSensitive = isCaseSensitive

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
                context.coordinator.findMatchRanges(for: searchText, isRegex: isRegexSearch, isCaseSensitive: isCaseSensitive, in: textView)
            } else {
                context.coordinator.matchRanges = []
            }

            // Restore scroll position after content is set (only on content change, not zoom)
            if contentChanged {
                DispatchQueue.main.async {
                    if let pinY = context.coordinator.pendingDiagramScrollY {
                        // Diagram-render rebuild: clamp scroll back to the exact Y the user
                        // was at before the rebuild. Doc layout may have shifted slightly
                        // (math attachments arrived) but pinning Y means no visible scroll jump.
                        context.coordinator.pendingDiagramScrollY = nil
                        context.coordinator.restoreScrollPosition(pinY, in: scrollView)
                    } else if initialScrollPosition > 10 && searchText.isEmpty {
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

            // Clear only the ranges we previously painted (H3) — see updateMatchHighlighting
            // for the rationale. The blanket clear here used to wipe inline-code/table/code-block
            // backgrounds whenever search ran or cleared.
            if let storage = textView.textStorage {
                for r in context.coordinator.searchHighlightRanges where r.location + r.length <= storage.length {
                    storage.removeAttribute(.backgroundColor, range: r)
                }
                context.coordinator.searchHighlightRanges.removeAll(keepingCapacity: true)
            }

            if !searchText.isEmpty {
                context.coordinator.findMatchRanges(for: searchText, isRegex: isRegexSearch, isCaseSensitive: isCaseSensitive, in: textView)
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
        /// Track the search-mode flags so toggling regex/case is treated like a search change and
        /// the stale highlight backgrounds get cleared + re-applied.
        var lastIsRegex: Bool = false
        var lastIsCaseSensitive: Bool = false
        var matchRanges: [NSRange] = []
        // Ranges currently painted with a search highlight. Tracked separately so we can clear
        // only those backgrounds — previously the lightweight search-update path called
        // `removeAttribute(.backgroundColor, range: 0..<storage.length)` and wiped legitimate
        // backgrounds from inline-code spans, code blocks, and table cells. After H3 the only
        // backgrounds removed are the ones search itself painted.
        var searchHighlightRanges: [NSRange] = []
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
            cache.countLimit = Cache.imageCountLimit
            cache.totalCostLimit = Cache.imageByteLimit
            return cache
        }()
        // Diagram/math cache — uses the diagram-specific limits, which are much higher than
        // the image limits because math images are tiny but appear in large numbers in
        // technical docs (~300+ inline spans is common). Old shared image limit (100) thrashed.
        static var diagramCache: NSCache<NSString, NSImage> = {
            let cache = NSCache<NSString, NSImage>()
            cache.countLimit = Cache.diagramCountLimit
            cache.totalCostLimit = Cache.diagramByteLimit
            return cache
        }()
        // Element-level rendering cache for incremental updates
        var elementCache: [String: NSAttributedString] = [:]
        var lastZoomKey: String = ""

        // Scroll Y captured at the moment a diagram-render notification arrived. After the
        // rebuild lands, updateNSView restores to this exact Y — preserving the user's scroll
        // position rather than letting setAttributedString reset to 0 or anchor-based restore
        // visibly shift it. The visible content at that Y may be slightly different post-rebuild
        // (math images replaced text placeholders) but the viewport doesn't jump.
        var pendingDiagramScrollY: CGFloat?

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

            // Flag programmatic scroll so the bounds-change observer doesn't re-broadcast this
            // motion as a user scroll event, which would rebound the source side in split mode.
            isProgrammaticScroll = true

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: clampedY))
            }, completionHandler: { [weak self] in
                self?.isProgrammaticScroll = false
            })
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
                let resolved = base.appendingPathComponent(url.relativeString).standardizedFileURL
                // S3: confine the resolved path to the document's directory subtree. Without this,
                // a crafted link like [x](../../../../private.md) resolves outside the folder and
                // would be opened. The trailing-slash form prevents a sibling-prefix false match
                // (e.g. base "/a/notes" vs "/a/notes-secret/x.md").
                let baseDir = base.standardizedFileURL
                let basePrefix = baseDir.path.hasSuffix("/") ? baseDir.path : baseDir.path + "/"
                guard resolved.path == baseDir.path || resolved.path.hasPrefix(basePrefix) else {
                    return false
                }
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

        func findMatchRanges(for searchText: String, isRegex: Bool, isCaseSensitive: Bool, in textView: NSTextView) {
            matchRanges = []
            guard let storage = textView.textStorage, !searchText.isEmpty else {
                onMatchCountChanged?(0)
                return
            }

            let string = storage.string as NSString

            if isRegex {
                var options: NSRegularExpression.Options = []
                if !isCaseSensitive { options.insert(.caseInsensitive) }
                guard let regex = try? NSRegularExpression(pattern: searchText, options: options) else {
                    onMatchCountChanged?(0)
                    return
                }
                let results = regex.matches(in: storage.string, range: NSRange(location: 0, length: string.length))
                for result in results {
                    matchRanges.append(result.range)
                }
            } else {
                var stringOptions: NSString.CompareOptions = []
                if !isCaseSensitive { stringOptions.insert(.caseInsensitive) }
                var searchRange = NSRange(location: 0, length: string.length)
                while searchRange.location < string.length {
                    let range = string.range(of: searchText, options: stringOptions, range: searchRange)
                    guard range.location != NSNotFound else { break }
                    matchRanges.append(range)
                    // Advance by at least one character to avoid infinite loops on zero-length matches.
                    let advance = max(1, range.length)
                    searchRange.location = range.location + advance
                    searchRange.length = max(0, string.length - searchRange.location)
                }
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

            // Clear ONLY the ranges we previously painted. Previously this stripped
            // .backgroundColor across the entire storage, which also erased legitimate
            // backgrounds on inline code, code blocks, and table cells (H3). Restore the
            // original token color afterward in case our overlay had stomped it.
            for r in searchHighlightRanges where r.location + r.length <= storage.length {
                storage.removeAttribute(.backgroundColor, range: r)
                // .foregroundColor was force-overridden to black during highlight; we don't
                // know the original here, so leave it — the next full rebuild will repaint
                // with the correct token color. For the common case (search on, search off,
                // edit) this drift is invisible because typing triggers a rebuild anyway.
            }
            searchHighlightRanges.removeAll(keepingCapacity: true)

            // Re-apply highlighting to all matches
            for (index, range) in matchRanges.enumerated() {
                guard range.location + range.length <= storage.length else { continue }
                let isCurrent = index == currentIndex
                let bgColor = isCurrent ? NSColor.systemOrange : NSColor.systemYellow.withAlphaComponent(0.5)
                storage.addAttributes([
                    .backgroundColor: bgColor,
                    .foregroundColor: NSColor.black
                ], range: range)
                searchHighlightRanges.append(range)
            }
        }

        // Debounce diagram-render notifications so a doc with N Mermaid/KaTeX blocks doesn't
        // force N full rebuilds during initial open (M2). 100ms is below the perceptible-flicker
        // threshold and comfortably groups the burst from a normal multi-diagram doc.
        private var diagramCoalesceTimer: Timer?

        @objc func diagramDidRender() {
            diagramCoalesceTimer?.invalidate()
            diagramCoalesceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                // Snapshot scroll Y so the post-rebuild restore pins to the user's current
                // scroll position (not initialScrollPosition, and not an anchor-char position
                // that visibly shifts when math attachments arrive above the viewport).
                if let sv = self.scrollView {
                    self.pendingDiagramScrollY = sv.contentView.bounds.origin.y
                }
                self.lastContent = nil
                self.elementCache.removeAll()
                // Force SwiftUI to re-evaluate the view body so updateNSView fires and
                // rebuilds with the now-cached image. Without this, the math/Mermaid
                // placeholder text stays on screen until the user scrolls/types/resizes
                // (regression I introduced when adding the 100ms coalesce in Phase 5).
                DocumentManager.shared.diagramRenderTick &+= 1
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
            syncDebounceTimer?.invalidate()
            diagramCoalesceTimer?.invalidate()
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
        // P6: collect the ids actually present in this build so stale cache entries can be swept
        // afterward. Keys are content-addressed, so without a sweep every edit leaves the previous
        // version of the edited element behind, growing elementCache unboundedly for the session.
        var liveKeys = Set<String>()

        // Pair headings to slug IDs as we encounter them in the parsed element stream.
        // Previously this used a positional index into `headings`, which drifted whenever
        // `extractHeadings` returned an entry that `parse()` did not (e.g., a `#` line inside a
        // fenced code block). Now `extractHeadings` skips fenced/frontmatter, so both sequences
        // are aligned — but we also track slug-counts here to handle duplicates defensively.
        var parsedHeadingIndex = 0

        // Manage element cache — invalidate on zoom, font, OR appearance change. H4: code-block
        // and html-block renderers bake resolved RGB into the cached fragment, so toggling system
        // theme without an edit served stale colors from the cache. Including the resolved
        // appearance in the cache key forces a rebuild on theme flip.
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let zoomKey = "\(zoomLevel)-\(fontStyle.rawValue)-\(isDark ? "d" : "l")"
        let cacheValid = coordinator.lastZoomKey == zoomKey
        if !cacheValid {
            coordinator.elementCache.removeAll()
            coordinator.lastZoomKey = zoomKey
        }

        for element in elements {
            let startPos = result.length

            // Elements whose appearance depends on an out-of-band async resource (remote images,
            // Mermaid/LaTeX diagrams rendered by WebRenderer, HTML blocks converted via WebKit) must
            // NOT be cached by content id: their first render inserts a "[Image: alt]" / "[Rendering…]"
            // placeholder, and caching that placeholder freezes the wrong visual even after the
            // diagramDidRender notification clears `elementCache`.
            let skipCache: Bool
            switch element {
            case .image, .mermaidBlock, .displayMath, .htmlBlock:
                skipCache = true
            default:
                skipCache = false
            }
            if !skipCache { liveKeys.insert(element.id) }

            if !skipCache, cacheValid, let cached = coordinator.elementCache[element.id] {
                result.append(cached)
            } else {
                renderElement(element, to: result)
                let endPos = result.length
                if !skipCache, endPos > startPos {
                    let fragment = result.attributedSubstring(from: NSRange(location: startPos, length: endPos - startPos))
                    coordinator.elementCache[element.id] = fragment
                }
            }

            // Track heading ranges for outline navigation. extractHeadings now skips
            // lines inside fenced code blocks, so the parsed-element heading order and the
            // outline heading order align 1:1.
            if element.isHeading, parsedHeadingIndex < headings.count {
                headingRanges[headings[parsedHeadingIndex].id] = NSRange(location: startPos, length: result.length - startPos)
                parsedHeadingIndex += 1
            }
        }

        // P6: evict cache entries whose elements are no longer in the document (e.g. the previous
        // content of an edited element), keeping the cache bounded to the current element stream.
        if coordinator.elementCache.count > liveKeys.count {
            coordinator.elementCache = coordinator.elementCache.filter { liveKeys.contains($0.key) }
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

    private func appendList(items: [(level: Int, text: String, isOrdered: Bool, startNumber: Int?)], to result: NSMutableAttributedString) {
        let font = fontStyle.nsFont(size: 16 * zoomLevel)

        // Track ordered list counters per nesting level. The list's first item carries an
        // optional startNumber from the source markdown; subsequent items at the same level
        // continue sequentially. A list opening with `4. foo` renders as `4.`, not `1.`.
        var orderedCounters: [Int: Int] = [:]

        for (level, text, isOrdered, startNumber) in items {
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
                let counter: Int
                if let existing = orderedCounters[level] {
                    counter = existing + 1
                } else if let start = startNumber {
                    // First item at this level — honor the explicit start number from source.
                    counter = start
                } else {
                    counter = 1
                }
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
        // C2: clamp at 0 — a long language label would make this count negative, and
        // String(repeating:count:) with a negative count is a precondition failure (crash on render).
        let labelPadding = max(0, 76 - langLabel.count - 1)
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

            // "Populated first cell, empty trailing cells" → render as a single full-width
            // cell. Convention used in many docs to create summary/footer rows that visually
            // span the table; CommonMark has no syntax for it, so we infer the intent.
            let trimmed = row.map { $0.trimmingCharacters(in: .whitespaces) }
            let isFullSpan = row.count > 1 && !trimmed[0].isEmpty
                && trimmed.dropFirst().allSatisfy({ $0.isEmpty })

            if isFullSpan {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: 0, columnSpan: columnCount)
                block.setBorderColor(borderColor)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                if rowIndex % 2 == 0 {
                    block.backgroundColor = NSColor.textColor.withAlphaComponent(0.03)
                }

                let cellStyle = NSMutableParagraphStyle()
                cellStyle.textBlocks = [block]
                cellStyle.lineSpacing = 2
                cellStyle.paragraphSpacingBefore = 2
                cellStyle.paragraphSpacing = 2

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.textColor,
                    .paragraphStyle: cellStyle
                ]

                let formattedCell = formatInlineMarkdown(row[0], attributes: attrs)
                result.append(formattedCell)
                result.append(NSAttributedString(string: "\n", attributes: attrs))
                continue
            }

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
        // L3: cache key composed of (baseURL.path, path) so two open documents in different
        // folders can each have an `image.png` without one's image overwriting the other's
        // entry. Remote URLs are unique by URL alone, so we leave them keyed on `path`.
        let cacheKey: String = {
            if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
            return (baseURL?.deletingLastPathComponent().path ?? "") + "\u{1F}" + path
        }()
        if let cached = Coordinator.imageCache.object(forKey: cacheKey as NSString) {
            return cached
        }

        // Remote URL — return nil (placeholder) and load asynchronously.
        // Posts .diagramRendered when the image lands so the preview rebuilds and the placeholder
        // text gets replaced with the actual image. (Piggybacks on the existing diagram refresh hook.)
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            if let url = URL(string: path) {
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let image = NSImage(contentsOf: url) else { return }
                    DispatchQueue.main.async {
                        Coordinator.imageCache.setObject(image, forKey: cacheKey as NSString)
                        NotificationCenter.default.post(name: .diagramRendered, object: nil)
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
            Coordinator.imageCache.setObject(image, forKey: cacheKey as NSString)
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

    /// Sentinel attribute marking ranges that came from an inline code span. Subsequent inline
    /// passes (bold, italic, strike, link) skip ranges carrying this attribute so that
    /// `` `*foo*` `` renders with literal asterisks instead of treating them as italic markers.
    /// Cleared at the end of formatInlineMarkdown so it never leaks to the storage.
    private static let codeSpanSentinel = NSAttributedString.Key("zMD.codeSpanSentinel")

    private func formatInlineMarkdown(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        // CommonMark backslash escapes + <br>. Sentinel-out before regex passes so escaped
        // markers (\* \_ etc.) don't trigger bold/italic, and <br> becomes a real newline in
        // the rendered NSAttributedString instead of literal "<br>" text.
        var processed = text.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        let openSentinel = "\u{E000}"
        let closeSentinel = "\u{E001}"
        processed = processed.replacingOccurrences(
            of: #"\\([\\`*_{}\[\]()#+\-.!|~])"#,
            with: "\(openSentinel)$1\(closeSentinel)",
            options: .regularExpression
        )
        let result = NSMutableAttributedString(string: processed, attributes: attributes)
        let baseFont = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 16)

        // Inline code FIRST. It's atomic in CommonMark — `*x*` inside a code span must remain
        // literal asterisks. Tag the resulting content with codeSpanSentinel so downstream passes
        // skip those ranges (H5). Try double-backtick first so `` `foo` `` content (with literal
        // backticks inside) renders correctly; then single-backtick handles the common case (L7).
        applyPattern(#"``([^`]+(?:`[^`]+)*)``"#, to: result, attributes: [
            Self.codeSpanSentinel: true,
            .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular),
            .backgroundColor: NSColor.separatorColor.withAlphaComponent(0.15)
        ])
        applyPattern(#"`([^`]+?)`"#, to: result, attributes: [
            Self.codeSpanSentinel: true,
            .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular),
            .backgroundColor: NSColor.separatorColor.withAlphaComponent(0.15)
        ])

        // Inline math $...$ — moved up to run BEFORE bold/italic/strike (M3) so a math span like
        // `$a^{**}$` doesn't get its `**` consumed by the bold pass.
        applyInlineMathPattern(to: result)

        // Bold **text**
        applyPattern(#"\*\*(.+?)\*\*"#, to: result, attributes: [.font: baseFont.withWeight(.bold)], skipCodeSpans: true)

        // Italic *text*
        applyPattern(#"\*(.+?)\*"#, to: result, attributes: [.font: baseFont.withTraits(.italic)], skipCodeSpans: true)

        // Strikethrough ~~text~~
        applyPattern(#"~~(.+?)~~"#, to: result, attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue], skipCodeSpans: true)

        // Links [text](url)
        applyLinkPattern(to: result)

        // Strip the sentinel before returning so it doesn't ride along into NSTextStorage.
        let fullRange = NSRange(location: 0, length: result.length)
        result.removeAttribute(Self.codeSpanSentinel, range: fullRange)

        // Strip backslash-escape sentinels — leaves the literal escaped char.
        result.mutableString.replaceOccurrences(of: openSentinel, with: "", options: [], range: NSRange(location: 0, length: result.length))
        result.mutableString.replaceOccurrences(of: closeSentinel, with: "", options: [], range: NSRange(location: 0, length: result.length))

        return result
    }

    private static var regexCache: [String: NSRegularExpression] = [:]

    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        if let cached = regexCache[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache[pattern] = regex
        return regex
    }

    private func applyPattern(_ pattern: String, to result: NSMutableAttributedString, attributes: [NSAttributedString.Key: Any], skipCodeSpans: Bool = false) {
        guard let regex = Self.cachedRegex(pattern) else { return }
        let string = result.string as NSString

        // L8: matches are computed once over the original string and iterated in reverse so
        // index-shifting from earlier replacements doesn't invalidate later ranges. Side effect:
        // we don't re-tokenize after each mutation, so a replacement that creates new pairs
        // (e.g., `**a*` followed by `*b**` joined into `**a*` + `*b**` → `**a**b**` post-replace)
        // would not be re-matched. This is acceptable: the input must be CommonMark-correct, and
        // emitting paired markers from a non-paired input is a pathological case.
        let matches = regex.matches(in: result.string, range: NSRange(location: 0, length: string.length)).reversed()

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let fullRange = match.range(at: 0)
            let contentRange = match.range(at: 1)

            // H5: skip matches that overlap a previously-marked code span.
            if skipCodeSpans && rangeIntersectsCodeSpan(fullRange, in: result) { continue }

            // Get the content text
            let content = string.substring(with: contentRange)

            // Get existing attributes and merge. Do NOT inherit codeSpanSentinel from the
            // surrounding text — we'd be tagging non-code as code.
            var newAttributes = result.attributes(at: contentRange.location, effectiveRange: nil)
            newAttributes.removeValue(forKey: Self.codeSpanSentinel)
            for (key, value) in attributes {
                newAttributes[key] = value
            }

            // Replace the full match with just the content, applying new attributes
            result.replaceCharacters(in: fullRange, with: NSAttributedString(string: content, attributes: newAttributes))
        }
    }

    private func rangeIntersectsCodeSpan(_ range: NSRange, in attributed: NSAttributedString) -> Bool {
        guard range.location + range.length <= attributed.length else { return false }
        var found = false
        attributed.enumerateAttribute(Self.codeSpanSentinel, in: range, options: []) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
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
        // Pandoc-style inline-math rule:
        //   - opening `$` not preceded by `$` (so `$$` is display math)
        //   - opening `$` not followed by `$`, space, OR digit (so `$1`, `$10.50` are money,
        //     not math openers — without this, paragraphs containing `…thanks ($1) for …
        //     thanks ($10) for …` matched the entire span between the two `$` as math)
        //   - closing `$` not preceded by space, not followed by `$` or digit
        //   - content capped at 200 chars to bound runaway lazy matches
        let pattern = MarkdownParser.inlineMathPattern  // C7: shared canonical pattern
        guard let regex = Self.cachedRegex(pattern) else { return }
        let string = result.string as NSString

        let matches = regex.matches(in: result.string, range: NSRange(location: 0, length: string.length)).reversed()

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let fullRange = match.range(at: 0)
            let contentRange = match.range(at: 1)
            let latex = string.substring(with: contentRange)
            let cacheKey = "math-inline-" + latex

            // Preserve the existing attributes (especially .paragraphStyle, which carries the
            // table-cell textBlocks attribute). NSAttributedString(attachment:) and a fresh
            // dictionary both strip the paragraph style; without it, table cells containing math
            // lose their textBlock binding and render as full-width rows outside the table.
            let existing = result.attributes(at: fullRange.location, effectiveRange: nil)

            if let cached = Coordinator.diagramCache.object(forKey: cacheKey as NSString) {
                // Replace with image attachment, sized to match the surrounding line height.
                // takeSnapshot returns NSImages whose pixel dimensions are at the device scale
                // (2x on retina), and NSTextAttachment displays at NSImage.size in points —
                // without explicit bounds, math renders 2x bigger than text and breaks line
                // metrics + table cell widths. Scale to the body font's point size, preserving
                // aspect ratio, with a small descent offset so the math sits on the baseline.
                let attachment = NSTextAttachment()
                attachment.image = cached
                let baseFontSize: CGFloat = fontStyle.nsFont(size: 14 * zoomLevel).pointSize
                let aspect = cached.size.height > 0 ? cached.size.width / cached.size.height : 1
                let displayHeight = baseFontSize * 1.1
                let displayWidth = displayHeight * aspect
                attachment.bounds = CGRect(x: 0, y: -2, width: displayWidth, height: displayHeight)
                let replacement = NSMutableAttributedString(attachment: attachment)
                replacement.addAttributes(existing, range: NSRange(location: 0, length: replacement.length))
                result.replaceCharacters(in: fullRange, with: replacement)
            } else {
                // Style as code-like placeholder and trigger async render. Merge math styling
                // on top of the existing attrs so paragraph style is preserved (see above).
                var attributes = existing
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13 * zoomLevel, weight: .regular)
                attributes[.foregroundColor] = NSColor.systemPurple
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
