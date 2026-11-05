import AppKit

/// Flat toolbar button in the style of the Windows 11 Snipping Tool:
/// plain icon, soft hover/selected background, optional title, chevron and color stripe.
final class BarButton: NSControl {
    enum Style { case plain, accent }

    var symbol: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var title: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var showsChevron = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var style: Style = .plain { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    /// Small colored stripe under the icon (pen / highlighter color).
    var indicatorColor: NSColor? { didSet { needsDisplay = true } }

    private var hovering = false
    private var pressing = false
    private var tracking: NSTrackingArea?

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    init(symbol: String?, title: String? = nil, chevron: Bool = false, style: Style = .plain,
         tip: String? = nil, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.symbol = symbol
        self.title = title
        self.showsChevron = chevron
        self.style = style
        self.target = target
        self.action = action
        self.toolTip = tip
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title ?? tip)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var labelFont: NSFont { .systemFont(ofSize: 13, weight: style == .accent ? .semibold : .regular) }
    private let iconBox: CGFloat = 20

    private var contentWidth: CGFloat {
        var w: CGFloat = 0
        if symbol != nil { w += iconBox }
        if let t = title {
            if symbol != nil { w += 5 }
            w += ceil((t as NSString).size(withAttributes: [.font: labelFont]).width)
        }
        if showsChevron { w += 5 + 9 }
        return w
    }

    override var intrinsicContentSize: NSSize {
        let pad: CGFloat = (title == nil && !showsChevron) ? 8 : 11
        return NSSize(width: max(contentWidth + pad * 2, 34), height: 32)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func tinted(_ name: String, _ color: NSColor, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        var fg: NSColor = isEnabled ? .labelColor : .tertiaryLabelColor

        switch style {
        case .accent:
            var c = NSColor.controlAccentColor
            if !isEnabled {
                c = c.withAlphaComponent(0.45)
            } else if pressing {
                c = c.blended(withFraction: 0.18, of: .black) ?? c
            } else if hovering {
                c = c.blended(withFraction: 0.12, of: .white) ?? c
            }
            c.setFill()
            bg.fill()
            fg = .white
        case .plain:
            var a: CGFloat = isSelected ? 0.11 : 0
            if isEnabled && hovering { a += 0.06 }
            if isEnabled && pressing { a += 0.06 }
            if a > 0 {
                NSColor.labelColor.withAlphaComponent(a).setFill()
                bg.fill()
            }
        }

        let lift: CGFloat = indicatorColor == nil ? 0 : 2
        let midY = bounds.midY + lift
        var x = ((bounds.width - contentWidth) / 2).rounded()

        if let s = symbol, let img = tinted(s, fg, size: 15, weight: .regular) {
            let sz = img.size
            img.draw(in: NSRect(x: x + (iconBox - sz.width) / 2, y: midY - sz.height / 2, width: sz.width, height: sz.height))
            x += iconBox
            if title != nil { x += 5 }
        }
        if let t = title {
            let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: fg]
            let sz = (t as NSString).size(withAttributes: attrs)
            (t as NSString).draw(at: NSPoint(x: x, y: (midY - sz.height / 2).rounded()), withAttributes: attrs)
            x += ceil(sz.width)
        }
        if showsChevron, let c = tinted("chevron.down", fg.withAlphaComponent(0.65), size: 8.5, weight: .bold) {
            x += 5
            let sz = c.size
            c.draw(in: NSRect(x: x, y: midY - sz.height / 2, width: sz.width, height: sz.height))
        }
        if let ic = indicatorColor {
            let r = NSRect(x: (bounds.midX - 7).rounded(), y: 4, width: 14, height: 3)
            let p = NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5)
            (isEnabled ? ic : ic.withAlphaComponent(0.4)).setFill()
            p.fill()
            if let rgb = ic.usingColorSpace(.sRGB), rgb.brightnessComponent > 0.9, rgb.saturationComponent < 0.1 {
                NSColor.separatorColor.setStroke()
                p.lineWidth = 0.5
                p.stroke()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressing = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != pressing { pressing = inside; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let fire = pressing && bounds.contains(convert(event.locationInWindow, from: nil))
        pressing = false
        needsDisplay = true
        if fire, let action { NSApp.sendAction(action, to: target, from: self) }
    }

    /// Shows a menu just below the button.
    func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
    }
}

/// The editor's top strip. Empty areas drag the window.
final class EditorBar: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// Window whose traffic lights sit vertically centered in the taller custom bar.
final class EditorWindow: NSWindow {
    static let barHeight: CGFloat = 52

    func positionTrafficLights() {
        guard !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton),
              let mini = standardWindowButton(.miniaturizeButton),
              let zoom = standardWindowButton(.zoomButton),
              let titlebar = close.superview,
              let container = titlebar.superview else { return }
        let h = Self.barHeight
        var cf = container.frame
        if cf.height != h || cf.minY != frame.height - h {
            cf.size.height = h
            cf.origin.y = frame.height - h
            container.frame = cf
        }
        if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
        let y = ((h - close.frame.height) / 2).rounded()
        let step = close.frame.width + 8
        for (i, b) in [close, mini, zoom].enumerated() {
            b.setFrameOrigin(NSPoint(x: 18 + CGFloat(i) * step, y: y))
        }
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        positionTrafficLights()
    }
}
