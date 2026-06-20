import SwiftUI
import AppKit

struct SourceEditorView: NSViewRepresentable {
    @Binding var content: String
    let onContentChange: ((String) -> Void)?
    /// Identity of the document this editor is bound to. updateNSView compares it against the
    /// coordinator's last-bound id to detect a document switch, so the text view is re-synced (and
    /// its undo reset) even when it holds focus — otherwise switching tabs while the editor kept
    /// first-responder left it showing, and then saving, the PREVIOUS document's text (data loss).
    let documentId: UUID
    var zoomLevel: CGFloat = 1.0
    var onScrollPercentChanged: ((CGFloat) -> Void)?
    var scrollToPercent: CGFloat?
    /// Callback handed the NSTextView + NSScrollView once they're constructed.
    /// Used by the parent to wire the optional minimap (MinimapView needs live references to
    /// both the text view and its scroll view to draw the viewport indicator).
    var onViewsReady: ((NSTextView, NSScrollView) -> Void)?

    // Search highlight inputs. When `searchText` is non-empty the editor paints `.backgroundColor`
    // on every match in `searchMatches`, with the match at `currentMatchIndex` painted in an
    // accent color so the user can see which one Replace/Next/Prev will act on. Source-mode find
    // bar previously had no visual feedback at all (matches lit up only in the preview pane).
    var searchText: String = ""
    var searchMatches: [SearchMatch] = []
    var currentMatchIndex: Int = 0

    func makeNSView(context: Context) -> NSScrollView {
        // Build NSScrollView + EditorTextView manually so we get our NSTextView subclass with
        // multi-cursor, auto-close brackets, snippet autocomplete, Cmd+/ comment toggle, line-move
        // shortcuts, and thin caret. NSTextView.scrollableTextView() would hand back a vanilla
        // NSTextView and none of that functionality would be reachable.
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor

        let contentSize = scrollView.contentSize
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = EditorTextView(
            frame: NSRect(origin: .zero, size: contentSize),
            textContainer: textContainer
        )
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 40, height: 30)
        textView.font = NSFont.monospacedSystemFont(ofSize: 14 * zoomLevel, weight: .regular)
        textView.textColor = NSColor.textColor

        scrollView.documentView = textView

        // Line number gutter
        let settings = SettingsManager.shared
        if settings.showLineNumbers {
            let gutter = LineNumberGutter(scrollView: scrollView, orientation: .verticalRuler)
            scrollView.verticalRulerView = gutter
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.zoomLevel = zoomLevel
        context.coordinator.onScrollPercentChanged = onScrollPercentChanged
        context.coordinator.searchText = searchText
        context.coordinator.searchMatches = searchMatches
        context.coordinator.currentMatchIndex = currentMatchIndex

        // Scroll sync
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        textView.string = content
        context.coordinator.boundDocumentId = documentId
        context.coordinator.applyHighlighting(to: textView)

        // Hand references to the parent so it can render an optional minimap alongside us.
        // Deferred to main-async to ensure the scroll view's layout has resolved before
        // MinimapView reads its document/frame dimensions.
        DispatchQueue.main.async { [weak textView, weak scrollView] in
            if let tv = textView, let sv = scrollView {
                self.onViewsReady?(tv, sv)
            }
        }

        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if context.coordinator.isUpdatingFromUser { return }

        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.onScrollPercentChanged = onScrollPercentChanged

        if context.coordinator.zoomLevel != zoomLevel {
            context.coordinator.zoomLevel = zoomLevel
            let newFont = NSFont.monospacedSystemFont(ofSize: 14 * zoomLevel, weight: .regular)
            textView.font = newFont
            // typingAttributes must be updated explicitly so the next character typed uses the
            // new font size — NSTextView does not always recompute from caret context after a
            // full font override.
            textView.typingAttributes = [
                .font: newFont,
                .foregroundColor: NSColor.textColor
            ]
            context.coordinator.applyHighlighting(to: textView)
            // Redraw gutter to pick up its new scaled font size.
            if let gutter = scrollView.verticalRulerView {
                gutter.needsDisplay = true
            }
        }

        // Runtime toggle for the gutter so the setting takes effect immediately instead of
        // requiring the editor view to be torn down and rebuilt.
        let wantsGutter = SettingsManager.shared.showLineNumbers
        let hasGutter = scrollView.verticalRulerView is LineNumberGutter
        if wantsGutter && !hasGutter {
            let gutter = LineNumberGutter(scrollView: scrollView, orientation: .verticalRuler)
            scrollView.verticalRulerView = gutter
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        } else if !wantsGutter && hasGutter {
            scrollView.rulersVisible = false
            scrollView.hasVerticalRuler = false
        }

        // Sync the NSTextView from the binding. Two cases:
        // 1. Document switch (boundDocumentId changed): the active document changed under us. A
        //    switch is NOT an in-flight edit, so replace the content even when the editor has focus,
        //    and reset undo (undo must not cross documents). Without this, switching tabs while the
        //    editor kept first-responder left it showing — and then saving — the PREVIOUS document's
        //    text into the newly-selected file (data loss).
        // 2. Same document, editor not focused: keep the original guard so we don't clobber in-flight
        //    typing during unrelated state updates (save/isDirty/zoom).
        let textViewHasFocus = (textView.window?.firstResponder == textView)
        if context.coordinator.boundDocumentId != documentId {
            context.coordinator.boundDocumentId = documentId
            if textView.string != content {
                textView.string = content
                context.coordinator.invalidateCursorPositionCache()
                context.coordinator.applyHighlighting(to: textView)
            }
            textView.undoManager?.removeAllActions()
        } else if !textViewHasFocus && textView.string != content {
            let selectedRanges = textView.selectedRanges
            textView.string = content
            textView.selectedRanges = selectedRanges
            context.coordinator.invalidateCursorPositionCache()  // P3: programmatic replace, no textDidChange
            context.coordinator.applyHighlighting(to: textView)
        }

        // Search highlight diff — repaint only when something actually changed. Without this guard,
        // every unrelated state update (zoom, scroll-percent push, etc.) repaints the whole storage,
        // which is both wasteful and can fight with active typing.
        let coord = context.coordinator
        let matchIDs = searchMatches.map(\.id)
        if coord.searchText != searchText
            || coord.lastMatchIDs != matchIDs
            || coord.currentMatchIndex != currentMatchIndex {
            coord.searchText = searchText
            coord.searchMatches = searchMatches
            coord.currentMatchIndex = currentMatchIndex
            coord.lastMatchIDs = matchIDs
            coord.applyHighlighting(to: textView)
        }

        if let percent = scrollToPercent, !context.coordinator.isUserScrolling {
            context.coordinator.scrollToPercent(percent, in: scrollView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onContentChange: onContentChange)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var textView: NSTextView?
        var scrollView: NSScrollView?
        var isUpdatingFromUser = false
        var isUserScrolling = false
        // Identity of the document currently loaded into the text view. updateNSView compares this
        // against the bound documentId to detect a document switch and force a content re-sync.
        var boundDocumentId: UUID?
        var zoomLevel: CGFloat = 1.0
        var onScrollPercentChanged: ((CGFloat) -> Void)?
        let onContentChange: ((String) -> Void)?
        private var highlightTimer: Timer?
        private var autocompleteTimer: Timer?
        private var scrollDebounceTimer: Timer?
        private var isProgrammaticScroll = false

        // Search highlight state mirrored from SourceEditorView so applyHighlighting can paint
        // match backgrounds. lastMatchIDs is just the dedupe key for updateNSView.
        var searchText: String = ""
        var searchMatches: [SearchMatch] = []
        var currentMatchIndex: Int = 0
        var lastMatchIDs: [UUID] = []

        // Timestamp of the most recent textDidChange. Used by textViewDidChangeSelection to
        // distinguish caret movement caused by text insertion (don't dismiss autocomplete) from
        // caret movement caused by arrow keys / click (do dismiss). AppKit fires textDidChange
        // immediately before textViewDidChangeSelection on the same runloop turn for inserts, so
        // a 50ms window safely catches the caret-from-insert case.
        private var lastTextChangeTimestamp: Date = .distantPast

        // P3: cache the last computed (caret, line) so caret movement (arrow keys, clicks) counts
        // newlines only over the small delta region instead of rescanning [0, caret) every time.
        // Valid only while the text is unchanged; textDidChange invalidates it. AppKit fires
        // textDidChange before the selection-change notification for edits, so the delta path only
        // runs over an immutable buffer and stays exact.
        private var cursorCacheValid = false
        private var cursorCacheCaret = 0
        private var cursorCacheLine = 1

        /// P3: invalidate the cursor (caret, line) cache. Called on user edits (textDidChange) and
        /// on programmatic content replacement in updateNSView, which does not fire textDidChange.
        func invalidateCursorPositionCache() {
            cursorCacheValid = false
        }

        /// Count 0x0A (newline) UTF-16 units in text[from..<to]. Disjoint across successive caret
        /// moves, so amortized cost tracks how far the caret travels, not document size.
        private func newlineCount(in text: NSString, from: Int, to: Int) -> Int {
            var count = 0
            var i = from
            while i < to {
                if text.character(at: i) == 0x0A { count += 1 }
                i += 1
            }
            return count
        }

        init(onContentChange: ((String) -> Void)?) {
            self.onContentChange = onContentChange
            super.init()
        }

        deinit {
            teardown()
        }

        /// Tear down observers, timers, and delegate references. Invoked from both `deinit` and
        /// `dismantleNSView` so SwiftUI can release us without dangling timers firing on a zombie self.
        /// Previously none of this was released, leaving 0.3s highlight timers and scroll observers
        /// live after the view was destroyed.
        func teardown() {
            highlightTimer?.invalidate()
            highlightTimer = nil
            autocompleteTimer?.invalidate()
            autocompleteTimer = nil
            scrollDebounceTimer?.invalidate()
            scrollDebounceTimer = nil
            NotificationCenter.default.removeObserver(self)
            textView?.delegate = nil
            textView = nil
            scrollView = nil
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard !isProgrammaticScroll else { return }
            guard let scrollView = scrollView,
                  let documentView = scrollView.documentView else { return }

            let contentHeight = documentView.frame.height
            let viewportHeight = scrollView.contentView.bounds.height
            let scrollableHeight = contentHeight - viewportHeight
            guard scrollableHeight > 0 else { return }

            let currentOffset = scrollView.contentView.bounds.origin.y
            let percent = min(1.0, max(0.0, currentOffset / scrollableHeight))

            isUserScrolling = true
            scrollDebounceTimer?.invalidate()
            scrollDebounceTimer = Timer.scheduledTimer(withTimeInterval: Timing.scrollSyncDebounce, repeats: false) { [weak self] _ in
                self?.isUserScrolling = false
            }

            onScrollPercentChanged?(percent)
        }

        func scrollToPercent(_ percent: CGFloat, in scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
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

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            lastTextChangeTimestamp = Date()
            cursorCacheValid = false  // P3: text changed — the cached (caret, line) is now stale.
            isUpdatingFromUser = true
            onContentChange?(textView.string)

            DispatchQueue.main.async { [weak self] in
                self?.isUpdatingFromUser = false
            }

            // Debounced syntax highlighting
            highlightTimer?.invalidate()
            highlightTimer = Timer.scheduledTimer(withTimeInterval: Timing.highlightDebounce, repeats: false) { [weak self] _ in
                self?.applyHighlighting(to: textView)
            }

            // Debounced autocomplete trigger (EditorTextView only).
            autocompleteTimer?.invalidate()
            autocompleteTimer = Timer.scheduledTimer(withTimeInterval: Timing.autocompleteDebounce, repeats: false) { [weak self, weak textView] _ in
                guard let self = self,
                      let editor = textView as? EditorTextView else { return }
                self.triggerAutocomplete(in: editor)
            }

            // Update gutter
            if let scrollView = scrollView, let gutter = scrollView.verticalRulerView {
                gutter.needsDisplay = true
            }
        }

        /// Build completions for the word/HTML-tag at the cursor and show the panel.
        /// Silent no-op when no prefix is eligible; never interrupts mid-word typing because the
        /// trigger is debounced 300ms (via autocompleteTimer) after the user pauses.
        private func triggerAutocomplete(in editor: EditorTextView) {
            let text = editor.string as NSString
            let cursor = editor.selectedRange().location
            guard cursor <= text.length else { return }

            // HTML tag trigger: "<" immediately before cursor → show tag list
            if cursor > 0 {
                let prevChar = text.substring(with: NSRange(location: cursor - 1, length: 1))
                if prevChar == "<" {
                    editor.showCompletions(CompletionData.htmlCompletions(prefix: ""), triggerStart: cursor)
                    return
                }
            }

            // Word trigger: 3+ alphanum/underscore chars
            let wordStart = editor.findWordStart(at: cursor, in: text)
            let prefixLen = cursor - wordStart
            guard prefixLen >= 3 else { return }
            let prefix = text.substring(with: NSRange(location: wordStart, length: prefixLen))
            let items = CompletionData.completions(
                prefix: prefix,
                currentDocText: editor.string,
                allDocTexts: [editor.string]
            )
            guard !items.isEmpty else { return }
            editor.showCompletions(items, triggerStart: wordStart)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let scrollView = scrollView, let gutter = scrollView.verticalRulerView {
                gutter.needsDisplay = true
            }

            // Dismiss autocomplete if caret moved without a corresponding text change. Otherwise
            // an open popup confirms with `replaceCharacters(in: triggerRange, ...)` at the
            // ORIGINAL trigger location, silently rewriting unrelated text. Repro before fix:
            // type `code`, popup appears, press Left arrow once, press Enter → completion was
            // inserted at the original word position, mutilating text under the cursor.
            if let editor = notification.object as? EditorTextView, editor.autocomplete.isVisible {
                let elapsedSinceTextChange = Date().timeIntervalSince(lastTextChangeTimestamp)
                if elapsedSinceTextChange > 0.05 {
                    editor.autocomplete.dismiss()
                }
            }

            // Publish real cursor position so StatusBar shows accurate "Ln X, Col Y".
            // Previously StatusBar computed `cursorPosition(for: content)` as (line.count, 1)
            // which was effectively "end of file, column 1" — a visible lie.
            if let textView = notification.object as? NSTextView {
                let text = textView.string as NSString
                let caret = textView.selectedRange().location
                let clampedCaret = min(caret, text.length)

                // P3: line number from the cached (caret, line) by counting only the delta region,
                // falling back to a full count from 0 when the cache is invalid (after an edit).
                let line: Int
                if cursorCacheValid {
                    let anchor = min(cursorCacheCaret, text.length)
                    if clampedCaret >= anchor {
                        line = cursorCacheLine + newlineCount(in: text, from: anchor, to: clampedCaret)
                    } else {
                        line = cursorCacheLine - newlineCount(in: text, from: clampedCaret, to: anchor)
                    }
                } else {
                    line = newlineCount(in: text, from: 0, to: clampedCaret) + 1
                }
                cursorCacheCaret = clampedCaret
                cursorCacheLine = line
                cursorCacheValid = true

                // column: scan back to the previous newline (bounded by line length, always exact).
                var lineStart = clampedCaret
                while lineStart > 0 && text.character(at: lineStart - 1) != 0x0A { lineStart -= 1 }
                let col = clampedCaret - lineStart + 1  // 1-based

                DispatchQueue.main.async {
                    DocumentManager.shared.currentCursorLine = line
                    DocumentManager.shared.currentCursorColumn = col
                }
            }
        }

        func applyHighlighting(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let text = storage.string
            let fullRange = NSRange(location: 0, length: (text as NSString).length)

            storage.beginEditing()

            let fontSize = 14 * zoomLevel
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.textColor
            ], range: fullRange)

            let nsText = text as NSString
            highlightPattern(#"^#{1,6}\s+.*$"#, in: storage, text: nsText, color: .systemBlue, font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold))
            highlightPattern(#"\*\*[^\*]+\*\*"#, in: storage, text: nsText, color: .textColor, font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold))
            highlightPattern(#"(?<!\*)\*(?!\*)([^\*]+)(?<!\*)\*(?!\*)"#, in: storage, text: nsText, color: .textColor, font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular).withTraits(.italic))
            highlightPattern(#"~~[^~]+~~"#, in: storage, text: nsText, color: .systemGray)
            highlightPattern(#"`[^`]+`"#, in: storage, text: nsText, color: .systemOrange)
            highlightPattern(#"^```.*$"#, in: storage, text: nsText, color: .systemGray)
            highlightPattern(#"\[[^\]]+\]\([^\)]+\)"#, in: storage, text: nsText, color: .systemTeal)
            highlightPattern(#"^>\s+.*$"#, in: storage, text: nsText, color: .systemGreen)
            highlightPattern(#"^[\t ]*[-*+]\s"#, in: storage, text: nsText, color: .systemPurple)
            highlightPattern(#"^[\t ]*\d+\.\s"#, in: storage, text: nsText, color: .systemPurple)
            highlightPattern(#"\[[ xX]\]"#, in: storage, text: nsText, color: .systemIndigo)

            // Paint search match backgrounds last so they layer on top of token coloring.
            // Active match gets the system control-accent color for visibility against any token.
            if !searchText.isEmpty && !searchMatches.isEmpty {
                let plainColor = NSColor.systemYellow.withAlphaComponent(0.4)
                let activeColor = NSColor.controlAccentColor.withAlphaComponent(0.5)
                for (i, match) in searchMatches.enumerated() {
                    guard let nsRange = NSRange(match.range, in: text) as NSRange?,
                          nsRange.location + nsRange.length <= storage.length else { continue }
                    let color = (i == currentMatchIndex) ? activeColor : plainColor
                    storage.addAttribute(.backgroundColor, value: color, range: nsRange)
                }
            }

            storage.endEditing()
        }

        private static var regexCache: [String: NSRegularExpression] = [:]

        private func highlightPattern(_ pattern: String, in storage: NSTextStorage, text: NSString, color: NSColor, font: NSFont? = nil) {
            let regex: NSRegularExpression
            if let cached = Self.regexCache[pattern] {
                regex = cached
            } else {
                guard let created = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return }
                Self.regexCache[pattern] = created
                regex = created
            }

            for match in regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
                if let font = font {
                    storage.addAttribute(.font, value: font, range: match.range)
                }
            }
        }
    }
}
