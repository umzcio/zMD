import SwiftUI
import AppKit

struct SourceEditorView: NSViewRepresentable {
    @Binding var content: String
    let onContentChange: ((String) -> Void)?
    var zoomLevel: CGFloat = 1.0
    var onScrollPercentChanged: ((CGFloat) -> Void)?
    var scrollToPercent: CGFloat?
    /// Callback handed the NSTextView + NSScrollView once they're constructed.
    /// Used by the parent to wire the optional minimap (MinimapView needs live references to
    /// both the text view and its scroll view to draw the viewport indicator).
    var onViewsReady: ((NSTextView, NSScrollView) -> Void)?

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

        // Scroll sync
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        textView.string = content
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

        // Only overwrite from binding if the textView isn't the active editor —
        // otherwise we can clobber in-flight edits during save/isDirty updates.
        let textViewHasFocus = (textView.window?.firstResponder == textView)
        if !textViewHasFocus && textView.string != content {
            let selectedRanges = textView.selectedRanges
            textView.string = content
            textView.selectedRanges = selectedRanges
            context.coordinator.applyHighlighting(to: textView)
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
        var zoomLevel: CGFloat = 1.0
        var onScrollPercentChanged: ((CGFloat) -> Void)?
        let onContentChange: ((String) -> Void)?
        private var highlightTimer: Timer?
        private var autocompleteTimer: Timer?
        private var scrollDebounceTimer: Timer?
        private var isProgrammaticScroll = false

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
            scrollDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
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

            isUpdatingFromUser = true
            onContentChange?(textView.string)

            DispatchQueue.main.async { [weak self] in
                self?.isUpdatingFromUser = false
            }

            // Debounced syntax highlighting
            highlightTimer?.invalidate()
            highlightTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                self?.applyHighlighting(to: textView)
            }

            // Debounced autocomplete trigger (EditorTextView only).
            autocompleteTimer?.invalidate()
            autocompleteTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self, weak textView] _ in
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

            // Publish real cursor position so StatusBar shows accurate "Ln X, Col Y".
            // Previously StatusBar computed `cursorPosition(for: content)` as (line.count, 1)
            // which was effectively "end of file, column 1" — a visible lie.
            if let textView = notification.object as? NSTextView {
                let text = textView.string as NSString
                let caret = textView.selectedRange().location
                let clampedCaret = min(caret, text.length)
                // line: count newlines in [0, caret)
                var line = 1
                var lastNewline: Int = -1
                var i = 0
                while i < clampedCaret {
                    if text.character(at: i) == 0x0A {
                        line += 1
                        lastNewline = i
                    }
                    i += 1
                }
                let col = clampedCaret - lastNewline  // 1-based (lastNewline = -1 → col = caret + 1)
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
