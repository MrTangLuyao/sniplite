/* Always-on edge ruler: tick bars along the top and left of the monitor under
 * the mouse. They are layered, take no focus or clicks, and stay out of
 * captures so screenshots do not include them. */
#pragma once
#include "common.h"

/* Show on the monitor the mouse is on; rebuilds the bars if already shown. */
bool edge_ruler_show(void);
void edge_ruler_hide(void);
void edge_ruler_toggle(void);
bool edge_ruler_visible(void);
/* A display mode or layout change: rebuild at the mouse's new monitor. */
void edge_ruler_refresh(void);
/* The crosshair and coordinate box, shown with the ruler by default. */
bool edge_ruler_cross_enabled(void);
void edge_ruler_cross_set(bool on);
void edge_ruler_cross_toggle(void);
/* The crosshair and coordinate box color, 0xRRGGBB. */
void edge_ruler_set_color(uint32_t color);
