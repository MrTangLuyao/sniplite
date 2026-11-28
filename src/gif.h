/* gif.c: the GIF encoder. */
#pragma once
#include "common.h"

typedef struct GifState GifState; /* what the encoder needs of its own */

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
    uint8_t *prev;   /* the indices of the frame before, one byte per pixel */
    uint8_t *idx;    /* the indices of the frame being made, one byte per pixel */
    GifState *state;
} Gif;

/* Start a GIF of a region: its size and how many colours the palette may hold.
 * Nothing is written until the first frame. False when there is no memory. */
bool gif_begin(Gif *g, int w, int h, int ncolours);
/* Write one frame of indices: its size, where it sits in the picture, how long
 * it is shown (in hundredths of a second), and the palette entry that means
 * "unchanged" (-1 when the frame has none). The bytes are in g->buf. */
bool gif_write_frame(Gif *g, const uint8_t *idx, int fw, int fh, int fx, int fy, int delay_cs, int trans);
/* One frame of pixels: 32-bit, top-down, 0x00RRGGBB. The delay is in hundredths
 * of a second. The encoder finds the part that changed by itself. The bytes of
 * the frame are in g->buf. */
bool gif_frame(Gif *g, const uint32_t *px, int stride, int delay_cs);
/* The last byte of the file. */
bool gif_end(Gif *g);
/* The memory the encoder took. */
void gif_free(Gif *g);
