import AppKit
import Vision
import ImageIO
import CoreML

/// Recognized text: plain (columns separated by tabs, so a table pastes into a spreadsheet as cells)
/// and, when it looks like a table, Markdown.
struct OCRText {
    var plain: String
    var markdown: String?
}

/// Text recognition with Apple's Vision framework, entirely on this Mac (no module to install).
enum OCR {
    /// The recognition languages: Chinese of the system's kind and English. Fewer languages and no
    /// language detection keep a recognition well under a second.
    private static var languages: [String] {
        let first = L.current == .zhHant ? "zh-Hant" : "zh-Hans"
        var langs = [first, "en-US"]
        let pref = Locale.preferredLanguages.first ?? ""
        if pref.hasPrefix("ja") { langs.insert("ja-JP", at: 0) }
        if pref.hasPrefix("ko") { langs.insert("ko-KR", at: 0) }
        return langs
    }

    private static func request() -> VNRecognizeTextRequest {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = false
        req.recognitionLanguages = languages
        // the CPU: the Neural Engine first compiles the model, which takes 30-60 s after every
        // install or update; on the CPU a recognition starts at once and takes well under a second
        if ProcessInfo.processInfo.environment["SNIPLITE_OCR_ANE"] == nil,
           let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { return true }; return false }) {
            for stage in [VNComputeStage.main, .postProcessing] { req.setComputeDevice(cpu, for: stage) }
        }
        return req
    }

    /// Runs in the helper process (`sniplite --ocr-helper <png>`): prints one line per piece of
    /// text, "x y w h<TAB>text" in pixels from the top left, then exits.
    static func helperMain(_ path: String) -> Int32 {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return 1 }
        let req = request()
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        var out = ""
        for o in req.results ?? [] {
            guard let s = o.topCandidates(1).first?.string else { continue }
            let b = o.boundingBox  // normalized, bottom-left origin
            let w = CGFloat(img.width), h = CGFloat(img.height)
            let line = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            out += String(format: "%.1f %.1f %.1f %.1f\t", b.minX * w, (1 - b.maxY) * h, b.width * w, b.height * h) + line + "\n"
        }
        FileHandle.standardOutput.write(out.data(using: .utf8) ?? Data())
        return 0
    }

    /// Recognizes in a child process: Vision keeps its models (over 100 MB) for the life of the
    /// process that used them, so they go away with the helper instead of staying in sniplite.
    static func recognize(_ img: CGImage, done: @escaping (OCRText) -> Void) {
        Toast.show(L.t("reading"))
        DispatchQueue.global(qos: .userInteractive).async {
            let t = Date()
            var items: [(CGRect, String)] = []
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sniplite-ocr-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }
            if let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]),
               (try? png.write(to: url)) != nil, let exe = Bundle.main.executablePath {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = ["--ocr-helper", url.path]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                if (try? p.run()) != nil {
                    // a helper that hangs is stopped after 20 s (the recognition then finds nothing)
                    let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    watchdog.cancel()
                    for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
                        let parts = line.split(separator: "\t", maxSplits: 1)
                        guard parts.count == 2 else { continue }
                        let n = parts[0].split(separator: " ").compactMap { Double($0) }
                        guard n.count == 4 else { continue }
                        items.append((CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), String(parts[1])))
                    }
                }
            }
            let text = layout(items)
            Log.write(String(format: "OCR %.2fs", Date().timeIntervalSince(t)))
            DispatchQueue.main.async { Toast.hide(); done(text) }
        }
    }

    /// Puts the pieces into lines (by vertical overlap) and columns (by wide gaps).
    static func layout(_ items: [(CGRect, String)]) -> OCRText {
        let sorted = items.sorted { $0.0.midY < $1.0.midY }
        var lines: [[(CGRect, String)]] = []
        for it in sorted {
            if var last = lines.last, let ref = last.first {
                let top = max(ref.0.minY, it.0.minY), bot = min(ref.0.maxY, it.0.maxY)
                if bot - top > 0.5 * min(ref.0.height, it.0.height) {
                    last.append(it); lines[lines.count - 1] = last; continue
                }
            }
            lines.append([it])
        }
        var out: [[String]] = []
        for line in lines {
            let row = line.sorted { $0.0.minX < $1.0.minX }
            var cells: [String] = []
            var prev: CGRect?
            for (r, s) in row {
                if let p = prev, r.minX - p.maxX <= max(p.height, r.height) * 1.2, let a = cells.last {
                    let latin = (a.last.map { $0.isASCII } ?? false) && (s.first.map { $0.isASCII } ?? false)
                    cells[cells.count - 1] = a + (latin ? " " : "") + s
                } else {
                    cells.append(s)
                }
                prev = r
            }
            out.append(cells)
        }
        let plain = out.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        var md: String?
        let multi = out.filter { $0.count > 1 }
        if multi.count >= 2 {
            let cols = out.map(\.count).max() ?? 0
            var rows = out.map { r -> String in
                let cells = r + Array(repeating: "", count: cols - r.count)
                return "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
            }
            rows.insert("|" + Array(repeating: " --- |", count: cols).joined(), at: 1)
            md = rows.joined(separator: "\n")
        }
        return OCRText(plain: plain, markdown: md)
    }
}

/// The recognized text beside where it came from, to read, edit and copy.
final class OCRPanel: NSPanel {
    private static var open: [OCRPanel] = []
    private let textView = NSTextView()
    private let result: OCRText

    static func show(_ t: OCRText, near r: CGRect) {
        if t.plain.isEmpty { Toast.show(L.t("noText")); return }
        let p = OCRPanel(t, near: r)
        open.append(p)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(p.textView)
    }

    private init(_ t: OCRText, near r: CGRect) {
        result = t
        let w: CGFloat = 380, h: CGFloat = min(max(r.height, 220), 520)
        let vis = (NSScreen.screens.first { $0.frame.intersects(r) } ?? NSScreen.main)?.visibleFrame ?? r
        var x = r.maxX + 10
        if x + w > vis.maxX { x = r.minX - 10 - w }
        if x < vis.minX { x = max(vis.minX, min(r.minX, vis.maxX - w)) }
        var y = r.maxY - h
        y = min(max(vis.minY, y), vis.maxY - h)
        super.init(contentRect: NSRect(x: x, y: y, width: w, height: h),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        title = L.t("ocrTitle")
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        textView.isRichText = false
        TextInput.quiet(textView)
        textView.font = .systemFont(ofSize: 13)
        textView.string = t.plain
        textView.isEditable = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        let copy = NSButton(title: L.t("copyAll"), target: self, action: #selector(copyAll))
        copy.keyEquivalent = "\r"
        var buttons: [NSView] = [copy]
        if t.markdown != nil {
            buttons.insert(NSButton(title: L.t("copyMarkdown"), target: self, action: #selector(copyMarkdown)), at: 0)
        }
        let bar = NSStackView(views: [NSView()] + buttons)
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)

        let stack = NSStackView(views: [scroll, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        bar.setContentHuggingPriority(.required, for: .vertical)
        contentView = stack
        textView.frame = NSRect(x: 0, y: 0, width: w, height: h - 40)
    }

    @objc private func copyAll() {
        let s = textView.selectedRange().length > 0
            ? (textView.string as NSString).substring(with: textView.selectedRange()) : textView.string
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        Toast.show(L.t("copied"))
    }

    @objc private func copyMarkdown() {
        guard let md = result.markdown else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        Toast.show(L.t("copied"))
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        OCRPanel.open.removeAll { $0 === self }
        super.close()
    }
}
