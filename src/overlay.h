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
bool ov_active(void);
void ov_pin_hotkey(void); /* pin hotkey pressed while capturing */
void ov_cancel(void);
bool ov_last_timing(OvTiming *t); /* false before the first capture */

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
