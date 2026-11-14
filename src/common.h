/* sniplite - lightweight screenshot tool. Shared declarations. */
#pragma once

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef COBJMACROS
#define COBJMACROS
#endif
#include <windows.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#define SNIPLITE_VERSION L"1.2.0"

#define DAEMON_CLASS L"sniplite.daemon"
#define DAEMON_MUTEX L"Local\\sniplite.daemon"

/* IPC over WM_COPYDATA. Request payload: cwd, then argv, separated by IPC_SEP. */
#define IPC_REQ   0x4C534E01u
#define IPC_REPLY 0x4C534E02u
#define IPC_BASE  0x1000 /* WM_COPYDATA result = IPC_BASE + exit code */
#define IPC_SEP   L'\x1F'

/* Exit codes shared by the CLI and the daemon. */
enum {
    EXIT_OK = 0,
    EXIT_FAIL = 1,
    EXIT_USAGE = 2,
    EXIT_NOT_RUNNING = 3,
    EXIT_NOTHING = 4,
    EXIT_HOTKEY = 5,
};

/* Private window messages of the daemon window. */
#define WM_APP_GPU_READY (WM_APP + 1) /* lParam = GpuState* built on a worker thread */

#define MINI(a, b) ((a) < (b) ? (a) : (b))
#define MAXI(a, b) ((a) > (b) ? (a) : (b))
#define CLAMPI(v, lo, hi) ((v) < (lo) ? (lo) : (v) > (hi) ? (hi) : (v))
#define COUNTOF(a) ((int)(sizeof(a) / sizeof((a)[0])))

/* ---- util.c ---------------------------------------------------------- */
void *mem_alloc(size_t n);            /* zero-filled, NULL on failure */
void *mem_grow(void *p, size_t n);    /* realloc, new tail zero-filled */
void mem_free(void *p);
WCHAR *wcs_dup(const WCHAR *s, int n); /* n < 0: up to terminator */
double now_ms(void);

static inline bool rect_empty(const RECT *r) { return r->right <= r->left || r->bottom <= r->top; }
static inline bool rect_eq(const RECT *a, const RECT *b) { return memcmp(a, b, sizeof *a) == 0; }
static inline bool rect_has(const RECT *r, int x, int y)
{
    return x >= r->left && x < r->right && y >= r->top && y < r->bottom;
}
RECT rect_isect(RECT a, RECT b);
RECT rect_union(RECT a, RECT b);      /* empty inputs are ignored */
RECT rect_inflate(RECT r, int d);
RECT rect_corners(POINT a, POINT b);  /* two inclusive corner pixels -> half-open rect */

/* Growable UTF-16 string. */
typedef struct {
    WCHAR *p;
    int n, cap;
} Str;
void str_add(Str *s, const WCHAR *t);
void str_addn(Str *s, const WCHAR *t, int n);
void str_addf(Str *s, const WCHAR *fmt, ...); /* wvsprintfW: no floats, <= 1024 chars */
void str_add_ms(Str *s, double ms);           /* "12.3" */
void str_add_json(Str *s, const WCHAR *t);    /* quoted JSON string, non-ASCII as \uXXXX */
void str_add_quoted(Str *s, const WCHAR *a);  /* one command-line argument, MSVC quoting */
void str_free(Str *s);

/* ---- ipc.c (client side, shared by sniplite.exe and sniplite.com) --------------- */
HWND ipc_find(void);
HWND ipc_find_dialog(const WCHAR *mark); /* the open dialog carrying that mark (settings.h), or NULL */
/* Run a command in the daemon. Returns its exit code, or -1 if it could not be reached. */
int ipc_call(HWND daemon, int argc, WCHAR **argv, Str *reply);

/* Split a command line with the MSVC rules (no shell32 needed). */
WCHAR **cmdline_split(const WCHAR *cmd, int *argc);
bool arg_eq(const WCHAR *a, const WCHAR *b); /* case-insensitive */

/* DPI scale (1.0 = 96 dpi) of the monitor containing a screen point. */
float dpi_scale_at(POINT pt);
float dpi_scale_of(HMONITOR mon);

/* ---- Img: top-down 32bpp DIB section selected into its own memory DC ---- */
typedef struct {
    HBITMAP bmp;
    HDC dc;
    HGDIOBJ old;
    uint32_t *px; /* stride == w */
    int w, h;
} Img;
bool img_create(Img *im, int w, int h);
void img_destroy(Img *im);
