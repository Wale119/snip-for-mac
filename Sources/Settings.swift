import AppKit
import Carbon.HIToolbox

enum SnipMode: Int, CaseIterable {
    case rectangle, window, fullscreen, freeform

    var title: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .window: return "Window"
        case .fullscreen: return "Full screen"
        case .freeform: return "Freeform"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullscreen: return "display"
        case .freeform: return "lasso"
        }
    }
}

struct HotKeyOption {
    let title: String
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyEquivalent: String
    let modifierMask: NSEvent.ModifierFlags
    let display: String

    static let all: [HotKeyOption] = [
        HotKeyOption(title: "⇧⌘S  (same keys as ⊞ Win + Shift + S)", keyCode: UInt32(kVK_ANSI_S),
                     carbonModifiers: UInt32(cmdKey | shiftKey), keyEquivalent: "s",
                     modifierMask: [.command, .shift], display: "⇧⌘S"),
        HotKeyOption(title: "⌃⇧S", keyCode: UInt32(kVK_ANSI_S),
                     carbonModifiers: UInt32(controlKey | shiftKey), keyEquivalent: "s",
                     modifierMask: [.control, .shift], display: "⌃⇧S"),
        HotKeyOption(title: "⌥⇧S", keyCode: UInt32(kVK_ANSI_S),
                     carbonModifiers: UInt32(optionKey | shiftKey), keyEquivalent: "s",
                     modifierMask: [.option, .shift], display: "⌥⇧S"),
        HotKeyOption(title: "F13  (the Print Screen key on PC keyboards)", keyCode: UInt32(kVK_F13),
                     carbonModifiers: 0,
                     keyEquivalent: String(Character(UnicodeScalar(UInt32(NSF13FunctionKey))!)),
                     modifierMask: [], display: "F13"),
    ]
}

enum Settings {
    private static let d = UserDefaults.standard

    private static func bool(_ key: String, default def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }

    static var mode: SnipMode {
        get { SnipMode(rawValue: d.integer(forKey: "mode")) ?? .rectangle }
        set { d.set(newValue.rawValue, forKey: "mode") }
    }

    /// Seconds. Only applies to "New" from the editor / menu bar, like Windows.
    static var delay: Int {
        get { d.integer(forKey: "delay") }
        set { d.set(newValue, forKey: "delay") }
    }

    static var hotKeyIndex: Int {
        get { min(max(d.integer(forKey: "hotKeyIndex"), 0), HotKeyOption.all.count - 1) }
        set { d.set(newValue, forKey: "hotKeyIndex") }
    }

    static var hotKey: HotKeyOption { HotKeyOption.all[hotKeyIndex] }

    static var autoSave: Bool {
        get { bool("autoSave", default: true) }
        set { d.set(newValue, forKey: "autoSave") }
    }

    static var autoCopyChanges: Bool {
        get { bool("autoCopyChanges", default: true) }
        set { d.set(newValue, forKey: "autoCopyChanges") }
    }

    static var saveFolder: URL {
        get {
            if let p = d.string(forKey: "saveFolder") { return URL(fileURLWithPath: p, isDirectory: true) }
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Screenshots", isDirectory: true)
        }
        set { d.set(newValue.path, forKey: "saveFolder") }
    }

    static func int(_ key: String, default def: Int) -> Int {
        d.object(forKey: key) == nil ? def : d.integer(forKey: key)
    }

    static func setInt(_ v: Int, _ key: String) { d.set(v, forKey: key) }

    static var hasLaunchedBefore: Bool {
        get { d.bool(forKey: "hasLaunchedBefore") }
        set { d.set(newValue, forKey: "hasLaunchedBefore") }
    }
}

func sym(_ name: String, size: CGFloat = 15, weight: NSFont.Weight = .regular) -> NSImage {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)!
    return img.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? img
}
