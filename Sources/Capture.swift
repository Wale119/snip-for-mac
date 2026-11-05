import AppKit
import ScreenCaptureKit

struct Snip {
    let image: CGImage
    let scale: CGFloat
    var pointSize: NSSize {
        NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}

struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage
    var frame: CGRect { screen.frame }
    var scale: CGFloat { CGFloat(image.width) / max(screen.frame.width, 1) }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func under(_ p: NSPoint) -> NSScreen? {
        screens.first { NSMouseInRect(p, $0.frame, false) }
    }
}

enum Capturer {
    /// Freezes every display (like Windows does when you start a snip). Our own windows are excluded.
    static func captureScreens() async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let mine = content.applications.filter { $0.processID == pid }
        var result: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int((screen.frame.width * scale).rounded())
            config.height = Int((screen.frame.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(FrozenScreen(screen: screen, image: image))
        }
        return result
    }

    /// On-screen app windows, front to back, in Cocoa global coordinates.
    static func windowRects() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let pid = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < 20,
                  let owner = info[kCGWindowOwnerPID as String] as? Int32, owner != pid,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  r.width > 40, r.height > 40 else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { return nil }
            return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
    }
}

enum Cropper {
    static func makeContext(_ w: Int, _ h: Int, like img: CGImage?) -> CGContext? {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        if let cs = img?.colorSpace, cs.model == .rgb,
           let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                             space: cs, bitmapInfo: info) {
            return c
        }
        return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
    }

    /// Local rect (points, bottom-left origin within the screen) -> pixel rect (top-left origin).
    static func pixelRect(_ r: CGRect, in f: FrozenScreen) -> CGRect {
        let s = f.scale
        let h = f.frame.height
        let px = CGRect(x: r.minX * s, y: (h - r.maxY) * s, width: r.width * s, height: r.height * s).integral
        return px.intersection(CGRect(x: 0, y: 0, width: f.image.width, height: f.image.height))
    }

    static func rect(_ r: CGRect, in f: FrozenScreen) -> Snip? {
        let px = pixelRect(r, in: f)
        guard !px.isNull, px.width >= 1, px.height >= 1, let img = f.image.cropping(to: px) else { return nil }
        return Snip(image: img, scale: f.scale)
    }

    static func freeform(_ path: CGPath, in f: FrozenScreen) -> Snip? {
        let px = pixelRect(path.boundingBoxOfPath, in: f)
        guard !px.isNull, px.width >= 2, px.height >= 2,
              let ctx = makeContext(Int(px.width), Int(px.height), like: f.image) else { return nil }
        let s = f.scale
        let h = CGFloat(f.image.height)
        let dx = -px.minX
        let dy = -(h - px.maxY)
        var t = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s)
        guard let p = path.copy(using: &t) else { return nil }
        ctx.addPath(p)
        ctx.closePath()
        ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(f.image, in: CGRect(x: dx, y: dy, width: CGFloat(f.image.width), height: h))
        guard let img = ctx.makeImage() else { return nil }
        return Snip(image: img, scale: s)
    }

    /// Full screen: every display stitched together, like Windows.
    static func stitch(_ frozen: [FrozenScreen]) -> Snip? {
        guard let first = frozen.first else { return nil }
        if frozen.count == 1 { return Snip(image: first.image, scale: first.scale) }
        let union = frozen.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let scale = frozen.map(\.scale).max() ?? 2
        let w = Int((union.width * scale).rounded())
        let h = Int((union.height * scale).rounded())
        guard let ctx = makeContext(w, h, like: first.image) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        for f in frozen {
            let r = f.frame
            ctx.draw(f.image, in: CGRect(x: (r.minX - union.minX) * scale, y: (r.minY - union.minY) * scale,
                                         width: r.width * scale, height: r.height * scale))
        }
        guard let img = ctx.makeImage() else { return nil }
        return Snip(image: img, scale: scale)
    }
}

enum ImageUtil {
    static func rep(_ img: CGImage, scale: CGFloat) -> NSBitmapImageRep {
        let r = NSBitmapImageRep(cgImage: img)
        r.size = NSSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
        return r
    }

    static func png(_ img: CGImage, scale: CGFloat) -> Data? {
        rep(img, scale: scale).representation(using: .png, properties: [:])
    }

    static func jpeg(_ img: CGImage, scale: CGFloat) -> Data? {
        guard let ctx = Cropper.makeContext(img.width, img.height, like: img) else { return nil }
        let full = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(full)
        ctx.draw(img, in: full)
        guard let flat = ctx.makeImage() else { return nil }
        return rep(flat, scale: scale).representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    static func copy(_ img: CGImage, scale: CGFloat) {
        let pb = NSPasteboard.general
        let r = rep(img, scale: scale)
        pb.declareTypes([.png, .tiff], owner: nil)
        if let png = r.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
        if let tiff = r.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    static func timestampName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return "Screenshot \(f.string(from: Date()))"
    }

    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    @discardableResult
    static func autoSave(_ snip: Snip) -> URL? {
        let folder = Settings.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, base: timestampName(), ext: "png")
        guard let data = png(snip.image, scale: snip.scale) else { return nil }
        do { try data.write(to: url); return url } catch { NSLog("Snip autosave failed: \(error)"); return nil }
    }

    static func writeTemp(_ img: CGImage, scale: CGFloat) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Snip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = uniqueURL(in: dir, base: timestampName(), ext: "png")
        guard let data = png(img, scale: scale), (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}
