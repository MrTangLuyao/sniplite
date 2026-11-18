import AppKit

/// A square toolbar button showing an SF Symbol (or a color / size swatch).
final class ToolButton: NSView {
    enum Look { case symbol(String), color(NSColor), size(CGFloat) }
    let look: Look
    var selected = false { didSet { needsDisplay = true } }
    var enabled = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hover = false { didSet { needsDisplay = true } }
    private lazy var image: NSImage? = {
        guard case .symbol(let name) = look else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?.withSymbolConfiguration(cfg)
    }()

    init(_ look: Look, tip: String?, size: CGFloat = 32) {
        self.look = look
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        toolTip = tip
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if enabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        if selected || (hover && enabled) {
            (selected ? Palette.accent.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.07)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }
        switch look {
        case .symbol:
            guard let img = image else { return }
            let tint: NSColor = !enabled ? .tertiaryLabelColor : (selected ? Palette.accent : NSColor(white: 0.15, alpha: 1))
            let tinted = NSImage(size: img.size, flipped: false) { rect in
                img.draw(in: rect); tint.set(); rect.fill(using: .sourceAtop); return true
            }
            let s = img.size
            tinted.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
        case .color(let c):
            let d = r.insetBy(dx: 6, dy: 6)
            c.setFill()
            let p = NSBezierPath(roundedRect: d, xRadius: 3, yRadius: 3)
            p.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke(); p.lineWidth = 1; p.stroke()
            if selected {
                Palette.accent.setStroke()
                let o = NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
                o.lineWidth = 2; o.stroke()
            }
        case .size(let w):
            let d = min(w * 2 + 2, r.width - 6)
            (selected ? Palette.accent : NSColor(white: 0.3, alpha: 1)).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
        }
    }
}

/// The toolbar beside the selection: the tools, then the commands; a second row of sizes and colors.
final class Toolbar: NSView {
    enum Command { case undo, redo, ocr, ocrCopy, pin, save, close, ok }

    var onTool: ((Tool?) -> Void)?
    var onCommand: ((Command) -> Void)?
    var onColor: ((Int) -> Void)?
    var onSize: ((Int) -> Void)?
    var onMosaicMode: ((MosaicMode) -> Void)?

    private var toolButtons: [Tool: ToolButton] = [:]
    private var commandButtons: [Command: ToolButton] = [:]
    private var colorButtons: [ToolButton] = []
    private var sizeButtons: [ToolButton] = []
    private var modeButtons: [MosaicMode: ToolButton] = [:]
    private var paletteSeps: [NSView] = []
    private var colorIndex = Prefs.shared.colorIndex
    private(set) var mosaicMode = Prefs.shared.mosaicMode
    private let mainRow = NSView()
    private let paletteRow = NSView()
    private(set) var tool: Tool?
    private let unit: CGFloat = 32

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for row in [mainRow, paletteRow] {
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor(white: 0.98, alpha: 0.98).cgColor
            row.layer?.cornerRadius = 8
            row.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
            row.layer?.borderWidth = 0.5
            row.shadow = NSShadow()
            row.layer?.shadowOpacity = 0.25; row.layer?.shadowRadius = 6; row.layer?.shadowOffset = CGSize(width: 0, height: -2)
            addSubview(row)
        }
        var x: CGFloat = 4
        func place(_ b: ToolButton, in row: NSView) { b.frame.origin = CGPoint(x: x, y: 2); row.addSubview(b); x += b.frame.width }
        func gap() {
            let s = NSView(frame: NSRect(x: x + 4, y: 9, width: 1, height: unit - 14))
            s.wantsLayer = true; s.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
            mainRow.addSubview(s); x += 9
        }
        for t in Tool.allCases {
            let b = ToolButton(.symbol(t.symbol), tip: t.tip, size: unit)
            b.onClick = { [weak self] in self?.select(self?.tool == t ? nil : t) }
            toolButtons[t] = b; place(b, in: mainRow)
        }
        gap()
        let cmds: [(Command, String, String)] = [
            (.undo, "arrow.uturn.backward", L.t("undo")), (.redo, "arrow.uturn.forward", L.t("redo")),
        ]
        let cmds2: [(Command, String, String)] = [
            (.ocr, "text.viewfinder", L.t("ocr")), (.ocrCopy, "doc.on.clipboard", L.t("ocrCopy")),
        ]
        let cmds3: [(Command, String, String)] = [
            (.pin, "pin", L.t("pin")), (.save, "square.and.arrow.down", L.t("save")),
            (.close, "xmark", L.t("close")), (.ok, "checkmark", L.t("ok")),
        ]
        for (i, group) in (Prefs.shared.ocrEnabled ? [cmds, cmds2, cmds3] : [cmds, cmds3]).enumerated() {
            if i > 0 { gap() }
            for (c, sym, tip) in group {
                let b = ToolButton(.symbol(sym), tip: tip, size: unit)
                b.onClick = { [weak self] in self?.onCommand?(c) }
                commandButtons[c] = b; place(b, in: mainRow)
            }
        }
        mainRow.frame = NSRect(x: 0, y: 0, width: x + 4, height: unit + 4)

        // second row: sizes | mosaic modes (mosaic tool only) | colors; laid out by layoutPalette()
        for (i, w) in Palette.widths.enumerated() {
            let b = ToolButton(.size(w), tip: nil, size: unit)
            b.onClick = { [weak self] in self?.onSize?(i) }
            sizeButtons.append(b); paletteRow.addSubview(b)
        }
        let modes: [(MosaicMode, String, String)] = [
            (.rect, "checkerboard.rectangle", L.t("mosaicRect")),
            (.brush, "scribble.variable", L.t("mosaicBrush")),
            (.fill, "rectangle.fill", L.t("mosaicFill")),
        ]
        for (m, sym, tip) in modes {
            let b = ToolButton(.symbol(sym), tip: tip, size: unit)
            b.onClick = { [weak self] in self?.setMosaicMode(m) }
            modeButtons[m] = b; paletteRow.addSubview(b)
        }
        for _ in 0..<2 {
            let sep = NSView(frame: NSRect(x: 0, y: 9, width: 1, height: unit - 14))
            sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
            paletteSeps.append(sep); paletteRow.addSubview(sep)
        }
        for (i, c) in Palette.colors.enumerated() {
            let b = ToolButton(.color(c), tip: nil, size: unit)
            b.onClick = { [weak self] in
                guard let self else { return }
                self.colorIndex = i
                self.onColor?(i)
                // with the mosaic tool a color means: cover with that color
                if self.tool == .mosaic && self.mosaicMode != .fill { self.setMosaicMode(.fill) } else { self.refreshPalette() }
            }
            colorButtons.append(b); paletteRow.addSubview(b)
        }
        paletteRow.frame.origin = CGPoint(x: 0, y: unit + 10)
        paletteRow.isHidden = true
        layoutPalette()
        setFrameSize(NSSize(width: mainRow.frame.width, height: mainRow.frame.height))
        setWidth(Prefs.shared.strokeWidth)
    }

    /// Places the second row's buttons for the current tool.
    private func layoutPalette() {
        var x: CGFloat = 4
        func put(_ v: NSView) { v.frame.origin = CGPoint(x: x, y: 2); v.isHidden = false; x += v.frame.width }
        func sep(_ i: Int) { paletteSeps[i].frame.origin = CGPoint(x: x + 4, y: 9); paletteSeps[i].isHidden = false; x += 9 }
        sizeButtons.forEach(put)
        sep(0)
        if tool == .mosaic {
            for m in [MosaicMode.rect, .brush, .fill] { put(modeButtons[m]!) }
            sep(1)
        } else {
            modeButtons.values.forEach { $0.isHidden = true }
            paletteSeps[1].isHidden = true
        }
        colorButtons.forEach(put)
        paletteRow.frame.size = NSSize(width: x + 4, height: unit + 4)
        refreshPalette()
    }

    /// Selection marks: the chosen mosaic mode; a color only where it is used (not for mosaic squares).
    private func refreshPalette() {
        for (m, b) in modeButtons { b.selected = m == mosaicMode }
        let colorUsed = tool != .mosaic || mosaicMode == .fill
        for (k, b) in colorButtons.enumerated() { b.selected = colorUsed && k == colorIndex }
    }

    func setMosaicMode(_ m: MosaicMode) {
        mosaicMode = m
        Prefs.shared.mosaicMode = m
        refreshPalette()
        onMosaicMode?(m)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    var fullHeight: CGFloat { paletteRow.frame.maxY }

    func select(_ t: Tool?) {
        tool = t
        for (k, b) in toolButtons { b.selected = k == t }
        paletteRow.isHidden = t == nil
        layoutPalette()
        setFrameSize(NSSize(width: max(mainRow.frame.width, paletteRow.frame.width),
                            height: t == nil ? mainRow.frame.height : paletteRow.frame.maxY))
        onTool?(t)
    }

    /// When the toolbar sits above the selection the palette goes on top of the buttons.
    func setPaletteAbove(_ above: Bool) {
        if above {
            paletteRow.frame.origin.y = 0
            mainRow.frame.origin.y = paletteRow.isHidden ? 0 : unit + 10
        } else {
            mainRow.frame.origin.y = 0
            paletteRow.frame.origin.y = unit + 10
        }
    }

    func setColor(_ i: Int) { colorIndex = i; refreshPalette() }
    /// Marks the size button matching the width, if one does (the wheel sets widths in between).
    func setWidth(_ w: CGFloat) {
        for (k, b) in sizeButtons.enumerated() { b.selected = abs(Palette.widths[k] - w) < 0.5 }
    }
    func setEnabled(_ c: Command, _ on: Bool) { commandButtons[c]?.enabled = on }
}
