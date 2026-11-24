/* The long screenshot: the selection keeps growing while the user scrolls.
 *
 * The capture window is gone; a thin frame marks the region, a small bar below it
 * has the buttons, and a strip beside it shows what has been put together so far.
 * The user scrolls the page themselves, with the wheel or the keyboard, at their own
 * speed and in whatever program it is: nothing is sent to that program.
 *
 * Several times a second the region is read from the screen. A frame that differs
 * from the one before is placed on the canvas (the long picture so far) by its rows:
 *
 *   Every row of pixels gets one hash per vertical strip (STRIPS of them, the margins
 *   left out: a scroll bar moves at its own speed). Each row of the frame whose hash
 *   is rare among the canvas rows near the last position votes for the position that
 *   would put it on the canvas row with the same hash. Rows of plain background are
 *   everywhere and vote for nothing. Neither does anything that looks as it did in
 *   the frame before: what stays in place while the page moves (a side bar, a header)
 *   knows nothing about where the page went. The position with the most votes wins
 *   if it is clear of the runner-up; otherwise the frame is left out and the bar says
 *   to scroll back a little, until a frame fits again.
 *
 *   The canvas only ever grows at its end: the rows of the frame below what it has
 *   are appended. So a header that stays at the top of the page appears once, at the
 *   top. Rows at the bottom that did not move with the rest (a footer that stays) are
 *   held back, and added once at the very end.
 *
 * Cost: one read of the region per tick, a pass over its pixels for the hashes, and a
 * few thousand table steps when something moved. Ticks slow down while nothing does. */
#pragma GCC optimize("O2")
#include "common.h"
#include "draw.h"
#include "image.h"
#include "lang.h"
#include "ocr.h"
#include "overlay.h"
#include "pin.h"
#include "shot.h"
#include "ov_layout.inc"
#include <dwmapi.h>
#include <math.h>

#define LONG_CLASS L"sniplite.long"
#define STRIPS 8
#define MAX_ROWS 32000        /* of the long picture */
#define MAX_PIXELS 40000000   /* and of its size: 160 MB */
#define TICK_MS 30
#define TICK_QUIET_MS 120     /* while nothing changes */
#define TIMER_GRAB 1
#define TIMER_AUTO 2
#define AUTO_STEP_MS 1100     /* a wheel step, then time for the page to settle */
#define AUTO_SETTLE_MS 800
#define HK_CANCEL 1
#define HK_DONE 2

typedef struct {
    uint32_t key; /* a row's hash; 0: free */
    int32_t n;    /* canvas rows that have it */
    int32_t row[3];
} Slot;

enum { BT_OCR, BT_OCRCOPY, BT_PIN, BT_SAVE, BT_CLOSE, BT_OK, BT_COUNT }; /* the bar's buttons, left to right */
#define BT_AUTO 100      /* the status side of the bar: click to pause or resume */
static const int kIcon[BT_COUNT] = {IC_OCR, IC_OCRCOPY, IC_PIN, IC_SAVE, IC_CLOSE, IC_OK};

extern uint8_t O[]; /* the capture's state (ov_layout.inc) */
extern const uint32_t *ui_pal; /* the bars' colors, by P_* (ov_base.S, main.c) */

static struct {
    bool on, first, lost, full;
    bool reading; /* the text panel shows the picture's text: nothing is added meanwhile */
    RECT rc; /* the region on the screen */
    int w, h;
    float s;
    HWND frame, bar, view;
    Img shot;         /* the frame just read */
    uint32_t *canvas; /* reserved for max_rows, committed as it grows */
    size_t committed; /* bytes */
    int rows, max_rows;
    int pos;          /* the canvas row at the top of the last frame that fitted */
    uint32_t *chash;  /* STRIPS hashes per canvas row */
    uint32_t *fhash, *phash; /* per row of this frame, of the one before */
    int x0, sw;       /* the strips: first column, width */
    Slot *table;
    int tsize;
    int *vote;
    int quiet;        /* ticks without a change */
    uint32_t *thumb;  /* the canvas, small: tw wide */
    int tw, trows, tcap;
    Img barimg;
    int hover, down;  /* the bar's button under the mouse, pressed; -1 none */
    bool auto_on, auto_paused, auto_done, auto_manual; /* the page is scrolled for the user */
    int auto_rows;    /* rows when the last wheel step was sent */
    int auto_delta;   /* rows the last wheel step moved the page */
    int auto_miss;    /* steps that brought nothing new */
    bool auto_sent;
    bool cursor_saved; /* the wheel needs the cursor over the page: it was moved once */
    POINT cursor_at;
    uint64_t settle;  /* no grab before this tick: the page is still moving */
} L;
static unsigned begun; /* long screenshots so far: one that waited for a dialog can tell whether it is still the one */

static int px(float v) { return (int)lroundf(v * L.s); }

/* ---- rows ---- */

static inline uint32_t strip_hash(const uint32_t *p, int n)
{
    uint64_t a = 0x9E3779B97F4A7C15ull, b = 0xC2B2AE3D27D4EB4Full, v;
    int i = 0;
    for (; i + 4 <= n; i += 4) { /* two chains: the multiplies overlap */
        memcpy(&v, p + i, 8);
        a = (a ^ v) * 0xFF51AFD7ED558CCDull;
        memcpy(&v, p + i + 2, 8);
        b = (b ^ v) * 0xC4CEB9FE1A85EC53ull;
    }
    for (; i < n; i++)
        a = (a ^ p[i]) * 0xFF51AFD7ED558CCDull;
    a = (a ^ (b >> 32 | b << 32)) * 0x9E3779B97F4A7C15ull;
    uint32_t h = (uint32_t)(a >> 32);
    return h + !h; /* 0 marks a free slot */
}

static void hash_frame(void)
{
    for (int y = 0; y < L.h; y++) {
        const uint32_t *row = L.shot.px + (size_t)y * L.w + L.x0;
        uint32_t *out = L.fhash + (size_t)y * STRIPS;
        for (int s = 0; s < STRIPS; s++)
            out[s] = strip_hash(row + s * L.sw, L.sw);
    }
}

static inline Slot *slot_of(uint32_t key)
{
    unsigned mask = (unsigned)L.tsize - 1, i = key & mask;
    while (L.table[i].key && L.table[i].key != key)
        i = (i + 1) & mask;
    return &L.table[i];
}

/* Where on the canvas this frame's top row is; false when it cannot be told. */
static bool place(int *at)
{
    int h = L.h, base = L.pos - h, nbin = 2 * h + 1;
    int lo = MAXI(L.pos - h, 0), hi = MINI(L.pos + 2 * h, L.rows);
    memset(L.vote, 0, (size_t)nbin * sizeof(int));
    for (int s = 0; s < STRIPS; s++) {
        memset(L.table, 0, (size_t)L.tsize * sizeof(Slot));
        for (int r = lo; r < hi; r++) {
            uint32_t key = L.chash[(size_t)r * STRIPS + s];
            Slot *e = slot_of(key);
            e->key = key;
            if (e->n < 3)
                e->row[e->n] = r;
            e->n++;
        }
        for (int y = 0; y < h; y++) {
            uint32_t key = L.fhash[(size_t)y * STRIPS + s];
            if (key == L.phash[(size_t)y * STRIPS + s])
                continue; /* as in the frame before: it did not move, so it says nothing about where */
            const Slot *e = slot_of(key);
            if (!e->key || e->n > 3)
                continue; /* not on the canvas here, or everywhere on it */
            for (int j = 0; j < e->n; j++) {
                unsigned bin = (unsigned)(e->row[j] - y - base);
                if (bin < (unsigned)nbin)
                    L.vote[bin]++;
            }
        }
    }
    int min_move = L.auto_on && L.auto_delta ? MAXI(8, L.auto_delta / 3) : 0;
    int best = -1, most = 0, next = 0, fbest = -1, fmost = 0, fnext = 0, need = MAXI(16, h / 8);
    for (int i = 0; i < nbin; i++) {
        if (L.vote[i] > most) {
            next = most;
            best = i;
            most = L.vote[i];
        } else if (L.vote[i] > next) {
            next = L.vote[i];
        }
        int ati = base + i;
        if (L.auto_on && ati > L.pos && ati - L.pos >= min_move) {
            if (L.vote[i] > fmost) {
                fnext = fmost;
                fbest = i;
                fmost = L.vote[i];
            } else if (L.vote[i] > fnext) {
                fnext = L.vote[i];
            }
        }
    }
    if (L.auto_on) {
        best = fbest, most = fmost, next = fnext;
    }
    bool clear = most >= need && most >= 2 * next;
    /* A page that repeats (the same bands, the same table rows) can leave a second
     * position close behind. Going down, the page can only have moved forward: take
     * the best one there. */
    if (L.auto_on && most >= MAXI(16, need / 2) && most > next && best >= 0 && base + best > L.pos)
        clear = true;
    if (clear) {
        *at = base + best;
        return true;
    }
    /* What changed is on the canvas nowhere near (something on the page changed where it
     * stands, or the page went too far). Still in place if the frame looks like the
     * canvas does there. */
    int same = 0, all = 0;
    for (int y = MAXI(0, -L.pos); y < h && L.pos + y < L.rows; y++) {
        const uint32_t *f = L.fhash + (size_t)y * STRIPS, *c = L.chash + (size_t)(L.pos + y) * STRIPS;
        for (int s = 0; s < STRIPS; s++)
            same += f[s] == c[s];
        all += STRIPS;
    }
    *at = L.pos;
    return all && same * 4 >= all;
}

/* n rows of the frame, from row y, to the end of the canvas */
static void append(int y, int n)
{
    n = MINI(n, L.max_rows - L.rows);
    if (n <= 0)
        return;
    size_t row = (size_t)L.w * 4, need = (size_t)(L.rows + n) * row;
    if (need > L.committed) {
        size_t upto = (need + (4u << 20)) & ~(size_t)0xFFFF, all = (size_t)L.max_rows * row;
        upto = MINI(upto, all);
        if (!VirtualAlloc(L.canvas, upto, MEM_COMMIT, PAGE_READWRITE))
            return;
        L.committed = upto;
    }
    memcpy(L.canvas + (size_t)L.rows * L.w, L.shot.px + (size_t)y * L.w, (size_t)n * row);
    memcpy(L.chash + (size_t)L.rows * STRIPS, L.fhash + (size_t)y * STRIPS, (size_t)n * STRIPS * sizeof(uint32_t));
    L.rows += n;
    L.full = L.rows >= L.max_rows;
}

/* the small copy of the canvas: every finished row of it, each pixel the average of
 * the canvas pixels it stands for */
static void thumb_update(void)
{
    int w = L.w, tw = L.tw;
    if (!tw)
        return;
    for (; L.trows < L.tcap && (L.trows + 1) * w / tw <= L.rows; L.trows++) {
        int y0 = L.trows * w / tw, y1 = (L.trows + 1) * w / tw;
        uint32_t *d = L.thumb + (size_t)L.trows * tw;
        for (int x = 0; x < tw; x++) {
            int xa = x * w / tw, xb = (x + 1) * w / tw;
            unsigned b = 0, g = 0, r = 0, n = (unsigned)((xb - xa) * (y1 - y0));
            for (int y = y0; y < y1; y++) {
                const uint32_t *p = L.canvas + (size_t)y * w;
                for (int i = xa; i < xb; i++) {
                    uint32_t v = p[i];
                    b += v & 255, g += v >> 8 & 255, r += v >> 16 & 255;
                }
            }
            d[x] = (r / n) << 16 | (g / n) << 8 | b / n;
        }
    }
}

static void grab(void)
{
    HDC scr = GetDC(NULL);
    BitBlt(L.shot.dc, 0, 0, L.w, L.h, scr, L.rc.left, L.rc.top, SRCCOPY | CAPTUREBLT);
    ReleaseDC(NULL, scr);
}

/* ---- the windows ---- */

static void bar_text(WCHAR *t, int cap, uint32_t *color)
{
    *color = ui_pal[P_NOTE];
    if (L.lost) {
        lstrcpynW(t, T(LONG_LOST), cap);
        *color = ui_pal[P_WARN];
    } else if (L.full) {
        lstrcpynW(t, T(LONG_FULL), cap);
    } else if (L.auto_on) {
        lstrcpynW(t, T(LONG_AUTO), cap);
    } else if (L.auto_done) {
        lstrcpynW(t, T(LONG_AUTO_END), cap);
    } else if (L.auto_manual) {
        lstrcpynW(t, T(LONG_AUTO_MANUAL), cap);
    } else if (L.auto_paused) {
        lstrcpynW(t, T(LONG_AUTO_PAUSED), cap);
    } else if (L.rows <= L.h) {
        lstrcpynW(t, T(LONG_HINT), cap);
    } else {
        wsprintfW(t, L"%d \x00D7 %d", L.w, L.rows);
    }
}

/* the first button the bar has: without the module, not the two for text */
static int bar_first(void) { return ocr_there ? 0 : BT_PIN; }

static RECT bar_button(int i)
{
    int b = px(30), x = L.barimg.w - px(4) - (BT_COUNT - i) * b, y = (L.barimg.h - b) / 2;
    RECT r = {x, y, x + b, y + b};
    return r;
}

/* the side of the bar that says what the long picture is doing: click it to pause */
static RECT bar_text_rect(void)
{
    RECT r = {px(4), 0, bar_button(bar_first()).left - px(4), L.barimg.h};
    return r;
}

/* the bar, into its picture: what the picture is now, and the buttons */
static void bar_draw(void)
{
    RECT rc = {0, 0, L.barimg.w, L.barimg.h};
    Surf s = surf_img(&L.barimg, 0, 0);
    d_fill(&s, rc, ui_pal[P_BG]);
    d_frame(&s, rc, 1, ui_pal[P_EDGE]);
    if (L.hover == BT_AUTO)
        d_fill(&s, rect_inflate(bar_text_rect(), -px(2)), ui_pal[L.down == BT_AUTO ? P_DOWN : P_HOVER]);
    for (int i = bar_first(); i < BT_COUNT; i++) {
        RECT b = bar_button(i);
        if (i == L.hover || (i == BT_OCR && L.reading))
            d_fill(&s, rect_inflate(b, -px(2)), ui_pal[i == L.down || i != L.hover ? P_DOWN : P_HOVER]);
        d_icon(&s, kIcon[i], (float)(b.left + px(5)), (float)(b.top + px(5)), (float)px(20), ui_pal[i == BT_OK ? P_ACCENT : P_ICON]);
    }
    WCHAR t[96];
    uint32_t color;
    bar_text(t, COUNTOF(t), &color);
    HFONT f = CreateFontW(-px(13), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                          DEFAULT_PITCH, T(FONT));
    HGDIOBJ old = SelectObject(L.barimg.dc, f);
    SetBkMode(L.barimg.dc, TRANSPARENT);
    SetTextColor(L.barimg.dc, RGB(color >> 16, color >> 8 & 255, color & 255));
    RECT tr = bar_text_rect();
    tr.left += px(6);
    tr.right -= px(2);
    DrawTextW(L.barimg.dc, t, -1, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
    SelectObject(L.barimg.dc, old);
    DeleteObject(f);
}

static void bar_paint(HWND h)
{
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(h, &ps);
    bar_draw();
    BitBlt(dc, 0, 0, L.barimg.w, L.barimg.h, L.barimg.dc, 0, 0, SRCCOPY);
    EndPaint(h, &ps);
}

/* the strip: the end of the long picture so far, and a mark where the page is now */
static void view_draw(HDC dc, RECT rc)
{
    int shown = MINI(L.trows, rc.bottom), from = L.trows - shown;
    if (shown > 0) {
        BITMAPINFO bi = {{sizeof(BITMAPINFOHEADER), L.tw, -shown, 1, 32, BI_RGB, 0, 0, 0, 0, 0}, {{0, 0, 0, 0}}};
        SetDIBitsToDevice(dc, 0, 0, (DWORD)L.tw, (DWORD)shown, 0, 0, 0, (UINT)shown, L.thumb + (size_t)from * L.tw, &bi, DIB_RGB_COLORS);
    }
    RECT rest = {0, shown, rc.right, rc.bottom};
    HBRUSH dark = CreateSolidBrush(RGB(40, 40, 40)), accent = CreateSolidBrush(RGB(ACCENT >> 16, ACCENT >> 8 & 255, ACCENT & 255));
    FillRect(dc, &rest, dark);
    if (!L.lost && shown > 0) {
        RECT now = {0, L.pos * L.tw / L.w - from, rc.right, (L.pos + L.h) * L.tw / L.w - from};
        now.top = MAXI(now.top, 0), now.bottom = MINI(now.bottom, MAXI(shown, 1));
        if (now.bottom > now.top) {
            FrameRect(dc, &now, accent);
            now = rect_inflate(now, -1);
            if (now.bottom > now.top)
                FrameRect(dc, &now, accent);
        }
    }
    DeleteObject(dark);
    DeleteObject(accent);
}

static void view_paint(HWND h)
{
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(h, &ps);
    RECT rc;
    GetClientRect(h, &rc);
    view_draw(dc, rc);
    EndPaint(h, &ps);
}

/* The frame in L.shot goes onto the canvas. False when it is the same as the one before. */
static bool stitch_frame(void)
{
    hash_frame();
    if (L.first) {
        L.first = false;
        append(0, L.h);
    } else if (!memcmp(L.fhash, L.phash, (size_t)L.h * STRIPS * sizeof(uint32_t))) {
        return false;
    } else {
        int at;
        L.lost = !place(&at);
        if (!L.lost && at != L.pos) {
            int foot = 0; /* rows at the bottom that stayed where they were while the rest moved */
            while (foot < L.h / 2 && !memcmp(L.fhash + (size_t)(L.h - 1 - foot) * STRIPS, L.phash + (size_t)(L.h - 1 - foot) * STRIPS,
                                             STRIPS * sizeof(uint32_t)))
                foot++;
            int keep = L.pos + L.h - foot;
            if (foot && L.rows > keep && L.rows <= L.pos + L.h && keep > 0) { /* they were appended as if they belonged there */
                L.rows = keep;
                L.trows = MINI(L.trows, keep * L.tw / L.w);
            }
            if (L.auto_on && at > L.pos)
                L.auto_delta = at - L.pos;
            L.pos = at;
            if (at + L.h - foot > L.rows && L.rows - at >= 0)
                append(L.rows - at, at + L.h - foot - L.rows);
        }
    }
    uint32_t *t = L.fhash;
    L.fhash = L.phash, L.phash = t;
    return true;
}

/* The end: what the last frame has below the canvas, the footer that was held back. */
static void stitch_finish(void)
{
    int rest = L.rows - L.pos;
    if (!L.lost && rest >= 0 && rest < L.h)
        append(rest, L.h - rest);
}

static void stitch_free(void)
{
    if (L.canvas)
        VirtualFree(L.canvas, 0, MEM_RELEASE);
    img_destroy(&L.shot);
    mem_free(L.chash);
    mem_free(L.fhash);
    mem_free(L.phash);
    mem_free(L.table);
    mem_free(L.vote);
    L.canvas = NULL;
    L.chash = L.fhash = L.phash = NULL;
    L.table = NULL;
    L.vote = NULL;
}

/* a region w by h: everything the stitching needs, the canvas empty */
static bool stitch_start(int w, int h)
{
    L.w = w, L.h = h;
    L.first = true, L.lost = L.full = false;
    L.rows = L.pos = 0, L.committed = 0;
    L.max_rows = MAXI(MINI(MAX_ROWS, MAX_PIXELS / w), 2 * h);
    L.x0 = w / 16, L.sw = MAXI((w - 2 * L.x0) / STRIPS, 1);
    for (L.tsize = 1024; L.tsize < 6 * h; L.tsize *= 2)
        ;
    L.canvas = VirtualAlloc(NULL, (size_t)L.max_rows * w * 4, MEM_RESERVE, PAGE_READWRITE);
    L.chash = mem_alloc((size_t)L.max_rows * STRIPS * sizeof(uint32_t));
    L.fhash = mem_alloc((size_t)h * STRIPS * sizeof(uint32_t));
    L.phash = mem_alloc((size_t)h * STRIPS * sizeof(uint32_t));
    L.table = mem_alloc((size_t)L.tsize * sizeof(Slot));
    L.vote = mem_alloc((size_t)(2 * h + 1) * sizeof(int));
    return L.canvas && L.chash && L.fhash && L.phash && L.table && L.vote && img_create(&L.shot, w, h);
}

static void long_end(void);
static void long_done(int button);
static void hotkeys(bool on);

/* the text panel is gone: the keys and the scrolling are the long screenshot's again */
static void reading_end(void)
{
    L.reading = false;
    hotkeys(true);
    if (L.auto_on)
        SetTimer(L.bar, TIMER_AUTO, AUTO_STEP_MS, NULL);
    SetTimer(L.bar, TIMER_GRAB, TICK_MS, NULL);
    InvalidateRect(L.bar, NULL, FALSE);
}

static void tick(void)
{
    if (ov_active()) { /* a capture began: this one is over */
        long_end();
        return;
    }
    if (L.reading) { /* until the text panel is closed */
        if (ocr_picture_shown())
            return;
        reading_end();
    }
    if (L.settle && GetTickCount64() < L.settle)
        return; /* the page is still easing into its new place */
    L.settle = 0;
    bool was_first = L.first, was_lost = L.lost;
    int rows = L.rows, pos = L.pos;
    grab();
    if (!stitch_frame()) {
        if (++L.quiet == 12 && !L.auto_on)
            SetTimer(L.bar, TIMER_GRAB, TICK_QUIET_MS, NULL);
        return;
    }
    if (L.quiet >= 12 || was_first || L.auto_on)
        SetTimer(L.bar, TIMER_GRAB, TICK_MS, NULL);
    L.quiet = 0;
    thumb_update();
    if (L.view && (rows != L.rows || pos != L.pos || was_lost != L.lost))
        InvalidateRect(L.view, NULL, FALSE);
    if (rows != L.rows || was_lost != L.lost)
        InvalidateRect(L.bar, NULL, FALSE);
}

static int bar_hit(LPARAM lp)
{
    POINT p = {(short)LOWORD(lp), (short)HIWORD(lp)};
    for (int i = bar_first(); i < BT_COUNT; i++) {
        RECT b = bar_button(i);
        if (PtInRect(&b, p))
            return i;
    }
    RECT t = bar_text_rect();
    if (PtInRect(&t, p))
        return BT_AUTO;
    return -1;
}

/* ---- automatic scrolling ---- */

static void auto_stop(bool done, bool manual)
{
    if (L.cursor_saved) {
        POINT c, p = {L.rc.left + L.w / 2, L.rc.top + L.h / 2};
        GetCursorPos(&c);
        if (c.x == p.x && c.y == p.y) /* the user did not move it meanwhile */
            SetCursorPos(L.cursor_at.x, L.cursor_at.y);
        L.cursor_saved = false;
    }
    L.auto_on = false;
    L.auto_done = done;
    L.auto_manual = manual;
    L.auto_paused = !done && !manual;
    if (L.bar) {
        KillTimer(L.bar, TIMER_AUTO);
        SetTimer(L.bar, TIMER_GRAB, TICK_QUIET_MS, NULL);
        InvalidateRect(L.bar, NULL, FALSE);
    }
}

static void auto_toggle(void)
{
    L.auto_on = !L.auto_on;
    L.auto_paused = !L.auto_on;
    if (L.auto_on) {
        L.auto_done = L.auto_manual = false;
        L.auto_miss = 0;
        L.auto_delta = 0;
        L.auto_sent = false;
        L.auto_rows = L.rows;
        SetTimer(L.bar, TIMER_AUTO, 250, NULL);
        SetTimer(L.bar, TIMER_GRAB, TICK_MS, NULL);
    } else {
        KillTimer(L.bar, TIMER_AUTO);
    }
    InvalidateRect(L.bar, NULL, FALSE);
}

/* A wheel step for the page under the region. A real wheel goes to the window under the
 * cursor; when the cursor is not over the page it is moved to the middle of the region
 * once and kept there, and put back when the scrolling stops. It never moves per step,
 * so the pointer does not jitter. */
static void auto_wheel(void)
{
    /* Small steps: two frames need enough rows in common to find where the page went. */
    int notches = CLAMPI(L.h / 300, 2, 4);
    POINT c;
    GetCursorPos(&c);
    HWND under = WindowFromPoint(c);
    DWORD pid = 0;
    if (under)
        GetWindowThreadProcessId(under, &pid);
    if (!under || pid == GetCurrentProcessId() || !PtInRect(&L.rc, c)) {
        if (!L.cursor_saved) {
            L.cursor_saved = true;
            L.cursor_at = c;
        }
        c.x = L.rc.left + L.w / 2;
        c.y = L.rc.top + L.h / 2;
        SetCursorPos(c.x, c.y);
    }
    INPUT in = {0};
    in.type = INPUT_MOUSE;
    in.mi.dwFlags = MOUSEEVENTF_WHEEL;
    in.mi.mouseData = (DWORD)(-WHEEL_DELTA * notches);
    SendInput(1, &in, sizeof in);
}

static void auto_step(void)
{
    if (!L.on || !L.auto_on || L.reading || L.full)
        return;
    if (L.first) { /* the first frame has not been read yet */
        SetTimer(L.bar, TIMER_AUTO, 250, NULL);
        return;
    }
    if (L.lost) { /* the frame no longer fits: let the user bring it back by hand */
        auto_stop(false, false);
        return;
    }
    if (L.auto_sent) {
        if (L.rows == L.auto_rows) {
            if (++L.auto_miss >= 3) {
                auto_stop(L.rows > L.h, L.rows <= L.h);
                return;
            }
        } else {
            L.auto_miss = 0;
        }
    }
    L.auto_rows = L.rows;
    L.auto_sent = true;
    auto_wheel();
    L.settle = GetTickCount64() + AUTO_SETTLE_MS;
    SetTimer(L.bar, TIMER_AUTO, AUTO_STEP_MS, NULL);
    SetTimer(L.bar, TIMER_GRAB, TICK_MS, NULL);
}

static LRESULT CALLBACK long_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    if (m == WM_ERASEBKGND)
        return 1;
    if (m == WM_MOUSEACTIVATE)
        return MA_NOACTIVATE; /* the keyboard stays with the page being scrolled */
    if (h == L.view && m == WM_PAINT) {
        view_paint(h);
        return 0;
    }
    if (h == L.frame && m == WM_PAINT) {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        HBRUSH accent = CreateSolidBrush(RGB(ACCENT >> 16, ACCENT >> 8 & 255, ACCENT & 255));
        FillRect(dc, &ps.rcPaint, accent);
        DeleteObject(accent);
        EndPaint(h, &ps);
        return 0;
    }
    if (h != L.bar || !L.on)
        return DefWindowProcW(h, m, wp, lp);
    switch (m) {
    case WM_PAINT: bar_paint(h); return 0;
    case WM_TIMER:
        if (wp == TIMER_AUTO)
            auto_step();
        else
            tick();
        return 0;
    case WM_HOTKEY: long_done(wp == HK_DONE ? BT_OK : BT_CLOSE); return 0;
    case WM_MOUSEMOVE: {
        int at = bar_hit(lp);
        if (at != L.hover) {
            L.hover = at;
            InvalidateRect(h, NULL, FALSE);
        }
        TRACKMOUSEEVENT tme = {sizeof tme, TME_LEAVE, h, 0};
        TrackMouseEvent(&tme);
        return 0;
    }
    case WM_MOUSELEAVE:
        L.hover = L.down = -1;
        InvalidateRect(h, NULL, FALSE);
        return 0;
    case WM_LBUTTONDOWN:
        L.down = bar_hit(lp);
        InvalidateRect(h, NULL, FALSE);
        return 0;
    case WM_LBUTTONUP: {
        int at = bar_hit(lp), was = L.down;
        L.down = -1;
        InvalidateRect(h, NULL, FALSE);
        if (at >= 0 && at == was)
            long_done(at);
        return 0;
    }
    }
    return DefWindowProcW(h, m, wp, lp);
}

static HWND make(DWORD ex, int x, int y, int w, int h)
{
    HWND wnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | ex, LONG_CLASS, L"sniplite", WS_POPUP, x, y, w, h, NULL,
                               NULL, GetModuleHandleW(NULL), NULL);
    if (wnd) {
        SetWindowDisplayAffinity(wnd, 0x11); /* WDA_EXCLUDEFROMCAPTURE: never part of what is read from the screen */
        if (ex & WS_EX_LAYERED)
            SetLayeredWindowAttributes(wnd, 0, 255, LWA_ALPHA);
    }
    return wnd;
}

/* The keyboard belongs to the page being scrolled, so Esc and Enter come as hotkeys. */
static void hotkeys(bool on)
{
    if (on) {
        RegisterHotKey(L.bar, HK_CANCEL, 0, VK_ESCAPE);
        RegisterHotKey(L.bar, HK_DONE, 0, VK_RETURN);
    } else {
        UnregisterHotKey(L.bar, HK_CANCEL);
        UnregisterHotKey(L.bar, HK_DONE);
    }
}

static void long_end(void)
{
    if (!L.on)
        return;
    if (L.cursor_saved) {
        POINT c, p = {L.rc.left + L.w / 2, L.rc.top + L.h / 2};
        GetCursorPos(&c);
        if (c.x == p.x && c.y == p.y)
            SetCursorPos(L.cursor_at.x, L.cursor_at.y);
    }
    L.on = false;
    if (L.bar) {
        KillTimer(L.bar, TIMER_GRAB);
        KillTimer(L.bar, TIMER_AUTO);
        hotkeys(false);
    }
    if (L.reading)
        ocr_picture_hide();
    HWND w[3] = {L.frame, L.bar, L.view};
    for (int i = 0; i < 3; i++)
        if (w[i])
            DestroyWindow(w[i]);
    stitch_free();
    img_destroy(&L.barimg);
    mem_free(L.thumb);
    memset(&L, 0, sizeof L);
}

/* The text of the long picture as it is now. In the panel (it stands beside the region
 * and the strip, and the picture stops growing while it shows), or to the clipboard,
 * which ends the long screenshot like copying the picture does. */
static void long_text(bool panel)
{
    if (L.reading) { /* the button again: the panel goes, scrolling goes on */
        ocr_picture_hide();
        reading_end();
        return;
    }
    bool auto_was = L.auto_on;
    KillTimer(L.bar, TIMER_AUTO); /* the text panel owns the picture while it is open */
    int rows = L.rows;
    RECT beside = L.rc, view;
    if (L.view && GetWindowRect(L.view, &view))
        beside = rect_union(beside, view);
    stitch_finish(); /* with what the last frame has below the canvas */
    bool sent = ocr_picture(L.canvas, L.w, L.rows, beside, panel ? L.bar : NULL);
    L.rows = rows;
    L.trows = MINI(L.trows, rows * L.tw / L.w);
    if (!sent && ocr_there) { /* the module is there, the picture could not be handed over: it stays */
        if (auto_was)
            SetTimer(L.bar, TIMER_AUTO, AUTO_STEP_MS, NULL);
        MessageBeep(MB_ICONWARNING);
        return;
    }
    if (!panel || !sent) {
        long_end();
        return;
    }
    L.reading = true;
    hotkeys(false); /* Enter and Esc are for the panel's text now */
    SetTimer(L.bar, TIMER_GRAB, 300, NULL);
    InvalidateRect(L.bar, NULL, FALSE);
}

void long_cancel(void) { long_end(); }

/* a button of the bar, Enter (like its check mark) or Esc (like its cross) */
static void long_done(int button)
{
    if (button == BT_AUTO) {
        auto_toggle();
        return;
    }
    if (button == BT_CLOSE && !L.first && L.rows) { /* a picture would be lost: the user may be asked first */
        bool keys = !L.reading;
        if (keys)
            hotkeys(false); /* Esc and Enter are the question's while it shows */
        bool go = leave_ok(L.bar);
        if (!L.on)
            return; /* ended meanwhile: a capture began */
        if (!go) {
            if (keys && !L.reading)
                hotkeys(true);
            return;
        }
    }
    if (button == BT_CLOSE || L.first || !L.rows) {
        long_end();
        return;
    }
    if (button == BT_OCR || button == BT_OCRCOPY) {
        long_text(button == BT_OCR);
        return;
    }
    if (L.reading) {
        ocr_picture_hide();
        L.reading = false;
        hotkeys(true); /* as long_end and the save dialog expect them */
    }
    L.auto_on = false;
    L.auto_paused = true;
    KillTimer(L.bar, TIMER_GRAB);
    KillTimer(L.bar, TIMER_AUTO);
    int rows = L.rows;
    stitch_finish();
    HWND daemon = *(HWND *)(O + OV_DAEMON);
    bool done; /* false: the dialog was cancelled, or the pin or the copy failed */
    if (button == BT_SAVE) {
        WCHAR path[MAX_PATH * 2];
        unsigned mine = begun;
        for (HWND *w = &L.frame; w <= &L.view; w++)
            if (*w)
                ShowWindow(*w, SW_HIDE);
        hotkeys(false); /* Enter and Esc are the dialog's now */
        done = save_dialog(path, COUNTOF(path));
        if (!L.on || mine != begun)
            return; /* ended while the dialog was open, maybe by a capture that began another */
        if (done && !image_save(path, L.canvas, L.w, L.w, L.rows)) {
            MessageBoxW(NULL, T(OV_SAVE_FAILED), L"sniplite", MB_OK | MB_ICONWARNING);
            if (mine != begun)
                return;
        }
    } else if (button == BT_PIN) {
        Img im;
        done = img_create(&im, L.w, L.rows);
        if (done) {
            memcpy(im.px, L.canvas, (size_t)L.w * L.rows * 4);
            done = pin_add(&im, 0, 0, true);
        }
    } else {
        done = clip_put_image(daemon, L.canvas, L.w, L.w, L.rows);
    }
    if (!done) {
        L.rows = rows; /* the picture stays: on with the scrolling */
        L.trows = MINI(L.trows, rows * L.tw / L.w);
        if (button == BT_SAVE) {
            for (HWND *w = &L.frame; w <= &L.view; w++)
                if (*w)
                    ShowWindow(*w, SW_SHOWNOACTIVATE);
            hotkeys(true);
        } else {
            MessageBeep(MB_ICONWARNING);
        }
        L.quiet = 0;
        SetTimer(L.bar, TIMER_GRAB, TICK_MS, NULL);
        return;
    }
    if (button == BT_SAVE) {
        long_end();
        return;
    }
    /* the end comes before also_save, so the canvas outlives it */
    uint32_t *canvas = L.canvas;
    int w = L.w, h = L.rows;
    L.canvas = NULL;
    long_end();
    also_save(canvas, w, h);
    VirtualFree(canvas, 0, MEM_RELEASE);
}

/* Called by the capture, which closes right after: the selection becomes the region. */
void long_begin(void)
{
    long_end();
    begun++;
    const Shot *sh = (const Shot *)(O + OV_SHOT);
    const RECT *sel = (const RECT *)(O + OV_SEL);
    RECT rc = {sh->vx + sel->left, sh->vy + sel->top, sh->vx + sel->right, sh->vy + sel->bottom};
    int w = rc.right - rc.left, h = rc.bottom - rc.top;
    if (w < 32 || h < 32)
        return;
    POINT mid = {(rc.left + rc.right) / 2, (rc.top + rc.bottom) / 2};
    L.rc = rc, L.s = dpi_scale_at(mid);
    L.hover = L.down = -1;
    L.on = true;
    L.auto_on = true;
    L.auto_paused = L.auto_done = L.auto_manual = false;
    L.auto_rows = 0;
    L.auto_delta = 0;
    L.auto_miss = 0;
    L.auto_sent = false;
    L.settle = 0;
    if (!stitch_start(w, h)) {
        long_end();
        return;
    }

    WNDCLASSW wc = {0};
    wc.lpfnWndProc = long_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.lpszClassName = LONG_CLASS;
    RegisterClassW(&wc);
    MONITORINFO mi = {sizeof mi};
    GetMonitorInfoW(MonitorFromRect(&rc, MONITOR_DEFAULTTONEAREST), &mi);
    const RECT *mon = &mi.rcMonitor;
    int t = MAXI(px(2), 2), gap = t + px(6);

    /* the frame: a ring just outside the region */
    L.frame = make(WS_EX_LAYERED | WS_EX_TRANSPARENT, rc.left - t, rc.top - t, w + 2 * t, h + 2 * t);
    if (L.frame) {
        HRGN ring = CreateRectRgn(0, 0, w + 2 * t, h + 2 * t), hole = CreateRectRgn(t, t, t + w, t + h);
        CombineRgn(ring, ring, hole, RGN_DIFF);
        DeleteObject(hole);
        SetWindowRgn(L.frame, ring, FALSE);
    }
    /* the strip with the long picture: right of the region, else left of it, else none */
    int tw = CLAMPI(w / 5, px(90), px(180)), vx = rc.right + gap;
    if (vx + tw > mon->right)
        vx = rc.left - gap - tw;
    if (vx >= mon->left && tw < w) {
        L.tw = tw;
        L.tcap = (int)((int64_t)L.max_rows * tw / w) + 1;
        L.thumb = mem_alloc((size_t)L.tcap * tw * 4);
        L.view = L.thumb ? make(WS_EX_LAYERED | WS_EX_TRANSPARENT, vx, rc.top, tw, h) : NULL;
        if (!L.view)
            L.tw = 0;
    }
    /* the bar: below the region, else above it, else inside its bottom edge */
    int bw = px(240) + (BT_COUNT - bar_first()) * px(30) + px(8), bh = px(34);
    int bx = CLAMPI(rc.right - bw, mon->left, MAXI(mon->left, mon->right - bw)), by = rc.bottom + gap;
    if (by + bh > mon->bottom)
        by = rc.top - gap - bh >= mon->top ? rc.top - gap - bh : rc.bottom - bh - px(6);
    L.bar = make(0, bx, by, bw, bh);
    if (!L.bar || !img_create(&L.barimg, bw, bh)) {
        long_end();
        return;
    }
    int round = 2; /* DWMWCP_ROUND, Windows 11; ignored before */
    DwmSetWindowAttribute(L.bar, 33, &round, sizeof round);
    hotkeys(true);
    HWND wnd[3] = {L.frame, L.view, L.bar};
    for (int i = 0; i < 3; i++)
        if (wnd[i])
            ShowWindow(wnd[i], SW_SHOWNOACTIVATE);
    SetTimer(L.bar, TIMER_GRAB, 150, NULL); /* the first frame: once the capture window is off the screen */
    SetTimer(L.bar, TIMER_AUTO, 800, NULL); /* then the page is scrolled without touching the cursor */
}
