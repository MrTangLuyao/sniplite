import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = status.button {
            let img = NSImage(systemSymbolName: "scissors", accessibilityDescription: "sniplite")
            img?.isTemplate = true
            b.image = img
            b.toolTip = "sniplite"
        }
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu

        Log.write("start \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "") screen recording \(Capture.hasPermission) accessibility \(AXIsProcessTrusted())")
        // an entry left by an earlier build (another signature) shows as switched on but does not
        // apply to this one: remove it, so the list never shows a sniplite that is not really allowed
        for p in Permission.allCases where !p.granted { p.resetStaleEntry() }
        HotKeyCenter.shared.handler = { a in AppDelegate.run(a) }
        HotKeyCenter.shared.registerAll()
        TopRowKeys.shared.update(prompt: false)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in Capture.invalidate(); Capture.prewarm() }
        Capture.prewarm()

        if CommandLine.arguments.contains("--capture") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { CaptureSession.start() }
        } else {
            PermissionsWindow.showIfNeeded()
        }
    }

    private static var last: (HotAction, Date)?

    static func run(_ a: HotAction) {
        // the event tap and the Carbon hotkey can both see one press: act once
        if let (la, t) = last, la == a, Date().timeIntervalSince(t) < 0.35 { return }
        last = (a, Date())
        Log.write("run \(a.rawValue)")
        if a.isOCR && !Prefs.shared.ocrEnabled { return }
        switch a {
        case .capture: CaptureSession.start(.normal)
        case .ocr: CaptureSession.start(.ocr)
        case .ocrCopy: CaptureSession.start(.ocrCopy)
        case .pinClipboard: PinWindow.pinClipboard()
        case .togglePins: PinWindow.toggleAll()
        }
    }

    /// The menu is rebuilt each time it opens, so shortcut changes show at once.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for a in HotAction.active {
            let i = ClosureMenuItem(title: a.title, key: "") { AppDelegate.last = nil; AppDelegate.run(a) }
            if let k = Prefs.shared.hotkey(a) {
                // shown as text: a real key equivalent would only work while the menu is open
                i.title = a.title + "\t" + k.display
            }
            menu.addItem(i)
            if a == .togglePins { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L.t("settings"), key: ",") { SettingsWindow.show() })
        let perm = ClosureMenuItem(title: L.t("permissions") + "…", key: "") { PermissionsWindow.show() }
        if !Permission.allRequiredGranted { perm.title = "⚠︎ " + perm.title }
        menu.addItem(perm)
        menu.addItem(ClosureMenuItem(title: L.t("about"), key: "") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [
                .credits: NSAttributedString(string: "https://github.com/MrTangLuyao/sniplite",
                                             attributes: [.font: NSFont.systemFont(ofSize: 11)]),
            ])
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L.t("quit"), key: "q") { NSApp.terminate(nil) })
    }

    static func askForPermission() { PermissionsWindow.show() }

    /// Starts a new sniplite and quits this one (a new Screen Recording permission needs it).
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
