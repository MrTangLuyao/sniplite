/* Recording: one monitor's desktop through DXGI duplication, converted to NV12
 * and written by Media Foundation's Sink Writer as H.264 in an MP4 file.
 *
 * Everything is loaded at run time: the background program must not carry MF,
 * DXGI or D3D11 in its import table, and only the short-lived --record process
 * needs them. The interface calls are the C macros of the Windows headers. */
#include "common.h"
#include "rec.h"
#include "lang.h"
#include <d3d11.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <windowsx.h>

#define REC_FPS 30
#define REC_MF_VERSION 0x00020070
#define REC_ENC_H264 0x34363248u /* 'H264' */
#define REC_ENC_NV12 0x3231564Eu /* 'NV12' */

static const GUID k_iid_factory1 = {0x770aae78, 0xf26f, 0x4dba,
                                    {0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87}};
static const GUID k_iid_output1 = {0x00cddea8, 0x939b, 0x4b83,
                                   {0xa3, 0x40, 0xa6, 0x85, 0x22, 0x66, 0x66, 0xcc}};
static const GUID k_iid_texture2d = {0x6f15aaf2, 0xd208, 0x4e89,
                                     {0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c}};

static const GUID k_mt_major = {0x48eba18e, 0xf8c9, 0x4687,
                                {0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f}};
static const GUID k_mt_subtype = {0xf7e34c9a, 0x42e8, 0x4714,
                                  {0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5}};
static const GUID k_mt_bitrate = {0x20332624, 0xfb0d, 0x4d9e,
                                  {0xbd, 0x0d, 0xcb, 0xf6, 0x78, 0x6c, 0x10, 0x2e}};
static const GUID k_mt_interlace = {0xe2724bb8, 0xe676, 0x4806,
                                    {0xb4, 0xb2, 0xa8, 0xd6, 0xef, 0xb4, 0x4c, 0xcd}};
static const GUID k_mt_frame_size = {0x1652c33d, 0xd6b2, 0x4012,
                                     {0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d}};
static const GUID k_mt_frame_rate = {0xc459a2e8, 0x3d2c, 0x4e44,
                                     {0xb1, 0x32, 0xfe, 0xe5, 0x15, 0x6c, 0x7b, 0xb0}};
static const GUID k_mt_par = {0xc6376a1e, 0x8d0a, 0x4027,
                              {0xbe, 0x45, 0x6d, 0x9a, 0x0a, 0xd3, 0x9b, 0xb6}};
static const GUID k_mt_stride = {0x644b4e48, 0x1e02, 0x4516,
                                 {0xb0, 0xeb, 0xc0, 0x1c, 0xa9, 0xd4, 0x9a, 0xc6}};
static const GUID k_mt_indep = {0xc9173739, 0x5e56, 0x461c,
                                {0xb7, 0x13, 0x46, 0xfb, 0x99, 0x5c, 0xb9, 0x5f}};
static const GUID k_mt_fixed = {0xb8ebefaf, 0xb718, 0x4e04,
                                {0xb0, 0xa9, 0x11, 0x67, 0x75, 0xe3, 0x32, 0x1b}};
static const GUID k_mt_video = {0x73646976, 0x0000, 0x0010,
                                {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const GUID k_fmt_h264 = {0x34363248, 0x0000, 0x0010,
                                {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const GUID k_fmt_nv12 = {0x3231564e, 0x0000, 0x0010,
                                {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};

typedef HRESULT(WINAPI *PFN_CreateDXGIFactory1)(REFIID, void **);
typedef HRESULT(WINAPI *PFN_D3D11CreateDevice)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT,
                                               const D3D_FEATURE_LEVEL *, UINT, UINT, ID3D11Device **,
                                               D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
typedef HRESULT(WINAPI *PFN_MFStartup)(UINT32, UINT32);
typedef HRESULT(WINAPI *PFN_MFShutdown)(void);
typedef HRESULT(WINAPI *PFN_MFCreateAttributes)(IMFAttributes **, UINT32);
typedef HRESULT(WINAPI *PFN_MFCreateMediaType)(IMFMediaType **);
typedef HRESULT(WINAPI *PFN_MFCreateMemoryBuffer)(DWORD, IMFMediaBuffer **);
typedef HRESULT(WINAPI *PFN_MFCreateSample)(IMFSample **);
typedef HRESULT(WINAPI *PFN_MFCreateSinkWriterFromURL)(const WCHAR *, IMFByteStream *, IMFAttributes *,
                                                       IMFSinkWriter **);
typedef HRESULT(WINAPI *PFN_CoInitializeEx)(void *, DWORD);
typedef void(WINAPI *PFN_CoUninitialize)(void);

/* The mouse pointer is not part of a duplicated desktop frame: it is read here and
 * drawn into the staging texture before the pixels are converted. */
typedef struct {
    HCURSOR handle;
    int w, h, hot_x, hot_y; /* the size and hotspot in the pixels of the screen */
    uint32_t *px;           /* 0x00RRGGBB, top-down */
    uint8_t *alpha;
    bool visible;
    int x, y; /* top-left in the monitor, after the hotspot */
} RecCursor;

typedef struct {
    HMODULE dxgi, d3d11, mfplat, mfreadwrite, ole32;
    PFN_MFShutdown mf_shutdown;
    PFN_CoUninitialize co_uninit;
    PFN_CreateDXGIFactory1 create_factory;
    PFN_D3D11CreateDevice create_device;
    PFN_MFCreateMediaType create_media_type;
    PFN_MFCreateMemoryBuffer create_memory_buffer;
    PFN_MFCreateSample create_sample;
    PFN_MFCreateSinkWriterFromURL create_writer;
    bool com_owned, mf_started;

    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    IDXGIOutputDuplication *dupl;
    ID3D11Texture2D *staging;
    int tex_w, tex_h; /* the monitor, in pixels */
    int mon_x, mon_y; /* its top-left on the virtual desktop */
    float scale;      /* its DPI */
    int src_x, src_y; /* crop inside it */
    int out_w, out_h; /* video size, even */
    uint8_t *nv12;

    IMFSinkWriter *writer;
    DWORD stream;
    IMFSample *sample;
    IMFMediaBuffer *buffer;
    RecCursor cur;
} Rec;

/* ---- diagnostics ---------------------------------------------------------------- */

static void rec_log(const WCHAR *stage, HRESULT hr)
{
    WCHAR path[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"SNIPLITE_RECORD_LOG", path, COUNTOF(path));
    if (!n || n >= COUNTOF(path))
        return;
    HANDLE f = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ, NULL, OPEN_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE)
        return;
    WCHAR buf[256];
    int len = wsprintfW(buf, L"%s hr=0x%08X\r\n", stage, (unsigned)hr);
    DWORD written;
    WriteFile(f, buf, (DWORD)len * sizeof(WCHAR), &written, NULL);
    CloseHandle(f);
}

static int parse_int(const WCHAR *s)
{
    int sign = 1, v = 0;
    if (*s == L'-') {
        sign = -1;
        s++;
    }
    while (*s >= L'0' && *s <= L'9') {
        v = v * 10 + (*s - L'0');
        s++;
    }
    return v * sign;
}

/* ---- pixels --------------------------------------------------------------------- */

static inline uint8_t rec_y(uint32_t c)
{
    int r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
    int v = ((47 * r + 157 * g + 16 * b + 128) >> 8) + 16;
    return (uint8_t)CLAMPI(v, 0, 255);
}

static void bgra_to_nv12(Rec *r, const uint8_t *src, int pitch)
{
    const int w = r->out_w, h = r->out_h;
    uint8_t *y = r->nv12, *uv = r->nv12 + (size_t)w * (size_t)h;
    for (int j = 0; j < h; j += 2) {
        const uint32_t *p0 = (const uint32_t *)(src + (size_t)(r->src_y + j) * (size_t)pitch) + r->src_x;
        const uint32_t *p1 = (const uint32_t *)(src + (size_t)(r->src_y + j + 1) * (size_t)pitch) + r->src_x;
        uint8_t *y0 = y + (size_t)j * (size_t)w;
        uint8_t *y1 = y0 + w;
        uint8_t *u = uv + (size_t)(j / 2) * (size_t)w;
        for (int i = 0; i < w; i += 2) {
            const uint32_t c00 = p0[i], c01 = p0[i + 1], c10 = p1[i], c11 = p1[i + 1];
            y0[i] = rec_y(c00);
            y0[i + 1] = rec_y(c01);
            y1[i] = rec_y(c10);
            y1[i + 1] = rec_y(c11);
            int r = (((c00 >> 16) & 255) + ((c01 >> 16) & 255) + ((c10 >> 16) & 255) + ((c11 >> 16) & 255) + 2) >> 2;
            int g = (((c00 >> 8) & 255) + ((c01 >> 8) & 255) + ((c10 >> 8) & 255) + ((c11 >> 8) & 255) + 2) >> 2;
            int b = ((c00 & 255) + (c01 & 255) + (c10 & 255) + (c11 & 255) + 2) >> 2;
            u[i] = (uint8_t)CLAMPI(((-26 * r - 87 * g + 112 * b + 128) >> 8) + 128, 0, 255);
            u[i + 1] = (uint8_t)CLAMPI(((112 * r - 102 * g - 10 * b + 128) >> 8) + 128, 0, 255);
        }
    }
}

/* ---- the pointer ----------------------------------------------------------------- */

static void rec_cursor_free(RecCursor *c)
{
    mem_free(c->px);
    mem_free(c->alpha);
    c->px = NULL;
    c->alpha = NULL;
    c->w = c->h = 0;
    c->visible = false;
}

static void rec_cursor_load(Rec *r, HCURSOR hcur)
{
    RecCursor *c = &r->cur;
    rec_cursor_free(c);
    c->handle = hcur;
    ICONINFO ii;
    if (!GetIconInfo(hcur, &ii))
        return;
    BITMAP bm = {0};
    int w = 0, h = 0;
    bool ok = false;
    if (ii.hbmColor && GetObjectW(ii.hbmColor, sizeof bm, &bm)) {
        w = bm.bmWidth;
        h = bm.bmHeight;
        if (w > 0 && h > 0 && w <= 256 && h <= 256) {
            uint32_t *px = mem_alloc((size_t)w * (size_t)h * 4);
            uint8_t *a = mem_alloc((size_t)w * (size_t)h);
            if (px && a) {
                BITMAPINFO bi = {0};
                bi.bmiHeader.biSize = sizeof bi.bmiHeader;
                bi.bmiHeader.biWidth = w;
                bi.bmiHeader.biHeight = -h; /* top-down */
                bi.bmiHeader.biPlanes = 1;
                bi.bmiHeader.biBitCount = 32;
                bi.bmiHeader.biCompression = BI_RGB;
                HDC dc = GetDC(NULL);
                int got = dc && GetDIBits(dc, ii.hbmColor, 0, h, px, &bi, DIB_RGB_COLORS);
                if (dc)
                    ReleaseDC(NULL, dc);
                if (got) {
                    bool any = false;
                    for (int i = 0; i < w * h; i++) {
                        a[i] = (uint8_t)(px[i] >> 24);
                        any |= a[i] != 0;
                    }
                    if (!any && ii.hbmMask) { /* an old-style cursor: the mask says what is opaque */
                        BITMAP mb = {0};
                        if (GetObjectW(ii.hbmMask, sizeof mb, &mb) && mb.bmWidth == w && mb.bmHeight >= h * 2) {
                            int stride = ((w + 31) / 32) * 4;
                            uint8_t *bits = mem_alloc((size_t)stride * (size_t)h * 2);
                            if (bits) {
                                BITMAPINFO mi = {0};
                                mi.bmiHeader.biSize = sizeof mi.bmiHeader;
                                mi.bmiHeader.biWidth = w;
                                mi.bmiHeader.biHeight = -2 * h;
                                mi.bmiHeader.biPlanes = 1;
                                mi.bmiHeader.biBitCount = 1;
                                mi.bmiHeader.biCompression = BI_RGB;
                                HDC dc2 = GetDC(NULL);
                                int got2 = dc2 && GetDIBits(dc2, ii.hbmMask, 0, 2 * h, bits, &mi, DIB_RGB_COLORS);
                                if (dc2)
                                    ReleaseDC(NULL, dc2);
                                if (got2)
                                    for (int j = 0; j < h; j++)
                                        for (int i = 0; i < w; i++) {
                                            int byte = i >> 3, bit = 7 - (i & 7);
                                            int and_bit = (bits[j * stride + byte] >> bit) & 1;
                                            int xor_bit = (bits[(h + j) * stride + byte] >> bit) & 1;
                                            int k = j * w + i;
                                            if (and_bit) {
                                                a[k] = 0;
                                            } else {
                                                px[k] = xor_bit ? 0x00FFFFFF : 0;
                                                a[k] = 255;
                                            }
                                        }
                                mem_free(bits);
                            }
                        }
                    }
                    c->px = px;
                    c->alpha = a;
                    c->w = w;
                    c->h = h;
                    ok = true;
                }
            }
            if (!ok) {
                mem_free(px);
                mem_free(a);
            }
        }
    }
    if (ii.hbmColor)
        DeleteObject(ii.hbmColor);
    if (ii.hbmMask)
        DeleteObject(ii.hbmMask);
    if (!ok)
        return;

    int ow = w, oh = h;
    UINT dpi = (UINT)(96.f * r->scale + 0.5f);
    int tw = GetSystemMetricsForDpi(SM_CXCURSOR, dpi);
    if (tw < 8 || tw > 256)
        tw = ow;
    int th = oh * tw / ow;
    if (th < 1)
        th = 1;
    if (tw != ow || th != oh) { /* the cursor is drawn at the size Windows shows it */
        uint32_t *np = mem_alloc((size_t)tw * (size_t)th * 4);
        uint8_t *na = mem_alloc((size_t)tw * (size_t)th);
        if (np && na) {
            for (int j = 0; j < th; j++)
                for (int i = 0; i < tw; i++) {
                    int sx = i * ow / tw, sy = j * oh / th;
                    np[j * tw + i] = c->px[sy * ow + sx];
                    na[j * tw + i] = c->alpha[sy * ow + sx];
                }
            mem_free(c->px);
            mem_free(c->alpha);
            c->px = np;
            c->alpha = na;
            c->w = tw;
            c->h = th;
        } else {
            mem_free(np);
            mem_free(na);
        }
    }
    c->hot_x = (int)((int64_t)ii.xHotspot * c->w / ow);
    c->hot_y = (int)((int64_t)ii.yHotspot * c->h / oh);
}

static void rec_cursor_update(Rec *r)
{
    RecCursor *c = &r->cur;
    CURSORINFO ci = {sizeof ci};
    if (!GetCursorInfo(&ci) || !(ci.flags & CURSOR_SHOWING)) {
        c->visible = false;
        return;
    }
    if (ci.hCursor != c->handle)
        rec_cursor_load(r, ci.hCursor);
    c->visible = c->px != NULL;
    c->x = (int)ci.ptScreenPos.x - r->mon_x - c->hot_x;
    c->y = (int)ci.ptScreenPos.y - r->mon_y - c->hot_y;
}

static void rec_cursor_draw(Rec *r, uint8_t *base, int pitch)
{
    RecCursor *c = &r->cur;
    if (!c->visible || !c->px)
        return;
    for (int j = 0; j < c->h; j++) {
        int y = c->y + j;
        if (y < 0 || y >= r->tex_h)
            continue;
        uint32_t *row = (uint32_t *)(base + (size_t)y * (size_t)pitch);
        for (int i = 0; i < c->w; i++) {
            int x = c->x + i;
            if (x < 0 || x >= r->tex_w)
                continue;
            uint8_t a = c->alpha[j * c->w + i];
            if (!a)
                continue;
            uint32_t fg = c->px[j * c->w + i], bg = row[x];
            if (a == 255) {
                row[x] = fg & 0xFFFFFF;
            } else {
                int nb = 255 - a;
                int rr = (((fg >> 16) & 255) * a + ((bg >> 16) & 255) * nb + 127) / 255;
                int gg = (((fg >> 8) & 255) * a + ((bg >> 8) & 255) * nb + 127) / 255;
                int bb = ((fg & 255) * a + (bg & 255) * nb + 127) / 255;
                row[x] = ((uint32_t)rr << 16) | ((uint32_t)gg << 8) | (uint32_t)bb;
            }
        }
    }
}

/* ---- DXGI ----------------------------------------------------------------------- */

static bool rect_inside(const RECT *r, int x, int y)
{
    return x >= r->left && x < r->right && y >= r->top && y < r->bottom;
}

static HRESULT rec_open_output(Rec *r, HMONITOR mon, RECT region)
{
    IDXGIFactory1 *factory = NULL;
    HRESULT hr = r->create_factory(&k_iid_factory1, (void **)&factory);
    if (FAILED(hr))
        return hr;

    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    bool found = false;
    for (UINT ai = 0; !found; ai++) {
        IDXGIAdapter1 *ad = NULL;
        hr = IDXGIFactory1_EnumAdapters1(factory, ai, &ad);
        if (hr == DXGI_ERROR_NOT_FOUND)
            break;
        if (FAILED(hr))
            break;
        ID3D11Device *dev = NULL;
        ID3D11DeviceContext *ctx = NULL;
        hr = r->create_device((IDXGIAdapter *)ad, D3D_DRIVER_TYPE_UNKNOWN, NULL,
                              D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 3, D3D11_SDK_VERSION, &dev, NULL,
                              &ctx);
        if (FAILED(hr)) {
            IDXGIAdapter1_Release(ad);
            continue;
        }
        for (UINT oi = 0; !found; oi++) {
            IDXGIOutput *out = NULL;
            hr = IDXGIAdapter1_EnumOutputs(ad, oi, &out);
            if (hr == DXGI_ERROR_NOT_FOUND)
                break;
            if (FAILED(hr))
                break;
            DXGI_OUTPUT_DESC d;
            if (SUCCEEDED(IDXGIOutput_GetDesc(out, &d)) && d.AttachedToDesktop &&
                (d.Monitor == mon || rect_inside(&d.DesktopCoordinates, region.left, region.top))) {
                IDXGIOutput1 *out1 = NULL;
                if (SUCCEEDED(IDXGIOutput_QueryInterface(out, &k_iid_output1, (void **)&out1))) {
                    IDXGIOutputDuplication *dupl = NULL;
                    hr = IDXGIOutput1_DuplicateOutput(out1, (IUnknown *)dev, &dupl);
                    IDXGIOutput1_Release(out1);
                    if (SUCCEEDED(hr)) {
                        DXGI_OUTDUPL_DESC dd = {0};
                        IDXGIOutputDuplication_GetDesc(dupl, &dd);
                        if (dd.ModeDesc.Format != DXGI_FORMAT_B8G8R8A8_UNORM) {
                            /* an HDR desktop comes as 16-bit floats: say so instead of a wrong picture */
                            IDXGIOutputDuplication_Release(dupl);
                            IDXGIOutput_Release(out);
                            continue;
                        }
                        int tw = d.DesktopCoordinates.right - d.DesktopCoordinates.left;
                        int th = d.DesktopCoordinates.bottom - d.DesktopCoordinates.top;
                        int x0 = CLAMPI(region.left - d.DesktopCoordinates.left, 0, tw);
                        int y0 = CLAMPI(region.top - d.DesktopCoordinates.top, 0, th);
                        int x1 = CLAMPI(region.right - d.DesktopCoordinates.left, 0, tw);
                        int y1 = CLAMPI(region.bottom - d.DesktopCoordinates.top, 0, th);
                        if (x1 - x0 >= 2 && y1 - y0 >= 2) {
                            r->dev = dev;
                            r->ctx = ctx;
                            r->dupl = dupl;
                            r->tex_w = tw;
                            r->tex_h = th;
                            r->mon_x = d.DesktopCoordinates.left;
                            r->mon_y = d.DesktopCoordinates.top;
                            r->src_x = x0;
                            r->src_y = y0;
                            r->out_w = (x1 - x0) & ~1;
                            r->out_h = (y1 - y0) & ~1;
                            found = true;
                        } else {
                            IDXGIOutputDuplication_Release(dupl);
                        }
                    }
                }
            }
            IDXGIOutput_Release(out);
        }
        IDXGIAdapter1_Release(ad);
        if (!found) {
            ID3D11DeviceContext_Release(ctx);
            ID3D11Device_Release(dev);
        }
    }
    IDXGIFactory1_Release(factory);
    return found ? S_OK : E_FAIL;
}

static HRESULT rec_open_staging(Rec *r)
{
    D3D11_TEXTURE2D_DESC d = {0};
    d.Width = (UINT)r->tex_w;
    d.Height = (UINT)r->tex_h;
    d.MipLevels = 1;
    d.ArraySize = 1;
    d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    d.SampleDesc.Count = 1;
    d.Usage = D3D11_USAGE_STAGING;
    d.CPUAccessFlags = D3D11_CPU_ACCESS_READ | D3D11_CPU_ACCESS_WRITE;
    return ID3D11Device_CreateTexture2D(r->dev, &d, NULL, &r->staging);
}

static HRESULT rec_grab(Rec *r, UINT timeout, bool *got)
{
    *got = false;
    DXGI_OUTDUPL_FRAME_INFO fi = {0};
    IDXGIResource *res = NULL;
    HRESULT hr = IDXGIOutputDuplication_AcquireNextFrame(r->dupl, timeout, &fi, &res);
    if (hr == DXGI_ERROR_WAIT_TIMEOUT)
        return S_FALSE;
    if (FAILED(hr))
        return hr;

    ID3D11Texture2D *tex = NULL;
    bool copied = false;
    if (res && fi.LastPresentTime.QuadPart != 0 &&
        SUCCEEDED(IDXGIResource_QueryInterface(res, &k_iid_texture2d, (void **)&tex))) {
        ID3D11DeviceContext_CopyResource(r->ctx, (ID3D11Resource *)r->staging, (ID3D11Resource *)tex);
        ID3D11Texture2D_Release(tex);
        copied = true;
    }
    if (res)
        IDXGIResource_Release(res);
    IDXGIOutputDuplication_ReleaseFrame(r->dupl);
    if (fi.LastPresentTime.QuadPart == 0)
        return S_FALSE; /* only the pointer moved */
    if (!copied)
        return S_FALSE; /* never write the staging texture before it has a frame in it */

    D3D11_MAPPED_SUBRESOURCE map;
    hr = ID3D11DeviceContext_Map(r->ctx, (ID3D11Resource *)r->staging, 0, D3D11_MAP_READ_WRITE, 0, &map);
    if (FAILED(hr))
        return hr;
    rec_cursor_update(r);
    rec_cursor_draw(r, (uint8_t *)map.pData, (int)map.RowPitch);
    bgra_to_nv12(r, (const uint8_t *)map.pData, (int)map.RowPitch);
    ID3D11DeviceContext_Unmap(r->ctx, (ID3D11Resource *)r->staging, 0);
    *got = true;
    return S_OK;
}

/* ---- Media Foundation ------------------------------------------------------------ */

static HRESULT rec_open_writer(Rec *r, const WCHAR *path, int fps)
{
    IMFMediaType *out = NULL, *in = NULL;
    HRESULT hr = r->create_writer(path, NULL, NULL, &r->writer);
    if (FAILED(hr))
        goto done;
    hr = r->create_media_type(&out);
    if (FAILED(hr))
        goto done;
    IMFMediaType_SetGUID(out, &k_mt_major, &k_mt_video);
    IMFMediaType_SetGUID(out, &k_mt_subtype, &k_fmt_h264);
    IMFMediaType_SetUINT32(out, &k_mt_bitrate, (UINT32)CLAMPI((int)((int64_t)r->out_w * r->out_h * fps / 10),
                                                              1000000, 40000000));
    IMFMediaType_SetUINT32(out, &k_mt_interlace, 2);
    IMFMediaType_SetUINT64(out, &k_mt_frame_size, ((UINT64)r->out_w << 32) | (UINT32)r->out_h);
    IMFMediaType_SetUINT64(out, &k_mt_frame_rate, ((UINT64)fps << 32) | 1);
    IMFMediaType_SetUINT64(out, &k_mt_par, (1ULL << 32) | 1);
    hr = IMFSinkWriter_AddStream(r->writer, out, &r->stream);
    if (FAILED(hr))
        goto done;

    hr = r->create_media_type(&in);
    if (FAILED(hr))
        goto done;
    IMFMediaType_SetGUID(in, &k_mt_major, &k_mt_video);
    IMFMediaType_SetGUID(in, &k_mt_subtype, &k_fmt_nv12);
    IMFMediaType_SetUINT32(in, &k_mt_interlace, 2);
    IMFMediaType_SetUINT32(in, &k_mt_stride, (UINT32)r->out_w);
    IMFMediaType_SetUINT32(in, &k_mt_indep, 1);
    IMFMediaType_SetUINT32(in, &k_mt_fixed, 1);
    IMFMediaType_SetUINT64(in, &k_mt_frame_size, ((UINT64)r->out_w << 32) | (UINT32)r->out_h);
    IMFMediaType_SetUINT64(in, &k_mt_frame_rate, ((UINT64)fps << 32) | 1);
    IMFMediaType_SetUINT64(in, &k_mt_par, (1ULL << 32) | 1);
    hr = IMFSinkWriter_SetInputMediaType(r->writer, r->stream, in, NULL);
    if (FAILED(hr))
        goto done;
    hr = IMFSinkWriter_BeginWriting(r->writer);
    if (FAILED(hr))
        goto done;

    hr = r->create_sample(&r->sample);
    if (FAILED(hr))
        goto done;
    hr = r->create_memory_buffer((DWORD)((size_t)r->out_w * (size_t)r->out_h * 3 / 2), &r->buffer);
    if (FAILED(hr))
        goto done;
    hr = IMFSample_AddBuffer(r->sample, r->buffer);

done:
    if (in)
        IMFMediaType_Release(in);
    if (out)
        IMFMediaType_Release(out);
    return hr;
}

static HRESULT rec_write(Rec *r, LONGLONG ts, int fps)
{
    const DWORD len = (DWORD)((size_t)r->out_w * (size_t)r->out_h * 3 / 2);
    BYTE *p = NULL;
    DWORD max = 0, cur = 0;
    HRESULT hr = IMFMediaBuffer_Lock(r->buffer, &p, &max, &cur);
    if (FAILED(hr))
        return hr;
    memcpy(p, r->nv12, len);
    IMFMediaBuffer_SetCurrentLength(r->buffer, len);
    IMFMediaBuffer_Unlock(r->buffer);
    IMFSample_SetSampleTime(r->sample, ts);
    IMFSample_SetSampleDuration(r->sample, 10000000LL / fps);
    return IMFSinkWriter_WriteSample(r->writer, r->stream, r->sample);
}

/* ---- lifecycle ------------------------------------------------------------------- */

static HRESULT rec_close(Rec *r)
{
    HRESULT result = S_OK;
    if (r->writer) {
        HRESULT hr = IMFSinkWriter_Finalize(r->writer);
        if (FAILED(hr)) {
            rec_log(L"finalize", hr);
            result = hr;
        }
        IMFSinkWriter_Release(r->writer);
        r->writer = NULL;
    }
    if (r->sample) {
        IMFSample_Release(r->sample);
        r->sample = NULL;
    }
    if (r->buffer) {
        IMFMediaBuffer_Release(r->buffer);
        r->buffer = NULL;
    }
    if (r->dupl) {
        IDXGIOutputDuplication_Release(r->dupl);
        r->dupl = NULL;
    }
    if (r->staging) {
        ID3D11Texture2D_Release(r->staging);
        r->staging = NULL;
    }
    if (r->ctx) {
        ID3D11DeviceContext_Release(r->ctx);
        r->ctx = NULL;
    }
    if (r->dev) {
        ID3D11Device_Release(r->dev);
        r->dev = NULL;
    }
    mem_free(r->nv12);
    r->nv12 = NULL;
    rec_cursor_free(&r->cur);
    if (r->mf_started && r->mf_shutdown)
        r->mf_shutdown();
    if (r->com_owned && r->co_uninit)
        r->co_uninit();
    if (r->mfreadwrite) FreeLibrary(r->mfreadwrite);
    if (r->mfplat) FreeLibrary(r->mfplat);
    if (r->d3d11) FreeLibrary(r->d3d11);
    if (r->dxgi) FreeLibrary(r->dxgi);
    if (r->ole32) FreeLibrary(r->ole32);
    return result;
}

static HRESULT rec_open(Rec *r, RECT region, const WCHAR *path, int fps)
{
    memset(r, 0, sizeof *r);
    r->ole32 = LoadLibraryW(L"ole32.dll");
    r->mfplat = LoadLibraryW(L"mfplat.dll");
    r->mfreadwrite = LoadLibraryW(L"mfreadwrite.dll");
    r->dxgi = LoadLibraryW(L"dxgi.dll");
    r->d3d11 = LoadLibraryW(L"d3d11.dll");
    if (!r->ole32 || !r->mfplat || !r->mfreadwrite || !r->dxgi || !r->d3d11)
        return HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND);

    PFN_CoInitializeEx co_init = (PFN_CoInitializeEx)(void *)GetProcAddress(r->ole32, "CoInitializeEx");
    r->co_uninit = (PFN_CoUninitialize)(void *)GetProcAddress(r->ole32, "CoUninitialize");
    PFN_MFStartup mf_start = (PFN_MFStartup)(void *)GetProcAddress(r->mfplat, "MFStartup");
    r->mf_shutdown = (PFN_MFShutdown)(void *)GetProcAddress(r->mfplat, "MFShutdown");
    PFN_MFCreateAttributes create_attrs =
        (PFN_MFCreateAttributes)(void *)GetProcAddress(r->mfplat, "MFCreateAttributes");
    PFN_MFCreateMediaType create_type =
        (PFN_MFCreateMediaType)(void *)GetProcAddress(r->mfplat, "MFCreateMediaType");
    r->create_media_type = create_type;
    r->create_memory_buffer = (PFN_MFCreateMemoryBuffer)(void *)GetProcAddress(r->mfplat, "MFCreateMemoryBuffer");
    r->create_sample = (PFN_MFCreateSample)(void *)GetProcAddress(r->mfplat, "MFCreateSample");
    r->create_writer =
        (PFN_MFCreateSinkWriterFromURL)(void *)GetProcAddress(r->mfreadwrite, "MFCreateSinkWriterFromURL");
    r->create_factory = (PFN_CreateDXGIFactory1)(void *)GetProcAddress(r->dxgi, "CreateDXGIFactory1");
    r->create_device = (PFN_D3D11CreateDevice)(void *)GetProcAddress(r->d3d11, "D3D11CreateDevice");
    if (!co_init || !r->co_uninit || !mf_start || !r->mf_shutdown || !create_attrs || !create_type ||
        !r->create_memory_buffer || !r->create_sample || !r->create_writer || !r->create_factory ||
        !r->create_device)
        return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    (void)create_attrs;

    HRESULT hr = co_init(NULL, COINIT_MULTITHREADED);
    r->com_owned = hr == S_OK || hr == S_FALSE;
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE)
        return hr;
    hr = mf_start(REC_MF_VERSION, 0);
    if (FAILED(hr))
        return hr;
    r->mf_started = true;

    POINT mid = {region.left + (region.right - region.left) / 2,
                 region.top + (region.bottom - region.top) / 2};
    r->scale = dpi_scale_at(mid);
    HMONITOR mon = MonitorFromRect(&region, MONITOR_DEFAULTTONEAREST);
    hr = rec_open_output(r, mon, region);
    if (FAILED(hr))
        return hr;
    hr = rec_open_staging(r);
    if (FAILED(hr))
        return hr;

    r->nv12 = mem_alloc((size_t)r->out_w * (size_t)r->out_h * 3 / 2);
    if (!r->nv12)
        return E_OUTOFMEMORY;
    hr = rec_open_writer(r, path, fps);
    return hr;
}

static HRESULT rec_run(Rec *r, int fps, int duration_ms)
{
    double start = now_ms();
    int last = -1;
    bool have = false;
    for (;;) {
        double elapsed = now_ms() - start;
        if (elapsed >= duration_ms)
            break;
        int frame = (int)(elapsed * fps / 1000.0);
        if (frame <= last) {
            Sleep(1);
            continue;
        }
        bool got = false;
        HRESULT hr = rec_grab(r, have ? 0 : 100, &got);
        if (FAILED(hr))
            return hr;
        if (got)
            have = true;
        if (!have)
            continue;
        hr = rec_write(r, (LONGLONG)frame * 10000000LL / fps, fps);
        if (FAILED(hr))
            return hr;
        last = frame;
    }
    if (!have)
        return E_FAIL;
    return rec_write(r, (LONGLONG)duration_ms * 10000, fps);
}

/* The same loop for the recorder window: it runs until the stop event is set, and
 * the pause event freezes the timeline while it is set. */
static HRESULT rec_run_stop(Rec *r, int fps, HANDLE stop, HANDLE pause)
{
    double start = now_ms();
    double paused_at = 0, paused_total = 0;
    int last = -1;
    bool have = false, paused = false;
    for (;;) {
        bool stopping = WaitForSingleObject(stop, 0) == WAIT_OBJECT_0;
        bool want_paused = pause && WaitForSingleObject(pause, 0) == WAIT_OBJECT_0;
        if (want_paused != paused) {
            if (want_paused)
                paused_at = now_ms();
            else
                paused_total += now_ms() - paused_at;
            paused = want_paused;
        }
        if (paused) {
            if (stopping)
                break;
            Sleep(10);
            continue;
        }
        double elapsed = now_ms() - start - paused_total;
        int frame = (int)(elapsed * fps / 1000.0);
        if (frame <= last) {
            if (stopping)
                break;
            Sleep(1);
            continue;
        }
        bool got = false;
        HRESULT hr = rec_grab(r, have ? 0 : 100, &got);
        if (FAILED(hr))
            return hr;
        if (got)
            have = true;
        if (!have) {
            if (stopping)
                break;
            continue;
        }
        hr = rec_write(r, (LONGLONG)frame * 10000000LL / fps, fps);
        if (FAILED(hr))
            return hr;
        last = frame;
        if (stopping)
            break;
    }
    if (!have)
        return E_FAIL;
    return S_OK;
}

/* ---- the recorder window --------------------------------------------------------- */

#define REC_CLASS L"sniplite.recorder"
#define REC_WM_STARTED (WM_APP + 20)
#define REC_WM_FAILED (WM_APP + 21)
#define REC_WM_DONE (WM_APP + 22)
#define REC_WM_PAUSE (WM_APP + 30)

static HWND g_rec_wnd;
static HANDLE g_rec_stop;
static HANDLE g_rec_pause;
static HFONT g_rec_font;
static float g_rec_scale = 1.f;
static int g_rec_w = 216, g_rec_h = 52;
static WCHAR g_rec_path[2 * MAX_PATH];
static double g_rec_started;
static bool g_rec_started_set, g_rec_stopping, g_rec_hover, g_rec_pause_hover, g_rec_ok;
static bool g_rec_paused;
static double g_rec_paused_at, g_rec_paused_total;

static RECT rec_button_rect(void)
{
    RECT b;
    int side = (int)(36.f * g_rec_scale);
    b.right = g_rec_w - (int)(8.f * g_rec_scale);
    b.left = b.right - side;
    b.top = (g_rec_h - side) / 2;
    b.bottom = b.top + side;
    return b;
}

static RECT rec_pause_rect(void)
{
    RECT b = rec_button_rect(), p;
    int side = b.right - b.left, gap = (int)(6.f * g_rec_scale);
    p.right = b.left - gap;
    p.left = p.right - side;
    p.top = b.top;
    p.bottom = b.bottom;
    return p;
}

static void rec_stop_click(void)
{
    if (g_rec_stopping)
        return;
    g_rec_stopping = true;
    if (g_rec_stop)
        SetEvent(g_rec_stop);
    if (g_rec_wnd)
        InvalidateRect(g_rec_wnd, NULL, FALSE);
}

static void rec_pause_toggle(void)
{
    if (g_rec_stopping || !g_rec_started_set)
        return;
    double t = now_ms();
    if (g_rec_paused) {
        g_rec_paused_total += t - g_rec_paused_at;
        g_rec_paused = false;
        if (g_rec_pause)
            ResetEvent(g_rec_pause);
    } else {
        g_rec_paused_at = t;
        g_rec_paused = true;
        if (g_rec_pause)
            SetEvent(g_rec_pause);
    }
    if (g_rec_wnd)
        InvalidateRect(g_rec_wnd, NULL, FALSE);
}

static void rec_time_text(WCHAR *out, int cap)
{
    if (g_rec_stopping) {
        lstrcpynW(out, T(REC_SAVING), cap);
        return;
    }
    if (g_rec_paused) {
        lstrcpynW(out, T(REC_PAUSED), cap);
        return;
    }
    if (!g_rec_started_set) {
        lstrcpynW(out, L"00:00", cap);
        return;
    }
    int sec = (int)((now_ms() - g_rec_started - g_rec_paused_total) / 1000.0);
    if (sec < 0)
        sec = 0;
    if (sec >= 3600)
        wsprintfW(out, L"%d:%02d:%02d", sec / 3600, sec / 60 % 60, sec % 60);
    else
        wsprintfW(out, L"%02d:%02d", sec / 60, sec % 60);
}

static void rec_paint(HWND h)
{
    PAINTSTRUCT ps;
    HDC win = BeginPaint(h, &ps);
    RECT rc;
    GetClientRect(h, &rc);
    HDC mem = CreateCompatibleDC(win);
    HBITMAP bmp = mem ? CreateCompatibleBitmap(win, rc.right, rc.bottom) : NULL;
    HGDIOBJ oldbmp = bmp ? SelectObject(mem, bmp) : NULL;
    HDC dc = bmp ? mem : win;
    const float s = g_rec_scale;

    HBRUSH bg = CreateSolidBrush(RGB(30, 30, 34));
    FillRect(dc, &rc, bg);
    DeleteObject(bg);
    SetBkMode(dc, TRANSPARENT);

    int cy = rc.bottom / 2;
    bool lit = g_rec_stopping || !g_rec_started_set || ((GetTickCount64() / 500) & 1) == 0;
    HBRUSH dot = CreateSolidBrush(g_rec_paused ? RGB(125, 125, 133)
                                               : lit ? RGB(255, 69, 58) : RGB(92, 38, 40));
    HGDIOBJ oldbr = SelectObject(dc, dot);
    HGDIOBJ oldpen = SelectObject(dc, GetStockObject(NULL_PEN));
    int rad = (int)(5.f * s), dx = (int)(18.f * s);
    Ellipse(dc, dx - rad, cy - rad, dx + rad + 1, cy + rad + 1);
    SelectObject(dc, oldpen);
    SelectObject(dc, oldbr);
    DeleteObject(dot);

    RECT b = rec_button_rect(), pb = rec_pause_rect();
    WCHAR text[32];
    rec_time_text(text, COUNTOF(text));
    HFONT oldf = SelectObject(dc, g_rec_font);
    SetTextColor(dc, g_rec_stopping ? RGB(165, 165, 172) : RGB(245, 245, 247));
    RECT tr = {(int)(32.f * s), 0, pb.left - (int)(6.f * s), rc.bottom};
    DrawTextW(dc, text, -1, &tr, DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_NOPREFIX | DT_END_ELLIPSIS);
    SelectObject(dc, oldf);

    int br = (int)(9.f * s);
    HBRUSH pbg = CreateSolidBrush(g_rec_paused ? RGB(96, 96, 104)
                                               : g_rec_pause_hover ? RGB(66, 66, 74) : RGB(48, 48, 54));
    oldbr = SelectObject(dc, pbg);
    oldpen = SelectObject(dc, GetStockObject(NULL_PEN));
    RoundRect(dc, pb.left, pb.top, pb.right, pb.bottom, br, br);
    SelectObject(dc, oldpen);
    SelectObject(dc, oldbr);
    DeleteObject(pbg);
    {
        int side = (int)(10.f * s);
        int mx = (pb.left + pb.right) / 2, my = (pb.top + pb.bottom) / 2;
        HBRUSH wb = CreateSolidBrush(RGB(235, 235, 240));
        if (g_rec_paused) {
            POINT tri[3] = {{mx - side / 3, my - side / 2}, {mx - side / 3, my + side / 2}, {mx + side / 2, my}};
            oldbr = SelectObject(dc, wb);
            oldpen = SelectObject(dc, GetStockObject(NULL_PEN));
            Polygon(dc, tri, 3);
            SelectObject(dc, oldpen);
            SelectObject(dc, oldbr);
        } else {
            RECT r1 = {mx - side / 3, my - side / 2, mx - side / 10, my + side / 2};
            RECT r2 = {mx + side / 10, my - side / 2, mx + side / 3, my + side / 2};
            FillRect(dc, &r1, wb);
            FillRect(dc, &r2, wb);
        }
        DeleteObject(wb);
    }

    HBRUSH bb = CreateSolidBrush(g_rec_stopping ? RGB(78, 78, 86)
                                                : g_rec_hover ? RGB(255, 96, 101) : RGB(229, 72, 77));
    oldbr = SelectObject(dc, bb);
    oldpen = SelectObject(dc, GetStockObject(NULL_PEN));
    RoundRect(dc, b.left, b.top, b.right, b.bottom, br, br);
    SelectObject(dc, oldpen);
    SelectObject(dc, oldbr);
    DeleteObject(bb);

    if (!g_rec_stopping) {
        int side = (int)(10.f * s);
        HBRUSH wb = CreateSolidBrush(RGB(255, 255, 255));
        oldbr = SelectObject(dc, wb);
        oldpen = SelectObject(dc, GetStockObject(NULL_PEN));
        int mx = (b.left + b.right) / 2, my = (b.top + b.bottom) / 2;
        RoundRect(dc, mx - side / 2, my - side / 2, mx + side / 2, my + side / 2, (int)(2.f * s), (int)(2.f * s));
        SelectObject(dc, oldpen);
        SelectObject(dc, oldbr);
        DeleteObject(wb);
    }

    if (bmp) {
        BitBlt(win, 0, 0, rc.right, rc.bottom, mem, 0, 0, SRCCOPY);
        SelectObject(mem, oldbmp);
        DeleteObject(bmp);
        DeleteDC(mem);
    }
    EndPaint(h, &ps);
}

static LRESULT CALLBACK rec_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    switch (m) {
    case WM_CREATE:
        g_rec_wnd = h;
        SetWindowDisplayAffinity(h, 0x11); /* WDA_EXCLUDEFROMCAPTURE: not in the recording */
        g_rec_font = CreateFontW(-(int)(16.f * g_rec_scale), 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
                                 OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, T(FONT));
        SetTimer(h, 1, 200, NULL);
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT:
        rec_paint(h);
        return 0;
    case WM_TIMER:
        InvalidateRect(h, NULL, FALSE);
        return 0;
    case WM_MOUSEMOVE: {
        POINT p = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
        RECT b = rec_button_rect(), pb = rec_pause_rect();
        bool h1 = PtInRect(&b, p) != 0, h2 = PtInRect(&pb, p) != 0;
        if (h1 != g_rec_hover || h2 != g_rec_pause_hover) {
            g_rec_hover = h1;
            g_rec_pause_hover = h2;
            InvalidateRect(h, NULL, FALSE);
        }
        SetCursor(LoadCursorW(NULL, (h1 || h2) ? IDC_HAND : IDC_ARROW));
        TRACKMOUSEEVENT t = {sizeof t, TME_LEAVE, h, 0};
        TrackMouseEvent(&t);
        return 0;
    }
    case WM_MOUSELEAVE:
        if (g_rec_hover || g_rec_pause_hover) {
            g_rec_hover = false;
            g_rec_pause_hover = false;
            InvalidateRect(h, NULL, FALSE);
        }
        return 0;
    case WM_LBUTTONUP: {
        POINT p = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
        RECT b = rec_button_rect(), pb = rec_pause_rect();
        if (PtInRect(&b, p))
            rec_stop_click();
        else if (PtInRect(&pb, p))
            rec_pause_toggle();
        return 0;
    }
    case WM_KEYDOWN:
        if (wp == VK_ESCAPE)
            rec_stop_click();
        else if (wp == VK_SPACE)
            rec_pause_toggle();
        return 0;
    case WM_CLOSE:
        rec_stop_click();
        return 0;
    case REC_WM_STARTED:
        g_rec_started = now_ms();
        g_rec_started_set = true;
        InvalidateRect(h, NULL, FALSE);
        return 0;
    case REC_WM_FAILED:
        g_rec_ok = false;
        DestroyWindow(h);
        return 0;
    case REC_WM_DONE:
        g_rec_ok = wp != 0;
        DestroyWindow(h);
        return 0;
    case REC_WM_PAUSE:
        rec_pause_toggle();
        return 0;
    case WM_DESTROY:
        KillTimer(h, 1);
        if (g_rec_font) {
            DeleteObject(g_rec_font);
            g_rec_font = NULL;
        }
        PostQuitMessage(g_rec_ok ? 0 : 1);
        return 0;
    }
    return DefWindowProcW(h, m, wp, lp);
}

typedef struct {
    RECT rc;
    WCHAR path[2 * MAX_PATH];
    HANDLE stop;
    HANDLE pause;
    HWND wnd;
} RecJob;

static DWORD WINAPI rec_worker(void *arg)
{
    RecJob *j = arg;
    Rec r;
    HRESULT hr = rec_open(&r, j->rc, j->path, REC_FPS);
    if (FAILED(hr)) {
        rec_log(L"open", hr);
        (void)rec_close(&r);
        DeleteFileW(j->path);
        PostMessageW(j->wnd, REC_WM_FAILED, 0, 0);
        return 0;
    }
    PostMessageW(j->wnd, REC_WM_STARTED, 0, 0);
    hr = rec_run_stop(&r, REC_FPS, j->stop, j->pause);
    HRESULT close_hr = rec_close(&r);
    if (SUCCEEDED(hr))
        hr = close_hr;
    if (FAILED(hr)) {
        rec_log(L"run", hr);
        DeleteFileW(j->path);
    }
    PostMessageW(j->wnd, REC_WM_DONE, SUCCEEDED(hr), 0);
    return 0;
}

int rec_main(int argc, WCHAR **argv)
{
    if (argc < 7)
        return 2;
    int x = parse_int(argv[2]), y = parse_int(argv[3]);
    int w = parse_int(argv[4]), h = parse_int(argv[5]);
    if (w < 2 || h < 2)
        return 2;
    RECT rc = {x, y, x + w, y + h};
    lstrcpynW(g_rec_path, argv[6], COUNTOF(g_rec_path));

    POINT centre = {x + w / 2, y + h / 2};
    g_rec_scale = dpi_scale_at(centre);
    if (g_rec_scale < 1.f)
        g_rec_scale = 1.f;
    g_rec_w = (int)(216.f * g_rec_scale);
    g_rec_h = (int)(52.f * g_rec_scale);

    MONITORINFO mi = {sizeof mi};
    GetMonitorInfoW(MonitorFromRect(&rc, MONITOR_DEFAULTTONEAREST), &mi);
    int gap = (int)(12.f * g_rec_scale);
    int wx = x + (w - g_rec_w) / 2;
    int wy = y - g_rec_h - gap;
    if (wy < mi.rcWork.top)
        wy = y + h + gap;
    if (wy + g_rec_h > mi.rcWork.bottom) { /* no room above or below: the corner of the monitor */
        wx = mi.rcWork.right - g_rec_w - gap;
        wy = mi.rcWork.bottom - g_rec_h - gap;
    }
    wx = CLAMPI(wx, mi.rcWork.left, MAXI(mi.rcWork.left, mi.rcWork.right - g_rec_w));
    wy = CLAMPI(wy, mi.rcWork.top, MAXI(mi.rcWork.top, mi.rcWork.bottom - g_rec_h));

    WNDCLASSW wc = {0};
    wc.lpfnWndProc = rec_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = REC_CLASS;
    RegisterClassW(&wc);

    g_rec_stop = CreateEventW(NULL, FALSE, FALSE, NULL);
    g_rec_pause = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!g_rec_stop || !g_rec_pause)
        return 1;
    HWND hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, REC_CLASS, L"sniplite recording", WS_POPUP,
                                wx, wy, g_rec_w, g_rec_h, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) {
        CloseHandle(g_rec_stop);
        g_rec_stop = NULL;
        return 1;
    }
    HRGN rgn = CreateRoundRectRgn(0, 0, g_rec_w + 1, g_rec_h + 1, (int)(14.f * g_rec_scale),
                                  (int)(14.f * g_rec_scale));
    if (rgn)
        SetWindowRgn(hwnd, rgn, TRUE);
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    UpdateWindow(hwnd);

    RecJob *j = mem_alloc(sizeof *j);
    HANDLE th = NULL;
    if (j) {
        j->rc = rc;
        lstrcpynW(j->path, g_rec_path, COUNTOF(j->path));
        j->stop = g_rec_stop;
        j->pause = g_rec_pause;
        j->wnd = hwnd;
        th = CreateThread(NULL, 0, rec_worker, j, 0, NULL);
    }
    if (!th) {
        mem_free(j);
        DestroyWindow(hwnd);
    } else {
        CloseHandle(th);
    }

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    int code = th ? (int)msg.wParam : 1;
    mem_free(j);
    CloseHandle(g_rec_stop);
    g_rec_stop = NULL;
    CloseHandle(g_rec_pause);
    g_rec_pause = NULL;
    g_rec_wnd = NULL;
    return code;
}

int rec_test_main(int argc, WCHAR **argv)
{
    if (argc < 8)
        return 2;
    int x = parse_int(argv[2]), y = parse_int(argv[3]);
    int w = parse_int(argv[4]), h = parse_int(argv[5]);
    int sec = parse_int(argv[6]);
    if (w < 2 || h < 2 || sec <= 0)
        return 2;
    RECT rc = {x, y, x + w, y + h};
    Rec r;
    HRESULT hr = rec_open(&r, rc, argv[7], REC_FPS);
    if (FAILED(hr)) {
        rec_log(L"open", hr);
        (void)rec_close(&r);
        return 1;
    }
    hr = rec_run(&r, REC_FPS, sec * 1000);
    HRESULT close_hr = rec_close(&r);
    if (SUCCEEDED(hr))
        hr = close_hr;
    rec_log(SUCCEEDED(hr) ? L"done" : L"run", hr);
    return SUCCEEDED(hr) ? 0 : 1;
}
