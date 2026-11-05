import AppKit
import QuartzCore

/// One snipping session: frozen screens, dimmed overlay on every display, mode toolbar at the top.
final class SnipSession {
    let frozen: [FrozenScreen]
    let windowRects: [CGRect]
    private(set) var mode: SnipMode
    private(set) var hoverWindow: CGRect?
    private var windows: [OverlayWindow] = []
    private let completion: (Snip?) -> Void
    private var done = false

    init(frozen: [FrozenScreen], windowRects: [CGRect], mode: SnipMode, completion: @escaping (Snip?) -> Void) {
        self.frozen = frozen
        self.windowRects = windowRects
        self.mode = mode
        self.completion = completion
    }

    func begin() {
        let mouse = NSEvent.mouseLocation
        windows = frozen.map { OverlayWindow(frozen: $0, session: self) }
        let home = windows.first { NSMouseInRect(mouse, $0.frozen.frame, false) } ?? windows.first
        home?.overlay.installToolbar()
        for w in windows { w.orderFrontRegardless() }
        NSApp.activate(ignoringOtherApps: true)
        if let home {
            home.makeKeyAndOrderFront(nil)
            home.makeFirstResponder(home.overlay)
        }
        updateHover(mouse, force: true)
    }

    func setMode(_ m: SnipMode) {
        mode = m
        Settings.mode = m
        if m == .fullscreen { captureFullscreen(); return }
        windows.forEach { $0.overlay.modeChanged() }
        updateHover(NSEvent.mouseLocation, force: true)
    }

    func updateHover(_ p: NSPoint, force: Bool = false) {
        let newHover = mode == .window ? windowRects.first(where: { $0.contains(p) }) : nil
        guard force || newHover != hoverWindow else { return }
        hoverWindow = newHover
        windows.forEach { $0.overlay.refresh() }
    }

    func cancel() { finish(nil) }

    func captureRect(_ r: CGRect, on f: FrozenScreen) { finish(Cropper.rect(r, in: f)) }

    func captureFreeform(_ p: CGPath, on f: FrozenScreen) { finish(Cropper.freeform(p, in: f)) }

    func captureHoveredWindow(on f: FrozenScreen) {
        guard let g = hoverWindow else { return }
        let local = g.intersection(f.frame).offsetBy(dx: -f.frame.minX, dy: -f.frame.minY)
        guard !local.isNull, local.width > 1, local.height > 1 else { return }
        finish(Cropper.rect(local, in: f))
    }

    func captureFullscreen() { finish(Cropper.stitch(frozen)) }

    private func finish(_ snip: Snip?) {
        guard !done else { return }
        done = true
        for w in windows { w.orderOut(nil) }
        let keepAlive = windows
        DispatchQueue.main.async { [self] in
            _ = keepAlive
            windows.removeAll()
            completion(snip)
        }
    }
}

final class OverlayWindow: NSWindow {
    let frozen: FrozenScreen
    let overlay: OverlayView

    init(frozen: FrozenScreen, session: SnipSession) {
        self.frozen = frozen
        self.overlay = OverlayView(frozen: frozen, session: session)
        super.init(contentRect: frozen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = overlay
        setFrame(frozen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    private unowned let session: SnipSession
    private let frozen: FrozenScreen
    private let host = NSView()
    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private var toolbar: ModeToolbar?

    private var dragStart: CGPoint?
    private var dragRect: CGRect?
    private var freePath: CGMutablePath?
    private var freeCount = 0

    init(frozen: FrozenScreen, session: SnipSession) {
        self.frozen = frozen
        self.session = session
        super.init(frame: NSRect(origin: .zero, size: frozen.frame.size))

        // Layer-hosting child view holds the frozen image + dim + outline, below the toolbar.
        let root = CALayer()
        host.frame = bounds
        host.layer = root
        host.wantsLayer = true
        let scale = frozen.screen.backingScaleFactor
        imageLayer.contents = frozen.image
        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds
        dimLayer.frame = bounds
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor(white: 0, alpha: 0.42).cgColor
        dimLayer.contentsScale = scale
        borderLayer.frame = bounds
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.lineWidth = 1.5
        borderLayer.lineJoin = .round
        borderLayer.contentsScale = scale
        root.addSublayer(imageLayer)
        root.addSublayer(dimLayer)
        root.addSublayer(borderLayer)
        addSubview(host)

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        if let v, let tb = toolbar, v.isDescendant(of: tb) { return v }
        return v == nil ? nil : self
    }

    func installToolbar() {
        let tb = ModeToolbar(mode: session.mode,
                             onMode: { [unowned self] m in self.session.setMode(m) },
                             onClose: { [unowned self] in self.session.cancel() })
        let size = tb.fittingSize
        let menuBar = max(frozen.screen.frame.maxY - frozen.screen.visibleFrame.maxY, 0)
        tb.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                          y: (bounds.height - menuBar - 14 - size.height).rounded(),
                          width: size.width, height: size.height)
        addSubview(tb)
        toolbar = tb
    }

    func modeChanged() {
        dragStart = nil
        dragRect = nil
        freePath = nil
        freeCount = 0
        toolbar?.setMode(session.mode)
        refresh()
    }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var hole: CGPath?
        var outline: CGPath?
        var lineWidth: CGFloat = 1.5
        var stroke = NSColor.white
        switch session.mode {
        case .rectangle:
            if let r = dragRect, r.width > 0, r.height > 0 {
                hole = CGPath(rect: r, transform: nil)
                outline = hole
            }
        case .freeform:
            if let p = freePath, freeCount > 1 {
                let closed = p.mutableCopy()!
                closed.closeSubpath()
                hole = closed
                outline = p
                lineWidth = 2
            }
        case .window:
            if let g = session.hoverWindow {
                let l = g.offsetBy(dx: -frozen.frame.minX, dy: -frozen.frame.minY).intersection(bounds)
                if !l.isNull, !l.isEmpty {
                    hole = CGPath(rect: l, transform: nil)
                    outline = CGPath(rect: l.insetBy(dx: 1.5, dy: 1.5), transform: nil)
                    lineWidth = 3
                    stroke = .controlAccentColor
                }
            }
        case .fullscreen:
            hole = CGPath(rect: bounds, transform: nil)
        }
        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let hole { dim.addPath(hole) }
        dimLayer.path = dim
        borderLayer.path = outline
        borderLayer.lineWidth = lineWidth
        borderLayer.strokeColor = stroke.cgColor
        CATransaction.commit()
    }

    // MARK: Mouse

    private func local(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    override func mouseDown(with e: NSEvent) {
        let p = local(e)
        switch session.mode {
        case .rectangle:
            dragStart = p
            dragRect = CGRect(origin: p, size: .zero)
        case .freeform:
            let path = CGMutablePath()
            path.move(to: p)
            freePath = path
            freeCount = 1
        case .window, .fullscreen:
            break
        }
        refresh()
    }

    override func mouseDragged(with e: NSEvent) {
        let p = local(e)
        switch session.mode {
        case .rectangle:
            guard let s = dragStart else { return }
            dragRect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        case .freeform:
            guard let path = freePath else { return }
            path.addLine(to: p)
            freeCount += 1
        case .window:
            session.updateHover(NSEvent.mouseLocation)
        case .fullscreen:
            break
        }
        refresh()
    }

    override func mouseUp(with e: NSEvent) {
        switch session.mode {
        case .rectangle:
            if let r = dragRect, r.width >= 3, r.height >= 3 {
                session.captureRect(r, on: frozen)
            } else {
                dragStart = nil
                dragRect = nil
                refresh()
            }
        case .freeform:
            if let path = freePath, freeCount > 2 {
                let bb = path.boundingBoxOfPath
                if bb.width >= 3, bb.height >= 3 {
                    session.captureFreeform(path, on: frozen)
                    return
                }
            }
            freePath = nil
            freeCount = 0
            refresh()
        case .window:
            session.captureHoveredWindow(on: frozen)
        case .fullscreen:
            session.captureFullscreen()
        }
    }

    override func mouseMoved(with e: NSEvent) {
        session.updateHover(NSEvent.mouseLocation)
        updateCursor(e)
    }

    override func cursorUpdate(with e: NSEvent) { updateCursor(e) }

    private func updateCursor(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let tb = toolbar, tb.frame.contains(p) { NSCursor.arrow.set() } else { NSCursor.crosshair.set() }
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { session.cancel() } else { super.keyDown(with: e) }
    }
}

/// The floating Rectangle / Window / Full screen / Freeform bar at the top of the screen.
final class ModeToolbar: NSView {
    private var buttons: [SnipMode: NSButton] = [:]
    private let onMode: (SnipMode) -> Void
    private let onClose: () -> Void

    init(mode: SnipMode, onMode: @escaping (SnipMode) -> Void, onClose: @escaping () -> Void) {
        self.onMode = onMode
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .withinWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        fx.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fx)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)

        for m in SnipMode.allCases {
            let b = makeButton(m.symbol, tip: "\(m.title) snip", action: #selector(modeTapped(_:)))
            b.tag = m.rawValue
            buttons[m] = b
            stack.addArrangedSubview(b)
        }
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
        sep.heightAnchor.constraint(equalToConstant: 22).isActive = true
        stack.addArrangedSubview(sep)
        stack.addArrangedSubview(makeButton("xmark", tip: "Close (Esc)", action: #selector(closeTapped)))

        NSLayoutConstraint.activate([
            fx.leadingAnchor.constraint(equalTo: leadingAnchor),
            fx.trailingAnchor.constraint(equalTo: trailingAnchor),
            fx.topAnchor.constraint(equalTo: topAnchor),
            fx.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        setMode(mode)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(image: sym(symbol, size: 17), target: self, action: action)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.toolTip = tip
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 42).isActive = true
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return b
    }

    func setMode(_ m: SnipMode) {
        for (k, b) in buttons {
            let on = k == m
            b.layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : nil
            b.contentTintColor = on ? .controlAccentColor : .labelColor
        }
    }

    @objc private func modeTapped(_ b: NSButton) {
        guard let m = SnipMode(rawValue: b.tag) else { return }
        setMode(m)
        onMode(m)
    }

    @objc private func closeTapped() { onClose() }

    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}
