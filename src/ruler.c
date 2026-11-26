/* Screen ruler geometry, readout and drawing; see ruler.h. */
#include "ruler.h"

static int abs_i(int v)
{
    return v < 0 ? -v : v;
}

static int put_ch(WCHAR *out, int cap, int n, WCHAR c)
{
    if (n < cap - 1)
        out[n++] = c;
    return n;
}

static int put_int(WCHAR *out, int cap, int n, int v)
{
    WCHAR tmp[12];
    int k = 0;
    unsigned u = (unsigned)v;
    do {
        tmp[k++] = (WCHAR)(L'0' + u % 10);
        u /= 10;
    } while (u);
    while (k > 0)
        n = put_ch(out, cap, n, tmp[--k]);
    return n;
}

/* Integer square root, so nothing here needs the C library or libm. */
static unsigned isqrt64(unsigned long long v)
{
    unsigned long long r = 0, bit = 1ULL << 62;
    while (bit > v)
        bit >>= 2;
    while (bit) {
        if (v >= r + bit) {
            v -= r + bit;
            r = (r >> 1) + bit;
        } else {
            r >>= 1;
        }
        bit >>= 2;
    }
    return (unsigned)r;
}

/* atan2 in radians; the minimax polynomial keeps the error under 0.001 rad. */
static float atan2_approx(int y, int x)
{
    float fy = (float)y, fx = (float)x;
    float ay = fy < 0 ? -fy : fy, ax = fx < 0 ? -fx : fx;
    if (ax == 0 && ay == 0)
        return 0;
    float z = ax >= ay ? ay / ax : ax / ay; /* 0..1 */
    float s = z * z;
    float r = z * (0.9998660f + s * (-0.3302995f + s * (0.1801410f + s * (-0.0851330f + s * 0.0208351f))));
    if (ay > ax)
        r = 1.57079637f - r;
    if (fx < 0)
        r = 3.14159274f - r;
    if (fy < 0)
        r = -r;
    return r;
}

int ruler_label(WCHAR *out, int cap, const RulerGeom *g)
{
    int n = 0;
    if (!out || cap <= 0)
        return 0;
    int w = abs_i(g->bx - g->ax);
    int h = abs_i(g->by - g->ay);
    unsigned long long dx = (unsigned long long)w, dy = (unsigned long long)h;
    unsigned len = isqrt64(dx * dx + dy * dy);
    float deg = atan2_approx(g->by - g->ay, g->bx - g->ax) * (1800.0f / 3.14159274f);
    int deg10 = (int)(deg + (deg < 0 ? -0.5f : 0.5f));
    if (deg10 < -1800)
        deg10 = -1800;
    if (deg10 > 1800)
        deg10 = 1800;
    n = put_int(out, cap, n, w);
    n = put_ch(out, cap, n, 0x0020);
    n = put_ch(out, cap, n, 0x00D7);
    n = put_ch(out, cap, n, 0x0020);
    n = put_int(out, cap, n, h);
    n = put_ch(out, cap, n, 0x0020);
    n = put_ch(out, cap, n, 0x0020);
    n = put_int(out, cap, n, (int)len);
    n = put_ch(out, cap, n, 0x0020);
    n = put_ch(out, cap, n, L'p');
    n = put_ch(out, cap, n, L'x');
    n = put_ch(out, cap, n, 0x0020);
    n = put_ch(out, cap, n, 0x0020);
    if (deg10 < 0) {
        n = put_ch(out, cap, n, L'-');
        deg10 = -deg10;
    }
    n = put_int(out, cap, n, deg10 / 10);
    n = put_ch(out, cap, n, L'.');
    n = put_int(out, cap, n, deg10 % 10);
    n = put_ch(out, cap, n, 0x00B0);
    out[n < cap ? n : cap - 1] = 0;
    return n;
}

/* Move dx/dy to the nearest axis or diagonal when it is close. */
static void snap_axis(int *dx, int *dy)
{
    int ax = abs_i(*dx), ay = abs_i(*dy);
    if (ax > ay * 2) {
        *dy = 0;
    } else if (ay > ax * 2) {
        *dx = 0;
    } else if (ax || ay) {
        int m = ax > ay ? ax : ay;
        *dx = *dx < 0 ? -m : m;
        *dy = *dy < 0 ? -m : m;
    }
}

void ruler_move(RulerGeom *g, int drag, int shift, int alt)
{
    if (drag == 1) {
        int dx = g->px - g->bx, dy = g->py - g->by;
        if (shift)
            snap_axis(&dx, &dy);
        g->ax = g->bx + dx;
        g->ay = g->by + dy;
    } else if (drag == 2) {
        int dx = g->px - g->ax, dy = g->py - g->ay;
        if (shift)
            snap_axis(&dx, &dy);
        g->bx = g->ax + dx;
        g->by = g->ay + dy;
        if (alt) {
            g->ax = 2 * g->cx - g->bx;
            g->ay = 2 * g->cy - g->by;
        }
    }
}

void ruler_draw(const Surf *s, const RulerGeom *g, float scale)
{
    float s0 = scale < 0.5f ? 0.5f : scale;
    float ax = (float)g->ax + 0.5f, ay = (float)g->ay + 0.5f;
    float bx = (float)g->bx + 0.5f, by = (float)g->by + 0.5f;
    int dx = abs_i(g->bx - g->ax), dy = abs_i(g->by - g->ay);
    if (dx || dy) {
        /* the right-angle guides first, so the measurement line stays on top */
        d_line(s, ax, ay, bx, ay, s0, 0xFFFFFF, 90);
        d_line(s, bx, ay, bx, by, s0, 0xFFFFFF, 90);
        d_line(s, ax, ay, bx, by, s0 * 3.0f, 0xFFFFFF, 70);
        d_line(s, ax, ay, bx, by, s0 * 1.6f, 0x1A8CFF, 255);
    }
    d_disc(s, ax, ay, s0 * 4.0f, 0x1A8CFF, 255);
    d_disc(s, ax, ay, s0 * 2.0f, 0xFFFFFF, 255);
    d_disc(s, bx, by, s0 * 4.0f, 0x1A8CFF, 255);
    d_disc(s, bx, by, s0 * 2.0f, 0xFFFFFF, 255);
}

int ruler_tick_step(int scale1000, int min_px)
{
    int base = 1, m = 1;
    if (scale1000 <= 0)
        scale1000 = 1000;
    if (min_px < 1)
        min_px = 1;
    while ((long long)base * m * scale1000 < (long long)min_px * 1000) {
        if (m == 1)
            m = 2;
        else if (m == 2)
            m = 5;
        else {
            m = 1;
            base *= 10;
        }
    }
    return base * m;
}
