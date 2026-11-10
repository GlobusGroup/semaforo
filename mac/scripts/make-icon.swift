// Draws the Azioni app icon and writes mac/Resources/AppIcon.icns.
//   swift mac/scripts/make-icon.swift
// Re-run only when the design changes; the .icns is committed.
import AppKit

let macDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
let output = macDir.appendingPathComponent("Resources/AppIcon.icns")

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: 824pt body centred in a 1024 canvas, ~185pt corner radius.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.10, green: 0.13, blue: 0.24, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.24, blue: 0.48, alpha: 1),
    ])!.draw(in: body, angle: 90)
    // soft top highlight
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: 270)
    NSGraphicsContext.restoreGraphicsState()

    // Main glyph: the "running" arrows, in white.
    func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, colors: [NSColor]) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    }
    func drawCentered(_ image: NSImage, at center: NSPoint) {
        let r = NSRect(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2,
                       width: image.size.width, height: image.size.height)
        image.draw(in: r)
    }

    let arrows = symbol("arrow.triangle.2.circlepath", pointSize: 420 * s, weight: .semibold,
                        colors: [NSColor.white.withAlphaComponent(0.95)])
    drawCentered(arrows, at: NSPoint(x: 492 * s, y: 532 * s))

    // Status badge: green tick on a ring matching the background.
    let badgeCenter = NSPoint(x: 712 * s, y: 312 * s)
    let ring = NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - 150 * s, y: badgeCenter.y - 150 * s,
                                           width: 300 * s, height: 300 * s))
    NSColor(srgbRed: 0.12, green: 0.17, blue: 0.32, alpha: 1).setFill()
    ring.fill()
    let tick = symbol("checkmark.circle.fill", pointSize: 230 * s, weight: .bold,
                      colors: [.white, NSColor(srgbRed: 0.20, green: 0.78, blue: 0.40, alpha: 1)])
    drawCentered(tick, at: badgeCenter)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: px).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: macDir.appendingPathComponent("build/AppIcon-preview.png"), options: [])

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print(output.path)
