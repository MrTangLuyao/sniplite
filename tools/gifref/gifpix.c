/* gifpix.c: the encoder of src/gif.c, driven with pixels instead of indices.
 *
 * Build:  cc -O2 -Itools/gifref/win -Isrc -o gifpix gifpix.c ../../src/gif.c
 * Use:    ./gifpix <out.gif> <width> <height> <nframes> <mode>
 *
 * The picture is a checkerboard of four flat colours, with a block that moves
 * from frame to frame. The colours are few enough for the palette to hold
 * them exactly, so what comes back out of the file is the picture that went
 * in.
 *
 * The file is written as it goes: <out.gif>.<n> holds the file after the n-th
 * frame, so that the checker can see that it is a valid GIF all the way.
 *
 * The project has its own allocator (src/util.c) and it is not in libc under
 * those names: this program has one of its own.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gif.h"

#define FPS 15

void *mem_alloc(size_t n) { return calloc(1, n ? n : 1); }
void *mem_grow(void *p, size_t n) { return realloc(p, n ? n : 1); }
void mem_free(void *p) { free(p); }

/* The picture of a frame: the checkerboard, and the block on top of it. */
static void picture(uint32_t *px, int w, int h, int n, int mode)
{
    static const uint32_t cols[4] = {0x000000, 0xFFFFFF, 0xFF0000, 0x0000FF};
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            px[(size_t)y * w + x] = cols[((x / 8) + (y / 8)) % 4];
    int x0 = 0, y0 = h / 4;
    uint32_t c = 0;
    if (mode == 3) {
        /* a gradient: every pixel is a colour of its own, so the palette has to
         * be cut out of the colour cube */
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                px[(size_t)y * w + x] = ((uint32_t)(x * 255 / (w > 1 ? w - 1 : 1)) << 16) |
                                        ((uint32_t)(y * 255 / (h > 1 ? h - 1 : 1)) << 8) | 0x40;
        return;
    }
    if (mode == 0) {
        x0 = n * 4;
        c = 0xFF0000;
    } else if (mode == 2 && n >= 1) {
        x0 = w / 2;
        c = 0xC8C8C8; /* a colour the palette does not have: the nearest of the four */
    }
    if (!c)
        return;
    for (int y = y0; y < y0 + 16 && y < h; y++)
        for (int x = x0; x < x0 + 16 && x < w; x++)
            px[(size_t)y * w + x] = c;
}

/* The delay of a frame: from its number, so that the total comes out right. */
static int delay_of(int n)
{
    int a = (int)((n + 1) * 100.0 / FPS + 0.5), b = (int)(n * 100.0 / FPS + 0.5);
    return a - b;
}

int main(int argc, char **argv)
{
    if (argc < 6) {
        fprintf(stderr, "gifpix <out.gif> <w> <h> <nframes> <mode>\n");
        return 2;
    }
    int w = atoi(argv[2]), h = atoi(argv[3]), nframes = atoi(argv[4]), mode = atoi(argv[5]);
    uint32_t *px = malloc((size_t)w * h * 4);
    if (!px)
        return 1;
    Gif g;
    if (!gif_begin(&g, w, h, 256)) {
        free(px);
        return 1;
    }
    /* the file as it is so far: the bytes of every frame, one after the other */
    uint8_t *all = NULL;
    size_t alln = 0, allcap = 0;
    for (int n = 0; n < nframes; n++) {
        picture(px, w, h, n, mode);
        if (!gif_frame(&g, px, w, delay_of(n))) {
            free(px);
            return 1;
        }
        if (alln + (size_t)g.n > allcap) {
            size_t cap = allcap ? allcap : 4096;
            while (cap < alln + (size_t)g.n)
                cap *= 2;
            uint8_t *p = realloc(all, cap);
            if (!p) {
                free(px);
                return 1;
            }
            all = p;
            allcap = cap;
        }
        memcpy(all + alln, g.buf, (size_t)g.n);
        alln += (size_t)g.n;
        char name[512];
        snprintf(name, sizeof name, "%s.%d", argv[1], n + 1);
        FILE *f = fopen(name, "wb");
        if (!f) {
            free(px);
            return 1;
        }
        fwrite(all, 1, alln, f);
        fclose(f);
    }
    if (!gif_end(&g)) {
        free(px);
        return 1;
    }
    FILE *f = fopen(argv[1], "wb");
    if (f) {
        fwrite(all, 1, alln, f);
        fwrite(g.buf, 1, (size_t)g.n, f);
        fclose(f);
    }
    free(all);
    gif_free(&g);
    free(px);
    return 0;
}
