/* rec.c: the GIF recorder: a region of the screen is read a few times a second
 * and written to a GIF file.
 *
 * The shape of scroll.c: the capture closes and its selection becomes the
 * region; a small panel beside it shows the time, the number of frames and the
 * size of the file; Enter stops the recording and keeps the file, Esc stops it
 * and throws it away.
 *
 * The file is written as the recording goes, so that the memory is one frame
 * and the file on disk is a valid GIF up to the last frame that was written.
 * The frame that did not change is written as one transparent pixel, so that
 * the delays stay exact.
 *
 * The window helpers of scroll.c are written again here, small and plainly, so
 * that the file the author reads is only the new code. */
#include "common.h"
#include "config.h"
#include "draw.h"
#include "gif.h"
#include "image.h"
#include "lang.h"
#include "ocr.h"
#include "overlay.h"
#include "shot.h"
#include "ov_layout.inc"
#include <dwmapi.h>
#include <math.h>
#include <shlobj.h>

#define REC_CLASS L"sniplite.rec"
#define MAX_FILE (256u << 20) /* the size of the file: the recording stops there */
#define MAX_PX 1280          /* a region that is bigger is scaled down to fit this */
#define MAX_PY 720
#define TIMER_GRAB 1
#define HK_CANCEL 1
#define HK_STOP 2

extern uint8_t O[];            /* the capture's state (ov_layout.inc) */
extern const uint32_t *ui_pal; /* the bars' colors, by P_* (ov_base.S, main.c) */

static struct {
    bool on;
    RECT rc;    /* the region on the screen */
    int w, h;   /* its size */
    int sw, sh; /* the size of the picture: the region, scaled down when it is big */
    int vw, vh; /* the screen, to know when it changes under the recording */
    float s;    /* the scale of the screen */
    HWND panel;
    Img shot;   /* the region, as it is read */
    Img small;  /* the region, scaled down */
    Img bar;    /* the picture of the panel */
    Gif gif;
    HANDLE file;
    WCHAR path[MAX_PATH + 80];
    DWORD size; /* the bytes written */
    double start; /* when the recording began */
    int frames;
    int fps;
    int hover, down; /* the button of the panel under the mouse, pressed; -1 none */
    bool full;       /* the file is as big as it may be */
    bool first;      /* the first frame is read after the capture is off the screen */
} R;

static void rec_end(bool save);
static LRESULT CALLBACK rec_proc(HWND h, UINT m, WPARAM wp, LPARAM lp);

static int px(float v) { return (int)lroundf(v * R.s); }

/* ---- the window ---- */

static HWND make(DWORD ex, int x, int y, int w, int h)
{
    HWND wnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | ex, REC_CLASS, L"sniplite", WS_POPUP, x, y, w, h,
                               NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (wnd)
        SetWindowDisplayAffinity(wnd, 0x11); /* WDA_EXCLUDEFROMCAPTURE: never part of what is read */
    return wnd;
}

/* The keyboard belongs to the program in front, so Esc and Enter come as hotkeys. */
static void hotkeys(bool on)
{
    if (on) {
        RegisterHotKey(R.panel, HK_CANCEL, 0, VK_ESCAPE);
        RegisterHotKey(R.panel, HK_STOP, 0, VK_RETURN);
    } else {
        UnregisterHotKey(R.panel, HK_CANCEL);
        UnregisterHotKey(R.panel, HK_STOP);
    }
}

/* the button of the panel: at its right */
static RECT panel_button(void)
{
    int b = px(30), x = R.bar.w - px(4) - b, y = (R.bar.h - b) / 2;
    RECT r = {x, y, x + b, y + b};
    return r;
}

/* the size of the file, in the unit that fits it */
static void size_text(WCHAR *out, int cap, DWORD n)
{
    if (n < 1024 * 1024)
        wsprintfW(out, L"%d KB", (int)(n / 1024));
    else
        wsprintfW(out, L"%d.%d MB", (int)(n / (1024 * 1024)), (int)(n % (1024 * 1024) / (1024 * 1024 / 10)));
}

/* the panel, into its picture: what it says and the button that stops it */
static void panel_draw(void)
{
    RECT rc = {0, 0, R.bar.w, R.bar.h};
    Surf s = surf_img(&R.bar, 0, 0);
    d_fill(&s, rc, ui_pal[P_BG]);
    d_frame(&s, rc, 1, ui_pal[P_EDGE]);
    RECT b = panel_button();
    if (R.hover >= 0 || R.down >= 0)
        d_fill(&s, rect_inflate(b, -px(2)), ui_pal[R.down >= 0 ? P_DOWN : P_HOVER]);
    d_icon(&s, IC_OK, (float)(b.left + px(5)), (float)(b.top + px(5)), (float)px(20), ui_pal[P_ACCENT]);

    WCHAR size[32], t[160];
    size_text(size, COUNTOF(size), R.size);
    int secs = (int)((now_ms() - R.start) / 1000.0);
    if (R.full)
        lstrcpynW(t, T(REC_FULL), COUNTOF(t));
    else
        wsprintfW(t, L"%s %d:%02d    %s %d    %s %s", T(REC_TIME), secs / 60, secs % 60, T(REC_FRAMES), R.frames, T(REC_SIZE),
                  size);
    HFONT f = CreateFontW(-px(13), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                          CLEARTYPE_QUALITY, DEFAULT_PITCH, T(FONT));
    HGDIOBJ old = SelectObject(R.bar.dc, f);
    SetBkMode(R.bar.dc, TRANSPARENT);
    uint32_t note = R.full ? ui_pal[P_WARN] : ui_pal[P_NOTE];
    SetTextColor(R.bar.dc, RGB(note >> 16, note >> 8 & 255, note & 255));
    RECT tr = {px(10), 0, b.left - px(6), rc.bottom};
    DrawTextW(R.bar.dc, t, -1, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
    SelectObject(R.bar.dc, old);
    DeleteObject(f);
}

static void panel_paint(HWND h)
{
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(h, &ps);
    panel_draw();
    BitBlt(dc, 0, 0, R.bar.w, R.bar.h, R.bar.dc, 0, 0, SRCCOPY);
    EndPaint(h, &ps);
}

/* the button of the panel under the mouse */
static int panel_hit(LPARAM lp)
{
    POINT p = {(short)LOWORD(lp), (short)HIWORD(lp)};
    RECT b = panel_button();
    return PtInRect(&b, p) ? 0 : -1;
}

/* ---- the picture ---- */

/* the region, read from the screen */
static void grab(void)
{
    HDC scr = GetDC(NULL);
    BitBlt(R.shot.dc, 0, 0, R.w, R.h, scr, R.rc.left, R.rc.top, SRCCOPY | CAPTUREBLT);
    ReleaseDC(NULL, scr);
}

/* The region, scaled down to the size of the picture: every pixel of the
 * picture is the average of the pixels it stands for. The nearest of them
 * would drop some rows and keep others when the ratio is not a whole number,
 * and a line of text that lands on a dropped row vanishes for that frame and
 * comes back for the next: the recording shimmers.
 *
 * The check of this function is in tools/gifref/check.py: it takes the code
 * from here, so that the check is of the code that runs. */
static void scale_pixels(const uint32_t *src, int w, int h, uint32_t *dst, int sw, int sh)
{
    for (int y = 0; y < sh; y++) {
        int y0 = y * h / sh, y1 = (y + 1) * h / sh;
        for (int x = 0; x < sw; x++) {
            int x0 = x * w / sw, x1 = (x + 1) * w / sw;
            unsigned r = 0, g = 0, b = 0, n = 0;
            for (int yy = y0; yy < y1; yy++) {
                const uint32_t *row = src + (size_t)yy * w;
                for (int xx = x0; xx < x1; xx++) {
                    uint32_t v = row[xx];
                    r += v >> 16 & 255, g += v >> 8 & 255, b += v & 255, n++;
                }
            }
            if (n)
                dst[(size_t)y * sw + x] = (r / n << 16) | (g / n << 8) | b / n;
        }
    }
}

/* ---- the recording ---- */

static void tick(void)
{
    if (ov_active()) { /* a capture began: this one is over */
        rec_end(false);
        return;
    }
    if (GetSystemMetrics(SM_CXVIRTUALSCREEN) != R.vw || GetSystemMetrics(SM_CYVIRTUALSCREEN) != R.vh) {
        rec_end(false); /* the screen changed under the recording */
        return;
    }
    grab();
    if (R.sw != R.w || R.sh != R.h)
        scale_pixels(R.shot.px, R.w, R.h, R.small.px, R.sw, R.sh);
    const uint32_t *pixels = R.sw == R.w ? R.shot.px : R.small.px;
    /* the delay of this frame: from its number, so that the total comes out
     * right however many frames there are */
    int delay = (int)((R.frames + 1) * 100.0 / R.fps + 0.5) - (int)(R.frames * 100.0 / R.fps + 0.5);
    if (!gif_frame(&R.gif, pixels, R.sw, delay)) {
        rec_end(false);
        return;
    }
    DWORD written = 0;
    if (!WriteFile(R.file, R.gif.buf, (DWORD)R.gif.n, &written, NULL) || written != (DWORD)R.gif.n) {
        rec_end(false);
        return;
    }
    R.size += written;
    R.frames++;
    if (R.first) { /* the capture is off the screen now: the frames come every tick */
        R.first = false;
        SetTimer(R.panel, TIMER_GRAB, 1000 / R.fps, NULL);
    }
    if (R.size > MAX_FILE) { /* the file is as big as it may be: no more frames */
        R.full = true;
        KillTimer(R.panel, TIMER_GRAB);
        InvalidateRect(R.panel, NULL, FALSE);
        return;
    }
    InvalidateRect(R.panel, NULL, FALSE);
}

/* The recording is over. The file is kept, or it is thrown away: what is left
 * of it is deleted, so that nothing is left behind. */
static void rec_end(bool save)
{
    if (!R.on)
        return;
    R.on = false;
    if (R.panel) {
        KillTimer(R.panel, TIMER_GRAB);
        hotkeys(false);
    }
    if (save && R.file) {
        gif_end(&R.gif);
        DWORD written = 0;
        WriteFile(R.file, R.gif.buf, (DWORD)R.gif.n, &written, NULL);
    }
    if (R.file)
        CloseHandle(R.file);
    if (!save && R.path[0])
        DeleteFileW(R.path);
    if (R.panel)
        DestroyWindow(R.panel);
    WCHAR path[MAX_PATH + 80];
    lstrcpynW(path, R.path, COUNTOF(path));
    POINT at = {R.rc.left, R.rc.top};
    img_destroy(&R.shot);
    img_destroy(&R.small);
    img_destroy(&R.bar);
    gif_free(&R.gif);
    memset(&R, 0, sizeof R);
    if (save && path[0])
        notice_corner(T(QUICK_SAVED), path, at, 2000);
}

/* The folder of the settings, or the desktop when there is none */
static void save_dir(const Config *c, WCHAR *out, int cap)
{
    lstrcpynW(out, c->save_dir, cap);
    if (out[0])
        return;
    typedef HRESULT(WINAPI *PFN_SHGetFolderPathW)(HWND, int, HANDLE, DWORD, LPWSTR);
    HMODULE sh = LoadLibraryW(L"shell32.dll");
    PFN_SHGetFolderPathW get = sh ? (PFN_SHGetFolderPathW)(void *)GetProcAddress(sh, "SHGetFolderPathW") : NULL;
    if (get && SUCCEEDED(get(NULL, CSIDL_DESKTOPDIRECTORY, NULL, 0, out)))
        return;
    out[0] = 0;
}

/* The file: the name the other saves use, in the folder the settings name.
 * The name is made here, so that two recordings in the same second do not
 * write over each other. */
static bool open_file(const Config *c)
{
    WCHAR dir[MAX_PATH];
    save_dir(c, dir, MAX_PATH);
    if (!dir[0])
        return false;
    SYSTEMTIME now;
    GetLocalTime(&now);
    WCHAR name[NAME_CAP];
    name_format(c->name, &now, name);
    int n = wsprintfW(R.path, L"%s\\%s", dir, name); /* the end of the name */
    lstrcpyW(R.path + n, L".gif");
    for (int k = 2; k < 100; k++) { /* CREATE_NEW: two recordings never take the same name */
        R.file = CreateFileW(R.path, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
        if (R.file != INVALID_HANDLE_VALUE || GetLastError() != ERROR_FILE_EXISTS)
            return R.file != INVALID_HANDLE_VALUE;
        wsprintfW(R.path + n, L"_%d.gif", k);
    }
    R.file = NULL;
    return false;
}

/* The capture is gone and its selection is the region that is recorded. */
void rec_begin(void)
{
    rec_end(false);
    const Shot *sh = (const Shot *)(O + OV_SHOT);
    const RECT *sel = (const RECT *)(O + OV_SEL);
    RECT rc = {sh->vx + sel->left, sh->vy + sel->top, sh->vx + sel->right, sh->vy + sel->bottom};
    int w = rc.right - rc.left, h = rc.bottom - rc.top;
    if (w < 32 || h < 32)
        return;
    POINT mid = {(rc.left + rc.right) / 2, (rc.top + rc.bottom) / 2};
    R.rc = rc, R.s = dpi_scale_at(mid);
    R.hover = R.down = -1;
    R.w = w, R.h = h;
    /* a region that is bigger than the picture is scaled down to fit it */
    R.sw = w, R.sh = h;
    if (w > MAX_PX || h > MAX_PY) {
        float f = w * (float)MAX_PY > (float)MAX_PX * h ? (float)MAX_PX / w : (float)MAX_PY / h;
        R.sw = MAXI(1, (int)lroundf(w * f));
        R.sh = MAXI(1, (int)lroundf(h * f));
    }
    R.first = true;
    R.vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    R.vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);

    Config c;
    config_load(&c);
    R.fps = kFps[c.fps];
    R.on = true;
    if (!gif_begin(&R.gif, R.sw, R.sh, kColours[c.colours]) || !img_create(&R.shot, w, h)) {
        rec_end(false);
        return;
    }
    if ((R.sw != w || R.sh != h) && !img_create(&R.small, R.sw, R.sh)) {
        rec_end(false);
        return;
    }
    if (!open_file(&c)) {
        rec_end(false);
        return;
    }
    R.start = now_ms();

    WNDCLASSW wc = {0};
    wc.lpfnWndProc = rec_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.lpszClassName = REC_CLASS;
    RegisterClassW(&wc);

    /* the panel: beside the region, else in the corner of the monitor */
    MONITORINFO mi = {sizeof mi};
    GetMonitorInfoW(MonitorFromRect(&rc, MONITOR_DEFAULTTONEAREST), &mi);
    const RECT *mon = &mi.rcMonitor;
    int pw = px(300), ph = px(34), gap = px(6);
    int bx = CLAMPI(rc.left, mon->left, MAXI(mon->left, mon->right - pw));
    int by = rc.bottom + gap;
    if (by + ph > mon->bottom)
        by = rc.top - gap - ph >= mon->top ? rc.top - gap - ph : mon->bottom - ph;
    R.panel = make(0, bx, by, pw, ph);
    if (!R.panel || !img_create(&R.bar, pw, ph)) {
        rec_end(false);
        return;
    }
    int round = 2; /* DWMWCP_ROUND, Windows 11; ignored before */
    DwmSetWindowAttribute(R.panel, 33, &round, sizeof round);
    hotkeys(true);
    SetTimer(R.panel, TIMER_GRAB, 150, NULL); /* the first frame: once the capture is off the screen */
    ShowWindow(R.panel, SW_SHOWNOACTIVATE);
}

void rec_cancel(void) { rec_end(false); }

static LRESULT CALLBACK rec_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    if (m == WM_ERASEBKGND)
        return 1;
    if (m == WM_MOUSEACTIVATE)
        return MA_NOACTIVATE; /* the keyboard stays with the program in front */
    if (!R.on || h != R.panel)
        return DefWindowProcW(h, m, wp, lp);
    switch (m) {
    case WM_PAINT:
        panel_paint(h);
        return 0;
    case WM_TIMER:
        tick();
        return 0;
    case WM_HOTKEY:
        if (wp == HK_STOP)
            rec_end(true);
        else if (wp == HK_CANCEL)
            rec_end(false);
        return 0;
    case WM_MOUSEMOVE: {
        int at = panel_hit(lp);
        if (at != R.hover) {
            R.hover = at;
            InvalidateRect(h, NULL, FALSE);
        }
        TRACKMOUSEEVENT tme = {sizeof tme, TME_LEAVE, h, 0};
        TrackMouseEvent(&tme);
        return 0;
    }
    case WM_MOUSELEAVE:
        R.hover = R.down = -1;
        InvalidateRect(h, NULL, FALSE);
        return 0;
    case WM_LBUTTONDOWN:
        R.down = panel_hit(lp);
        InvalidateRect(h, NULL, FALSE);
        return 0;
    case WM_LBUTTONUP: {
        int at = panel_hit(lp), was = R.down;
        R.down = -1;
        InvalidateRect(h, NULL, FALSE);
        if (at >= 0 && at == was)
            rec_end(true);
        return 0;
    }
    }
    return DefWindowProcW(h, m, wp, lp);
}
