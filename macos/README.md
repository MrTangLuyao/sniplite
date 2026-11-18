# sniplite for macOS

A native macOS version of sniplite, written in Swift and AppKit. It needs nothing besides the system: capture through ScreenCaptureKit, text recognition through Apple's Vision framework (on this Mac, with no module to download). The app is about 0.7 MB and runs on Apple Silicon and Intel Macs with macOS 14 Sonoma or later.

The Windows version (`../src`, x86-64 assembly and Win32) is unchanged; this folder is a separate program with the same features and shortcuts.

## Build

```bash
xcode-select --install      # once, if the Command Line Tools are not there
./build.sh                  # -> build/sniplite.app
./build.sh --zip            # also build/sniplite_<version>_macos.zip
```

Copy `build/sniplite.app` to `/Applications` and open it. The scissors icon appears in the menu bar; there is no Dock icon.

On first start a **Permissions** window lists what sniplite needs: **Screen Recording** (to capture) and **Accessibility** ("Device Control and Data Access" on macOS 27; for F1–F12 without fn and for picking parts of windows). Each button opens its page of System Settings with sniplite's icon in a panel below it: drag the icon into the list and turn it on. System Settings closes when the permission is granted, and the window when all are; sniplite restarts by itself after Screen Recording. The window is also in the menu (Permissions…). The build is signed ad hoc, so macOS asks again after every rebuild; `SIGN_ID="Developer ID Application: …" ./build.sh` signs with your own certificate. A downloaded copy that is not notarized has to be opened once with right-click › Open.

## Shortcuts

The same as on Windows, with ⌘ in place of Ctrl. They can be changed in Settings.

| Key | What it does |
| --- | --- |
| **F1** | Capture |
| **F3** | Pin the copied image or text to the screen |
| **⇧F3** | Hide / show all pins |
| **F4** | Capture and read the text (when text recognition is on) |
| **⇧F4** | Capture and copy the text |
| **Enter** / double-click | Copy the capture |
| **⌘S** | Save the capture (PNG or JPEG) |
| **⌘T** / middle click | Pin the capture to the screen |
| **⌘O** | Read the text of the selection |
| **⇧⌘C** | Copy the text of the selection |
| **⌘Z** / **⇧⌘Z** | Undo / redo |
| **Esc** | Cancel the capture |
| **Right click** | Back to choosing an area; once more to cancel |
| **Arrow keys**, **W A S D** | Move the cursor or the selection by one pixel; with Shift, by ten |
| **C** (while choosing) | Copy the color under the cursor |
| **Wheel** | Capturing: pick a bigger or smaller window; on a pin: zoom; ⌥ + wheel: pin opacity |
| **Double-click** / **Esc** | Close a pin |

On a Mac keyboard F1–F12 control brightness, Mission Control and so on. With the Accessibility permission sniplite takes those keys for its shortcuts, so F1 captures without fn (the key then no longer dims the screen); without it, press **fn** with them.

## What is the same and what is not

- The same: choosing an area or a window under the mouse, the magnifier with pixel colors, rectangle, ellipse, line, arrow, pen, marker, mosaic, text and numbers in eight colors and three sizes, undo / redo, copy, save, pins (move, zoom, copy, save, read text), text recognition with tables kept as columns (tab-separated, or Markdown), changeable shortcuts, open at login.
- Also: picking a part of a window (a button, a field, a list, a pane) through the Accessibility API; the wheel steps out to bigger parts, the window and the screen.
- Text recognition is off until turned on in Settings; it runs in a short-lived helper process, so Vision's models (over 100 MB) do not stay in memory. sniplite itself uses about 15–25 MB.
- Not yet: long screenshots, the command line, the update check.
- Languages: English, 简体中文 and 繁體中文, following the system unless one is picked in Settings.

## Code

| File | What it holds |
| --- | --- |
| `App.swift`, `main.swift` | the menu bar icon and menu, start-up |
| `HotKeys.swift` | global shortcuts (Carbon `RegisterEventHotKey`, no Accessibility permission needed) |
| `Capture.swift` | screenshots of every display (ScreenCaptureKit) and the window list for snapping |
| `Overlay.swift` | the capture overlay: choosing, editing, magnifier, rendering the result |
| `Annotation.swift`, `Toolbar.swift` | the drawing tools and the toolbar |
| `Pin.swift` | pins |
| `OCR.swift` | text recognition (Vision) and the text panel |
| `Elements.swift` | the parts of a window under the mouse (Accessibility API) |
| `TopRowKeys.swift` | F1–F12 without fn (an event tap) |
| `Permissions.swift` | the permissions window and the drag-to-authorize panel (after [PermissionFlow](https://github.com/jaywcjlove/PermissionFlow), MIT) |
| `Settings.swift`, `L10n.swift`, `Util.swift` | settings, texts, clipboard / save / notices, log (`~/Library/Logs/sniplite.log`) |
