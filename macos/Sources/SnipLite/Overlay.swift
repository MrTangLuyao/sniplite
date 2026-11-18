import AppKit

/// One capture: an overlay window on every screen, from the hotkey until copy / save / pin / cancel.
final class CaptureSession {
    enum Mode { case normal, ocr, ocrCopy }
    static var current: CaptureSession?

    let mode: Mode
    private(set) var windows: [OverlayWindow] = []

    private init(mode: Mode) { self.mode = mode }

    static func start(_ mode: Mode = .normal) {
        guard current == nil else { return }
        // without the permission ScreenCaptureKit would show the system's own dialog: show ours
        guard Permission.screenRecording.granted else { PermissionsWindow.show(); return }
        let s = CaptureSession(mode: mode)
        current = s
        Task { @MainActor in
            do {
                let shots = try await Capture.captureAll()
                s.show(shots)
            } catch CaptureError.noPermission {
                current = nil
                AppDelegate.askForPermission()
            } catch {
                current = nil
                NSSound.beep()
                Log.write("capture failed: \(error)")
            }
        }
    }

    @MainActor
    private func show(_ shots: [DisplayShot]) {
        let mouse = NSEvent.mouseLocation
        for shot in shots {
            let w = OverlayWindow(shot: shot, session: self)
            windows.append(w)
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let key = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        key?.makeKeyAndOrderFront(nil)
        key?.overlay.mouseAt(key?.overlay.localMouse() ?? .zero)
    }

    /// One overlay began editing: the others go quiet.
    func editing(on view: OverlayView) {
        for w in windows where w.overlay !== view { w.overlay.goIdle() }
    }

    func finish() {
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
        if CaptureSession.current === self { CaptureSession.current = nil }
        CaptureSession.releaseMemory()
    }

    /// A capture frees its screen images (tens of MB), which malloc may keep cached for reuse;
    /// Activity Monitor counts that against sniplite. Info.plist turns the large-block cache off
    /// (LSEnvironment MallocLargeCache=0); this also hands back what other caches keep.
    static func releaseMemory() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            autoreleasepool { }
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}

/// A panel that takes the keyboard without making sniplite the active app, so it works the
/// same from a hotkey (when another app is active) as from the menu.
final class OverlayWindow: NSPanel {
    let overlay: OverlayView

    init(shot: DisplayShot, session: CaptureSession) {
        overlay = OverlayView(shot: shot, session: session)
        super.init(contentRect: shot.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        setFrame(shot.screen.frame, display: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none

        let root = NSView(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
        let bg = NSView(frame: root.bounds)
        bg.wantsLayer = true
        bg.layer?.contents = shot.image
        bg.layer?.contentsGravity = .resize
        bg.layer?.magnificationFilter = .nearest
        bg.autoresizingMask = [.width, .height]
        overlay.frame = root.bounds
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(bg)
        root.addSubview(overlay)
        contentView = root
        makeFirstResponder(overlay)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The drawing surface of an overlay: dimming, selection, annotations, magnifier, toolbar.
final class OverlayView: NSView, NSTextViewDelegate {
    enum Phase { case select, edit, idle }
    enum Drag {
        case none, newSelection, move(CGPoint, CGRect), resize(Int, CGRect), draw
        case moveAnnotation(Int, CGPoint, Annotation)     // index, where the drag began, as it was
        case dragHandle(Int, Int, Annotation)             // index, handle, as it was
    }

    static let edgeL = 1, edgeT = 2, edgeR = 4, edgeB = 8

    let shot: DisplayShot
    weak var session: CaptureSession?
    private var phase: Phase = .select
    private var drag: Drag = .none
    private var mouse: CGPoint = .zero
    private var downAt: CGPoint = .zero
    private var dragged = false

    private var chain: [CGRect] = []     // windows under the mouse, smallest first, then the screen
    private var chainIndex = 0
    private var hover: CGRect? { chain.isEmpty ? nil : chain[min(chainIndex, chain.count - 1)] }

    private(set) var selection: CGRect = .zero
    private var annotations: [Annotation] = []
    /// Undo and redo keep whole states, so moving, reshaping, recoloring and resizing undo too.
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var pendingUndo: [Annotation]?        // taken on mouse down, kept only if something changes
    private var lastScrollEdit = Date.distantPast
    /// The annotation being edited (drawn last, or clicked): it shows handles, the wheel sizes it,
    /// a color recolors it, Delete removes it.
    private var selected: Int? { didSet { if selected != oldValue { needsDisplay = true } } }
    private var hoverAnnotation = false
    private var current: Annotation?
    private var tool: Tool?
    private var colorIndex = Prefs.shared.colorIndex
    private var width = Prefs.shared.strokeWidth
    private var mosaicMode = Prefs.shared.mosaicMode
    private var mosaicSolid = Prefs.shared.mosaicSolid
    private var scrollSum: CGFloat = 0           // trackpad scrolling, collected into width steps
    private var sizeHUDUntil = Date.distantPast  // the width preview at the mouse
    private let toolbar = Toolbar()
    private var textView: NSTextView?
    private var textOrigin: CGPoint = .zero
    private var mosaicCache: [Int: CGImage] = [:]

    /// The blocky copy of the screen for squares of `block` points, made once per size.
    private func mosaicImage(_ block: CGFloat) -> CGImage? {
        let px = max(2, Int((block * shot.scale).rounded()))
        if let m = mosaicCache[px] { return m }
        let m = shot.image.pixelated(block: px)
        mosaicCache[px] = m
        return m
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(shot: DisplayShot, session: CaptureSession) {
        self.shot = shot
        self.session = session
        super.init(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
        toolbar.isHidden = true
        addSubview(toolbar)
        toolbar.onTool = { [weak self] t in self?.setTool(t) }
        toolbar.onColor = { [weak self] i in self?.pickColor(i) }
        toolbar.onSize = { [weak self] i in self?.setWidth(Palette.widths[i], preview: false) }
        toolbar.onMosaicMode = { [weak self] m in self?.pickMosaicMode(m) }
        toolbar.onMosaicSolid = { [weak self] on in self?.pickMosaicSolid(on) }
        toolbar.onResize = { [weak self] in self?.placeToolbar() }
        toolbar.onCommand = { [weak self] c in self?.command(c) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.owner === self { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    func localMouse() -> CGPoint {
        guard let w = window else { return .zero }
        return convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    }

    // MARK: highlight animation

    /// The highlight as drawn: it glides to the next window or element instead of jumping.
    private var holeShown: CGRect?
    private var holeFrom = CGRect.zero, holeTo = CGRect.zero
    private var holeStart: CFTimeInterval = 0
    private var holeLink: CADisplayLink?
    private static let holeDuration: CFTimeInterval = 0.14

    private func animateHole(to r: CGRect?) {
        guard let r else { holeShown = nil; stopHoleAnimation(); return }
        guard let cur = holeShown else { holeShown = r; return }     // the first one appears at once
        if r == (holeLink != nil ? holeTo : cur) { return }
        holeFrom = cur
        holeTo = r
        holeStart = CACurrentMediaTime()
        if holeLink == nil {
            // frames only while it moves: about 8 of them, then the link stops
            let link = displayLink(target: self, selector: #selector(stepHole(_:)))
            link.add(to: .main, forMode: .common)
            holeLink = link
        }
    }

    @objc private func stepHole(_ link: CADisplayLink) {
        let t = min(1, (CACurrentMediaTime() - holeStart) / Self.holeDuration)
        let e = 1 - pow(1 - t, 3)                                   // ease out
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * e }
        holeShown = CGRect(x: mix(holeFrom.minX, holeTo.minX), y: mix(holeFrom.minY, holeTo.minY),
                           width: mix(holeFrom.width, holeTo.width), height: mix(holeFrom.height, holeTo.height))
        needsDisplay = true
        if t >= 1 { holeShown = holeTo; stopHoleAnimation() }
    }

    private func stopHoleAnimation() {
        holeLink?.invalidate()
        holeLink = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopHoleAnimation() }   // the link holds the view: let it go with the window
        super.viewWillMove(toWindow: newWindow)
    }

    func goIdle() {
        stopHoleAnimation(); holeShown = nil
        commitText()
        phase = .idle; chain = []; toolbar.isHidden = true
        needsDisplay = true
    }

    private var screenBounds: CGRect { bounds }

    // MARK: window snapping

    private var elements: [CGRect] = []          // parts of the top window under the mouse, smallest first
    private var lastLookup: CGPoint = CGPoint(x: -1000, y: -1000)

    /// What the wheel steps through: the element under the mouse and the elements holding it,
    /// then the window, bigger windows behind it, and the screen.
    private func computeChain(_ p: CGPoint, lookUp: Bool = true) {
        let under = shot.windows.filter { $0.rect.contains(p) }
        var list: [CGRect] = []
        if let top = under.first {
            let tr = top.rect
            let area = tr.width * tr.height
            list += elements.filter { $0.contains(p) && tr.insetBy(dx: -1, dy: -1).contains($0) && $0.width * $0.height < area * 0.97 }
            list.append(tr)
            let bigger = under.dropFirst().map(\.rect).filter { $0.width * $0.height > area && !list.contains($0) }
            list += bigger.sorted { $0.width * $0.height < $1.width * $1.height }
            if lookUp && hypot(p.x - lastLookup.x, p.y - lastLookup.y) >= 2 {
                lastLookup = p
                let o = shot.globalOffset
                ElementFinder.shared.find(at: CGPoint(x: p.x + o.x, y: p.y + o.y), pid: top.pid) { [weak self] rects in
                    guard let self, self.phase == .select else { return }
                    self.elements = rects.map { $0.offsetBy(dx: -o.x, dy: -o.y) }
                    self.computeChain(self.mouse, lookUp: false)
                    self.needsDisplay = true
                }
            }
        } else {
            elements = []
        }
        if !list.contains(screenBounds) { list.append(screenBounds) }
        if list != chain { chain = list; chainIndex = 0; animateHole(to: hover) }
    }

    func mouseAt(_ p: CGPoint) {
        mouse = p
        if phase == .select { computeChain(p); needsDisplay = true }   // the highlight and the magnifier follow
        else if Date() < sizeHUDUntil { needsDisplay = true }           // the size preview follows
    }

    // MARK: mouse

    override func mouseEntered(with event: NSEvent) {
        if phase == .idle { return }
        if window?.isKeyWindow == false, case .none = drag { window?.makeKey(); window?.makeFirstResponder(self) }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if window?.isKeyWindow == false && phase != .idle { window?.makeKey() }
        mouseAt(p)
        updateCursor(p)
    }

    private func updateCursor(_ p: CGPoint) {
        switch phase {
        case .select: NSCursor.crosshair.set()
        case .idle: NSCursor.arrow.set()
        case .edit:
            if toolbar.frame.contains(p) && !toolbar.isHidden { NSCursor.arrow.set(); return }
            let handle = annotationHandle(at: p)
            let e = handle == nil ? edges(at: p) : 0
            if let (i, h) = handle {
                // the ends of a line move freely; a box corner resizes along its diagonal
                let a = annotations[i]
                if a.tool == .line || a.tool == .arrow { Cursors.move.set() }
                else { (h % 2 == 0 ? Cursors.resizeNWSE : Cursors.resizeNESW).set() }
            } else if e != 0 {
                if e == Self.edgeL || e == Self.edgeR { NSCursor.resizeLeftRight.set() }
                else if e == Self.edgeT || e == Self.edgeB { NSCursor.resizeUpDown.set() }
                else if e == Self.edgeL | Self.edgeT || e == Self.edgeR | Self.edgeB { Cursors.resizeNWSE.set() }
                else { Cursors.resizeNESW.set() }
            } else if annotationIndex(at: p) != nil {
                Cursors.move.set()                         // a drawing: drag to move it
            } else if let t = tool {
                (t == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
            } else if selection.contains(p) {
                Cursors.move.set()                         // the capture area: drag to move it
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        downAt = p; dragged = false; mouse = p
        switch phase {
        case .idle: return
        case .select:
            drag = .newSelection
        case .edit:
            if textView != nil { commitText(); if tool == .text { drag = .none; return } }
            pendingUndo = annotations
            if let (i, h) = annotationHandle(at: p) {
                drag = .dragHandle(i, h, annotations[i])
                return
            }
            if let i = annotationIndex(at: p) {
                if event.clickCount == 2 && annotations[i].tool == .text { editText(i); return }
                select(i)
                drag = .moveAnnotation(i, p, annotations[i])
                return
            }
            selected = nil
            let e = edges(at: p)
            if e != 0 {
                drag = .resize(e, selection); toolbar.isHidden = true
            } else if let t = tool, selection.insetBy(dx: -2, dy: -2).contains(p) {
                switch t {
                case .text:
                    beginText(at: p)
                    drag = .none
                case .number:
                    let n = (annotations.filter { $0.tool == .number }.map(\.number).max() ?? 0) + 1
                    push(Annotation(tool: .number, color: Palette.colors[colorIndex], width: width, points: [p], number: n))
                    drag = .none
                default:
                    current = Annotation(tool: t, color: Palette.colors[colorIndex], width: width,
                                         mosaicMode: mosaicMode, solid: mosaicSolid, points: [p, p])
                    if current?.isStrokeLike == true { current?.points = [p] }
                    drag = .draw
                }
            } else if tool == nil && selection.contains(p) {
                if event.clickCount == 2 { command(.ok); return }
                drag = .move(p, selection); toolbar.isHidden = true
            } else {
                drag = .none
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        mouse = p
        if hypot(p.x - downAt.x, p.y - downAt.y) > 3 { dragged = true }
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .newSelection:
            if dragged { selection = CGRect(downAt, p) }
        case .move(let start, let orig):
            var r = orig.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(0, r.minX), bounds.width - r.width)
            r.origin.y = min(max(0, r.minY), bounds.height - r.height)
            selection = r
        case .resize(let e, let orig):
            var x0 = orig.minX, y0 = orig.minY, x1 = orig.maxX, y1 = orig.maxY
            if e & Self.edgeL != 0 { x0 = p.x }
            if e & Self.edgeR != 0 { x1 = p.x }
            if e & Self.edgeT != 0 { y0 = p.y }
            if e & Self.edgeB != 0 { y1 = p.y }
            selection = CGRect(CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1))
        case .draw:
            guard var a = current else { break }
            let q = clamp(p, to: selection)
            if a.isStrokeLike {
                if let last = a.points.last, hypot(q.x - last.x, q.y - last.y) >= 1 { a.points.append(q) }
            } else {
                a.points[1] = shift ? constrain(a.points[0], q, a.tool) : q
            }
            current = a
        case .moveAnnotation(let i, let start, let orig):
            guard i < annotations.count else { break }
            keepUndo()
            var a = orig
            a.offset(p.x - start.x, p.y - start.y)
            annotations[i] = a
        case .dragHandle(let i, let h, let orig):
            guard i < annotations.count else { break }
            keepUndo()
            var a = orig
            let q = clamp(p, to: selection)
            let others = orig.handlePoints
            if shift, others.count == 2 { a.moveHandle(h, to: constrain(others[1 - h], q, a.tool)) }
            else { a.moveHandle(h, to: q) }
            annotations[i] = a
        case .none: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let d = drag
        drag = .none
        switch d {
        case .newSelection:
            if !dragged || selection.width < 2 || selection.height < 2 { selection = hover ?? bounds }
            selection = selection.integral.intersection(bounds)
            enterEdit()
        case .move, .resize:
            if selection.width < 2 || selection.height < 2 { selection = selection.insetBy(dx: -1, dy: -1) }
            placeToolbar()
        case .draw:
            if let a = current {
                let ok = a.isStrokeLike ? true : hypot(a.points[0].x - a.points[1].x, a.points[0].y - a.points[1].y) > 2
                if ok { push(a) }
            }
            current = nil
        case .moveAnnotation, .dragHandle, .none: break
        }
        pendingUndo = nil
        updateCursor(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        switch phase {
        case .edit:
            // back to choosing an area; what was drawn is dropped
            commitText()
            annotations.removeAll(); undoStack.removeAll(); redoStack.removeAll(); current = nil; selected = nil
            phase = .select; toolbar.isHidden = true; toolbar.select(nil)
            holeShown = nil; chain = []
            mouseAt(convert(event.locationInWindow, from: nil))
        default:
            session?.finish()
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if phase == .edit { command(.pin) }
        else if phase == .select, let h = hover { selection = h; enterEdit(); command(.pin) }
    }

    override func scrollWheel(with event: NSEvent) {
        if phase == .edit, selected != nil || tool != nil { scrollWidth(event); return }
        guard phase == .select, !chain.isEmpty else { return }
        // a wheel notch is one step; on a trackpad a step takes a deliberate swipe
        let steps = scrollSteps(event, trackpadDistance: 30)
        guard steps != 0 else { return }
        chainIndex = min(max(chainIndex + steps, 0), chain.count - 1)
        animateHole(to: hover)
        needsDisplay = true
    }

    /// Whole steps from a scroll: one per wheel notch; on a trackpad one per `trackpadDistance`
    /// points of swipe. Up is positive whatever the system's scroll direction; the coasting after
    /// the fingers lift is ignored, so nothing keeps changing once you stop.
    private func scrollSteps(_ e: NSEvent, trackpadDistance: CGFloat) -> Int {
        guard e.momentumPhase.isEmpty else { return 0 }
        var dy = e.scrollingDeltaY
        if e.isDirectionInvertedFromDevice { dy = -dy }
        if !e.hasPreciseScrollingDeltas { return abs(dy) > 0.1 ? (dy > 0 ? 1 : -1) : 0 }
        if e.phase == .began || e.phase == .mayBegin { scrollSum = 0 }
        scrollSum += dy
        var steps = 0
        while scrollSum >= trackpadDistance { steps += 1; scrollSum -= trackpadDistance }
        while scrollSum <= -trackpadDistance { steps -= 1; scrollSum += trackpadDistance }
        return steps
    }

    /// With a tool, the wheel (or two fingers up / down on a trackpad) sets its width: border,
    /// line, arrow, text and number size, mosaic squares. Up makes it bigger, whichever way the
    /// system's scrolling direction is set.
    private func scrollWidth(_ e: NSEvent) {
        let steps = scrollSteps(e, trackpadDistance: 8)
        guard steps != 0 else { return }
        // the selected annotation, else the tool's next drawing
        let target: Annotation? = selected.map { annotations[$0] }
        if let a = target, !a.hasWidth { return }
        if target == nil, let t = tool, t == .mosaic && mosaicMode != .brush { return }
        let t = target?.tool ?? tool ?? .rect
        var w = target?.width ?? width
        for _ in 0..<abs(steps) {
            let step: CGFloat = w >= 10 ? 2 : 1          // finer when thin
            w += steps > 0 ? step : -step
        }
        w = min(max(w.rounded(), Palette.widthRange.lowerBound), Annotation.maxWidth(t))
        if let i = selected {
            // one undo step per gesture: a pause of half a second starts a new one
            if Date().timeIntervalSince(lastScrollEdit) > 0.5 { saveUndo() }
            lastScrollEdit = Date()
            annotations[i].width = w
        }
        setWidth(w, preview: true)
    }

    private func setWidth(_ w: CGFloat, preview: Bool) {
        width = w
        Prefs.shared.strokeWidth = w
        toolbar.setWidth(w)
        restyleText()
        if preview {
            sizeHUDUntil = Date().addingTimeInterval(0.9)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in self?.needsDisplay = true }
        }
        needsDisplay = true
    }

    /// The width preview: what the tool will draw, at the mouse, with its size in pixels.
    private func drawSizeHUD(_ ctx: CGContext) {
        guard phase == .edit, Date() < sizeHUDUntil,
              let t = selected.map({ annotations[$0].tool }) ?? tool else { return }
        let c = selected.map { annotations[$0].color } ?? Palette.colors[colorIndex]
        let d: CGFloat
        switch t {
        case .text: d = Annotation.fontSize(for: width)
        case .number: d = (8 + width * 1.6) * 2
        case .marker: d = width * 4
        case .mosaic: d = Annotation.brushWidth(width)
        default: d = width
        }
        let r = CGRect(x: mouse.x - d / 2, y: mouse.y - d / 2, width: d, height: d)
        if t == .text {
            // text: a sample at its size and color
            let sample = NSAttributedString(string: "Aa", attributes: Annotation.textAttributes(color: c, size: d))
            let sz = sample.size()
            let box = CGRect(x: mouse.x - sz.width / 2 - 6, y: mouse.y - sz.height / 2 - 2, width: sz.width + 12, height: sz.height + 4)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            sample.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2))
            drawHUDLabel("\(Int(d.rounded())) pt", below: box)
            return
        }
        ctx.saveGState()
        if t == .mosaic && !(selected.map { annotations[$0].solid } ?? mosaicSolid) {
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5)
            ctx.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.stroke(r)
        } else {
            ctx.setFillColor(c.cgColor)
            ctx.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.fillEllipse(in: r)
        }
        ctx.restoreGState()
        drawHUDLabel("\(Int(width)) px", below: r)
    }

    private func drawHUDLabel(_ label: String, below r: CGRect) {
        let str = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
        let sz = str.size()
        let box = CGRect(x: mouse.x - sz.width / 2 - 6, y: r.maxY + 6, width: sz.width + 12, height: sz.height + 4)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        str.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2))
    }

    // MARK: keys

    override func keyDown(with e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = f.contains(.command), shift = f.contains(.shift)
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch Int(e.keyCode) {
        case 0x35: // Esc: let go of the selected annotation first, then cancel
            if selected != nil { selected = nil; return }
            session?.finish(); return
        case 0x33, 0x75: // Delete, Forward Delete: remove the selected annotation
            if let i = selected { saveUndo(); annotations.remove(at: i); selected = nil; needsDisplay = true }
            return
        case 0x24, 0x4C: // Return, Enter
            if phase == .select, let h = hover { selection = h; enterEdit(after: false) }
            if phase == .edit { command(.ok) }
            return
        case 0x7B: nudge(-1, 0, shift); return
        case 0x7C: nudge(1, 0, shift); return
        case 0x7E: nudge(0, -1, shift); return
        case 0x7D: nudge(0, 1, shift); return
        default: break
        }
        if cmd {
            switch chars {
            case "z": shift ? command(.redo) : command(.undo)
            case "s": command(.save)
            case "t": command(.pin)
            case "o": command(.ocr)
            case "c": shift ? command(.ocrCopy) : command(.ok)
            case "q", "w": session?.finish()
            default: break
            }
            return
        }
        switch chars {
        case "w": nudge(0, -1, shift)
        case "a": nudge(-1, 0, shift)
        case "s": nudge(0, 1, shift)
        case "d": nudge(1, 0, shift)
        case "c" where phase == .select:
            if let c = pixelColor(at: mouse) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(c.hexString, forType: .string)
                Toast.show(L.t("copied") + " " + c.hexString)
            }
        default: break
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if textView != nil { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command), window?.firstResponder === self { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Arrow keys and W A S D: the cursor while choosing, the selection while editing.
    private func nudge(_ dx: CGFloat, _ dy: CGFloat, _ ten: Bool) {
        let k: CGFloat = (ten ? 10 : 1) / shot.scale
        if phase == .select {
            let p = clamp(CGPoint(x: mouse.x + dx * k, y: mouse.y + dy * k))
            let f = shot.screen.frame
            let primaryH = NSScreen.screens.first?.frame.height ?? f.height
            CGWarpMouseCursorPosition(CGPoint(x: f.minX + p.x, y: primaryH - f.maxY + p.y))
            mouseAt(p)
        } else if phase == .edit {
            var r = selection.offsetBy(dx: dx * k, dy: dy * k)
            r.origin.x = min(max(0, r.minX), bounds.width - r.width)
            r.origin.y = min(max(0, r.minY), bounds.height - r.height)
            selection = r
            placeToolbar()
            needsDisplay = true
        }
    }

    // MARK: editing

    private func enterEdit(after act: Bool = true) {
        stopHoleAnimation()
        phase = .edit
        session?.editing(on: self)
        toolbar.isHidden = false
        toolbar.setEnabled(.undo, false); toolbar.setEnabled(.redo, false)
        placeToolbar()
        needsDisplay = true
        guard act, let mode = session?.mode else { return }
        if mode == .ocr { command(.ocr) } else if mode == .ocrCopy { command(.ocrCopy) }
    }

    private func setTool(_ t: Tool?) {
        commitText()
        if let i = selected, annotations[i].tool != t { selected = nil }
        tool = t
        placeToolbar()
        updateCursor(mouse)
    }

    /// Adds a new annotation and selects it, so the wheel or a color can still change it.
    private func push(_ a: Annotation) {
        saveUndo()
        annotations.append(a)
        selected = annotations.count - 1
    }

    private func saveUndo() {
        undoStack.append(annotations)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshUndo()
    }

    /// The state from mouse down becomes an undo step at the first real change of a drag.
    private func keepUndo() {
        guard let s = pendingUndo else { return }
        pendingUndo = nil
        undoStack.append(s)
        redoStack.removeAll()
        refreshUndo()
    }

    private func refreshUndo() {
        toolbar.setEnabled(.undo, !undoStack.isEmpty)
        toolbar.setEnabled(.redo, !redoStack.isEmpty)
    }

    // MARK: editing annotations

    /// The topmost annotation under `p`.
    private func annotationIndex(at p: CGPoint) -> Int? {
        guard phase == .edit, drag.isIdle else { return nil }
        return annotations.indices.reversed().first { annotations[$0].hit(p) }
    }

    /// An end or a corner of the selected annotation under `p`.
    private func annotationHandle(at p: CGPoint) -> (Int, Int)? {
        guard phase == .edit, let i = selected, i < annotations.count else { return nil }
        guard let h = annotations[i].handlePoints.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= 7 }) else { return nil }
        return (i, h)
    }

    /// Selects annotation `i` and shows its settings: its tool, color, size and mosaic mode.
    private func select(_ i: Int) {
        let a = annotations[i]
        if toolbar.tool != a.tool { toolbar.select(a.tool) }
        selected = i
        width = a.width
        toolbar.setWidth(a.width)
        if a.tool == .mosaic {
            mosaicMode = a.mosaicMode
            mosaicSolid = a.solid
            toolbar.setMosaicMode(a.mosaicMode, notify: false)
            toolbar.setMosaicSolid(a.solid, notify: false)
        }
        if a.hasColor, let c = Palette.colors.firstIndex(of: a.color) {
            colorIndex = c
            toolbar.setColor(c)
        }
    }

    private func pickColor(_ i: Int) {
        colorIndex = i
        Prefs.shared.colorIndex = i
        restyleText()
        guard let k = selected else { return }
        var a = annotations[k]
        if a.tool == .mosaic { a.solid = true }              // a hide box or stroke: now in this color
        saveUndo()
        a.color = Palette.colors[i]
        annotations[k] = a
    }

    /// Box or brush, for the next hide (a drawn box cannot become a stroke): lets go of a selected one.
    private func pickMosaicMode(_ m: MosaicMode) {
        mosaicMode = m
        if let k = selected, annotations[k].tool == .mosaic, annotations[k].mosaicMode != m { selected = nil }
    }

    /// Mosaic or color: for the next hide, and for a selected one.
    private func pickMosaicSolid(_ on: Bool) {
        mosaicSolid = on
        guard let k = selected, annotations[k].tool == .mosaic, annotations[k].solid != on else { return }
        saveUndo()
        annotations[k].solid = on
        if on { annotations[k].color = Palette.colors[colorIndex] }
    }

    /// Double-click on a text: edit it again, where it is, with its color and size.
    private func editText(_ i: Int) {
        let a = annotations[i]
        saveUndo()
        annotations.remove(at: i)
        selected = nil
        if let c = Palette.colors.firstIndex(of: a.color) { colorIndex = c; toolbar.setColor(c) }
        width = a.width
        toolbar.setWidth(a.width)
        beginText(at: a.points[0], origin: a.points[0], text: a.text)
    }

    /// Handles and outline of the selected annotation.
    private func drawSelectionMarks(_ ctx: CGContext) {
        guard let i = selected, i < annotations.count, current == nil else { return }
        let a = annotations[i]
        let hs = a.handlePoints
        ctx.saveGState()
        if hs.isEmpty || a.tool == .rect || a.tool == .ellipse {
            ctx.setStrokeColor(Palette.accent.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            let pad: CGFloat = a.tool == .rect || a.tool == .ellipse ? a.width / 2 + 3 : 4
            ctx.stroke(a.bounds.insetBy(dx: -pad, dy: -pad))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        for h in hs {
            let r = CGRect(x: snap(h.x) - 5, y: snap(h.y) - 5, width: 10, height: 10)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.fillEllipse(in: r)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(Palette.accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: r.insetBy(dx: 0.75, dy: 0.75))
        }
        ctx.restoreGState()
    }

    private func placeToolbar() {
        guard phase == .edit else { toolbar.isHidden = true; return }
        toolbar.isHidden = false
        let w = toolbar.frame.width, h = toolbar.frame.height
        var x = selection.maxX - w
        x = min(max(4, x), bounds.width - w - 4)
        var y = selection.maxY + 8
        var above = false
        if y + h > bounds.height - 4 {
            y = selection.minY - 8 - h
            above = true
            if y < 4 { y = selection.maxY - h - 8; above = false }
        }
        toolbar.setPaletteAbove(above)
        toolbar.frame.origin = CGPoint(x: snap(x), y: snap(y))
    }

    private func edges(at p: CGPoint) -> Int {
        guard phase == .edit else { return 0 }
        let r = selection, m: CGFloat = 6
        guard r.insetBy(dx: -m, dy: -m).contains(p) else { return 0 }
        var e = 0
        if abs(p.x - r.minX) <= m { e |= Self.edgeL } else if abs(p.x - r.maxX) <= m { e |= Self.edgeR }
        if abs(p.y - r.minY) <= m { e |= Self.edgeT } else if abs(p.y - r.maxY) <= m { e |= Self.edgeB }
        // with a tool, only the corner and middle handles resize, so drawing near an edge still works
        if tool != nil && e != 0 {
            let hs = handles().contains { hypot($0.x - p.x, $0.y - p.y) <= m }
            if !hs { return 0 }
        }
        return e
    }

    private func handles() -> [CGPoint] {
        let r = selection
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    private func clamp(_ p: CGPoint, to r: CGRect? = nil) -> CGPoint {
        let b = r ?? bounds
        return CGPoint(x: min(max(b.minX, p.x), b.maxX), y: min(max(b.minY, p.y), b.maxY))
    }

    private func constrain(_ a: CGPoint, _ b: CGPoint, _ t: Tool) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        if t == .rect || t == .ellipse || t == .mosaic {
            let s = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -s : s), y: a.y + (dy < 0 ? -s : s))
        }
        let ang = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let len = hypot(dx, dy)
        return CGPoint(x: a.x + cos(ang) * len, y: a.y + sin(ang) * len)
    }

    // MARK: text

    private func beginText(at p: CGPoint, origin: CGPoint? = nil, text: String = "") {
        let o = origin ?? CGPoint(x: p.x, y: p.y - Annotation.fontSize(for: width) * 0.6)
        let tv = NSTextView(frame: NSRect(x: o.x, y: o.y, width: 20, height: 20))
        tv.string = text
        tv.drawsBackground = false
        tv.isRichText = false
        TextInput.quiet(tv)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.minSize = NSSize(width: 20, height: 20)
        tv.wantsLayer = true
        tv.layer?.borderColor = Palette.accent.withAlphaComponent(0.8).cgColor
        tv.layer?.borderWidth = 1
        tv.delegate = self
        addSubview(tv)
        textView = tv
        restyleText()
        tv.sizeToFit()
        window?.makeFirstResponder(tv)
    }

    private func restyleText() {
        guard let tv = textView else { return }
        let attrs = Annotation.textAttributes(color: Palette.colors[colorIndex], size: Annotation.fontSize(for: width))
        tv.typingAttributes = attrs
        tv.textStorage?.setAttributes(attrs, range: NSRange(location: 0, length: tv.string.utf16.count))
        tv.insertionPointColor = Palette.colors[colorIndex]
        tv.sizeToFit()
    }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(cancelOperation(_:)) { commitText(); return true }
        return false
    }

    private func commitText() {
        guard let tv = textView else { return }
        textView = nil
        let s = tv.string
        if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            push(Annotation(tool: .text, color: Palette.colors[colorIndex], width: width,
                            points: [tv.frame.origin], text: s))
        }
        tv.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: commands

    private func command(_ c: Toolbar.Command) {
        switch c {
        case .undo:
            commitText()
            if let prev = undoStack.popLast() { redoStack.append(annotations); annotations = prev; selected = nil }
            refreshUndo(); needsDisplay = true
        case .redo:
            if let next = redoStack.popLast() { undoStack.append(annotations); annotations = next; selected = nil }
            refreshUndo(); needsDisplay = true
        case .close:
            session?.finish()
        case .ocr where !Prefs.shared.ocrEnabled, .ocrCopy where !Prefs.shared.ocrEnabled:
            return
        default:
            guard phase == .edit, let img = render() else { return }
            let rect = globalSelection()
            let size = selection.size
            session?.finish()
            switch c {
            case .ok: Clipboard.copy(img, size: size); Toast.show(L.t("copied"))
            case .save: Saver.save(img, size: size)
            case .pin: PinWindow.show(img, frame: rect)
            case .ocr: OCR.recognize(img) { text in OCRPanel.show(text, near: rect) }
            case .ocrCopy:
                OCR.recognize(img) { text in
                    if text.plain.isEmpty { Toast.show(L.t("noText")); return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text.plain, forType: .string)
                    Toast.show(L.t("textCopied"))
                }
            default: break
            }
        }
    }

    /// The selection in global Cocoa coordinates (bottom-left origin).
    private func globalSelection() -> CGRect {
        let f = shot.screen.frame
        return CGRect(x: f.minX + selection.minX, y: f.maxY - selection.maxY, width: selection.width, height: selection.height)
    }

    /// The selection with its annotations, at full pixel resolution.
    func render() -> CGImage? {
        commitText()
        let s = shot.scale
        let px = CGRect(x: (selection.minX * s).rounded(), y: (selection.minY * s).rounded(),
                        width: (selection.width * s).rounded(), height: (selection.height * s).rounded())
            .intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
        guard px.width >= 1, px.height >= 1, let base = shot.image.cropping(to: px) else { return nil }
        if annotations.isEmpty { return base }
        let W = Int(px.width), H = Int(px.height)
        let cs = shot.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: -px.minX / s, y: -px.minY / s)
        ctx.clip(to: selection)
        for a in annotations { a.draw(in: ctx, mosaic: mosaicImage, screenRect: bounds) }
        return ctx.makeImage()
    }

    // MARK: drawing

    /// Device pixels per point of this screen: 2 on Retina, 1 on most external displays.
    private var pixelScale: CGFloat { window?.backingScaleFactor ?? shot.scale }
    private func snap(_ v: CGFloat) -> CGFloat { (v * pixelScale).rounded() / pixelScale }
    /// A rectangle on whole device pixels, so its edges are sharp at 1x as at 2x.
    private func snap(_ r: CGRect) -> CGRect {
        let x0 = snap(r.minX), y0 = snap(r.minY)
        return CGRect(x: x0, y: y0, width: snap(r.maxX) - x0, height: snap(r.maxY) - y0)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var hole: CGRect?
        switch phase {
        case .select:
            if case .newSelection = drag, dragged { hole = selection } else { hole = holeShown ?? hover }
        case .edit: hole = selection
        case .idle: hole = nil
        }

        hole = hole.map(snap)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        if let h = hole {
            ctx.addRect(bounds); ctx.addRect(h)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }
        guard let h = hole else { return }

        if phase == .edit {
            ctx.saveGState()
            ctx.clip(to: h)
            for a in annotations { a.draw(in: ctx, mosaic: mosaicImage, screenRect: bounds) }
            current?.draw(in: ctx, mosaic: mosaicImage, screenRect: bounds)
            ctx.restoreGState()
            drawSelectionMarks(ctx)
            drawSizeHUD(ctx)
        }

        // the border: whole device pixels (3 on Retina, 2 at 1x) just outside the area
        let lw = (pixelScale >= 2 ? 3 : 2) / pixelScale
        ctx.setStrokeColor(Palette.accent.cgColor)
        ctx.setLineWidth(lw)
        ctx.stroke(h.insetBy(dx: -lw / 2, dy: -lw / 2))
        if phase == .edit {
            // handles: white dots ringed in the accent color, centered on whole pixels
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 1.5, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            for p in handles() {
                let c = CGPoint(x: snap(p.x), y: snap(p.y))
                ctx.setFillColor(Palette.accent.cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
            }
            ctx.restoreGState()
            ctx.setFillColor(NSColor.white.cgColor)
            for p in handles() {
                let c = CGPoint(x: snap(p.x), y: snap(p.y))
                ctx.fillEllipse(in: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5))
            }
        }

        drawSizeLabel(h)
        var showMag = phase == .select
        if case .resize = drag { showMag = true }
        if showMag { drawMagnifier(ctx) }
    }

    private func drawSizeLabel(_ r: CGRect) {
        let s = "\(Int((r.width * shot.scale).rounded())) × \(Int((r.height * shot.scale).rounded()))"
        let str = NSAttributedString(string: s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                             .foregroundColor: NSColor.white])
        let sz = str.size()
        var box = CGRect(x: r.minX, y: r.minY - sz.height - 10, width: sz.width + 12, height: sz.height + 6)
        if box.minY < 2 { box.origin.y = r.minY + 4; box.origin.x = r.minX + 4 }
        box.origin.x = min(box.minX, bounds.width - box.width - 2)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        str.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }

    private func pixelColor(at p: CGPoint) -> NSColor? {
        shot.image.color(atPixel: Int(p.x * shot.scale), Int(p.y * shot.scale))
    }

    private func drawMagnifier(_ ctx: CGContext) {
        let cols = 25, rows = 19, cell: CGFloat = 5
        let mw = CGFloat(cols) * cell, mh = CGFloat(rows) * cell
        let info: CGFloat = 50
        var x = mouse.x + 20, y = mouse.y + 24
        if x + mw > bounds.width - 4 { x = mouse.x - 20 - mw }
        if y + mh + info > bounds.height - 4 { y = mouse.y - 24 - mh - info }
        let box = CGRect(x: x, y: y, width: mw, height: mh)

        let cx = Int(mouse.x * shot.scale), cy = Int(mouse.y * shot.scale)
        let src = CGRect(x: cx - cols / 2, y: cy - rows / 2, width: cols, height: rows)
        let imgRect = CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height)
        let clipped = src.intersection(imgRect)
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(box)
        if !clipped.isNull, let part = shot.image.cropping(to: clipped) {
            let dst = CGRect(x: box.minX + (clipped.minX - src.minX) * cell, y: box.minY + (clipped.minY - src.minY) * cell,
                             width: clipped.width * cell, height: clipped.height * cell)
            ctx.interpolationQuality = .none
            ctx.drawFlipped(part, in: dst)
        }
        // the pixel under the cursor
        ctx.setStrokeColor(Palette.accent.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(cell)
        let mx = box.minX + CGFloat(cols / 2) * cell + cell / 2, my = box.minY + CGFloat(rows / 2) * cell + cell / 2
        ctx.strokeLineSegments(between: [CGPoint(x: box.minX, y: my), CGPoint(x: mx - cell / 2, y: my),
                                         CGPoint(x: mx + cell / 2, y: my), CGPoint(x: box.maxX, y: my),
                                         CGPoint(x: mx, y: box.minY), CGPoint(x: mx, y: my - cell / 2),
                                         CGPoint(x: mx, y: my + cell / 2), CGPoint(x: mx, y: box.maxY)])
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: mx - cell / 2, y: my - cell / 2, width: cell, height: cell))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.stroke(box)
        ctx.restoreGState()

        let ib = CGRect(x: box.minX, y: box.maxY, width: mw, height: info)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(rect: ib).fill()
        let col = pixelColor(at: mouse)
        let lines = ["\(cx), \(cy)", col?.hexString ?? "", L.t("copyColor")]
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                                                    .foregroundColor: NSColor.white]
        for (i, l) in lines.enumerated() {
            NSAttributedString(string: l, attributes: attrs).draw(at: CGPoint(x: ib.minX + (i == 1 ? 20 : 6), y: ib.minY + 3 + CGFloat(i) * 15))
        }
        if let col {
            col.setFill()
            let sw = NSRect(x: ib.minX + 6, y: ib.minY + 19, width: 10, height: 10)
            sw.fill()
            NSColor.white.setStroke(); NSBezierPath(rect: sw).stroke()
        }
    }
}

extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

private extension OverlayView.Drag {
    var isIdle: Bool { if case .none = self { return true }; return false }
}

/// Cursors macOS does not offer publicly: the four-way move arrow and the diagonal resize arrows.
/// Drawn as vector paths in the style of the system's cursors (black, an even white outline, a
/// soft shadow) and rendered into a 1x and a 2x bitmap, so they are sharp on every display.
enum Cursors {
    static let move = make { moveArrows() }
    static let resizeNWSE = make { doubleArrow(angle: -.pi / 4) }   // ↖↘ (y grows downward when drawn)
    static let resizeNESW = make { doubleArrow(angle: .pi / 4) }    // ↗↙

    private static let side: CGFloat = 22      // points; the hot spot is the middle

    /// One closed outline through the given points, turned by `angle` about the middle. A single
    /// outline has no inner seams, so the white edge runs only around the outside.
    private static func outline(_ pts: [CGPoint], angle: CGFloat = 0) -> NSBezierPath {
        let p = NSBezierPath()
        let c = side / 2, ca = cos(angle), sa = sin(angle)
        for (i, q) in pts.enumerated() {
            let r = NSPoint(x: c + q.x * ca - q.y * sa, y: c + q.x * sa + q.y * ca)
            if i == 0 { p.move(to: r) } else { p.line(to: r) }
        }
        p.close()
        return p
    }

    /// Four arrows from the middle: thin shafts, solid heads, as one outline.
    private static func moveArrows() -> NSBezierPath {
        let w: CGFloat = 1, reach: CGFloat = 8, hl: CGFloat = 3.2, hw: CGFloat = 2.6
        var pts: [CGPoint] = []
        for k in 0..<4 {
            let arm = [CGPoint(x: w, y: -w), CGPoint(x: reach - hl, y: -w), CGPoint(x: reach - hl, y: -hw),
                       CGPoint(x: reach, y: 0), CGPoint(x: reach - hl, y: hw), CGPoint(x: reach - hl, y: w)]
            let a = CGFloat(k) * .pi / 2
            pts += arm.map { CGPoint(x: $0.x * cos(a) - $0.y * sin(a), y: $0.x * sin(a) + $0.y * cos(a)) }
        }
        return outline(pts)
    }

    /// A double-headed arrow through the middle, turned by `angle`, as one outline.
    private static func doubleArrow(angle: CGFloat) -> NSBezierPath {
        let w: CGFloat = 1.1, reach: CGFloat = 9, hl: CGFloat = 4.2, hw: CGFloat = 3.5
        return outline([CGPoint(x: -reach, y: 0), CGPoint(x: -reach + hl, y: hw), CGPoint(x: -reach + hl, y: w),
                        CGPoint(x: reach - hl, y: w), CGPoint(x: reach - hl, y: hw), CGPoint(x: reach, y: 0),
                        CGPoint(x: reach - hl, y: -hw), CGPoint(x: reach - hl, y: -w),
                        CGPoint(x: -reach + hl, y: -w), CGPoint(x: -reach + hl, y: -hw)], angle: angle)
    }

    private static func make(_ shape: () -> NSBezierPath) -> NSCursor {
        let path = shape()
        let image = NSImage(size: NSSize(width: side, height: side))
        for scale in [CGFloat(1), 2] {
            let px = Int(side * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: side, height: side)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // outline first (a wide white stroke under a soft shadow), then the black shape on it
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()
            NSColor.white.setStroke()
            path.lineWidth = 2.2
            path.lineJoinStyle = .round
            path.stroke()
            NSShadow().set()
            NSColor.white.setFill()
            path.fill()
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}
