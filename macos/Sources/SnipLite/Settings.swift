import AppKit
import ServiceManagement

/// The settings, kept in UserDefaults (~/Library/Preferences/<bundle id>.plist).
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    var language: String {
        get { d.string(forKey: "language") ?? "system" }
        set { d.set(newValue, forKey: "language") }
    }
    var pinOnTop: Bool {
        get { d.object(forKey: "pinOnTop") as? Bool ?? true }
        set { d.set(newValue, forKey: "pinOnTop") }
    }
    /// The F1–F12 shortcuts on Mac keyboards (an event tap; needs the Accessibility permission).
    var topRowKeys: Bool { true }   // always: F1 should just work, as on Windows
    /// Text recognition: its buttons, menu items and F4 / ⇧F4. Off until turned on.
    var ocrEnabled: Bool {
        get { d.object(forKey: "ocrEnabled") as? Bool ?? false }
        set { d.set(newValue, forKey: "ocrEnabled") }
    }
    /// Index into Palette.colors and Palette.sizes, remembered between captures.
    var colorIndex: Int {
        get { d.object(forKey: "colorIndex") as? Int ?? 0 }
        set { d.set(newValue, forKey: "colorIndex") }
    }
    /// The width of the drawing tools (also sets text size, number size and mosaic squares).
    /// Each tool has its own size, remembered between captures; one does not change another.
    /// The defaults are on the small side: lines 3 px, text about 17 pt, numbers about 19 pt across.
    static let defaultWidths: [Tool: CGFloat] = [.rect: 3, .ellipse: 3, .line: 3, .arrow: 3, .pen: 3,
                                                  .marker: 3, .mosaic: 4, .text: 3, .number: 3]
    private var widths: [Tool: CGFloat] = [:]

    func width(for t: Tool) -> CGFloat {
        if let w = widths[t] { return w }
        let w = (d.object(forKey: "width.\(t)") as? Double).map { CGFloat($0) } ?? Self.defaultWidths[t] ?? 3
        widths[t] = w
        return w
    }

    func setWidth(_ w: CGFloat, for t: Tool) {
        widths[t] = w
        d.set(Double(w), forKey: "width.\(t)")
    }
    var mosaicMode: MosaicMode {
        get { MosaicMode(rawValue: d.string(forKey: "mosaicMode") ?? "") ?? .rect }   // "fill" from before: a box
        set { d.set(newValue.rawValue, forKey: "mosaicMode") }
    }
    /// The hide tool covers with the color instead of mosaic.
    var mosaicSolid: Bool {
        get { d.bool(forKey: "mosaicSolid") }
        set { d.set(newValue, forKey: "mosaicSolid") }
    }

    /// nil: no shortcut for that action.
    func hotkey(_ a: HotAction) -> HotKey? {
        let key = "hotkey." + a.rawValue
        guard let data = d.data(forKey: key) else { return a.defaultKey }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(HotKey.self, from: data)) ?? a.defaultKey
    }
    func setHotkey(_ a: HotAction, _ k: HotKey?) {
        let key = "hotkey." + a.rawValue
        if let k, let data = try? JSONEncoder().encode(k) { d.set(data, forKey: key) } else { d.set(Data(), forKey: key) }
    }
}

/// A field that records a shortcut: click it, then press the keys. Delete or Backspace clears it.
final class HotKeyField: NSButton {
    var hotkey: HotKey? { didSet { refresh() } }
    var onChange: ((HotKey?) -> Void)?
    private var recording = false { didSet { refresh(); HotKeyField.active = recording ? self : nil } }

    /// The field recording now: the event tap hands it the F keys (it would run their shortcuts
    /// otherwise, since on a Mac keyboard F1 without fn never reaches a key-down here).
    static weak var active: HotKeyField?

    /// An F key seen by the event tap while recording.
    func takeFKey(_ code: Int, mods: UInt32) {
        guard recording, let label = HotKey.fKeys[code] else { return }
        hotkey = HotKey(keyCode: UInt32(code), mods: mods, label: label)
        onChange?(hotkey)
        window?.makeFirstResponder(nil)
    }

    init(_ k: HotKey?) {
        hotkey = k
        super.init(frame: .zero)
        bezelStyle = .push
        controlSize = .small
        font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        setButtonType(.momentaryPushIn)
        target = self; action = #selector(start)
        widthAnchor.constraint(equalToConstant: 120).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        title = recording ? L.t("recordHint") : (hotkey?.display ?? L.t("none"))
    }

    @objc private func start() {
        recording = true
        HotKeyCenter.shared.unregisterAll()   // so the old shortcut can be pressed again
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        if recording { recording = false; HotKeyCenter.shared.registerAll() }
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if recording { keyDown(with: e); return true }
        return super.performKeyEquivalent(with: e)
    }

    override func keyDown(with e: NSEvent) {
        guard recording else { super.keyDown(with: e); return }
        let code = Int(e.keyCode)
        if code == 0x35 { window?.makeFirstResponder(nil); return }                // Esc: keep the old one
        if (code == 0x33 || code == 0x75) && e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            hotkey = nil                                                           // Backspace / Delete
        } else {
            guard let label = HotKey.label(for: e) else { return }
            let mods = HotKey.carbonMods(e.modifierFlags)
            let isF = HotKey.fKeys[code] != nil
            if mods == 0 && !isF { NSSound.beep(); return }   // a plain letter would block typing everywhere
            hotkey = HotKey(keyCode: UInt32(code), mods: mods, label: label)
        }
        onChange?(hotkey)
        window?.makeFirstResponder(nil)
    }
}

/// Settings, in the style of System Settings: grouped cards, a switch at the end of each row.
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    static var shared: SettingsWindow?

    static func show() {
        if shared == nil { shared = SettingsWindow() }
        NSApp.activate(ignoringOtherApps: true)
        shared?.window?.center()
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        shared?.refreshPermissions()
    }

    private let status = NSTextField(wrappingLabelWithString: "")
    private let permState = NSTextField(labelWithString: "")
    private let permIcon = NSImageView()
    private let width: CGFloat = 500

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]   // opens on the current desktop
        w.title = L.t("settings").replacingOccurrences(of: "…", with: "")
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: building blocks

    private func header(_ s: String) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabelColor
        let v = NSStackView(views: [l])
        v.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        return v
    }

    /// A row: title (and a smaller line under it), then the control at the end.
    private func row(_ title: String, _ detail: String? = nil, _ control: NSView) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13)
        var texts: [NSView] = [t]
        if let detail {
            let d = NSTextField(wrappingLabelWithString: detail)
            d.font = .systemFont(ofSize: 11)
            d.textColor = .secondaryLabelColor
            d.preferredMaxLayoutWidth = 300
            texts.append(d)
        }
        let text = NSStackView(views: texts)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let r = NSStackView(views: [text, spacer, control])
        r.alignment = .centerY
        r.spacing = 12
        r.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        r.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return r
    }

    /// Rows in one card, with hairlines between them.
    private func group(_ rows: [NSView]) -> NSView {
        var views: [NSView] = []
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let line = NSBox()
                line.boxType = .separator
                let inset = NSStackView(views: [line])
                inset.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 0)
                views.append(inset)
            }
            views.append(r)
        }
        let st = NSStackView(views: views)
        st.orientation = .vertical
        st.spacing = 0
        for v in views { v.widthAnchor.constraint(equalTo: st.widthAnchor).isActive = true }
        return card(st, inset: 0)
    }

    private func toggle(_ on: Bool, _ action: Selector) -> NSSwitch {
        let s = NSSwitch()
        s.controlSize = .small
        s.state = on ? .on : .off
        s.target = self
        s.action = action
        return s
    }

    // MARK: the page

    private func build() {
        let bg = NSVisualEffectView()
        bg.material = .underWindowBackground
        bg.blendingMode = .behindWindow
        bg.state = .active

        // shortcuts
        var keyRows: [NSView] = []
        for a in HotAction.allCases {
            let f = HotKeyField(Prefs.shared.hotkey(a))
            f.onChange = { [weak self] k in
                Prefs.shared.setHotkey(a, k)
                let failed = HotKeyCenter.shared.registerAll()
                self?.status.stringValue = failed.contains(a) ? L.t("hkConflict") : ""
                self?.status.textColor = failed.contains(a) ? .systemRed : .secondaryLabelColor
            }
            keyRows.append(row(a.title, nil, f))
        }

        // general
        let lang = NSPopUpButton()
        lang.controlSize = .small
        let names: [(L.Lang, String)] = [(.system, L.t("langSystem")), (.en, "English"),
                                         (.zhHans, "简体中文"), (.zhHant, "繁體中文")]
        for (code, name) in names {
            lang.addItem(withTitle: name); lang.lastItem?.representedObject = code.rawValue
            if Prefs.shared.language == code.rawValue { lang.select(lang.lastItem) }
        }
        lang.target = self; lang.action = #selector(pickLang(_:))
        let general = group([
            row(L.t("launchAtLogin"), nil, toggle(SMAppService.mainApp.status == .enabled, #selector(toggleLogin(_:)))),
            row(L.t("ocrTitle2"), L.t("ocrDetail"), toggle(Prefs.shared.ocrEnabled, #selector(toggleOCR(_:)))),
            row(L.t("pinTop"), nil, toggle(Prefs.shared.pinOnTop, #selector(togglePinTop(_:)))),
            row(L.t("language"), nil, lang),
        ])

        // permissions: their state and the button to the permissions page
        permIcon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        permState.font = .systemFont(ofSize: 12)
        let manage = NSButton(title: L.t("manage"), target: self, action: #selector(openPermissions))
        manage.controlSize = .small
        manage.bezelStyle = .push
        let permRight = NSStackView(views: [permIcon, permState, manage])
        permRight.spacing = 6
        permRight.alignment = .centerY
        permRight.setCustomSpacing(12, after: permState)
        let perms = group([row(L.t("permStatus"), nil, permRight)])

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.stringValue = ""
        status.preferredMaxLayoutWidth = width - 60
        let foot = NSStackView(views: [status])
        foot.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)

        let items: [NSView] = [header(L.t("hotkeys")), group(keyRows),
                               header(L.t("general")), general,
                               header(L.t("permissions")), perms, foot]
        let stack = NSStackView(views: items)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for (i, v) in items.enumerated() where i > 0 && i % 2 == 0 && i < items.count - 1 {
            stack.setCustomSpacing(18, after: items[i - 1])
            _ = v
        }
        stack.setCustomSpacing(14, after: perms)
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in items { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true }
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        window?.contentView = bg
        refreshPermissions()
    }

    private func refreshPermissions() {
        let missing = Permission.allCases.filter { $0.required && !$0.granted }.count
        if missing == 0 {
            permIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            permIcon.contentTintColor = .systemGreen
            permState.stringValue = L.t("permAllOK")
            permState.textColor = .secondaryLabelColor
        } else {
            permIcon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
            permIcon.contentTintColor = .systemOrange
            permState.stringValue = String(format: L.t("permMissing"), missing)
            permState.textColor = .systemOrange
        }
    }

    // MARK: actions

    @objc private func toggleLogin(_ b: NSSwitch) {
        do {
            if b.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status.stringValue = error.localizedDescription
            status.textColor = .systemRed
            b.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func toggleOCR(_ b: NSSwitch) {
        Prefs.shared.ocrEnabled = b.state == .on
        HotKeyCenter.shared.registerAll()
    }

    @objc private func togglePinTop(_ b: NSSwitch) {
        Prefs.shared.pinOnTop = b.state == .on
        PinWindow.applyLevelToAll()
    }

    @objc private func pickLang(_ p: NSPopUpButton) {
        Prefs.shared.language = p.selectedItem?.representedObject as? String ?? "system"
        status.stringValue = L.t("langRestart")
        status.textColor = .secondaryLabelColor
    }

    @objc private func openPermissions() { PermissionsWindow.show() }

    func windowDidBecomeKey(_ notification: Notification) { refreshPermissions() }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }
}
