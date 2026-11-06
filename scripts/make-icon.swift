// Draws the app icon and writes it as an .icns file.
// Usage: swift scripts/make-icon.swift <output.icns>
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024

    // Standard macOS icon shape: a rounded square inset from the canvas.
    let frame = NSRect(x: 100, y: 100, width: 824, height: 824).applying(.init(scaleX: scale, y: scale))
    let shape = NSBezierPath(roundedRect: frame, xRadius: 185 * scale, yRadius: 185 * scale)
    shape.addClip()
    color(0x0A1C4A).setFill()
    frame.fill()

    // Soft color fields, as in the reader's background.
    let fields: [(NSPoint, CGFloat, UInt32)] = [
        (NSPoint(x: 250, y: 780), 560, 0x2A4FD8),
        (NSPoint(x: 820, y: 250), 620, 0x6A2BD0),
        (NSPoint(x: 800, y: 800), 380, 0x0E8FA8),
    ]
    for (center, radius, hex) in fields {
        let gradient = NSGradient(colors: [color(hex).withAlphaComponent(0.85), color(hex).withAlphaComponent(0)])!
        let point = NSPoint(x: center.x * scale, y: center.y * scale)
        gradient.draw(
            fromCenter: point,
            radius: 0,
            toCenter: point,
            radius: radius * scale,
            options: []
        )
    }

    // Three caption lines: spoken, current, upcoming.
    let bars: [(CGFloat, CGFloat, UInt32, CGFloat)] = [
        (650, 440, 0x9FC2FF, 0.55),
        (490, 600, 0xFFFFFF, 1),
        (330, 500, 0x9FC2FF, 1),
    ]
    for (y, width, hex, alpha) in bars {
        let rect = NSRect(x: 212 * scale, y: y * scale, width: width * scale, height: 84 * scale)
        color(hex).withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 42 * scale, yRadius: 42 * scale).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("Usage: swift make-icon.swift <output.icns>")
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1])
let iconset = FileManager.default.temporaryDirectory
    .appending(path: "PodcastReader-\(UUID().uuidString).iconset", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 1 ? "" : "@2x"
        let data = drawIcon(size: base * multiplier).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appending(path: "icon_\(base)x\(base)\(suffix).png"))
    }
}

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
