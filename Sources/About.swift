import AppKit
import QuartzCore

/// Custom "About Snip" window: glowing backdrop, floating icon, gradient author name.
final class AboutWindowController: NSObject, NSWindowDelegate {
    static let shared = AboutWindowController()
    static let author = "Wale119"

    private var window: NSWindow?
    private var iconView: NSImageView?


    func show() {
        if window == nil { build() }
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        animateIn()
    }

    private func build() {
        let w: CGFloat = 380, h: CGFloat = 520
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.title = "About Snip"
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.delegate = self

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .underWindowBackground
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true

        // Soft colored glows behind the icon, matching the app icon's gradient.
        for (color, center, radius) in [
            (NSColor(srgbRed: 0.16, green: 0.50, blue: 1.0, alpha: 0.55), CGPoint(x: w * 0.32, y: h - 150), CGFloat(210)),
            (NSColor(srgbRed: 0.55, green: 0.30, blue: 0.98, alpha: 0.50), CGPoint(x: w * 0.70, y: h - 120), CGFloat(190)),
            (NSColor(srgbRed: 0.95, green: 0.35, blue: 0.75, alpha: 0.22), CGPoint(x: w * 0.55, y: h - 250), CGFloat(170)),
        ] {
            let g = CAGradientLayer()
            g.type = .radial
            g.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 1)
            g.frame = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            bg.layer?.addSublayer(g)
        }

        let content = FlippedView(frame: bg.bounds)
        bg.addSubview(content)
        var y: CGFloat = 54

        // Icon
        let iconSize: CGFloat = 132
        let icon = NSImageView(frame: NSRect(x: (w - iconSize) / 2, y: y, width: iconSize, height: iconSize))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor(srgbRed: 0.25, green: 0.2, blue: 0.7, alpha: 0.55)
            s.shadowBlurRadius = 28
            s.shadowOffset = NSSize(width: 0, height: -10)
            return s
        }()
        content.addSubview(icon)
        iconView = icon
        y += iconSize + 16

        // Name + version
        let name = label("Snip", size: 34, weight: .bold, color: .labelColor)
        name.frame = NSRect(x: 0, y: y, width: w, height: 42)
        content.addSubview(name)
        y += 44

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        let versionPill = pill("Version \(version) (\(build))")
        versionPill.frame.origin = NSPoint(x: ((w - versionPill.frame.width) / 2).rounded(), y: y)
        content.addSubview(versionPill)
        y += versionPill.frame.height + 14

        let tagline = label("A Windows-style snipping tool for macOS.", size: 13, weight: .regular, color: .secondaryLabelColor)
        tagline.frame = NSRect(x: 20, y: y, width: w - 40, height: 18)
        content.addSubview(tagline)
        y += 34

        // Divider
        let divider = NSView(frame: NSRect(x: (w - 48) / 2, y: y, width: 48, height: 2))
        divider.wantsLayer = true
        let dg = CAGradientLayer()
        dg.frame = divider.bounds
        dg.cornerRadius = 1
        dg.startPoint = CGPoint(x: 0, y: 0.5)
        dg.endPoint = CGPoint(x: 1, y: 0.5)
        dg.colors = Self.brandColors.map(\.cgColor)
        divider.layer?.addSublayer(dg)
        content.addSubview(divider)
        y += 22

        // Credit
        let credit = NSTextField(labelWithAttributedString: NSAttributedString(
            string: "DESIGNED & BUILT BY",
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                         .kern: 2.0,
                         .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }(),
                         .foregroundColor: NSColor.tertiaryLabelColor]))
        credit.alignment = .center
        credit.frame = NSRect(x: 0, y: y, width: w, height: 14)
        content.addSubview(credit)
        y += 20

        let author = GradientTextView(text: Self.author, font: .systemFont(ofSize: 24, weight: .bold),
                                      colors: Self.brandColors)
        author.frame = NSRect(x: 0, y: y, width: w, height: 32)
        content.addSubview(author)
        y += 50

        // Mode chips
        let chips = SnipMode.allCases.map { chip($0.title, symbol: $0.symbol) }
        let gap: CGFloat = 5
        let total = chips.reduce(0) { $0 + $1.frame.width } + gap * CGFloat(chips.count - 1)
        var x = ((w - total) / 2).rounded()
        for c in chips {
            c.frame.origin = NSPoint(x: x, y: y)
            content.addSubview(c)
            x += c.frame.width + gap
        }

        // Footer
        let year = Calendar.current.component(.year, from: Date())
        let footer = label("© \(year) \(Self.author). All rights reserved.", size: 11, weight: .regular,
                           color: .tertiaryLabelColor)
        footer.frame = NSRect(x: 0, y: h - 36, width: w, height: 16)
        content.addSubview(footer)

        win.contentView = bg
        window = win
    }

    private static let brandColors: [NSColor] = [
        NSColor(srgbRed: 0.16, green: 0.50, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.48, green: 0.30, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.36, blue: 0.72, alpha: 1),
    ]

    private func animateIn() {
        guard let layer = iconView?.layer else { return }
        let move = CASpringAnimation(keyPath: "transform.translation.y")
        move.fromValue = -14
        move.toValue = 0
        move.damping = 9
        move.stiffness = 120
        move.mass = 1
        move.duration = move.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.35
        layer.add(move, forKey: "float")
        layer.add(fade, forKey: "fade")
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = .center
        return l
    }

    private func pill(_ text: String) -> NSView {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let tw = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let v = NSView(frame: NSRect(x: 0, y: 0, width: tw + 22, height: 22))
        v.wantsLayer = true
        v.layer?.cornerRadius = 11
        v.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        l.frame = NSRect(x: 0, y: 3, width: v.frame.width, height: 16)
        v.addSubview(l)
        return v
    }

    private func chip(_ text: String, symbol: String) -> NSView {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let tw = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let v = NSView(frame: NSRect(x: 0, y: 0, width: tw + 28, height: 24))
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        let img = NSImageView(frame: NSRect(x: 7, y: 5, width: 13, height: 14))
        img.image = sym(symbol, size: 10, weight: .medium)
        img.contentTintColor = .controlAccentColor
        v.addSubview(img)
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.textColor = .labelColor
        l.frame = NSRect(x: 22, y: 4, width: tw + 4, height: 16)
        v.addSubview(l)
        return v
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Text filled with a horizontal gradient (CAGradientLayer masked by a CATextLayer).
private final class GradientTextView: NSView {
    private let gradient = CAGradientLayer()
    private let textMask = CATextLayer()

    init(text: String, font: NSFont, colors: [NSColor]) {
        super.init(frame: .zero)
        wantsLayer = true
        gradient.colors = colors.map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        textMask.string = text
        textMask.font = font
        textMask.fontSize = font.pointSize
        textMask.alignmentMode = .center
        textMask.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textMask.foregroundColor = NSColor.black.cgColor
        gradient.mask = textMask
        layer?.addSublayer(gradient)
        let tw = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        textWidth = tw
    }

    private var textWidth: CGFloat = 0

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        // Gradient spans just the text so the full color range shows across the name.
        let gx = ((bounds.width - textWidth) / 2).rounded()
        gradient.frame = CGRect(x: gx, y: 0, width: textWidth, height: bounds.height)
        textMask.frame = gradient.bounds
    }
}
