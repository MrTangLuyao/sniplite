import AppKit

enum Tool: Int, CaseIterable {
    case rect, ellipse, line, arrow, pen, marker, mosaic, text, number

    var symbol: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .marker: return "highlighter"
        case .mosaic: return "square.grid.3x3.square"
        case .text: return "character"
        case .number: return "1.circle"
        }
    }
    var tip: String {
        switch self {
        case .rect: return L.t("rect")
        case .ellipse: return L.t("ellipse")
        case .line: return L.t("line")
        case .arrow: return L.t("arrow")
        case .pen: return L.t("pen")
        case .marker: return L.t("marker")
        case .mosaic: return L.t("mosaic")
        case .text: return L.t("text")
        case .number: return L.t("number")
        }
    }
    /// Tools drawn by dragging from one corner to the other.
    var isShape: Bool { self == .rect || self == .ellipse || self == .line || self == .arrow }
    var isStroke: Bool { self == .pen || self == .marker }
}

/// The colors and sizes of the toolbar (the same eight colors as the Windows version).
enum Palette {
    static let hex: [UInt32] = [0xE53935, 0xFB8C00, 0xFDD835, 0x43A047, 0x1E88E5, 0x8E24AA, 0x000000, 0xFFFFFF]
    static let colors: [NSColor] = hex.map {
        NSColor(srgbRed: CGFloat($0 >> 16 & 0xFF) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255,
                blue: CGFloat($0 & 0xFF) / 255, alpha: 1)
    }
    /// The three size buttons; the wheel (or two fingers on a trackpad) sets any width in `widthRange`.
    static let widths: [CGFloat] = [2, 4, 8]
    static let widthRange: ClosedRange<CGFloat> = 1...40
    static let accent = NSColor(srgbRed: 0x1A / 255, green: 0x8C / 255, blue: 1, alpha: 1)
}

/// The shape of what the hide tool covers: a dragged box (the default) or a brush stroke.
/// What it covers it with is separate: mosaic, or a solid color (`Annotation.solid`).
enum MosaicMode: String { case rect, brush }

struct Annotation {
    var tool: Tool
    var color: NSColor
    var width: CGFloat
    var mosaicMode: MosaicMode = .rect
    var solid = false                 // hide with the color instead of mosaic
    var points: [CGPoint]          // shapes: [start, end]; strokes: the path; text / number: [origin]
    var text: String = ""
    var number: Int = 0
    /// Text: parts in other colors than `color` (UTF-16 ranges), from coloring while typing.
    var colorRuns: [ColorRun] = []

    struct ColorRun: Equatable {
        var location: Int, length: Int
        var color: NSColor
    }

    /// The text with its size and its colors.
    var attributedText: NSAttributedString {
        let m = NSMutableAttributedString(string: text, attributes: Self.textAttributes(color: color, size: fontSize))
        for r in colorRuns where r.location >= 0 && r.location + r.length <= m.length {
            m.addAttribute(.foregroundColor, value: r.color, range: NSRange(location: r.location, length: r.length))
        }
        return m
    }

    /// Colors as an attributed string has them: the first one is the text's color, the parts in
    /// other colors become runs.
    static func colors(of s: NSAttributedString, default d: NSColor) -> (NSColor, [ColorRun]) {
        var base: NSColor?
        var runs: [ColorRun] = []
        s.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            let c = (v as? NSColor) ?? d
            if base == nil { base = c }
            if c != base { runs.append(ColorRun(location: r.location, length: r.length, color: c)) }
        }
        return (base ?? d, runs)
    }

    var fontSize: CGFloat { Self.fontSize(for: width) }
    /// A number's circle: about 17 / 22 / 31 pt across for the three sizes.
    static func numberRadius(_ width: CGFloat) -> CGFloat { 6 + width * 1.2 }
    /// Width 2 / 4 / 8 -> about 14 / 20 / 30 pt, as the three sizes of the Windows version.
    static func fontSize(for width: CGFloat) -> CGFloat { 9 + width * 2.6 }
    /// Mosaic squares are not set by hand: big enough that text under them cannot be read,
    /// from the size of the box, or of the brush.
    static func mosaicBlock(box r: CGRect) -> CGFloat { min(20, max(8, min(r.width, r.height) / 5)) }
    static func mosaicBlock(brush width: CGFloat) -> CGFloat { min(20, max(8, brushWidth(width) / 2.5)) }
    static func brushWidth(_ width: CGFloat) -> CGFloat { max(10, width * 5) }

    /// The largest width per tool: lines up to 40, text up to about 72 pt, numbers up to a 30 pt radius.
    static func maxWidth(_ t: Tool) -> CGFloat { t == .text ? 24 : (t == .number ? 20 : 40) }

    /// Whether the wheel and the size buttons change it: not a hide box (its size is the box).
    var hasWidth: Bool { tool != .mosaic || mosaicMode == .brush }
    /// Whether a color applies: everything but mosaic (a solid hide has one).
    var hasColor: Bool { tool != .mosaic || solid }

    /// Drawn as a path of points (rather than from one corner to the other).
    var isStrokeLike: Bool { tool.isStroke || (tool == .mosaic && mosaicMode == .brush) }

    static func textAttributes(color: NSColor, size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color]
    }

    /// Draws into a context whose coordinates are the overlay's flipped points (y down).
    /// `mosaic` gives the blocky copy of the screen for a block size (points), `screenRect` where it goes.
    func draw(in ctx: CGContext, mosaic: (CGFloat) -> CGImage?, screenRect: CGRect) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        guard let p0 = points.first else { return }
        let p1 = points.last ?? p0
        switch tool {
        case .rect:
            ctx.stroke(CGRect(p0, p1))
        case .ellipse:
            ctx.strokeEllipse(in: CGRect(p0, p1))
        case .line:
            ctx.strokeLineSegments(between: [p0, p1])
        case .arrow:
            drawArrow(ctx, p0, p1)
        case .pen, .marker:
            if tool == .marker {
                ctx.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
                ctx.setLineWidth(width * 4)
                ctx.setLineCap(.square)
            }
            ctx.addPath(Self.smoothPath(points))
            ctx.strokePath()
        case .mosaic:
            switch (mosaicMode, solid) {
            case (.rect, true):
                ctx.fill(CGRect(p0, p1))
            case (.brush, true):
                ctx.setLineWidth(Self.brushWidth(width))
                ctx.addPath(Self.smoothPath(points))
                ctx.strokePath()
            default:
                let block = mosaicMode == .rect ? Self.mosaicBlock(box: CGRect(p0, p1)) : Self.mosaicBlock(brush: width)
                guard let img = mosaic(block) else { return }
                if mosaicMode == .rect {
                    ctx.clip(to: CGRect(p0, p1))
                } else {
                    ctx.setLineWidth(Self.brushWidth(width))
                    ctx.addPath(Self.smoothPath(points))
                    ctx.replacePathWithStrokedPath()
                    ctx.clip()
                }
                ctx.interpolationQuality = .none
                ctx.drawFlipped(img, in: screenRect)
            }
        case .text:
            let s = attributedText
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            s.draw(at: p0)
            NSGraphicsContext.restoreGraphicsState()
        case .number:
            let r = Annotation.numberRadius(width)
            ctx.fillEllipse(in: CGRect(x: p0.x - r, y: p0.y - r, width: r * 2, height: r * 2))
            let light = Palette.hex[Palette.colors.firstIndex(of: color) ?? 0] == 0xFFFFFF
                || Palette.hex[Palette.colors.firstIndex(of: color) ?? 0] == 0xFDD835
            let s = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: r * 1.1, weight: .bold),
                .foregroundColor: light ? NSColor.black : NSColor.white])
            let sz = s.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            s.draw(at: CGPoint(x: p0.x - sz.width / 2, y: p0.y - sz.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawArrow(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let ux = dx / len, uy = dy / len
        let head = min(len, max(14, width * 4.5))
        let half = head * 0.45
        let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        ctx.strokeLineSegments(between: [a, CGPoint(x: base.x + ux * 1, y: base.y + uy * 1)])
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        ctx.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        ctx.closePath()
        ctx.fillPath()
    }

    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count == 1 { p.addLine(to: first); return p }
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i - 1])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }
}

extension CGRect {
    /// The rectangle between two corners.
    init(_ a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

extension CGContext {
    /// Draws an image upright although the context's y axis points down.
    func drawFlipped(_ img: CGImage, in r: CGRect) {
        saveGState()
        translateBy(x: 0, y: r.minY + r.maxY)
        scaleBy(x: 1, y: -1)
        draw(img, in: r)
        restoreGState()
    }
}

// MARK: - editing after drawing

extension Annotation {
    private var isBox: Bool {
        tool == .rect || tool == .ellipse || (tool == .mosaic && mosaicMode == .rect)
    }

    /// Points that can be dragged to reshape it: the two ends of a line or an arrow, the four
    /// corners of a box. Other kinds are only moved.
    var handlePoints: [CGPoint] {
        guard points.count >= 2 else { return [] }
        if tool == .line || tool == .arrow { return [points[0], points[1]] }
        if isBox { return Self.corners(CGRect(points[0], points[1])) }
        return []
    }

    /// Text: corners just outside its box; dragging one scales the text.
    var textHandles: [CGPoint] { tool == .text ? Self.corners(bounds.insetBy(dx: -Self.textPad, dy: -Self.textPad)) : [] }
    static let textPad: CGFloat = 4

    static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    /// Scales a text by dragging corner `i` to `p`; the opposite corner stays where it is.
    mutating func scaleText(corner i: Int, to p: CGPoint, from orig: Annotation) {
        let hs = orig.textHandles
        guard hs.count == 4 else { return }
        let fixed = hs[(i + 2) % 4]
        let oldH = orig.bounds.height
        guard oldH > 0 else { return }
        let newH = max(8, abs(p.y - fixed.y) - Self.textPad * 2)
        let font = orig.fontSize * newH / oldH
        width = min(max((font - 9) / 2.6, Palette.widthRange.lowerBound), Self.maxWidth(.text))
        // put the text so the fixed corner stays
        let b = bounds
        let left = i == 1 || i == 2           // dragging a right corner keeps the left side
        let top = i == 2 || i == 3            // dragging a bottom corner keeps the top
        let x = left ? fixed.x + Self.textPad : fixed.x - Self.textPad - b.width
        let y = top ? fixed.y + Self.textPad : fixed.y - Self.textPad - b.height
        points = [CGPoint(x: x, y: y)]
    }

    /// Moves handle `i` to `p`: an end, or a corner (the opposite corner stays).
    mutating func moveHandle(_ i: Int, to p: CGPoint) {
        if tool == .line || tool == .arrow { points[i] = p; return }
        let h = handlePoints
        guard h.count == 4 else { return }
        points = [h[(i + 2) % 4], p]
    }

    mutating func offset(_ dx: CGFloat, _ dy: CGFloat) {
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// The area it covers (for the selection mark and hit testing).
    var bounds: CGRect {
        guard let p0 = points.first else { return .null }
        switch tool {
        case .text:
            let sz = attributedText.size()
            return CGRect(origin: p0, size: sz)
        case .number:
            let r = Annotation.numberRadius(width)
            return CGRect(x: p0.x - r, y: p0.y - r, width: r * 2, height: r * 2)
        default:
            if isBox || tool == .line || tool == .arrow { return CGRect(p0, points.last ?? p0) }
            var r = CGRect(origin: p0, size: .zero)
            for q in points { r = r.union(CGRect(origin: q, size: .zero)) }
            let w = tool == .marker ? width * 4 : (tool == .mosaic ? Self.brushWidth(width) : width)
            return r.insetBy(dx: -w / 2, dy: -w / 2)
        }
    }

    /// Whether a click at `p` is on it: near the outline of a shape or the path of a stroke,
    /// inside a mosaic or color box, a text or a number.
    func hit(_ p: CGPoint) -> Bool {
        guard let p0 = points.first else { return false }
        let p1 = points.last ?? p0
        switch tool {
        case .text, .number:
            return bounds.insetBy(dx: -3, dy: -3).contains(p)
        case .line, .arrow:
            return Self.distance(p, p0, p1) <= max(6, width / 2 + 4)
        case .rect:
            let r = CGRect(p0, p1), t = max(6, width / 2 + 4)
            let inner = r.insetBy(dx: t, dy: t)
            return r.insetBy(dx: -t, dy: -t).contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
        case .ellipse:
            let r = CGRect(p0, p1), t = max(6, width / 2 + 4)
            let rx = max(r.width / 2, 1), ry = max(r.height / 2, 1)
            let d = hypot((p.x - r.midX) / rx, (p.y - r.midY) / ry)
            return abs(d - 1) * min(rx, ry) <= t
        case .mosaic where mosaicMode == .rect:
            return CGRect(p0, p1).insetBy(dx: -4, dy: -4).contains(p)
        default:   // pen, marker, mosaic brush
            let w = tool == .marker ? width * 4 : (tool == .mosaic ? Self.brushWidth(width) : width)
            let t = max(6, w / 2 + 3)
            if points.count == 1 { return hypot(p.x - p0.x, p.y - p0.y) <= t }
            for i in 1..<points.count where Self.distance(p, points[i - 1], points[i]) <= t { return true }
            return false
        }
    }

    /// From a point to a segment.
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
