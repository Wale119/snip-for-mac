import AppKit

// Renders a 1024px app icon PNG: gradient squircle, dashed selection, white scissors.
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let full = NSRect(x: 0, y: 0, width: px, height: px)
let tile = full.insetBy(dx: 100, dy: 100)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.50, blue: 1.0, alpha: 1),
                    NSColor(srgbRed: 0.42, green: 0.27, blue: 0.96, alpha: 1)])!.draw(in: shape, angle: -90)
let sel = NSBezierPath(roundedRect: tile.insetBy(dx: 120, dy: 120), xRadius: 28, yRadius: 28)
sel.lineWidth = 20
sel.setLineDash([56, 36], count: 2, phase: 0)
NSColor.white.withAlphaComponent(0.55).setStroke()
sel.stroke()
let cfg = NSImage.SymbolConfiguration(pointSize: 330, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let s = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let sz = s.size
    s.draw(in: NSRect(x: (CGFloat(px) - sz.width) / 2, y: (CGFloat(px) - sz.height) / 2, width: sz.width, height: sz.height))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
