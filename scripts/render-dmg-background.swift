import AppKit

// DMG background for the zMD installer window. Finder layout coordinates are in
// points; a 2× PNG keeps the artwork crisp. Same renderer pattern as zStats and
// zWhisper, branded to the zMD icon: charcoal base, red accent, white document.
//
// Everything positional here must agree with the create-dmg arguments in
// scripts/build-dmg.sh (window 720×468 incl. title bar, icon size 112, app at
// x=200 and Applications at x=520, both at y=218).
let size = NSSize(width: 720, height: 440)
let scale = 2
guard CommandLine.arguments.count == 2,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                    pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Usage: swift scripts/render-dmg-background.swift output.png")
}
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
let bounds = NSRect(origin: .zero, size: size)
// Near-black base (the icon's bezel) warming very slightly toward its red at the top.
NSGradient(colors: [color(0x0B0C0F), color(0x1E1416)])!.draw(in: bounds, angle: 90)

func centeredText(_ text: String, top: CGFloat, font: NSFont, tint: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint, .paragraphStyle: style]
    (text as NSString).draw(in: NSRect(x: 30, y: size.height - top - 40, width: size.width - 60, height: 40), withAttributes: attributes)
}

// Accent bar in the icon's red, then the title.
color(0xE5322B, alpha: 0.9).setFill()
NSBezierPath(roundedRect: NSRect(x: 344, y: 393, width: 32, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
centeredText("zMD", top: 68, font: .systemFont(ofSize: 30, weight: .semibold), tint: color(0xF5F5F7))

// The arrow is artwork; both app and Applications icons remain real draggable items.
let arrowY: CGFloat = size.height - 218
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 334, y: arrowY))
arrow.line(to: NSPoint(x: 386, y: arrowY))
arrow.move(to: NSPoint(x: 376, y: arrowY + 10))
arrow.line(to: NSPoint(x: 386, y: arrowY))
arrow.line(to: NSPoint(x: 376, y: arrowY - 10))
arrow.lineWidth = 2
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
color(0xB0666A).setStroke()
arrow.stroke()

// Finder always uses dark filename text over a custom picture. Keep the real
// filenames readable without renaming the app or drawing fake icon labels.
color(0xECECEF).setFill()
for (centerX, width): (CGFloat, CGFloat) in [(200, 76), (520, 140)] {
    NSBezierPath(roundedRect: NSRect(x: centerX - width / 2, y: size.height - 309,
                                    width: width, height: 30),
                 xRadius: 10, yRadius: 10).fill()
}

centeredText("Drag zMD to Applications.", top: 343,
             font: .systemFont(ofSize: 15, weight: .medium), tint: color(0xC2B4B6))
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode background") }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
