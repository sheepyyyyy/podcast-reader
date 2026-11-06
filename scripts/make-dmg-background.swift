// Draws the picture behind the installer window, at normal and Retina sizes.
// Usage: swift scripts/make-dmg-background.swift <output-folder>
//
// Finder draws the icon labels in black or white depending on the Mac's appearance, and it
// can't be told which. This blue, one of the app's own colors, keeps both readable.
import AppKit

let size = NSSize(width: 600, height: 380)
let background = NSColor(srgbRed: 0x4F / 255, green: 0x74 / 255, blue: 0xB5 / 255, alpha: 1)

func draw(scale: Int, to url: URL) throws {
    let image = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    image.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)

    background.setFill()
    NSRect(origin: .zero, size: size).fill()

    // The arrow points from the app to Applications. Its height matches their icons.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 246, y: 210))
    arrow.line(to: NSPoint(x: 346, y: 210))
    arrow.move(to: NSPoint(x: 322, y: 236))
    arrow.line(to: NSPoint(x: 350, y: 210))
    arrow.line(to: NSPoint(x: 322, y: 184))
    arrow.lineWidth = 10
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor.white.setStroke()
    arrow.stroke()

    let words = NSAttributedString(
        string: "Drag Podcast Reader into Applications",
        attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
    )
    words.draw(at: NSPoint(x: (size.width - words.size().width) / 2, y: 42))

    NSGraphicsContext.restoreGraphicsState()
    try image.representation(using: .png, properties: [:])!.write(to: url)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try draw(scale: 1, to: folder.appending(path: "background.png"))
try draw(scale: 2, to: folder.appending(path: "background@2x.png"))
