<div align="center">

<img src="../pics/icon.png" width="96" alt="sniplite icon">

# sniplite for macOS

**The native macOS version of sniplite: capture, draw, pin and read text, in under 1 MB**

[English](README.md) • [简体中文](README.zh-CN.md)

</div>

A native port of sniplite to macOS, written in Swift and AppKit, with the features and shortcuts of the Windows version. It uses nothing but the system: ScreenCaptureKit to capture, the Accessibility API to find windows and their parts, Vision to read text. The app is under 1 MB, runs natively on Apple Silicon and Intel, and needs macOS 14 Sonoma or later.

The Windows version (`../src`) is unchanged; this folder is a separate program.

## Features

- **Capture**: press F1; the window or the part of a window under the mouse (a button, a field, a list, a pane) is found for you, and the wheel steps out to bigger parts, the window and the screen. Drag to select any area; a magnifier shows the pixels and their color.
- **Draw**: rectangle, ellipse, line, arrow, pen, marker, text and numbers, in eight colors; three preset sizes, and the wheel (two fingers up / down on a trackpad) sets any width. Undo and redo.
- **Hide**: a dragged box (the default) or a brush, covered with mosaic or with a solid color (the mosaic swatch, or any color); mosaic squares are sized so text under them cannot be read.
- **Edit afterwards**: click anything drawn to select it (with a tool, drawings of that tool; others are drawn over): drag it to move it, drag the ends of a line or arrow and the corners of a box (the corners of a text scale it), the arrow keys nudge it, scroll to change its width or size, click a color to recolor it, Delete removes it, double-click a text to edit it. While typing, drag the box's edge to move it and its corners to scale it. Moving the mouse well away ends typing and lets go of the selection. All of it undoes with ⌘Z.
- **Smooth**: the highlight glides from one window or element to the next.
- **Copy, save, pin**: Enter copies, ⌘S saves (PNG or JPEG), ⌘T pins the capture above other windows. Pins move, zoom with the wheel, change opacity with ⌥ + wheel, copy, save and read their text.
- **Text recognition** (optional, off by default): read the text of a capture; tables keep their columns (tab-separated, or Markdown). It runs on this Mac with Apple's Vision, in a short-lived helper process, so its models do not stay in memory.
- **Light**: about 15–25 MB of memory while idle.
- **Languages**: English, 简体中文, 繁體中文, following the system unless one is picked in Settings.

## Install

Build it (below), then copy `build/sniplite.app` to `/Applications` and open it. The scissors icon appears in the menu bar; there is no Dock icon.

sniplite is not signed with an Apple Developer ID or notarized, so macOS blocks a downloaded copy ("cannot be opened" / "is damaged"). After copying it to `/Applications`, remove the quarantine flag once:

```bash
xattr -dr com.apple.quarantine "/Applications/sniplite.app"
```

### Permissions

On first start the **Permissions** page lists what sniplite needs:

| Permission | Why |
| --- | --- |
| **Screen Recording** | to capture the screen |
| **Accessibility** (called "Device Control and Data Access" on macOS 27) | the F1–F12 shortcuts, and finding the parts of windows |

Click **Allow…** on each: System Settings opens at the right page with sniplite in a panel beside it; drag sniplite into the list and turn it on. System Settings then closes and the page comes back for the next one. The page stays until everything is allowed; sniplite restarts once after Screen Recording, which macOS needs. The page is also in the menu (Permissions…) and in Settings.

## Shortcuts

The same as on Windows, with ⌘ in place of Ctrl. They can be changed in Settings.

| Key | What it does |
| --- | --- |
| **F1** | Capture |
| **F3** | Pin the copied image or text to the screen |
| **⇧F3** | Hide / show all pins |
| **F4** | Capture and read the text (when text recognition is on) |
| **⇧F4** | Capture and copy the text (when text recognition is on) |
| **Enter** / double-click | Copy the capture |
| **⌘S** | Save the capture |
| **⌘T** / middle click | Pin the capture |
| **⌘O** / **⇧⌘C** | Read / copy the text of the selection |
| **⌘Z** / **⇧⌘Z** | Undo / redo |
| **Esc** | One step back: end typing, let go of the selected drawing, put the tool down; then cancel the capture |
| **Delete** | Remove the selected drawing |
| **Right click** | The same steps back as Esc; then back to choosing an area; once more to cancel |
| **Arrow keys**, **W A S D** | Move the cursor, the selected drawing or the capture area by one pixel; with Shift, by ten |
| **C** (while choosing) | Copy the color under the cursor |
| **Wheel** / two fingers | Choosing: a bigger or smaller part; with a tool: its width (and mosaic size); on a pin: zoom; ⌥ + wheel: pin opacity |
| **Double-click** / **Esc** | Close a pin |

The F1–F12 shortcuts use the Accessibility permission: sniplite takes the keys bound to its shortcuts, so on a Mac keyboard F1 captures instead of dimming the screen.

## Build

Needs only the Xcode Command Line Tools (`xcode-select --install`); Xcode itself is not required.

```bash
cd macos
./build.sh          # -> build/sniplite.app (Apple Silicon + Intel)
./build.sh --zip    # also build/sniplite_<version>_macos.zip
./test.sh           # unit tests (Swift Testing)
```

**Signing.** By default the app is signed ad hoc. macOS then sees every build as a new app: its permissions must be granted again after each rebuild (sniplite removes the stale entries itself, so the list never shows one that no longer applies). To keep them across rebuilds, sign with a fixed identity:

- `./make-cert.sh` once creates a local signing certificate, "sniplite Local Signing", in your login keychain; `build.sh` uses it from then on. It is good only for signing on that Mac and can be deleted in Keychain Access.
- Or `SIGN_ID="Developer ID Application: …" ./build.sh` with your own Apple certificate (needed to share the app without warnings, together with notarization).

Diagnostics go to `~/Library/Logs/sniplite.log` (hotkeys, permissions, recognition time).

## Not yet

Long screenshots, the command line and the update check of the Windows version.

## Code

| File | What it holds |
| --- | --- |
| `App.swift`, `main.swift` | the menu bar icon and menu, start-up |
| `HotKeys.swift` | global shortcuts (Carbon `RegisterEventHotKey`) |
| `TopRowKeys.swift` | the F1–F12 shortcuts on Mac keyboards (an event tap) |
| `Capture.swift` | screenshots of every display (ScreenCaptureKit) and the windows to snap to |
| `Elements.swift` | the parts of a window under the mouse (Accessibility API) |
| `Overlay.swift` | the capture overlay: choosing, editing, magnifier, rendering the result |
| `Annotation.swift`, `Toolbar.swift` | the drawing tools and the toolbar |
| `Pin.swift` | pins |
| `OCR.swift` | text recognition (Vision, in a helper process) and the text panel |
| `Permissions.swift` | the permissions page and the drag-to-authorize panel |
| `Settings.swift` | settings and the shortcut recorder |
| `L10n.swift`, `Util.swift` | texts; clipboard, saving, notices, log |

## Credits

The drag-to-authorize panel follows the approach of [PermissionFlow](https://github.com/jaywcjlove/PermissionFlow) by jaywcjlove (MIT), rewritten in AppKit so the app builds without Xcode.

## License

[MIT](../LICENSE)
