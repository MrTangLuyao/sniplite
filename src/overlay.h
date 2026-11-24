/* The full-screen capture overlay: selection, annotation, output. */
#pragma once
#include "common.h"

/* Where the time from hotkey to visible overlay went (milliseconds). */
typedef struct {
    double total;   /* hotkey handler start -> overlay uncloaked (visible from the next DWM frame) */
    double grab;    /* screen capture; the overlay window is prepared during its GPU wait */
    double windows; /* window enumeration, runs in parallel with grab */
    double paint;   /* first full-screen paint */
    double focus;   /* activation after becoming visible (does not delay what you see) */
} OvTiming;

bool ov_init(HINSTANCE inst, HWND daemon);
bool ov_begin(void);      /* start an interactive capture; false if busy or failed */
bool ov_begin_pick(void); /* the color picker: the same overlay, no selection */
bool ov_begin_ruler(void); /* the screen ruler: the same overlay, no selection */
bool ov_active(void);
void ov_pin_hotkey(void); /* pin hotkey pressed while capturing */
void ruler_copy(void);    /* the ruler's readout as text, without leaving it */
void ov_cancel(void);
bool ov_last_timing(OvTiming *t); /* false before the first capture */
/* main.c: the user leaves (Esc, a close button). A capture that holds something may ask first. */
void ov_leave(void);        /* the capture itself: asks when a selection is made */
bool leave_ok(HWND owner);  /* the question alone, above owner; true: leave */
void color_hex_set(int on); /* main.c: keep the picker's HEX / RGB choice */
/* main.c: a capture was copied or pinned and is off the screen. While the settings say "also save",
 * its picture goes into a file too. */
void also_save(const uint32_t *px, int w, int h);

/* scroll.c: the long screenshot. long_begin is called by the capture, which closes
 * right after: its selection becomes the region that grows as the user scrolls. */
void long_begin(void);
void long_cancel(void);

#ifdef SNIPLITE_DEMO
/* README image generator only (tools/mkdemo.c). Tool ids follow the toolbar:
 * 1 rect, 2 ellipse, 3 line, 4 arrow, 5 pen, 6 marker, 7 mosaic, 8 text, 9 number. */
typedef struct {
    int tool, color_idx, size_idx;
    POINT a, b;
    const WCHAR *text;
} DemoAnno;

typedef struct {
    int phase;   /* 1: choosing (highlight + magnifier), 2: editing (toolbar), 3: annotated selection only */
    RECT sel;    /* phase 1: highlighted window; phase 2: selection */
    POINT cursor;
    int tool, color_idx, size_idx, hover; /* hover: toolbar id whose tooltip shows */
    int nanno;
    DemoAnno anno[16];
} DemoScene;

bool ov_demo_render(const Img *screen, float scale, const DemoScene *sc, Img *out);
#endif
