import AppKit

class LineNumberGutter: NSRulerView {

    private var textView: NSTextView? {
        clientView as? NSTextView
    }

    private let gutterPadding: CGFloat = 12
    private let minWidth: CGFloat = 40

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = minWidth
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let text = textView.string as NSString
        let visibleRect = scrollView?.contentView.bounds ?? bounds
        let textInset = textView.textContainerInset

        // Background
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark ? NSColor(white: 0.12, alpha: 1.0) : NSColor(white: 0.96, alpha: 1.0)
        bgColor.setFill()
        rect.fill()

        // Separator line
        let separatorColor = isDark ? NSColor(white: 0.2, alpha: 1.0) : NSColor(white: 0.85, alpha: 1.0)
        separatorColor.setStroke()
        let separatorX = bounds.maxX - 0.5
        NSBezierPath.strokeLine(from: NSPoint(x: separatorX, y: rect.minY), to: NSPoint(x: separatorX, y: rect.maxY))

        // Calculate visible glyph range
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        // Current line for highlighting
        let selectedRange = textView.selectedRange()
        let currentLineRange = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))

        // Determine total line count for width calculation
        var totalLines = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            totalLines += 1
        }

        let digits = max(2, String(totalLines).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: lineNumberFont()]).width
        let newThickness = max(minWidth, CGFloat(digits) * digitWidth + gutterPadding * 2)
        if abs(ruleThickness - newThickness) > 1 {
            ruleThickness = newThickness
        }

        // Draw line numbers
        var lineNumber = 1
        // Count lines before visible range
        let preText = text.substring(to: visibleCharRange.location)
        lineNumber = preText.components(separatedBy: "\n").count

        var charIndex = visibleCharRange.location
        while charIndex < NSMaxRange(visibleCharRange) && charIndex < text.length {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)

            // Only draw the number for the first glyph range (not wrapped continuation)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            lineRect.origin.y += textInset.height

            let isCurrent = NSLocationInRange(selectedRange.location, currentLineRange) && lineRange.location == currentLineRange.location
            let attrs = lineNumberAttributes(isCurrent: isCurrent)

            let numberString = "\(lineNumber)" as NSString
            let size = numberString.size(withAttributes: attrs)
            let x = ruleThickness - size.width - gutterPadding
            let y = lineRect.origin.y + (lineRect.height - size.height) / 2

            numberString.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }
    }

    private func lineNumberFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    }

    private func lineNumberAttributes(isCurrent: Bool) -> [NSAttributedString.Key: Any] {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let normalColor = isDark ? NSColor(white: 0.45, alpha: 1.0) : NSColor(white: 0.55, alpha: 1.0)
        let currentColor = NSColor.controlAccentColor

        return [
            .font: isCurrent ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold) : lineNumberFont(),
            .foregroundColor: isCurrent ? currentColor : normalColor,
        ]
    }
}
