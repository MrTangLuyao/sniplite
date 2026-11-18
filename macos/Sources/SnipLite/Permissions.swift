import AppKit

/// The permissions sniplite asks for, granted by dragging sniplite into the list in System Settings.
/// The approach (a floating panel under the System Settings window holding the app to drag) follows
/// PermissionFlow by jaywcjlove (MIT, https://github.com/jaywcjlove/PermissionFlow), rewritten in
/// AppKit so the app builds with the Command Line Tools alone.
enum Permission: CaseIterable {
    case screenRecording, accessibility

    var granted: Bool {
        switch self {
        case .screenRecording: return Self.screenRecordingGranted
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    /// Only Screen Recording is needed to capture; Accessibility is for the F1–F12 shortcuts and the parts of windows.
    var required: Bool { self == .screenRecording || Prefs.shared.topRowKeys }

    var name: String {
        switch self {
        case .screenRecording: return L.t("screenRecording")
        case .accessibility:
            // macOS 27 renamed the page; its address stays the same
            let new = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            return L.t(new ? "deviceControl" : "accessibility")
        }
    }

    var purpose: String { L.t(self == .screenRecording ? "whyScreen" : "whyAX") }

    var settingsURL: URL {
        let anchor = self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        // the address of System Settings since macOS 13; the older com.apple.preference.security one
        // does not always switch pages when Settings is already open
        return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)")!
    }

    /// The system's answer. It can stay false until a restart after the permission is switched on;
    /// the guide notices that moment itself (see `liveScreenGrant`) and sniplite then restarts.
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() || liveScreenGrant }

    /// Set by the guide when Screen Recording was switched on while sniplite runs.
    static var liveScreenGrant = false

    /// How many windows of other apps show their titles. Without Screen Recording only a few
    /// system windows do; switching it on makes the titles of all windows visible at once, so a
    /// jump from the count when the guide opened means it was just allowed. (A plain "any title
    /// visible" test is wrong: some system windows always show theirs.)
    static func visibleWindowTitles() -> Int {
        let me = getpid()
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        return info.filter { w in
            (w[kCGWindowOwnerPID as String] as? Int32) != me
                && (w[kCGWindowLayer as String] as? Int) == 0
                && !((w[kCGWindowName as String] as? String) ?? "").isEmpty
        }.count
    }

    /// The TCC service of this permission, for tccutil.
    var tccService: String { self == .screenRecording ? "ScreenCapture" : "Accessibility" }

    /// Removes sniplite's own entry for this permission. After a rebuild with another signature
    /// the old entry stays in the list, switched on, yet no longer applies to this sniplite, and
    /// a new one cannot be added beside it; without it the user just drags sniplite in again.
    func resetStaleEntry() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", tccService, id]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        Log.write("tccutil reset \(tccService) \(id): \(p.terminationStatus)")
    }

    static var allRequiredGranted: Bool { allCases.allSatisfy { !$0.required || $0.granted } }
}

// MARK: - the permissions window

extension Permission {
    var symbol: String { self == .screenRecording ? "rectangle.dashed.badge.record" : "hand.point.up.left.fill" }
    var tint: NSColor { self == .screenRecording ? .systemBlue : .systemPurple }
}

/// A rounded card whose colors follow light / dark mode.
func card(_ content: NSView, inset: CGFloat = 16) -> NSBox {
    let b = NSBox()
    b.boxType = .custom
    b.cornerRadius = 12
    b.borderWidth = 1
    b.borderColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.07) }
    b.fillColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor.white.withAlphaComponent(0.05) : NSColor.white.withAlphaComponent(0.85) }
    b.contentViewMargins = NSSize(width: inset, height: inset)
    content.translatesAutoresizingMaskIntoConstraints = false
    b.contentView?.addSubview(content)
    if let cv = b.contentView {
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            content.topAnchor.constraint(equalTo: cv.topAnchor),
            content.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])
    }
    return b
}

/// A quiet capsule beside a name: "Required" on a soft fill, "Optional" as an outline only.
private final class Tag: NSView {
    private let label: NSTextField
    private let filled: Bool

    init(_ text: String, filled: Bool) {
        label = NSTextField(labelWithString: text)
        self.filled = filled
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = filled ? .secondaryLabelColor : .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            heightAnchor.constraint(equalToConstant: 17),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 8.5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if filled {
                layer.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.06)).cgColor
                layer.borderWidth = 0
            } else {
                layer.backgroundColor = NSColor.clear.cgColor
                layer.borderWidth = 1
                layer.borderColor = (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.13)).cgColor
            }
        }
    }
}

/// A small colored label with rounded ends ("Allowed").
private final class Pill: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        icon.symbolConfiguration = .init(pointSize: 10, weight: .bold)
        let st = NSStackView(views: [icon, label])
        st.spacing = 3
        st.edgeInsets = NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 8)
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        NSLayoutConstraint.activate([
            st.leadingAnchor.constraint(equalTo: leadingAnchor), st.trailingAnchor.constraint(equalTo: trailingAnchor),
            st.topAnchor.constraint(equalTo: topAnchor), st.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 18),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ text: String, _ color: NSColor, symbol: String? = nil) {
        label.stringValue = text
        label.textColor = color
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.contentTintColor = color
        icon.isHidden = symbol == nil
        layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
    }
}

/// The permissions page: what sniplite needs, why, and a button for each that opens System
/// Settings with the drag panel. Closes by itself once everything needed is allowed.
final class PermissionsWindow: NSWindowController, NSWindowDelegate {
    static var shared: PermissionsWindow?

    private struct Row { let badge: Tag; let status: Pill; let button: NSButton }
    private var rows: [Permission: Row] = [:]
    private var timer: Timer?
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let footerIcon = NSImageView()
    private let doneButton = NSButton(title: "", target: nil, action: nil)
    private let screenAtStart = Permission.screenRecording.granted
    private var finishing = false

    static func show() {
        if shared == nil { shared = PermissionsWindow() }
        NSApp.activate(ignoringOtherApps: true)
        shared?.window?.center()
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        shared?.refresh()
    }

    /// At start-up: only when something needed is missing.
    static func showIfNeeded() {
        if !Permission.allRequiredGranted { show() }
    }

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.title = "sniplite " + L.t("permissions")
        super.init(window: w)
        w.delegate = self
        build()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let bg = NSVisualEffectView()
        bg.material = .underWindowBackground
        bg.blendingMode = .behindWindow
        bg.state = .active

        // header: icon, title, one line of why
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let title = NSTextField(labelWithString: L.t("permTitle2"))
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let sub = NSTextField(wrappingLabelWithString: L.t("permSubtitle"))
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        sub.preferredMaxLayoutWidth = 420
        let header = NSStackView(views: [icon, title, sub])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 6
        header.setCustomSpacing(12, after: icon)

        // one card per permission
        var cards: [NSView] = []
        for (i, p) in Permission.allCases.enumerated() {
            let tile = NSView()
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 10
            tile.layer?.backgroundColor = p.tint.cgColor
            let sym = NSImageView(image: NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)!)
            sym.symbolConfiguration = .init(pointSize: 19, weight: .semibold)
            sym.contentTintColor = .white
            sym.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(sym)
            tile.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                tile.widthAnchor.constraint(equalToConstant: 40), tile.heightAnchor.constraint(equalToConstant: 40),
                sym.centerXAnchor.constraint(equalTo: tile.centerXAnchor), sym.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            ])

            let name = NSTextField(labelWithString: "\(i + 1). " + p.name)
            name.font = .systemFont(ofSize: 14, weight: .semibold)
            let badge = Tag(p.required ? L.t("required") : L.t("optional"), filled: p.required)
            let line = NSStackView(views: [name, badge])
            line.spacing = 7
            line.alignment = .centerY
            let why = NSTextField(wrappingLabelWithString: p.purpose)
            why.font = .systemFont(ofSize: 12)
            why.textColor = .secondaryLabelColor
            why.preferredMaxLayoutWidth = 270
            let text = NSStackView(views: [line, why])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 4

            let button = NSButton(title: L.t("openPane"), target: self, action: #selector(open(_:)))
            button.tag = i
            button.bezelStyle = .push
            button.controlSize = .large
            button.bezelColor = .controlAccentColor
            let status = Pill()

            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let row = NSStackView(views: [tile, text, spacer, status, button])
            row.spacing = 14
            row.alignment = .centerY
            text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            cards.append(card(row))
            rows[p] = Row(badge: badge, status: status, button: button)
        }

        // footer: how the drag works, and the button that closes
        footerIcon.image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: nil)
        footerIcon.contentTintColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 11.5)
        footer.textColor = .secondaryLabelColor
        footer.preferredMaxLayoutWidth = 360
        doneButton.target = self
        doneButton.action = #selector(finish)
        doneButton.bezelStyle = .push
        doneButton.controlSize = .large
        let fspacer = NSView()
        fspacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let foot = NSStackView(views: [footerIcon, footer, fspacer, doneButton])
        foot.spacing = 8
        foot.alignment = .centerY

        let stack = NSStackView(views: [header] + cards + [foot])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(26, after: header)
        stack.setCustomSpacing(22, after: cards.last!)
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 32, bottom: 26, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in cards + [foot] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true }

        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 560),
        ])
        window?.contentView = bg
    }

    func refresh() {
        let firstMissing = Permission.allCases.first { !$0.granted }
        for (p, r) in rows {
            let ok = p.granted
            r.button.keyEquivalent = p == firstMissing ? "\r" : ""
            r.status.set(L.t("granted"), .systemGreen, symbol: "checkmark")
            r.status.isHidden = !ok
            r.button.isHidden = ok
        }
        // the page stays until everything needed is allowed: no close button, no "later"
        let done = Permission.allRequiredGranted
        doneButton.title = L.t("done")
        doneButton.keyEquivalent = done ? "\r" : ""
        doneButton.bezelColor = .controlAccentColor
        doneButton.isHidden = !done
        window?.standardWindowButton(.closeButton)?.isEnabled = done
        if done {
            footerIcon.image = NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: nil)
            footerIcon.contentTintColor = .systemGreen
            footer.stringValue = screenAtStart ? L.t("permDone") : L.t("permRestart")
            if !finishing {
                finishing = true
                timer?.invalidate(); timer = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finish() }
            }
        } else {
            footerIcon.image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: nil)
            footerIcon.contentTintColor = .secondaryLabelColor
            footer.stringValue = L.t("permDrag")
        }
    }

    @objc private func open(_ b: NSButton) {
        let p = Permission.allCases[b.tag]
        PermissionGuide.start(p) { [weak self] in
            // System Settings has just closed: back to this page for the next permission
            self?.refresh()
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Done (restarting when Screen Recording is new, which ScreenCaptureKit needs) or later.
    @objc private func finish() {
        if Permission.allRequiredGranted && !screenAtStart && Permission.screenRecording.granted {
            AppDelegate.relaunch()
        } else {
            close()
        }
    }

    /// ⌘W, Esc and the close button do nothing until everything needed is allowed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if Permission.allRequiredGranted { finish(); return false }
        NSSound.beep()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        PermissionGuide.stop(closeSettings: false)
        PermissionsWindow.shared = nil
    }
}

// MARK: - the drag panel beside System Settings

/// Opens a privacy page of System Settings and keeps a small panel under its window holding
/// sniplite's icon to drag into the list. When the permission is granted, the panel and
/// System Settings close.
final class PermissionGuide {
    private static var current: PermissionGuide?

    private let permission: Permission
    private let onGranted: () -> Void
    private let panel: NSPanel
    private var timer: Timer?
    private var sawSettings = false
    private let started = Date()
    private let titlesAtStart = Permission.visibleWindowTitles()

    static func start(_ p: Permission, onGranted: @escaping () -> Void) {
        stop(closeSettings: false)
        if !p.granted { p.resetStaleEntry() }
        let g = PermissionGuide(p, onGranted: onGranted)
        current = g
        // an open System Settings does not always follow the link to another page: quit it first
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
        running.forEach { $0.terminate() }
        func openWhenClosed(_ tries: Int) {
            guard current === g else { return }
            if tries > 0 && running.contains(where: { !$0.isTerminated }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { openWhenClosed(tries - 1) }
                return
            }
            NSWorkspace.shared.open(p.settingsURL)
            g.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in g.tick() }
        }
        openWhenClosed(20)
    }

    static func stop(closeSettings: Bool) {
        guard let g = current else { return }
        current = nil
        g.timer?.invalidate()
        g.panel.orderOut(nil)
        if closeSettings {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").forEach { $0.terminate() }
        }
    }

    private init(_ p: Permission, onGranted: @escaping () -> Void) {
        permission = p
        self.onGranted = onGranted
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: PermissionGuide.size.width, height: PermissionGuide.size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = DragPanelView(permission: p)
    }

    private func tick() {
        if permission == .screenRecording && !Permission.liveScreenGrant
            && Permission.visibleWindowTitles() >= titlesAtStart + 2 {
            Permission.liveScreenGrant = true
        }
        if permission.granted {
            Log.write("granted \(permission)")
            PermissionGuide.stop(closeSettings: true)
            onGranted()
            return
        }
        guard let f = settingsWindowFrame() else {
            // System Settings closed (or not up yet): give it a few seconds to open
            if sawSettings || Date().timeIntervalSince(started) > 8 { PermissionGuide.stop(closeSettings: false) }
            return
        }
        sawSettings = true
        place(below: f)
    }

    static let size = CGSize(width: 380, height: 112)

    /// Under the content side of the System Settings window; with no room there, beside it (right,
    /// then left) level with the bottom of its list; only then over its bottom edge.
    private func place(below f: CGRect) {
        let sidebar: CGFloat = min(220, f.width * 0.33)
        let size = PermissionGuide.size
        let vis = (NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main)?.visibleFrame ?? f
        let gap: CGFloat = 10
        let candidates = [
            CGRect(x: f.minX + sidebar + (f.width - sidebar - size.width) / 2, y: f.minY - size.height - gap,
                   width: size.width, height: size.height),
            CGRect(x: f.maxX + gap, y: f.minY + 40, width: size.width, height: size.height),
            CGRect(x: f.minX - gap - size.width, y: f.minY + 40, width: size.width, height: size.height),
        ]
        let i = candidates.firstIndex { vis.contains($0) }
        var r = i.map { candidates[$0] }
            ?? CGRect(x: f.minX + sidebar + (f.width - sidebar - size.width) / 2, y: f.minY + 18,
                      width: size.width, height: size.height)
        // the arrow points at the list: up from below (or over the bottom), left from the right side
        (panel.contentView as? DragPanelView)?.direction = i == 1 ? .left : (i == 2 ? .right : .up)
        r.origin.x = min(max(vis.minX + 8, r.minX), vis.maxX - r.width - 8)
        r.origin.y = min(max(vis.minY + 4, r.minY), vis.maxY - r.height - 4)
        if panel.frame != r { panel.setFrame(r, display: true) }
        if !panel.isVisible {
            panel.invalidateShadow()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        }
    }

    /// The main window of System Settings in Cocoa screen coordinates.
    private func settingsWindowFrame() -> CGRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let wins = info.compactMap { w -> CGRect? in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width > 200, r.height > 200 else { return nil }
            return CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
        }
        return wins.max { $0.width * $0.height < $1.width * $1.height }
    }
}

/// The drag panel: a line of instructions and, under it, sniplite as a row like the ones in the
/// list of System Settings (icon, name, drag handle). The whole row is dragged.
private final class DragPanelView: NSVisualEffectView {
    enum Direction { case up, left, right }
    private let arrow = NSImageView()
    private let title = NSTextField(labelWithString: "")
    var direction: Direction = .up { didSet { if direction != oldValue { applyDirection() } } }

    private func applyDirection() {
        let (symbol, key, dx, dy): (String, String, CGFloat, CGFloat) = {
            switch direction {
            case .up: return ("arrow.up", "dragTitle", 0, 2.5)
            case .left: return ("arrow.left", "dragTitleLeft", -2.5, 0)
            case .right: return ("arrow.right", "dragTitleRight", 2.5, 0)
            }
        }()
        arrow.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        title.stringValue = L.t(key)
        arrow.layer?.removeAnimation(forKey: "bob")
        let bob = CABasicAnimation(keyPath: dx != 0 ? "transform.translation.x" : "transform.translation.y")
        bob.fromValue = 0; bob.toValue = dx != 0 ? dx : dy
        bob.duration = 0.7; bob.autoreverses = true; bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arrow.layer?.add(bob, forKey: "bob")
    }

    init(permission p: Permission) {
        let size = PermissionGuide.size
        super.init(frame: NSRect(origin: .zero, size: size))
        material = .popover
        blendingMode = .behindWindow
        state = .active
        // a rounded mask: behind-window blur ignores the layer's corner radius, and the window
        // shadow follows the mask, so both corners and shadow come out round
        let r: CGFloat = 16
        let mask = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        maskImage = mask

        // instructions, with an arrow that nudges upward
        arrow.symbolConfiguration = .init(pointSize: 11, weight: .bold)
        arrow.contentTintColor = .controlAccentColor
        arrow.wantsLayer = true
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let head = NSStackView(views: [arrow, title])
        head.spacing = 5

        let row = AppDragRow()
        let stack = NSStackView(views: [head, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.heightAnchor.constraint(equalToConstant: 46),
            head.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor, constant: -18),
        ])

        DispatchQueue.main.async { [weak self] in self?.applyDirection() }

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L.t("close.pin"))!,
                             target: PermissionGuideCloser.shared, action: #selector(PermissionGuideCloser.close))
        close.isBordered = false
        close.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        close.contentTintColor = .tertiaryLabelColor
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// sniplite as a list row (icon, name, handle), dragged as the .app file into System Settings.
final class AppDragRow: NSView, NSDraggingSource {
    private let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    private var hover = false { didSet { needsDisplay = true } }
    private var dragging = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = Bundle.main.bundlePath
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand) }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        (isDark ? NSColor.white.withAlphaComponent(hover ? 0.12 : 0.08)
                : NSColor.white.withAlphaComponent(hover ? 1 : 0.92)).setFill()
        path.fill()
        (hover ? NSColor.controlAccentColor.withAlphaComponent(0.7)
               : (isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.1))).setStroke()
        path.lineWidth = 1
        path.stroke()

        icon.draw(in: NSRect(x: 10, y: (bounds.height - 28) / 2, width: 28, height: 28))
        let name = NSAttributedString(string: "sniplite", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
        let nh = name.size().height
        name.draw(at: NSPoint(x: 46, y: (bounds.height - nh) / 2))

        if let grip = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
            let tinted = NSImage(size: grip.size, flipped: false) { rect in
                grip.draw(in: rect); NSColor.tertiaryLabelColor.set(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: bounds.width - grip.size.width - 12, y: (bounds.height - grip.size.height) / 2,
                                   width: grip.size.width, height: grip.size.height))
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard !dragging else { return }
        // the drag image is the row itself
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        dragging = true
        beginDraggingSession(with: [item], event: e, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        window?.invalidateCursorRects(for: self)
    }
}

private final class PermissionGuideCloser: NSObject {
    static let shared = PermissionGuideCloser()
    @objc func close() { PermissionGuide.stop(closeSettings: false) }
}
