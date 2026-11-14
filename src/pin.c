/* Pin windows: drag to move, wheel to zoom, Ctrl+wheel for opacity,
 * double-click or Esc to close, right-click for a menu. */
#include "pin.h"
#include "image.h"
#include "lang.h"
#include <dwmapi.h>
#include <math.h>
#include <windowsx.h>

#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif

#define TIMER_LABEL 1
enum { CM_COPY = 1, CM_SAVE, CM_RESET, CM_CLOSE, CM_CLOSE_ALL };

typedef struct Pin {
    HWND hwnd;
    Img img;
    float zoom;
    int alpha; /* percent, 10..100 */
    bool drag;
    POINT drag_pt, win_pt;
    bool show_label;
    WCHAR label[32];
    struct Pin *next;
} Pin;

static struct {
    HINSTANCE inst;
    HWND daemon;
    Pin *list;
    int count;
} P;

static Pin *pin_of(HWND h) { return (Pin *)GetWindowLongPtrW(h, GWLP_USERDATA); }

static void flash_label(Pin *p, const WCHAR *text)
{
    lstrcpynW(p->label, text, COUNTOF(p->label));
    p->show_label = true;
    SetTimer(p->hwnd, TIMER_LABEL, 900, NULL);
    InvalidateRect(p->hwnd, NULL, FALSE);
}

static void set_zoom(Pin *p, float z, POINT anchor)
{
    float maxz = fminf(16.f, 16000.f / (float)MAXI(p->img.w, p->img.h));
    z = fmaxf(0.05f, fminf(z, maxz));
    RECT wr;
    GetWindowRect(p->hwnd, &wr);
    float fx = (float)(anchor.x - wr.left) / (float)MAXI(1, wr.right - wr.left);
    float fy = (float)(anchor.y - wr.top) / (float)MAXI(1, wr.bottom - wr.top);
    int nw = MAXI(8, (int)lroundf((float)p->img.w * z)), nh = MAXI(8, (int)lroundf((float)p->img.h * z));
    int nx = anchor.x - (int)lroundf(fx * (float)nw), ny = anchor.y - (int)lroundf(fy * (float)nh);
    p->zoom = z;
    SetWindowPos(p->hwnd, NULL, nx, ny, nw, nh, SWP_NOZORDER | SWP_NOACTIVATE);
    WCHAR t[16];
    wsprintfW(t, L"%d%%", (int)lroundf(z * 100.f));
    flash_label(p, t);
}

static void set_alpha(Pin *p, int pct)
{
    p->alpha = CLAMPI(pct, 10, 100);
    LONG ex = GetWindowLongW(p->hwnd, GWL_EXSTYLE);
    if (p->alpha < 100) {
        if (!(ex & WS_EX_LAYERED))
            SetWindowLongW(p->hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED);
        SetLayeredWindowAttributes(p->hwnd, 0, (BYTE)(p->alpha * 255 / 100), LWA_ALPHA);
    } else if (ex & WS_EX_LAYERED) {
        /* fully opaque again: drop the layered style, it costs composition work */
        SetWindowLongW(p->hwnd, GWL_EXSTYLE, ex & ~WS_EX_LAYERED);
        RedrawWindow(p->hwnd, NULL, NULL, RDW_INVALIDATE | RDW_FRAME);
    }
    WCHAR t[24];
    wsprintfW(t, T(PIN_OPACITY), p->alpha);
    flash_label(p, t);
}

static void pin_copy(Pin *p)
{
    clip_put_image(P.daemon, p->img.px, p->img.w, p->img.w, p->img.h);
    flash_label(p, T(PIN_COPIED));
}

static void pin_save(Pin *p)
{
    /* The dialog runs a nested message loop in which this pin may be closed,
     * so save from a private copy and re-validate the window afterwards. */
    Img copy;
    if (!img_create(&copy, p->img.w, p->img.h))
        return;
    memcpy(copy.px, p->img.px, (size_t)p->img.w * p->img.h * 4);
    HWND h = p->hwnd;
    WCHAR path[MAX_PATH * 2];
    if (save_dialog(path, COUNTOF(path))) {
        bool ok = image_save(path, copy.px, copy.w, copy.w, copy.h);
        if (IsWindow(h) && pin_of(h) == p)
            flash_label(p, ok ? T(PIN_SAVED) : T(PIN_SAVE_FAILED));
    }
    img_destroy(&copy);
}

static void pin_menu(Pin *p, POINT at)
{
    HMENU m = CreatePopupMenu();
    AppendMenuW(m, MF_STRING, CM_COPY, T(PM_COPY));
    AppendMenuW(m, MF_STRING, CM_SAVE, T(PM_SAVE));
    AppendMenuW(m, MF_STRING | (p->zoom == 1.f && p->alpha == 100 ? MF_GRAYED : 0), CM_RESET, T(PM_RESET));
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    AppendMenuW(m, MF_STRING, CM_CLOSE, T(PM_CLOSE));
    AppendMenuW(m, MF_STRING, CM_CLOSE_ALL, T(M_CLOSE_PINS));
    HWND h = p->hwnd;
    SetForegroundWindow(h);
    int cmd = TrackPopupMenu(m, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, at.x, at.y, 0, h, NULL);
    DestroyMenu(m);
    PostMessageW(h, WM_NULL, 0, 0);
    if (!IsWindow(h))
        return;
    switch (cmd) {
    case CM_COPY: pin_copy(p); break;
    case CM_SAVE: pin_save(p); break;
    case CM_RESET: {
        RECT wr;
        GetWindowRect(h, &wr);
        POINT tl = {wr.left, wr.top};
        set_alpha(p, 100);
        set_zoom(p, 1.f, tl);
        break;
    }
    case CM_CLOSE: DestroyWindow(h); break;
    case CM_CLOSE_ALL: pin_close_all(); break;
    }
}

static void paint(Pin *p)
{
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(p->hwnd, &ps);
    RECT rc;
    GetClientRect(p->hwnd, &rc);
    int w = rc.right, h = rc.bottom;
    HDC tgt = dc, mem = NULL;
    HBITMAP bmp = NULL;
    HGDIOBJ old = NULL;
    if (p->show_label) { /* compose off-screen so the label never flickers */
        mem = CreateCompatibleDC(dc);
        bmp = CreateCompatibleBitmap(dc, w, h);
        if (mem && bmp) {
            old = SelectObject(mem, bmp);
            tgt = mem;
        }
    }
    if (w == p->img.w && h == p->img.h) {
        BitBlt(tgt, 0, 0, w, h, p->img.dc, 0, 0, SRCCOPY);
    } else {
        SetStretchBltMode(tgt, w < p->img.w ? HALFTONE : COLORONCOLOR);
        SetBrushOrgEx(tgt, 0, 0, NULL);
        StretchBlt(tgt, 0, 0, w, h, p->img.dc, 0, 0, p->img.w, p->img.h, SRCCOPY);
    }
    if (tgt == mem) {
        float s = (float)GetDpiForWindow(p->hwnd) / 96.f;
        HFONT f = CreateFontW(-(int)lroundf(12.f * s), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                              CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, T(FONT));
        HGDIOBJ of = SelectObject(mem, f);
        SIZE sz;
        GetTextExtentPoint32W(mem, p->label, lstrlenW(p->label), &sz);
        int pad = (int)lroundf(6.f * s);
        RECT lr = {0, 0, sz.cx + pad * 2, sz.cy + pad};
        HBRUSH br = CreateSolidBrush(RGB(32, 32, 32));
        FillRect(mem, &lr, br);
        DeleteObject(br);
        SetBkMode(mem, TRANSPARENT);
        SetTextColor(mem, RGB(255, 255, 255));
        DrawTextW(mem, p->label, -1, &lr, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        SelectObject(mem, of);
        DeleteObject(f);
        BitBlt(dc, 0, 0, w, h, mem, 0, 0, SRCCOPY);
    }
    if (mem) {
        if (old)
            SelectObject(mem, old);
        DeleteDC(mem);
    }
    if (bmp)
        DeleteObject(bmp);
    EndPaint(p->hwnd, &ps);
}

static LRESULT CALLBACK pin_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    if (m == WM_NCCREATE) {
        Pin *np = ((CREATESTRUCTW *)lp)->lpCreateParams;
        np->hwnd = h;
        SetWindowLongPtrW(h, GWLP_USERDATA, (LONG_PTR)np);
    }
    Pin *p = pin_of(h);
    if (!p)
        return DefWindowProcW(h, m, wp, lp);
    switch (m) {
    case WM_NCCALCSIZE:
        if (wp)
            return 0; /* no non-client area: the image is the whole window */
        break;
    case WM_NCHITTEST:
        return HTCLIENT;
    case WM_NCACTIVATE:
        return DefWindowProcW(h, m, wp, -1); /* do not repaint a frame we do not have */
    case WM_GETMINMAXINFO: {
        MINMAXINFO *mm = (MINMAXINFO *)lp;
        mm->ptMinTrackSize.x = mm->ptMinTrackSize.y = 1;
        mm->ptMaxTrackSize.x = mm->ptMaxTrackSize.y = 32000;
        return 0;
    }
    case WM_SYSCOMMAND: {
        UINT c = (UINT)(wp & 0xFFF0);
        if (c == SC_MAXIMIZE || c == SC_MINIMIZE || c == SC_SIZE || c == SC_RESTORE)
            return 0;
        break;
    }
    case WM_DPICHANGED:
        return 0; /* keep physical pixel size across monitors */
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT:
        paint(p);
        return 0;
    case WM_LBUTTONDOWN:
        SetCapture(h);
        p->drag = true;
        GetCursorPos(&p->drag_pt);
        {
            RECT wr;
            GetWindowRect(h, &wr);
            p->win_pt.x = wr.left;
            p->win_pt.y = wr.top;
        }
        return 0;
    case WM_MOUSEMOVE:
        if (p->drag) {
            POINT c;
            GetCursorPos(&c);
            SetWindowPos(h, NULL, p->win_pt.x + c.x - p->drag_pt.x, p->win_pt.y + c.y - p->drag_pt.y, 0, 0,
                         SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        }
        return 0;
    case WM_LBUTTONUP:
        if (p->drag) {
            p->drag = false;
            ReleaseCapture();
        }
        return 0;
    case WM_CAPTURECHANGED:
        p->drag = false;
        return 0;
    case WM_LBUTTONDBLCLK:
        DestroyWindow(h);
        return 0;
    case WM_MOUSEWHEEL: {
        int d = GET_WHEEL_DELTA_WPARAM(wp);
        if (GET_KEYSTATE_WPARAM(wp) & MK_CONTROL) {
            set_alpha(p, p->alpha + (d > 0 ? 10 : -10));
        } else {
            POINT c = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
            float z = p->zoom * (d > 0 ? 1.1f : 1.f / 1.1f);
            if ((p->zoom < 1.f && z > 1.f) || (p->zoom > 1.f && z < 1.f) || fabsf(z - 1.f) < 0.02f)
                z = 1.f; /* always stop at 100% on the way through */
            set_zoom(p, z, c);
        }
        return 0;
    }
    case WM_KEYDOWN: {
        bool ctrl = GetKeyState(VK_CONTROL) < 0;
        if (wp == VK_ESCAPE)
            DestroyWindow(h);
        else if (ctrl && wp == 'C')
            pin_copy(p);
        else if (ctrl && wp == 'S')
            pin_save(p);
        return 0;
    }
    case WM_CONTEXTMENU: {
        POINT at = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
        if (at.x == -1 && at.y == -1) {
            RECT wr;
            GetWindowRect(h, &wr);
            at.x = wr.left;
            at.y = wr.top;
        }
        pin_menu(p, at);
        return 0;
    }
    case WM_TIMER:
        if (wp == TIMER_LABEL) {
            KillTimer(h, TIMER_LABEL);
            p->show_label = false;
            InvalidateRect(h, NULL, FALSE);
        }
        return 0;
    case WM_NCDESTROY: {
        SetWindowLongPtrW(h, GWLP_USERDATA, 0);
        Pin **pp = &P.list;
        while (*pp && *pp != p)
            pp = &(*pp)->next;
        if (*pp) { /* not listed yet = creation failed; pin_add frees it */
            *pp = p->next;
            P.count--;
            img_destroy(&p->img);
            mem_free(p);
        }
        return 0;
    }
    }
    return DefWindowProcW(h, m, wp, lp);
}

bool pin_init(HINSTANCE inst, HWND daemon)
{
    P.inst = inst;
    P.daemon = daemon;
    WNDCLASSW wc = {0};
    wc.style = CS_DBLCLKS;
    wc.lpfnWndProc = pin_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(NULL, IDC_SIZEALL);
    wc.lpszClassName = L"sniplite.pin";
    return RegisterClassW(&wc) != 0;
}

bool pin_add(Img *img, int x, int y, bool at_cursor)
{
    Pin *p = mem_alloc(sizeof *p);
    if (!p) {
        img_destroy(img);
        return false;
    }
    p->img = *img;
    memset(img, 0, sizeof *img);
    p->zoom = 1.f;
    p->alpha = 100;
    int w = p->img.w, h = p->img.h;
    if (at_cursor) {
        POINT c;
        GetCursorPos(&c);
        MONITORINFO mi = {sizeof mi};
        GetMonitorInfoW(MonitorFromPoint(c, MONITOR_DEFAULTTONEAREST), &mi);
        RECT wa = mi.rcWork;
        float fit = fminf(0.9f * (float)(wa.right - wa.left) / (float)w, 0.9f * (float)(wa.bottom - wa.top) / (float)h);
        if (fit < 1.f) {
            p->zoom = fit;
            w = MAXI(8, (int)lroundf((float)w * fit));
            h = MAXI(8, (int)lroundf((float)h * fit));
        }
        x = CLAMPI((int)c.x - w / 2, (int)wa.left, (int)wa.right - w);
        y = CLAMPI((int)c.y - h / 2, (int)wa.top, (int)wa.bottom - h);
    }
    /* WS_CAPTION (non-client area removed in WM_NCCALCSIZE) gives the native DWM shadow. */
    HWND hw = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, L"sniplite.pin", L"sniplite", WS_POPUP | WS_CAPTION, x, y, w,
                              h, NULL, NULL, P.inst, p);
    if (!hw) {
        img_destroy(&p->img);
        mem_free(p);
        return false;
    }
    p->next = P.list;
    P.list = p;
    P.count++;
    MARGINS mg = {0, 0, 0, 1};
    DwmExtendFrameIntoClientArea(hw, &mg);
    DWORD corner = 1; /* DWMWCP_DONOTROUND */
    DwmSetWindowAttribute(hw, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof corner);
    SetWindowPos(hw, HWND_TOPMOST, x, y, w, h, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    SetForegroundWindow(hw);
    return true;
}

bool pin_any_visible(void)
{
    for (Pin *p = P.list; p; p = p->next)
        if (IsWindowVisible(p->hwnd))
            return true;
    return false;
}

void pin_toggle_all(void)
{
    bool any_visible = false;
    for (Pin *p = P.list; p; p = p->next)
        if (IsWindowVisible(p->hwnd))
            any_visible = true;
    for (Pin *p = P.list; p; p = p->next)
        ShowWindow(p->hwnd, any_visible ? SW_HIDE : SW_SHOWNOACTIVATE);
}

void pin_close_all(void)
{
    while (P.list)
        DestroyWindow(P.list->hwnd);
}

int pin_count(void) { return P.count; }
