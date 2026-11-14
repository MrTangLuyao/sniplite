/* Small helpers shared by every module (and by the console client). */
#include "common.h"
#include <stdarg.h>

void *mem_alloc(size_t n)
{
    return HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, n ? n : 1);
}

void *mem_grow(void *p, size_t n)
{
    if (!p)
        return mem_alloc(n);
    return HeapReAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, p, n ? n : 1);
}

void mem_free(void *p)
{
    if (p)
        HeapFree(GetProcessHeap(), 0, p);
}

WCHAR *wcs_dup(const WCHAR *s, int n)
{
    if (n < 0)
        n = (int)wcslen(s);
    WCHAR *d = mem_alloc(((size_t)n + 1) * sizeof(WCHAR));
    if (d)
        memcpy(d, s, (size_t)n * sizeof(WCHAR));
    return d;
}

double now_ms(void)
{
    static LARGE_INTEGER freq;
    LARGE_INTEGER c;
    if (!freq.QuadPart)
        QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)freq.QuadPart;
}

RECT rect_isect(RECT a, RECT b)
{
    RECT r = {MAXI(a.left, b.left), MAXI(a.top, b.top), MINI(a.right, b.right), MINI(a.bottom, b.bottom)};
    if (rect_empty(&r))
        r.left = r.top = r.right = r.bottom = 0;
    return r;
}

RECT rect_union(RECT a, RECT b)
{
    if (rect_empty(&a))
        return b;
    if (rect_empty(&b))
        return a;
    RECT r = {MINI(a.left, b.left), MINI(a.top, b.top), MAXI(a.right, b.right), MAXI(a.bottom, b.bottom)};
    return r;
}

RECT rect_inflate(RECT r, int d)
{
    if (rect_empty(&r))
        return r;
    RECT o = {r.left - d, r.top - d, r.right + d, r.bottom + d};
    return o;
}

RECT rect_corners(POINT a, POINT b)
{
    RECT r = {MINI(a.x, b.x), MINI(a.y, b.y), MAXI(a.x, b.x) + 1, MAXI(a.y, b.y) + 1};
    return r;
}

/* ---- Str ---------------------------------------------------------------- */

static bool str_reserve(Str *s, int extra)
{
    if (s->n + extra + 1 <= s->cap)
        return true;
    int cap = MAXI(64, s->cap * 2);
    while (cap < s->n + extra + 1)
        cap *= 2;
    WCHAR *p = mem_grow(s->p, (size_t)cap * sizeof(WCHAR));
    if (!p)
        return false;
    s->p = p;
    s->cap = cap;
    return true;
}

void str_addn(Str *s, const WCHAR *t, int n)
{
    if (n <= 0 || !str_reserve(s, n))
        return;
    memcpy(s->p + s->n, t, (size_t)n * sizeof(WCHAR));
    s->n += n;
    s->p[s->n] = 0;
}

void str_add(Str *s, const WCHAR *t)
{
    str_addn(s, t, (int)wcslen(t));
}

void str_addf(Str *s, const WCHAR *fmt, ...)
{
    WCHAR buf[1025];
    va_list ap;
    va_start(ap, fmt);
    int n = wvsprintfW(buf, fmt, ap);
    va_end(ap);
    if (n > 0)
        str_addn(s, buf, n);
}

void str_add_ms(Str *s, double ms)
{
    int t = (int)(ms * 10.0 + 0.5);
    if (t < 0)
        t = 0;
    str_addf(s, L"%d.%d", t / 10, t % 10);
}

void str_add_json(Str *s, const WCHAR *t)
{
    str_add(s, L"\"");
    for (; *t; t++) {
        WCHAR c = *t;
        if (c == L'"' || c == L'\\') {
            WCHAR e[3] = {L'\\', c, 0};
            str_add(s, e);
        } else if (c == L'\n') {
            str_add(s, L"\\n");
        } else if (c == L'\r') {
            str_add(s, L"\\r");
        } else if (c == L'\t') {
            str_add(s, L"\\t");
        } else if (c < 0x20 || c > 0x7E) {
            str_addf(s, L"\\u%04x", (unsigned)c);
        } else {
            str_addn(s, &c, 1);
        }
    }
    str_add(s, L"\"");
}

void str_add_quoted(Str *s, const WCHAR *a)
{
    str_add(s, L"\"");
    int bs = 0;
    for (const WCHAR *p = a; *p; p++) {
        if (*p == L'\\') {
            bs++;
            continue;
        }
        for (int i = 0; i < (*p == L'"' ? bs * 2 + 1 : bs); i++)
            str_add(s, L"\\");
        bs = 0;
        str_addn(s, p, 1);
    }
    for (int i = 0; i < bs * 2; i++) /* backslashes before the closing quote must be doubled */
        str_add(s, L"\\");
    str_add(s, L"\"");
}

void str_free(Str *s)
{
    mem_free(s->p);
    s->p = NULL;
    s->n = s->cap = 0;
}

/* ---- command line ----------------------------------------------------- */

WCHAR **cmdline_split(const WCHAR *cmd, int *argc)
{
    size_t len = wcslen(cmd);
    int maxargs = (int)len / 2 + 2;
    WCHAR **argv = mem_alloc((size_t)maxargs * sizeof(WCHAR *) + (len + (size_t)maxargs) * sizeof(WCHAR));
    if (!argv) {
        *argc = 0;
        return NULL;
    }
    WCHAR *out = (WCHAR *)(argv + maxargs);
    const WCHAR *p = cmd;
    int n = 0;

    /* argv[0]: quotes delimit, backslashes are literal */
    while (*p == L' ' || *p == L'\t')
        p++;
    if (*p) {
        argv[n++] = out;
        if (*p == L'"') {
            for (p++; *p && *p != L'"'; p++)
                *out++ = *p;
            if (*p)
                p++;
        } else {
            while (*p && *p != L' ' && *p != L'\t')
                *out++ = *p++;
        }
        *out++ = 0;
    }

    for (;;) {
        while (*p == L' ' || *p == L'\t')
            p++;
        if (!*p)
            break;
        argv[n++] = out;
        bool quoted = false;
        while (*p) {
            if (!quoted && (*p == L' ' || *p == L'\t'))
                break;
            if (*p == L'\\') {
                int bs = 0;
                while (*p == L'\\') {
                    bs++;
                    p++;
                }
                if (*p == L'"') {
                    for (int i = 0; i < bs / 2; i++)
                        *out++ = L'\\';
                    if (bs & 1) {
                        *out++ = L'"';
                        p++;
                    }
                } else {
                    for (int i = 0; i < bs; i++)
                        *out++ = L'\\';
                }
            } else if (*p == L'"') {
                if (quoted && p[1] == L'"') {
                    *out++ = L'"';
                    p += 2;
                } else {
                    quoted = !quoted;
                    p++;
                }
            } else {
                *out++ = *p++;
            }
        }
        *out++ = 0;
    }
    *argc = n;
    return argv;
}

bool arg_eq(const WCHAR *a, const WCHAR *b)
{
    return CompareStringOrdinal(a, -1, b, -1, TRUE) == CSTR_EQUAL;
}

/* ---- DPI ----------------------------------------------------------------- */

typedef HRESULT(WINAPI *PFN_GetDpiForMonitor)(HMONITOR, int, UINT *, UINT *);

float dpi_scale_of(HMONITOR mon)
{
    static PFN_GetDpiForMonitor get_dpi;
    static bool tried;
    if (!tried) {
        tried = true;
        HMODULE h = LoadLibraryW(L"shcore.dll");
        if (h)
            get_dpi = (PFN_GetDpiForMonitor)(void *)GetProcAddress(h, "GetDpiForMonitor");
    }
    UINT x = 0, y = 0;
    if (!get_dpi || !mon || FAILED(get_dpi(mon, 0 /* MDT_EFFECTIVE_DPI */, &x, &y)) || !x)
        x = GetDpiForSystem();
    return (float)x / 96.0f;
}

float dpi_scale_at(POINT pt)
{
    return dpi_scale_of(MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST));
}

/* ---- Img ----------------------------------------------------------------- */

bool img_create(Img *im, int w, int h)
{
    memset(im, 0, sizeof *im);
    if (w <= 0 || h <= 0 || (int64_t)w * h > ((int64_t)1 << 28))
        return false;
    BITMAPINFO bi = {0};
    bi.bmiHeader.biSize = sizeof bi.bmiHeader;
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h; /* top-down */
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void *bits = NULL;
    im->bmp = CreateDIBSection(NULL, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    if (!im->bmp)
        return false;
    im->dc = CreateCompatibleDC(NULL);
    if (!im->dc) {
        DeleteObject(im->bmp);
        im->bmp = NULL;
        return false;
    }
    im->old = SelectObject(im->dc, im->bmp);
    im->px = bits;
    im->w = w;
    im->h = h;
    return true;
}

void img_destroy(Img *im)
{
    if (im->dc) {
        SelectObject(im->dc, im->old);
        DeleteDC(im->dc);
    }
    if (im->bmp)
        DeleteObject(im->bmp);
    memset(im, 0, sizeof *im);
}
