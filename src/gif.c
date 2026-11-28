/* gif.c: the GIF encoder: the container and the LZW.
 *
 * The bytes of a GIF89a file are written one frame at a time. The caller writes
 * what comes out to the file as it goes, so the file on disk is a valid GIF up
 * to the last frame that was written.
 *
 * The rules of the LZW below are the ones that look wrong and are right: a
 * decoder that reads them differently does not show the picture. They are
 * written down because the neighbours look right too.
 */
#include "gif.h"

#define HASH 8192         /* the dictionary's table: twice the dictionary, to keep the chains short */
#define EMPTY 0xFFFFFFFFu /* a free slot of the table */

struct Lzw {
    uint32_t key[HASH]; /* the (prefix, character) of an entry */
    uint16_t val[HASH]; /* the code of that entry */
    uint8_t *out;       /* the codes, as bytes: the blocks of the file come out of it */
    int n, cap;
    int mincode;         /* the size of the smallest code: the size of the palette */
    int clear, end;      /* the clear code, the end code */
    int next, size, old; /* the next free entry, the size of the code in bits, the last code */
    uint32_t acc;        /* the bits that have not been written out yet */
    int nbits;
};

/* ---- the bytes ---- */

static bool buf_room(Gif *g, int n)
{
    if (g->n + n <= g->cap)
        return true;
    int cap = g->cap ? g->cap : 4096;
    while (cap < g->n + n)
        cap *= 2;
    uint8_t *p = mem_grow(g->buf, (size_t)cap);
    if (!p)
        return false;
    g->buf = p;
    g->cap = cap;
    return true;
}

static bool buf_byte(Gif *g, int b)
{
    if (!buf_room(g, 1))
        return false;
    g->buf[g->n++] = (uint8_t)b;
    return true;
}

static bool buf_word(Gif *g, int v)
{
    if (!buf_byte(g, v & 0xFF) || !buf_byte(g, (v >> 8) & 0xFF))
        return false;
    return true;
}

static bool buf_bytes(Gif *g, const void *p, int n)
{
    if (!buf_room(g, n))
        return false;
    memcpy(g->buf + g->n, p, (size_t)n);
    g->n += n;
    return true;
}

/* ---- the LZW ---- */

/* The dictionary starts over: the codes are the size they were at the start,
 * and the table of the entries is empty. The bits that are in the accumulator
 * are not touched: they belong to the code that is being written. */
static void lzw_reset(Lzw *l)
{
    memset(l->key, 0xFF, sizeof l->key);
    l->next = l->end + 1;
    l->size = l->mincode + 1;
    l->old = -1;
}

static bool out_byte(Lzw *l, int b)
{
    if (l->n >= l->cap) {
        int cap = l->cap ? l->cap * 2 : 4096;
        uint8_t *p = mem_grow(l->out, (size_t)cap);
        if (!p)
            return false;
        l->out = p;
        l->cap = cap;
    }
    l->out[l->n++] = (uint8_t)b;
    return true;
}

static bool put_code(Lzw *l, int code)
{
    l->acc |= (uint32_t)code << l->nbits;
    l->nbits += l->size;
    while (l->nbits >= 8) {
        if (!out_byte(l, l->acc & 0xFF))
            return false;
        l->acc >>= 8;
        l->nbits -= 8;
    }
    return true;
}

/* The entry for a prefix and a character, or -1 when there is none. */
static int lzw_find(Lzw *l, int prefix, int ch)
{
    uint32_t key = ((uint32_t)prefix << 8) | (uint32_t)ch;
    uint32_t h = (key * 2654435761u) >> 19; /* the top bits of the product: the buckets */
    while (l->key[h] != EMPTY && l->key[h] != key)
        h = (h + 1) & (HASH - 1);
    return l->key[h] == key ? l->val[h] : -1;
}

static void lzw_add(Lzw *l, int prefix, int ch, int code)
{
    uint32_t key = ((uint32_t)prefix << 8) | (uint32_t)ch;
    uint32_t h = (key * 2654435761u) >> 19;
    while (l->key[h] != EMPTY)
        h = (h + 1) & (HASH - 1);
    l->key[h] = key;
    l->val[h] = (uint16_t)code;
}

/* The indices of a frame, as the codes of the LZW.
 *
 * The clear code goes out first, so that the decoder starts in step. The size
 * of the code grows when the next free entry passes what the size can hold: the
 * decoder grows its own size at the same point in the stream, one entry later,
 * and the two have to agree or the picture turns to noise. When the dictionary
 * is full a clear code goes out and the dictionary starts over; the bits in
 * the accumulator are not reset then, only at the start of the file. */
static bool lzw_write(Lzw *l, const uint8_t *idx, int n)
{
    lzw_reset(l);
    l->n = 0;
    if (!put_code(l, l->clear))
        return false;
    for (int i = 0; i < n; i++) {
        int k = idx[i];
        if (l->old < 0) {
            l->old = k;
            continue;
        }
        int found = lzw_find(l, l->old, k);
        if (found >= 0) {
            l->old = found;
            continue;
        }
        if (!put_code(l, l->old))
            return false;
        if (l->next < 4096) {
            lzw_add(l, l->old, k, l->next);
            l->next++;
            if (l->next > (1 << l->size) && l->size < 12)
                l->size++;
        } else {
            if (!put_code(l, l->clear))
                return false;
            lzw_reset(l);
            if (!put_code(l, l->clear))
                return false;
            l->old = k;
            continue;
        }
        l->old = k;
    }
    if (l->old >= 0 && !put_code(l, l->old))
        return false;
    if (!put_code(l, l->end))
        return false;
    if (l->nbits > 0 && !out_byte(l, l->acc & 0xFF))
        return false;
    return true;
}

/* ---- the file ---- */

bool gif_begin(Gif *g, int w, int h, int ncolours)
{
    memset(g, 0, sizeof *g);
    g->w = w;
    g->h = h;
    g->ncolours = ncolours;
    g->trans = -1;
    g->lzw = mem_alloc(sizeof *g->lzw);
    if (!g->lzw)
        return false;
    int mincode = 2;
    while ((1 << mincode) < ncolours)
        mincode++;
    g->lzw->mincode = mincode;
    g->lzw->clear = 1 << mincode;
    g->lzw->end = g->lzw->clear + 1;
    return true;
}

void gif_free(Gif *g)
{
    mem_free(g->buf);
    if (g->lzw) {
        mem_free(g->lzw->out);
        mem_free(g->lzw);
    }
    memset(g, 0, sizeof *g);
}

bool gif_write_frame(Gif *g, const uint8_t *idx, int fw, int fh, int fx, int fy, int delay_cs)
{
    g->n = 0; /* the buffer holds the bytes of this frame alone */
    if (!g->started) {
        /* the header and the logical screen descriptor */
        if (!buf_bytes(g, "GIF89a", 6) || !buf_word(g, g->w) || !buf_word(g, g->h))
            return false;
        if (!buf_byte(g, 0x80 | 0x70 | (g->lzw->mincode - 1)))
            return false;
        if (!buf_byte(g, 0) || !buf_byte(g, 0)) /* the background colour, the aspect ratio */
            return false;
        /* the global colour table */
        for (int i = 0; i < g->ncolours; i++)
            if (!buf_byte(g, g->pal[i][0]) || !buf_byte(g, g->pal[i][1]) || !buf_byte(g, g->pal[i][2]))
                return false;
        /* the Netscape extension: the animation loops forever */
        if (!buf_byte(g, 0x21) || !buf_byte(g, 0xFF) || !buf_byte(g, 0x0B))
            return false;
        if (!buf_bytes(g, "NETSCAPE2.0", 11) || !buf_byte(g, 0x03) || !buf_byte(g, 0x01))
            return false;
        if (!buf_word(g, 0) || !buf_byte(g, 0))
            return false;
        g->started = 1;
    }
    /* the graphic control extension: the delay, the disposal method, the
     * transparent index */
    if (!buf_byte(g, 0x21) || !buf_byte(g, 0xF9) || !buf_byte(g, 0x04))
        return false;
    if (!buf_byte(g, 0x04 | (g->trans >= 0 ? 1 : 0)))
        return false;
    if (!buf_word(g, delay_cs))
        return false;
    if (!buf_byte(g, g->trans >= 0 ? g->trans : 0) || !buf_byte(g, 0))
        return false;
    /* the image descriptor */
    if (!buf_byte(g, 0x2C) || !buf_word(g, fx) || !buf_word(g, fy))
        return false;
    if (!buf_word(g, fw) || !buf_word(g, fh) || !buf_byte(g, 0))
        return false;
    /* the data, in blocks of at most 255 bytes */
    if (!buf_byte(g, g->lzw->mincode))
        return false;
    if (!lzw_write(g->lzw, idx, fw * fh))
        return false;
    Lzw *l = g->lzw;
    for (int off = 0; off < l->n;) {
        int chunk = l->n - off;
        if (chunk > 255)
            chunk = 255;
        if (!buf_byte(g, chunk) || !buf_bytes(g, l->out + off, chunk))
            return false;
        off += chunk;
    }
    if (!buf_byte(g, 0)) /* the end of the blocks */
        return false;
    return true;
}

bool gif_end(Gif *g)
{
    g->n = 0;
    return buf_byte(g, 0x3B);
}
