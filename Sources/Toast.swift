import AppKit

/// The "Snip copied to clipboard" notification in the bottom-right corner. Click it to open the editor.
final class ToastController {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var onClick: (() -> Void)?

    func show(_ snip: Snip, screen target: NSScreen? = nil, onClick: @escaping () -> Void) {
        dismiss(animated: false)
        self.onClick = onClick

        let w: CGFloat = 360
        let pad: CGFloat = 14
        let ps = snip.pointSize
        let k = min(1, (w - pad * 2) / max(ps.width, 1), 190 / max(ps.height, 1))
        let tw = max((ps.width * k).rounded(), 24)
        let th = max((ps.height * k).rounded(), 24)
        let headerH: CGFloat = 18
        let textH: CGFloat = 38
        let h = pad + headerH + 10 + th + 12 + textH + pad

        let content = ToastView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        content.autoresizingMask = [.width, .height]
        content.onClick = { [weak self] in self?.clicked() }
        content.onHover = { [weak self] inside in self?.hover(inside) }
        content.menuProvider = { [weak self, weak content] p in
            guard let self, let content else { return nil }
            return self.contextMenu(snip, in: content, at: p)
        }

        let icon = NSImageView(frame: NSRect(x: pad, y: pad, width: 18, height: 18))
        icon.image = NSApp.applicationIconImage
        content.addSubview(icon)

        let appName = label("Snip", size: 12, weight: .semibold, color: .secondaryLabelColor)
        appName.frame = NSRect(x: pad + 24, y: pad + 1, width: 200, height: 16)
        content.addSubview(appName)

        let close = NSButton(image: sym("xmark", size: 11, weight: .semibold), target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.frame = NSRect(x: w - pad - 18, y: pad, width: 18, height: 18)
        content.addSubview(close)
        content.closeButton = close

        let thumb = NSImageView(frame: NSRect(x: ((w - tw) / 2).rounded(), y: pad + headerH + 10, width: tw, height: th))
        thumb.image = NSImage(cgImage: snip.image, size: ps)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        content.addSubview(thumb)

        let title = label("Snip copied to clipboard", size: 13, weight: .semibold, color: .labelColor)
        title.frame = NSRect(x: pad, y: pad + headerH + 10 + th + 12, width: w - pad * 2, height: 18)
        content.addSubview(title)

        let sub = label("Click here to mark up and share the image.", size: 12, weight: .regular, color: .secondaryLabelColor)
        sub.frame = NSRect(x: pad, y: title.frame.maxY + 3, width: w - pad * 2, height: 16)
        content.addSubview(sub)

        let fx = NSVisualEffectView(frame: content.bounds)
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        fx.addSubview(content)

        let screen = target ?? NSScreen.under(NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        let frame = NSRect(x: vis.maxX - w - 16, y: vis.minY + 16, width: w, height: h)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = fx
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }
        panel = p
        scheduleHide(after: 6)
    }

    func dismiss(animated: Bool = true) {
        hideWork?.cancel()
        hideWork = nil
        guard let p = panel else { return }
        panel = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        } else {
            p.orderOut(nil)
        }
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hover(_ inside: Bool) {
        if inside { hideWork?.cancel() } else { scheduleHide(after: 3) }
    }

    private func clicked() {
        let action = onClick
        dismiss()
        action?()
    }

    @objc private func closeTapped() { dismiss() }

    // MARK: Right-click: Copy / Save As / Share

    private var menuSnip: Snip?
    private weak var menuView: NSView?
    private var menuPoint = NSPoint.zero

    private func contextMenu(_ snip: Snip, in view: NSView, at p: NSPoint) -> NSMenu {
        hideWork?.cancel()
        menuSnip = snip
        menuView = view
        menuPoint = p
        let m = NSMenu()
        for (title, sel, icon) in [("Copy", #selector(menuCopy), "doc.on.doc"),
                                   ("Save As…", #selector(menuSave), "square.and.arrow.down"),
                                   ("Share…", #selector(menuShare), "square.and.arrow.up")] {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.image = sym(icon, size: 14)
            m.addItem(it)
        }
        return m
    }

    @objc private func menuCopy() {
        guard let s = menuSnip else { return }
        ImageUtil.copy(s.image, scale: s.scale)
        scheduleHide(after: 3)
    }

    @objc private func menuSave() {
        guard let s = menuSnip else { return }
        dismiss()
        SnipSaver.save(s.image, scale: s.scale, over: nil) { _ in }
    }

    @objc private func menuShare() {
        guard let s = menuSnip, let view = menuView, let url = ImageUtil.writeTemp(s.image, scale: s.scale) else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: NSRect(x: menuPoint.x, y: menuPoint.y, width: 1, height: 1),
                                                  of: view, preferredEdge: .maxY)
        scheduleHide(after: 15)
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }
}

final class ToastView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var menuProvider: ((NSPoint) -> NSMenu?)?
    weak var closeButton: NSButton?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        if let v, let c = closeButton, v.isDescendant(of: c) { return v }
        return v == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return }
        onClick?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(convert(event.locationInWindow, from: nil))
    }
}
