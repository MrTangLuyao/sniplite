/* refgif.c: a reference GIF encoder, used to check the one in src/gif.c.
 *
 * This is deliberately the plainest possible implementation of the GIF89a
 * format: it makes no attempt to be small or fast, only to be obviously
 * correct. The check compares its output with the encoder's, byte for byte.
 *
 * Build:  cc -O2 -o refgif refgif.c
 * Use:    ./refgif <out.gif> <width> <height> <pattern> [pixels.out]
 *         pattern: 0 random 1 gradient 2 all one colour 3 alternating
 *
 * With a fourth argument, the picture is also written out as raw bytes, one
 * per pixel, so that the checker can compare what the file gives back with
 * what went in. The picture is made with rand(), so it cannot be worked out
 * in another language.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- the LZW encoder, the plain way ---- */

/* The dictionary: for each entry, the code it stands for and the pixel it
 * ends with. Entries 0..255 are the literals, 256 the clear code, 257 the end
 * code, 258 and up the ones the encoder makes. */
static int pre[4096], suf[4096];

/* The code size grows when the next free slot passes what the size can hold.
 * That is the rule the decoders expect; the neighbouring rules also look
 * right and are wrong. */
static int next_code, code_size, old_code, nbits;
static unsigned long acc;

static unsigned char out[1 << 20];
static int outn;

static void put_code(int code)
{
    acc |= (unsigned long)code << nbits;
    nbits += code_size;
    while (nbits >= 8) {
        out[outn++] = (unsigned char)(acc & 0xFF);
        acc >>= 8;
        nbits -= 8;
    }
}

static void lzw_reset(void)
{
    next_code = 258;
    code_size = 9;
    old_code = -1;
    for (int i = 0; i < 256; i++) {
        pre[i] = -1;
        suf[i] = i;
    }
}

static void lzw_write(const unsigned char *idx, int n)
{
    lzw_reset();
    outn = 0;
    put_code(256); /* the clear code, so the decoder starts in step */
    for (int i = 0; i < n; i++) {
        int k = idx[i], found = -1;
        if (old_code < 0) {
            old_code = k;
            continue;
        }
        for (int j = 258; j < next_code; j++)
            if (pre[j] == old_code && suf[j] == k) {
                found = j;
                break;
            }
        if (found >= 0) {
            old_code = found;
            continue;
        }
        put_code(old_code);
        if (next_code < 4096) {
            pre[next_code] = old_code;
            suf[next_code] = k;
            next_code++;
            if (next_code > (1 << code_size) && code_size < 12)
                code_size++;
        } else {
            put_code(256);
            lzw_reset();
            put_code(256);
            old_code = k;
            continue;
        }
        old_code = k;
    }
    if (old_code >= 0)
        put_code(old_code);
    put_code(257); /* the end of the information */
    if (nbits > 0)
        out[outn++] = (unsigned char)(acc & 0xFF);
}

/* ---- the file ---- */

static void put_word(FILE *f, int v)
{
    fputc(v & 0xFF, f);
    fputc((v >> 8) & 0xFF, f);
}

/* The LZW data goes in sub-blocks of at most 255 bytes, each with its length
 * before it, and a zero length ends them. */
static void put_blocks(FILE *f, const unsigned char *p, int n)
{
    for (int off = 0; off < n; off += 255) {
        int chunk = n - off;
        if (chunk > 255)
            chunk = 255;
        fputc(chunk, f);
        fwrite(p + off, 1, chunk, f);
    }
    fputc(0, f);
}

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "refgif <out.gif> <w> <h> <pattern>\n");
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

    if (argc > 5) {
        FILE *px = fopen(argv[5], "wb");
        if (px) {
            fwrite(idx, 1, (size_t)n, px);
            fclose(px);
        }
    }
    FILE *f = fopen(argv[1], "wb");
    if (!f) {
        free(idx);
        return 1;
    }
    fputs("GIF89a", f);
    put_word(f, w);
    put_word(f, h);
    fputc(0x80 | 0x70 | 7, f); /* a global colour table of 256 */
    fputc(0, f);
    fputc(0, f);
    for (int i = 0; i < 256; i++) {
        fputc(i, f);
        fputc(i, f);
        fputc(i, f);
    }
    /* the Netscape extension: the animation loops forever */
    fputc(0x21, f);
    fputc(0xFF, f);
    fputc(0x0B, f);
    fputs("NETSCAPE2.0", f);
    fputc(0x03, f);
    fputc(0x01, f);
    put_word(f, 0);
    fputc(0, f);
    /* the graphic control extension: the delay, the disposal method 1 */
    fputc(0x21, f);
    fputc(0xF9, f);
    fputc(0x04, f);
    fputc(0x04, f); /* do not dispose */
    put_word(f, 7); /* the delay, in hundredths of a second */
    fputc(0, f);    /* no transparent index */
    fputc(0, f);    /* the end of the block */
    fputc(0x2C, f); /* the image descriptor */
    put_word(f, 0);
    put_word(f, 0);
    put_word(f, w);
    put_word(f, h);
    fputc(0, f);
    fputc(8, f); /* the minimum code size */
    lzw_write(idx, n);
    put_blocks(f, out, outn); /* the data in sub-blocks, and the zero that ends them */
    fputc(0x3B, f); /* the trailer */
    fclose(f);
    free(idx);
    return 0;
}
