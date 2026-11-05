import AppKit

struct Stroke {
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var highlighter: Bool

    func path() -> CGPath {
        let p = CGMutablePath()
        guard let first = points.first else { return p }
        p.move(to: first)
        switch points.count {
        case 1:
            p.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
        case 2:
            p.addLine(to: points[1])
        default:
            for i in 1..<(points.count - 1) {
                let a = points[i], b = points[i + 1]
                p.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
            }
            p.addLine(to: points[points.count - 1])
        }
        return p
    }

    func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path())
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(color.cgColor)
        if highlighter { ctx.setBlendMode(.multiply) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        let t = width / 2 + tolerance
        if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= t }
        for i in 1..<points.count where Stroke.distance(p, points[i - 1], points[i]) <= t { return true }
        return false
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

struct EditState {
    var image: CGImage
    var scale: CGFloat
    var strokes: [Stroke]
    var pointSize: NSSize {
        NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}

enum Tool { case none, pen, highlighter, eraser, crop }

private struct Edges: OptionSet {
    let rawValue: Int
    static let left = Edges(rawValue: 1)
    static let right = Edges(rawValue: 2)
    static let top = Edges(rawValue: 4)
    static let bottom = Edges(rawValue: 8)
}

/// The image + ink surface inside the editor's scroll view.
final class CanvasView: NSView {
    var state: EditState? {
        didSet {
            let s = state?.pointSize ?? NSSize(width: 1, height: 1)
            if frame.size != s { setFrameSize(s) }
            needsDisplay = true
        }
    }

    var tool: Tool = .pen {
        didSet {
            cropRect = tool == .crop ? bounds : nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    var penColor: NSColor = .black
    var penWidth: CGFloat = 4
    var highlighterColor: NSColor = .systemYellow
    var highlighterWidth: CGFloat = 18

    /// Called right before a change (push undo), and right after (dirty / auto-copy).
    var willChange: (() -> Void)?
    var didChange: (() -> Void)?
    var onCropKey: ((Bool) -> Void)?
    /// Right-click menu (Copy / Save As / Share), given the click point in canvas coordinates.
    var menuProvider: ((NSPoint) -> NSMenu?)?

    private var current: Stroke?
    private var erasing = false
    private(set) var cropRect: CGRect?
    private var cropEdges: Edges = []
    private var cropMoving = false
    private var cropStart: CGPoint?
    private var cropStartRect: CGRect?

    var hasImage: Bool { state != nil }
    private var mag: CGFloat { enclosingScrollView?.magnification ?? 1 }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let st = state, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = mag < 1 ? .high : .none
        ctx.draw(st.image, in: bounds)
        ctx.saveGState()
        ctx.clip(to: bounds)
        for s in st.strokes { s.draw(in: ctx) }
        current?.draw(in: ctx)
        ctx.restoreGState()
        if tool == .crop, let r = cropRect { drawCrop(ctx, r) }
    }

    private func drawCrop(_ ctx: CGContext, _ r: CGRect) {
        ctx.saveGState()
        let dim = CGMutablePath()
        dim.addRect(bounds)
        dim.addRect(r)
        ctx.addPath(dim)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fillPath(using: .evenOdd)

        let m = mag
        // Rule-of-thirds guides
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(0.75 / m)
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3
            let y = r.minY + r.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY))
            ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5 / m)
        ctx.stroke(r)

        // Corner brackets and edge grips
        let t = 4 / m
        let len = min(20 / m, r.width / 3, r.height / 3)
        ctx.setLineWidth(t)
        ctx.setLineCap(.butt)
        let i = t / 2
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: r.minX + i, y: r.minY + i), 1, 1),
            (CGPoint(x: r.maxX - i, y: r.minY + i), -1, 1),
            (CGPoint(x: r.minX + i, y: r.maxY - i), 1, -1),
            (CGPoint(x: r.maxX - i, y: r.maxY - i), -1, -1),
        ]
        for (c, sx, sy) in corners {
            ctx.move(to: CGPoint(x: c.x + sx * len, y: c.y))
            ctx.addLine(to: c)
            ctx.addLine(to: CGPoint(x: c.x, y: c.y + sy * len))
        }
        let g = len / 2
        ctx.move(to: CGPoint(x: r.midX - g, y: r.minY + i)); ctx.addLine(to: CGPoint(x: r.midX + g, y: r.minY + i))
        ctx.move(to: CGPoint(x: r.midX - g, y: r.maxY - i)); ctx.addLine(to: CGPoint(x: r.midX + g, y: r.maxY - i))
        ctx.move(to: CGPoint(x: r.minX + i, y: r.midY - g)); ctx.addLine(to: CGPoint(x: r.minX + i, y: r.midY + g))
        ctx.move(to: CGPoint(x: r.maxX - i, y: r.midY - g)); ctx.addLine(to: CGPoint(x: r.maxX - i, y: r.midY + g))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Image with ink burned in, at full pixel resolution.
    static func render(_ st: EditState) -> CGImage {
        if st.strokes.isEmpty { return st.image }
        guard let ctx = Cropper.makeContext(st.image.width, st.image.height, like: st.image) else { return st.image }
        ctx.interpolationQuality = .none
        ctx.scaleBy(x: st.scale, y: st.scale)
        let r = CGRect(origin: .zero, size: st.pointSize)
        ctx.draw(st.image, in: r)
        ctx.clip(to: r)
        for s in st.strokes { s.draw(in: ctx) }
        return ctx.makeImage() ?? st.image
    }

    // MARK: Cursors

    override func resetCursorRects() {
        switch tool {
        case .pen, .highlighter: addCursorRect(bounds, cursor: .crosshair)
        case .eraser: addCursorRect(bounds, cursor: CanvasView.eraserCursor)
        case .crop, .none: break
        }
    }

    private static let eraserCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let c = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2))
            NSColor.white.withAlphaComponent(0.6).setFill()
            c.fill()
            c.lineWidth = 1.5
            NSColor.black.setStroke()
            c.stroke()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 9, y: 9))
    }()

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        guard state != nil else { return }
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        switch tool {
        case .pen:
            current = Stroke(points: [p], color: penColor, width: penWidth, highlighter: false)
            needsDisplay = true
        case .highlighter:
            current = Stroke(points: [p], color: highlighterColor, width: highlighterWidth, highlighter: true)
            needsDisplay = true
        case .eraser:
            erasing = false
            erase(at: p)
        case .crop:
            beginCrop(at: p)
        case .none:
            break
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard state != nil else { return }
        let p = convert(e.locationInWindow, from: nil)
        switch tool {
        case .pen, .highlighter:
            guard var c = current, let last = c.points.last else { return }
            if hypot(p.x - last.x, p.y - last.y) > 0.75 / mag {
                c.points.append(p)
                current = c
                needsDisplay = true
            }
        case .eraser:
            erase(at: p)
        case .crop:
            dragCrop(to: p)
        case .none:
            break
        }
    }

    override func mouseUp(with e: NSEvent) {
        switch tool {
        case .pen, .highlighter:
            guard let c = current else { return }
            current = nil
            willChange?()
            state?.strokes.append(c)
            didChange?()
        case .eraser:
            if erasing {
                erasing = false
                didChange?()
            }
        case .crop:
            cropStart = nil
            cropStartRect = nil
        case .none:
            break
        }
    }

    private func erase(at p: CGPoint) {
        guard var st = state else { return }
        let hits = st.strokes.indices.filter { st.strokes[$0].hitTest(p, tolerance: 6 / mag) }
        guard !hits.isEmpty else { return }
        if !erasing {
            willChange?()
            erasing = true
        }
        for i in hits.reversed() { st.strokes.remove(at: i) }
        state = st
    }

    func eraseAll() {
        guard let st = state, !st.strokes.isEmpty else { return }
        willChange?()
        state?.strokes.removeAll()
        didChange?()
    }

    // MARK: Crop

    private func beginCrop(at p: CGPoint) {
        guard let r = cropRect else { return }
        let t = 12 / mag
        let inY = p.y >= r.minY - t && p.y <= r.maxY + t
        let inX = p.x >= r.minX - t && p.x <= r.maxX + t
        var edges: Edges = []
        if inY && abs(p.x - r.minX) <= t { edges.insert(.left) }
        if inY && abs(p.x - r.maxX) <= t { edges.insert(.right) }
        if inX && abs(p.y - r.minY) <= t { edges.insert(.bottom) }
        if inX && abs(p.y - r.maxY) <= t { edges.insert(.top) }
        cropEdges = edges
        cropMoving = edges.isEmpty && r.contains(p)
        cropStart = p
        cropStartRect = r
    }

    private func dragCrop(to p: CGPoint) {
        guard let start = cropStart, let r0 = cropStartRect else { return }
        let dx = p.x - start.x, dy = p.y - start.y
        let b = bounds
        let minSize = max(4, 8 / mag)
        if cropMoving {
            let x = min(max(r0.minX + dx, 0), b.width - r0.width)
            let y = min(max(r0.minY + dy, 0), b.height - r0.height)
            cropRect = CGRect(x: x, y: y, width: r0.width, height: r0.height)
        } else if !cropEdges.isEmpty {
            var minX = r0.minX, maxX = r0.maxX, minY = r0.minY, maxY = r0.maxY
            if cropEdges.contains(.left) { minX = min(max(r0.minX + dx, 0), maxX - minSize) }
            if cropEdges.contains(.right) { maxX = max(min(r0.maxX + dx, b.width), minX + minSize) }
            if cropEdges.contains(.bottom) { minY = min(max(r0.minY + dy, 0), maxY - minSize) }
            if cropEdges.contains(.top) { maxY = max(min(r0.maxY + dy, b.height), minY + minSize) }
            cropRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        needsDisplay = true
    }

    /// Returns true if the crop changed the image.
    @discardableResult
    func applyCrop() -> Bool {
        guard var st = state, let r = cropRect?.intersection(bounds), !r.isNull else { return false }
        let ps = st.pointSize
        let px = CGRect(x: r.minX * st.scale, y: (ps.height - r.maxY) * st.scale,
                        width: r.width * st.scale, height: r.height * st.scale).integral
            .intersection(CGRect(x: 0, y: 0, width: st.image.width, height: st.image.height))
        guard px.width >= 1, px.height >= 1,
              px.size != CGSize(width: st.image.width, height: st.image.height),
              let img = st.image.cropping(to: px) else { return false }
        let ox = px.minX / st.scale
        let oy = (CGFloat(st.image.height) - px.maxY) / st.scale
        willChange?()
        st.image = img
        st.strokes = st.strokes.map { s in
            var s = s
            s.points = s.points.map { CGPoint(x: $0.x - ox, y: $0.y - oy) }
            return s
        }
        state = st
        didChange?()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with e: NSEvent) {
        if tool == .crop {
            switch e.keyCode {
            case 36, 76: onCropKey?(true); return
            case 53: onCropKey?(false); return
            default: break
            }
        }
        super.keyDown(with: e)
    }
}

/// Keeps the image centered when it's smaller than the window.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let df = doc.frame
        if r.width > df.width { r.origin.x = df.minX - (r.width - df.width) / 2 }
        if r.height > df.height { r.origin.y = df.minY - (r.height - df.height) / 2 }
        return r
    }
}
