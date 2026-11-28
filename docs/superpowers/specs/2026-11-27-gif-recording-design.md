# GIF recording in sniplite — design

Date: 2026-11-27. Author of this document: takenroot (a contributor).
Target: upstream pull request (MrTangLuyao/sniplite).

## Intent and why

sniplite can capture a region, stitch a long screenshot and read text. It cannot
record motion. A GIF of a small screen region is the shortest way to show what
happened on screen — a bug that reproduces only while something moves, a UI
animation, a terminal session scrolling.

The author was asked about this in issue #19 ("希望支持简单的屏幕录制，保存为 gif
（保存时可调文件压缩级别）") and answered on 2026-11-20:

> 你的第 3 4 5 已经实现了，但是 1 2 我觉得短期内不会实现 可以试试

So the feature is wanted, the author does not plan it, and he invited a
contribution. This document is the design for that contribution.

## Goals

- Record a chosen region of the screen as an animated GIF.
- The region is chosen the way every other capture in sniplite is chosen: the
  usual capture overlay, so the region may be any rectangle, including one that
  covers the whole screen.
- The recording is written as a single `.gif` file.
- The result opens in any GIF viewer, in a browser, and in every editor.

## Non-goals

- Not a video recorder. No MP4, no WebM, no audio.
- Not a general animation encoder. One region, one GIF, one file.
- Not a screen recorder with effects: no click markers, no zoom, no webcam
  overlay, no system-tray counter.
- No new runtime dependency. sniplite links only the Windows system libraries;
  that stays true.

## Anti-goals

- Do not pull in GDI+, giflib, stb_image or any other third-party code. The
  encoder is written from scratch in this project's style.
- Do not grow the program past what the author is comfortable shipping. The
  program is about 320 KB now; the whole feature must fit in 400 KB.
- Do not re-implement the capture path. The existing overlay and the existing
  region read are reused as they are.

## Constraints

These come from the project's own code and rules, and they shape every decision
below.

1. **Almost no C runtime.** `src/crt.c` has `memcpy`, `memmove`, `memset`,
   `memcmp` and a few wide-string functions; `src/util.c` has the allocator
   (`mem_alloc`, `mem_grow`, `mem_free`) and the growable string. What is
   missing is `qsort` — and there is no stdio at all, so the file is written
   with `CreateFileW` and `WriteFile`. The quantiser needs a sort; the
   project's own answer to that is in `src/ocr.c`, which has its own insertion
   sort because the lists are short or nearly sorted. The same trick works
   here, and it is the reason no library function has to be added.
2. **No new DLLs.** Only `kernel32`, `user32`, `gdi32`, `dwmapi`, `imm32`,
   `uuid` are linked (`build.bat`).
3. **Windows has no GIF encoder.** WIC can *decode* GIF but not encode it, and
   WIC is not linked here at all (it is loaded on demand by `image.S`, which
   uses it for PNG/JPEG/BMP). So the encoder is written from scratch.
4. **Eight languages.** Every user-visible string goes into `src/lang_text.h` in
   all eight, in the existing `X(name, ...)` order.
5. **Size.** The program must stay small. The author's README tracks it
   (280 KB to 320 KB after v1.5.0), so he notices.
6. **The author's style.** Dense C, four-space indent, comments that explain
   *why* rather than *what*, `/* */` comments, no tabs, lines under about 110
   columns.

## The approach, and why this one

### The encoder: written from scratch, in C

Three ways to get GIF bytes were considered.

**A. A separate module, like the OCR one.** The text recognition is optional
and lives outside the program: `src/ocr.c` *is* linked into the program, and
what is optional is the `onnxruntime.dll` and the models in the `ocr` folder.
So "the module" in this project means the data files, not the code. A GIF
encoder written as a separate DLL would be a new pattern with no precedent
here, and it would need an ABI between the program and the DLL. Rejected: the
author has no reason to accept a new mechanism, and the size saving is small
because the encoder is not the biggest part (see *Measurements*).

**B. GDI+.** `Gdiplus.dll` can write GIF. But: GDI+ writes a *single frame*
GIF (animation has to be assembled by hand around it), it pulls in a large
dependency for one format, and `gdiplus.dll` is not in the list of libraries
this program links. Rejected.

**C. Write the encoder here, in this project's C.** Within this, writing it in
assembly was measured (see *Measurements*) and turns out to be *no smaller*
than C for this algorithm, because GIF's LZW is branch-heavy rather than
memory-bound. The project's assembly is used where the work is pixel shuffling
(capture, composition, drawing), which is not what this is. C it is.

The encoder is therefore a new file, `src/gif.c` with `src/gif.h`, holding
three separable pieces:

- **quantisation**: 32-bit BGRA pixels to an index into a palette of up to 256
  colours.
- **LZW**: the indices to the compressed stream of a GIF frame.
- **the file**: the GIF89a container: header, logical screen descriptor,
  global colour table, per-frame graphic control extension, image descriptor,
  the LZW data in sub-blocks, and the trailer.

### The recording: the existing long-screenshot machinery, reused

`src/scroll.c` already does almost everything a recorder needs:

- it takes over the selection when the capture closes (`long_begin`, called
  from `ov_show.S` when the long-screenshot button is pressed),
- it reads the region from the screen several times a second with
  `GetDC(NULL)` and `BitBlt(..., SRCCOPY | CAPTUREBLT)` on a 30 ms timer,
- it draws a thin frame around the region and a bar of buttons below it,
- it puts `WDA_EXCLUDEFROMCAPTURE` on its own windows so they never end up in
  what it reads,
- it ends on a key (done/cancel) and on a button.

So the recorder is a new sibling of `scroll.c`, not a new subsystem. It gets
its own file `src/rec.c`, its own window class, and its own button on the
capture toolbar.

### The button: where it sits

The capture overlay has two phases. Phase 1 picks the region; phase 2 shows the
toolbar with the annotation tools and the buttons for what to do with the
selection. The text buttons (`B_OCR`, `B_OCRCOPY`) and the long-screenshot
button (`B_LONG`) are already there, in `kTbOrder` in `src/ov_base.S`, with
their own button ids in `src/ov_layout.inc`.

The GIF recording gets one more button there, `B_GIF`, next to `B_LONG`:

1. F1 (or the tray, or the CLI) starts the capture,
2. the user drags out the region — any region, up to the whole screen,
3. the toolbar appears; the user presses the GIF button,
4. the capture closes and the recorder takes over that region,
5. the recorder runs; the user presses Enter (done) or Esc (cancel),
6. the file is written, and a notice says where it went.

This is exactly the path the long screenshot already takes, so it needs no new
flow, no new dialog and no new hotkey. A hotkey could be added later; it is
not in this design.

### Size of the result

A GIF of a whole screen at 15 fps is large: 1920x1080 is 2.07 million pixels
per second, and GIF has 256 colours per frame and no inter-frame prediction
except what the format offers. Three measures keep the file usable, and all
three are in this design:

1. **Frame differencing with a transparent index.** GIF's own format for this:
   the first frame is the whole region; each frame after it holds only the
   rectangle that changed, and the pixels inside that rectangle that did not
   change are the transparent index, so the previous frame shows through them.
   A screen that is mostly still then costs almost nothing per frame.
   The disposal method is **1 ("do not dispose")**, so the frames pile up on the
   canvas instead of each one replacing the last. (Disposal 2, "restore to
   background", would clear each frame's rectangle after its delay, and the
   animation would fall apart.)
2. **Downscaling when the region is large.** A region whose picture is bigger
   than 1280x720 is scaled down to fit that, keeping its proportions. A whole
   1920x1080 screen becomes 1280x720, which is 44% of the pixels. The rule is
   in one place, so the logical screen of the file is the scaled size, not the
   size on screen.

   The scaling averages the pixels of each block rather than taking the
   nearest one, and the reason is flicker. Nearest-neighbour scaling to a
   fraction like 2:3 can drop some rows entirely and keep others; a line of
   text that lands on a dropped row vanishes for that frame and comes back
   for the next, and the recording shimmers. Averaging keeps every row's
   share of the light, so a row that is faint stays faint and the picture
   does not pulse. It costs a little sharpness, which is the right trade for
   something that moves.
3. **The delay unit.** GIF's frame delay is in hundredths of a second, and a
   frame rate rarely divides into that. 15 fps is 6.67 hundredths, 30 fps is
   3.33. The delay of each frame is therefore computed from the frame's number
   rather than from a fixed number: frame *n* waits `round((n+1) * 100/fps) -
   round(n * 100/fps)` hundredths. The total then comes out right over any
   number of frames, and no frame is systematically long or short. 10 and 20
   fps divide exactly and need none of this. This is in the code as a comment,
   because a fixed delay that is one hundredth off looks right for a while
   and then drifts.

The frame rate is a setting: 10, 15, 20 or 30 fps, 30 the highest. The
default is 15.

If the machine cannot keep up — a whole screen at 30 fps, on a slow disk —
the frames that arrive late are simply late. The delay of each frame is
computed from its number, not from a clock, so the animation plays at the
rate that was asked for, with the frames that were missed missing from it.
The alternative, stretching the delays to match what really happened, would
make a recording of a slow moment play slowly, which is worse: the point of
the delay is the frame rate the user chose.

## The parts, in detail

### `src/gif.h` — the interface

```c
/* gif.c: the GIF encoder. */
#pragma once
#include "common.h"

/* A GIF being written: the bytes come out one frame at a time. */
typedef struct {
    uint8_t *buf;    /* the bytes of the last chunk: what the caller writes to the file */
    int n, cap;
    int w, h;        /* the logical screen: the size of the region */
    int nframes;
    int npal;        /* the colours in the palette */
    uint8_t pal[256][3];  /* the palette: one table for the whole file */
    uint8_t *prev;   /* the indices of the frame before, one byte per pixel */
    int trans;       /* the palette entry that means "unchanged", -1 for none */
    int ncolours;    /* how many colours the palette may hold */
    int started;     /* the header and the palette have been written */
} Gif;

/* Start a GIF of a region: its size, and how many colours the palette may hold.
 * Nothing is written until the first frame. */
void gif_begin(Gif *g, int w, int h, int ncolours);
/* Add a frame: the pixels (top-down 32-bit BGRA), the delay in hundredths of a
 * second. The encoder finds the part that changed by itself. The bytes of the
 * frame are in g->buf; the first frame's chunk holds the header and the palette. */
void gif_frame(Gif *g, const uint32_t *px, int stride, int delay_cs);
/* The last byte of the file. */
void gif_end(Gif *g);
/* The memory the encoder took. */
void gif_free(Gif *g);

/* The writer on its own: a frame of indices with the palette already in g->pal.
 * The check in tools/gifref/ uses this to compare the bytes with the reference. */
void gif_write_frame(Gif *g, const uint8_t *idx, int fw, int fh, int fx, int fy, int delay_cs);
```

**The palette is global: one table for the whole file.** It is built from the
first frame, and it stays. A palette that changed from frame to frame would
make the colours flicker, and it would cost a table per frame.

The first frame therefore decides the colours. Later frames that bring colours
the palette does not have get the nearest entry, which for a screen is
usually right: a screen has few colours and they change slowly. The first
frame of a recording is a fair sample of the rest.

One palette entry is kept for transparency: the entry the encoder uses for the
pixels that did not change. The quantiser is told to leave it alone, so it
gets 255 real colours rather than 256. That is the price of the delta
frames, and it is a fair one.

**The encoder keeps the previous frame** as palette indices, one byte per
pixel, not as pixels. Two things follow from that: the comparison that finds
the changed part is done on indices, so two different pixels that happen to
quantise to the same colour count as unchanged, and the memory is a quarter
of what the pixels would take. The order is: quantise, then compare.

### `src/gif.c` — the encoder

**Quantisation.** The pixels are reduced to a palette of 256 colours with
median cut: split the colour cube on the longest axis of the colours that are
there, repeatedly, until 256 boxes are left; the average of each box is its
palette entry. Median cut is chosen over octree because it is simpler to get
right and its result is good enough for a screen, where the colours are few
and flat. A cache of the last mapping (a small direct-mapped table keyed on
the top bits of each channel) keeps the per-pixel cost low: a screen has few
distinct colours, so the cache hits almost always.

**LZW.** The classic GIF variant: 9 bits at the start, a clear code (256) and
an end code (257), the dictionary growing to 4096 entries, and the code size
growing one bit at a time. The rule that the code size grows when the next
free slot passes what the current size can hold is the one that decoders
expect; it was settled by testing against an independent decoder, and it is
written down in a comment because the neighbouring rules also look right.

When the dictionary is full, a clear code goes out and the dictionary starts
over. The accumulator and the bits in it are *not* reset then, only at the
start of a file. That distinction is the bug a first version of this would
have had.

**The container.** GIF89a. The header, the logical screen descriptor (the size
of the region), the global colour table, then for each frame: the graphic
control extension (the delay, the disposal method, the transparent index), the
image descriptor (where in the picture this frame's pixels are), the minimum
code size, the LZW data in sub-blocks of at most 255 bytes, and the block
terminator. The trailer ends the file. The Netscape 2.0 application extension
is written so the animation loops forever.

The bytes of that container are fixed here, down to the flags, because the
reference in `tools/gifref/` has to write exactly the same ones for the
comparison to be exact: the reference is the plainest possible version of
*this* format, not of some other one.

**Every tick writes a frame.** A frame in which nothing changed is written as
a 1x1 frame whose one pixel is the transparent index: the picture does not
change, and the file grows by about twenty bytes. The alternative — leaving
the frame out — would make the delay of the next frame the sum of all the
ones in between, and that sum does not fit in the one byte a GIF gives a
delay. A recording of a still screen would then play too fast.

### The file on disk

The file is written as the recording goes, not at the end. Only the first
frame has to wait: the palette comes from it, and the header comes before
it, so the file is opened and the header written once the first frame is
there, and every frame after that is appended.

Holding the whole file in memory instead would mean a long recording of a
whole screen grows into gigabytes of RAM, and a crash would lose all of it.
Writing as it goes means the memory is one frame, and the file on disk is
always a valid GIF up to the last frame written.

The size is therefore the size of the file on disk, which the panel shows.
There
is a cap, as the long screenshot has one (`MAX_PIXELS`, 160 MB): the
recording stops at 256 MB and the panel says so.

The file is written with `CreateFileW` and `WriteFile` — there is no stdio
here, and the project's own `image.S` does the same.

The name comes from the settings the other saves use: the folder and the
pattern in the capture page's "File name format". No dialog: the recording
writes to that folder and says where it put the file when it ends. (The
dialog would have to come first, before the recording starts, which is the
wrong way round.)

The name is made when the recording starts, so that two recordings in the
same second do not write over each other. The `.gif` ending is added to it,
the way the other saves add their own.

When the recording ends, the notice in the corner of the monitor says what
was saved and where. That is the same notice the quick capture shows
(`notice_corner` in `ocr_ui.c`), with the same texts, so nothing new is
needed for it: the line is the same "Saved" text and the path is the one
that was written.

### `src/rec.c` — the recorder

The shape of `scroll.c`, with the stitching replaced by the encoder.

- The region comes from the capture's selection, the way `long_begin` gets it.
- A timer reads the region with `BitBlt` and hands the pixels to the encoder.
- The frame that changed is found by comparing with the frame before: the
  rectangle that differs is what goes into the GIF.
- The interface is a small floating panel, and nothing else. No ring around
  the region, no toolbar: the region is recorded as it is, and the panel sits
  outside it. The panel shows the time so far, the number of frames, the size
  of the file so far, and one button, to stop.
- The size matters: the user should see a 40 MB file growing before it is a
  surprise.
- The panel is a `WS_EX_NOACTIVATE` window with `WDA_EXCLUDEFROMCAPTURE`, so
  it never appears in what it is recording, and it takes no focus.
- The panel is placed just outside the region, on whichever side has room,
  the way the long screenshot puts its strip. If there is no room on either
  side, it goes in the corner of the monitor the region is on.
- Enter stops the recording, as the button does. Esc stops it and throws the
  recording away.
- The window helpers (`make()` with `WDA_EXCLUDEFROMCAPTURE`, the panel, the
  hotkeys) are `static` in `scroll.c`. The recorder needs the same few, and
  the author's diff is easier to read if `scroll.c` is not touched: so they
  are written again in `rec.c`, small and plainly. If the author would rather
  they were shared, that is a small follow-up.
- A capture that starts while the recorder runs ends the recording the way it
  ends the long screenshot: the work is thrown away, because the user has
  moved on. (The long screenshot does the same, in `tick()`.) The file that
  was being written is deleted.
- The screen changing (a monitor unplugged, a resolution change) ends it too,
  and the same way.

The recorder has no message loop of its own: the daemon has one, and it
dispatches to whatever window the message is for, which is how the long
screenshot works too. The recorder's windows are therefore `WS_EX_NOACTIVATE`
ones that the daemon's loop reaches through their window procedures.

### The settings

On the capture page, next to the other capture settings:

- **Frame rate**: 10 / 15 / 20 / 30 fps. Default 15.
- **Quality**: how many colours the palette has. Three steps: 256, 128 or 64.
  Fewer colours means a smaller table and, more importantly, fewer distinct
  symbols for the LZW to work with, so the frames compress better. 64 colours
  is visibly posterised on a gradient, but on a screen with flat colours it
  is often not noticeable at all.

Both are stored in `sniplite.ini` next to the program, like every other
setting (`config.h` / `config.c`).

### The texts

New strings in `src/lang_text.h`, all eight languages:

- the button's tooltip ("Record as GIF"),
- the words in the panel: "Time", "Frames", "Size", and the one it says when
  the file is as big as it may be,
- the two settings' labels and their choices.

The panel's button is the check mark the long screenshot's bar uses for "done",
so it needs no text of its own.

The notice that says the file was saved is the one the quick capture already
shows, so it needs no new text.

### The icon

The toolbar button needs an icon in `src/draw_icons.inc`, in the same form as
the others: a small programme of lines and polygons in grid units. A filled
circle with a ring around it (a record button). The existing icons there are
the model.

## Measurements

The encoder's LZW part was written and measured before this document, so the
size and the correctness are known rather than guessed.

- The LZW encoder alone, in the project's real assembly macros and the real
  compiler flags: **692 bytes** of code. The same algorithm in C at `-Os`:
  **656 bytes**. C is no bigger, and much easier to review. This is why the
  encoder is C.
- The whole feature (encoder, quantisation, differencing, container, recorder
  UI, texts, icon) is estimated at **25 to 35 KB**, so the program goes from
  326144 bytes to roughly **355 KB**, under the 400 KB ceiling.
- The LZW encoder was tested against an independent decoder, on random data of
  many sizes and colour counts, and on ten adversarial patterns (all one
  colour, alternating, gradients, noise, sparse). All passed, byte for byte
  against a reference implementation.

## What is left to the builder

1. `src/gif.c` and `src/gif.h`: quantisation, LZW, the container. The LZW is
   the part with the fiddly rules; it is described above and a reference
   implementation exists.
2. `src/rec.c`: the recorder window, the timer, the differencing, the panel.
3. The button: `B_GIF` in `src/ov_layout.inc`, the entry in `kTbOrder` in
   `src/ov_base.S`, the call in `src/ov_show.S` next to `long_begin`.
   Three things in there will break the build if they are missed, so they are
   written down:
   - `B_GIF` goes into **both** `kTbOrder` and `kTbPlain` (`kTbPlain` is the
     table without the two text buttons), and `TB_ITEMS` becomes 23. The
     `.error` in `ov_base.S` checks both lengths and will stop the build.
   - `B_LAST` grows, because `tip_text` in `ov_paint.S` maps `B_UNDO..B_LAST`
     onto `S_TIP_UNDO, S_TIP_REDO, ...` **by position**. The new `TIP_GIF` has
     to sit at the matching place in `lang_text.h`, or every command's tooltip
     shifts by one.
   - the icon: `d_icon` in `draw.S` refuses an icon above 21, so the `IC_*`
     enum, the table in `draw_icons.inc` and that bound all grow. A filled
     circle is not one of the icon kinds; it is a filled polygon (kind 2), so
     the record button is an octagon.
4. The icon in `src/draw_icons.inc`.
5. The settings: `config.h`, `config.c`, `res/sniplite.rc`, `settings.c`.
   `config_save` writes the whole file by hand, so a new setting has to be
   added on both sides.
6. The texts in `src/lang_text.h`, all eight languages. They go in the part
   that is not under `#if CONSOLE` or `#if SETUP`, because both the program
   and the assembly need them.
7. `build.bat`: the new files in the link line.

### The reference implementation, and how the encoder is verified

While designing this, the LZW encoder was written and tested outside the
repository, in a form that can run on Linux, so that the bytes it produces
could be checked against an independent decoder. That harness is kept, in
`tools/` at the top of the repository (not in `src/`, so it is not part of the
program):

- `tools/gifref/` — the reference encoder, in C, and the driver that compares
  it with the encoder in `src/gif.c`. The same inputs go through both and the
  bytes must be equal.
- `tools/gifref/gifread.py` — an independent GIF reader, with its own LZW
  decoder, written so that it is a second opinion rather than a copy of the
  encoder's idea of the format.
- `tools/gifref/check.py` — the check that runs the encoder over a set of
  patterns (random data of many sizes and colour counts, and ten awkward
  patterns: all one colour, alternating, gradients, noise, sparse) and asks
  PIL to decode the result and compare the pixels.

**Why the harness is not in `src/`:** the program must not grow, and the
harness is not part of it. Why it is in the repository at all: the encoder's
correctness rests on it, and a reader of the pull request should be able to
run it. The harness needs Python and PIL, which is fine for a developer.

The same idea carries into the program itself: `sniplite.exe` gets no test
mode, because the author keeps the program small. The check runs outside.

The harness on Linux needs one thing the project's assembly does not have:
the `.S` files use directives that only exist for Windows PE. For the
reference (which is C) this does not matter; the harness compiles the C
encoder of `src/gif.c` directly.

**What has been verified so far.** The LZW part — the part with the fiddly
rules — was written in the project's own assembly dialect, with the project's
own macros and the project's own compiler flags, and was checked against the
reference and against PIL on the patterns above: all passed, byte for byte.
That work is what settled the two rules this document describes (the code
size growing, and the clear code when the dictionary is full) and it is what
the C encoder in `src/gif.c` will be written against. The C encoder itself is
not written yet.

## The pull request

The order is: implement here, then open the issue on upstream, then the pull
request. The author is at the moment very busy and does not reply quickly, so
the issue comes after the work, not before it.

**What changed while it was built** (the code is the truth; this is what it
came to be).

- The interface of `src/gif.h` is as it is above: the bytes come out one frame at
  a time, and the caller writes them to the file as they come.
- The palette's lookup is a table of the colour cube (32 levels a channel,
  32 KB), not a cache of the colours that were seen. A cache is fast for a
  screen, but a picture with more colours than the cache holds misses on every
  pixel, and the search of the palette then takes a quarter of a second a frame.
  With the table every pixel is one lookup, and the whole screen is read in
  about ten milliseconds.
- The colours of a frame are counted in a table of eight thousand entries of
  eight bytes: the colour and its place in the array in one word, so that the
  counting of a whole screen is one cache miss a pixel and not two.
- The picture of a region that is bigger than 1280x720 is scaled down by the
  recorder, before the encoder sees it. The averaging of the block is in
  `src/rec.c`, and the check of it is in `tools/gifref/check.py`: the check
  takes the code from the file, so that what is checked is what runs.
- The icon of the button is a circle in a ring. The icons have one colour and
  no filled circle, so the circle is a polygon of eight points and the ring is
  an ellipse.
- The recording stops when the file is as big as it may be (256 MB), and the
  panel says so; the user ends it with the key or the button as usual.
- The file is named when the recording starts, and it is written to the folder
  of the settings, or to the desktop when there is none.

**What upstream looks like now** (checked on 2026-11-28). The last release is
still v1.5.1, from 2026-11-20; nothing has been committed since. Issue #19 is
still open with one comment, the author's "可以试试", and nobody has taken it
up. There is no GIF anywhere in the program.

One thing to keep in mind: pull request #33 (from lvjunlei, still open, no
review yet) adds MP4 recording through DXGI and Media Foundation. That is a
different format from a GIF, and it reads the screen through the GPU where
this design reads it with `BitBlt`, the way the long screenshot does. If that
pull request is merged, the program would have two recorders, and the two
would want the same place in the toolbar. That is not a reason to hold off:
the author asked for a GIF and said he would not do one soon. But it is worth
saying so in the issue, so that the author can say what he thinks.

The issue says, in short: the feature from #19, what it does, the two things
that needed deciding (the encoder is written here rather than taken from
elsewhere, and the frame rate is a setting), and that the code is ready.

The pull request is a small series:

1. `gif.c` / `gif.h`: the encoder.
2. `rec.c`: the recorder.
3. the button, the icon, the settings, the texts.

The author's review is the point of the exercise, so the pull request should
say plainly what was measured, and where a rule came from.
