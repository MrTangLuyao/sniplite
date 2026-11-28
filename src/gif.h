/* gif.c: the GIF encoder. */
#pragma once
#include "common.h"

typedef struct Lzw Lzw; /* the LZW's dictionary: gif.c's own */

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
    Lzw *lzw;
} Gif;

/* Start a GIF of a region: its size and how many colours the palette may hold.
 * Nothing is written until the first frame. False when there is no memory. */
bool gif_begin(Gif *g, int w, int h, int ncolours);
/* Write one frame of indices: its size, where it sits in the picture, and how
 * long it is shown (in hundredths of a second). The bytes are in g->buf. */
bool gif_write_frame(Gif *g, const uint8_t *idx, int fw, int fh, int fx, int fy, int delay_cs);
/* The last byte of the file. */
bool gif_end(Gif *g);
/* The memory the encoder took. */
void gif_free(Gif *g);
