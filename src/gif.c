/* gif.c: the GIF encoder: the quantiser, the frame differencing, the container
 * and the LZW.
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
#define GRID 32           /* the levels of the colour the table of the palette has */
#define MAXCOL 4096       /* the distinct colours of a frame that are looked at */
#define SEEN 8192         /* the table they are looked up in: twice as many, to keep it short */

typedef struct {
    uint8_t r, g, b;
    uint32_t n; /* the pixels of that colour */
} Colour;

typedef struct {
    int lo, hi; /* the colours of the box, in the array */
    int rmin, rmax, gmin, gmax, bmin, bmax;
    uint64_t count; /* the pixels in the box */
} Box;

struct GifState {
    uint32_t key[HASH]; /* the LZW: the (prefix, character) of an entry */
    uint16_t val[HASH]; /* the LZW: the code of that entry */
    uint8_t *out;       /* the LZW: the codes, as bytes */
    int n, cap;
    int mincode;         /* the size of the smallest code: the size of the palette */
    int clear, end;      /* the clear code, the end code */
    int next, size, old; /* the LZW: the next free entry, the size of the code in bits, the last code */
    uint32_t acc;        /* the LZW: the bits that have not been written out yet */
    int nbits;
    Colour *cols;   /* the distinct colours of the frame */
    int ncols;
    uint64_t seen[SEEN]; /* the colour in the high bits, its place in the array + 1 in the low ones */
    uint8_t grid[GRID * GRID * GRID]; /* the nearest colour of the palette, for every cell of the cube */
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
static void lzw_reset(GifState *s)
{
    memset(s->key, 0xFF, sizeof s->key);
    s->next = s->end + 1;
    s->size = s->mincode + 1;
    s->old = -1;
}

static bool out_byte(GifState *s, int b)
{
    if (s->n >= s->cap) {
        int cap = s->cap ? s->cap * 2 : 4096;
        uint8_t *p = mem_grow(s->out, (size_t)cap);
        if (!p)
            return false;
        s->out = p;
        s->cap = cap;
    }
    s->out[s->n++] = (uint8_t)b;
    return true;
}

static bool put_code(GifState *s, int code)
{
    s->acc |= (uint32_t)code << s->nbits;
    s->nbits += s->size;
    while (s->nbits >= 8) {
        if (!out_byte(s, s->acc & 0xFF))
            return false;
        s->acc >>= 8;
        s->nbits -= 8;
    }
    return true;
}

/* The entry for a prefix and a character, or -1 when there is none. */
static int lzw_find(GifState *s, int prefix, int ch)
{
    uint32_t key = ((uint32_t)prefix << 8) | (uint32_t)ch;
    uint32_t h = (key * 2654435761u) >> 19; /* the top bits of the product: the buckets */
    while (s->key[h] != EMPTY && s->key[h] != key)
        h = (h + 1) & (HASH - 1);
    return s->key[h] == key ? s->val[h] : -1;
}

static void lzw_add(GifState *s, int prefix, int ch, int code)
{
    uint32_t key = ((uint32_t)prefix << 8) | (uint32_t)ch;
    uint32_t h = (key * 2654435761u) >> 19;
    while (s->key[h] != EMPTY)
        h = (h + 1) & (HASH - 1);
    s->key[h] = key;
    s->val[h] = (uint16_t)code;
}

/* The indices of a frame, as the codes of the LZW.
 *
 * The clear code goes out first, so that the decoder starts in step. The size
 * of the code grows when the next free entry passes what the size can hold: the
 * decoder grows its own size at the same point in the stream, one entry later,
 * and the two have to agree or the picture turns to noise. When the dictionary
 * is full a clear code goes out and the dictionary starts over; the bits in
 * the accumulator are not reset then, only at the start of the file. */
static bool lzw_write(GifState *s, const uint8_t *idx, int n)
{
    lzw_reset(s);
    s->n = 0;
    s->acc = 0; /* every frame is a stream of its own: it starts on a byte */
    s->nbits = 0;
    if (!put_code(s, s->clear))
        return false;
    for (int i = 0; i < n; i++) {
        int k = idx[i];
        if (s->old < 0) {
            s->old = k;
            continue;
        }
        int found = lzw_find(s, s->old, k);
        if (found >= 0) {
            s->old = found;
            continue;
        }
        if (!put_code(s, s->old))
            return false;
        if (s->next < 4096) {
            lzw_add(s, s->old, k, s->next);
            s->next++;
            if (s->next > (1 << s->size) && s->size < 12)
                s->size++;
        } else {
            if (!put_code(s, s->clear))
                return false;
            lzw_reset(s);
            if (!put_code(s, s->clear))
                return false;
            s->old = k;
            continue;
        }
        s->old = k;
    }
    if (s->old >= 0 && !put_code(s, s->old))
        return false;
    if (!put_code(s, s->end))
        return false;
    if (s->nbits > 0 && !out_byte(s, s->acc & 0xFF))
        return false;
    return true;
}

/* ---- the palette ---- */

/* The colours of the frame that are in the table: where they are in the array.
 * The table is direct-mapped with a chain: a colour that is not in it is not
 * counted, and the quantiser maps it to the nearest entry of the palette. */
static int seen_of(GifState *s, uint32_t c, uint32_t *at)
{
    uint32_t h = (c * 2654435761u) >> 19; /* the buckets of the table */
    while (s->seen[h]) {
        if ((uint32_t)(s->seen[h] >> 16) == c) {
            *at = h;
            return (int)(s->seen[h] & 0xFFFF) - 1;
        }
        h = (h + 1) & (SEEN - 1);
    }
    *at = h;
    return -1;
}

static void build_grid(Gif *g);

/* The palette of the first frame: the colours that are there, or as many of
 * them as fit, cut out of the colour cube. The last entry of the table is
 * left for the transparent index. */
static void build_palette(Gif *g)
{
    GifState *s = g->state;
    int wanted = g->ncolours - 1; /* the last entry is for the transparent index */
    if (s->ncols <= wanted) {
        for (int i = 0; i < s->ncols; i++) {
            g->pal[i][0] = s->cols[i].r;
            g->pal[i][1] = s->cols[i].g;
            g->pal[i][2] = s->cols[i].b;
        }
        g->npal = s->ncols;
        g->trans = g->ncolours - 1;
        build_grid(g);
        return;
    }
    /* median cut: the box with the longest side is split in two, until there
     * are as many boxes as the palette has room for */
    Box *boxes = mem_alloc((size_t)(wanted + 2) * sizeof(Box));
    if (!boxes) {
        g->npal = 0;
        return;
    }
    int nb = 1;
    boxes[0].lo = 0;
    boxes[0].hi = s->ncols;
    for (int i = 0; i < s->ncols; i++) {
        Colour *c = &s->cols[i];
        if (i == 0) {
            boxes[0].rmin = boxes[0].rmax = c->r;
            boxes[0].gmin = boxes[0].gmax = c->g;
            boxes[0].bmin = boxes[0].bmax = c->b;
        } else {
            boxes[0].rmin = MINI(boxes[0].rmin, c->r), boxes[0].rmax = MAXI(boxes[0].rmax, c->r);
            boxes[0].gmin = MINI(boxes[0].gmin, c->g), boxes[0].gmax = MAXI(boxes[0].gmax, c->g);
            boxes[0].bmin = MINI(boxes[0].bmin, c->b), boxes[0].bmax = MAXI(boxes[0].bmax, c->b);
        }
    }
    uint64_t total = 0;
    for (int i = 0; i < s->ncols; i++)
        total += s->cols[i].n;
    boxes[0].count = total;
    while (nb < wanted) {
        /* the box with the longest side */
        int best = -1, bestr = 0, axis = 0;
        for (int i = 0; i < nb; i++) {
            int dr = boxes[i].rmax - boxes[i].rmin, dg = boxes[i].gmax - boxes[i].gmin, db = boxes[i].bmax - boxes[i].bmin;
            int r = MAXI(dr, MAXI(dg, db));
            if (r > bestr) {
                bestr = r, best = i;
                axis = dr >= dg && dr >= db ? 0 : (dg >= db ? 1 : 2);
            }
        }
        if (best < 0 || bestr == 0)
            break; /* every colour is the same */
        Box *b = &boxes[best];
        /* the colours of the box, in the order of the axis: the median is where
         * half of the pixels of the box are */
        int lo = b->lo, hi = b->hi;
        for (int i = lo + 1; i < hi; i++) {
            Colour v = s->cols[i];
            int j = i - 1;
            while (j >= lo) {
                Colour *u = &s->cols[j];
                int a = axis == 0 ? u->r : axis == 1 ? u->g : u->b;
                int c = axis == 0 ? v.r : axis == 1 ? v.g : v.b;
                if (a <= c)
                    break;
                s->cols[j + 1] = *u;
                j--;
            }
            s->cols[j + 1] = v;
        }
        uint64_t half = b->count / 2, sum = 0;
        int mid = lo;
        for (int i = lo; i < hi; i++) {
            sum += s->cols[i].n;
            if (sum > half) {
                mid = i + 1;
                break;
            }
        }
        if (mid <= lo || mid >= hi)
            mid = (lo + hi) / 2; /* one colour alone on one side of the axis */
        /* the two halves: the box that is split keeps the first one, the
         * second is a new box */
        Box part[2];
        for (int k = 0; k < 2; k++) {
            int from = k ? mid : lo, to = k ? hi : mid;
            memset(&part[k], 0, sizeof part[k]);
            part[k].lo = from, part[k].hi = to;
            for (int i = from; i < to; i++) {
                Colour *c = &s->cols[i];
                if (i == from) {
                    part[k].rmin = part[k].rmax = c->r, part[k].gmin = part[k].gmax = c->g;
                    part[k].bmin = part[k].bmax = c->b;
                } else {
                    part[k].rmin = MINI(part[k].rmin, c->r), part[k].rmax = MAXI(part[k].rmax, c->r);
                    part[k].gmin = MINI(part[k].gmin, c->g), part[k].gmax = MAXI(part[k].gmax, c->g);
                    part[k].bmin = MINI(part[k].bmin, c->b), part[k].bmax = MAXI(part[k].bmax, c->b);
                }
                part[k].count += c->n;
            }
        }
        boxes[best] = part[0];
        boxes[nb] = part[1];
        nb++;
    }
    /* the palette: the average of the colours of every box */
    int n = 0;
    for (int i = 0; i < nb && n < wanted; i++) {
        uint64_t r = 0, gg = 0, b = 0, c = 0;
        for (int j = boxes[i].lo; j < boxes[i].hi; j++) {
            r += (uint64_t)s->cols[j].r * s->cols[j].n;
            gg += (uint64_t)s->cols[j].g * s->cols[j].n;
            b += (uint64_t)s->cols[j].b * s->cols[j].n;
            c += s->cols[j].n;
        }
        if (!c)
            continue;
        g->pal[n][0] = (uint8_t)(r / c);
        g->pal[n][1] = (uint8_t)(gg / c);
        g->pal[n][2] = (uint8_t)(b / c);
        n++;
    }
    g->npal = n;
    g->trans = g->ncolours - 1;
    build_grid(g);
    mem_free(boxes);
}

/* The index of the palette that is nearest to a colour. */
static int nearest(Gif *g, uint32_t c)
{
    int best = 0, bd = 1 << 30;
    int r = (int)(c >> 16 & 255), gg = (int)(c >> 8 & 255), b = (int)(c & 255);
    for (int i = 0; i < g->npal; i++) {
        int dr = r - g->pal[i][0], dg = gg - g->pal[i][1], db = b - g->pal[i][2];
        int d = dr * dr + dg * dg + db * db;
        if (d < bd) {
            bd = d;
            best = i;
        }
    }
    return best;
}

/* The table: for every cell of the colour cube, the palette entry that is
 * nearest to it. A pixel is then one lookup, whatever the picture is: a screen
 * has few colours, but a photograph has as many as it has pixels. */
static void build_grid(Gif *g)
{
    GifState *s = g->state;
    for (int r = 0; r < GRID; r++)
        for (int gg = 0; gg < GRID; gg++)
            for (int b = 0; b < GRID; b++) {
                uint32_t c = ((uint32_t)(r * 8 + 4) << 16) | ((uint32_t)(gg * 8 + 4) << 8) | (uint32_t)(b * 8 + 4);
                s->grid[(r * GRID + gg) * GRID + b] = (uint8_t)nearest(g, c);
            }
}

/* The index of a pixel's colour. */
static int index_of(Gif *g, uint32_t c)
{
    GifState *s = g->state;
    int r = (int)(c >> 16 & 255) >> 3, gg = (int)(c >> 8 & 255) >> 3, b = (int)(c & 255) >> 3;
    return s->grid[(r * GRID + gg) * GRID + b];
}

/* ---- the frames ---- */

bool gif_begin(Gif *g, int w, int h, int ncolours)
{
    memset(g, 0, sizeof *g);
    g->w = w;
    g->h = h;
    g->ncolours = ncolours;
    g->trans = -1;
    g->state = mem_alloc(sizeof *g->state);
    if (!g->state)
        return false;
    g->state->cols = mem_alloc(MAXCOL * sizeof(Colour));
    g->prev = mem_alloc((size_t)w * h);
    g->idx = mem_alloc((size_t)w * h);
    if (!g->state->cols || !g->prev || !g->idx) {
        gif_free(g);
        return false;
    }
    int mincode = 2;
    while ((1 << mincode) < ncolours)
        mincode++;
    g->state->mincode = mincode;
    g->state->clear = 1 << mincode;
    g->state->end = g->state->clear + 1;
    return true;
}

void gif_free(Gif *g)
{
    mem_free(g->buf);
    mem_free(g->prev);
    mem_free(g->idx);
    if (g->state) {
        mem_free(g->state->cols);
        mem_free(g->state->out);
        mem_free(g->state);
    }
    memset(g, 0, sizeof *g);
}

/* The colours of the frame, and the palette they make. */
static void quantise(Gif *g, const uint32_t *px, int stride, int w, int h)
{
    GifState *s = g->state;
    /* the distinct colours, in the order they are met */
    s->ncols = 0;
    memset(s->seen, 0, sizeof s->seen);
    for (int y = 0; y < h; y++) {
        const uint32_t *row = px + (size_t)y * stride;
        for (int x = 0; x < w; x++) {
            uint32_t c = row[x] & 0xFFFFFF;
            uint32_t at;
            int found = seen_of(s, c, &at);
            if (found >= 0) {
                s->cols[found].n++;
                continue;
            }
            if (s->ncols >= MAXCOL)
                continue; /* too many colours: this one is not counted, and is mapped to the nearest */
            Colour *e = &s->cols[s->ncols];
            e->r = (uint8_t)(c >> 16 & 255), e->g = (uint8_t)(c >> 8 & 255), e->b = (uint8_t)(c & 255);
            e->n = 1;
            s->seen[at] = ((uint64_t)c << 16) | (uint64_t)(s->ncols + 1);
            s->ncols++;
        }
    }
    build_palette(g);
}

bool gif_frame(Gif *g, const uint32_t *px, int stride, int delay_cs)
{
    int w = g->w, h = g->h;
    if (!g->started) {
        /* the first frame decides the colours */
        quantise(g, px, stride, w, h);
        for (int y = 0; y < h; y++) {
            const uint32_t *row = px + (size_t)y * stride;
            for (int x = 0; x < w; x++)
                g->idx[(size_t)y * w + x] = (uint8_t)index_of(g, row[x] & 0xFFFFFF);
        }
        memcpy(g->prev, g->idx, (size_t)w * h);
        return gif_write_frame(g, g->idx, w, h, 0, 0, delay_cs, -1);
    }
    /* the frame, in the indices of the palette */
    for (int y = 0; y < h; y++) {
        const uint32_t *row = px + (size_t)y * stride;
        for (int x = 0; x < w; x++)
            g->idx[(size_t)y * w + x] = (uint8_t)index_of(g, row[x] & 0xFFFFFF);
    }
    /* the rectangle that changed: the smallest one that holds every pixel
     * whose index is different */
    int x0 = w, y0 = h, x1 = -1, y1 = -1;
    for (int y = 0; y < h; y++) {
        const uint8_t *a = g->idx + (size_t)y * w, *b = g->prev + (size_t)y * w;
        for (int x = 0; x < w; x++) {
            if (a[x] == b[x])
                continue;
            if (x < x0)
                x0 = x;
            if (x > x1)
                x1 = x;
            if (y < y0)
                y0 = y;
            y1 = y;
        }
    }
    if (x1 < 0) {
        /* nothing changed: a frame of one transparent pixel, so that the delay
         * of the next frame is the one it should be */
        uint8_t one = (uint8_t)g->trans;
        memcpy(g->prev, g->idx, (size_t)w * h);
        return gif_write_frame(g, &one, 1, 1, 0, 0, delay_cs, g->trans);
    }
    /* the pixels that did not change are the transparent index: the picture of
     * the frame before shows through them */
    int fw = x1 - x0 + 1, fh = y1 - y0 + 1;
    uint8_t *rect = mem_alloc((size_t)fw * fh);
    if (!rect)
        return false;
    for (int y = 0; y < fh; y++) {
        const uint8_t *a = g->idx + (size_t)(y + y0) * w + x0;
        const uint8_t *b = g->prev + (size_t)(y + y0) * w + x0;
        uint8_t *o = rect + (size_t)y * fw;
        for (int x = 0; x < fw; x++)
            o[x] = a[x] == b[x] ? (uint8_t)g->trans : a[x];
    }
    memcpy(g->prev, g->idx, (size_t)w * h);
    bool ok = gif_write_frame(g, rect, fw, fh, x0, y0, delay_cs, g->trans);
    mem_free(rect);
    return ok;
}

/* ---- the file ---- */

bool gif_write_frame(Gif *g, const uint8_t *idx, int fw, int fh, int fx, int fy, int delay_cs, int trans)
{
    g->n = 0; /* the buffer holds the bytes of this frame alone */
    if (!g->started) {
        /* the header and the logical screen descriptor */
        if (!buf_bytes(g, "GIF89a", 6) || !buf_word(g, g->w) || !buf_word(g, g->h))
            return false;
        if (!buf_byte(g, 0x80 | 0x70 | (g->state->mincode - 1)))
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
    if (!buf_byte(g, 0x04 | (trans >= 0 ? 1 : 0)))
        return false;
    if (!buf_word(g, delay_cs))
        return false;
    if (!buf_byte(g, trans >= 0 ? trans : 0) || !buf_byte(g, 0))
        return false;
    /* the image descriptor */
    if (!buf_byte(g, 0x2C) || !buf_word(g, fx) || !buf_word(g, fy))
        return false;
    if (!buf_word(g, fw) || !buf_word(g, fh) || !buf_byte(g, 0))
        return false;
    /* the data, in blocks of at most 255 bytes */
    if (!buf_byte(g, g->state->mincode))
        return false;
    GifState *s = g->state;
    if (!lzw_write(s, idx, fw * fh))
        return false;
    for (int off = 0; off < s->n;) {
        int chunk = s->n - off;
        if (chunk > 255)
            chunk = 255;
        if (!buf_byte(g, chunk) || !buf_bytes(g, s->out + off, chunk))
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
