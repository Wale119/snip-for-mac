// Helper for tools/screenshots.sh.
//   window_info <pid>          prints the process's on-screen windows: "<windowID> <x> <y> <width> <height>" (points)
//   window_info --main-height  prints the main display's height in points
import CoreGraphics
import Foundation

import ImageIO
import UniformTypeIdentifiers

if CommandLine.arguments.dropFirst().first == "--main-height" {
    print(Int(CGDisplayBounds(CGMainDisplayID()).height))
    exit(0)
}
// window_info --main-scale  prints 2 for a Retina main display, 1 otherwise
if CommandLine.arguments.dropFirst().first == "--main-scale" {
    let id = CGMainDisplayID()
    let mode = CGDisplayCopyDisplayMode(id)
    print(max(1, (mode?.pixelWidth ?? 1) / max(1, mode?.width ?? 1)))
    exit(0)
}
// window_info --strip <file.png>...  redraws each PNG into plain sRGB and saves only the pixels. This drops all
// metadata (EXIF, comments) and the display's color profile, which names the monitor model.
if CommandLine.arguments.dropFirst().first == "--strip" {
    for path in CommandLine.arguments.dropFirst(2) {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil),
              let original = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: original.width, height: original.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { print("could not read \(path)"); exit(1) }
        ctx.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
        else { print("could not strip \(path)"); exit(1) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { print("could not write \(path)"); exit(1) }
    }
    exit(0)
}
// window_info --check <file.png>...  fails if a file is missing or almost entirely black (e.g. the display slept)
if CommandLine.arguments.dropFirst().first == "--check" {
    var ok = true
    for path in CommandLine.arguments.dropFirst(2) {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = (ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)), ctx.data).1
        else { print("MISSING: \(path)"); ok = false; continue }
        let px = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        var black = 0, visible = 0
        for i in 0..<(image.width * image.height) where px[i * 4 + 3] > 200 {
            visible += 1
            if px[i * 4] < 10 && px[i * 4 + 1] < 10 && px[i * 4 + 2] < 10 { black += 1 }
        }
        if visible == 0 || Double(black) / Double(visible) > 0.9 { print("BLANK: \(path)"); ok = false }
    }
    exit(ok ? 0 : 1)
}
guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    print("usage: window_info <pid> | --main-height | --strip <png>... | --check <png>...")
    exit(1)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    guard let id = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    print(id, Int(b["X"] ?? 0), Int(b["Y"] ?? 0), Int(b["Width"] ?? 0), Int(b["Height"] ?? 0))
}
