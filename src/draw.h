/* Tiny anti-aliased software rasterizer for 32bpp BGRX buffers. */
#pragma once
#include "common.h"

/* A drawing target. Pixel (x, y) in "world" coordinates lives at
 * px[(y - oy) * stride + (x - ox)]; nothing outside clip is touched. */
typedef struct {
    uint32_t *px;
    int stride; /* in pixels */
    int ox, oy;
    RECT clip;
} Surf;

static inline Surf surf_img(const Img *im, int ox, int oy)
{
    Surf s = {im->px, im->w, ox, oy, {ox, oy, ox + im->w, oy + im->h}};
    return s;
}

static inline uint32_t *surf_at(const Surf *s, int x, int y)
{
    return s->px + (size_t)(y - s->oy) * (size_t)s->stride + (size_t)(x - s->ox);
}

/* Colors are 0xRRGGBB, alpha arguments are 0..255. */
void d_fill(const Surf *s, RECT r, uint32_t c);
void d_fill_alpha(const Surf *s, RECT r, uint32_t c, int a);
void d_frame(const Surf *s, RECT r, int t, uint32_t c); /* border of thickness t inside r */
void d_dash_frame(const Surf *s, RECT r, uint32_t c1, uint32_t c2, int dash);

/* Coordinates below are continuous: the center of pixel (x, y) is (x + .5, y + .5). */
void d_line(const Surf *s, float x0, float y0, float x1, float y1, float w, uint32_t c, int a);
void d_polyline(const Surf *s, const float *xy, int n, float w, uint32_t c, int a, bool multiply);
void d_ellipse(const Surf *s, float cx, float cy, float rx, float ry, float w, uint32_t c, int a);
void d_disc(const Surf *s, float cx, float cy, float r, uint32_t c, int a);
void d_convex(const Surf *s, const float *xy, int n, uint32_t c, int a);
void d_arrow(const Surf *s, float x0, float y0, float x1, float y1, float w, uint32_t c);

/* Pixelate r on dst; block averages are read from src (may equal dst). */
void d_mosaic(const Surf *dst, const Surf *src, RECT r, int block);

/* Darken n pixels from src into dst (screenshot backdrop). */
void d_dim_row(uint32_t *dst, const uint32_t *src, int n);

enum {
    IC_RECT, IC_ELLIPSE, IC_LINE, IC_ARROW, IC_PEN, IC_MARKER, IC_MOSAIC, IC_TEXT, IC_NUMBER,
    IC_UNDO, IC_REDO, IC_PIN, IC_SAVE, IC_CLOSE, IC_OK,
};
/* Draw a toolbar icon into the box (x, y, size, size). */
void d_icon(const Surf *s, int icon, float x, float y, float size, uint32_t c);

/* Free the scratch mask kept between calls. */
void draw_release(void);
