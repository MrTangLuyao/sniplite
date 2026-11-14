/* sniplite.exe: the background process (hotkeys, tray icon, capture overlay, pins, IPC),
 * plus the internal helper modes (--save-dialog, --settings, --shortcuts,
 * --update-check, --uninstall), each its own short-lived process. */
#include "common.h"
#include "config.h"
#include "image.h"
#include "install.h"
#include "lang.h"
#include "overlay.h"
#include "pin.h"
#include "settings.h"
#include "shot.h"
#include "update.h"
#include <shellapi.h>
#include <windowsx.h>

#define WM_APP_TRAY (WM_APP + 2)
#define WM_APP_SETTINGS_DONE (WM_APP + 3)
#define TIMER_MENU_CAPTURE 1
#define TIMER_UPDATE 2
#define UPDATE_FIRST_MS (60 * 1000)           /* first check a minute after start */
#define UPDATE_EVERY_MS (24 * 60 * 60 * 1000) /* then once a day */

typedef struct {
    UINT mod, vk;
    bool ok;
    WCHAR text[40];
} Hotkey;

typedef struct {
    UINT mod[HK_COUNT], vk[HK_COUNT];
    bool set[HK_COUNT];
    int backend; /* 0 keep, 1 dxgi, 2 gdi */
} StartOpts;

typedef BOOL(WINAPI *PFN_ShellNotify)(DWORD, PNOTIFYICONDATAW);

static struct {
    HINSTANCE inst;
    HWND hwnd;
    Hotkey hk[HK_COUNT];
    Config cfg;          /* effective settings (ini, then command-line overrides) */
    bool tray_on;
    NOTIFYICONDATAW nid;
    HICON icon;
    UINT wm_taskbar;     /* "TaskbarCreated": Explorer restarted */
    PFN_ShellNotify notify;
    HANDLE settings;     /* the preferences helper process while it is open */
    bool update_timer;   /* the daily update check is scheduled */
    WCHAR update_tag[32]; /* newer release already announced in a balloon */
} D;

/* ---- hotkeys --------------------------------------------------------------------- */

static void hotkey_apply(int id, UINT mod, UINT vk)
{
    Hotkey *k = &D.hk[id];
    UnregisterHotKey(D.hwnd, id);
    k->mod = mod;
    k->vk = vk;
    hotkey_format(mod, vk, k->text);
    k->ok = !vk || RegisterHotKey(D.hwnd, id, mod | MOD_NOREPEAT, vk);
}

static bool hotkeys_ok(void)
{
    for (int i = 1; i < HK_COUNT; i++)
        if (!D.hk[i].ok)
            return false;
    return true;
}

/* ---- command helpers ---------------------------------------------------------------- */

static const WCHAR *opt_val(int argc, WCHAR **argv, const WCHAR *name)
{
    for (int i = 1; i + 1 < argc; i++)
        if (arg_eq(argv[i], name))
            return argv[i + 1];
    return NULL;
}

static bool opt_has(int argc, WCHAR **argv, const WCHAR *name)
{
    for (int i = 1; i < argc; i++)
        if (arg_eq(argv[i], name))
            return true;
    return false;
}

/* Every token after the command must be a known flag, a known option + value,
 * or (when allowed) the single positional argument. */
static bool args_valid(int argc, WCHAR **argv, const WCHAR *const *flags, const WCHAR *const *opts, int positional,
                       Str *out)
{
    int pos = 0;
    for (int i = 1; i < argc; i++) {
        bool known = false;
        for (int k = 0; flags[k] && !known; k++)
            known = arg_eq(argv[i], flags[k]);
        for (int k = 0; opts[k] && !known; k++)
            if (arg_eq(argv[i], opts[k])) {
                if (i + 1 >= argc) {
                    str_addf(out, T(ERR_MISSING_VALUE), argv[i]);
                    return false;
                }
                i++;
                known = true;
            }
        if (!known && argv[i][0] != L'-' && pos < positional) {
            pos++;
            known = true;
        }
        if (!known) {
            str_addf(out, T(ERR_UNKNOWN_ARG), argv[i]);
            return false;
        }
    }
    return true;
}

static bool parse_ints(const WCHAR *s, int *v, int n)
{
    for (int i = 0; i < n; i++) {
        bool neg = *s == L'-';
        if (neg)
            s++;
        if (*s < L'0' || *s > L'9')
            return false;
        long long x = 0;
        while (*s >= L'0' && *s <= L'9') {
            x = x * 10 + (*s++ - L'0');
            if (x > 1000000)
                return false;
        }
        v[i] = (int)(neg ? -x : x);
        if (i + 1 < n && *s++ != L',')
            return false;
    }
    return *s == 0;
}

static void resolve_path(const WCHAR *cwd, const WCHAR *p, WCHAR *out, int cap)
{
    WCHAR tmp[1025]; /* the 1024 characters wsprintfW can write, and the 0 */
    bool abs = (p[0] && p[1] == L':') || (p[0] == L'\\' && p[1] == L'\\');
    if (abs || !cwd[0])
        lstrcpynW(tmp, p, MAX_PATH * 2);
    else if (p[0] == L'\\' || p[0] == L'/') /* root of the caller's drive */
        wsprintfW(tmp, L"%c:%s", cwd[0], p);
    else
        wsprintfW(tmp, L"%s\\%s", cwd, p);
    DWORD n = GetFullPathNameW(tmp, (DWORD)cap, out, NULL);
    if (!n || n >= (DWORD)cap) /* failed, or out is too small */
        lstrcpynW(out, tmp, cap);
}

static bool start_opts_parse(int argc, WCHAR **argv, StartOpts *so, Str *err)
{
    static const WCHAR *names[HK_COUNT] = {NULL, L"--hotkey", L"--pin-hotkey", L"--toggle-hotkey"};
    memset(so, 0, sizeof *so);
    for (int id = 1; id < HK_COUNT; id++) {
        const WCHAR *v = opt_val(argc, argv, names[id]);
        if (!v)
            continue;
        if (!hotkey_parse(v, &so->mod[id], &so->vk[id])) {
            if (err)
                str_addf(err, T(ERR_BAD_HOTKEY), v);
            return false;
        }
        so->set[id] = true;
    }
    bool gdi = opt_has(argc, argv, L"--gdi"), dxgi = opt_has(argc, argv, L"--dxgi");
    if (gdi && dxgi) {
        if (err)
            str_add(err, T(ERR_GDI_DXGI));
        return false;
    }
    so->backend = dxgi ? 1 : gdi ? 2 : 0;
    return true;
}

/* ---- commands ---------------------------------------------------------------------- */

/* "  label" padded to column 16 (Chinese, Japanese and Korean characters take two
 * columns), with at least one space after a longer one. */
static void add_label(Str *out, const WCHAR *label)
{
    int w = 0;
    for (const WCHAR *p = label; *p; p++)
        w += *p >= 0x1100 ? 2 : 1;
    str_add(out, L"  ");
    str_add(out, label);
    do
        str_add(out, L" ");
    while (++w < 16);
}

static void status_text(Str *out)
{
    str_addf(out, T(ST_RUNNING), SNIPLITE_VERSION, GetCurrentProcessId());
    for (int id = 1; id < HK_COUNT; id++) {
        const Hotkey *k = &D.hk[id];
        add_label(out, g_tr[S_ST_HK_CAPTURE + id - 1]);
        str_addf(out, L"%s%s\n", k->vk ? k->text : T(UNSET), k->ok ? L"" : T(ST_HK_FAILED));
    }
    const WCHAR *b = shot_backend();
    add_label(out, T(ST_BACKEND));
    str_addf(out, L"%s\n", !lstrcmpW(b, L"dxgi") ? T(ST_DXGI) : !lstrcmpW(b, L"starting") ? T(ST_DXGI_STARTING) : L"GDI");
    add_label(out, T(ST_PINS));
    str_addf(out, L"%d\n", pin_count());
    OvTiming t;
    if (ov_last_timing(&t)) {
        add_label(out, T(ST_LAST));
        str_add(out, T(ST_LAST_1));
        str_add_ms(out, t.total);
        str_add(out, T(ST_LAST_2));
        str_add_ms(out, t.grab);
        str_add(out, T(ST_LAST_3));
        str_add_ms(out, t.paint);
        str_add(out, T(ST_LAST_4));
    }
}

static void status_json(Str *out)
{
    static const WCHAR *keys[HK_COUNT] = {NULL, L"capture", L"pin", L"toggle_pins"};
    str_addf(out, L"{\"running\":true,\"version\":\"%s\",\"pid\":%lu,\"backend\":\"%s\",\"capturing\":%s,\"pins\":%d,",
             SNIPLITE_VERSION, GetCurrentProcessId(), shot_backend(), ov_active() ? L"true" : L"false", pin_count());
    str_add(out, L"\"hotkeys\":{");
    for (int id = 1; id < HK_COUNT; id++)
        str_addf(out, L"%s\"%s\":{\"key\":\"%s\",\"ok\":%s}", id > 1 ? L"," : L"", keys[id], D.hk[id].text,
                 D.hk[id].ok ? L"true" : L"false");
    str_add(out, L"},\"last_capture\":");
    OvTiming t;
    if (ov_last_timing(&t)) {
        const double v[] = {t.total, t.grab, t.windows, t.paint, t.focus};
        const WCHAR *k[] = {L"total_ms", L"grab_ms", L"windows_ms", L"paint_ms", L"focus_ms"};
        for (int i = 0; i < COUNTOF(v); i++) {
            str_addf(out, L"%s\"%s\":", i ? L"," : L"{", k[i]);
            str_add_ms(out, v[i]);
        }
        str_add(out, L"}");
    } else {
        str_add(out, L"null");
    }
    str_add(out, L"}\n");
}

/* ---- tray icon --------------------------------------------------------------------- */

static void tray_tip(WCHAR *tip, int cap)
{
    WCHAR t[200];
    lstrcpyW(t, L"sniplite");
    if (D.hk[HK_CAPTURE].vk)
        wsprintfW(t + lstrlenW(t), T(TRAY_CAPTURE), D.hk[HK_CAPTURE].text);
    if (D.hk[HK_PIN].vk)
        wsprintfW(t + lstrlenW(t), T(TRAY_PIN), D.hk[HK_PIN].text);
    lstrcpynW(tip, t, cap);
}

static void tray_add(void)
{
    if (D.tray_on)
        return;
    if (!D.notify) { /* shell32 only gets loaded when the icon is wanted */
        HMODULE h = LoadLibraryW(L"shell32.dll");
        D.notify = h ? (PFN_ShellNotify)(void *)GetProcAddress(h, "Shell_NotifyIconW") : NULL;
        if (!D.notify)
            return;
    }
    if (!D.icon) {
        int sz = GetSystemMetricsForDpi(SM_CXSMICON, GetDpiForSystem());
        D.icon = LoadImageW(D.inst, MAKEINTRESOURCEW(1), IMAGE_ICON, sz, sz, 0);
    }
    NOTIFYICONDATAW *n = &D.nid;
    memset(n, 0, sizeof *n);
    n->cbSize = sizeof *n;
    n->hWnd = D.hwnd;
    n->uID = 1;
    n->uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    n->uCallbackMessage = WM_APP_TRAY;
    n->hIcon = D.icon;
    tray_tip(n->szTip, COUNTOF(n->szTip));
    if (D.notify(NIM_ADD, n)) {
        n->uVersion = NOTIFYICON_VERSION_4;
        D.notify(NIM_SETVERSION, n);
        D.tray_on = true;
    }
}

static void tray_remove(void)
{
    if (D.tray_on) {
        D.notify(NIM_DELETE, &D.nid);
        D.tray_on = false;
    }
}

static void tray_refresh_tip(void)
{
    if (!D.tray_on)
        return;
    tray_tip(D.nid.szTip, COUNTOF(D.nid.szTip));
    D.nid.uFlags = NIF_TIP | NIF_SHOWTIP;
    D.notify(NIM_MODIFY, &D.nid);
}

/* Apply settings. force_keys re-registers every hotkey (after the preferences window). */
static void apply_config(const Config *c, bool force_keys)
{
    for (int id = 1; id < HK_COUNT; id++)
        if (force_keys || c->mod[id] != D.hk[id].mod || c->vk[id] != D.hk[id].vk || !D.hk[id].ok)
            hotkey_apply(id, c->mod[id], c->vk[id]);
    if (c->gdi && gpu_enabled())
        gpu_stop();
    else if (!c->gdi && !gpu_enabled())
        gpu_start(D.hwnd);
    if (c->tray)
        tray_add();
    else
        tray_remove();
    /* the result is shown as a tray balloon: without the icon there is no point checking */
    bool check = c->auto_update && c->tray;
    if (check && !D.update_timer) {
        D.update_timer = SetTimer(D.hwnd, TIMER_UPDATE, UPDATE_FIRST_MS, NULL) != 0;
    } else if (!check && D.update_timer) {
        KillTimer(D.hwnd, TIMER_UPDATE);
        D.update_timer = false;
    }
    D.cfg = *c;
    tray_refresh_tip();
}

/* A newer release was found by `--update-check`: say so once, in a balloon. */
static void update_notify(const WCHAR *tag)
{
    for (const WCHAR *p = tag; *p; p++)
        if (!((*p >= L'0' && *p <= L'9') || (*p >= L'a' && *p <= L'z') || (*p >= L'A' && *p <= L'Z') || *p == L'.' ||
              *p == L'-' || *p == L'_'))
            return;
    if (!*tag || lstrlenW(tag) >= COUNTOF(D.update_tag) || !lstrcmpW(tag, D.update_tag) || !D.tray_on)
        return;
    lstrcpyW(D.update_tag, tag);
    NOTIFYICONDATAW n = D.nid;
    n.uFlags = NIF_INFO | NIF_SHOWTIP; /* without NIF_SHOWTIP the tooltip would go away */
    n.dwInfoFlags = NIIF_INFO;
    lstrcpynW(n.szInfoTitle, T(UPD_BALLOON_TITLE), COUNTOF(n.szInfoTitle));
    wsprintfW(n.szInfo, T(UPD_BALLOON_TEXT), tag);
    D.notify(NIM_MODIFY, &n);
}

static void apply_start(const StartOpts *so)
{
    Config c = D.cfg;
    for (int id = 1; id < HK_COUNT; id++)
        if (so->set[id]) {
            c.mod[id] = so->mod[id];
            c.vk[id] = so->vk[id];
        }
    if (so->backend)
        c.gdi = so->backend == 2;
    apply_config(&c, false);
}

/* ---- preferences window (separate short-lived process) -------------------------------- */

static DWORD WINAPI settings_wait(void *proc)
{
    WaitForSingleObject((HANDLE)proc, INFINITE);
    PostMessageW(D.hwnd, WM_APP_SETTINGS_DONE, 0, 0);
    return 0;
}

/* Start sniplite.exe with a helper switch (its own short-lived process). quiet: a
 * background job, so no busy cursor while it starts. */
static bool run_helper(const WCHAR *args, bool quiet)
{
    WCHAR exe[MAX_PATH];
    if (!GetModuleFileNameW(NULL, exe, MAX_PATH))
        return false;
    Str cmd = {0};
    str_add_quoted(&cmd, exe);
    str_add(&cmd, args);
    STARTUPINFOW si = {sizeof si};
    if (quiet)
        si.dwFlags = STARTF_FORCEOFFFEEDBACK;
    PROCESS_INFORMATION pi;
    AllowSetForegroundWindow(ASFW_ANY);
    bool ok = cmd.p && CreateProcessW(exe, cmd.p, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi);
    str_free(&cmd);
    if (ok) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
    return ok;
}

/* page: NULL, or "update" to open the window on the update tab (an open window switches) */
static bool settings_open(const WCHAR *page)
{
    if (D.settings) {
        if (page)
            return run_helper(L" --settings update", false); /* finds the open window and tells it */
        HWND w = ipc_find_dialog(SETTINGS_MARK);
        if (w) {
            ShowWindow(w, SW_RESTORE);
            SetForegroundWindow(w);
        }
        return true;
    }
    WCHAR exe[MAX_PATH];
    if (!GetModuleFileNameW(NULL, exe, MAX_PATH))
        return false;
    Str cmd = {0};
    str_add_quoted(&cmd, exe);
    str_add(&cmd, page ? L" --settings update" : L" --settings");
    STARTUPINFOW si = {sizeof si};
    PROCESS_INFORMATION pi;
    AllowSetForegroundWindow(ASFW_ANY);
    bool ok = cmd.p && CreateProcessW(exe, cmd.p, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi);
    str_free(&cmd);
    HANDLE th = NULL;
    if (ok) {
        CloseHandle(pi.hThread);
        D.settings = pi.hProcess;
        th = CreateThread(NULL, 0, settings_wait, pi.hProcess, 0, NULL);
    }
    if (!th) { /* without a watcher a crash mid-recording could leave hotkeys off */
        if (ok) {
            TerminateProcess(pi.hProcess, 1);
            CloseHandle(pi.hProcess);
            D.settings = NULL;
        }
        return false;
    }
    CloseHandle(th);
    return true;
}

/* sniplite.ini again: the preferences window saves every change, the language too. */
static void reload(void)
{
    lang_init(NULL);
    Config c;
    config_load(&c);
    apply_config(&c, true);
}

static void settings_done(void)
{
    if (D.settings) {
        CloseHandle(D.settings);
        D.settings = NULL;
    }
    reload(); /* also restores the hotkeys if the window died while recording one */
}

static int cmd_start(int argc, WCHAR **argv, bool json, Str *out)
{
    static const WCHAR *flags[] = {L"--json", L"--gdi", L"--dxgi", NULL};
    static const WCHAR *opts[] = {L"--hotkey", L"--pin-hotkey", L"--toggle-hotkey", NULL};
    StartOpts so;
    if (!args_valid(argc, argv, flags, opts, 0, out) || !start_opts_parse(argc, argv, &so, out))
        return EXIT_USAGE;
    apply_start(&so);
    if (json)
        status_json(out);
    else
        status_text(out);
    return hotkeys_ok() ? EXIT_OK : EXIT_HOTKEY;
}

static int capture_now(RECT sr, const WCHAR *path, bool clip, bool pin, bool json, Str *out)
{
    Shot sh;
    if (!shot_take(&sh, NULL, NULL)) {
        str_add(out, T(CAP_FAILED));
        return EXIT_FAIL;
    }
    RECT vs = {sh.vx, sh.vy, sh.vx + sh.vw, sh.vy + sh.vh};
    RECT r = rect_isect(sr, vs);
    if (rect_empty(&r)) {
        shot_free(&sh);
        str_add(out, T(CAP_OUTSIDE));
        return EXIT_USAGE;
    }
    RECT cr = {r.left - sh.vx, r.top - sh.vy, r.right - sh.vx, r.bottom - sh.vy};
    int w = r.right - r.left, h = r.bottom - r.top;
    double grab = sh.grab_ms;
    Img im;
    if (!img_create(&im, w, h)) {
        shot_free(&sh);
        str_add(out, T(NO_MEMORY));
        return EXIT_FAIL;
    }
    shot_copy(&sh, cr, im.px, w);
    shot_free(&sh);
    bool saved = false, copied = false, pinned = false;
    if (path)
        saved = image_save(path, im.px, w, w, h);
    if (clip)
        copied = clip_put_image(D.hwnd, im.px, w, w, h);
    if (pin)
        pinned = pin_add(&im, r.left, r.top, false);
    else
        img_destroy(&im);
    bool ok = (!path || saved) && (!clip || copied) && (!pin || pinned);
    if (json) {
        str_addf(out, L"{\"ok\":%s,\"x\":%d,\"y\":%d,\"width\":%d,\"height\":%d,\"grab_ms\":", ok ? L"true" : L"false",
                 (int)r.left, (int)r.top, w, h);
        str_add_ms(out, grab);
        str_add(out, L",\"file\":");
        if (path)
            str_add_json(out, path);
        else
            str_add(out, L"null");
        str_addf(out, L",\"saved\":%s,\"clipboard\":%s,\"pinned\":%s}\n", saved ? L"true" : L"false",
                 copied ? L"true" : L"false", pinned ? L"true" : L"false");
    } else {
        str_addf(out, T(CAP_DONE_1), w, h);
        str_add_ms(out, grab);
        str_add(out, T(CAP_DONE_2));
        if (path)
            str_addf(out, saved ? T(SAVED) : T(SAVE_FAILED), path);
        if (clip)
            str_add(out, copied ? T(COPIED) : T(COPY_FAILED));
        if (pin)
            str_add(out, pinned ? T(PINNED) : T(PIN_FAILED));
    }
    return ok ? EXIT_OK : EXIT_FAIL;
}

static int cmd_capture(int argc, WCHAR **argv, const WCHAR *cwd, bool json, Str *out)
{
    static const WCHAR *flags[] = {L"--json", L"--full", L"--clip", L"--pin", NULL};
    static const WCHAR *opts[] = {L"--rect", L"--out", NULL};
    if (!args_valid(argc, argv, flags, opts, 0, out))
        return EXIT_USAGE;
    const WCHAR *rect = opt_val(argc, argv, L"--rect"), *file = opt_val(argc, argv, L"--out");
    bool full = opt_has(argc, argv, L"--full"), clip = opt_has(argc, argv, L"--clip"), pin = opt_has(argc, argv, L"--pin");
    if (ov_active()) {
        str_add(out, T(CAPTURING));
        return EXIT_FAIL;
    }
    if (!rect && !full) {
        if (file || clip || pin) {
            str_add(out, T(ERR_NEED_RECT));
            return EXIT_USAGE;
        }
        if (!ov_begin()) {
            str_add(out, T(CAP_CANNOT));
            return EXIT_FAIL;
        }
        return EXIT_OK;
    }
    RECT sr;
    if (rect) {
        int v[4];
        if (full || !parse_ints(rect, v, 4) || v[2] <= 0 || v[3] <= 0) {
            str_add(out, T(ERR_RECT));
            return EXIT_USAGE;
        }
        SetRect(&sr, v[0], v[1], v[0] + v[2], v[1] + v[3]);
    } else {
        int x = GetSystemMetrics(SM_XVIRTUALSCREEN), y = GetSystemMetrics(SM_YVIRTUALSCREEN);
        SetRect(&sr, x, y, x + GetSystemMetrics(SM_CXVIRTUALSCREEN), y + GetSystemMetrics(SM_CYVIRTUALSCREEN));
    }
    WCHAR path[MAX_PATH * 2];
    if (file)
        resolve_path(cwd, file, path, COUNTOF(path));
    if (!file && !pin)
        clip = true; /* the useful default */
    return capture_now(sr, file ? path : NULL, clip, pin, json, out);
}

static int cmd_pin(int argc, WCHAR **argv, const WCHAR *cwd, bool json, Str *out)
{
    static const WCHAR *flags[] = {L"--json", NULL};
    static const WCHAR *opts[] = {NULL};
    if (!args_valid(argc, argv, flags, opts, 1, out))
        return EXIT_USAGE;
    const WCHAR *file = NULL;
    for (int i = 1; i < argc; i++)
        if (argv[i][0] != L'-')
            file = argv[i];
    Img im;
    int rc;
    WCHAR path[MAX_PATH * 2];
    if (file) {
        resolve_path(cwd, file, path, COUNTOF(path));
        rc = image_load(path, &im) ? EXIT_OK : EXIT_FAIL;
        if (rc)
            str_addf(out, T(ERR_READ_IMAGE), path);
    } else {
        rc = clip_get_image(D.hwnd, &im);
        if (rc == EXIT_NOTHING)
            str_add(out, T(CLIP_EMPTY));
        else if (rc)
            str_add(out, T(CLIP_FAILED));
    }
    if (rc)
        return rc;
    int w = im.w, h = im.h;
    if (!pin_add(&im, 0, 0, true)) {
        str_add(out, T(PIN_FAILED));
        return EXIT_FAIL;
    }
    if (json)
        str_addf(out, L"{\"ok\":true,\"width\":%d,\"height\":%d}\n", w, h);
    else
        str_addf(out, T(PIN_DONE), w, h);
    return EXIT_OK;
}

static int cmd_run(int argc, WCHAR **argv, const WCHAR *cwd, Str *out)
{
    WCHAR *tmp[66];
    if (argc == 0 || argv[0][0] == L'-') { /* no command or bare options mean "start" */
        int tc = 0;
        tmp[tc++] = L"start";
        for (int i = 0; i < argc && tc < COUNTOF(tmp); i++)
            tmp[tc++] = argv[i];
        argv = tmp;
        argc = tc;
    }
    bool json = opt_has(argc, argv, L"--json");
    const WCHAR *c = argv[0];
    if (arg_eq(c, L"start"))
        return cmd_start(argc, argv, json, out);
    if (arg_eq(c, L"capture"))
        return cmd_capture(argc, argv, cwd, json, out);
    if (arg_eq(c, L"pin"))
        return cmd_pin(argc, argv, cwd, json, out);
    if (arg_eq(c, L"status")) {
        json ? status_json(out) : status_text(out);
        return EXIT_OK;
    }
    if (arg_eq(c, L"quit") || arg_eq(c, L"exit")) {
        PostMessageW(D.hwnd, WM_CLOSE, 0, 0);
        str_add(out, json ? L"{\"ok\":true}\n" : T(QUIT_DONE));
        return EXIT_OK;
    }
    if (arg_eq(c, L"_hotkeys")) { /* a hotkey field is recording: let the keys through */
        for (int id = 1; id < HK_COUNT; id++)
            UnregisterHotKey(D.hwnd, id);
        return EXIT_OK;
    }
    if (arg_eq(c, L"_reload") || arg_eq(c, L"_hkstate")) {
        if (arg_eq(c, L"_reload"))
            reload();
        for (int id = 1; id < HK_COUNT; id++) /* 1 registered, 0 failed, 2 none */
            str_addf(out, L"%d ", !D.hk[id].vk ? 2 : D.hk[id].ok ? 1 : 0);
        return EXIT_OK;
    }
    if (arg_eq(c, L"_update")) { /* from `--update-check` */
        if (argc > 1)
            update_notify(argv[1]);
        return EXIT_OK;
    }
    if (arg_eq(c, L"settings")) { /* `settings update` opens the update tab */
        if (!settings_open(argc > 1 && arg_eq(argv[1], L"update") ? L"update" : NULL)) {
            str_add(out, T(ERR_SETTINGS));
            return EXIT_FAIL;
        }
        return EXIT_OK;
    }
    if (arg_eq(c, L"version") || arg_eq(c, L"--version")) {
        str_addf(out, L"sniplite %s\n", SNIPLITE_VERSION);
        return EXIT_OK;
    }
    str_addf(out, T(ERR_UNKNOWN_CMD), c);
    return EXIT_USAGE;
}

/* ---- daemon window ------------------------------------------------------------------- */

static LRESULT ipc_handle(HWND h, HWND reply, const COPYDATASTRUCT *cd)
{
    if (!cd || cd->dwData != IPC_REQ || cd->cbData < sizeof(WCHAR) || cd->cbData > 256 * 1024)
        return 0;
    int n = (int)(cd->cbData / sizeof(WCHAR));
    WCHAR *buf = mem_alloc(((size_t)n + 1) * sizeof(WCHAR));
    if (!buf)
        return 0;
    memcpy(buf, cd->lpData, (size_t)n * sizeof(WCHAR));
    buf[n] = 0;
    WCHAR *parts[64];
    int np = 0;
    parts[np++] = buf;
    for (WCHAR *p = buf; *p; p++)
        if (*p == IPC_SEP) {
            *p = 0;
            if (np < COUNTOF(parts))
                parts[np++] = p + 1;
        }
    Str out = {0};
    int code = cmd_run(np - 1, parts + 1, parts[0], &out);
    if (reply && IsWindow(reply)) {
        COPYDATASTRUCT rc = {IPC_REPLY, (DWORD)((out.n + 1) * sizeof(WCHAR)), out.p ? out.p : (WCHAR *)L""};
        SendMessageTimeoutW(reply, WM_COPYDATA, (WPARAM)h, (LPARAM)&rc, SMTO_ABORTIFHUNG, 5000, NULL);
    }
    str_free(&out);
    mem_free(buf);
    return IPC_BASE + code;
}

static void pin_clipboard(void)
{
    Img im;
    if (clip_get_image(D.hwnd, &im) == EXIT_OK)
        pin_add(&im, 0, 0, true);
    else
        MessageBeep(MB_ICONWARNING);
}

enum { TM_CAPTURE = 1, TM_PIN, TM_TOGGLE, TM_CLOSE_PINS, TM_SETTINGS, TM_HELP, TM_UPDATE, TM_ABOUT, TM_EXIT };

static void menu_item(HMENU m, UINT id, const WCHAR *text, int hk, bool enabled)
{
    WCHAR t[96];
    if (hk && D.hk[hk].vk)
        wsprintfW(t, L"%s\t%s", text, D.hk[hk].text);
    else
        lstrcpynW(t, text, COUNTOF(t));
    AppendMenuW(m, MF_STRING | (enabled ? 0 : MF_GRAYED), id, t);
}

static void tray_menu(POINT at)
{
    HMENU m = CreatePopupMenu();
    bool pins = pin_count() > 0;
    menu_item(m, TM_CAPTURE, T(M_CAPTURE), HK_CAPTURE, true);
    menu_item(m, TM_PIN, T(M_PIN), HK_PIN, true);
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    menu_item(m, TM_TOGGLE, pins && !pin_any_visible() ? T(M_SHOW_PINS) : T(M_HIDE_PINS), HK_TOGGLE, pins);
    menu_item(m, TM_CLOSE_PINS, T(M_CLOSE_PINS), 0, pins);
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    menu_item(m, TM_SETTINGS, T(M_SETTINGS), 0, true);
    menu_item(m, TM_HELP, T(M_HELP), 0, true);
    menu_item(m, TM_UPDATE, T(M_UPDATE), 0, true);
    menu_item(m, TM_ABOUT, T(M_ABOUT), 0, true);
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    menu_item(m, TM_EXIT, T(M_EXIT), 0, true);
    SetMenuDefaultItem(m, TM_CAPTURE, FALSE); /* bold: what a left click does */
    SetForegroundWindow(D.hwnd);              /* so the menu closes when clicking elsewhere */
    UINT align = GetSystemMetrics(SM_MENUDROPALIGNMENT) ? TPM_RIGHTALIGN : TPM_LEFTALIGN;
    int cmd = TrackPopupMenu(m, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | align | TPM_BOTTOMALIGN, at.x, at.y,
                             0, D.hwnd, NULL);
    PostMessageW(D.hwnd, WM_NULL, 0, 0);
    DestroyMenu(m);
    switch (cmd) {
    case TM_CAPTURE: /* let the menu's fade-out finish so it is not in the screenshot */
        SetTimer(D.hwnd, TIMER_MENU_CAPTURE, 200, NULL);
        break;
    case TM_PIN:
        pin_clipboard();
        break;
    case TM_TOGGLE:
        pin_toggle_all();
        break;
    case TM_CLOSE_PINS:
        pin_close_all();
        break;
    case TM_SETTINGS:
        settings_open(NULL);
        break;
    case TM_UPDATE:
        settings_open(L"update");
        break;
    case TM_HELP:
        run_helper(L" --shortcuts", false);
        break;
    case TM_ABOUT: {
        WCHAR t[200];
        wsprintfW(t, L"sniplite " SNIPLITE_VERSION L"\n%s\n\nMIT License", T(TAGLINE));
        MessageBoxW(NULL, t, T(M_ABOUT), MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND);
        break;
    }
    case TM_EXIT:
        PostMessageW(D.hwnd, WM_CLOSE, 0, 0);
        break;
    }
}

static LRESULT CALLBACK daemon_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    if (m == D.wm_taskbar && m) { /* Explorer restarted: the icon is gone */
        D.tray_on = false;
        if (D.cfg.tray)
            tray_add();
        return 0;
    }
    switch (m) {
    case WM_APP_TRAY:
        switch (LOWORD(lp)) {
        case NIN_SELECT:
        case NIN_KEYSELECT:
            if (!ov_active())
                ov_begin();
            break;
        case WM_CONTEXTMENU: {
            POINT at = {GET_X_LPARAM(wp), GET_Y_LPARAM(wp)};
            tray_menu(at);
            break;
        }
        case NIN_BALLOONUSERCLICK: /* the "new version" balloon was clicked */
            settings_open(L"update");
            break;
        }
        return 0;
    case WM_TIMER:
        if (wp == TIMER_MENU_CAPTURE) {
            KillTimer(h, TIMER_MENU_CAPTURE);
            if (!ov_active())
                ov_begin();
        } else if (wp == TIMER_UPDATE) { /* the check runs in its own process */
            SetTimer(h, TIMER_UPDATE, UPDATE_EVERY_MS, NULL);
            if (D.cfg.auto_update && D.cfg.tray)
                run_helper(L" --update-check", true);
        }
        return 0;
    case WM_APP_SETTINGS_DONE:
        settings_done();
        return 0;
    case WM_HOTKEY:
        if (wp == HK_CAPTURE) {
            if (!ov_active())
                ov_begin();
        } else if (wp == HK_PIN) {
            if (ov_active())
                ov_pin_hotkey();
            else
                pin_clipboard();
        } else if (wp == HK_TOGGLE) {
            pin_toggle_all();
        }
        return 0;
    case WM_COPYDATA:
        return ipc_handle(h, (HWND)wp, (const COPYDATASTRUCT *)lp);
    case WM_APP_GPU_READY:
        gpu_ready((void *)lp);
        return 0;
    case WM_DISPLAYCHANGE:
        gpu_display_changed();
        return 0;
    case WM_CLOSE:
        ov_cancel();
        pin_close_all();
        tray_remove();
        for (int id = 1; id < HK_COUNT; id++)
            UnregisterHotKey(h, id);
        gpu_stop();
        DestroyWindow(h);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, m, wp, lp);
}

static int daemon_main(HINSTANCE inst, int argc, WCHAR **argv, bool from_cli)
{
    D.inst = inst;
    WCHAR cwd[MAX_PATH * 2];
    if (!GetCurrentDirectoryW(COUNTOF(cwd), cwd))
        cwd[0] = 0;

    /* Wake up fast: above-normal priority, and never put into EcoQoS/efficiency mode.
     * Both cost nothing while idle because the thread sleeps in GetMessage. */
    SetPriorityClass(GetCurrentProcess(), ABOVE_NORMAL_PRIORITY_CLASS);
#ifdef PROCESS_POWER_THROTTLING_CURRENT_VERSION
    PROCESS_POWER_THROTTLING_STATE pt = {PROCESS_POWER_THROTTLING_CURRENT_VERSION,
                                         PROCESS_POWER_THROTTLING_EXECUTION_SPEED, 0};
    SetProcessInformation(GetCurrentProcess(), ProcessPowerThrottling, &pt, sizeof pt);
#endif
    /* Do not keep the caller's directory locked. */
    WCHAR exe_dir[MAX_PATH];
    if (GetModuleFileNameW(NULL, exe_dir, MAX_PATH)) {
        WCHAR *sl = wcsrchr(exe_dir, L'\\');
        if (sl) {
            *sl = 0;
            SetCurrentDirectoryW(exe_dir);
            /* left by an update that had to move running files aside */
            WIN32_FIND_DATAW fd;
            HANDLE fh = FindFirstFileW(L"sniplite.*.old", &fd);
            if (fh != INVALID_HANDLE_VALUE) {
                do
                    if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY))
                        DeleteFileW(fd.cFileName);
                while (FindNextFileW(fh, &fd));
                FindClose(fh);
            }
        }
    }

    WNDCLASSW wc = {0};
    wc.lpfnWndProc = daemon_proc;
    wc.hInstance = inst;
    wc.lpszClassName = DAEMON_CLASS;
    if (!RegisterClassW(&wc))
        return EXIT_FAIL;
    D.hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, DAEMON_CLASS, L"sniplite", WS_POPUP, 0, 0, 0, 0, NULL, NULL, inst, NULL);
    if (!D.hwnd)
        return EXIT_FAIL;
    ChangeWindowMessageFilterEx(D.hwnd, WM_COPYDATA, MSGFLT_ALLOW, NULL);
    D.wm_taskbar = RegisterWindowMessageW(L"TaskbarCreated");
    ChangeWindowMessageFilterEx(D.hwnd, D.wm_taskbar, MSGFLT_ALLOW, NULL);
    if (!ov_init(inst, D.hwnd) || !pin_init(inst, D.hwnd))
        return EXIT_FAIL;

    /* Settings: defaults, then sniplite.ini, then command-line start options
     * (lenient here: invalid ones are reported by the CLI's own start call). */
    bool start = argc == 0 || arg_eq(argv[0], L"start") || argv[0][0] == L'-';
    StartOpts so = {0};
    if (start) {
        WCHAR *tmp[66];
        int tc = 0;
        tmp[tc++] = L"start";
        for (int i = argc > 0 && arg_eq(argv[0], L"start") ? 1 : 0; i < argc && tc < 66; i++)
            tmp[tc++] = argv[i];
        if (!start_opts_parse(tc, tmp, &so, NULL))
            memset(&so, 0, sizeof so);
    }
    Config c;
    config_load(&c);
    for (int id = 1; id < HK_COUNT; id++)
        if (so.set[id]) {
            c.mod[id] = so.mod[id];
            c.vk[id] = so.vk[id];
        }
    if (so.backend)
        c.gdi = so.backend == 2;
    apply_config(&c, true);

    if (!from_cli && !hotkeys_ok()) {
        Str msg = {0};
        str_add(&msg, T(HK_WARN_1));
        status_text(&msg);
        str_add(&msg, T(HK_WARN_2));
        MessageBoxW(NULL, msg.p, L"sniplite", MB_OK | MB_ICONWARNING);
        str_free(&msg);
    }
    if (!start) { /* e.g. `sniplite.exe capture` or `sniplite.exe pin a.png` */
        Str out = {0};
        int code = cmd_run(argc, argv, cwd, &out);
        if (code && out.n && !from_cli)
            MessageBoxW(NULL, out.p, L"sniplite", MB_OK | MB_ICONWARNING);
        str_free(&out);
    }

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return EXIT_OK;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmdline, int show)
{
    (void)prev;
    (void)cmdline;
    (void)show;
    int argc;
    WCHAR **argv = cmdline_split(GetCommandLineW(), &argc);
    if (!argv)
        return EXIT_FAIL;
    lang_init(NULL); /* every mode below talks to the user */
    if (argc > 1 && arg_eq(argv[1], L"--save-dialog"))
        return save_dialog_helper(argc, argv);
    if (argc > 1 && arg_eq(argv[1], L"--settings"))
        return settings_main(inst, argc > 2 ? argv[2] : NULL);
    if (argc > 1 && arg_eq(argv[1], L"--shortcuts"))
        return shortcuts_main(inst);
    if (argc > 1 && arg_eq(argv[1], L"--update-check"))
        return update_check_main();
    if (argc > 1 && arg_eq(argv[1], L"--uninstall"))
        return uninstall_main(argc > 2 && (arg_eq(argv[2], L"/S") || arg_eq(argv[2], L"-S")));

    bool from_cli = false;
    WCHAR *av[64];
    int ac = 0;
    for (int i = 1; i < argc; i++) {
        if (arg_eq(argv[i], L"--daemon"))
            from_cli = true;
        else if (ac < COUNTOF(av))
            av[ac++] = argv[i];
    }

    HANDLE mutex = CreateMutexW(NULL, FALSE, DAEMON_MUTEX);
    if (mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        /* Already running: act as a client. No arguments = start a capture. */
        if (from_cli)
            return EXIT_OK;
        HWND d = NULL;
        for (int i = 0; i < 300 && !(d = ipc_find()); i++)
            Sleep(10);
        if (!d)
            return EXIT_FAIL;
        WCHAR *cap[1] = {L"capture"};
        Str reply = {0};
        int code = ac ? ipc_call(d, ac, av, &reply) : ipc_call(d, 1, cap, &reply);
        if (code != 0 && reply.n)
            MessageBoxW(NULL, reply.p, L"sniplite", MB_OK | MB_ICONWARNING);
        str_free(&reply);
        return code < 0 ? EXIT_FAIL : code;
    }
    int rc = daemon_main(inst, ac, av, from_cli);
    if (mutex)
        CloseHandle(mutex);
    return rc;
}
