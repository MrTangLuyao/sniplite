import Testing
import CoreGraphics
import AppKit
@testable import SnipLite

/// Hit testing, handles and the rules for sizes and colors of the drawings.
struct AnnotationTests {
    let red = Palette.colors[0]

    @Test func arrowHitAndEnds() {
        var a = Annotation(tool: .arrow, color: red, width: 4, points: [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 10)])
        #expect(a.hit(CGPoint(x: 60, y: 13)))
        #expect(!a.hit(CGPoint(x: 60, y: 30)))
        #expect(a.handlePoints.count == 2)
        a.moveHandle(1, to: CGPoint(x: 200, y: 50))
        #expect(a.points[1] == CGPoint(x: 200, y: 50))
    }

    @Test func rectangleBorderAndCorners() {
        var a = Annotation(tool: .rect, color: red, width: 4, points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 160)])
        #expect(a.hit(CGPoint(x: 101, y: 130)))           // on the border
        #expect(!a.hit(CGPoint(x: 150, y: 130)))          // inside: not the shape
        a.moveHandle(2, to: CGPoint(x: 300, y: 300))      // bottom right; top left stays
        #expect(CGRect(a.points[0], a.points[1]) == CGRect(x: 100, y: 100, width: 200, height: 200))
    }

    @Test func ellipseOutline() {
        let a = Annotation(tool: .ellipse, color: red, width: 4, points: [.zero, CGPoint(x: 100, y: 50)])
        #expect(a.hit(CGPoint(x: 50, y: 1)))
        #expect(!a.hit(CGPoint(x: 50, y: 25)))
    }

    @Test func hideRules() {
        let box = Annotation(tool: .mosaic, color: red, width: 4, mosaicMode: .rect, points: [.zero, CGPoint(x: 100, y: 30)])
        #expect(box.hit(CGPoint(x: 50, y: 15)))
        #expect(!box.hasWidth && !box.hasColor)
        let colorBox = Annotation(tool: .mosaic, color: red, width: 4, mosaicMode: .rect, solid: true, points: [.zero, CGPoint(x: 10, y: 10)])
        #expect(!colorBox.hasWidth && colorBox.hasColor)
        let brush = Annotation(tool: .mosaic, color: red, width: 4, mosaicMode: .brush, points: [.zero, CGPoint(x: 100, y: 0)])
        #expect(brush.hasWidth && !brush.hasColor && brush.handlePoints.isEmpty)
        #expect(Annotation.mosaicBlock(box: CGRect(x: 0, y: 0, width: 300, height: 30)) == 8)
        #expect(Annotation.mosaicBlock(box: CGRect(x: 0, y: 0, width: 300, height: 300)) == 20)
    }

    @Test func penHit() {
        let a = Annotation(tool: .pen, color: red, width: 2, points: [.zero, CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 0)])
        #expect(a.hit(CGPoint(x: 26, y: 24)))
        #expect(!a.hit(CGPoint(x: 50, y: 0)))
    }

    @Test func textAndNumber() {
        let t = Annotation(tool: .text, color: red, width: 4, points: [CGPoint(x: 10, y: 10)], text: "Hello")
        #expect(t.hit(CGPoint(x: 20, y: 18)))
        #expect(t.textHandles.count == 4 && t.handlePoints.isEmpty)
        let n = Annotation(tool: .number, color: red, width: 4, points: [CGPoint(x: 50, y: 50)], number: 1)
        #expect(n.hit(CGPoint(x: 55, y: 52)))
    }

    @Test func textScalesFromACorner() {
        let orig = Annotation(tool: .text, color: red, width: 4, points: [CGPoint(x: 100, y: 100)], text: "Hello")
        let hs = orig.textHandles
        var a = orig
        // drag the bottom right corner down to double the height: the top left corner stays
        let target = CGPoint(x: hs[2].x + 50, y: hs[0].y + (hs[2].y - hs[0].y - 2 * Annotation.textPad) * 2 + 2 * Annotation.textPad)
        a.scaleText(corner: 2, to: target, from: orig)
        #expect(a.fontSize > orig.fontSize * 1.8)
        #expect(abs(a.textHandles[0].x - hs[0].x) < 0.5 && abs(a.textHandles[0].y - hs[0].y) < 0.5)
        // the top left corner, dragged far: capped at the largest text size
        var b = orig
        b.scaleText(corner: 0, to: CGPoint(x: -5000, y: -5000), from: orig)
        #expect(b.width == Annotation.maxWidth(.text))
    }

    @Test func limitsPerTool() {
        #expect(Annotation.maxWidth(.text) == 24 && Annotation.fontSize(for: 24) <= 72)
        #expect(Annotation.maxWidth(.number) == 20)
        #expect(Annotation.maxWidth(.line) == 40)
    }

    @Test func movingKeepsShape() {
        var a = Annotation(tool: .line, color: red, width: 2, points: [.zero, CGPoint(x: 10, y: 20)])
        a.offset(5, -3)
        #expect(a.points == [CGPoint(x: 5, y: -3), CGPoint(x: 15, y: 17)])
    }
}

/// Recognized text into lines and columns.
struct OCRLayoutTests {
    @Test func linesAndColumns() {
        let items: [(CGRect, String)] = [
            (CGRect(x: 0, y: 0, width: 40, height: 10), "Name"), (CGRect(x: 200, y: 0, width: 30, height: 10), "Qty"),
            (CGRect(x: 0, y: 20, width: 40, height: 10), "Apple"), (CGRect(x: 200, y: 21, width: 10, height: 10), "3"),
        ]
        let t = OCR.layout(items)
        #expect(t.plain == "Name\tQty\nApple\t3")
        #expect(t.markdown?.contains("| Name | Qty |") == true)
    }

    @Test func wordsOnOneLineJoin() {
        let t = OCR.layout([(CGRect(x: 0, y: 0, width: 40, height: 10), "Hello"), (CGRect(x: 45, y: 0, width: 40, height: 10), "world")])
        #expect(t.plain == "Hello world")
        #expect(t.markdown == nil)
    }
}

/// A text typed in several colors keeps them.
struct TextColorTests {
    @Test func runsRoundTrip() {
        let red = Palette.colors[0], blue = Palette.colors[4]
        let s = NSMutableAttributedString(string: "Hello world", attributes: [.foregroundColor: red])
        s.addAttribute(.foregroundColor, value: blue, range: NSRange(location: 6, length: 5))
        let (base, runs) = Annotation.colors(of: s, default: red)
        #expect(base == red)
        #expect(runs == [Annotation.ColorRun(location: 6, length: 5, color: blue)])
        var a = Annotation(tool: .text, color: base, width: 4, points: [.zero], text: "Hello world")
        a.colorRuns = runs
        let t = a.attributedText
        #expect((t.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == red)
        #expect((t.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor) == blue)
    }
}

/// Colors with an opacity are still the palette's colors.
struct OpacityTests {
    @Test func paletteIndexIgnoresOpacity() {
        for (i, c) in Palette.colors.enumerated() {
            #expect(Palette.index(of: c.withAlphaComponent(0.4)) == i)
        }
        #expect(Palette.index(of: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)) == nil)
    }
}
