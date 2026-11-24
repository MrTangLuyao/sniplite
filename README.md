<div align="center">

<img src="pics/icon.png" width="96" alt="sniplite icon">

# sniplite

**A tiny, fast screenshot and pin tool, with its core written in assembly**

[![English](https://img.shields.io/badge/English-1677e5?style=flat-square)](README.md) [![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-eaeef2?style=flat-square)](docs/README.zh-CN.md) [![繁體中文](https://img.shields.io/badge/%E7%B9%81%E9%AB%94%E4%B8%AD%E6%96%87-eaeef2?style=flat-square)](docs/README.zh-TW.md) [![日本語](https://img.shields.io/badge/%E6%97%A5%E6%9C%AC%E8%AA%9E-eaeef2?style=flat-square)](docs/README.ja.md) [![한국어](https://img.shields.io/badge/%ED%95%9C%EA%B5%AD%EC%96%B4-eaeef2?style=flat-square)](docs/README.ko.md) [![Français](https://img.shields.io/badge/Fran%C3%A7ais-eaeef2?style=flat-square)](docs/README.fr.md) [![Deutsch](https://img.shields.io/badge/Deutsch-eaeef2?style=flat-square)](docs/README.de.md) [![Español](https://img.shields.io/badge/Espa%C3%B1ol-eaeef2?style=flat-square)](docs/README.es.md)

[![version](https://img.shields.io/github/v/tag/MrTangLuyao/sniplite?sort=date&label=version&style=flat-square&color=1677e5)](https://github.com/MrTangLuyao/sniplite/releases) [![system](https://img.shields.io/badge/system-Windows%2010%20%2F%2011-3b82f6?style=flat-square)](#download) [![license](https://img.shields.io/badge/license-MIT-3b82f6?style=flat-square)](LICENSE)

[**Download**](#download) | [Default shortcuts](#default-shortcuts) | [FAQ](#faq)

<img src="pics/demo-edit.png" alt="Select an area and draw circles, arrows, text and numbers right on it" width="66%">
<br>
<img src="pics/demo-select.png" alt="Before a capture, the window or control under the mouse is found for you; the magnifier shows pixels and colors" width="32.5%"> <img src="pics/demo-pin.png" alt="Pin a screenshot or text on top of the screen; the wheel zooms" width="32.5%">
<br>
<img src="pics/demo-ocr.png" alt="Read the text of what you select; a table keeps its columns" width="66%">
<br>
<img src="pics/demo-long.png" alt="Scroll a page and it is stitched into one long screenshot" width="66%">

</div>

## Features

- **Fast**: press F1 and the screenshot is there, sooner than in 99% of screenshot tools
- **Light**: about 320 KB, nothing else to install; the capture and drawing core is written in assembly
- **Pins**: pin a screenshot on top of every other window, so it stays in view while you work
- **Complete**: screenshots, pins, arrows, text, mosaic, spotlight, magnifier: it is all there
- **Measure**: a screen ruler measures the distance, size and angle between two points; Shift snaps to 0°/45°/90°, Alt measures from the centre, Enter copies the readout; the edge ruler keeps ticks along the top and left edges, with a thin crosshair that follows the mouse, a coordinate box when it stops, and a pixel loupe
- **Text recognition**: read the text in a capture, tables included; an optional module that runs entirely on your computer
- **Long screenshots**: the page is scrolled for you and stitched together as it goes
- **Clean**: no ads, open source, no logs, no data collected
- **Multilingual**: 8 languages, following Windows unless you pick one

## Download

Get the latest installer from [Releases](https://github.com/MrTangLuyao/sniplite/releases/latest).

There are two portable versions too, with nothing to install: `sniplite_<version>_portable_x64.exe`, and `sniplite_<version>_portable_with_OCR_x64.exe`, which carries the text recognition module.

> [!TIP]
> The icon is at the right end of the taskbar; click the small arrow there if you do not see it. To keep it in view, search Windows Settings for "Other system tray icons" and turn sniplite on.

## Default shortcuts

| Key | What it does |
| --- | --- |
| **F1** | Capture |
| **Shift+F1** | Quick capture: the screen under the mouse straight into a file (the folder is set in Settings) |
| **F2** | Color picker: click to copy the color and keep picking; Shift switches HEX / RGB; Esc or right click closes |
| **R** (in the picker or the ruler) | Switch between the color picker and the screen ruler |
| **C** (while capturing) | Copy the color under the cursor |
| **F3** | Pin the copied image or text to the screen |
| **Shift+F3** | Hide / show all pins |
| **F4** | Capture and read the text (with the text recognition module) |
| **Shift+F4** | Capture and copy the text |
| **Enter** | Copy the capture |
| **Ctrl+S** | Save the capture |
| **Ctrl+T** | Pin the capture to the screen |
| **Middle click** | Pin the capture to the screen |
| **Ctrl+O** | Recognize the text of the selection |
| **Ctrl+Shift+C** | Copy the text of the selection |
| **Ctrl+L** | Long screenshot: scrolls automatically, click the status text to pause |
| **Esc** | Cancel the capture |
| **Arrow keys**, **W A S D** | Move the cursor or the selection by one pixel; with Shift, by ten |
| **Wheel** | Capturing: pick a bigger or smaller window; on a pin: zoom |
| **Double-click** | Close a pin |

## FAQ

**How big is it?**

Tiny: under 1 MB.

**Why is it so fast?**

The parts that have to be fast (capture, composition, drawing and the capture overlay) are written in x86-64 assembly and the rest in C, with no C runtime. A screenshot is read straight from the graphics card and handed to Windows to compose on the GPU, which is much faster than the usual ways of capturing the screen on Windows.

**How does it compare with other tools?**

| Tool | Download | Memory when idle | Hotkey to ready |
| --- | --- | --- | --- |
| **sniplite** | 0.4 MB | 11 MB | 12 ms |
| Snipaste 2.11.3 | 19 MB | 50 MB | 121 ms |
| PixPin 3.6.6 | 66 MB | 31 MB | 142 ms |
| Greenshot 1.3.328 | 4 MB | 16 MB | 252 ms |
| Flameshot 15.0.0 | 18 MB | 6 MB | not measured |
| ShareX 22.4.0 | 139 MB | 58 MB | not measured |

<sub>This is an informal test, for reference only.</sub>

**How do I get the text out of a screenshot?**

Select an area and click the text button (Ctrl+O): the text appears in a panel beside the selection, where you can select, edit and copy it. A table keeps its columns and pastes into a spreadsheet as cells, or as Markdown if you prefer. Ctrl+Shift+C copies the text straight away. It needs the text recognition module (12 MB; PaddleOCR PP-OCRv6 models on ONNX Runtime, running entirely on your computer): install it on the OCR page of Settings, tick it in the installer, or use the portable version with OCR. Until it is installed, the text buttons are not shown. F4 and Shift+F4 start a capture that reads or copies the text right away.

**How do I take a long screenshot?**

Select the area and press Ctrl+L: sniplite scrolls the page for you and stitches it as it goes. Click the status text on the bar to pause or resume, or scroll the page yourself. A strip beside the area shows the result so far. Enter copies it and Esc cancels; you can also save it, pin it or read its text.

**How do I pick a color?**

Press F2 (or run `sniplite pick`): the color picker opens over the screen with the magnifier. Click to copy the color and keep picking; Shift switches between `#RRGGBB` and `R, G, B`; Esc or a right click closes it. While capturing normally, C copies the color under the cursor too.

**How do I measure something on screen?**

Click the sniplite icon in the tray and choose **Screen ruler**, or run `sniplite ruler`. Drag from one point to the other: the readout shows width × height, the distance in pixels and the angle. Hold Shift to snap to 0°, 45° or 90°; hold Alt to measure outward from where you pressed, both ways. The arrow keys nudge the end by one pixel (ten with Shift). Enter or C copies the readout, R switches to the color picker, and Esc closes it. For a ruler that stays on screen, run `sniplite ruler --edge` (or choose **Edge ruler** in the tray menu): ticks run along the top and left of the monitor under the mouse, follow its DPI, take no focus or clicks, and stay out of screenshots. A thin crosshair follows the mouse and hides when it leaves that monitor; when the mouse stops, a small box shows its coordinates and a pixel loupe with a grid and the center pixel marked appears below it. Switch the crosshair on or off on its own from the tray menu. Set the crosshair and box color with `cross_color=RRGGBB` under `[sniplite]` in `sniplite.ini` (default `00D6F5`), then restart sniplite. Run `sniplite ruler --edge --hide`, or choose **Hide the edge ruler**, to close it.

**Where are my captures saved?**

Ctrl+S opens the save dialog in the folder you last saved to; the first time, or if that folder is gone, in the default save location if you changed it, else in Pictures. Quick captures (Shift+F1) go straight into the default save location, which is the desktop until you change it on the Capture page of Settings. Tick "Also save each capture as a file" there, and every capture you copy or pin goes into that folder too. Under File name format, on the same page, you pick how the files are named, from a few patterns with the date and time.

**What if the hotkeys get in the way of a game?**

On the Hotkeys page of Settings, tick "Leave the hotkeys to full-screen apps (like games)": while a program that fills its screen is in front, sniplite lets go of its hotkeys and the keys reach that program; they come back when you switch away. Programs that do not run full screen can be added under "Leave the hotkeys to": click Manage, then New to type a file name such as `game.exe`, or Browse to pick the program.

**How much memory does it use?**

About 50 MB most of the time, nearly all of it held by the graphics driver, and a little more right after a capture. To use less, choose Low memory on the Capture page of Settings: about 2 MB, with slower captures.

**What does it leave on my computer?**

It needs no administrator rights and does not touch the registry. Changing a setting, or saving through the save dialog (it remembers the folder), creates one settings file; delete it to get the defaults back.

**How do I change the language?**

sniplite follows the language of Windows. To use another, open Settings from the tray icon and pick it under Language.

**How do I update?**

Once a day sniplite asks GitHub whether there is a newer version. If there is, a notification appears at the bottom right, and one click updates. Only the version number is checked and nothing is uploaded; you can turn this off in Settings. The portable versions do not look for updates: get the new one from [Releases](https://github.com/MrTangLuyao/sniplite/releases/latest).

**How do I uninstall it?**

Click "Uninstall sniplite" in the sniplite folder of the Start menu. The program, its settings and its shortcuts are removed.

**Is there a command line?**

Yes. Run `sniplite help` to see it.

## Settings

<img src="pics/ui/en.png" alt="The six pages of the settings, the shortcut list and the installer">

## Build it yourself

Install [w64devkit](https://github.com/skeeto/w64devkit) (or another MinGW-w64), add its `bin` folder to PATH and run `build.bat`; the programs appear in the `build` folder. The source is in `src`: the fast parts are assembly files (`.S`), assembled by gcc with the GNU assembler, the rest is C (`.c`). No C runtime is linked, only the system libraries that come with Windows.

## License

[MIT](LICENSE)

## Third-party open source

sniplite itself uses nothing but the system libraries of Windows. The optional text recognition module is the work of others, passed on unchanged with their licenses (they, or links to them, are in the module's `ocr` folder and on the [module's release page](https://github.com/MrTangLuyao/sniplite/releases/tag/ocr-2)):

- [ONNX Runtime](https://github.com/microsoft/onnxruntime) 1.26.0, Copyright (c) Microsoft Corporation, MIT License
- The [Microsoft Visual C++](https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files) runtime 14.51.36247 that ONNX Runtime needs (`msvcp140.dll`, `msvcp140_1.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`), Copyright (c) Microsoft Corporation, not open source: redistributed under Microsoft's [license terms](https://visualstudio.microsoft.com/license-terms/)
- The PP-OCRv6 models of [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR), Copyright (c) PaddlePaddle Authors, Apache License 2.0
- Their ONNX form comes from [RapidOCR](https://github.com/RapidAI/RapidOCR), Apache License 2.0
