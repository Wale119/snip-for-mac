import AppKit

/// The markup window: New / mode / delay, pen / highlighter / eraser / crop / undo / redo, zoom / save / copy / share.
final class EditorController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    let window: EditorWindow
    private let bar = EditorBar()
    private let scrollView = NSScrollView()
    private let canvas = CanvasView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private(set) var dirty = false
    private var savedURL: URL?
    private var copyWork: DispatchWorkItem?
    private var toolBeforeCrop: Tool = .pen
    private var wasVisibleBeforeSnip = false

    var onNewSnip: (() -> Void)?

    private var newButton: BarButton!
    private var modeButton: BarButton!
    private var delayButton: BarButton!
    private var penButton: BarButton!
    private var highlighterButton: BarButton!
    private var eraserButton: BarButton!
    private var cropButton: BarButton!
    private var undoButton: BarButton!
    private var redoButton: BarButton!
    private var applyCropButton: BarButton!
    private var cancelCropButton: BarButton!
    private var zoomButton: BarButton!
    private var saveButton: BarButton!
    private var copyButton: BarButton!
    private var shareButton: BarButton!
    private var moreButton: BarButton!
    private var separators: [NSView] = []
    private var leadStack: NSStackView!
    private var leadInset: NSLayoutConstraint!

    private let penColors: [(String, NSColor)] = [
        ("Black", .black), ("White", .white), ("Gray", .systemGray), ("Red", .systemRed),
        ("Orange", .systemOrange), ("Yellow", .systemYellow), ("Green", .systemGreen),
        ("Blue", .systemBlue), ("Purple", .systemPurple), ("Pink", .systemPink),
    ]
    private let highlighterColors: [(String, NSColor)] = [
        ("Yellow", NSColor(srgbRed: 1.0, green: 0.93, blue: 0.0, alpha: 1)),
        ("Green", NSColor(srgbRed: 0.45, green: 1.0, blue: 0.35, alpha: 1)),
        ("Aqua", NSColor(srgbRed: 0.3, green: 0.95, blue: 1.0, alpha: 1)),
        ("Pink", NSColor(srgbRed: 1.0, green: 0.5, blue: 0.85, alpha: 1)),
        ("Orange", NSColor(srgbRed: 1.0, green: 0.7, blue: 0.25, alpha: 1)),
    ]
    private let penSizes: [(String, CGFloat)] = [("Extra fine", 1.5), ("Fine", 2.5), ("Medium", 4), ("Thick", 7), ("Extra thick", 12)]
    private let highlighterSizes: [(String, CGFloat)] = [("Small", 10), ("Medium", 18), ("Large", 28)]

    private var penColorIndex = Settings.int("penColor", default: 3) { didSet { Settings.setInt(penColorIndex, "penColor"); applyInkSettings() } }
    private var penSizeIndex = Settings.int("penSize", default: 2) { didSet { Settings.setInt(penSizeIndex, "penSize"); applyInkSettings() } }
    private var hlColorIndex = Settings.int("hlColor", default: 0) { didSet { Settings.setInt(hlColorIndex, "hlColor"); applyInkSettings() } }
    private var hlSizeIndex = Settings.int("hlSize", default: 1) { didSet { Settings.setInt(hlSizeIndex, "hlSize"); applyInkSettings() } }

    var isVisible: Bool { window.isVisible }
    var hasImage: Bool { canvas.hasImage }

    override init() {
        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init()
        window.title = "Snip"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 820, height: 380)
        window.tabbingMode = .disallowed

        buildContent()

        canvas.willChange = { [weak self] in
            guard let self, let s = self.canvas.state else { return }
            self.undoStack.append(s)
            if self.undoStack.count > 200 { self.undoStack.removeFirst() }
            self.redoStack.removeAll()
        }
        canvas.didChange = { [weak self] in self?.contentChanged() }
        canvas.onCropKey = { [weak self] apply in
            if apply { self?.applyCrop() } else { self?.cancelCrop() }
        }
        canvas.menuProvider = { [weak self] p in self?.contextMenu(at: p) }

        applyInkSettings()
        setTool(.pen)
        updateUI()
        window.center()
        window.positionTrafficLights()
    }

    // MARK: Building UI

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> BarButton {
        BarButton(symbol: symbol, tip: tip, target: self, action: action)
    }

    private func separator() -> NSView {
        let s = NSBox()
        s.boxType = .separator
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(equalToConstant: 1).isActive = true
        s.heightAnchor.constraint(equalToConstant: 20).isActive = true
        separators.append(s)
        return s
    }

    private func stack(_ views: [NSView], spacing: CGFloat = 2) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = spacing
        s.alignment = .centerY
        s.detachesHiddenViews = true
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func buildContent() {
        newButton = BarButton(symbol: "plus", title: "New", style: .accent, tip: "New snip (⌘N)",
                              target: self, action: #selector(newSnip))
        modeButton = BarButton(symbol: Settings.mode.symbol, chevron: true, tip: "Snipping mode",
                               target: self, action: #selector(showModeMenu(_:)))
        delayButton = BarButton(symbol: "timer", chevron: true, tip: "Snip delay",
                                target: self, action: #selector(showDelayMenu(_:)))

        penButton = button("pencil.tip", "Ballpoint pen — click again for color & size", #selector(penClicked(_:)))
        highlighterButton = button("highlighter", "Highlighter — click again for color & size", #selector(highlighterClicked(_:)))
        eraserButton = button("eraser", "Eraser — click again to erase all ink", #selector(eraserClicked(_:)))
        cropButton = button("crop", "Image crop", #selector(cropClicked))
        undoButton = button("arrow.uturn.backward", "Undo (⌘Z)", #selector(undo))
        redoButton = button("arrow.uturn.forward", "Redo (⇧⌘Z)", #selector(redo))
        applyCropButton = BarButton(symbol: "checkmark", title: "Apply", style: .accent, tip: "Apply crop (Return)",
                                    target: self, action: #selector(applyCrop))
        cancelCropButton = BarButton(symbol: "xmark", title: "Cancel", tip: "Cancel crop (Esc)",
                                     target: self, action: #selector(cancelCrop))

        zoomButton = BarButton(symbol: "plus.magnifyingglass", chevron: true, tip: "Zoom",
                               target: self, action: #selector(showZoomMenu(_:)))
        saveButton = button("square.and.arrow.down", "Save as (⌘S)", #selector(save))
        copyButton = button("doc.on.doc", "Copy (⌘C)", #selector(copyImage))
        shareButton = button("square.and.arrow.up", "Share", #selector(share(_:)))
        moreButton = button("ellipsis", "See more", #selector(showMoreMenu(_:)))

        leadStack = stack([newButton, separator(), modeButton, delayButton], spacing: 4)
        let editStack = stack([penButton, highlighterButton, eraserButton, separator(), cropButton, separator(),
                               undoButton, redoButton, applyCropButton, cancelCropButton])
        editStack.setCustomSpacing(8, after: applyCropButton)
        let outStack = stack([zoomButton, separator(), saveButton, copyButton, shareButton, moreButton])
        // The lead separator should stay visible during crop.
        separators.removeFirst()

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(leadStack)
        bar.addSubview(editStack)
        bar.addSubview(outStack)

        let content = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = CenteringClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 8
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        canvas.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        scrollView.documentView = canvas
        content.addSubview(scrollView)
        content.addSubview(bar)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        leadInset = leadStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 92)
        let center = editStack.centerXAnchor.constraint(equalTo: bar.centerXAnchor)
        center.priority = .defaultHigh
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: EditorWindow.barHeight),

            leadInset,
            leadStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            editStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            center,
            editStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadStack.trailingAnchor, constant: 16),
            outStack.leadingAnchor.constraint(greaterThanOrEqualTo: editStack.trailingAnchor, constant: 16),
            outStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            outStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        window.contentView = content
    }

    func refreshSettingsUI() {
        modeButton.symbol = Settings.mode.symbol
        delayButton.title = Settings.delay == 0 ? nil : "\(Settings.delay)s"
        updateEmptyText()
    }

    private func updateEmptyText() {
        emptyLabel.stringValue = """
        Snip anything on your screen.

        Press \(Settings.hotKey.display) from anywhere, or click New (⌘N).
        Your snip is copied to the clipboard automatically.
        """
    }

    // MARK: Showing

    func show() {
        refreshSettingsUI()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(canvas)
        window.positionTrafficLights()
    }

    func showEmptyOrCurrent() {
        if !window.isVisible && !canvas.hasImage {
            window.setContentSize(NSSize(width: 860, height: 440))
            window.center()
        }
        show()
    }

    func hideForSnip() {
        wasVisibleBeforeSnip = window.isVisible
        window.orderOut(nil)
    }

    func showAgainAfterCancel() {
        if wasVisibleBeforeSnip { show() }
    }

    func load(_ snip: Snip) {
        let apply = { [self] in
            canvas.state = EditState(image: snip.image, scale: snip.scale, strokes: [])
            undoStack.removeAll()
            redoStack.removeAll()
            dirty = false
            savedURL = nil
            setTool(.pen)
            updateUI()
            fitWindowToImage()
            show()
            zoomToFit()
        }
        if dirty && canvas.hasImage {
            show()
            confirmDiscard { ok in if ok { apply() } }
        } else {
            apply()
        }
    }

    /// README screenshot aid (`--demo-markup`): adds example pen and highlighter marks to a window snip of the
    /// About window (no shadow). Positions are fractions of the image, measured from the top. The marks don't
    /// count as an edit, so nothing is auto-copied to the clipboard.
    func addDemoMarkup() {
        guard let s = canvas.state else { return }
        let w = s.pointSize.width, h = s.pointSize.height
        func pt(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: w * fx, y: h * (1 - fy)) }
        let underline = Stroke(points: [pt(0.37, 0.517), pt(0.63, 0.517)], color: .systemBlue,
                               width: canvas.penWidth, highlighter: false)
        let highlight = Stroke(points: [pt(0.16, 0.558), pt(0.84, 0.558)], color: canvas.highlighterColor,
                               width: canvas.highlighterWidth, highlighter: true)
        let center = pt(0.5, 0.717), rx = w * 0.19, ry = h * 0.038
        let ellipse = Stroke(points: (0...60).map { i in
            let a = CGFloat(i) / 60 * 2 * .pi
            return CGPoint(x: center.x + rx * cos(a), y: center.y + ry * sin(a))
        }, color: .systemRed, width: canvas.penWidth, highlighter: false)
        canvas.state?.strokes += [underline, highlight, ellipse]
    }

    private func fitWindowToImage() {
        guard let st = canvas.state else { return }
        let screen = window.screen ?? NSScreen.under(NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        let pad: CGFloat = 40
        let w = min(max(st.pointSize.width + pad * 2, window.minSize.width), vis.width * 0.9)
        let h = min(max(st.pointSize.height + pad * 2 + EditorWindow.barHeight, window.minSize.height), vis.height * 0.9)
        window.setFrame(NSRect(x: (vis.midX - w / 2).rounded(), y: (vis.midY - h / 2).rounded(), width: w, height: h),
                        display: true)
        window.layoutIfNeeded()
    }

    // MARK: State

    private func contentChanged() {
        dirty = true
        updateUI()
        scheduleAutoCopy()
    }

    private func updateUI() {
        let has = canvas.hasImage
        for b in [penButton, highlighterButton, eraserButton, cropButton, zoomButton, saveButton, copyButton, shareButton] {
            b?.isEnabled = has
        }
        undoButton.isEnabled = has && !undoStack.isEmpty
        redoButton.isEnabled = has && !redoStack.isEmpty
        emptyLabel.isHidden = has
        scrollView.isHidden = !has
        updateEmptyText()
    }

    private func applyInkSettings() {
        let pc = penColors[min(penColorIndex, penColors.count - 1)].1
        let hc = highlighterColors[min(hlColorIndex, highlighterColors.count - 1)].1
        canvas.penColor = pc
        canvas.penWidth = penSizes[min(penSizeIndex, penSizes.count - 1)].1
        canvas.highlighterColor = hc
        canvas.highlighterWidth = highlighterSizes[min(hlSizeIndex, highlighterSizes.count - 1)].1
        penButton?.indicatorColor = pc
        highlighterButton?.indicatorColor = hc
    }

    private func setTool(_ t: Tool) {
        if t == .crop && canvas.tool != .crop { toolBeforeCrop = canvas.tool }
        canvas.tool = t
        penButton.isSelected = t == .pen
        highlighterButton.isSelected = t == .highlighter
        eraserButton.isSelected = t == .eraser
        cropButton.isSelected = t == .crop
        let cropping = t == .crop
        for v in [penButton, highlighterButton, eraserButton, cropButton, undoButton, redoButton] as [NSView] {
            v.isHidden = cropping
        }
        separators.prefix(2).forEach { $0.isHidden = cropping }
        applyCropButton.isHidden = !cropping
        cancelCropButton.isHidden = !cropping
        window.makeFirstResponder(canvas)
    }

    private func scheduleAutoCopy() {
        guard Settings.autoCopyChanges else { return }
        copyWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.copyImage() }
        copyWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private var flattened: CGImage? { canvas.state.map(CanvasView.render) }

    // MARK: Dropdown menus

    private func menuItem(_ title: String, _ action: Selector, tag: Int = 0, symbol: String? = nil,
                          on: Bool = false) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.tag = tag
        it.state = on ? .on : .off
        if let symbol { it.image = sym(symbol, size: 14) }
        return it
    }

    @objc private func showModeMenu(_ b: BarButton) {
        let m = NSMenu()
        for mode in SnipMode.allCases {
            m.addItem(menuItem(mode.title, #selector(modePicked(_:)), tag: mode.rawValue, symbol: mode.symbol,
                               on: mode == Settings.mode))
        }
        b.popUp(m)
    }

    @objc private func modePicked(_ it: NSMenuItem) {
        if let m = SnipMode(rawValue: it.tag) { Settings.mode = m }
        refreshSettingsUI()
    }

    @objc private func showDelayMenu(_ b: BarButton) {
        let m = NSMenu()
        for d in [0, 3, 5, 10] {
            m.addItem(menuItem(d == 0 ? "No delay" : "Snip in \(d) seconds", #selector(delayPicked(_:)), tag: d,
                               on: d == Settings.delay))
        }
        b.popUp(m)
    }

    @objc private func delayPicked(_ it: NSMenuItem) {
        Settings.delay = it.tag
        refreshSettingsUI()
    }

    @objc private func showZoomMenu(_ b: BarButton) {
        let m = NSMenu()
        m.addItem(menuItem("Zoom In", #selector(zoomIn), symbol: "plus.magnifyingglass"))
        m.addItem(menuItem("Zoom Out", #selector(zoomOut), symbol: "minus.magnifyingglass"))
        m.addItem(.separator())
        m.addItem(menuItem("Actual Size", #selector(actualSize)))
        m.addItem(menuItem("Zoom to Fit", #selector(zoomToFit)))
        b.popUp(m)
    }

    @objc private func showMoreMenu(_ b: BarButton) {
        let m = NSMenu()
        m.autoenablesItems = false
        let preview = menuItem("Open in Preview", #selector(openInPreview), symbol: "eye")
        preview.isEnabled = canvas.hasImage
        m.addItem(preview)
        let finder = menuItem("Show in Finder", #selector(showInFinder), symbol: "folder")
        finder.isEnabled = savedURL != nil
        m.addItem(finder)
        m.addItem(menuItem("Open Screenshots Folder", #selector(openScreenshotsFolder), symbol: "photo.on.rectangle"))
        b.popUp(m)
    }

    // MARK: Right-click menu on the snip

    private func contextMenu(at p: NSPoint) -> NSMenu? {
        guard canvas.hasImage, canvas.tool != .crop else { return nil }
        let m = NSMenu()
        m.addItem(menuItem("Copy", #selector(copyImage), symbol: "doc.on.doc"))
        m.addItem(menuItem("Save As…", #selector(save), symbol: "square.and.arrow.down"))
        let share = menuItem("Share…", #selector(shareFromContext(_:)), symbol: "square.and.arrow.up")
        share.representedObject = NSValue(point: p)
        m.addItem(share)
        return m
    }

    @objc private func shareFromContext(_ it: NSMenuItem) {
        let p = (it.representedObject as? NSValue)?.pointValue ?? NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        showSharePicker(relativeTo: NSRect(x: p.x, y: p.y, width: 1, height: 1), of: canvas)
    }

    // MARK: Actions

    @objc func newSnip() {
        if canvas.tool == .crop { cancelCrop() }
        onNewSnip?()
    }

    @objc private func penClicked(_ b: BarButton) {
        let was = canvas.tool == .pen
        setTool(.pen)
        if was { showInkMenu(highlighter: false, from: b) }
    }

    @objc private func highlighterClicked(_ b: BarButton) {
        let was = canvas.tool == .highlighter
        setTool(.highlighter)
        if was { showInkMenu(highlighter: true, from: b) }
    }

    @objc private func eraserClicked(_ b: BarButton) {
        let was = canvas.tool == .eraser
        setTool(.eraser)
        if was {
            let m = NSMenu()
            m.addItem(menuItem("Erase all ink", #selector(eraseAll)))
            b.popUp(m)
        }
    }

    @objc private func eraseAll() { canvas.eraseAll() }

    @objc private func cropClicked() {
        guard canvas.hasImage else { return }
        if canvas.tool == .crop { cancelCrop() } else { setTool(.crop) }
    }

    @objc private func applyCrop() {
        canvas.applyCrop()
        setTool(toolBeforeCrop == .crop ? .pen : toolBeforeCrop)
        zoomToFit()
    }

    @objc private func cancelCrop() {
        setTool(toolBeforeCrop == .crop ? .pen : toolBeforeCrop)
    }

    @objc func undo() {
        guard let prev = undoStack.popLast(), let cur = canvas.state else { return }
        redoStack.append(cur)
        canvas.state = prev
        contentChanged()
    }

    @objc func redo() {
        guard let next = redoStack.popLast(), let cur = canvas.state else { return }
        undoStack.append(cur)
        canvas.state = next
        contentChanged()
    }

    @objc func copyImage() {
        guard let st = canvas.state, let img = flattened else { return }
        ImageUtil.copy(img, scale: st.scale)
    }

    @objc func save() { saveAs(completion: nil) }

    private func saveAs(completion: ((Bool) -> Void)?) {
        guard let st = canvas.state, let img = flattened else { completion?(false); return }
        SnipSaver.save(img, scale: st.scale, over: window) { [weak self] url in
            if let url, let self {
                self.savedURL = url
                self.dirty = false
                self.updateUI()
            }
            completion?(url != nil)
        }
    }

    @objc private func share(_ sender: BarButton) {
        showSharePicker(relativeTo: sender.bounds, of: sender)
    }

    private func showSharePicker(relativeTo rect: NSRect, of view: NSView) {
        guard let st = canvas.state, let img = flattened, let url = ImageUtil.writeTemp(img, scale: st.scale) else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    @objc private func openInPreview() {
        guard let st = canvas.state, let img = flattened, let url = ImageUtil.writeTemp(img, scale: st.scale) else { return }
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showInFinder() {
        if let u = savedURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    @objc private func openScreenshotsFolder() {
        let f = Settings.saveFolder
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        NSWorkspace.shared.open(f)
    }

    private func setZoom(_ m: CGFloat) {
        let v = scrollView.documentVisibleRect
        scrollView.setMagnification(min(max(m, scrollView.minMagnification), scrollView.maxMagnification),
                                    centeredAt: NSPoint(x: v.midX, y: v.midY))
        canvas.needsDisplay = true
    }

    @objc func zoomIn() { setZoom(scrollView.magnification * 1.25) }
    @objc func zoomOut() { setZoom(scrollView.magnification / 1.25) }
    @objc func actualSize() { setZoom(1) }

    @objc func zoomToFit() {
        guard let st = canvas.state else { return }
        window.layoutIfNeeded()
        let avail = scrollView.frame.size
        let s = st.pointSize
        let m = min(1, (avail.width - 48) / max(s.width, 1), (avail.height - 48) / max(s.height, 1))
        scrollView.magnification = max(m, scrollView.minMagnification)
        canvas.needsDisplay = true
    }

    // MARK: Ink menu

    private func swatch(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            c.setFill()
            p.fill()
            NSColor.separatorColor.setStroke()
            p.lineWidth = 1
            p.stroke()
            return true
        }
    }

    private func sizeDot(_ w: CGFloat) -> NSImage {
        let d = min(max(w, 2), 14)
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
            return true
        }
    }

    private func showInkMenu(highlighter: Bool, from b: BarButton) {
        let m = NSMenu()
        m.addItem(NSMenuItem.sectionHeader(title: "Color"))
        let colors = highlighter ? highlighterColors : penColors
        let selColor = highlighter ? hlColorIndex : penColorIndex
        for (i, c) in colors.enumerated() {
            let it = menuItem(c.0, #selector(inkPicked(_:)), tag: (highlighter ? 1000 : 0) + i, on: i == selColor)
            it.image = swatch(c.1)
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(NSMenuItem.sectionHeader(title: "Size"))
        let sizes = highlighter ? highlighterSizes : penSizes
        let selSize = highlighter ? hlSizeIndex : penSizeIndex
        for (i, s) in sizes.enumerated() {
            let it = menuItem(s.0, #selector(inkPicked(_:)), tag: (highlighter ? 1000 : 0) + 100 + i, on: i == selSize)
            it.image = sizeDot(s.1 * (highlighter ? 0.5 : 1))
            m.addItem(it)
        }
        b.popUp(m)
    }

    @objc private func inkPicked(_ it: NSMenuItem) {
        let hl = it.tag >= 1000
        let t = it.tag % 1000
        if t >= 100 {
            if hl { hlSizeIndex = t - 100 } else { penSizeIndex = t - 100 }
        } else {
            if hl { hlColorIndex = t } else { penColorIndex = t }
        }
    }

    // MARK: Closing

    func confirmDiscard(_ done: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = "Do you want to save changes to this snip?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save")
        let dont = a.addButton(withTitle: "Don't Save")
        dont.keyEquivalent = "d"
        dont.keyEquivalentModifierMask = .command
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] resp in
            switch resp {
            case .alertFirstButtonReturn:
                DispatchQueue.main.async { self?.saveAs(completion: done) }
            case .alertSecondButtonReturn:
                self?.dirty = false
                done(true)
            default:
                done(false)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty && canvas.hasImage else { return true }
        confirmDiscard { [weak self] ok in
            if ok { self?.window.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        copyWork?.cancel()
        if canvas.tool == .crop { setTool(.pen) }
        canvas.state = nil
        undoStack.removeAll()
        redoStack.removeAll()
        dirty = false
        savedURL = nil
        updateUI()
    }

    // Keep the traffic lights centered in the tall bar.
    func windowDidResize(_ notification: Notification) { window.positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { window.positionTrafficLights() }
    func windowDidResignKey(_ notification: Notification) { window.positionTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) {
        leadInset.constant = 92
        window.positionTrafficLights()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        leadInset.constant = 12
    }

    // MARK: Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo): return window.isKeyWindow && !undoStack.isEmpty
        case #selector(redo): return window.isKeyWindow && !redoStack.isEmpty
        case #selector(save), #selector(copyImage), #selector(zoomIn), #selector(zoomOut),
             #selector(actualSize), #selector(zoomToFit):
            return canvas.hasImage
        default: return true
        }
    }
}
