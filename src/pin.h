/* Pinned images: borderless topmost windows. */
#pragma once
#include "common.h"

bool pin_init(HINSTANCE inst, HWND daemon);
/* Takes ownership of img. at_cursor: center on the cursor and shrink to fit the monitor;
 * otherwise the top-left goes to (x, y) at 100%. */
bool pin_add(Img *img, int x, int y, bool at_cursor);
void pin_toggle_all(void);
bool pin_any_visible(void);
void pin_close_all(void);
int pin_count(void);
