import SwiftUI
import AppKit

/// NSTextView-based markdown renderer with full text selection support
struct MarkdownTextView: NSViewRepresentable {
    let content: String
    let baseURL: URL?
    let directoryBookmark: Data?
    /// Identifies which open document this pane is currently displaying. Threaded through to
    /// the Coordinator and stamped on every posted `.diagramRendered` notification so a
    /// diagram/math render completing in one pane cannot invalidate another pane's cache
    /// (Plan 003 — was previously a global, unscoped notification).
    let documentId: UUID
    @Binding var scrollToHeadingId: String?
    let searchText: String
    let currentMatchIndex: Int
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

    init(content: String, baseURL: URL?, directoryBookmark: Data? = nil, documentId: UUID, scrollToHeadingId: Binding<String?>, searchText: String, currentMatchIndex: Int, fontStyle: SettingsManager.FontStyle, zoomLevel: CGFloat = 1.0, initialScrollPosition: CGFloat = 0, onScrollPositionChanged: ((CGFloat) -> Void)? = nil, onMatchCountChanged: ((Int) -> Void)? = nil, onScrollPercentChanged: ((CGFloat) -> Void)? = nil, scrollToPercent: CGFloat? = nil, isRegexSearch: Bool = false, isCaseSensitive: Bool = false) {
        self.content = content
        self.baseURL = baseURL
        self.directoryBookmark = directoryBookmark
        self.documentId = documentId
        self._scrollToHeadingId = scrollToHeadingId
        self.searchText = searchText
        self.currentMatchIndex = currentMatchIndex
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
        context.coordinator.documentId = documentId
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

        // Listen for diagram render completions. Registered with object: nil (rather than
        // filtering here via NotificationCenter's own object-equality matching) because the
        // poster's object is a UUID value type — NotificationCenter's object filter is not
        // documented/reliable for value-type identity, so filtering happens explicitly inside
        // diagramDidRender(_:) instead (Plan 003).
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.diagramDidRender(_:)),
            name: .diagramRendered,
            object: nil
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Captured BEFORE the reassignment below so we can tell a tab/document switch apart
        // from a same-document content edit (Plan 009) — the coordinator is reused across
        // document switches within a pane (see comment below), so `documentId` itself always
        // reads as "current" by the time the debounce decision is made unless we snapshot the
        // prior value first.
        let previousDocumentId = context.coordinator.documentId

        // Coordinator instances are reused across document switches within the same pane
        // (same view identity, new `content`/`documentId` params) — refresh this on every
        // pass so the diagram-render filter always reflects what's CURRENTLY displayed, not
        // whichever document this pane showed when the NSView was first created (Plan 003).
        context.coordinator.documentId = documentId

        // Check if content changed
        let contentChanged = context.coordinator.lastContent != content
        let searchChanged = context.coordinator.lastSearchText != searchText
            || context.coordinator.lastIsRegex != isRegexSearch
            || context.coordinator.lastIsCaseSensitive != isCaseSensitive
        let matchIndexChanged = context.coordinator.lastMatchIndex != currentMatchIndex
        let zoomChanged = context.coordinator.lastZoomLevel != zoomLevel
        let documentSwitched = previousDocumentId != documentId
        // `lastContent == nil` covers both "first render of a fresh/reused Coordinator" and
        // "diagram-render-forced rebuild" (diagramDidRender resets `lastContent` to nil to force
        // a rebuild, Plan 003) — neither is live typing, so both must rebuild immediately rather
        // than ride the typing debounce below.
        let isFreshOrForcedRebuild = context.coordinator.lastContent == nil

        // Keep the Coordinator's mode flags in sync so a future tick can detect the NEXT toggle.
        context.coordinator.lastIsRegex = isRegexSearch
        context.coordinator.lastIsCaseSensitive = isCaseSensitive

        // Full rebuild when content or zoom changes. Debounce ONLY a same-document content edit
        // (live typing) with no zoom change — everything else (zoom, tab/document switch, first
        // render, diagram-render-forced rebuild) rebuilds with zero delay (Plan 009).
        if contentChanged || zoomChanged {
            context.coordinator.lastZoomLevel = zoomLevel
            let isPureContentEdit = contentChanged && !zoomChanged && !documentSwitched && !isFreshOrForcedRebuild
            context.coordinator.scheduleRebuild(
                for: self,
                textView: textView,
                scrollView: scrollView,
                contentChanged: contentChanged,
                immediate: !isPureContentEdit
            )
        }
        // Lightweight search update — no full rebuild needed
        else if searchChanged {
            context.coordinator.lastSearchText = searchText

            // Clear only the ranges we previously painted — as TEMPORARY attributes, matching
            // how updateMatchHighlighting paints them. (A storage-level removeAttribute here
            // would clear nothing — the highlights aren't in the storage — while still wiping
            // the tracking list, orphaning the painted ranges forever. That was exactly the
            // stuck-highlight-after-clearing-the-query bug.)
            if let layoutManager = textView.layoutManager, let storage = textView.textStorage {
                for r in context.coordinator.searchHighlightRanges where r.location + r.length <= storage.length {
                    layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
                    layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r)
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
                context.coordinator.reportMatchCount(0)
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
        // Which open document this pane is CURRENTLY displaying — refreshed on every
        // updateNSView pass (see comment there). Used to filter incoming .diagramRendered
        // notifications so a render belonging to a different document/pane is ignored (Plan 003).
        var documentId: UUID?
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
        // Coalesces the preview rebuild (full re-parse + NSAttributedString build) while the
        // user is actively typing in split/source mode, so each keystroke doesn't force a
        // synchronous main-thread re-parse of the whole document (Plan 009). Only gates *this
        // pane's reaction* to a content change — DocumentManager.updateContent stays fully
        // synchronous, so save/source-editor content is never delayed or dropped.
        private var rebuildDebounceTimer: Timer?
        // Image cache shared across renders
        static var imageCache: NSCache<NSString, NSImage> = {
            let cache = NSCache<NSString, NSImage>()
            cache.countLimit = Cache.imageCountLimit
            cache.totalCostLimit = Cache.imageByteLimit
            return cache
        }()
        static var remoteImageInFlight: Set<String> = []
        static var remoteImageFailures: Set<String> = []
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

        // MARK: - Preview Rebuild (debounced during typing, Plan 009)

        /// Entry point `updateNSView` routes every full-rebuild trigger through. `immediate`
        /// distinguishes live typing (debounced 150ms, coalescing a burst of keystrokes into one
        /// rebuild) from everything else — zoom changes, tab/document switches, first render, and
        /// diagram-render-forced rebuilds (Plan 003) — which must land with zero delay. `parent`
        /// is captured as a value-type snapshot at the moment of the call, so a debounced timer
        /// firing later always rebuilds against the content that was current when it was
        /// (re)scheduled — each keystroke re-invalidates and reschedules with the latest snapshot,
        /// so the final edit after typing stops is never dropped.
        func scheduleRebuild(for parent: MarkdownTextView, textView: NSTextView, scrollView: NSScrollView, contentChanged: Bool, immediate: Bool) {
            if immediate {
                rebuildDebounceTimer?.invalidate()
                rebuildDebounceTimer = nil
                performRebuild(for: parent, textView: textView, scrollView: scrollView, contentChanged: contentChanged)
                return
            }
            rebuildDebounceTimer?.invalidate()
            rebuildDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.rebuildDebounceTimer = nil
                    self?.performRebuild(
                        for: parent,
                        textView: textView,
                        scrollView: scrollView,
                        contentChanged: contentChanged
                    )
                }
            }
        }

        /// Does the actual re-parse + NSAttributedString rebuild, plus every side effect that
        /// used to sit directly in `updateNSView`'s `if contentChanged || zoomChanged` block
        /// (search-match repopulation/highlighting, scroll-position restore, scroll-to-match) —
        /// moved here so they run against the freshly rebuilt text storage regardless of whether
        /// this was reached immediately or after the debounce delay.
        private func performRebuild(for parent: MarkdownTextView, textView: NSTextView, scrollView: NSScrollView, contentChanged: Bool) {
            let (attributedString, headingRanges) = parent.buildAttributedString(coordinator: self)
            textView.textStorage?.setAttributedString(attributedString)
            self.headingRanges = headingRanges
            self.lastContent = parent.content
            self.lastSearchText = parent.searchText

            // Find and store all match ranges in the rendered text
            if !parent.searchText.isEmpty {
                findMatchRanges(for: parent.searchText, isRegex: parent.isRegexSearch, isCaseSensitive: parent.isCaseSensitive, in: textView)
            } else {
                matchRanges = []
            }
            // C6: paint the flag-aware match ranges onto the freshly rebuilt storage.
            updateMatchHighlighting(currentIndex: parent.currentMatchIndex, in: textView, searchText: parent.searchText)

            // Restore scroll position after content is set (only on content change, not zoom)
            if contentChanged {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let pinY = self.pendingDiagramScrollY {
                        // Diagram-render rebuild: clamp scroll back to the exact Y the user
                        // was at before the rebuild.
                        self.pendingDiagramScrollY = nil
                        self.restoreScrollPosition(pinY, in: scrollView)
                    } else if parent.initialScrollPosition > 10 && parent.searchText.isEmpty {
                        self.restoreScrollPosition(parent.initialScrollPosition, in: scrollView)
                    } else if parent.searchText.isEmpty {
                        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                }
            }

            // Scroll to first match if searching
            if !parent.searchText.isEmpty && !matchRanges.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.scrollToMatch(at: parent.currentMatchIndex, in: textView)
                }
            }
        }

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
                Task { @MainActor [weak self] in
                    self?.isProgrammaticScroll = false
                }
            })
            scrollView.reflectScrolledClipView(scrollView.contentView)

            // Briefly highlight the heading. The text storage can be rebuilt while the delayed
            // clear is pending, so validate the captured range before touching the selection.
            let storageLength = textView.textStorage?.length ?? textView.string.utf16.count
            guard NSMaxRange(range) <= storageLength else { return }
            textView.setSelectedRange(range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let currentLength = textView.textStorage?.length ?? textView.string.utf16.count
                guard range.location <= currentLength else { return }
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

        /// Deliver the match count on the next runloop turn. All callers run inside
        /// updateNSView — i.e. during the SwiftUI update pass — and the callback writes a
        /// @Published property on DocumentManager; publishing synchronously from within a view
        /// update is undefined behavior (dropped updates, runtime warning).
        func reportMatchCount(_ count: Int) {
            let cb = onMatchCountChanged
            DispatchQueue.main.async { cb?(count) }
        }

        func findMatchRanges(for searchText: String, isRegex: Bool, isCaseSensitive: Bool, in textView: NSTextView) {
            matchRanges = []
            guard let storage = textView.textStorage, !searchText.isEmpty else {
                reportMatchCount(0)
                return
            }

            let string = storage.string as NSString

            if isRegex {
                var options: NSRegularExpression.Options = []
                if !isCaseSensitive { options.insert(.caseInsensitive) }
                guard let regex = try? NSRegularExpression(pattern: searchText, options: options) else {
                    reportMatchCount(0)
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

            // Report match count back (deferred — see reportMatchCount)
            reportMatchCount(matchRanges.count)
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
            guard let layoutManager = textView.layoutManager,
                  let storage = textView.textStorage else { return }

            // Paint search highlights as the layout manager's TEMPORARY attributes, never
            // into the text storage. Storage-level painting caused a visible bug: the black
            // .foregroundColor forced onto matches could not be reliably cleared (the
            // original token color is unknown at clear time), so every character that
            // matched an earlier prefix of the query ("h", "hi", …) stayed permanently
            // black — invisible in dark mode — until the next full rebuild. Temporary
            // attributes are render-only overlays; removing them restores the underlying
            // storage attributes exactly, with no bookkeeping of original colors needed.
            for r in searchHighlightRanges where r.location + r.length <= storage.length {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r)
            }
            searchHighlightRanges.removeAll(keepingCapacity: true)

            // Re-apply highlighting to all matches
            for (index, range) in matchRanges.enumerated() {
                guard range.location + range.length <= storage.length else { continue }
                let isCurrent = index == currentIndex
                let bgColor = isCurrent ? NSColor.systemOrange : NSColor.systemYellow.withAlphaComponent(0.5)
                layoutManager.addTemporaryAttributes([
                    .backgroundColor: bgColor,
                    .foregroundColor: NSColor.black
                ], forCharacterRange: range)
                searchHighlightRanges.append(range)
            }
        }

        // Debounce diagram-render notifications so a doc with N Mermaid/KaTeX blocks doesn't
        // force N full rebuilds during initial open (M2). 100ms is below the perceptible-flicker
        // threshold and comfortably groups the burst from a normal multi-diagram doc.
        private var diagramCoalesceTimer: Timer?

        // Plan 003: every open pane's coordinator registers for this notification (object: nil
        // — see registration comment in makeNSView), so without filtering, a diagram/math
        // render completing in ANY tab/pane would clear every OTHER open pane's elementCache
        // and force a full re-parse, even for documents with no diagrams at all. Filter to only
        // the document this pane is currently displaying.
        @objc func diagramDidRender(_ notification: Notification) {
            guard let renderedDocumentId = notification.object as? UUID,
                  let myDocumentId = self.documentId,
                  renderedDocumentId == myDocumentId else { return }
            diagramCoalesceTimer?.invalidate()
            diagramCoalesceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Re-check identity at fire time, not just at notification-arrival time.
                    guard self.documentId == myDocumentId else { return }
                    if let scrollView = self.scrollView {
                        self.pendingDiagramScrollY = scrollView.contentView.bounds.origin.y
                    }
                    self.lastContent = nil
                    self.elementCache.removeAll()
                    DocumentManager.shared.diagramRenderTicks[myDocumentId, default: 0] &+= 1
                }
            }
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }

            // Debounce scroll position saving
            scrollDebounceTimer?.invalidate()
            scrollDebounceTimer = Timer.scheduledTimer(withTimeInterval: Timing.scrollPositionPersistDebounce, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self, weak clipView] in
                    guard let clipView else { return }
                    self?.onScrollPositionChanged?(clipView.bounds.origin.y)
                }
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
                        Task { @MainActor [weak self] in
                            self?.isUserScrolling = false
                        }
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
                Task { @MainActor [weak self] in
                    self?.isProgrammaticScroll = false
                }
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        deinit {
            MainActor.assumeIsolated {
                scrollDebounceTimer?.invalidate()
                syncDebounceTimer?.invalidate()
                diagramCoalesceTimer?.invalidate()
                rebuildDebounceTimer?.invalidate()
                NotificationCenter.default.removeObserver(self)
            }
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

        // C6: search highlighting is applied after the rebuild via updateMatchHighlighting (which
        // paints the ranges from findMatchRanges, honoring regex and case-sensitive mode), not here
        // with a literal case-insensitive search that ignored those flags.

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
            let highlightedLine = SyntaxHighlighter.shared.highlight(code: line, language: language, fontSize: 13 * zoomLevel)
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

        result.append(formatInlineMarkdown(text, attributes: attributes))
        result.append(NSAttributedString(string: "\n", attributes: attributes))
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

            let displayImage = (image.copy() as? NSImage) ?? image
            displayImage.size = newSize
            attachment.image = displayImage

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
            guard !Coordinator.remoteImageFailures.contains(cacheKey),
                  !Coordinator.remoteImageInFlight.contains(cacheKey),
                  let url = URL(string: path) else {
                return nil
            }

            Coordinator.remoteImageInFlight.insert(cacheKey)
            // Captured locally (not via implicit `self`) so the notification carries the
            // document this image load belongs to — a different pane's coordinator ignores it
            // (Plan 003).
            let docId = documentId
            // URLSession instead of the old synchronous NSImage(contentsOf:) on a global queue —
            // that path had no timeout, so a hung server pinned a dispatch thread indefinitely.
            Task {
                let image: NSImage?
                if let (data, _) = try? await URLSession.shared.data(from: url) {
                    image = NSImage(data: data)
                } else {
                    image = nil
                }
                await MainActor.run {
                    Coordinator.remoteImageInFlight.remove(cacheKey)
                    guard let image = image else {
                        Coordinator.remoteImageFailures.insert(cacheKey)
                        return
                    }

                    Coordinator.remoteImageFailures.remove(cacheKey)
                    Coordinator.imageCache.setObject(image, forKey: cacheKey as NSString)
                    NotificationCenter.default.post(name: .diagramRendered, object: docId)
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

            // Captured locally so the notification carries the document this diagram belongs
            // to — a different pane's coordinator ignores it (Plan 003).
            let docId = documentId
            Task { @MainActor in
                WebRenderer.shared.renderMermaid(code) { image in
                    guard let image = image else { return }
                    Coordinator.diagramCache.setObject(image, forKey: cacheKey as NSString)
                    NotificationCenter.default.post(name: .diagramRendered, object: docId)
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

            // Captured locally so the notification carries the document this math block
            // belongs to — a different pane's coordinator ignores it (Plan 003).
            let docId = documentId
            Task { @MainActor in
                WebRenderer.shared.renderMath(latex, displayMode: true) { image in
                    guard let image = image else { return }
                    Coordinator.diagramCache.setObject(image, forKey: cacheKey as NSString)
                    NotificationCenter.default.post(name: .diagramRendered, object: docId)
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

    private func formatInlineMarkdown(_ text: String, attributes: [NSAttributedString.Key: Any], stripCodeSpanSentinel: Bool = true) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 16)

        for token in InlineMarkdown.tokenize(text) {
            var tokenAttributes = attributes
            switch token {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: tokenAttributes))
            case .lineBreak:
                result.append(NSAttributedString(string: "\n", attributes: tokenAttributes))
            case .code(let text):
                tokenAttributes[Self.codeSpanSentinel] = true
                tokenAttributes[.font] = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
                tokenAttributes[.backgroundColor] = NSColor.separatorColor.withAlphaComponent(0.15)
                result.append(NSAttributedString(string: text, attributes: tokenAttributes))
            case .math(let text):
                result.append(NSAttributedString(string: "$\(text)$", attributes: tokenAttributes))
            case .strong(let text):
                tokenAttributes[.font] = baseFont.withWeight(.bold)
                result.append(formatInlineMarkdown(text, attributes: tokenAttributes, stripCodeSpanSentinel: false))
            case .emphasis(let text):
                tokenAttributes[.font] = baseFont.withTraits(.italic)
                result.append(formatInlineMarkdown(text, attributes: tokenAttributes, stripCodeSpanSentinel: false))
            case .strikethrough(let text):
                tokenAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                result.append(formatInlineMarkdown(text, attributes: tokenAttributes, stripCodeSpanSentinel: false))
            case .highlight(let text):
                tokenAttributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.35)
                result.append(formatInlineMarkdown(text, attributes: tokenAttributes, stripCodeSpanSentinel: false))
            case .image(let alt, let source):
                if let image = loadImage(path: source) {
                    let attachment = NSTextAttachment()
                    let maxHeight = baseFont.pointSize * 2.2
                    let scale = image.size.height > 0 ? min(1.0, maxHeight / image.size.height) : 1.0
                    let displaySize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                    let displayImage = (image.copy() as? NSImage) ?? image
                    displayImage.size = displaySize
                    attachment.image = displayImage
                    attachment.bounds = CGRect(x: 0, y: -4, width: displaySize.width, height: displaySize.height)
                    let replacement = NSMutableAttributedString(attachment: attachment)
                    replacement.addAttributes(tokenAttributes, range: NSRange(location: 0, length: replacement.length))
                    result.append(replacement)
                } else {
                    let label = "[Image: \(alt.isEmpty ? source : alt)]"
                    result.append(NSAttributedString(string: label, attributes: tokenAttributes))
                }
            case .link(let label, let destination):
                tokenAttributes[.link] = URL(string: destination)
                tokenAttributes[.foregroundColor] = NSColor.linkColor
                tokenAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                result.append(formatInlineMarkdown(label, attributes: tokenAttributes, stripCodeSpanSentinel: false))
            }
        }

        // Inline math $...$ — moved up to run BEFORE bold/italic/strike (M3) so a math span like
        // `$a^{**}$` doesn't get its `**` consumed by the bold pass.
        applyInlineMathPattern(to: result)

        // Strip the sentinel before returning so it doesn't ride along into NSTextStorage.
        if stripCodeSpanSentinel {
            let fullRange = NSRange(location: 0, length: result.length)
            result.removeAttribute(Self.codeSpanSentinel, range: fullRange)
        }

        return result
    }

    private static var regexCache: [String: NSRegularExpression] = [:]

    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        if let cached = regexCache[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache[pattern] = regex
        return regex
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
            if rangeIntersectsCodeSpan(fullRange, in: result) { continue }

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

                // Captured locally so the notification carries the document this inline math
                // belongs to — a different pane's coordinator ignores it (Plan 003).
                let docId = documentId
                Task { @MainActor in
                    WebRenderer.shared.renderMath(latex, displayMode: false) { image in
                        guard let image = image else { return }
                        Coordinator.diagramCache.setObject(image, forKey: cacheKey as NSString)
                        NotificationCenter.default.post(name: .diagramRendered, object: docId)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

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
