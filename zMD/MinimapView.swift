import AppKit
import SwiftUI

class MinimapView: NSView {

    weak var linkedTextView: NSTextView?
    weak var linkedScrollView: NSScrollView?

    private var cachedImage: CGImage?
    private var debounceTimer: Timer?
    private var isDragging = false

    private let minimapWidth: CGFloat = 80

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: minimapWidth, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func invalidateContent() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.regenerateImage()
            self?.needsDisplay = true
        }
    }

    private func regenerateImage() {
        guard let textView = linkedTextView else {
            cachedImage = nil
            return
        }

        let text = textView.string
        let lines = text.components(separatedBy: "\n")
        let lineHeight: CGFloat = 2
        let imageHeight = max(1, CGFloat(lines.count) * lineHeight)
        let imageWidth = minimapWidth

        guard imageHeight > 0 else {
            cachedImage = nil
            return
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(imageWidth),
            height: Int(imageHeight),
            bitsPerComponent: 8,
            bytesPerRow: Int(imageWidth) * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // Flip context
        context.translateBy(x: 0, y: imageHeight)
        context.scaleBy(x: 1, y: -1)

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let y = CGFloat(index) * lineHeight
            let indent = CGFloat(line.count - line.drop(while: { $0 == " " || $0 == "\t" }).count)
            let barX = min(indent * 0.5, imageWidth * 0.3)
            let barWidth = min(CGFloat(trimmed.count) * 0.5, imageWidth - barX - 4)

            let color: CGColor
            if trimmed.hasPrefix("#") {
                color = isDark
                    ? NSColor.systemBlue.withAlphaComponent(0.7).cgColor
                    : NSColor.systemBlue.withAlphaComponent(0.5).cgColor
            } else if trimmed.hasPrefix("```") {
                color = isDark
                    ? NSColor.systemGray.withAlphaComponent(0.5).cgColor
                    : NSColor.systemGray.withAlphaComponent(0.4).cgColor
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                color = isDark
                    ? NSColor.systemPurple.withAlphaComponent(0.4).cgColor
                    : NSColor.systemPurple.withAlphaComponent(0.3).cgColor
            } else {
                color = isDark
                    ? NSColor.white.withAlphaComponent(0.2).cgColor
                    : NSColor.black.withAlphaComponent(0.15).cgColor
            }

            context.setFillColor(color)
            context.fill(CGRect(x: barX + 4, y: y, width: max(2, barWidth), height: max(1, lineHeight - 0.5)))
        }

        cachedImage = context.makeImage()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark ? NSColor(white: 0.14, alpha: 1.0) : NSColor(white: 0.97, alpha: 1.0)
        context.setFillColor(bgColor.cgColor)
        context.fill(bounds)

        // Separator on left edge
        let sepColor = isDark ? NSColor(white: 0.22, alpha: 1.0) : NSColor(white: 0.85, alpha: 1.0)
        context.setStrokeColor(sepColor.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: 0.25, y: 0))
        context.addLine(to: CGPoint(x: 0.25, y: bounds.height))
        context.strokePath()

        // Draw cached content
        if let image = cachedImage {
            let scale = bounds.height / CGFloat(image.height)
            let drawRect = CGRect(x: 0, y: 0, width: bounds.width, height: CGFloat(image.height) * scale)
            context.draw(image, in: drawRect)
        }

        // Draw viewport indicator
        if let scrollView = linkedScrollView, let documentView = scrollView.documentView {
            let contentHeight = documentView.frame.height
            let viewportHeight = scrollView.contentView.bounds.height
            let scrollOffset = scrollView.contentView.bounds.origin.y

            guard contentHeight > 0 else { return }

            let indicatorY = (scrollOffset / contentHeight) * bounds.height
            let indicatorHeight = max(20, (viewportHeight / contentHeight) * bounds.height)

            let indicatorColor = isDark
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.06)
            context.setFillColor(indicatorColor.cgColor)

            let indicatorRect = CGRect(x: 0, y: indicatorY, width: bounds.width, height: indicatorHeight)
            context.fill(indicatorRect)

            // Top/bottom border of indicator
            let borderColor = isDark
                ? NSColor.white.withAlphaComponent(0.15)
                : NSColor.black.withAlphaComponent(0.1)
            context.setStrokeColor(borderColor.cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: 0, y: indicatorY))
            context.addLine(to: CGPoint(x: bounds.width, y: indicatorY))
            context.move(to: CGPoint(x: 0, y: indicatorY + indicatorHeight))
            context.addLine(to: CGPoint(x: bounds.width, y: indicatorY + indicatorHeight))
            context.strokePath()
        }
    }

    // MARK: - Click/Drag to scroll

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        scrollToClickPosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        scrollToClickPosition(event)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    private func scrollToClickPosition(_ event: NSEvent) {
        guard let scrollView = linkedScrollView, let documentView = scrollView.documentView else { return }

        let localPoint = convert(event.locationInWindow, from: nil)
        let fraction = localPoint.y / bounds.height

        let contentHeight = documentView.frame.height
        let viewportHeight = scrollView.contentView.bounds.height
        let maxScroll = contentHeight - viewportHeight

        guard maxScroll > 0 else { return }

        let targetY = fraction * maxScroll
        let clampedY = max(0, min(maxScroll, targetY))

        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

// MARK: - SwiftUI Wrapper

struct MinimapViewRepresentable: NSViewRepresentable {
    let textView: NSTextView?
    let scrollView: NSScrollView?
    let contentVersion: Int

    func makeNSView(context: Context) -> MinimapView {
        let minimap = MinimapView(frame: .zero)
        minimap.linkedTextView = textView
        minimap.linkedScrollView = scrollView
        return minimap
    }

    func updateNSView(_ nsView: MinimapView, context: Context) {
        nsView.linkedTextView = textView
        nsView.linkedScrollView = scrollView
        nsView.invalidateContent()
    }
}
