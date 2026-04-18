import AppKit

class LineNumberGutter: NSRulerView {

    private var textView: NSTextView? {
        clientView as? NSTextView
    }

    private let gutterPadding: CGFloat = 12
    private let minWidth: CGFloat = 40

    /// Cached array of logical-line start character offsets. Index i = start of line i+1 (1-based).
    /// Previously the gutter re-scanned the entire text storage twice per draw call (once to count
    /// total lines, once via `substring(to:).components(separatedBy:"\n")` to find the starting
    /// line number), allocating an O(N) string each time. On a 10k-line file this was a hot path
    /// running on every scroll tick.
    private var lineStartCache: [Int] = [0]
    private var cachedTextLength: Int = -1
    private var cachedTextHash: Int = 0

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

        // Refresh line-start cache if text changed (hash+length comparison keeps this cheap).
        rebuildLineCacheIfNeeded(text: text)

        let totalLines = lineStartCache.count

        let digits = max(2, String(totalLines).count)
        let font = lineNumberFont()
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let newThickness = max(minWidth, CGFloat(digits) * digitWidth + gutterPadding * 2)
        if abs(ruleThickness - newThickness) > 1 {
            ruleThickness = newThickness
        }

        let selectedRange = textView.selectedRange()
        let currentLineRange = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))

        // Walk visible line fragments; draw the logical-line number only on the fragment that
        // starts a new logical line. Soft-wrap continuations are left unnumbered, matching
        // conventional editor behavior (VS Code, TextMate, BBEdit).
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)

        layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphRange) { [weak self] rect, _, _, glyphRange, _ in
            guard let self = self else { return }
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            // Lookup the logical line number for this char position in O(log N).
            guard let lineNumber = self.logicalLineNumber(atCharIndex: charRange.location, in: text) else { return }

            // Only draw on the fragment that starts the logical line.
            let logicalLineStart = self.lineStartCache[lineNumber - 1]
            guard charRange.location == logicalLineStart else { return }

            var lineRect = rect
            lineRect.origin.y += textInset.height
            // Also offset by the scrollView's visible origin so ruler math matches textView.
            lineRect.origin.y -= visibleRect.origin.y

            let isCurrent = NSLocationInRange(selectedRange.location, currentLineRange) && currentLineRange.location == logicalLineStart
            let attrs = self.lineNumberAttributes(isCurrent: isCurrent, font: font)

            let numberString = "\(lineNumber)" as NSString
            let size = numberString.size(withAttributes: attrs)
            let x = self.ruleThickness - size.width - self.gutterPadding
            let y = lineRect.origin.y + (lineRect.height - size.height) / 2

            numberString.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
    }

    /// Rebuild the line-start cache if the backing text changed.
    /// Comparison strategy: length + hashValue. Cheap enough to run per draw and will only do the
    /// O(N) scan when something actually changed. For incremental updates on large files a future
    /// optimization would hook NSTextStorageDelegate.processEditing and mutate the cache in place.
    private func rebuildLineCacheIfNeeded(text: NSString) {
        let currentLength = text.length
        let currentHash = (text as String).hashValue

        if currentLength == cachedTextLength && currentHash == cachedTextHash { return }

        var offsets: [Int] = [0]
        text.enumerateSubstrings(in: NSRange(location: 0, length: currentLength), options: [.byLines, .substringNotRequired]) { _, substringRange, enclosingRange, _ in
            let nextLineStart = NSMaxRange(enclosingRange)
            // Only record a new line if there's another line after it (avoids a phantom trailing line).
            if nextLineStart < text.length || substringRange.length < enclosingRange.length {
                offsets.append(nextLineStart)
            }
        }

        lineStartCache = offsets
        cachedTextLength = currentLength
        cachedTextHash = currentHash
    }

    /// Return 1-based logical line number for a character index via binary search of lineStartCache.
    private func logicalLineNumber(atCharIndex charIndex: Int, in text: NSString) -> Int? {
        guard !lineStartCache.isEmpty else { return nil }
        var lo = 0
        var hi = lineStartCache.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStartCache[mid] <= charIndex {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo + 1
    }

    /// Gutter font scales with the editor's text font so numbers stay aligned at any zoom.
    private func lineNumberFont() -> NSFont {
        let basePointSize = textView?.font?.pointSize ?? 14
        let size = max(9, basePointSize - 3)
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    private func lineNumberAttributes(isCurrent: Bool, font: NSFont) -> [NSAttributedString.Key: Any] {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let normalColor = isDark ? NSColor(white: 0.45, alpha: 1.0) : NSColor(white: 0.55, alpha: 1.0)
        let currentColor = NSColor.controlAccentColor
        let weightedFont = isCurrent
            ? NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .semibold)
            : font
        return [
            .font: weightedFont,
            .foregroundColor: isCurrent ? currentColor : normalColor,
        ]
    }
}
