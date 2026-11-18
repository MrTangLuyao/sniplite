import AppKit
import Carbon.HIToolbox

/// A global shortcut: a virtual key code (the same codes as NSEvent.keyCode) and Carbon modifiers.
struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var mods: UInt32       // Carbon: cmdKey, shiftKey, optionKey, controlKey
    var label: String      // the key's name, e.g. "F1", "A"

    var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label
    }

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    static let fKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
    static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]

    /// The name of the key in an event, or nil for keys that cannot be a shortcut.
    static func label(for e: NSEvent) -> String? {
        let code = Int(e.keyCode)
        if let f = fKeys[code] { return f }
        if let n = namedKeys[code] { return n }
        if code == kVK_Escape { return nil }
        guard let c = e.charactersIgnoringModifiers?.uppercased(), !c.isEmpty,
              c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return c
    }

    static func f(_ n: Int, shift: Bool = false) -> HotKey {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4]
        return HotKey(keyCode: UInt32(codes[n - 1]), mods: shift ? UInt32(shiftKey) : 0, label: "F\(n)")
    }
}

/// What a global shortcut does; the defaults are the ones of the Windows version.
enum HotAction: String, CaseIterable, Codable {
    case capture, pinClipboard, togglePins, ocr, ocrCopy

    var isOCR: Bool { self == .ocr || self == .ocrCopy }
    /// The actions in use: the text ones only while text recognition is on.
    static var active: [HotAction] { allCases.filter { !$0.isOCR || Prefs.shared.ocrEnabled } }

    var title: String {
        switch self {
        case .capture: return L.t("capture")
        case .pinClipboard: return L.t("pinClipboard")
        case .togglePins: return L.t("togglePins")
        case .ocr: return L.t("ocrCapture")
        case .ocrCopy: return L.t("ocrCopyCapture")
        }
    }

    var defaultKey: HotKey {
        switch self {
        case .capture: return .f(1)
        case .pinClipboard: return .f(3)
        case .togglePins: return .f(3, shift: true)
        case .ocr: return .f(4)
        case .ocrCopy: return .f(4, shift: true)
        }
    }
}

/// Registers the global shortcuts through Carbon, which needs no Accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: HotAction] = [:]
    var handler: ((HotAction) -> Void)?
    private var installed = false

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) {
        Log.write(String(format: "hotkey %u", id))
        if let a = actions[id] { handler?(a) }
    }

    /// Unregisters everything and registers the shortcuts in Prefs. Returns the actions that failed.
    @discardableResult
    func registerAll() -> [HotAction] {
        install()
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll(); actions.removeAll()
        var failed: [HotAction] = []
        for (i, a) in HotAction.allCases.enumerated() where HotAction.active.contains(a) {
            guard let k = Prefs.shared.hotkey(a) else { continue }
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(k.keyCode, k.mods, EventHotKeyID(signature: OSType(0x534E504C), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref); actions[id] = a } else { failed.append(a) }
            Log.write(String(format: "register %@ (%@): %d", a.rawValue, k.display, st))
        }
        return failed
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll(); actions.removeAll()
    }
}
