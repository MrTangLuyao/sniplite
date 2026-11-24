/* Always-on edge ruler: tick bars along the top and left of the monitor under
 * the mouse. They are layered, take no focus or clicks, and stay out of
 * captures so screenshots do not include them. */
#include "ruler_win.h"
#include "ruler.h"

#define BAR_CLASS L"sniplite.edge-ruler"
#define BAR_CAPTURE_EXCLUDE 0x11 /* WDA_EXCLUDEFROMCAPTURE */
#define CROSS_TIMER 1
#define CROSS_MS 16
#define LABEL_DELAY_MS 260
#define LOUPE_PIXELS 15
#define LOUPE_REFRESH_MS 150

enum { BAR_TOP = 1, BAR_LEFT = 2, BAR_CROSS_H = 3, BAR_CROSS_V = 4, BAR_LABEL = 5, BAR_LOUPE = 6 };

static HWND g_top, g_left, g_cross_h, g_cross_v, g_label, g_loupe;
static RECT g_monitor;
static float g_scale = 1.0f;
static int g_bar = 32;
static int g_font_h;
static HFONT g_font;
static bool g_cross_shown;
static bool g_cross_enabled = true;
static LONG g_cross_x = -1000000, g_cross_y = -1000000;
static uint32_t g_cross_color = 0x00D6F5;
static int g_label_w, g_label_h;
static WCHAR g_label_text[32];
static bool g_label_shown;
static bool g_loupe_shown;
static int g_loupe_zoom = 6;
static int g_loupe_size;
static POINT g_loupe_at = {-1000000, -1000000};
static DWORD g_loupe_refresh;
static DWORD g_still_at;

static void cross_track(void);

static int iround(float v)
{
    return (int)(v + 0.5f);
}

static void paint_top(HDC dc, int w, int h)
{
    RECT all = {0, 0, w, h};
    HBRUSH bg = CreateSolidBrush(RGB(20, 22, 27));
    FillRect(dc, &all, bg);
    DeleteObject(bg);

    int screen_w = g_monitor.right - g_monitor.left;
    int step = ruler_tick_step(1000, iround(90.0f * g_scale));
    int minor = step / 5;
    if (minor < 1)
        minor = 1;
    int major_len = iround(10.0f * g_scale);
    int minor_len = iround(5.0f * g_scale);
    if (major_len < 4)
        major_len = 4;
    if (minor_len < 2)
        minor_len = 2;
    if (major_len > h - 2)
        major_len = h - 2;
    if (minor_len > h - 2)
        minor_len = h - 2;

    HPEN tick = CreatePen(PS_SOLID, 1, RGB(132, 142, 158));
    HPEN hot = CreatePen(PS_SOLID, 1, RGB(90, 175, 255));
    HGDIOBJ old = SelectObject(dc, tick);
    for (int v = 0; v < screen_w; v += minor) {
        MoveToEx(dc, v, h - 1, NULL);
        LineTo(dc, v, h - 1 - minor_len);
    }
    SelectObject(dc, hot);
    for (int v = 0; v < screen_w; v += step) {
        MoveToEx(dc, v, h - 1, NULL);
        LineTo(dc, v, h - 1 - major_len);
    }
    SelectObject(dc, old);
    DeleteObject(tick);
    DeleteObject(hot);

    HPEN edge = CreatePen(PS_SOLID, 1, RGB(58, 68, 84));
    HGDIOBJ oe = SelectObject(dc, edge);
    MoveToEx(dc, 0, h - 1, NULL);
    LineTo(dc, w, h - 1);
    SelectObject(dc, oe);
    DeleteObject(edge);

    HFONT font = g_font ? g_font : (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    HGDIOBJ of = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(226, 231, 239));
    int box = iround(56.0f * g_scale);
    int top = iround(2.0f * g_scale);
    for (int v = 0; v < screen_w; v += step) {
        WCHAR t[16];
        wsprintfW(t, L"%d", v);
        int l = v - box / 2, r = l + box;
        UINT align = DT_CENTER;
        if (l < 1) {
            r = box + 1;
            l = 1;
            align = DT_LEFT;
        }
        if (r > w - 1) {
            l -= r - (w - 1);
            r = w - 1;
            align = DT_RIGHT;
        }
        if (l < 0)
            l = 0;
        RECT tr = {l, top, r, h - major_len - 1};
        DrawTextW(dc, t, -1, &tr, align | DT_TOP | DT_SINGLELINE | DT_NOCLIP);
    }
    SelectObject(dc, of);
}

static void paint_left(HDC dc, int w, int h)
{
    RECT all = {0, 0, w, h};
    HBRUSH bg = CreateSolidBrush(RGB(20, 22, 27));
    FillRect(dc, &all, bg);
    DeleteObject(bg);

    int screen_h = g_monitor.bottom - g_monitor.top;
    int step = ruler_tick_step(1000, iround(90.0f * g_scale));
    int minor = step / 5;
    if (minor < 1)
        minor = 1;
    int major_len = iround(10.0f * g_scale);
    int minor_len = iround(5.0f * g_scale);
    if (major_len < 4)
        major_len = 4;
    if (minor_len < 2)
        minor_len = 2;
    if (major_len > w - 2)
        major_len = w - 2;
    if (minor_len > w - 2)
        minor_len = w - 2;

    HPEN tick = CreatePen(PS_SOLID, 1, RGB(132, 142, 158));
    HPEN hot = CreatePen(PS_SOLID, 1, RGB(90, 175, 255));
    HGDIOBJ old = SelectObject(dc, tick);
    for (int v = ((g_bar + minor - 1) / minor) * minor; v < screen_h; v += minor) {
        int y = v - g_bar;
        if (y < 0)
            continue;
        MoveToEx(dc, w - 1, y, NULL);
        LineTo(dc, w - 1 - minor_len, y);
    }
    SelectObject(dc, hot);
    for (int v = ((g_bar + step - 1) / step) * step; v < screen_h; v += step) {
        int y = v - g_bar;
        if (y < 0)
            continue;
        MoveToEx(dc, w - 1, y, NULL);
        LineTo(dc, w - 1 - major_len, y);
    }
    SelectObject(dc, old);
    DeleteObject(tick);
    DeleteObject(hot);

    HPEN edge = CreatePen(PS_SOLID, 1, RGB(58, 68, 84));
    HGDIOBJ oe = SelectObject(dc, edge);
    MoveToEx(dc, w - 1, 0, NULL);
    LineTo(dc, w - 1, h);
    SelectObject(dc, oe);
    DeleteObject(edge);

    HFONT font = g_font ? g_font : (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    HGDIOBJ of = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(226, 231, 239));
    int pad = iround(3.0f * g_scale);
    int fh = g_font_h > 0 ? g_font_h : 11;
    for (int v = ((g_bar + step - 1) / step) * step; v < screen_h; v += step) {
        int y = v - g_bar;
        if (y < 0)
            continue;
        WCHAR t[16];
        wsprintfW(t, L"%d", v);
        RECT tr = {pad, y - fh / 2, w - major_len - pad, y + (fh + 1) / 2};
        DrawTextW(dc, t, -1, &tr, DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_NOCLIP);
    }
    SelectObject(dc, of);
}

static COLORREF cref(uint32_t c)
{
    return RGB((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF);
}

/* The chosen color, or a light one when it would disappear on the box's dark background. */
static COLORREF cross_ink(void)
{
    uint32_t c = g_cross_color;
    int lum = (int)(((c >> 16) & 0xFF) * 299 + ((c >> 8) & 0xFF) * 587 + (c & 0xFF) * 114) / 1000;
    return lum < 70 ? RGB(235, 240, 246) : cref(c);
}

static void paint_cross(HDC dc, int w, int h)
{
    HBRUSH b = CreateSolidBrush(cref(g_cross_color));
    RECT r = {0, 0, w, h};
    FillRect(dc, &r, b);
    DeleteObject(b);
}

static void paint_label(HDC dc, int w, int h)
{
    RECT all = {0, 0, w, h};
    HBRUSH bg = CreateSolidBrush(RGB(16, 18, 22));
    FillRect(dc, &all, bg);
    DeleteObject(bg);

    COLORREF ink = cross_ink();
    HPEN pen = CreatePen(PS_SOLID, 1, ink);
    HGDIOBJ op = SelectObject(dc, pen);
    HGDIOBJ ob = SelectObject(dc, GetStockObject(NULL_BRUSH));
    Rectangle(dc, 0, 0, w, h);
    SelectObject(dc, ob);
    SelectObject(dc, op);
    DeleteObject(pen);

    HFONT font = g_font ? g_font : (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    HGDIOBJ of = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, ink);
    RECT tr = {iround(4.0f * g_scale), 0, w - iround(4.0f * g_scale), h};
    DrawTextW(dc, g_label_text, -1, &tr, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOCLIP);
    SelectObject(dc, of);
}

static void paint_loupe(HDC dc, int w, int h)
{
    RECT all = {0, 0, w, h};
    HBRUSH bg = CreateSolidBrush(RGB(10, 12, 16));
    FillRect(dc, &all, bg);
    DeleteObject(bg);

    int zoom = g_loupe_zoom > 0 ? g_loupe_zoom : 1;
    int src_w = w / zoom, src_h = h / zoom;
    if (src_w < 1)
        src_w = 1;
    if (src_h < 1)
        src_h = 1;
    int sx = g_loupe_at.x - src_w / 2;
    int sy = g_loupe_at.y - src_h / 2;
    int dx = 0, dy = 0, cw = src_w, ch = src_h;
    if (sx < g_monitor.left) {
        dx = g_monitor.left - sx;
        sx = g_monitor.left;
        cw -= dx;
    }
    if (sy < g_monitor.top) {
        dy = g_monitor.top - sy;
        sy = g_monitor.top;
        ch -= dy;
    }
    if (sx + cw > g_monitor.right)
        cw = g_monitor.right - sx;
    if (sy + ch > g_monitor.bottom)
        ch = g_monitor.bottom - sy;
    if (cw > 0 && ch > 0) {
        HDC screen = GetDC(NULL);
        if (screen) {
            SetStretchBltMode(dc, COLORONCOLOR);
            StretchBlt(dc, dx * zoom, dy * zoom, cw * zoom, ch * zoom, screen, sx, sy, cw, ch, SRCCOPY);
            ReleaseDC(NULL, screen);
        }
    }

    HGDIOBJ ob = SelectObject(dc, GetStockObject(NULL_BRUSH));
    if (zoom >= 4) {
        HPEN grid = CreatePen(PS_SOLID, 1, RGB(96, 108, 126));
        HGDIOBJ og = SelectObject(dc, grid);
        for (int x = 1; x < src_w; x++) {
            MoveToEx(dc, x * zoom, 0, NULL);
            LineTo(dc, x * zoom, h);
        }
        for (int y = 1; y < src_h; y++) {
            MoveToEx(dc, 0, y * zoom, NULL);
            LineTo(dc, w, y * zoom);
        }
        SelectObject(dc, og);
        DeleteObject(grid);
    }
    int cx = (src_w / 2) * zoom, cy = (src_h / 2) * zoom;
    HPEN hot = CreatePen(PS_SOLID, 2, cross_ink());
    HGDIOBJ oh = SelectObject(dc, hot);
    Rectangle(dc, cx - 1, cy - 1, cx + zoom + 1, cy + zoom + 1);
    SelectObject(dc, oh);
    DeleteObject(hot);
    HPEN edge = CreatePen(PS_SOLID, 1, RGB(82, 94, 110));
    HGDIOBJ oe = SelectObject(dc, edge);
    Rectangle(dc, 0, 0, w, h);
    SelectObject(dc, oe);
    SelectObject(dc, ob);
    DeleteObject(edge);
}

static void paint_bar(HWND hwnd)
{
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(hwnd, &ps);
    RECT cr;
    GetClientRect(hwnd, &cr);
    int w = cr.right, h = cr.bottom;
    if (w > 0 && h > 0) {
        HDC mem = CreateCompatibleDC(dc);
        HBITMAP bmp = mem ? CreateCompatibleBitmap(dc, w, h) : NULL;
        HGDIOBJ old = bmp ? SelectObject(mem, bmp) : NULL;
        HDC tgt = bmp ? mem : dc;
        int kind = (int)(LONG_PTR)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if (kind == BAR_TOP)
            paint_top(tgt, w, h);
        else if (kind == BAR_LEFT)
            paint_left(tgt, w, h);
        else if (kind == BAR_LABEL)
            paint_label(tgt, w, h);
        else if (kind == BAR_LOUPE)
            paint_loupe(tgt, w, h);
        else
            paint_cross(tgt, w, h);
        if (bmp) {
            BitBlt(dc, 0, 0, w, h, mem, 0, 0, SRCCOPY);
            SelectObject(mem, old);
            DeleteObject(bmp);
        }
        if (mem)
            DeleteDC(mem);
    }
    EndPaint(hwnd, &ps);
}

static LRESULT CALLBACK bar_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    switch (m) {
    case WM_TIMER:
        if (h == g_cross_h && wp == CROSS_TIMER) {
            cross_track();
            return 0;
        }
        break;
    case WM_NCHITTEST:
        return HTTRANSPARENT;
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT:
        paint_bar(h);
        return 0;
    case WM_DESTROY:
        if (h == g_top)
            g_top = NULL;
        else if (h == g_left)
            g_left = NULL;
        else if (h == g_cross_h)
            g_cross_h = NULL;
        else if (h == g_cross_v)
            g_cross_v = NULL;
        else if (h == g_label)
            g_label = NULL;
        else if (h == g_loupe)
            g_loupe = NULL;
        return 0;
    }
    return DefWindowProcW(h, m, wp, lp);
}

static bool bar_class_ready(void)
{
    static int state;
    if (state)
        return state > 0;
    WNDCLASSEXW wc;
    ZeroMemory(&wc, sizeof wc);
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = bar_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.lpszClassName = BAR_CLASS;
    if (RegisterClassExW(&wc) || GetLastError() == ERROR_CLASS_ALREADY_EXISTS)
        state = 1;
    else
        state = -1;
    return state > 0;
}

static HWND make_bar(int kind, int x, int y, int w, int h, bool show)
{
    DWORD ex = WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT;
    HWND hwnd = CreateWindowExW(ex, BAR_CLASS, L"", WS_POPUP, x, y, w, h, NULL, NULL, GetModuleHandleW(NULL),
                                NULL);
    if (!hwnd)
        return NULL;
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)kind);
    BYTE alpha = 176;
    if (kind == BAR_CROSS_H || kind == BAR_CROSS_V)
        alpha = 245;
    else if (kind == BAR_LABEL)
        alpha = 232;
    else if (kind == BAR_LOUPE)
        alpha = 248;
    SetLayeredWindowAttributes(hwnd, 0, alpha, LWA_ALPHA);
    SetWindowDisplayAffinity(hwnd, BAR_CAPTURE_EXCLUDE);
    SetWindowPos(hwnd, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE | (show ? SWP_SHOWWINDOW : 0));
    return hwnd;
}

static void label_hide(void)
{
    if (g_label && g_label_shown) {
        ShowWindow(g_label, SW_HIDE);
        g_label_shown = false;
    }
    if (g_loupe && g_loupe_shown) {
        ShowWindow(g_loupe, SW_HIDE);
        g_loupe_shown = false;
    }
}

static void label_show(POINT p)
{
    if (!g_label)
        return;
    int rx = p.x - g_monitor.left, ry = p.y - g_monitor.top;
    wsprintfW(g_label_text, L"%d, %d", rx, ry);
    int off = iround(16.0f * g_scale);
    int x = p.x + off, y = p.y + off;
    if (x + g_label_w > g_monitor.right)
        x = p.x - g_label_w - off;
    if (y + g_label_h > g_monitor.bottom)
        y = p.y - g_label_h - off;
    if (x < g_monitor.left)
        x = g_monitor.left;
    if (y < g_monitor.top)
        y = g_monitor.top;
    SetWindowPos(g_label, HWND_TOPMOST, x, y, g_label_w, g_label_h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InvalidateRect(g_label, NULL, TRUE);
    g_label_shown = true;
    if (g_loupe && g_loupe_size > 0) {
        int gap = iround(4.0f * g_scale);
        int lx = x, ly = y + g_label_h + gap;
        if (ly + g_loupe_size > g_monitor.bottom)
            ly = y - g_loupe_size - gap;
        if (ly < g_monitor.top)
            ly = g_monitor.top;
        if (lx + g_loupe_size > g_monitor.right)
            lx = g_monitor.right - g_loupe_size;
        if (lx < g_monitor.left)
            lx = g_monitor.left;
        g_loupe_at = p;
        SetWindowPos(g_loupe, HWND_TOPMOST, lx, ly, g_loupe_size, g_loupe_size,
                     SWP_NOACTIVATE | SWP_SHOWWINDOW);
        InvalidateRect(g_loupe, NULL, TRUE);
        g_loupe_shown = true;
        g_loupe_refresh = GetTickCount();
    }
}

static void cross_track(void)
{
    if (!g_cross_enabled || !g_cross_h || !g_cross_v)
        return;
    POINT p;
    if (!GetCursorPos(&p) || p.x < g_monitor.left || p.x >= g_monitor.right || p.y < g_monitor.top ||
        p.y >= g_monitor.bottom) {
        label_hide();
        if (g_cross_shown) {
            ShowWindow(g_cross_h, SW_HIDE);
            ShowWindow(g_cross_v, SW_HIDE);
            g_cross_shown = false;
        }
        return;
    }
    if (g_cross_shown && p.x == g_cross_x && p.y == g_cross_y) {
        DWORD now = GetTickCount();
        if (!g_label_shown && g_label && now - g_still_at >= LABEL_DELAY_MS)
            label_show(p);
        else if (g_loupe_shown && g_loupe && now - g_loupe_refresh >= LOUPE_REFRESH_MS) {
            g_loupe_refresh = now;
            InvalidateRect(g_loupe, NULL, FALSE);
        }
        return;
    }
    label_hide();
    SetWindowPos(g_cross_h, HWND_TOPMOST, g_monitor.left, p.y, 0, 0,
                 SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    SetWindowPos(g_cross_v, HWND_TOPMOST, p.x, g_monitor.top, 0, 0,
                 SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    g_cross_x = p.x;
    g_cross_y = p.y;
    g_cross_shown = true;
    g_still_at = GetTickCount();
}

void edge_ruler_hide(void)
{
    HWND top = g_top, left = g_left, ch = g_cross_h, cv = g_cross_v, label = g_label, loupe = g_loupe;
    g_top = g_left = g_cross_h = g_cross_v = g_label = g_loupe = NULL;
    g_cross_shown = false;
    g_label_shown = false;
    g_loupe_shown = false;
    g_loupe_at.x = g_loupe_at.y = -1000000;
    g_still_at = 0;
    g_loupe_refresh = 0;
    g_cross_x = g_cross_y = -1000000;
    if (ch)
        KillTimer(ch, CROSS_TIMER);
    if (cv)
        KillTimer(cv, CROSS_TIMER);
    if (top)
        DestroyWindow(top);
    if (left)
        DestroyWindow(left);
    if (ch)
        DestroyWindow(ch);
    if (cv)
        DestroyWindow(cv);
    if (label)
        DestroyWindow(label);
    if (loupe)
        DestroyWindow(loupe);
    if (g_font) {
        DeleteObject(g_font);
        g_font = NULL;
    }
    g_font_h = 0;
}

bool edge_ruler_show(void)
{
    edge_ruler_hide();
    if (!bar_class_ready())
        return false;
    POINT pt;
    GetCursorPos(&pt);
    HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO mi;
    mi.cbSize = sizeof mi;
    if (!GetMonitorInfoW(mon, &mi))
        return false;
    RECT rc = mi.rcMonitor;
    int sw = rc.right - rc.left, sh = rc.bottom - rc.top;
    if (sw <= 0 || sh <= 0)
        return false;
    float scale = dpi_scale_of(mon);
    if (!(scale > 0.5f))
        scale = 1.0f;
    if (scale > 4.0f)
        scale = 4.0f;
    g_scale = scale;
    g_bar = iround(32.0f * scale);
    if (g_bar < 18)
        g_bar = 18;
    if (g_bar > sh)
        g_bar = sh;
    g_monitor = rc;
    g_font_h = iround(8.5f * scale);
    if (g_font_h < 8)
        g_font_h = 8;
    g_font = CreateFontW(-g_font_h, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_TT_PRECIS,
                         CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Tahoma");
    if (!g_font)
        g_font_h = 11;

    g_top = make_bar(BAR_TOP, rc.left, rc.top, sw, g_bar, true);
    if (!g_top) {
        edge_ruler_hide();
        return false;
    }
    if (sh > g_bar) {
        int lw = iround(34.0f * g_scale);
        if (lw < g_bar)
            lw = g_bar;
        if (lw > sw)
            lw = sw;
        g_left = make_bar(BAR_LEFT, rc.left, rc.top + g_bar, lw, sh - g_bar, true);
        if (!g_left) {
            edge_ruler_hide();
            return false;
        }
    }
    g_cross_h = make_bar(BAR_CROSS_H, rc.left, rc.top, sw, 1, false);
    g_cross_v = make_bar(BAR_CROSS_V, rc.left, rc.top, 1, sh, false);
    g_label_w = iround(90.0f * g_scale);
    g_label_h = iround(28.0f * g_scale);
    if (g_label_w < 64)
        g_label_w = 64;
    if (g_label_h < 22)
        g_label_h = 22;
    g_label = make_bar(BAR_LABEL, rc.left, rc.top, g_label_w, g_label_h, false);
    g_loupe_zoom = iround(6.0f * g_scale);
    if (g_loupe_zoom < 3)
        g_loupe_zoom = 3;
    if (g_loupe_zoom > 12)
        g_loupe_zoom = 12;
    g_loupe_size = LOUPE_PIXELS * g_loupe_zoom;
    if (g_loupe_size > sh)
        g_loupe_size = sh;
    g_loupe = make_bar(BAR_LOUPE, rc.left, rc.top, g_loupe_size, g_loupe_size, false);
    if (!g_cross_h || !g_cross_v || !g_label || !g_loupe) {
        edge_ruler_hide();
        return false;
    }
    lstrcpyW(g_label_text, L"0, 0");
    g_label_shown = false;
    g_loupe_shown = false;
    g_still_at = GetTickCount();
    if (g_cross_enabled) {
        SetTimer(g_cross_h, CROSS_TIMER, CROSS_MS, NULL);
        cross_track();
    }
    return true;
}

void edge_ruler_toggle(void)
{
    if (edge_ruler_visible())
        edge_ruler_hide();
    else
        edge_ruler_show();
}

bool edge_ruler_visible(void)
{
    return g_top != NULL || g_left != NULL;
}

bool edge_ruler_cross_enabled(void)
{
    return g_cross_enabled;
}

void edge_ruler_cross_set(bool on)
{
    g_cross_enabled = on;
    if (!on) {
        label_hide();
        if (g_cross_shown && g_cross_h && g_cross_v) {
            ShowWindow(g_cross_h, SW_HIDE);
            ShowWindow(g_cross_v, SW_HIDE);
        }
        g_cross_shown = false;
        g_cross_x = g_cross_y = -1000000;
        g_still_at = 0;
        if (g_cross_h)
            KillTimer(g_cross_h, CROSS_TIMER);
    } else if (g_cross_h) {
        g_cross_x = g_cross_y = -1000000;
        g_still_at = GetTickCount();
        SetTimer(g_cross_h, CROSS_TIMER, CROSS_MS, NULL);
        cross_track();
    }
}

void edge_ruler_cross_toggle(void)
{
    edge_ruler_cross_set(!g_cross_enabled);
}

void edge_ruler_refresh(void)
{
    if (edge_ruler_visible())
        edge_ruler_show();
}

void edge_ruler_set_color(uint32_t color)
{
    g_cross_color = color & 0xFFFFFF;
    if (g_cross_h)
        InvalidateRect(g_cross_h, NULL, TRUE);
    if (g_cross_v)
        InvalidateRect(g_cross_v, NULL, TRUE);
    if (g_label)
        InvalidateRect(g_label, NULL, TRUE);
}
