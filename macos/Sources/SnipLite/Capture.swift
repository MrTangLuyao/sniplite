import AppKit
import ScreenCaptureKit
import CoreVideo

/// One captured display: its pixels and where it is.
struct DisplayShot {
    let screen: NSScreen
    let image: CGImage      // full display, in pixels, top-left origin
    let scale: CGFloat      // pixels per point
    let windows: [SnapWindow]  // on-screen windows front to back, in this screen's flipped view coordinates

    /// This screen's flipped view coordinates <-> CG global coordinates (top-left of the primary display).
    var globalOffset: CGPoint {
        let f = screen.frame
        return CGPoint(x: f.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - f.maxY)
    }
}

struct SnapWindow {
    let rect: CGRect
    let pid: pid_t
}

enum CaptureError: Error { case noPermission, failed(String) }

/// Captures every display through ScreenCaptureKit and lists the windows for snapping.
enum Capture {
    private static var cachedDisplays: [SCDisplay]?

    static func invalidate() { cachedDisplays = nil }

    /// At start-up (and when displays change): fetch the display list and take one 16 x 16
    /// screenshot that is thrown away, so ScreenCaptureKit is warm: the first capture then takes
    /// about 120 ms like the others, instead of about 225.
    static func prewarm() {
        guard hasPermission else { return }
        Task {
            guard let d = try? await displays().first else { return }
            do {
                let cfg = SCStreamConfiguration()
                cfg.width = 16; cfg.height = 16; cfg.showsCursor = false
                cfg.sourceRect = CGRect(x: 0, y: 0, width: 16, height: 16)
                _ = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg)
            }
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    private static func displays() async throws -> [SCDisplay] {
        if let d = cachedDisplays { return d }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cachedDisplays = content.displays
            return content.displays
        } catch {
            if !hasPermission { throw CaptureError.noPermission }
            throw CaptureError.failed(error.localizedDescription)
        }
    }

    static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Captures all screens at once.
    @MainActor
    static func captureAll() async throws -> [DisplayShot] {
        let screens = NSScreen.screens
        let wins = windowRects()
        var list = try await displays()
        // a display that was plugged in since the list was cached: ask again
        if screens.contains(where: { s in !list.contains { $0.displayID == displayID(s) } }) {
            cachedDisplays = nil
            list = try await displays()
        }
        var jobs: [(NSScreen, SCDisplay)] = []
        for s in screens {
            if let d = list.first(where: { $0.displayID == displayID(s) }) { jobs.append((s, d)) }
        }
        let images: [CGImage?] = try await withThrowingTaskGroup(of: (Int, CGImage?).self) { group in
            for (i, (s, d)) in jobs.enumerated() {
                let scale = s.backingScaleFactor
                let size = s.frame.size
                group.addTask {
                    let filter = SCContentFilter(display: d, excludingWindows: [])
                    let cfg = SCStreamConfiguration()
                    cfg.width = Int(size.width * scale)
                    cfg.height = Int(size.height * scale)
                    cfg.showsCursor = false
                    cfg.captureResolution = .best
                    cfg.scalesToFit = false
                    cfg.colorSpaceName = CGColorSpace.sRGB
                    // 8-bit color: otherwise the image can come as 16-bit floats, twice the memory
                    // and slow to sample for the magnifier and the colors
                    cfg.pixelFormat = kCVPixelFormatType_32BGRA
                    let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    return (i, img)
                }
            }
            var out = [CGImage?](repeating: nil, count: jobs.count)
            for try await (i, img) in group { out[i] = img }
            return out
        }
        var shots: [DisplayShot] = []
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        for (i, (s, _)) in jobs.enumerated() {
            guard let img = images[i] else { continue }
            let f = s.frame
            // CG global (top-left of the primary display) -> this screen's flipped view coordinates
            let dy = primaryH - f.maxY
            let local = wins.compactMap { w -> SnapWindow? in
                let r = w.rect
                let v = CGRect(x: r.minX - f.minX, y: r.minY - dy, width: r.width, height: r.height)
                let clipped = v.intersection(CGRect(origin: .zero, size: f.size))
                return clipped.width >= 8 && clipped.height >= 8 ? SnapWindow(rect: clipped, pid: w.pid) : nil
            }
            shots.append(DisplayShot(screen: s, image: img, scale: CGFloat(img.width) / f.width, windows: local))
        }
        if shots.isEmpty { throw hasPermission ? CaptureError.failed("no display") : CaptureError.noPermission }
        return shots
    }

    /// Windows to snap to, front to back, in CG global coordinates: the windows of apps (layer 0)
    /// and small system ones such as menu bar items and the Dock. Transparent full-screen layers
    /// (Notification Center, gestures, Stage Manager…) are left out: under the mouse they would
    /// select the whole screen and nothing would be dimmed.
    private static func windowRects() -> [SnapWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let screens = NSScreen.screens.map { $0.frame.size }
        var out: [SnapWindow] = []
        for w in info {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if alpha <= 0.01 || layer < 0 || layer > Int(CGWindowLevelForKey(.mainMenuWindow)) + 1 { continue }
            if pid == me && layer != NSWindow.Level.floating.rawValue { continue }     // only pins of sniplite
            if layer != 0 {
                let big = screens.contains { r.width * r.height >= $0.width * $0.height * 0.5 }
                if big { continue }
            }
            out.append(SnapWindow(rect: r, pid: pid))
        }
        return out
    }
}

/// Helpers for CGImage.
extension CGImage {
    /// The color of one pixel (sRGB), or nil outside.
    func color(atPixel x: Int, _ y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < width, y < height,
              let one = cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    /// A blocky copy, `block` pixels per square, the same size as this image when drawn without interpolation.
    func pixelated(block: Int) -> CGImage? {
        let w = max(1, width / block), h = max(1, height / block)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
