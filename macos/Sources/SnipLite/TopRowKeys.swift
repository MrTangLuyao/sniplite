import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// On a Mac keyboard F1, F3 and F4 send brightness down, Mission Control and Spotlight / Launchpad
/// unless fn is held, so a plain F1 never reaches a global shortcut. This event tap turns those keys
/// back into F1 / F3 / F4 for the shortcuts that use them (the key then does only that), and it
/// catches real F-key shortcuts too, which some keyboards do not deliver to Carbon hotkeys.
/// It needs the Accessibility permission; without it the Carbon hotkeys (fn + F1) still work.
final class TopRowKeys {
    static let shared = TopRowKeys()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?

    private let nxSysDefined = CGEventType(rawValue: 14)!   // NX_SYSDEFINED
    private static let brightnessDown = 3                   // NX_KEYTYPE_BRIGHTNESS_DOWN
    private static let missionControl: UInt16 = 160         // the F3 key without fn
    private static let spotlight: UInt16 = 177              // the F4 key without fn (newer keyboards)
    private static let launchpad: UInt16 = 131              // the F4 key without fn (older keyboards)

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Starts (or stops) following Prefs.topRowKeys. Asks for the permission once if needed.
    func update(prompt: Bool) {
        guard Prefs.shared.topRowKeys else { stop(); return }
        if tap != nil { return }
        if !AXIsProcessTrusted() {
            if prompt { PermissionsWindow.show() }
            // the permission is granted in System Settings while sniplite runs: start as soon as it is
            if retry == nil {
                retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self, AXIsProcessTrusted() else { return }
                    self.retry?.invalidate(); self.retry = nil
                    self.update(prompt: false)
                }
            }
            return
        }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << 14)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, _ in
                                            TopRowKeys.shared.handle(type, event)
                                        }, userInfo: nil) else {
            Log.write("could not create the event tap")
            return
        }
        Log.write("event tap on")
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func stop() {
        retry?.invalidate(); retry = nil
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }

    static func carbonMods(_ flags: CGEventFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.maskCommand) { mods |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { mods |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { mods |= UInt32(optionKey) }
        if flags.contains(.maskControl) { mods |= UInt32(controlKey) }
        return mods
    }

    /// The shortcut bound to this F key with these modifiers, if any.
    private func action(fKey: Int, flags: CGEventFlags) -> HotAction? {
        var mods: UInt32 = 0
        if flags.contains(.maskCommand) { mods |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { mods |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { mods |= UInt32(optionKey) }
        if flags.contains(.maskControl) { mods |= UInt32(controlKey) }
        return HotAction.active.first { a in
            guard let k = Prefs.shared.hotkey(a) else { return false }
            return Int(k.keyCode) == fKey && k.mods == mods
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        var fKey: Int?
        var down = false
        if type == nxSysDefined {
            guard let e = NSEvent(cgEvent: event), e.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
            let code = (e.data1 & 0xFFFF0000) >> 16
            let state = (e.data1 & 0xFF00) >> 8           // 0xA: down, 0xB: up
            if state == 0xA { Log.write("system key \(code)") }
            if code == Self.brightnessDown { fKey = kVK_F1; down = state == 0xA }
        } else {
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            switch code {
            case Self.missionControl: fKey = kVK_F3
            case Self.spotlight, Self.launchpad: fKey = kVK_F4
            case _ where HotKey.fKeys[Int(code)] != nil: fKey = Int(code)   // a real F key (fn held, or another keyboard)
            default: break
            }
            down = type == .keyDown
            if down && fKey != nil { Log.write("key \(code) -> F key \(fKey ?? 0)") }
        }
        // a shortcut field recording: the key is for it, not for a shortcut
        if let f = fKey, HotKeyField.active != nil {
            if down {
                let mods = Self.carbonMods(event.flags)
                DispatchQueue.main.async { HotKeyField.active?.takeFKey(f, mods: mods) }
            }
            return nil
        }
        guard let f = fKey, let a = action(fKey: f, flags: event.flags) else { return Unmanaged.passUnretained(event) }
        if down && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { AppDelegate.run(a) }
        }
        return nil   // swallowed: the key does the shortcut instead of brightness / Mission Control
    }
}
