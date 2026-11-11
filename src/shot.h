/* Whole-desktop capture. DXGI desktop duplication when possible, GDI otherwise. */
#pragma once
#include "common.h"

#define SHOT_MAX_TILES 16

/* One monitor's pixels. Coordinates are relative to the virtual-screen origin. */
typedef struct {
    RECT rc;
    const uint8_t *bits; /* top-left pixel of rc */
    int pitch;           /* bytes per row */
    float scale;         /* UI scale (dpi / 96) of this monitor */
    void *tex;           /* mapped ID3D11Texture2D (DXGI tile) */
    void *ctx;           /* its ID3D11DeviceContext */
    Img gdi;             /* GDI tile */
} Tile;

typedef struct {
    int vx, vy, vw, vh; /* virtual screen, screen coordinates */
    Tile tile[SHOT_MAX_TILES];
    int ntile;
    bool gaps;          /* virtual screen not fully covered by monitors */
    int ndxgi;          /* tiles captured through DXGI */
    double grab_ms;
} Shot;

/* idle(ctx), if given, runs while the GPU produces the frame (must not pump messages). */
bool shot_take(Shot *sh, void (*idle)(void *), void *ctx);
void shot_free(Shot *sh);

/* For the overlay. show: a cloaked window to show at that rectangle (screen
 * coordinates), batched with the windows that make DWM present the frame.
 * frame(ctx, i, dev, tex), if given, is called with monitor i's frame (an
 * ID3D11Texture2D on device dev); the frames are then kept and DXGI tiles have
 * no bits until shot_map, which reads them back. Without frame, shot_map only
 * waits for copies already queued. */
typedef struct {
    HWND hwnd;
    int x, y, w, h;
    bool poke; /* uncloaked and transparent: its appearance alone makes DWM present a frame */
} ShotShow;
typedef void (*ShotFrameFn)(void *ctx, int tile, void *dev, void *tex);
bool shot_take_gpu(Shot *sh, const ShotShow *show, ShotFrameFn frame, void *ctx);
void shot_map(Shot *sh); /* afterwards every tile has bits, or none (black) */
bool shot_gpu(void **dev, void **ctx); /* the first GPU's device (presentation), if any */
void shot_on_ready(void (*cb)(void));   /* called when the GPU state was rebuilt or dropped */

static inline const uint32_t *tile_row(const Tile *t, int x, int y)
{
    return (const uint32_t *)(t->bits + (size_t)(y - t->rc.top) * (size_t)t->pitch) + (x - t->rc.left);
}
uint32_t shot_pixel(const Shot *sh, int x, int y);                 /* 0 outside monitors */
void shot_copy(const Shot *sh, RECT r, uint32_t *dst, int stride); /* r: client coords */
int shot_tile_at(const Shot *sh, int x, int y);                   /* nearest tile index */

/* Backend management (all on the daemon thread). */
void gpu_start(HWND notify);   /* build DXGI state on a worker thread -> WM_APP_GPU_READY */
void gpu_ready(void *state);   /* handle WM_APP_GPU_READY */
void gpu_stop(void);           /* release everything, use GDI only */
void gpu_display_changed(void);
bool gpu_enabled(void);
const WCHAR *shot_backend(void); /* "dxgi", "gdi" or "starting" */
