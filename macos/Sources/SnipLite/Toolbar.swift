import AppKit

/// A square toolbar button showing an SF Symbol (or a color / size swatch).
final class ToolButton: NSView {
    enum Look { case symbol(String), color(NSColor), size(CGFloat), glyph(String, CGFloat), number(CGFloat), mosaicSwatch }
    var look: Look { didSet { needsDisplay = true } }
    /// Shown faded: it still works, but does not apply as things are (colors for a mosaic).
    var dimmed = false { didSet { needsDisplay = true } }
    /// The main action (✓): drawn in the accent color.
    var prominent = false { didSet { needsDisplay = true } }
    /// The mosaic tool's icon, drawn like an SF Symbol of the same size and weight (15 pt
    /// regular: an 18 x 17 canvas, 1.25 pt lines): a rounded square holding a checkerboard.
    static let mosaicIconName = "sniplite.mosaic"

    /// The pin, tilted 45° (head up right, point down left): upright it stood taller than the
    /// other icons.
    static let tiltedPin: NSImage? = {
        guard let pin = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) else { return nil }
        let w = pin.size.width, h = pin.size.height
        let side = ceil((w + h) / sqrt(2))
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let t = NSAffineTransform()
            t.translateX(by: side / 2, yBy: side / 2)
            t.rotate(byDegrees: -45)
            t.concat()
            pin.draw(in: NSRect(x: -w / 2, y: -h / 2, width: w, height: h))
            return true
        }
        img.isTemplate = true
        return img
    }()

    /// SF Symbols at one point size differ in how big they look (a wide rectangle, a small "A",
    /// a full circle). Each gets the point size that makes its drawn part about as big as the
    /// others' (the square root of its area near 15.5 pt), kept within 13-17 pt so the line
    /// weights stay alike.
    static func pointSize(for name: String) -> CGFloat {
        if let p = pointSizes[name] { return p }
        var p: CGFloat = 15
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)),
           let ink = inkSize(img), ink.width > 0, ink.height > 0 {
            p = min(17, max(13, 15 * 15.5 / sqrt(ink.width * ink.height)))
        }
        pointSizes[name] = p
        return p
    }
    private static var pointSizes: [String: CGFloat] = [:]

    /// The size of the drawn (non-transparent) part of an image, in points.
    private static func inkSize(_ img: NSImage) -> CGSize? {
        let k: CGFloat = 4
        let w = Int(img.size.width * k), h = Int(img.size.height * k)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where data[y * w + x] > 64 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGSize(width: CGFloat(maxX - minX + 1) / k, height: CGFloat(maxY - minY + 1) / k)
    }
    static let mosaicIcon: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 17), flipped: false) { _ in
            let frame = NSRect(x: 1.75, y: 1.25, width: 14.5, height: 14.5)
            let outline = NSBezierPath(roundedRect: frame, xRadius: 3.4, yRadius: 3.4)
            outline.lineWidth = 1.25
            NSColor.black.setStroke()
            outline.stroke()
            // a checkerboard of half-tone squares inside: reads as mosaic, weighs like the others
            let inner = frame.insetBy(dx: 0.6, dy: 0.6)
            let cell = inner.width / 4
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: inner, xRadius: 2.8, yRadius: 2.8).addClip()
            NSColor.black.withAlphaComponent(0.45).setFill()
            for i in 0..<4 { for j in 0..<4 where (i + j) % 2 == 0 {
                NSRect(x: inner.minX + CGFloat(i) * cell, y: inner.minY + CGFloat(j) * cell, width: cell, height: cell).fill()
            } }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        img.isTemplate = true
        return img
    }()
    var selected = false { didSet { needsDisplay = true } }
    var enabled = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hover = false { didSet { needsDisplay = true } }
    private lazy var image: NSImage? = {
        guard case .symbol(let name) = look else { return nil }
        if name == ToolButton.mosaicIconName { return ToolButton.mosaicIcon }
        if name == "pin" { return ToolButton.tiltedPin }
        let cfg = NSImage.SymbolConfiguration(pointSize: ToolButton.pointSize(for: name), weight: .regular)
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
            let tint: NSColor = !enabled ? .tertiaryLabelColor : (selected || prominent ? Palette.accent : NSColor.labelColor)
            let tinted = NSImage(size: img.size, flipped: false) { rect in
                img.draw(in: rect); tint.set(); rect.fill(using: .sourceIn); return true
            }
            // drawn at their own size: SF Symbols of one size and weight are balanced already, and
            // scaling one would thin its lines
            let s = img.size
            tinted.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
        case .color(let c):
            let side = min(r.width, r.height) - 8          // square, whatever the button's width
            let d = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            c.setFill()
            let p = NSBezierPath(roundedRect: d, xRadius: 3, yRadius: 3)
            p.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke(); p.lineWidth = 1; p.stroke()
            if selected {
                Palette.accent.setStroke()
                let o = NSBezierPath(roundedRect: d.insetBy(dx: -3, dy: -3), xRadius: 5, yRadius: 5)
                o.lineWidth = 2; o.stroke()
            }
        case .mosaicSwatch:
            // like a color swatch, filled with mosaic squares
            let side = min(r.width, r.height) - 8
            let d = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
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
                let o = NSBezierPath(roundedRect: d.insetBy(dx: -3, dy: -3), xRadius: 5, yRadius: 5)
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
    var onOpacity: ((CGFloat) -> Void)?
    private let opacitySlider = OpacitySlider(frame: NSRect(x: 0, y: 0, width: 96, height: 28))
    private let opacityValue = NSTextField(labelWithString: "100%")
    var onMosaicMode: ((MosaicMode) -> Void)?
    var onMosaicSolid: ((Bool) -> Void)?
    /// The toolbar changed size (the second row's buttons depend on the tool and mosaic mode).
    var onResize: (() -> Void)?

    private var toolButtons: [Tool: ToolButton] = [:]
    private var commandButtons: [Command: ToolButton] = [:]
    private var colorButtons: [ToolButton] = []
    private let sizeSlider = SizeSlider(frame: NSRect(x: 0, y: 0, width: 96, height: 28))
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
    static let swatchWidth: CGFloat = 28

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
            (.close, "xmark", L.t("close")), (.ok, "square.on.square", L.t("ok")),   // copy: the main action
        ]
        for (i, group) in (Prefs.shared.ocrEnabled ? [cmds, cmds2, cmds3] : [cmds, cmds3]).enumerated() {
            if i > 0 { gap() }
            for (c, sym, tip) in group {
                let b = ToolButton(.symbol(sym), tip: tip, size: unit)
                b.onClick = { [weak self] in self?.onCommand?(c) }
                b.prominent = c == .ok
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
            (.rect, "square.dashed", L.t("mosaicRect")),
            (.brush, "paintbrush", L.t("mosaicBrush")),
        ]
        for (m, sym, tip) in modes {
            let b = ToolButton(.symbol(sym), tip: tip, size: unit)
            b.onClick = { [weak self] in self?.setMosaicMode(m) }
            modeButtons[m] = b; paletteRow.addSubview(b)
        }
        for _ in 0..<3 {
            let sep = NSView(frame: NSRect(x: 0, y: 9, width: 1, height: unit - 14))
            sep.wantsLayer = true; seps.append(sep)
            paletteSeps.append(sep); paletteRow.addSubview(sep)
        }
        for (i, c) in Palette.colors.enumerated() {
            let b = ToolButton(.color(c), tip: nil, size: unit)
            b.frame.size.width = Toolbar.swatchWidth                   // a little narrower: two rows of one width
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
        mosaicSwatch.frame.size.width = Toolbar.swatchWidth
        mosaicSwatch.onClick = { [weak self] in self?.setMosaicSolid(false) }
        paletteRow.addSubview(mosaicSwatch)
        opacitySlider.toolTip = L.t("opacityTip")
        opacitySlider.onChange = { [weak self] in
            guard let self else { return }
            self.showOpacity(self.opacitySlider.value)
            self.onOpacity?(self.opacitySlider.value)
        }
        opacityValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        opacityValue.textColor = .secondaryLabelColor
        opacityValue.frame = NSRect(x: 0, y: 0, width: 36, height: 16)
        paletteRow.addSubview(opacitySlider)
        paletteRow.addSubview(opacityValue)
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
            sizeSlider.frame.origin = CGPoint(x: x - 3, y: (unit + 4 - sizeSlider.frame.height) / 2)
            sizeSlider.isHidden = false
            x += sizeSlider.frame.width - 3          // the value just past the largest knob
            // as wide as the widest value this tool shows: no blank after it, no jumping while dragging
            let widest = valueText(Annotation.maxWidth(tool ?? .rect))
            let w = ceil(NSAttributedString(string: widest, attributes: [.font: sizeValue.font as Any]).size().width) + 2
            sizeValue.frame = NSRect(x: x, y: (unit + 4 - sizeValue.frame.height) / 2, width: w, height: sizeValue.frame.height)
            sizeValue.isHidden = false
            x += w
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
        // the opacity of the color, where a color applies
        if tool != .mosaic || mosaicSolid {
            sep(2)
            opacitySlider.frame.origin = CGPoint(x: x - 6, y: (unit + 4 - opacitySlider.frame.height) / 2)
            opacitySlider.isHidden = false
            x += opacitySlider.frame.width - 6 - 2   // its knob is smaller: the value closer
            let w = ceil(NSAttributedString(string: "100%", attributes: [.font: opacityValue.font as Any]).size().width) + 2
            opacityValue.frame = NSRect(x: x, y: (unit + 4 - opacityValue.frame.height) / 2, width: w, height: opacityValue.frame.height)
            opacityValue.isHidden = false
            x += w
        } else {
            opacitySlider.isHidden = true
            opacityValue.isHidden = true
            paletteSeps[2].isHidden = true
        }
        paletteRow.frame.size = NSSize(width: x + 4, height: unit + 4)
        refreshPalette()
    }

    /// Selection marks: the chosen mosaic mode; a color only where it is used (not for mosaic squares).
    private func refreshPalette() {
        for (m, b) in modeButtons { b.selected = m == mosaicMode }
        let colorUsed = tool != .mosaic || mosaicSolid
        for (k, b) in colorButtons.enumerated() { b.selected = colorUsed && k == colorIndex }
        opacitySlider.color = Palette.colors[colorIndex]
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
        layoutPalette()                      // the opacity slider comes and goes with the color
        fitSize()
        if notify { onMosaicSolid?(on) }
        onResize?()
    }

    func setOpacity(_ o: CGFloat) {
        opacitySlider.value = o
        showOpacity(o)
    }

    private func showOpacity(_ o: CGFloat) { opacityValue.stringValue = "\(Int((o * 100).rounded()))%" }

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
    private func showValue(_ w: CGFloat) { sizeValue.stringValue = valueText(w) }

    private func valueText(_ w: CGFloat) -> String {
        switch tool {
        case .text: return "\(Int(Annotation.fontSize(for: w).rounded())) pt"
        case .number: return "\(Int((Annotation.numberRadius(w) * 2).rounded()))"
        case .marker: return "\(Int(w * 4))"
        case .mosaic: return "\(Int(Annotation.brushWidth(w)))"
        default: return "\(Int(w))"
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

/// The opacity slider: a checkerboard track with the color fading in from transparent, and a knob
/// showing the color at the chosen opacity. 10-100 %, in steps of 5.
final class OpacitySlider: NSView {
    var value: CGFloat = 1 { didSet { needsDisplay = true } }
    var color: NSColor = .black { didSet { needsDisplay = true } }
    var onChange: (() -> Void)?
    private let minValue: CGFloat = 0.1
    private let knob: CGFloat = 16
    private var inset: CGFloat { 11 }                 // as the size slider: the tracks line up
    private var knobX: CGFloat { inset + (bounds.width - inset * 2) * (value - minValue) / (1 - minValue) }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private func checker(_ r: NSRect, cell: CGFloat) {
        NSColor.white.setFill(); r.fill()
        NSColor(white: 0.82, alpha: 1).setFill()
        var y = r.minY, row = 0
        while y < r.maxY {
            var x = r.minX + (row % 2 == 0 ? 0 : cell)
            while x < r.maxX { NSRect(x: x, y: y, width: cell, height: cell).intersection(r).fill(); x += cell * 2 }
            y += cell; row += 1
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: inset, y: bounds.midY - 4, width: bounds.width - inset * 2, height: 8)
        let shape = NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        checker(track, cell: 4)
        NSGradient(starting: color.withAlphaComponent(0), ending: color.withAlphaComponent(1))?.draw(in: track, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let k = NSRect(x: knobX - knob / 2, y: bounds.midY - knob / 2, width: knob, height: knob)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: k).fill()
        NSGraphicsContext.restoreGraphicsState()
        // inside the knob: the color at this opacity, over the checkerboard
        let inner = k.insetBy(dx: 3, dy: 3)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: inner).addClip()
        checker(inner, cell: 2.5)
        color.withAlphaComponent(value).setFill()
        inner.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func set(fromX x: CGFloat) {
        let f = min(max((x - inset) / max(1, bounds.width - inset * 2), 0), 1)
        let v = ((minValue + (1 - minValue) * f) * 20).rounded() / 20
        guard v != value else { return }
        value = v
        onChange?()
    }

    override func mouseDown(with e: NSEvent) { set(fromX: convert(e.locationInWindow, from: nil).x) }
    override func mouseDragged(with e: NSEvent) { set(fromX: convert(e.locationInWindow, from: nil).x) }
}
