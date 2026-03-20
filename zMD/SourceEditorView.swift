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

        textView.textContainer?.widthTracksTextView = true

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

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if context.coordinator.isUpdatingFromUser { return }

        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.onScrollPercentChanged = onScrollPercentChanged

        if context.coordinator.zoomLevel != zoomLevel {
            context.coordinator.zoomLevel = zoomLevel
            textView.font = NSFont.monospacedSystemFont(ofSize: 14 * zoomLevel, weight: .regular)
            context.coordinator.applyHighlighting(to: textView)
        }

        if textView.string != content {
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
            registerForToolbarNotifications()
        }

        private func registerForToolbarNotifications() {
            let nc = NotificationCenter.default
            let names: [Notification.Name] = [
                .editorFormatBold, .editorFormatItalic, .editorFormatStrikethrough,
                .editorFormatInlineCode, .editorFormatCodeBlock, .editorInsertLink,
                .editorInsertImage, .editorInsertHR, .editorToggleHeading,
                .editorInsertUnorderedList, .editorInsertOrderedList, .editorInsertTaskList,
            ]
            for name in names {
                nc.addObserver(self, selector: #selector(handleToolbarAction(_:)), name: name, object: nil)
            }
        }

        @objc private func handleToolbarAction(_ notification: Notification) {
            guard let textView = textView else { return }
            let range = textView.selectedRange()
            let text = textView.string as NSString

            switch notification.name {
            case .editorFormatBold:
                wrapSelection("**", "**", placeholder: "bold text", in: textView)
            case .editorFormatItalic:
                wrapSelection("*", "*", placeholder: "italic text", in: textView)
            case .editorFormatStrikethrough:
                wrapSelection("~~", "~~", placeholder: "strikethrough", in: textView)
            case .editorFormatInlineCode:
                wrapSelection("`", "`", placeholder: "code", in: textView)
            case .editorFormatCodeBlock:
                let selected = range.length > 0 ? text.substring(with: range) : ""
                let replacement = "```\n\(selected)\n```"
                textView.insertText(replacement, replacementRange: range)
            case .editorInsertLink:
                if range.length > 0 {
                    let selected = text.substring(with: range)
                    textView.insertText("[\(selected)](url)", replacementRange: range)
                } else {
                    textView.insertText("[link text](url)", replacementRange: range)
                }
            case .editorInsertImage:
                if range.length > 0 {
                    let selected = text.substring(with: range)
                    textView.insertText("![\(selected)](image-url)", replacementRange: range)
                } else {
                    textView.insertText("![alt text](image-url)", replacementRange: range)
                }
            case .editorInsertHR:
                textView.insertText("\n---\n", replacementRange: range)
            case .editorToggleHeading:
                let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
                let line = text.substring(with: lineRange)
                var level = 0
                for ch in line { if ch == "#" { level += 1 } else { break } }
                if level == 0 {
                    textView.insertText("# " + line, replacementRange: lineRange)
                } else if level >= 6 {
                    var stripped = String(line.dropFirst(level))
                    if stripped.hasPrefix(" ") { stripped = String(stripped.dropFirst()) }
                    textView.insertText(stripped, replacementRange: lineRange)
                } else {
                    textView.insertText("#" + line, replacementRange: lineRange)
                }
            case .editorInsertUnorderedList:
                insertListPrefix("- ", in: textView)
            case .editorInsertOrderedList:
                insertListPrefix("1. ", in: textView)
            case .editorInsertTaskList:
                insertListPrefix("- [ ] ", in: textView)
            default:
                break
            }
        }

        private func wrapSelection(_ prefix: String, _ suffix: String, placeholder: String, in textView: NSTextView) {
            let range = textView.selectedRange()
            if range.length > 0 {
                let text = textView.string as NSString
                let selected = text.substring(with: range)
                textView.insertText(prefix + selected + suffix, replacementRange: range)
            } else {
                textView.insertText(prefix + placeholder + suffix, replacementRange: range)
            }
        }

        private func insertListPrefix(_ prefix: String, in textView: NSTextView) {
            let text = textView.string as NSString
            let range = textView.selectedRange()
            let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
            let line = text.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                textView.insertText(indent + String(trimmed.dropFirst(prefix.count)), replacementRange: lineRange)
            } else {
                let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                textView.insertText(indent + prefix + line.trimmingCharacters(in: .whitespaces), replacementRange: lineRange)
            }
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

            // Update gutter
            if let scrollView = scrollView, let gutter = scrollView.verticalRulerView {
                gutter.needsDisplay = true
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let scrollView = scrollView, let gutter = scrollView.verticalRulerView {
                gutter.needsDisplay = true
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
