import AppKit
import UniformTypeIdentifiers

/// "Save as" panel with a PNG / JPEG format picker. Used by the editor, its right-click menu and the toast.
final class SnipSaver: NSObject {
    private static var active: SnipSaver?
    private let panel = NSSavePanel()
    private let image: CGImage
    private let scale: CGFloat

    private init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    static func save(_ image: CGImage, scale: CGFloat, over window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let s = SnipSaver(image: image, scale: scale)
        active = s
        s.run(over: window, completion: completion)
    }

    private func run(over window: NSWindow?, completion: @escaping (URL?) -> Void) {
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ImageUtil.timestampName()
        let folder = Settings.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        panel.directoryURL = folder
        panel.canCreateDirectories = true

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 20, y: 11, width: 60, height: 18)
        let fmt = NSPopUpButton(frame: NSRect(x: 80, y: 6, width: 140, height: 28), pullsDown: false)
        fmt.addItems(withTitles: ["PNG", "JPEG"])
        fmt.target = self
        fmt.action = #selector(formatChanged(_:))
        accessory.addSubview(label)
        accessory.addSubview(fmt)
        panel.accessoryView = accessory

        let handler: (NSApplication.ModalResponse) -> Void = { [self] resp in
            defer { SnipSaver.active = nil }
            guard resp == .OK, let url = panel.url else { completion(nil); return }
            let ext = url.pathExtension.lowercased()
            let data = (ext == "jpg" || ext == "jpeg") ? ImageUtil.jpeg(image, scale: scale) : ImageUtil.png(image, scale: scale)
            do {
                guard let data else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url)
                completion(url)
            } catch {
                NSAlert(error: error).runModal()
                completion(nil)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.begin(completionHandler: handler)
        }
    }

    @objc private func formatChanged(_ p: NSPopUpButton) {
        panel.allowedContentTypes = p.indexOfSelectedItem == 1 ? [.jpeg] : [.png]
    }
}
