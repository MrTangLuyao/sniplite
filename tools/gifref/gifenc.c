/* gifenc.c: the encoder of src/gif.c, driven the way the reference in this
 * folder is driven, so that the two files can be compared byte for byte.
 *
 * Build:  cc -O2 -Itools/gifref/win -Isrc -o gifenc gifenc.c ../../src/gif.c
 * Use:    ./gifenc <out.gif> <width> <height> <pattern>
 *         pattern: 0 random 1 gradient 2 all one colour 3 alternating
 *
 * The pictures are the ones refgif.c makes, down to the rand() sequence, and
 * the palette is the identity ramp: the encoder is given indices, not pixels,
 * so that what is compared is the container and the LZW, and nothing else.
 *
 * The project has its own allocator (src/util.c) and it is not in libc under
 * those names: this program has one of its own.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gif.h"

void *mem_alloc(size_t n) { return calloc(1, n ? n : 1); }
void *mem_grow(void *p, size_t n) { return realloc(p, n ? n : 1); }
void mem_free(void *p) { free(p); }

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "gifenc <out.gif> <w> <h> <pattern>\n");
        return 2;
    }
    int w = atoi(argv[2]), h = atoi(argv[3]), pattern = atoi(argv[4]);
    int n = w * h;
    unsigned char *idx = malloc((size_t)n);
    if (!idx)
        return 1;
    srand(12345);
    for (int i = 0; i < n; i++) {
        switch (pattern) {
            case 0: idx[i] = (unsigned char)(rand() & 0xFF); break;
            case 1: idx[i] = (unsigned char)((i * 7) & 0xFF); break;
            case 2: idx[i] = 7; break;
            default: idx[i] = (unsigned char)(i & 1 ? 0 : 255); break;
        }
    }
    FILE *f = fopen(argv[1], "wb");
    if (!f) {
        free(idx);
        return 1;
    }
    Gif g;
    if (!gif_begin(&g, w, h, 256)) {
        free(idx);
        return 1;
    }
    for (int i = 0; i < 256; i++)
        g.pal[i][0] = g.pal[i][1] = g.pal[i][2] = (uint8_t)i;
    g.npal = 256;
    if (!gif_write_frame(&g, idx, w, h, 0, 0, 7)) {
        free(idx);
        return 1;
    }
    fwrite(g.buf, 1, (size_t)g.n, f);
    if (!gif_end(&g)) {
        free(idx);
        return 1;
    }
    fwrite(g.buf, 1, (size_t)g.n, f);
    fclose(f);
    gif_free(&g);
    free(idx);
    return 0;
}
