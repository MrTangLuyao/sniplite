import AppKit
import ApplicationServices

/// The parts of a window under the mouse (buttons, fields, lists, panes…) through the
/// Accessibility API, smallest first, so a capture can snap to one of them. Needs the
/// Accessibility permission; without it only whole windows are found.
final class ElementFinder {
    static let shared = ElementFinder()
    private let queue = DispatchQueue(label: "sniplite.elements", qos: .userInteractive)
    private var latest = 0
    private var cache: [pid_t: AXUIElement] = [:]

    /// Looks up the elements at `p` (CG global coordinates) in the app `pid`, off the main thread;
    /// `done` runs on the main thread with their frames (CG global), unless a newer lookup started.
    /// The newest lookup asked for; read on the lookup queue, so behind a lock.
    private let lock = NSLock()
    private var newest = 0

    func find(at p: CGPoint, pid: pid_t, done: @escaping ([CGRect]) -> Void) {
        guard AXIsProcessTrusted() else { return }
        latest += 1
        let id = latest
        lock.lock(); newest = id; lock.unlock()
        queue.async { [self] in
            // a slow app (up to 80 ms a lookup) must not build a queue behind the mouse:
            // a lookup that is no longer the newest is skipped
            lock.lock(); let current = newest; lock.unlock()
            guard id == current else { return }
            let rects = lookup(p, pid)
            DispatchQueue.main.async { [self] in if id == latest { done(rects) } }
        }
    }

    private func app(_ pid: pid_t) -> AXUIElement {
        if let a = cache[pid] { return a }
        let a = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(a, 0.08)   // a busy app must not stall the capture
        cache[pid] = a
        return a
    }

    private func lookup(_ p: CGPoint, _ pid: pid_t) -> [CGRect] {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app(pid), Float(p.x), Float(p.y), &hit) == .success, var el = hit else { return [] }
        var out: [CGRect] = []
        for _ in 0..<16 {
            if let r = frame(el), r.width >= 4, r.height >= 4, r.contains(p),
               !out.contains(where: { abs($0.minX - r.minX) < 1 && abs($0.minY - r.minY) < 1
                                    && abs($0.width - r.width) < 1 && abs($0.height - r.height) < 1 }) {
                out.append(r)
            }
            if role(el) == kAXWindowRole as String { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success,
                  let par = parent, CFGetTypeID(par) == AXUIElementGetTypeID() else { break }
            el = par as! AXUIElement
            if role(el) == kAXApplicationRole as String { break }
        }
        return out
    }

    private func role(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private func frame(_ el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              let pos = pv, let size = sv,
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var o = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &o)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: o, size: s)
    }
}
