import AppKit
import ServiceManagement

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let appMenu = NSMenu(title: "Snip")
    private let captureMenu = NSMenu(title: "Capture")
    private var session: SnipSession?
    private var pending = false
    private var previousApp: NSRunningApplication?
    private let toast = ToastController()

    private lazy var editor: EditorController = {
        let e = EditorController()
        e.onNewSnip = { [weak self] in self?.startSnip(fromEditor: true) }
        return e
    }()

    private static let snipHotKeyID: UInt32 = 1
    private static let escapeHotKeyID: UInt32 = 2

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        removeLegacyLoginItem()
        registerHotKey()
        // No permission prompt at launch: macOS asks on the first real snip, and
        // showPermissionHelp() explains what to do if capture is refused.

        let args = CommandLine.arguments
        // Testing / README screenshot aids:
        //   --open <image> [--demo-markup]   open an image in the editor (optionally with example marks)
        //   --toast <image>                  show the "copied to clipboard" notification for an image
        //   --about                          show the About window
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count, let snip = Self.snip(from: args[i + 1]) {
            editor.load(snip)
            if args.contains("--demo-markup") { editor.addDemoMarkup() }
        } else if let i = args.firstIndex(of: "--toast"), i + 1 < args.count, let snip = Self.snip(from: args[i + 1]) {
            toast.show(snip) { [weak self] in self?.editor.load(snip) }
        } else if args.contains("--about") {
            AboutWindowController.shared.show()
        } else {
            editor.showEmptyOrCurrent()
        }
    }

    /// Loads an image file as a Snip. The scale comes from the file's DPI (144 = Retina), defaulting to 2.
    private static func snip(from path: String) -> Snip? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 144
        return Snip(image: img, scale: max(1, (dpi / 72).rounded()))
    }

    /// "Open at Login" was removed; unregister Snip once if it had been turned on.
    private func removeLegacyLoginItem() {
        let key = "removedLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.global(qos: .utility).async {
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        }
    }

    // Closing the window keeps Snip running in the Dock so the shortcut keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        m.addItem(item("New snip", #selector(menuNewSnip)))
        return m
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        editor.showEmptyOrCurrent()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard editor.dirty && editor.hasImage else { return .terminateNow }
        editor.show()
        editor.confirmDiscard { ok in NSApp.reply(toApplicationShouldTerminate: ok) }
        return .terminateLater
    }

    // MARK: Snipping

    func startSnip(fromEditor: Bool) {
        guard session == nil, !pending else { return }
        pending = true
        toast.dismiss(animated: false)
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        if fromEditor { editor.hideForSnip() }
        // Like Windows: the delay applies to "New", not to the global shortcut.
        let delay = fromEditor ? Double(Settings.delay) : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + (fromEditor ? 0.15 : 0)) { [weak self] in
            Task { @MainActor in await self?.beginCapture(fromEditor: fromEditor) }
        }
    }

    @MainActor
    private func beginCapture(fromEditor: Bool) async {
        let rects = Capturer.windowRects()
        let frozen: [FrozenScreen]
        do {
            frozen = try await Capturer.captureScreens()
        } catch {
            pending = false
            if fromEditor { editor.showAgainAfterCancel() }
            showPermissionHelp(error)
            return
        }
        guard !frozen.isEmpty else {
            pending = false
            if fromEditor { editor.showAgainAfterCancel() }
            return
        }
        let s = SnipSession(frozen: frozen, windowRects: rects, mode: Settings.mode) { [weak self] snip in
            self?.finish(snip, fromEditor: fromEditor)
        }
        session = s
        pending = false
        HotKeyCenter.shared.register(id: Self.escapeHotKeyID, keyCode: 53, modifiers: 0) { [weak self] in
            self?.session?.cancel()
        }
        s.begin()
    }

    private func finish(_ snip: Snip?, fromEditor: Bool) {
        HotKeyCenter.shared.unregister(id: Self.escapeHotKeyID)
        session = nil
        guard let snip else {
            if fromEditor { editor.showAgainAfterCancel() } else { restorePreviousApp() }
            return
        }
        ImageUtil.copy(snip.image, scale: snip.scale)
        if Settings.autoSave { ImageUtil.autoSave(snip) }
        if fromEditor {
            editor.load(snip)
        } else {
            restorePreviousApp()
            toast.show(snip) { [weak self] in self?.editor.load(snip) }
        }
    }

    private func restorePreviousApp() {
        previousApp?.activate()
        previousApp = nil
    }

    private func showPermissionHelp(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Snip needs permission to capture your screen"
        a.informativeText = """
        Open System Settings → Privacy & Security → Screen & System Audio Recording, \
        turn on Snip, then quit and reopen Snip.

        (\(error.localizedDescription))
        """
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Quit Snip")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            CGRequestScreenCaptureAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default: break
        }
    }

    // MARK: Hotkey

    private func registerHotKey() {
        let opt = Settings.hotKey
        let ok = HotKeyCenter.shared.register(id: Self.snipHotKeyID, keyCode: opt.keyCode,
                                              modifiers: opt.carbonModifiers) { [weak self] in
            self?.startSnip(fromEditor: false)
        }
        if !ok {
            let a = NSAlert()
            a.messageText = "Couldn't use \(opt.display) as the snip shortcut"
            a.informativeText = "Another app may already be using it. Pick a different one from the Snip menu → Keyboard Shortcut."
            a.runModal()
        }
    }

    // MARK: App menus (Snip menu = settings, Capture menu = mode & delay)

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === appMenu { fillAppMenu(menu) } else if menu === captureMenu { fillCaptureMenu(menu) }
    }

    private func fillAppMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("About Snip", #selector(menuAbout)))
        menu.addItem(.separator())

        let keyMenu = NSMenu()
        for (i, o) in HotKeyOption.all.enumerated() {
            let it = item(o.title, #selector(menuPickHotKey(_:)))
            it.tag = i
            it.state = Settings.hotKeyIndex == i ? .on : .off
            keyMenu.addItem(it)
        }
        menu.addItem(submenu("Keyboard Shortcut (\(Settings.hotKey.display))", keyMenu))

        let autoCopy = item("Automatically Copy Changes", #selector(menuToggleAutoCopy))
        autoCopy.state = Settings.autoCopyChanges ? .on : .off
        menu.addItem(autoCopy)
        let autoSave = item("Automatically Save Screenshots", #selector(menuToggleAutoSave))
        autoSave.state = Settings.autoSave ? .on : .off
        menu.addItem(autoSave)
        menu.addItem(item("Change Save Folder… (\(Settings.saveFolder.lastPathComponent))", #selector(menuChooseFolder)))
        menu.addItem(item("Open Screenshots Folder", #selector(menuOpenFolder)))
        menu.addItem(.separator())

        menu.addItem(item("Hide Snip", #selector(NSApplication.hide(_:)), target: NSApp, key: "h"))
        let others = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), target: NSApp, key: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(others)
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        menu.addItem(.separator())
        menu.addItem(item("Quit Snip", #selector(NSApplication.terminate(_:)), target: NSApp, key: "q"))
    }

    private func fillCaptureMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let hk = Settings.hotKey
        let newItem = item("New Snip", #selector(menuNewSnip))
        newItem.keyEquivalent = hk.keyEquivalent
        newItem.keyEquivalentModifierMask = hk.modifierMask
        newItem.image = sym("scissors", size: 13)
        menu.addItem(newItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem.sectionHeader(title: "Snipping Mode"))
        for m in SnipMode.allCases {
            let it = item(m.title, #selector(menuPickMode(_:)), key: "\(m.rawValue + 1)")
            it.tag = m.rawValue
            it.image = sym(m.symbol, size: 13)
            it.state = Settings.mode == m ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Delay (for New)"))
        for d in [0, 3, 5, 10] {
            let it = item(d == 0 ? "No Delay" : "\(d) Seconds", #selector(menuPickDelay(_:)))
            it.tag = d
            it.state = Settings.delay == d ? .on : .off
            menu.addItem(it)
        }
    }

    private func item(_ title: String, _ action: Selector, target: AnyObject? = nil, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = target ?? self
        return it
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = sub
        return it
    }

    @objc private func menuNewSnip() {
        // Let the menu finish closing first.
        DispatchQueue.main.async { self.startSnip(fromEditor: false) }
    }

    @objc private func menuAbout() { AboutWindowController.shared.show() }

    @objc private func menuOpenEditor() { editor.showEmptyOrCurrent() }

    @objc private func menuPickMode(_ it: NSMenuItem) {
        if let m = SnipMode(rawValue: it.tag) { Settings.mode = m }
        editor.refreshSettingsUI()
    }

    @objc private func menuPickDelay(_ it: NSMenuItem) {
        Settings.delay = it.tag
        editor.refreshSettingsUI()
    }

    @objc private func menuPickHotKey(_ it: NSMenuItem) {
        Settings.hotKeyIndex = it.tag
        registerHotKey()
        editor.refreshSettingsUI()
    }

    @objc private func menuToggleAutoCopy() { Settings.autoCopyChanges.toggle() }
    @objc private func menuToggleAutoSave() { Settings.autoSave.toggle() }

    @objc private func menuChooseFolder() {
        // Non-blocking, and attached to Snip's window so it can't open hidden behind
        // other windows or on another display (which made Snip look frozen).
        DispatchQueue.main.async { [self] in
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.canCreateDirectories = true
            p.allowsMultipleSelection = false
            p.prompt = "Use Folder"
            p.message = "Choose where Snip saves your screenshots"
            p.directoryURL = Settings.saveFolder.deletingLastPathComponent()
            editor.showEmptyOrCurrent()
            p.beginSheetModal(for: editor.window) { resp in
                if resp == .OK, let url = p.url { Settings.saveFolder = url }
            }
        }
    }

    @objc private func menuOpenFolder() {
        let f = Settings.saveFolder
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        NSWorkspace.shared.open(f)
    }

    // MARK: Main menu (shown while the editor window is open)

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        appMenu.delegate = self
        fillAppMenu(appMenu)
        main.addItem(submenu("Snip", appMenu))

        let file = NSMenu(title: "File")
        file.addItem(menuItem("New Snip", #selector(EditorController.newSnip), "n"))
        file.addItem(menuItem("Save As…", #selector(EditorController.save), "s"))
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu("File", file))

        let edit = NSMenu(title: "Edit")
        edit.addItem(menuItem("Undo", #selector(EditorController.undo), "z"))
        let redo = menuItem("Redo", #selector(EditorController.redo), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(menuItem("Copy", #selector(EditorController.copyImage), "c"))
        main.addItem(submenu("Edit", edit))

        captureMenu.delegate = self
        fillCaptureMenu(captureMenu)
        main.addItem(submenu("Capture", captureMenu))

        let view = NSMenu(title: "View")
        view.addItem(menuItem("Zoom In", #selector(EditorController.zoomIn), "="))
        view.addItem(menuItem("Zoom Out", #selector(EditorController.zoomOut), "-"))
        view.addItem(menuItem("Actual Size", #selector(EditorController.actualSize), "0"))
        view.addItem(menuItem("Zoom to Fit", #selector(EditorController.zoomToFit), "9"))
        main.addItem(submenu("View", view))

        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu("Window", win))
        NSApp.windowsMenu = win
        return main
    }

    private func menuItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = editor
        return it
    }
}
