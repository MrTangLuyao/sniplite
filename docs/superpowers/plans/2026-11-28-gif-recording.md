# GIF recording in sniplite — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A region of the screen can be recorded as an animated GIF, from the capture overlay, and the file is written to the folder the settings name.

**Architecture:** Two new C files. `src/gif.c` is the encoder: it turns 32-bit pixels into palette indices and then into the bytes of a GIF89a file, one frame at a time. `src/rec.c` is the recorder: a small floating panel, a timer, the read of the region with `BitBlt`, and the file that is written as the recording goes. The capture overlay gets one more button, `B_GIF`, which calls `rec_begin()` the way `B_LONG` calls `long_begin()`.

**Tech Stack:** C11 (the project's own C, no runtime beyond `src/crt.c`), the Win32 API (`BitBlt`, `CreateFileW`, `WriteFile`), GNU as for the assembly parts that are touched (`ov_*.S`, `draw.S`). The encoder is checked against an independent reference in `tools/gifref/`.

**Spec:** `docs/superpowers/specs/2026-11-27-gif-recording-design.md` — read it before starting; this plan argues from it and does not repeat it.

## Global Constraints

- No new library, no new DLL, no third-party code. Only `kernel32`, `user32`, `gdi32`, `dwmapi`, `imm32`, `uuid` stay linked (`build.bat`).
- No C runtime beyond what `src/crt.c` and `src/util.c` already provide: `memcpy`/`memset`/`memcmp`, `mem_alloc`/`mem_grow`/`mem_free`, the wide-string functions. **No `qsort`** — a sort is written by hand (the project does the same in `src/ocr.c`).
- No stdio. The file is written with `CreateFileW` and `WriteFile`.
- The program must stay under **400 KB**. It is 326144 bytes now; the whole feature is estimated at 25–35 KB.
- Every user-visible string goes into `src/lang_text.h` in **all eight languages**, in the existing `X(name, zh-Hans, zh-Hant, en, ja, ko, fr, de, es)` order.
- The author's style: dense C, four-space indent, `/* */` comments that explain *why*, no tabs, lines under about 110 columns.
- **`src/scroll.c` is not touched.** The few helpers the recorder needs (`make()`, the hotkeys) are written again in `src/rec.c`, small and plainly, so the diff the author reads is only the new code.
- The frame rate is a setting: 10, 15, 20 or 30 fps, default 15, 30 the highest. The palette size is a setting: 256, 128 or 64 colours, default 256.
- **This machine cannot run the program.** It is WSL2 and the Windows interop is broken (`UtilBindVsockAnyPort` fails), there is no wine. Everything here is compile-time verification plus the encoder's own test rig; the run on Windows is the user's, and Task 7 is where that happens.
- The encoder is checked on this machine with `tools/gifref/` (the reference, an independent reader, and the checker). Every change to `src/gif.c` goes through that check.
- **No issue and no pull request until the feature works.** The user was explicit about this twice: build it first, then talk to the author.

## Review Focus

Five things the spec implies that no single test exercises. Each one gets the test named under it, in the task that owns the code.

1. **The region is the whole screen, or bigger than 1280x720.** The picture is scaled down to fit, and the panel has nowhere beside the region, so it goes into the corner of the monitor. (Task 4: the scaling; Task 7: the manual list.)
2. **The screen does not change.** Every tick still writes a frame — a 1x1 one whose pixel is the transparent index — so the delays stay exact and the file does not drift out of time. (Task 3: `test_still_screen`.)
3. **A colour that the palette does not have appears later** (a window opens, a tooltip shows). It gets the nearest palette entry, and the picture must not fall apart. (Task 3: `test_new_colour`.)
4. **The recording is cut short**: a capture begins, the monitor is unplugged, the user presses Esc. The file that was being written is deleted; nothing is left behind. (Task 4: `test_discard`; Task 7: the manual list.)
5. **The machine cannot keep up** (a whole screen at 30 fps on a slow disk). The file on disk is always a valid GIF up to the last frame written, the frames that arrive late are simply late, and the recording stops at 256 MB. (Task 3: the file is valid after every frame; Task 4: the size cap.)

---

## The files, and what each one is for

| File | What it is |
|---|---|
| `src/gif.h` | The encoder's interface: the `Gif` struct and the functions. |
| `src/gif.c` | The encoder: the quantiser, the frame differencing, the LZW, the container. |
| `src/rec.c` | The recorder: the panel, the timer, the read of the region, the file. |
| `src/overlay.h` | Two new declarations: `rec_begin`, `rec_cancel`. |
| `src/ov_layout.inc` | `B_GIF`, `ACT_GIF`, `B_LAST` grows, `TB_ITEMS` grows. |
| `src/ov_base.S` | `B_GIF` in `kTbOrder` and `kTbPlain`. |
| `src/ov_show.S` | `finish()` gets the `ACT_GIF` case; the toolbar's click maps `B_GIF` to it. |
| `src/draw.h`, `src/draw.S`, `src/draw_icons.inc` | The icon of the new button. |
| `src/config.h`, `src/config.c` | The two settings, in `sniplite.ini`. |
| `src/settings.c`, `res/sniplite.rc` | The two settings in the preferences, on the capture page. |
| `src/lang_text.h` | The new texts, in eight languages. |
| `build.bat`, `tools/build.sh` | The two new `.c` files are added to the link line. |
| `tools/gifref/` | The check of the encoder. Not part of the program. |

---

### Task 1: A build that works on this machine

The project builds on Windows with `build.bat`. Here it is WSL2, so the check that
the code compiles and links has to go through the cross-compiler.

**Files:**
- Create: `tools/build.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `bash tools/build.sh` builds `build/sniplite.exe`, `build/sniplite.com` and `build/setup.exe` with `x86_64-w64-mingw32-gcc`, and prints their sizes. Every later task uses it as its build check.

- [ ] **Step 1: write `tools/build.sh`**

A bash port of `build.bat`: the same flags (`-Isrc -Ires -std=c11 -Os -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -fno-math-errno -ffunction-sections -fdata-sections -fno-ident`), the same link flags (`-nostdlib -nostartfiles -e start -s -Wl,--gc-sections -Wl,--nxcompat -Wl,--dynamicbase -Wl,--high-entropy-va`), the same libraries, the same `windres` calls, `gcc` replaced by `x86_64-w64-mingw32-gcc` and `windres` by `x86_64-w64-mingw32-windres`. It takes the list of `.c`/`.S` files from `build.bat` — keep the two in step by hand, and check that with `diff` when the list changes.

- [ ] **Step 2: run it**

Run: `bash tools/build.sh`
Expected: three files in `build/`, no warning, and `sniplite.exe` is **326144** bytes (the size before the feature).

- [ ] **Step 3: commit**

```bash
git add tools/build.sh
git commit -m "tools: a build that runs here, for the encoder's check"
```

This file is ours, not for the pull request: the author builds on Windows. Leave it out of the PR.

---

### Task 2: The writer — the container and the LZW

The encoder in two layers. This task is the lower one: given a palette and a frame
of indices, it writes the bytes of a GIF89a file. Nothing here knows about pixels.

**Files:**
- Create: `src/gif.h`
- Create: `src/gif.c`
- Modify: `tools/gifref/refgif.c`
- Create: `tools/gifref/gifenc.c`
- Create: `tools/gifref/win/windows.h`
- Modify: `tools/gifref/check.py`

**Interfaces:**
- Consumes: nothing.
- Produces:

```c
/* src/gif.h */
#pragma once
#include "common.h"

/* A GIF being written: the bytes come out one frame at a time. */
typedef struct {
    uint8_t *buf;    /* the bytes of the last chunk: what the caller writes to the file */
    int n, cap;
    int w, h;        /* the logical screen: the size of the region */
    int npal;        /* the colours in the palette */
    uint8_t pal[256][3];
    int trans;       /* the palette entry that means "unchanged", -1 for none */
    int ncolours;    /* how many colours the palette may hold: 256, 128 or 64 */
    int started;     /* the header and the palette have been written */
} Gif;

/* Start a GIF of a region: its size and how many colours the palette may hold.
 * Nothing is written until the first frame. */
void gif_begin(Gif *g, int w, int h, int ncolours);
/* Write one frame of indices: its size, where it sits in the picture, and how long
 * it is shown (in hundredths of a second). The bytes are in g->buf. */
void gif_write_frame(Gif *g, const uint8_t *idx, int fw, int fh, int fx, int fy, int delay_cs);
/* The last byte of the file. */
void gif_end(Gif *g);
/* The memory the encoder took. */
void gif_free(Gif *g);
```

**The bytes of the container.** This is the contract: the reference in
`tools/gifref/refgif.c` and the encoder must write exactly these, or the comparison
is not exact.

```
"GIF89a"
logical screen descriptor:  w(2) h(2) 0xF7 0x00 0x00
      (the third byte: the global colour table, 8 bits of colour resolution,
       and the size field: 7 for 256 colours, 6 for 128, 5 for 64)
global colour table:       3 bytes per entry, ncolours entries
Netscape extension:        21 FF 0B "NETSCAPE2.0" 03 01 00 00 00
per frame:
  graphic control ext.:    21 F9 04 <flags> <delay(2)> <trans> 00
      flags: 0x04 (disposal method 1, "do not dispose") plus 0x01 when there is
      a transparent index
  image descriptor:        2C <left(2)> <top(2)> <w(2)> <h(2)> 00
  minimum code size:       one byte: 8, 7 or 6
  the data:                sub-blocks of at most 255 bytes, each with its length
                           before it, then a zero length that ends them
trailer:                   3B
```

- [ ] **Step 1: the reference with the new container**

Change `tools/gifref/refgif.c` so that it writes the container above: the Netscape
extension after the colour table, and a graphic control extension before each
image descriptor (the delay 7, the disposal method 1, no transparent index).
Everything else in it stays as it is: it still takes indices, not pixels, and its
palette is the identity ramp.

- [ ] **Step 2: the stub of the Windows header**

`tools/gifref/win/windows.h` — a small header that lets `src/common.h` be compiled
on Linux, so that `src/gif.c` can be checked here without a Windows compiler.
It declares only what `common.h` uses: `WCHAR`, `BOOL`, `BYTE`, `LPBYTE`, `WORD`,
`UINT`, `DWORD`, `LONG`, `HANDLE`, `HWND`, `HDC`, `HBITMAP`, `HGDIOBJ`, `HMONITOR`,
`HINSTANCE`, `RECT`, `POINT`, `STARTUPINFOW`, `PROCESS_INFORMATION`.

The check that it is enough: compile a file that includes `common.h` with
`gcc -Isrc -Itools/gifref/win -c` — it must compile with no error.

**Why `src/gif.c` may include `common.h` and still be checked here:** the stub is
found through `-Itools/gifref/win`, because `common.h` includes `<windows.h>` with
angle brackets. The project keeps its convention (`#include "common.h"`), and the
check runs on any machine.

- [ ] **Step 3: the encoder's lower layer**

`src/gif.h` as above. `src/gif.c`:

- the buffer: `buf_reserve`, `buf_byte`, `buf_word`, `buf_bytes` — they grow `g->buf`
  with `mem_grow` (see `src/util.c`) and never free it before `gif_free`.
- `gif_begin(g, w, h, ncolours)`: stores the size, `ncolours`, and `trans = -1`.
  Nothing is written.
- `gif_write_frame(g, idx, fw, fh, fx, fy, delay_cs)`: if `!g->started`, write the
  header, the logical screen descriptor, the global colour table (`g->pal`, `g->npal`
  entries) and the Netscape extension, and set `g->started`. Then write the graphic
  control extension, the image descriptor, the minimum code size, and the LZW data
  of the frame. The bytes end up in `g->buf` (the buffer is emptied at the start of
  each call).
- the LZW: the classic GIF variant, **the same rules as `tools/gifref/refgif.c`**,
  because the bytes have to come out the same:
  - the minimum code size is `log2(npal)` (8, 7 or 6); the clear code is
    `1 << min_code_size`, the end code is that plus one, the first free entry is
    that plus two;
  - the code size starts at `min_code_size + 1` and grows by one when
    `next_code > (1 << code_size)`, never past 12;
  - the accumulator and the bits in it are **not** reset when the dictionary is
    cleared, only at the start of a file;
  - when the dictionary is full, a clear code goes out, the dictionary starts over,
    and another clear code follows it;
  - the dictionary is looked up through a hash table (the reference scans the
    entries linearly, which is fine for it and too slow here). The table is cleared
    with the dictionary.
  Write a comment that says this in as many words as it takes: these are the rules
  that look wrong and are right, and the reason they are written down is that a
  decoder that disagrees will not show the picture.
- `gif_end(g)`: the trailer `3B` into `g->buf`.
- `gif_free(g)`: `mem_free(g->buf)` and zero the struct.

- [ ] **Step 4: the harness that drives the encoder**

`tools/gifref/gifenc.c` — a program that links `src/gif.c` and writes a GIF the
same way `refgif.c` does, so that the two files can be compared byte for byte:

```c
/* gifenc <out.gif> <width> <height> <pattern>
 * The same pictures refgif.c makes (the same rand() sequence), the identity
 * palette, and one frame. */
```

It must:
- build the indices exactly as `refgif.c` does: `srand(12345)` and then, per pixel,
  `rand() & 0xFF` (pattern 0), `(i * 7) & 0xFF` (1), `7` (2), `i & 1 ? 0 : 255` (3);
- fill `g.pal[i] = {i, i, i}` for all 256 entries, set `g.npal = 256`, and call
  `gif_begin(&g, w, h, 256)` before that;
- call `gif_write_frame(&g, idx, w, h, 0, 0, 7)` — the delay 7, the same as the
  reference's;
- call `gif_end(&g)` and write `g.buf` to the file.

It needs `mem_alloc`/`mem_free`/`mem_grow`: the project has them in `src/util.c`
and they are not in libc under those names, so the harness defines its own (with
`malloc`/`realloc`/`free` under them). `src/gif.c` picks the harness's up at link
time; nothing in `src/` changes.

- [ ] **Step 5: teach the checker the new container**

`tools/gifref/check.py` must:
- build the harness next to the reference (`cc -O2 -Itools/gifref/win -Isrc -o
  tools/gifref/gifenc tools/gifref/gifenc.c src/gif.c`), and build the reference as
  it does now;
- compare the two files byte for byte, as it does now;
- check the properties of the file through `gifread.py`: the format is `GIF89a`,
  the logical screen is `w` by `h`, the global colour table has 256 entries, the
  Netscape extension says the animation loops forever, there is one frame, its
  rectangle is the whole picture, its delay is 7 hundredths, its disposal method is
  1, and there is no transparent index.

`gifread.py` has to be able to say all that: it parses the file already, so it
gains the loop count, the disposal method and the transparent index.

- [ ] **Step 6: run the check**

Run: `python3 tools/gifref/check.py tools/gifref/gifenc`
Expected: every check passes, the exit code is 0, and the output names the harness
as the encoder under test. If the bytes differ, the difference is in the LZW: the
two rules that are easy to get wrong are the code size growing one step too late
and the accumulator being reset when the dictionary is cleared.

Run: `python3 tools/gifref/check.py`
Expected: the reference against itself still passes (the reference changed in
Step 1, so this is a real check).

- [ ] **Step 7: check that the program still builds**

Run: `bash tools/build.sh`
Expected: no warning. `src/gif.c` is not in the link line yet, so `sniplite.exe`
is still 326144 bytes.

- [ ] **Step 8: commit**

```bash
git add src/gif.h src/gif.c tools/gifref
git commit -m "gif: the writer: the container and the LZW"
```

---

### Task 3: The quantiser and the frame differencing

The upper layer: pixels in, indices out, and the comparison that finds what
changed.

**Files:**
- Modify: `src/gif.h`
- Modify: `src/gif.c`
- Create: `tools/gifref/gifpix.c`
- Modify: `tools/gifref/gifread.py`
- Modify: `tools/gifref/check.py`

**Interfaces:**
- Consumes: the writer of Task 2 (`gif_begin`, `gif_write_frame`, `gif_end`, `gif_free`, the `Gif` struct).
- Produces:

```c
/* Add to the Gif struct: */
    uint8_t *prev;    /* the indices of the frame before, one byte per pixel */
    uint8_t *idx;     /* the indices of the frame being made, one byte per pixel */

/* One frame of pixels: 32-bit, top-down, 0x00RRGGBB. The delay is in
 * hundredths of a second. The encoder finds the part that changed by itself.
 * The bytes of the frame are in g->buf. */
void gif_frame(Gif *g, const uint32_t *px, int stride, int delay_cs);
```

- [ ] **Step 1: the round trip**

`tools/gifref/gifpix.c` — a program that links `src/gif.c` and writes a GIF of
**pixels**, not of indices:

```c
/* gifpix <out.gif> <width> <height> <nframes>
 * A picture of a few flat colours, with a block that moves from frame to frame.
 * The colours are few enough that the palette holds them exactly. */
```

The picture it makes must be deterministic and known to `check.py`: the same
generator in both, so the checker knows what the frames must look like. Four flat
colours (black, white, red, blue) in a checkerboard, with a block of one colour
moving one cell to the right in every frame.

`tools/gifref/check.py` then checks, through `gifread.py`:
- the number of frames is `nframes`;
- the delay of frame *n* is `round((n+1)*100/15) - round(n*100/15)` hundredths
  (the frame rate is 15);
- the loop count is 0 (forever) and the disposal method of every frame is 1;
- **composing** the frames (the transparent index means "the pixel of the frame
  before stays") gives back the picture of each frame exactly, colour for colour.
  `gifread.py` gains a `compose()` that does this: it starts with an empty
  picture and, for each frame, takes the pixels that are not the transparent
  index and leaves the others as they were;
- the first frame covers the whole picture and the later ones are smaller (only
  the rectangle that changed);
- the file is a valid GIF at every step: the harness writes the frames one at a
  time to the file it makes, and the checker reads the file after each frame was
  written — the bytes after frame *k* must be a valid GIF with *k* frames. (This
  is the "the file on disk is always a valid GIF" promise of the spec.)

- [ ] **Step 2: the quantiser**

In `src/gif.c`:

- **the palette** (built once, from the first frame):
  - collect the distinct colours of the frame into a small hash table with counts
    (4096 entries is plenty for a screen; if it fills up, the colours that do not
    fit are mapped to the nearest entry later);
  - if there are no more distinct colours than the palette may hold (minus the one
    reserved for the transparent index), the palette is exactly those colours —
    the usual case for a screen, and exact;
  - otherwise **median cut**: split the box with the longest range on its longest
    axis at the median, until there are as many boxes as the palette may hold;
    the average of a box is its palette entry;
  - the sort inside a box is written by hand (the project has no `qsort`; see
    `src/ocr.c` for the precedent). A shell sort is enough: the boxes get small
    as they are split, and the palette is built once, not per frame;
  - the last entry of the table is reserved: `g->trans = ncolours - 1`, and the
    quantiser never gives it to a pixel.
- **the mapping of a pixel to an index**: a cache of the colours that were seen
  (a direct-mapped table of 2048 entries, each holding the colour and the index),
  so that a screen with few colours costs almost nothing per pixel. A colour that
  is not in the palette gets the nearest entry: the search is over the palette
  (255 entries at most) and the answer goes into the cache.
- `gif_frame(g, px, stride, delay_cs)`:
  - if this is the first frame, build the palette from it;
  - quantise the whole frame into `g->idx` (one byte per pixel);
  - compare it with `g->prev` and find the rectangle that changed: the smallest
    rectangle that holds every pixel whose index differs;
  - if nothing changed, write a **1x1 frame** whose one pixel is the transparent
    index, at (0, 0). (Not "no frame": the delay of the next frame would then be
    the sum of all the ones in between, and that sum does not fit in the one byte
    a GIF gives a delay.)
  - otherwise write the rectangle: the pixels that changed get their index, the
    ones that did not get the transparent index, so the picture of the frame
    before shows through them;
  - copy the frame's indices into `g->prev`.

  The first frame is written whole, with no transparent index in it: there is
  nothing before it.

- [ ] **Step 3: run the check**

Run: `python3 tools/gifref/check.py`
Expected: the reference against itself passes, and the new pixel check passes:
the frames come back exactly, the delays are 7, 6, 7, 6, ..., the later frames are
smaller than the first, and the file is valid after every frame.

Run: `python3 tools/gifref/check.py tools/gifref/gifenc`
Expected: still passes — the byte-exact comparison of the lower layer is not
affected by the upper one.

- [ ] **Step 4: the two cases of the Review Focus**

- **the screen does not change** (`test_still_screen`): a picture that does not
  change at all, three frames. Every frame must be in the file, every delay must
  be the formula's, and the file must stay small — a 1x1 frame with the
  transparent index and nothing else.
- **a colour that the palette does not have** (`test_new_colour`): the first frame
  has four colours, the second adds a fifth. The fifth must be mapped to the
  nearest of the four, and the composed picture must still show the block in the
  colour that is nearest to it (the check allows the nearest of the four, not an
  exact match: that is what the quantiser promises).

  Both are cases in `tools/gifref/check.py`, in the same style as the others.

- [ ] **Step 5: commit**

```bash
git add src/gif.h src/gif.c tools/gifref
git commit -m "gif: the quantiser and the frame differencing"
```

---

### Task 4: The recorder

The window, the timer, the read of the region, the file.

**Files:**
- Create: `src/rec.c`
- Modify: `src/overlay.h`
- Modify: `build.bat`
- Modify: `tools/build.sh`

**Interfaces:**
- Consumes: the encoder of Tasks 2 and 3 (`gif_begin`, `gif_frame`, `gif_end`, `gif_free`).
- Produces:

```c
/* src/overlay.h */
/* rec.c: the GIF recorder. rec_begin is called by the capture, which closes right
 * after: its selection becomes the region that is recorded. */
void rec_begin(void);
void rec_cancel(void);
```

- [ ] **Step 1: the shell of the recorder**

`src/rec.c`, the shape of `src/scroll.c`:

- `#define REC_CLASS L"sniplite.rec"`, the tick in `1000 / fps` milliseconds,
  `MAX_FILE` 256 MB.
- the state: `struct { bool on; RECT rc; int w, h, sw, sh; float s; HWND panel;
  Img shot, small; Gif gif; HANDLE file; WCHAR path[MAX_PATH + 80]; int frames;
  DWORD size; } R;`
- `make()` — the same helper as in `scroll.c` (`CreateWindowExW` with
  `WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`, then
  `SetWindowDisplayAffinity(wnd, 0x11)`), written again here so that `scroll.c` is
  not touched. The panel is the only window: there is no ring around the region
  and no toolbar.
- `rec_begin()`: the region out of the capture's state, exactly as `long_begin()`
  does it:

  ```c
  const Shot *sh = (const Shot *)(O + OV_SHOT);
  const RECT *sel = (const RECT *)(O + OV_SEL);
  RECT rc = {sh->vx + sel->left, sh->vy + sel->top, sh->vx + sel->right, sh->vy + sel->bottom};
  ```

  - the region must be at least 32 by 32, or nothing happens;
  - the scale: if the region is bigger than 1280 by 720, it is scaled down to fit
    that, keeping the proportions: `f = min(1280.0/w, 720.0/h)`, `sw = max(1,
    round(w * f))`, `sh = max(1, round(h * f))`. The **logical screen of the GIF is
    the scaled size**, so `gif_begin(&R.gif, sw, sh, colours)`.
  - the file: the folder from the settings (`config_load`), or the desktop when it
    is empty; the name from `name_format(cfg.name, &now, name)` — the same naming
    the other saves use — with `.gif` after it; the file is created with
    `CREATE_NEW`, and when the name is taken, `_2`, `_3`, ... are tried, the way the
    quick capture does it (`quick_save` in `src/main.c`). The name is made when the
    recording starts, so two recordings in the same second do not write over each
    other.
  - the panel: a window outside the region, `WS_POPUP`, of the size
    `px(300) by px(34)`, placed below the region when there is room, else above
    it, else in the corner of the monitor the region is on (the region may be the
    whole screen, and then there is no room anywhere else).
  - the hotkeys: `RegisterHotKey(panel, HK_STOP, 0, VK_RETURN)` and
    `RegisterHotKey(panel, HK_CANCEL, 0, VK_ESCAPE)` — the keyboard belongs to the
    program in front, so the keys come as hotkeys, the way the long screenshot does
    it.
  - the timer: `SetTimer(panel, TIMER_GRAB, 1000 / fps, NULL)`.

  The recorder has **no message loop of its own**: the daemon has one
  (`src/main.c`), and it dispatches to whatever window the message is for, which is
  how the long screenshot works too. That is why the panel is a `WS_EX_NOACTIVATE`
  window and why the keys come as hotkeys.

- [ ] **Step 2: the tick**

Every tick:
- if a capture has begun (`ov_active()`), the recording is over and the file is
  thrown away — the same way the long screenshot ends (see `tick()` in
  `src/scroll.c`);
- if the screen has changed under the recording (the region is no longer on the
  monitor it was on), the recording ends the same way;
- read the region: `GetDC(NULL)` and
  `BitBlt(R.shot.dc, 0, 0, w, h, scr, rc.left, rc.top, SRCCOPY | CAPTUREBLT)`,
  exactly as the long screenshot reads its region;
- if the region was scaled down, scale it: **the average of the block**, not the
  nearest pixel. Nearest-neighbour scaling to a fraction like 2:3 drops some rows
  and keeps others, and a line of text that lands on a dropped row vanishes for
  that frame and comes back for the next: the recording shimmers. The average
  keeps every row's share of the light. Write that in a comment;
- the delay of this frame: `delay = round((frames+1) * 100.0 / fps) -
  round(frames * 100.0 / fps)` hundredths — the delay is computed from the frame's
  number, not from a clock, so a recording that could not keep up plays at the
  rate that was asked for, with the frames that were missed missing from it;
- `gif_frame(&R.gif, px, stride, delay)`;
- write `R.gif.buf` (its `n` bytes) to the file with `WriteFile`, and add to the
  size;
- if the file is over 256 MB, the recording stops and the panel says so;
- the panel is redrawn: the time, the number of frames, the size, and the button.

- [ ] **Step 3: the panel**

The panel is drawn by the program, the way the long screenshot's bar is:
- the picture: `img_create` + `surf_img` + `d_fill` + `d_frame`, with the colours
  of the bars (`ui_pal[P_BG]`, `ui_pal[P_EDGE]` — see `src/ov_layout.inc`);
- the text: `Time 01:23   Frames 123   Size 1.2 MB`, with the font the long
  screenshot's bar uses (`CreateFontW(-px(13), ...)`, `T(FONT)`), and the words
  `Time`, `Frames`, `Size` from `src/lang_text.h` (Task 6 adds them);
- the button: at the right, 30 by 30, the icon `IC_OK` (the check mark — the same
  one the long screenshot's bar uses for "done"), with the hover and the pressed
  states the bar has;
- the mouse: `WM_MOUSEMOVE`, `WM_MOUSELEAVE`, `WM_LBUTTONDOWN`, `WM_LBUTTONUP`,
  and the button under the mouse is found by its rectangle — the same shape as
  `bar_hit()` in `src/scroll.c`;
- the window procedure returns `MA_NOACTIVATE` for `WM_MOUSEACTIVATE`, so the
  keyboard stays with the program in front.

- [ ] **Step 4: the end**

- **Enter, or the button**: the recording is saved. The trailer is written
  (`gif_end`), the file is closed, and the corner of the monitor says what was
  saved and where: `notice_corner(T(QUICK_SAVED), path, at, 2000)` — the same
  notice the quick capture shows (`src/ocr_ui.c`).
- **Esc**: the recording is thrown away: the file is closed and
  `DeleteFileW(path)` removes it. Nothing is said.
- **a capture begins, or the screen changes**: the same as Esc.
- the panel's window and the timer are destroyed, the encoder's memory is freed
  (`gif_free`), and the two pictures are destroyed (`img_destroy`).

- [ ] **Step 5: the two cases of the Review Focus**

- **the whole screen** (`rec_scale`): a region of 1920 by 1080 becomes 1280 by 720,
  and the GIF's logical screen is 1280 by 720 — not 1920 by 1080. The recorder
  cannot be run here; this is on the list of Task 7.
- **the recording is cut short** (`test_discard`): the file is deleted when the
  recording is thrown away. Also not runnable here; also on the list of Task 7.

- [ ] **Step 6: build**

Add `src/gif.c` and `src/rec.c` to the link line in `build.bat` and in
`tools/build.sh` (the same place as `src/scroll.c`).

Run: `bash tools/build.sh`
Expected: no warning; `sniplite.exe` grows by the size of the two new files.

- [ ] **Step 7: commit**

```bash
git add src/rec.c src/overlay.h build.bat tools/build.sh
git commit -m "rec: the recorder: the panel, the timer, the file"
```

---

### Task 5: The button and the icon

The capture overlay gets one more button. Six places have to change, and three of
them break the build if they are missed — that is why they are written down.

**Files:**
- Modify: `src/ov_layout.inc`
- Modify: `src/ov_base.S`
- Modify: `src/ov_show.S`
- Modify: `src/draw.h`
- Modify: `src/draw.S`
- Modify: `src/draw_icons.inc`

**Interfaces:**
- Consumes: `rec_begin()` (Task 4).
- Produces: the button `B_GIF` in the capture's toolbar; pressing it starts the
  recorder on the selection.

**The six places, and the three traps:**

1. `src/ov_layout.inc`:
   - `#define B_GIF 31` — **after** `B_BACK`, not in the middle of the others.
     `B_UNDO` (20), `B_REDO` (21), `B_FRONT` (29) and `B_BACK` (30) have fixed
     values: `src/ov_paint.S` has `.if B_UNDO + 4 != 24 || B_REDO + 4 != 25 ||
     B_FRONT + 4 != 33 || B_BACK + 4 != 34` and `.error` — their ids are the bits
     of the pick list. So `B_GIF` goes after them.
   - `#define B_LAST B_GIF` — it grows, because `tip_text` in `src/ov_paint.S` maps
     `B_UNDO..B_LAST` onto `S_TIP_UNDO, S_TIP_REDO, ...` **by position**.
   - `#define ACT_GIF 5` — after `ACT_LONG`.
   - `#define TB_ITEMS 23` — it grows by one.
2. `src/ov_base.S`: `B_GIF` goes into **both** `kTbOrder` and `kTbPlain`, right
   after `B_LONG`. The `.if kTbPlain - kTbOrder - 4 * TB_ITEMS || .Ltb_end -
   kTbPlain - 4 * (TB_ITEMS - 2)` and the `.error` after it stop the build if the
   counts do not match. `kTbPlain` is the toolbar without the two text buttons,
   and the GIF button is not one of them.
3. `src/ov_show.S`:
   - in the toolbar's click (around line 2377): `B_GIF` gives `ACT_GIF`, like
     `B_LONG` gives `ACT_LONG`;
   - in `finish()` (around line 1054): `ACT_GIF` calls `rec_begin()` and then
     goes to the same place `ACT_LONG` goes to — the capture closes and the
     recorder takes the selection over.
4. `src/draw.h`: `IC_GIF` after `IC_BACK` in the enum of the icons.
5. `src/draw.S`: the bound on the icon number goes from 21 to 22
   (`cmp edx, 21; ja .Lic_ret0`), and `.Lic_table` (at the end of the file) gets
   `.Lic_gif` as its last entry.
6. `src/draw_icons.inc`: the icon itself (below).

**The third trap: the tooltip.** `tip_text` in `src/ov_paint.S` maps
`B_UNDO..B_LAST` onto the rows of `lang_text.h` **by position**, so the new row
`TIP_GIF` has to sit in `lang_text.h` right after `TIP_BACK` (the rows are
`TIP_UNDO, TIP_REDO, TIP_PIN, TIP_SAVE, TIP_QUIT, TIP_COPY, TIP_OCR, TIP_OCRCOPY,
TIP_LONG, TIP_FRONT, TIP_BACK`, which are `B_UNDO..B_BACK` in that order). If it
does not, every tooltip after `B_LONG` shifts by one. Task 6 adds the row.

**The icon.** `src/draw_icons.inc`: a programme in the same form as the others — a
filled circle with a ring around it, the record button. The format is in the
header of the file: `.byte kind, n, width, alpha` and then the points as floats.
`kind 2` is a convex polygon (the points in order, counter-clockwise), `kind 3`
is an ellipse (the centre, then the two radii, in grid units of 0..20), `kind 1`
is a polyline. There is no "filled circle" kind and the icons have one colour
only, so the record button is an octagon (a convex polygon of eight points) with
a stroked ellipse (kind 3) as the ring around it. Keep it inside the 0..20 grid.

- [ ] **Step 1: the layout constants**

As in points 1 and 2 above. After the change, `TB_ITEMS` is 23 and the `.error`
in `src/ov_base.S` is satisfied.

- [ ] **Step 2: the click and the call**

As in point 3 above. `rec_begin` is declared in `src/overlay.h` (Task 4), so the
assembly can call it.

- [ ] **Step 3: the icon**

As in points 4, 5 and 6 above.

- [ ] **Step 4: build**

Run: `bash tools/build.sh`
Expected: no warning and no `.error` from `src/ov_base.S` or `src/ov_paint.S`.
The program grows by a few hundred bytes.

If the build stops with "TB_ITEMS is not the number of entries of kTbOrder", the
table and the count do not agree: `kTbOrder` has 23 entries and `kTbPlain` 21.

- [ ] **Step 5: commit**

```bash
git add src/ov_layout.inc src/ov_base.S src/ov_show.S src/draw.h src/draw.S src/draw_icons.inc
git commit -m "the capture overlay: a button that records the selection as a GIF"
```

---

### Task 6: The settings and the texts

**Files:**
- Modify: `src/config.h`
- Modify: `src/config.c`
- Modify: `src/settings.c`
- Modify: `res/resource.h`
- Modify: `res/sniplite.rc`
- Modify: `src/lang_text.h`

**Interfaces:**
- Consumes: nothing from the earlier tasks (the recorder reads the settings
  through `config_load`).
- Produces:

```c
/* src/config.h */
enum { FPS_COUNT = 4 };         /* the frame rates: kFps[0..3] */
enum { COLOURS_COUNT = 3 };     /* the palette sizes: kColours[0..2] */
extern const int kFps[FPS_COUNT];        /* 10, 15, 20, 30 */
extern const int kColours[COLOURS_COUNT]; /* 256, 128, 64 */

/* in Config: */
    int fps;      /* which of the kFps frame rates */
    int colours;  /* which of the kColours palette sizes */
```

- [ ] **Step 1: the settings in the file**

`src/config.h`: the two enumerations, the two arrays (declared), the two fields in
`Config`.

`src/config.c`: the arrays are defined there — `kFps[] = {10, 15, 20, 30}` and
`kColours[] = {256, 128, 64}`. The defaults (in `config_defaults`): the frame rate
15 (`kFps[1]`), the palette 256 (`kColours[0]`).

`config_load` reads them, and `config_save` writes them — **both sides**, because
`config_save` rewrites the whole file by hand and a setting that is only read is
lost at the next save:

```c
/* in config_load: the number is in the file, so that a person can read it */
c->fps = ini_pick(path, L"gif_fps", kFpsTexts, FPS_COUNT);
c->colours = ini_pick(path, L"gif_colours", kColoursTexts, COLOURS_COUNT);
/* in config_save: */
str_addf(&s, L"gif_fps=%d\r\ngif_colours=%d\r\n", kFps[c->fps], kColours[c->colours]);
```

`ini_pick` (in `src/config.c`) takes the list of the words of the setting; the
words here are `"10", "15", "20", "30"` and `"256", "128", "64"`, so the file
holds a number a person can read.

- [ ] **Step 2: the two controls in the preferences**

`res/sniplite.rc`, in `IDD_PAGE_CAPTURE`: two labels and two combo boxes. There is
room for one row between the file-name row and the *Defaults* button: the file
name combo sits at y=129, the button at y=163, and a combo box is 13 units high.
So the row goes at y=145 (the label two units lower, as the other rows do):

```
    LTEXT           "", IDC_FPS_LABEL, 8, 147, 52, 10
    COMBOBOX        IDC_FPS, 62, 145, 52, 80, CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP
    LTEXT           "", IDC_COLOURS_LABEL, 120, 147, 52, 10
    COMBOBOX        IDC_COLOURS, 174, 145, 38, 80, CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP
```

The new ids go into `res/resource.h`, where the ids of the controls are. The
numbers 212 to 215 are free (211 is the last of the installer's, 220 is the
first of the preferences'):

```c
#define IDC_FPS 212
#define IDC_FPS_LABEL 213
#define IDC_COLOURS 214
#define IDC_COLOURS_LABEL 215
```

`src/settings.c`:
- the labels are set through `kTexts` (the table of the controls with a text of
  their own): `{PG_CAPTURE, IDC_FPS_LABEL, S_C_FPS}` and
  `{PG_CAPTURE, IDC_COLOURS_LABEL, S_C_COLOURS}`;
- the combos are filled where the other ones are filled (in `WM_INITDIALOG`, next
  to the theme and the detect combos): the frame rates as the numbers
  (`"10", "15", "20", "30"`) and the palette sizes as the numbers
  (`"256", "128", "64"`), and then `CB_SETCURSEL` with the setting;
- the change is handled in `page_command`, where the other settings' combos are
  handled:

  ```c
  int *choice = id == IDC_THEME ? &S.cfg.theme : id == IDC_DETECT ? &S.cfg.detect
             : id == IDC_NAME ? &S.cfg.name : id == IDC_FPS ? &S.cfg.fps : id == IDC_COLOURS ? &S.cfg.colours : NULL;
  ```

  The frame rate and the palette size are numbers, so the combo holds the number
  itself and the index in the list is the index in `kFps` / `kColours`.

- [ ] **Step 3: the texts**

`src/lang_text.h` — the new rows go into the shared section (not the `CONSOLE`
one), each with all eight languages, in the existing `X(name, zh-Hans, zh-Hant, en,
ja, ko, fr, de, es)` order:

| Row | What it is |
|---|---|
| `TIP_GIF` | the tooltip of the new button: "Record as GIF". It goes **right after `TIP_BACK`**, because `tip_text` maps the buttons onto the rows by position (Task 5). |
| `REC_STOP` | the button of the panel: "Stop". |
| `REC_TIME` | "Time". |
| `REC_FRAMES` | "Frames". |
| `REC_SIZE` | "Size". |
| `C_FPS` | the label of the frame rate in the preferences: "Frame rate". In `src/settings.c` it is `S_C_FPS` (the enum adds the `S_`). |
| `C_COLOURS` | the label of the palette size: "Colours". In `src/settings.c` it is `S_C_COLOURS`. |

The notice that says the file was saved is the one the quick capture already shows
(`QUICK_SAVED`), so it needs no new row.

**The eight languages are not optional.** The Chinese texts are the ones the
program is written in; the other seven are translations of them. Where a
translation does not fit the space (the panel is small), the English word is kept
as it is in the existing rows.

- [ ] **Step 4: build**

Run: `bash tools/build.sh`
Expected: no warning. The languages are compiled into the program (`src/lang.c`
reads the rows of `lang_text.h`), so a row that is missing in one language shows
up as an empty string at run time, not as a build error — check that every new
row has all eight.

- [ ] **Step 5: commit**

```bash
git add src/config.h src/config.c src/settings.c res/resource.h res/sniplite.rc src/lang_text.h
git commit -m "the settings: the frame rate and the size of the palette"
```

---

### Task 7: The whole thing

**Files:**
- Modify: `docs/superpowers/specs/2026-11-27-gif-recording-design.md` (what changed)

- [ ] **Step 1: the checks that can run here**

Run: `python3 tools/gifref/check.py` → the reference against itself, all pass.
Run: `python3 tools/gifref/check.py tools/gifref/gifenc` → the byte-exact
comparison, all pass.
Run: `bash tools/build.sh` → no warning.

- [ ] **Step 2: the size**

Run: `ls -l build/sniplite.exe`
Expected: under 400 KB (the ceiling from the spec). It was 326144 bytes; the
feature is estimated at 25–35 KB.

If it is over, the first thing to look at is the icon table and the strings: the
author watches this number.

- [ ] **Step 3: the list for the user's machine**

The program cannot be run here (WSL2, the Windows interop is broken, no wine).
The user runs these on Windows, with the built `build/sniplite.exe`:

1. a small region (say 400x300) records and the file opens in a browser and shows
   the animation;
2. the whole screen (1920x1080) records, and the file's logical screen is
   1280x720 — the picture is scaled down;
3. the panel shows the time, the number of frames and the size, and it is **not**
   in the recording;
4. Enter stops it and the file is saved where the settings say, with the name the
   other saves use;
5. Esc stops it and **no file is left behind**;
6. starting a capture while the recording runs ends it, and the partial file is
   gone;
7. the frame rate and the palette size in the preferences change what is recorded
   (30 fps, 64 colours);
8. the program still starts, captures, copies, pins and saves as it did — the
   toolbar has one more button and nothing else moved.

- [ ] **Step 4: the issue and the pull request**

**Only after the feature works** — that is what the user asked for, twice.

The issue on upstream (issue #19 is the one to answer): what the feature does,
the two things that needed deciding (the encoder is written here rather than
taken from elsewhere, and the frame rate and the palette size are settings), and
that the code is ready. Mention the open pull request #33 (MP4 through DXGI), so
that the author can say what he thinks of two recorders in one program.

The pull request: the branch with the commits of Tasks 1 to 6 (Task 1's
`tools/build.sh` is ours and stays out of it), the description points at the
design document, and the check in `tools/gifref/` is there so a reader can run it.

- [ ] **Step 5: update the design document**

Anything that changed while it was built goes back into
`docs/superpowers/specs/2026-11-27-gif-recording-design.md`, so that the document
and the program agree.
