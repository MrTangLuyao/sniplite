import AppKit

// the text recognition helper: no window, no menu bar icon, exits when done
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--ocr-helper" {
    exit(OCR.helperMain(CommandLine.arguments[2]))
}

// sniplite lives in the menu bar: no Dock icon (LSUIElement in Info.plist, and here for `swift run`).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
