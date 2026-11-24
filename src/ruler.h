/* Screen ruler geometry, readout and drawing. Shared by the overlay's ruler
 * mode now and by the always-on ruler bars later (ruler_win.c). */
#pragma once
#include "common.h"
#include "draw.h"

/* ax..by: the two ends; cx..cy: the centre Alt measures from; px..py: the mouse.
 * The overlay keeps one of these in OvState at OV_RULER_AX (ov_layout.inc). */
typedef struct {
    int ax, ay, bx, by;
    int cx, cy;
    int px, py;
} RulerGeom;

/* "w × h  l px  a°" into out (cap WCHARs, including the 0); returns its length. */
int ruler_label(WCHAR *out, int cap, const RulerGeom *g);
/* Move the end being dragged to g->px/py; Shift locks to 0/45/90 degrees, Alt
 * measures from the centre. drag: 1 = A, 2 = B, 0 = nothing. */
void ruler_move(RulerGeom *g, int drag, int shift, int alt);
/* The measurement line, its right-angle guides, and the two end discs. */
void ruler_draw(const Surf *s, const RulerGeom *g, float scale);
/* The tick step for a ruler band: 1, 2 or 5 times a power of ten, at least
 * min_px pixels at the given scale (1000 = 100%). */
int ruler_tick_step(int scale1000, int min_px);