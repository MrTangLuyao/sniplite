import AppKit

/// An image pinned above the other windows. Drag to move, wheel to zoom (⌥ + wheel: opacity),
/// double-click or Esc to close, right-click for more.
final class PinWindow: NSPanel {
    private static var all: [PinWindow] = []
    private static var hidden = false

    let image: CGImage
    let baseSize: CGSize
    private var zoom: CGFloat = 1

    static func show(_ img: CGImage, frame: CGRect) {
        let w = PinWindow(image: img, frame: frame)
        all.append(w)
        if hidden { toggleAll() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// F3: the image (or the text) on the clipboard, centered on the mouse.
    static func pinClipboard() {
        let pb = NSPasteboard.general
        var img: CGImage?
        var size = CGSize.zero
        if let ni = NSImage(pasteboard: pb), let cg = ni.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            img = cg
            size = ni.size
            if let rep = ni.representations.first, rep.pixelsWide > 0, size.width > 0,
               CGFloat(rep.pixelsWide) == size.width, let scr = NSScreen.main {
                // a bitmap without a point size: show it at its pixel size on this screen
                size = CGSize(width: CGFloat(rep.pixelsWide) / scr.backingScaleFactor, height: CGFloat(rep.pixelsHigh) / scr.backingScaleFactor)
            }
        } else if let s = pb.string(forType: .string), !s.isEmpty {
            (img, size) = renderText(s)
        }
        guard let img, size.width > 0 else { NSSound.beep(); return }
        let m = NSEvent.mouseLocation
        var r = CGRect(x: m.x - size.width / 2, y: m.y - size.height / 2, width: size.width, height: size.height)
        if let vis = (NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            r.origin.x = min(max(vis.minX, r.minX), vis.maxX - r.width)
            r.origin.y = min(max(vis.minY, r.minY), vis.maxY - r.height)
        }
        show(img, frame: r)
    }

    private static func renderText(_ s: String) -> (CGImage?, CGSize) {
        let text = String(s.prefix(20000))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
        let str = NSAttributedString(string: text, attributes: attrs)
        let pad: CGFloat = 10
        let bound = str.boundingRect(with: CGSize(width: 600, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = CGSize(width: ceil(bound.width) + pad * 2, height: min(ceil(bound.height), 4000) + pad * 2)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return (nil, .zero) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        str.draw(with: NSRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2),
                 options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return (rep.cgImage, size)
    }

    static func toggleAll() {
        hidden.toggle()
        for w in all { hidden ? w.orderOut(nil) : w.orderFrontRegardless() }
    }

    static func closeAll() { for w in all { w.close() } }

    static func applyLevelToAll() { for w in all { w.level = Prefs.shared.pinOnTop ? .floating : .normal } }

    init(image: CGImage, frame: CGRect) {
        self.image = image
        self.baseSize = frame.size
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = Prefs.shared.pinOnTop ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isFloatingPanel = Prefs.shared.pinOnTop
        let v = PinView(frame: NSRect(origin: .zero, size: frame.size))
        v.autoresizingMask = [.width, .height]
        v.pin = self
        contentView = v
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        PinWindow.all.removeAll { $0 === self }
        super.close()
    }

    func zoom(by f: CGFloat, around p: CGPoint) {
        let nz = min(max(zoom * f, 0.1), 10)
        guard nz != zoom else { return }
        let old = frame
        let size = CGSize(width: baseSize.width * nz, height: baseSize.height * nz)
        // keep the point under the mouse where it is
        let rx = (p.x - old.minX) / old.width, ry = (p.y - old.minY) / old.height
        let nf = CGRect(x: p.x - rx * size.width, y: p.y - ry * size.height, width: size.width, height: size.height)
        zoom = nz
        setFrame(nf, display: true)
    }

    func copyImage() { Clipboard.copy(image, size: baseSize); Toast.show(L.t("copied")) }
    func saveImage() { Saver.save(image, size: baseSize) }
    func readText() { let f = frame; OCR.recognize(image) { OCRPanel.show($0, near: f) } }
    @objc func toggleTop() { Prefs.shared.pinOnTop.toggle(); PinWindow.applyLevelToAll() }
}

final class PinView: NSView {
    weak var pin: PinWindow?
    private var dragStart: CGPoint?
    private var frameStart: CGPoint = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let pin, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = bounds.width > pin.baseSize.width * 1.5 ? .none : .high
        ctx.draw(pin.image, in: bounds)
        ctx.setStrokeColor(Palette.accent.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { pin?.close(); return }
        dragStart = NSEvent.mouseLocation
        frameStart = window?.frame.origin ?? .zero
        window?.makeKey()
    }
    override func mouseDragged(with e: NSEvent) {
        guard let s = dragStart else { return }
        let m = NSEvent.mouseLocation
        window?.setFrameOrigin(CGPoint(x: frameStart.x + m.x - s.x, y: frameStart.y + m.y - s.y))
    }
    override func mouseUp(with e: NSEvent) { dragStart = nil }

    override func scrollWheel(with e: NSEvent) {
        guard let pin else { return }
        let dy = e.scrollingDeltaY
        guard abs(dy) > 0.1 else { return }
        if e.modifierFlags.contains(.option) {
            pin.alphaValue = min(1, max(0.15, pin.alphaValue + (dy > 0 ? 0.05 : -0.05)))
            return
        }
        let step: CGFloat = e.hasPreciseScrollingDeltas ? 1 + min(abs(dy), 20) / 100 : 1.1
        pin.zoom(by: dy > 0 ? step : 1 / step, around: NSEvent.mouseLocation)
    }

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        switch (e.keyCode, e.charactersIgnoringModifiers?.lowercased() ?? "") {
        case (0x35, _): pin?.close()
        case (_, "c") where cmd: pin?.copyImage()
        case (_, "s") where cmd: pin?.saveImage()
        case (_, "w") where cmd: pin?.close()
        case (_, "o") where cmd && Prefs.shared.ocrEnabled: pin?.readText()
        default: super.keyDown(with: e)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        func add(_ t: String, _ key: String = "", _ f: @escaping () -> Void) {
            let i = ClosureMenuItem(title: t, key: key, action: f)
            m.addItem(i)
        }
        add(L.t("copy"), "c") { [weak self] in self?.pin?.copyImage() }
        add(L.t("save").replacingOccurrences(of: " (⌘S)", with: ""), "s") { [weak self] in self?.pin?.saveImage() }
        if Prefs.shared.ocrEnabled { add(L.t("readText"), "o") { [weak self] in self?.pin?.readText() } }
        m.addItem(.separator())
        let top = ClosureMenuItem(title: L.t("onTop"), key: "") { [weak self] in self?.pin?.toggleTop() }
        top.state = Prefs.shared.pinOnTop ? .on : .off
        m.addItem(top)
        m.addItem(.separator())
        add(L.t("close.pin"), "w") { [weak self] in self?.pin?.close() }
        add(L.t("closeAll")) { PinWindow.closeAll() }
        return m
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, key: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
