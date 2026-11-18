import AppKit

enum Tool: Int, CaseIterable {
    case rect, ellipse, line, arrow, pen, marker, mosaic, text, number

    var symbol: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .mosaic: return "checkerboard.rectangle"
        case .text: return "textformat"
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

/// How the mosaic tool hides things: pixelating a dragged rectangle (the default), pixelating
/// along a brush stroke, or covering a rectangle with the chosen color.
enum MosaicMode: String { case rect, brush, fill }

struct Annotation {
    var tool: Tool
    var color: NSColor
    var width: CGFloat
    var mosaicMode: MosaicMode = .rect
    var points: [CGPoint]          // shapes: [start, end]; strokes: the path; text / number: [origin]
    var text: String = ""
    var number: Int = 0

    var fontSize: CGFloat { Self.fontSize(for: width) }
    /// Width 2 / 4 / 8 -> about 14 / 20 / 30 pt, as the three sizes of the Windows version.
    static func fontSize(for width: CGFloat) -> CGFloat { 9 + width * 2.6 }
    /// The side of a mosaic square, in points.
    static func mosaicBlock(for width: CGFloat) -> CGFloat { 4 + width * 1.5 }

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
            switch mosaicMode {
            case .fill:
                ctx.fill(CGRect(p0, p1))
            case .rect, .brush:
                guard let img = mosaic(Self.mosaicBlock(for: width)) else { return }
                if mosaicMode == .rect {
                    ctx.clip(to: CGRect(p0, p1))
                } else {
                    ctx.setLineWidth(max(10, width * 5))
                    ctx.addPath(Self.smoothPath(points))
                    ctx.replacePathWithStrokedPath()
                    ctx.clip()
                }
                ctx.interpolationQuality = .none
                ctx.drawFlipped(img, in: screenRect)
            }
        case .text:
            let s = NSAttributedString(string: text, attributes: Self.textAttributes(color: color, size: fontSize))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            s.draw(at: p0)
            NSGraphicsContext.restoreGraphicsState()
        case .number:
            let r = 8 + width * 1.6
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
