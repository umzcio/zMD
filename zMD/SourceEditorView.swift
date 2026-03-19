import SwiftUI
import AppKit

struct SourceEditorView: NSViewRepresentable {
    @Binding var content: String
    let onContentChange: ((String) -> Void)?
    var zoomLevel: CGFloat = 1.0
    var onScrollPercentChanged: ((CGFloat) -> Void)?
    var scrollToPercent: CGFloat?

    func makeNSView(context: Context) -> NSView {
        let settings = SettingsManager.shared

        // Create EditorTextView with proper text system
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let editorTextView = EditorTextView(frame: .zero, textContainer: textContainer)
        editorTextView.isEditable = true
        editorTextView.isSelectable = true
        editorTextView.backgroundColor = NSColor.textBackgroundColor
        editorTextView.textContainerInset = NSSize(width: 40, height: 30)
        editorTextView.font = NSFont.monospacedSystemFont(ofSize: 14 * zoomLevel, weight: .regular)
        editorTextView.textColor = NSColor.textColor
        editorTextView.autoresizingMask = [.width, .height]
        editorTextView.isVerticallyResizable = true
        editorTextView.isHorizontallyResizable = false
        editorTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editorTextView.minSize = NSSize(width: 0, height: 0)

        // Apply settings
        editorTextView.tabWidth = settings.tabWidth
        editorTextView.autoCloseBrackets = settings.autoCloseBrackets

        // Create scroll view
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = editorTextView
        scrollView.drawsBackground = false

        // Line number gutter
        if settings.showLineNumbers {
            let gutter = LineNumberGutter(scrollView: scrollView, orientation: .verticalRuler)
            scrollView.verticalRulerView = gutter
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }

        // Container view to hold scrollView + minimap
        let containerView = NSView(frame: .zero)
        containerView.autoresizingMask = [.width, .height]

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(scrollView)

        // Minimap
        let minimapView = MinimapView(frame: .zero)
        minimapView.linkedTextView = editorTextView
        minimapView.linkedScrollView = scrollView
        minimapView.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.minimapView = minimapView

        if settings.showMinimap {
            containerView.addSubview(minimapView)

            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

                minimapView.topAnchor.constraint(equalTo: containerView.topAnchor),
                minimapView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                minimapView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
                minimapView.widthAnchor.constraint(equalToConstant: 80),

                scrollView.trailingAnchor.constraint(equalTo: minimapView.leadingAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            ])
        }

        editorTextView.delegate = context.coordinator
        context.coordinator.textView = editorTextView
        context.coordinator.scrollView = scrollView
        context.coordinator.zoomLevel = zoomLevel
        context.coordinator.onScrollPercentChanged = onScrollPercentChanged

        // Set up scroll notification for sync
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        editorTextView.string = content
        context.coordinator.applyHighlighting(to: editorTextView)

        return containerView
    }

    func updateNSView(_ containerView: NSView, context: Context) {
        guard let scrollView = context.coordinator.scrollView,
              let textView = context.coordinator.textView else { return }

        context.coordinator.onScrollPercentChanged = onScrollPercentChanged

        let settings = SettingsManager.shared
        textView.tabWidth = settings.tabWidth
        textView.autoCloseBrackets = settings.autoCloseBrackets

        // Update zoom level if changed
        if context.coordinator.zoomLevel != zoomLevel {
            context.coordinator.zoomLevel = zoomLevel
            textView.font = NSFont.monospacedSystemFont(ofSize: 14 * zoomLevel, weight: .regular)
            context.coordinator.applyHighlighting(to: textView)
        }

        // Toggle line numbers
        if settings.showLineNumbers {
            if scrollView.verticalRulerView == nil {
                let gutter = LineNumberGutter(scrollView: scrollView, orientation: .verticalRuler)
                scrollView.verticalRulerView = gutter
                scrollView.hasVerticalRuler = true
                scrollView.rulersVisible = true
            }
        } else {
            scrollView.rulersVisible = false
        }

        // Update minimap visibility
        if let minimap = context.coordinator.minimapView {
            minimap.isHidden = !settings.showMinimap
            minimap.invalidateContent()
        }

        // Skip update if user is currently typing (prevents cursor jump)
        if context.coordinator.isUpdatingFromUser { return }

        if textView.string != content {
            let selectedRanges = textView.selectedRanges
            textView.string = content
            textView.selectedRanges = selectedRanges
            context.coordinator.applyHighlighting(to: textView)
        }

        // Handle programmatic scroll from sync
        if let percent = scrollToPercent, !context.coordinator.isUserScrolling {
            context.coordinator.scrollToPercent(percent, in: scrollView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onContentChange: onContentChange)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var textView: EditorTextView?
        var scrollView: NSScrollView?
        var minimapView: MinimapView?
        var isUpdatingFromUser = false
        var isUserScrolling = false
        var zoomLevel: CGFloat = 1.0
        var onScrollPercentChanged: ((CGFloat) -> Void)?
        let onContentChange: ((String) -> Void)?
        private var highlightTimer: Timer?
        private var scrollDebounceTimer: Timer?
        private var isProgrammaticScroll = false

        init(onContentChange: ((String) -> Void)?) {
            self.onContentChange = onContentChange
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

            // Update minimap viewport indicator
            minimapView?.needsDisplay = true
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

            // Update minimap
            minimapView?.invalidateContent()

            // Update line number gutter
            if let scrollView = scrollView, let gutter = scrollView.verticalRulerView {
                gutter.needsDisplay = true
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Redraw gutter to update current line highlight
            if let scrollView = scrollView, let gutter = scrollView.verticalRulerView {
                gutter.needsDisplay = true
            }
        }

        func applyHighlighting(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let text = storage.string
            let fullRange = NSRange(location: 0, length: (text as NSString).length)

            storage.beginEditing()

            // Reset to default
            let fontSize = 14 * zoomLevel
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.textColor
            ], range: fullRange)

            let nsText = text as NSString

            // Headings (#)
            highlightPattern(#"^#{1,6}\s+.*$"#, in: storage, text: nsText, color: NSColor.systemBlue, font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold))

            // Bold **text**
            highlightPattern(#"\*\*[^\*]+\*\*"#, in: storage, text: nsText, color: NSColor.textColor, font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold))

            // Italic *text*
            highlightPattern(#"(?<!\*)\*(?!\*)([^\*]+)(?<!\*)\*(?!\*)"#, in: storage, text: nsText, color: NSColor.textColor, font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular).withTraits(.italic))

            // Strikethrough ~~text~~
            highlightPattern(#"~~[^~]+~~"#, in: storage, text: nsText, color: NSColor.systemGray)

            // Inline code `text`
            highlightPattern(#"`[^`]+`"#, in: storage, text: nsText, color: NSColor.systemOrange)

            // Code fences ```
            highlightPattern(#"^```.*$"#, in: storage, text: nsText, color: NSColor.systemGray)

            // Links [text](url)
            highlightPattern(#"\[[^\]]+\]\([^\)]+\)"#, in: storage, text: nsText, color: NSColor.systemTeal)

            // Blockquotes > text
            highlightPattern(#"^>\s+.*$"#, in: storage, text: nsText, color: NSColor.systemGreen)

            // List markers (-, *, +, 1.)
            highlightPattern(#"^[\t ]*[-*+]\s"#, in: storage, text: nsText, color: NSColor.systemPurple)
            highlightPattern(#"^[\t ]*\d+\.\s"#, in: storage, text: nsText, color: NSColor.systemPurple)

            // Task list markers
            highlightPattern(#"\[[ xX]\]"#, in: storage, text: nsText, color: NSColor.systemIndigo)

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

            let matches = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
            for match in matches {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
                if let font = font {
                    storage.addAttribute(.font, value: font, range: match.range)
                }
            }
        }
    }
}
