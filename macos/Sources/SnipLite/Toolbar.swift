import AppKit

/// A square toolbar button showing an SF Symbol (or a color / size swatch).
final class ToolButton: NSView {
    enum Look { case symbol(String), color(NSColor), size(CGFloat), glyph(String, CGFloat), number(CGFloat), mosaicSwatch }
    var look: Look { didSet { needsDisplay = true } }
    /// Shown faded: it still works, but does not apply as things are (colors for a mosaic).
    var dimmed = false { didSet { needsDisplay = true } }
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
        if dimmed { NSGraphicsContext.current?.cgContext.setAlpha(0.35) }
        let r = bounds.insetBy(dx: 2, dy: 2)
        if selected || (hover && enabled) {
            (selected ? Palette.accent.withAlphaComponent(0.18) : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }
        switch look {
        case .symbol:
            guard let img = image else { return }
            let tint: NSColor = !enabled ? .tertiaryLabelColor : (selected ? Palette.accent : NSColor.labelColor)
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
        case .mosaicSwatch:
            // like a color swatch, filled with mosaic squares
            let d = r.insetBy(dx: 6, dy: 6)
            let clip = NSBezierPath(roundedRect: d, xRadius: 3, yRadius: 3)
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            let n = 4, cw = d.width / CGFloat(n), ch = d.height / CGFloat(n)
            let tones: [CGFloat] = [0.35, 0.6, 0.8, 0.5, 0.7, 0.45, 0.9, 0.55]
            for i in 0..<n { for j in 0..<n {
                NSColor(white: tones[(i * 3 + j * 5) % tones.count], alpha: 1).setFill()
                NSRect(x: d.minX + CGFloat(i) * cw, y: d.minY + CGFloat(j) * ch, width: cw + 0.5, height: ch + 0.5).fill()
            } }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.25).setStroke(); clip.lineWidth = 1; clip.stroke()
            if selected {
                Palette.accent.setStroke()
                let o = NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
                o.lineWidth = 2; o.stroke()
            }
        case .glyph(let g, let size):
            let str = NSAttributedString(string: g, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: selected ? Palette.accent : NSColor.secondaryLabelColor])
            let sz = str.size()
            str.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
        case .number(let d):
            (selected ? Palette.accent : NSColor.secondaryLabelColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
            let str = NSAttributedString(string: "1", attributes: [
                .font: NSFont.systemFont(ofSize: d * 0.62, weight: .bold), .foregroundColor: NSColor.white])
            let sz = str.size()
            str.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
        case .size(let w):
            let d = min(w * 2 + 2, r.width - 6)
            (selected ? Palette.accent : NSColor.secondaryLabelColor).setFill()
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
    var onWidth: ((CGFloat) -> Void)?
    var onMosaicMode: ((MosaicMode) -> Void)?
    var onMosaicSolid: ((Bool) -> Void)?
    /// The toolbar changed size (the second row's buttons depend on the tool and mosaic mode).
    var onResize: (() -> Void)?

    private var toolButtons: [Tool: ToolButton] = [:]
    private var commandButtons: [Command: ToolButton] = [:]
    private var colorButtons: [ToolButton] = []
    private let sizeSlider = SizeSlider(frame: NSRect(x: 0, y: 0, width: 112, height: 28))
    private let sizeValue = NSTextField(labelWithString: "")
    private var modeButtons: [MosaicMode: ToolButton] = [:]
    private var paletteSeps: [NSView] = []
    private var colorIndex = Prefs.shared.colorIndex
    private(set) var mosaicMode = Prefs.shared.mosaicMode
    private(set) var mosaicSolid = Prefs.shared.mosaicSolid
    private let mosaicSwatch = ToolButton(.mosaicSwatch, tip: L.t("mosaicSwatch"), size: 32)
    private let mainRow = NSView()
    private var rows: [NSView] = []
    private var seps: [NSView] = []

    /// Light or dark like the system: layer colors do not follow it by themselves.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for r in rows {
            r.layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 0.97) : NSColor(white: 0.98, alpha: 0.98)).cgColor
            r.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.12)).cgColor
        }
        for v in seps { v.layer?.backgroundColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.16).cgColor }
        for v in rows { v.subviews.forEach { $0.needsDisplay = true } }
    }
    private let paletteRow = NSView()
    private(set) var tool: Tool?
    private let unit: CGFloat = 32

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for row in [mainRow, paletteRow] {
            row.wantsLayer = true
            rows.append(row)
            row.layer?.cornerRadius = 8
            row.layer?.borderWidth = 0.5
            row.shadow = NSShadow()
            row.layer?.shadowOpacity = 0.25; row.layer?.shadowRadius = 6; row.layer?.shadowOffset = CGSize(width: 0, height: -2)
            addSubview(row)
        }
        var x: CGFloat = 4
        func place(_ b: ToolButton, in row: NSView) { b.frame.origin = CGPoint(x: x, y: 2); row.addSubview(b); x += b.frame.width }
        func gap() {
            let s = NSView(frame: NSRect(x: x + 4, y: 9, width: 1, height: unit - 14))
            s.wantsLayer = true; seps.append(s)
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
        sizeSlider.onChange = { [weak self] in self?.slid() }
        sizeSlider.toolTip = L.t("sizeTip")
        sizeValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeValue.textColor = .secondaryLabelColor
        sizeValue.alignment = .left
        sizeValue.frame = NSRect(x: 0, y: 0, width: 38, height: 16)
        paletteRow.addSubview(sizeSlider)
        paletteRow.addSubview(sizeValue)
        let modes: [(MosaicMode, String, String)] = [
            (.rect, "checkerboard.rectangle", L.t("mosaicRect")),
            (.brush, "scribble.variable", L.t("mosaicBrush")),
        ]
        for (m, sym, tip) in modes {
            let b = ToolButton(.symbol(sym), tip: tip, size: unit)
            b.onClick = { [weak self] in self?.setMosaicMode(m) }
            modeButtons[m] = b; paletteRow.addSubview(b)
        }
        for _ in 0..<2 {
            let sep = NSView(frame: NSRect(x: 0, y: 9, width: 1, height: unit - 14))
            sep.wantsLayer = true; seps.append(sep)
            paletteSeps.append(sep); paletteRow.addSubview(sep)
        }
        for (i, c) in Palette.colors.enumerated() {
            let b = ToolButton(.color(c), tip: nil, size: unit)
            b.onClick = { [weak self] in
                guard let self else { return }
                self.colorIndex = i
                self.onColor?(i)
                // with the mosaic tool a color means: cover with that color
                // with the hide tool a color means: cover with that color (box or brush)
                if self.tool == .mosaic { self.setMosaicSolid(true) } else { self.refreshPalette() }
            }
            colorButtons.append(b); paletteRow.addSubview(b)
        }
        mosaicSwatch.onClick = { [weak self] in self?.setMosaicSolid(false) }
        paletteRow.addSubview(mosaicSwatch)
        paletteRow.frame.origin = CGPoint(x: 0, y: unit + 10)
        paletteRow.isHidden = true
        layoutPalette()
        setFrameSize(NSSize(width: mainRow.frame.width, height: mainRow.frame.height))
        setWidth(Prefs.shared.width(for: .rect))
        applyAppearance()
    }

    /// Places the second row's buttons for the current tool.
    private func layoutPalette() {
        var x: CGFloat = 4
        func put(_ v: NSView) { v.frame.origin = CGPoint(x: x, y: 2); v.isHidden = false; x += v.frame.width }
        func sep(_ i: Int) { paletteSeps[i].frame.origin = CGPoint(x: x + 4, y: 9); paletteSeps[i].isHidden = false; x += 9 }
        // sizes: what they look like follows the tool; none for a mosaic box or a color box
        let sizesApply = tool != .mosaic || mosaicMode == .brush
        if sizesApply {
            // the size: a slider up to this tool's limit, and its value
            sizeSlider.maxValue = Annotation.maxWidth(tool ?? .rect)
            sizeSlider.frame.origin = CGPoint(x: x, y: (unit + 4 - sizeSlider.frame.height) / 2)
            sizeSlider.isHidden = false
            x += sizeSlider.frame.width - 4          // the knob's margin already leaves room
            sizeValue.frame.origin = CGPoint(x: x, y: (unit + 4 - sizeValue.frame.height) / 2)
            sizeValue.isHidden = false
            x += sizeValue.frame.width + 2
            sep(0)
        } else {
            sizeSlider.isHidden = true
            sizeValue.isHidden = true
            paletteSeps[0].isHidden = true
        }
        if tool == .mosaic {
            for m in [MosaicMode.rect, .brush] { put(modeButtons[m]!) }
            sep(1)
            put(mosaicSwatch)                      // mosaic, then the colors: what to cover with
        } else {
            modeButtons.values.forEach { $0.isHidden = true }
            mosaicSwatch.isHidden = true
            paletteSeps[1].isHidden = true
        }
        colorButtons.forEach(put)
        paletteRow.frame.size = NSSize(width: x + 4, height: unit + 4)
        refreshPalette()
    }

    /// Selection marks: the chosen mosaic mode; a color only where it is used (not for mosaic squares).
    private func refreshPalette() {
        for (m, b) in modeButtons { b.selected = m == mosaicMode }
        let colorUsed = tool != .mosaic || mosaicSolid
        for (k, b) in colorButtons.enumerated() { b.selected = colorUsed && k == colorIndex }
        mosaicSwatch.selected = !colorUsed
    }

    func setMosaicMode(_ m: MosaicMode, notify: Bool = true) {
        mosaicMode = m
        Prefs.shared.mosaicMode = m
        layoutPalette()
        fitSize()
        if notify { onMosaicMode?(m) }
        onResize?()
    }

    func setMosaicSolid(_ on: Bool, notify: Bool = true) {
        mosaicSolid = on
        Prefs.shared.mosaicSolid = on
        refreshPalette()
        if notify { onMosaicSolid?(on) }
    }

    private func fitSize() {
        setFrameSize(NSSize(width: max(mainRow.frame.width, paletteRow.frame.width),
                            height: tool == nil ? mainRow.frame.height : paletteRow.frame.maxY))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    var fullHeight: CGFloat { paletteRow.frame.maxY }

    func select(_ t: Tool?) {
        tool = t
        for (k, b) in toolButtons { b.selected = k == t }
        paletteRow.isHidden = t == nil
        layoutPalette()
        fitSize()
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
        sizeSlider.value = w
        showValue(w)
    }

    /// The value beside the slider, in what the tool shows: points of text, the width of a
    /// number's circle, the width of a line or a brush.
    private func showValue(_ w: CGFloat) {
        switch tool {
        case .text: sizeValue.stringValue = "\(Int(Annotation.fontSize(for: w).rounded())) pt"
        case .number: sizeValue.stringValue = "\(Int((Annotation.numberRadius(w) * 2).rounded()))"
        case .marker: sizeValue.stringValue = "\(Int(w * 4))"
        case .mosaic: sizeValue.stringValue = "\(Int(Annotation.brushWidth(w)))"
        default: sizeValue.stringValue = "\(Int(w))"
        }
    }

    private func slid() {
        let w = sizeSlider.value.rounded()
        showValue(w)
        onWidth?(w)
    }
    func setEnabled(_ c: Command, _ on: Bool) { commandButtons[c]?.enabled = on }
}

/// The size slider: a wedge track, thin on the left and thick on the right (small to big), and a
/// knob that grows with the value, so the slider itself shows the size being set.
final class SizeSlider: NSView {
    var minValue: CGFloat = 1
    var maxValue: CGFloat = 40 { didSet { needsDisplay = true } }
    var value: CGFloat = 3 { didSet { needsDisplay = true } }
    var onChange: (() -> Void)?

    private let knobMin: CGFloat = 8, knobMax: CGFloat = 20
    private var inset: CGFloat { knobMax / 2 + 1 }
    private var fraction: CGFloat { maxValue > minValue ? (min(max(value, minValue), maxValue) - minValue) / (maxValue - minValue) : 0 }
    private var knobX: CGFloat { inset + (bounds.width - inset * 2) * fraction }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY, x0 = inset, x1 = bounds.width - inset
        let thin: CGFloat = 1.5, thick: CGFloat = 5
        // the wedge: half height grows from `thin` to `thick` from left to right
        // rounded at both ends: a small cap on the thin end, a big one on the thick end
        func wedge(to x: CGFloat) -> NSBezierPath {
            let t = (x - x0) / max(1, x1 - x0)
            let h = thin + (thick - thin) * t
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x0, y: midY - thin))
            p.line(to: NSPoint(x: x, y: midY - h))
            p.appendArc(withCenter: NSPoint(x: x, y: midY), radius: h, startAngle: 270, endAngle: 90, clockwise: false)
            p.line(to: NSPoint(x: x0, y: midY + thin))
            p.appendArc(withCenter: NSPoint(x: x0, y: midY), radius: thin, startAngle: 90, endAngle: 270, clockwise: false)
            p.close()
            return p
        }
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        wedge(to: x1).fill()
        Palette.accent.setFill()
        wedge(to: knobX).fill()

        // the knob: as big as the value is
        let d = knobMin + (knobMax - knobMin) * fraction
        let knob = NSRect(x: knobX - d / 2, y: midY - d / 2, width: d, height: d)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }

    private func set(fromX x: CGFloat) {
        let f = min(max((x - inset) / max(1, bounds.width - inset * 2), 0), 1)
        let v = (minValue + (maxValue - minValue) * f).rounded()
        guard v != value else { return }
        value = v
        onChange?()
    }

    override func mouseDown(with e: NSEvent) { set(fromX: convert(e.locationInWindow, from: nil).x) }
    override func mouseDragged(with e: NSEvent) { set(fromX: convert(e.locationInWindow, from: nil).x) }
}
