import SwiftUI
import AppKit

struct SourceEditorView: NSViewRepresentable {
    @Binding var content: String
    let onContentChange: ((String) -> Void)?
    var zoomLevel: CGFloat = 1.0
    var onScrollPercentChanged: ((CGFloat) -> Void)?
    var scrollToPercent: CGFloat?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 40, height: 30)
        textView.font = NSFont.monospacedSystemFont(ofSize: 14 * zoomLevel, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
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

        textView.string = content
        context.coordinator.applyHighlighting(to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.onScrollPercentChanged = onScrollPercentChanged

        // Update zoom level if changed
        if context.coordinator.zoomLevel != zoomLevel {
            context.coordinator.zoomLevel = zoomLevel
            textView.font = NSFont.monospacedSystemFont(ofSize: 14 * zoomLevel, weight: .regular)
            context.coordinator.applyHighlighting(to: textView)
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
        var textView: NSTextView?
        var scrollView: NSScrollView?
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
