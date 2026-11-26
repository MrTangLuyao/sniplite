/* Preferences window: six tabs (general, capture, hotkeys, update, text recognition,
 * about); changes apply immediately.
 *
 * Every change is written to sniplite.ini and the background process is told to
 * reload it (`_reload`), which also reports whether each hotkey could be
 * registered (shown as a green check or red cross). While a hotkey field is
 * recording, the background process releases its hotkeys (`_hotkeys off`) so the
 * keys reach the field. Runs as its own process; nothing here loads into the
 * background process. */
#include "settings.h"
#include "config.h"
#include "draw.h"
#include "image.h"
#include "resource.h"
#include "install.h"
#include "lang.h"
#include "ocr.h"
#include "update.h"
#include "ov_layout.inc"
#include <commctrl.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <windowsx.h>

typedef BOOL(WINAPI *PFN_InitCommonControlsEx)(const INITCOMMONCONTROLSEX *);
typedef HRESULT(WINAPI *PFN_SHGetFolderPathW)(HWND, int, HANDLE, DWORD, LPWSTR);
typedef HINSTANCE(WINAPI *PFN_ShellExecuteW)(HWND, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, INT);
typedef HRESULT(WINAPI *PFN_EnableThemeDialogTexture)(HWND, DWORD);
typedef HRESULT(WINAPI *PFN_DrawThemeParentBackground)(HWND, HDC, const RECT *);

#define HKM_SETKEY (WM_USER + 10) /* wParam = modifiers, lParam = vk */
#define HKN_BEGIN 1               /* field notifications (WM_COMMAND high word) */
#define HKN_DONE 2
#define ETDT_ENABLETAB_ 6

#define WM_APP_UPD_CHECKED (WM_APP + 20)  /* wParam = UpdState */
#define WM_APP_UPD_PROGRESS (WM_APP + 21) /* wParam = percent, or -1 when the size is unknown */
#define WM_APP_UPD_FETCHED (WM_APP + 22)  /* wParam = downloaded */
#define WM_APP_UPD_DONE (WM_APP + 23)     /* wParam = installer exit code */
#define WM_APP_SHOW_PAGE (WM_APP + 24)    /* wParam = page, lParam = begin its download; from a second `--settings <page>` */
#define WM_APP_OCR_PROGRESS (WM_APP + 25) /* wParam = percent */
#define WM_APP_OCR_DONE (WM_APP + 26)     /* wParam = OCR_GET_... */
#define WM_APP_SAVE_FAILED (WM_APP + 27)  /* sniplite.ini could not be written */

enum { PG_GENERAL, PG_CAPTURE, PG_HOTKEYS, PG_UPDATE, PG_OCR, PG_ABOUT, PG_COUNT };
enum { RI_NONE, RI_CLEAR, RI_OK, RI_FAIL, RI_HELP }; /* round icons */

static struct {
    HINSTANCE inst;
    Config cfg;
    HWND dlg, tabs, page[PG_COUNT];
    int state[HK_COUNT]; /* 0 failed, 1 registered or stepping aside, 2 no hotkey */
    PFN_SHGetFolderPathW folder;
    PFN_ShellExecuteW shell_exec;
    PFN_EnableThemeDialogTexture theme_tex;
    PFN_DrawThemeParentBackground theme_bg;
    int start_page;
    bool busy;       /* an update check, download or install is running */
    bool installing; /* the installer is swapping files: keep the window open */
    WCHAR tag[32];   /* newer release found by the check */
    WCHAR setup[MAX_PATH];
    bool reopen;     /* the language changed: show the window again, in that language */
    bool ocr_busy;   /* the text recognition module is being downloaded */
    bool ocr_auto;   /* opened to download it: begin at once */
    bool portable;   /* the program by itself, not installed */
    volatile LONG ocr_cancel;
    POINT at;        /* where it was */
} S;

/* ---- talking to the background process ------------------------------------ */

static void daemon_cmd(const WCHAR *a, const WCHAR *b)
{
    HWND d = ipc_find();
    if (!d)
        return;
    WCHAR *argv[2] = {(WCHAR *)a, (WCHAR *)b};
    Str r = {0};
    if (ipc_call(d, b ? 2 : 1, argv, &r) == 0 && r.p) {
        const WCHAR *p = r.p;
        for (int id = 1; id < HK_COUNT && *p; id++) { /* "1 1 0": per-hotkey state */
            while (*p == L' ')
                p++;
            if (*p >= L'0' && *p <= L'2')
                S.state[id] = *p++ - L'0';
        }
        for (int id = 1; id < HK_COUNT; id++)
            InvalidateRect(GetDlgItem(S.page[PG_HOTKEYS], IDC_HK_STATE1 + id - 1), NULL, FALSE);
    }
    str_free(&r);
}

static void apply(void)
{
    Config f;
    config_load(&f); /* the save dialog's folder is the background process's to change: keep what the file has */
    lstrcpyW(S.cfg.last_dir, f.last_dir);
    if (!config_save(&S.cfg)) /* told by a posted message: this also runs as a hotkey field loses the focus */
        PostMessageW(S.dlg, WM_APP_SAVE_FAILED, 0, 0);
    daemon_cmd(L"_reload", NULL);
}

/* ---- startup shortcut ------------------------------------------------------------- */

static bool startup_link(WCHAR *path)
{
    if (!S.folder || FAILED(S.folder(NULL, CSIDL_STARTUP, NULL, 0, path)))
        return false;
    lstrcatW(path, L"\\sniplite.lnk");
    return true;
}

static bool autostart_set(bool on)
{
    WCHAR link[MAX_PATH + 20];
    if (!startup_link(link))
        return false;
    if (!on)
        return DeleteFileW(link) || GetLastError() == ERROR_FILE_NOT_FOUND;
    WCHAR exe[MAX_PATH], dir[MAX_PATH];
    if (!GetModuleFileNameW(NULL, exe, MAX_PATH))
        return false;
    lstrcpyW(dir, exe);
    WCHAR *sl = wcsrchr(dir, L'\\');
    if (sl)
        *sl = 0;
    IShellLinkW *sh = NULL;
    IPersistFile *pf = NULL;
    bool ok = false;
    if (SUCCEEDED(com_create(&CLSID_ShellLink, &IID_IShellLinkW, (void **)&sh))) {
        IShellLinkW_SetPath(sh, exe);
        IShellLinkW_SetWorkingDirectory(sh, dir);
        IShellLinkW_SetDescription(sh, L"sniplite");
        if (SUCCEEDED(IShellLinkW_QueryInterface(sh, &IID_IPersistFile, (void **)&pf))) {
            ok = SUCCEEDED(IPersistFile_Save(pf, link, TRUE));
            IPersistFile_Release(pf);
        }
        IShellLinkW_Release(sh);
    }
    return ok;
}

static bool autostart_on(void)
{
    WCHAR link[MAX_PATH + 20];
    return startup_link(link) && GetFileAttributesW(link) != INVALID_FILE_ATTRIBUTES;
}

/* ---- hotkey field ------------------------------------------------------------------
 * A flat field showing the key combination. Click (or Space) to record; while
 * recording it shows the modifiers being held and takes the next real key.
 * Esc cancels, Backspace clears. */

typedef struct {
    UINT mod, vk;
    bool rec;
    HFONT font;
} HkField;

static bool is_modifier(UINT vk)
{
    return vk == VK_SHIFT || vk == VK_CONTROL || vk == VK_MENU || vk == VK_LSHIFT || vk == VK_RSHIFT ||
           vk == VK_LCONTROL || vk == VK_RCONTROL || vk == VK_LMENU || vk == VK_RMENU || vk == VK_LWIN || vk == VK_RWIN;
}

static bool ok_without_modifier(UINT vk)
{
    return (vk >= VK_F1 && vk <= VK_F24) || vk == VK_SNAPSHOT || vk == VK_PAUSE || vk == VK_SCROLL ||
           vk == VK_INSERT || vk == VK_DELETE || vk == VK_HOME || vk == VK_END || vk == VK_PRIOR || vk == VK_NEXT ||
           (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9);
}

static UINT held_mods(void)
{
    UINT m = 0;
    if (GetKeyState(VK_CONTROL) < 0) m |= MOD_CONTROL;
    if (GetKeyState(VK_MENU) < 0) m |= MOD_ALT;
    if (GetKeyState(VK_SHIFT) < 0) m |= MOD_SHIFT;
    return m;
}

static void hk_notify(HWND h, int code)
{
    SendMessageW(GetParent(h), WM_COMMAND, MAKEWPARAM(GetDlgCtrlID(h), code), (LPARAM)h);
}

static void hk_record(HWND h, HkField *f, bool on)
{
    if (f->rec == on)
        return;
    f->rec = on;
    InvalidateRect(h, NULL, FALSE);
    hk_notify(h, on ? HKN_BEGIN : HKN_DONE);
}

static void hk_paint(HWND h, HkField *f)
{
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(h, &ps);
    RECT r;
    GetClientRect(h, &r);
    HDC mem = CreateCompatibleDC(dc);
    HBITMAP bmp = CreateCompatibleBitmap(dc, r.right, r.bottom);
    HGDIOBJ ob = SelectObject(mem, bmp);
    COLORREF accent = GetSysColor(COLOR_HIGHLIGHT);
    bool focus = GetFocus() == h;
    HBRUSH bg = CreateSolidBrush(GetSysColor(COLOR_WINDOW));
    FillRect(mem, &r, bg);
    DeleteObject(bg);
    HBRUSH frame = CreateSolidBrush(f->rec ? accent : focus ? RGB(0x80, 0x80, 0x80) : RGB(0xBC, 0xBC, 0xBC));
    FrameRect(mem, &r, frame);
    DeleteObject(frame);
    if (f->rec) { /* underline like a focused field */
        RECT u = {r.left, r.bottom - 2, r.right, r.bottom};
        HBRUSH ub = CreateSolidBrush(accent);
        FillRect(mem, &u, ub);
        DeleteObject(ub);
    }
    WCHAR t[64];
    COLORREF tc = GetSysColor(COLOR_WINDOWTEXT);
    if (f->rec) {
        UINT m = held_mods();
        t[0] = 0;
        if (m) {
            if (m & MOD_CONTROL) lstrcatW(t, L"Ctrl+");
            if (m & MOD_ALT) lstrcatW(t, L"Alt+");
            if (m & MOD_SHIFT) lstrcatW(t, L"Shift+");
        } else {
            lstrcpynW(t, T(HKF_PRESS), COUNTOF(t));
        }
        tc = accent;
    } else if (f->vk) {
        hotkey_format(f->mod, f->vk, t);
    } else {
        lstrcpynW(t, T(UNSET), COUNTOF(t));
        tc = GetSysColor(COLOR_GRAYTEXT);
    }
    HGDIOBJ of = SelectObject(mem, f->font ? (HGDIOBJ)f->font : GetStockObject(DEFAULT_GUI_FONT));
    SetBkMode(mem, TRANSPARENT);
    SetTextColor(mem, tc);
    DrawTextW(mem, t, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    SelectObject(mem, of);
    BitBlt(dc, 0, 0, r.right, r.bottom, mem, 0, 0, SRCCOPY);
    SelectObject(mem, ob);
    DeleteObject(bmp);
    DeleteDC(mem);
    EndPaint(h, &ps);
}

static LRESULT CALLBACK hk_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    HkField *f = (HkField *)GetWindowLongPtrW(h, GWLP_USERDATA);
    if (m == WM_NCCREATE) {
        f = mem_alloc(sizeof *f);
        if (!f)
            return FALSE;
        SetWindowLongPtrW(h, GWLP_USERDATA, (LONG_PTR)f);
    }
    if (!f)
        return DefWindowProcW(h, m, wp, lp);
    switch (m) {
    case WM_NCDESTROY:
        SetWindowLongPtrW(h, GWLP_USERDATA, 0);
        mem_free(f);
        return 0;
    case WM_SETFONT:
        f->font = (HFONT)wp;
        return 0;
    case WM_GETFONT:
        return (LRESULT)f->font;
    case WM_GETDLGCODE: /* while recording, every key (Tab, Esc, Enter...) is ours */
        return f->rec ? DLGC_WANTALLKEYS : DLGC_WANTCHARS;
    case WM_LBUTTONDOWN:
        SetFocus(h);
        hk_record(h, f, true);
        return 0;
    case WM_SETFOCUS:
        InvalidateRect(h, NULL, FALSE);
        return 0;
    case WM_KILLFOCUS:
        hk_record(h, f, false); /* clicking elsewhere cancels */
        InvalidateRect(h, NULL, FALSE);
        return 0;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN: {
        UINT vk = (UINT)wp, mods = held_mods();
        if (!f->rec) {
            if (vk == VK_SPACE || vk == VK_RETURN) {
                hk_record(h, f, true);
                return 0;
            }
            break;
        }
        if (is_modifier(vk)) {
            InvalidateRect(h, NULL, FALSE);
            return 0;
        }
        if (!mods && vk == VK_ESCAPE) {
            hk_record(h, f, false);
            return 0;
        }
        if (!mods && vk == VK_BACK) {
            f->mod = f->vk = 0;
            hk_record(h, f, false);
            return 0;
        }
        WCHAR name[40];
        hotkey_format(0, vk, name); /* empty for a key the settings file has no name for */
        if ((!mods && !ok_without_modifier(vk)) || !name[0]) { /* a lone letter would hijack typing */
            MessageBeep(MB_OK);
            return 0;
        }
        f->mod = mods;
        f->vk = vk;
        hk_record(h, f, false);
        return 0;
    }
    case WM_KEYUP:
    case WM_SYSKEYUP:
        if (!f->rec)
            break;
        if (wp == VK_SNAPSHOT) { /* Print Screen only ever arrives as key-up */
            f->mod = held_mods();
            f->vk = VK_SNAPSHOT;
            hk_record(h, f, false);
        } else {
            InvalidateRect(h, NULL, FALSE);
        }
        return 0;
    case WM_CHAR:
    case WM_SYSCHAR:
    case WM_DEADCHAR:
    case WM_SYSDEADCHAR:
        if (f->rec || m == WM_CHAR)
            return 0;
        break;
    case HKM_SETKEY:
        f->mod = (UINT)wp;
        f->vk = (UINT)lp;
        InvalidateRect(h, NULL, FALSE);
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT:
        hk_paint(h, f);
        return 0;
    }
    return DefWindowProcW(h, m, wp, lp);
}

/* ---- small round icons (clear / ok / failed / help), anti-aliased ----------------- */

static void draw_round_icon(const DRAWITEMSTRUCT *di, int kind)
{
    RECT r = di->rcItem;
    int w = r.right - r.left, h = r.bottom - r.top;
    if (S.theme_bg)
        S.theme_bg(di->hwndItem, di->hDC, &r);
    else
        FillRect(di->hDC, &r, GetSysColorBrush(COLOR_BTNFACE));
    Img im;
    if (kind == RI_NONE || !img_create(&im, w, h))
        return;
    BitBlt(im.dc, 0, 0, w, h, di->hDC, r.left, r.top, SRCCOPY); /* start from the page background */
    Surf s = surf_img(&im, 0, 0);
    float cx = (float)w * 0.5f, cy = (float)h * 0.5f, rad = (float)MINI(w, h) * 0.5f - 0.5f;
    float k = rad * 0.4f, lw = rad * 0.24f < 1.2f ? 1.2f : rad * 0.24f;
    bool pressed = (di->itemState & ODS_SELECTED) != 0;
    switch (kind) {
    case RI_CLEAR:
        d_disc(&s, cx, cy, rad, pressed ? 0x303030 : 0x5C5C5C, 255);
        d_line(&s, cx - k, cy - k, cx + k, cy + k, lw, 0xFFFFFF, 255);
        d_line(&s, cx + k, cy - k, cx - k, cy + k, lw, 0xFFFFFF, 255);
        break;
    case RI_OK: {
        float p[] = {cx - rad * 0.45f, cy + rad * 0.02f, cx - rad * 0.1f, cy + rad * 0.36f, cx + rad * 0.48f, cy - rad * 0.32f};
        d_disc(&s, cx, cy, rad, 0x22A04B, 255);
        d_polyline(&s, p, 3, lw, 0xFFFFFF, 255, false);
        break;
    }
    case RI_FAIL:
        d_disc(&s, cx, cy, rad, 0xE0443E, 255);
        d_line(&s, cx - k, cy - k, cx + k, cy + k, lw, 0xFFFFFF, 255);
        d_line(&s, cx + k, cy - k, cx - k, cy + k, lw, 0xFFFFFF, 255);
        break;
    case RI_HELP:
        d_ellipse(&s, cx, cy, rad - 0.6f, rad - 0.6f, 1.2f, pressed ? 0x303030 : 0x606060, 255);
        break;
    }
    if (kind == RI_HELP) {
        SetBkMode(im.dc, TRANSPARENT);
        SetTextColor(im.dc, pressed ? RGB(0x30, 0x30, 0x30) : RGB(0x60, 0x60, 0x60));
        HGDIOBJ of = SelectObject(im.dc, (HGDIOBJ)SendMessageW(di->hwndItem, WM_GETFONT, 0, 0));
        RECT tr = {0, 0, w, h};
        DrawTextW(im.dc, L"?", 1, &tr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        SelectObject(im.dc, of);
    }
    GdiFlush();
    BitBlt(di->hDC, r.left, r.top, w, h, im.dc, 0, 0, SRCCOPY);
    img_destroy(&im);
    if ((di->itemState & ODS_FOCUS) && di->CtlType == ODT_BUTTON)
        DrawFocusRect(di->hDC, &r);
}

/* ---- pages ---------------------------------------------------------------------------- */

/* the default save location: the chosen folder, else the desktop */
static void show_save_dir(void)
{
    WCHAR dir[MAX_PATH];
    lstrcpynW(dir, S.cfg.save_dir, MAX_PATH);
    if (!dir[0] && (!S.folder || FAILED(S.folder(NULL, CSIDL_DESKTOPDIRECTORY, NULL, 0, dir))))
        dir[0] = 0;
    SetDlgItemTextW(S.page[PG_CAPTURE], IDC_SAVE_DIR, dir);
}

/* the recording location: its own folder, or a note that it follows the one above */
static void show_rec_dir(void)
{
    SetDlgItemTextW(S.page[PG_CAPTURE], IDC_REC_DIR, S.cfg.rec_dir[0] ? S.cfg.rec_dir : T(C_REC_SAME));
}

/* the file names to choose from, each shown as the name it gives right now */
static void show_names(void)
{
    SYSTEMTIME now;
    GetLocalTime(&now);
    for (int i = 0; i < NAME_COUNT; i++) {
        WCHAR t[NAME_CAP];
        name_format(i, &now, t);
        SendDlgItemMessageW(S.page[PG_CAPTURE], IDC_NAME, CB_ADDSTRING, 0, (LPARAM)t);
    }
    SendDlgItemMessageW(S.page[PG_CAPTURE], IDC_NAME, CB_SETCURSEL, (WPARAM)S.cfg.name, 0);
}

/* Windows' picker of a folder, or of a program; false when nothing was picked */
static bool pick_path(HWND owner, WCHAR *out, int cap, bool program)
{
    IFileOpenDialog *d = NULL;
    IShellItem *item = NULL;
    WCHAR *path = NULL;
    bool ok = false;
    if (FAILED(com_create(&CLSID_FileOpenDialog, &IID_IFileOpenDialog, (void **)&d)))
        return false;
    DWORD opt = 0;
    IFileOpenDialog_GetOptions(d, &opt);
    if (program) {
        COMDLG_FILTERSPEC f = {T(APPS_FILTER), L"*.exe"};
        IFileOpenDialog_SetFileTypes(d, 1, &f);
    } else {
        opt |= FOS_PICKFOLDERS;
    }
    IFileOpenDialog_SetOptions(d, opt | FOS_FORCEFILESYSTEM);
    if (SUCCEEDED(IFileOpenDialog_Show(d, owner)) && SUCCEEDED(IFileOpenDialog_GetResult(d, &item))) {
        if (SUCCEEDED(IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &path))) {
            ok = lstrlenW(path) < cap;
            if (ok)
                lstrcpyW(out, path);
            /* ole32 is here: com_create loaded it */
            void(WINAPI * release)(void *) = (void(WINAPI *)(void *))(void *)GetProcAddress(GetModuleHandleW(L"ole32.dll"), "CoTaskMemFree");
            if (release)
                release(path);
        }
        IShellItem_Release(item);
    }
    IFileOpenDialog_Release(d);
    return ok;
}

static void show_hotkeys(void)
{
    for (int id = 1; id < HK_COUNT; id++)
        SendDlgItemMessageW(S.page[PG_HOTKEYS], IDC_HK_FIELD1 + id - 1, HKM_SETKEY, S.cfg.mod[id], S.cfg.vk[id]);
}

/* ---- the programs the hotkeys step aside for: a list like the one Windows has for a path ---- */

typedef BOOL(WINAPI *PFN_SetWindowTheme)(HWND, LPCWSTR, LPCWSTR);

/* a list view as Explorer draws one, the whole row selected */
static void list_look(HWND list, DWORD more)
{
    HMODULE ux = GetModuleHandleW(L"uxtheme.dll");
    PFN_SetWindowTheme set_theme = ux ? (PFN_SetWindowTheme)(void *)GetProcAddress(ux, "SetWindowTheme") : NULL;
    if (set_theme)
        set_theme(list, L"Explorer", NULL);
    SendMessageW(list, LVM_SETEXTENDEDLISTVIEWSTYLE, 0, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER | more);
}

static WCHAR *apps_text; /* what the text window edits */

static int apps_sel(HWND list) { return (int)SendMessageW(list, LVM_GETNEXTITEM, (WPARAM)-1, LVNI_SELECTED); }

static void apps_select(HWND list, int i)
{
    LVITEMW it = {0};
    it.stateMask = it.state = LVIS_SELECTED | LVIS_FOCUSED;
    SendMessageW(list, LVM_SETITEMSTATE, (WPARAM)i, (LPARAM)&it);
    SendMessageW(list, LVM_ENSUREVISIBLE, (WPARAM)i, FALSE);
}

static int apps_add(HWND list, const WCHAR *name)
{
    LVITEMW it = {0};
    it.mask = LVIF_TEXT;
    it.iItem = INT_MAX;
    it.pszText = (WCHAR *)name;
    return (int)SendMessageW(list, LVM_INSERTITEMW, 0, (LPARAM)&it);
}

/* s, names with | between them, as the rows of the list */
static void apps_fill(HWND list, const WCHAR *s)
{
    SendMessageW(list, LVM_DELETEALLITEMS, 0, 0);
    for (const WCHAR *e; *s; s = *e ? e + 1 : e) {
        while (*s == L' ')
            s++;
        for (e = s; *e && *e != L'|'; e++) {
        }
        int n = (int)(e - s);
        while (n && s[n - 1] == L' ')
            n--;
        WCHAR name[MAX_PATH];
        if (n && n < MAX_PATH) {
            lstrcpynW(name, s, n + 1);
            apps_add(list, name);
        }
    }
}

/* the rows back as one text; false when they do not fit */
static bool apps_join(HWND list, WCHAR *out, int cap)
{
    int n = 0, rows = (int)SendMessageW(list, LVM_GETITEMCOUNT, 0, 0);
    out[0] = 0;
    for (int i = 0; i < rows; i++) {
        WCHAR name[MAX_PATH];
        LVITEMW it = {0};
        it.pszText = name;
        it.cchTextMax = MAX_PATH;
        int len = (int)SendMessageW(list, LVM_GETITEMTEXTW, (WPARAM)i, (LPARAM)&it);
        if (!len)
            continue;
        if (n + !!n + len >= cap)
            return false;
        if (n)
            out[n++] = L'|';
        lstrcpyW(out + n, name);
        n += len;
    }
    return true;
}

static void apps_edit_row(HWND list, int i)
{
    if (i < 0)
        return;
    SetFocus(list);
    SendMessageW(list, LVM_EDITLABELW, (WPARAM)i, 0);
}

/* row i goes; the one that takes its place, or the last, is selected */
static void apps_delete(HWND list, int i)
{
    if (i < 0)
        return;
    SendMessageW(list, LVM_DELETEITEM, (WPARAM)i, 0);
    int rows = (int)SendMessageW(list, LVM_GETITEMCOUNT, 0, 0);
    if (rows)
        apps_select(list, i < rows ? i : rows - 1);
}

/* a program picked in Windows' file window: its file name, once */
static void apps_browse(HWND h, HWND list)
{
    WCHAR path[MAX_PATH];
    if (!pick_path(h, path, MAX_PATH, true))
        return;
    const WCHAR *name = wcsrchr(path, L'\\');
    LVFINDINFOW find = {LVFI_STRING, name ? name + 1 : path};
    int i = (int)SendMessageW(list, LVM_FINDITEMW, (WPARAM)-1, (LPARAM)&find);
    apps_select(list, i >= 0 ? i : apps_add(list, find.psz));
}

static INT_PTR CALLBACK apps_text_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    (void)lp;
    if (m == WM_INITDIALOG) {
        SetWindowTextW(h, T(APPS_TITLE));
        SetDlgItemTextW(h, IDC_APPS_TEXT_LABEL, T(APPS_TEXT_LABEL));
        SetDlgItemTextW(h, IDOK, T(OK_BTN));
        SetDlgItemTextW(h, IDCANCEL, T(O_CANCEL_BTN));
        SendDlgItemMessageW(h, IDC_APPS_TEXT_EDIT, EM_LIMITTEXT, COUNTOF(S.cfg.block_apps) - 1, 0);
        SetDlgItemTextW(h, IDC_APPS_TEXT_EDIT, apps_text);
        return TRUE;
    }
    if (m == WM_COMMAND && (LOWORD(wp) == IDOK || LOWORD(wp) == IDCANCEL)) {
        if (LOWORD(wp) == IDOK)
            GetDlgItemTextW(h, IDC_APPS_TEXT_EDIT, apps_text, COUNTOF(S.cfg.block_apps));
        EndDialog(h, LOWORD(wp));
        return TRUE;
    }
    return FALSE;
}

static INT_PTR CALLBACK apps_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    static const struct {
        unsigned short id, s;
    } kButtons[] = {{IDC_APPS_NEW, S_APPS_NEW},       {IDC_APPS_EDIT, S_APPS_EDIT}, {IDC_APPS_BROWSE, S_APPS_BROWSE},
                    {IDC_APPS_DELETE, S_APPS_DELETE}, {IDC_APPS_TEXT, S_APPS_TEXT}, {IDOK, S_OK_BTN},
                    {IDCANCEL, S_O_CANCEL_BTN}};
    HWND list = GetDlgItem(h, IDC_LIST);
    switch (m) {
    case WM_INITDIALOG: {
        SetWindowTextW(h, T(APPS_TITLE));
        for (int i = 0; i < COUNTOF(kButtons); i++)
            SetDlgItemTextW(h, kButtons[i].id, g_tr[kButtons[i].s]);
        list_look(list, LVS_EX_GRIDLINES);
        LVCOLUMNW col = {0};
        col.mask = LVCF_WIDTH;
        SendMessageW(list, LVM_INSERTCOLUMNW, 0, (LPARAM)&col);
        SendMessageW(list, LVM_SETCOLUMNWIDTH, 0, LVSCW_AUTOSIZE_USEHEADER);
        apps_fill(list, S.cfg.block_apps);
        if (SendMessageW(list, LVM_GETITEMCOUNT, 0, 0))
            apps_select(list, 0);
        return TRUE;
    }
    case WM_NOTIFY: {
        const NMHDR *n = (const NMHDR *)lp;
        if (n->idFrom != IDC_LIST)
            break;
        if (n->code == NM_DBLCLK)
            apps_edit_row(list, ((const NMITEMACTIVATE *)lp)->iItem);
        else if (n->code == LVN_KEYDOWN && ((const NMLVKEYDOWN *)lp)->wVKey == VK_DELETE)
            apps_delete(list, apps_sel(list));
        else if (n->code == LVN_KEYDOWN && ((const NMLVKEYDOWN *)lp)->wVKey == VK_F2)
            apps_edit_row(list, apps_sel(list));
        else if (n->code == LVN_BEGINLABELEDITW)
            SendMessageW((HWND)SendMessageW(list, LVM_GETEDITCONTROL, 0, 0), EM_LIMITTEXT, MAX_PATH - 1, 0);
        else if (n->code == LVN_ENDLABELEDITW) { /* the row keeps what was typed, trimmed; an empty row goes */
            const NMLVDISPINFOW *d = (const NMLVDISPINFOW *)lp;
            WCHAR name[MAX_PATH], *t = name;
            LVITEMW it = {0};
            it.pszText = name;
            it.cchTextMax = MAX_PATH;
            if (d->item.pszText)
                lstrcpynW(name, d->item.pszText, MAX_PATH);
            else
                SendMessageW(list, LVM_GETITEMTEXTW, (WPARAM)d->item.iItem, (LPARAM)&it);
            while (*t == L' ')
                t++;
            for (int k = lstrlenW(t); k && t[k - 1] == L' ';)
                t[--k] = 0;
            it.pszText = t;
            if (*t)
                SendMessageW(list, LVM_SETITEMTEXTW, (WPARAM)d->item.iItem, (LPARAM)&it);
            else
                apps_delete(list, d->item.iItem);
        }
        SetWindowLongPtrW(h, DWLP_MSGRESULT, FALSE);
        return TRUE;
    }
    case WM_COMMAND:
        if (HIWORD(wp) != BN_CLICKED)
            break;
        if (SendMessageW(list, LVM_GETEDITCONTROL, 0, 0)) { /* Enter or Esc ends the editing of a row */
            if (LOWORD(wp) == IDCANCEL)
                SendMessageW(list, LVM_CANCELEDITLABEL, 0, 0);
            else
                SetFocus(list);
            if (LOWORD(wp) == IDOK || LOWORD(wp) == IDCANCEL)
                return TRUE;
        }
        switch (LOWORD(wp)) {
        case IDC_APPS_NEW: {
            int i = apps_add(list, L"");
            apps_select(list, i);
            apps_edit_row(list, i);
            break;
        }
        case IDC_APPS_EDIT:
            apps_edit_row(list, apps_sel(list));
            break;
        case IDC_APPS_BROWSE:
            apps_browse(h, list);
            break;
        case IDC_APPS_DELETE:
            apps_delete(list, apps_sel(list));
            break;
        case IDC_APPS_TEXT: {
            WCHAR t[COUNTOF(S.cfg.block_apps)];
            apps_join(list, t, COUNTOF(t));
            apps_text = t;
            if (lang_dialog_box(S.inst, IDD_APPS_TEXT, h, apps_text_proc) == IDOK)
                apps_fill(list, t);
            break;
        }
        case IDOK: {
            WCHAR t[COUNTOF(S.cfg.block_apps)];
            if (!apps_join(list, t, COUNTOF(t))) {
                MessageBeep(MB_ICONWARNING);
                break;
            }
            if (lstrcmpW(t, S.cfg.block_apps)) {
                lstrcpyW(S.cfg.block_apps, t);
                apply();
            }
            EndDialog(h, IDOK);
            break;
        }
        case IDCANCEL:
            EndDialog(h, IDCANCEL);
            break;
        }
        return TRUE;
    case WM_CLOSE:
        EndDialog(h, IDCANCEL);
        return TRUE;
    }
    return FALSE;
}

/* ---- shortcut list: short and plain, the few keys people actually use ------------- */

/* One row: what it does, and its keys. The keys are a fixed name (the same in every
 * language), else a text, else the global hotkey `hk` as it is set. */
typedef struct {
    int group; /* 0..2: S_SC_G_CAPTURE + group */
    int what;  /* S_... */
    const WCHAR *keys;
    int keys_s; /* S_..., 0: none */
    int hk;
} Shortcut;

static const Shortcut kShortcuts[] = {
    {0, S_SC_START, NULL, 0, HK_CAPTURE},
    {0, S_SC_QUICK, NULL, 0, HK_QUICK},
    {0, S_SC_PICKER, NULL, 0, HK_PICK},
    {0, S_SC_WINDOW, NULL, S_K_CLICK, 0},
    {0, S_SC_COPY, NULL, S_K_ENTER_DBL, 0},
    {0, S_SC_SAVE, L"Ctrl+S", 0, 0},
    {0, S_SC_PIN, L"Ctrl+T", 0, 0},
    {0, S_SC_OCR, L"Ctrl+O", 0, 0},
    {0, S_PM_OCR, L"Ctrl+Shift+C", 0, 0},
    {0, S_SC_LONG, L"Ctrl+L", 0, 0},
    {0, S_SC_REC, L"Ctrl+R", 0, 0},
    {0, S_SC_UNDO, L"Ctrl+Z", 0, 0},
    {0, S_SC_CANCEL, L"Esc", 0, 0},
    {1, S_SC_PIN_CLIP, NULL, 0, HK_PIN},
    {1, S_SC_ZOOM, NULL, S_K_WHEEL, 0},
    {1, S_SC_OPACITY, NULL, S_K_CTRL_WHEEL, 0},
    {1, S_SC_CLOSE, NULL, S_K_DBL_ESC, 0},
    {2, S_SC_GROW, NULL, S_K_WHEEL_CAP, 0},
    {2, S_SC_NUDGE, NULL, S_K_ARROWS, 0},
    {2, S_SC_NUDGE10, NULL, S_K_SHIFT_SAME, 0},
    {2, S_SC_COLOR, NULL, S_K_C_CAP, 0},
};

static void fill_shortcuts(HWND list)
{
    list_look(list, 0);
    LVCOLUMNW col = {0};
    col.mask = LVCF_TEXT | LVCF_WIDTH;
    col.cx = 100;
    col.pszText = L"";
    SendMessageW(list, LVM_INSERTCOLUMNW, 0, (LPARAM)&col);
    col.pszText = L"";
    SendMessageW(list, LVM_INSERTCOLUMNW, 1, (LPARAM)&col);
    SendMessageW(list, LVM_ENABLEGROUPVIEW, TRUE, 0);
    for (int g = 0; g < 3; g++) {
        LVGROUP lg = {0};
        lg.cbSize = sizeof lg;
        lg.mask = LVGF_HEADER | LVGF_GROUPID;
        lg.pszHeader = (WCHAR *)g_tr[S_SC_G_CAPTURE + g];
        lg.iGroupId = g;
        SendMessageW(list, LVM_INSERTGROUP, (WPARAM)-1, (LPARAM)&lg);
    }
    for (int i = 0; i < COUNTOF(kShortcuts); i++) {
        const Shortcut *s = &kShortcuts[i];
        WCHAR keys[40];
        if (s->keys || s->keys_s)
            lstrcpynW(keys, s->keys ? s->keys : g_tr[s->keys_s], COUNTOF(keys));
        else if (S.cfg.vk[s->hk])
            hotkey_format(S.cfg.mod[s->hk], S.cfg.vk[s->hk], keys);
        else
            lstrcpynW(keys, T(SC_UNSET), COUNTOF(keys));
        LVITEMW it = {0};
        it.mask = LVIF_TEXT | LVIF_GROUPID;
        it.iItem = i;
        it.iGroupId = s->group;
        it.pszText = (WCHAR *)g_tr[s->what];
        int row = (int)SendMessageW(list, LVM_INSERTITEMW, 0, (LPARAM)&it);
        it.mask = LVIF_TEXT;
        it.iItem = row;
        it.iSubItem = 1;
        it.pszText = keys;
        SendMessageW(list, LVM_SETITEMTEXTW, (WPARAM)row, (LPARAM)&it);
    }
    RECT rc;
    GetClientRect(list, &rc);
    int w0 = (rc.right - rc.left) * 11 / 20;
    SendMessageW(list, LVM_SETCOLUMNWIDTH, 0, w0);
    SendMessageW(list, LVM_SETCOLUMNWIDTH, 1, rc.right - rc.left - w0 - GetSystemMetrics(SM_CXVSCROLL));
}

static INT_PTR CALLBACK shortcuts_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    (void)lp;
    if (m == WM_INITDIALOG) {
        HICON small = LoadImageW(S.inst, MAKEINTRESOURCEW(IDI_APP), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                 GetSystemMetrics(SM_CYSMICON), 0);
        SendMessageW(h, WM_SETICON, ICON_SMALL, (LPARAM)small);
        SetPropW(h, SHORTCUTS_MARK, (HANDLE)1);
        SetWindowTextW(h, T(SHORTCUTS_TITLE));
        SetDlgItemTextW(h, IDOK, T(OK_BTN));
        fill_shortcuts(GetDlgItem(h, IDC_LIST));
        SetForegroundWindow(h);
        return TRUE;
    }
    if (m == WM_DESTROY)
        RemovePropW(h, SHORTCUTS_MARK);
    if ((m == WM_COMMAND && (LOWORD(wp) == IDOK || LOWORD(wp) == IDCANCEL)) || m == WM_CLOSE) {
        EndDialog(h, 0);
        return TRUE;
    }
    return FALSE;
}

static void show_help(HWND owner)
{
    lang_dialog_box(S.inst, IDD_SHORTCUTS, owner, shortcuts_proc);
}

/* ---- update page: check, download, install (each step on a worker thread) ---------- */

static UpdateResult g_upd;
static bool g_relaunch; /* updated: reopen this window from the new exe */

static void upd_status(const WCHAR *t)
{
    SetDlgItemTextW(S.page[PG_UPDATE], IDC_U_STATUS, t);
}

static void upd_buttons(bool check, bool install)
{
    HWND u = S.page[PG_UPDATE], f = GetFocus();
    if ((!check && f == GetDlgItem(u, IDC_U_CHECK)) || (!install && f == GetDlgItem(u, IDC_U_INSTALL)))
        SendMessageW(S.dlg, WM_NEXTDLGCTL, (WPARAM)GetDlgItem(u, IDC_U_AUTO), TRUE); /* keep Esc/Tab working */
    EnableWindow(GetDlgItem(u, IDC_U_CHECK), check);
    ShowWindow(GetDlgItem(u, IDC_U_INSTALL), install ? SW_SHOW : SW_HIDE);
    EnableWindow(GetDlgItem(u, IDC_U_INSTALL), install);
}

static bool upd_run(LPTHREAD_START_ROUTINE fn)
{
    HANDLE t = CreateThread(NULL, 0, fn, NULL, 0, NULL);
    if (!t)
        return false;
    CloseHandle(t);
    S.busy = true;
    return true;
}

static DWORD WINAPI check_thread(void *p)
{
    (void)p;
    update_check(&g_upd);
    PostMessageW(S.dlg, WM_APP_UPD_CHECKED, (WPARAM)g_upd.state, 0);
    return 0;
}

static void upd_check(void)
{
    if (S.busy || S.portable)
        return;
    upd_buttons(false, false);
    upd_status(T(U_CHECKING));
    if (!upd_run(check_thread)) {
        upd_status(T(U_CHECK_FAILED));
        upd_buttons(true, false);
    }
}

static void upd_checked(int state)
{
    S.busy = false;
    WCHAR t[96];
    switch (state) {
    case UPD_NEWER:
        lstrcpynW(S.tag, g_upd.tag, COUNTOF(S.tag));
        wsprintfW(t, T(U_NEWER), S.tag);
        upd_status(t);
        upd_buttons(true, true);
        return;
    case UPD_LATEST:
        upd_status(T(U_LATEST));
        break;
    case UPD_NONE:
        upd_status(T(U_NONE));
        break;
    default:
        upd_status(T(U_NET_FAILED));
        break;
    }
    upd_buttons(true, false);
}

static void fetch_progress(int pct, void *ctx)
{
    static int last = -2;
    (void)ctx;
    if (pct != last) {
        last = pct;
        PostMessageW(S.dlg, WM_APP_UPD_PROGRESS, (WPARAM)pct, 0);
    }
}

static DWORD WINAPI fetch_thread(void *p)
{
    (void)p;
    bool ok = update_download(S.tag, S.setup, COUNTOF(S.setup), fetch_progress, NULL);
    PostMessageW(S.dlg, WM_APP_UPD_FETCHED, ok, 0);
    return 0;
}

/* The installer (/update) closes the background process, swaps the files (a running
 * exe like this one is moved aside) and starts sniplite again. */
static DWORD WINAPI install_thread(void *proc)
{
    DWORD code = 1;
    WaitForSingleObject((HANDLE)proc, 120000);
    if (!GetExitCodeProcess((HANDLE)proc, &code) || code == STILL_ACTIVE)
        code = 1;
    CloseHandle((HANDLE)proc);
    PostMessageW(S.dlg, WM_APP_UPD_DONE, code, 0);
    return 0;
}

/* Number of pins on screen; updating restarts sniplite, which closes them. */
static int daemon_pins(void)
{
    HWND d = ipc_find();
    int n = 0;
    if (d) {
        WCHAR *argv[2] = {L"status", L"--json"};
        Str r = {0};
        const WCHAR *p = ipc_call(d, 2, argv, &r) == 0 && r.p ? wcsstr(r.p, L"\"pins\":") : NULL;
        if (p)
            for (p += 7; *p >= L'0' && *p <= L'9' && n < 100000; p++)
                n = n * 10 + (*p - L'0');
        str_free(&r);
    }
    return n;
}

static void upd_install(void)
{
    if (S.busy || !S.tag[0])
        return;
    if (daemon_pins() > 0 &&
        MessageBoxW(S.dlg, T(U_CONFIRM), T(SETTINGS_TITLE), MB_OKCANCEL | MB_ICONQUESTION) != IDOK)
        return;
    upd_buttons(false, false);
    upd_status(T(U_DOWNLOADING));
    if (!upd_run(fetch_thread)) {
        upd_status(T(U_DOWNLOAD_FAILED));
        upd_buttons(true, true);
    }
}

static void upd_fetched(bool ok)
{
    if (!ok) {
        S.busy = false;
        upd_status(T(U_DOWNLOAD_FAILED));
        upd_buttons(true, true);
        return;
    }
    upd_status(T(U_INSTALLING));
    Str cmd = {0};
    update_setup_cmd(&cmd, S.setup);
    STARTUPINFOW si = {sizeof si};
    PROCESS_INFORMATION pi;
    HANDLE t = NULL;
    S.installing = true;
    if (cmd.p && CreateProcessW(S.setup, cmd.p, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hThread);
        t = CreateThread(NULL, 0, install_thread, pi.hProcess, 0, NULL);
        if (t)
            CloseHandle(t);
        else
            CloseHandle(pi.hProcess);
    }
    str_free(&cmd);
    if (!t) {
        S.busy = S.installing = false;
        DeleteFileW(S.setup);
        upd_status(T(U_INSTALL_FAILED));
        upd_buttons(true, true);
    }
}

static void upd_done(DWORD code)
{
    S.busy = S.installing = false;
    DeleteFileW(S.setup);
    if (code == 0) {
        g_relaunch = true;
        EndDialog(S.dlg, 0);
        return;
    }
    upd_status(T(U_INSTALL_FAILED));
    upd_buttons(true, true);
}

/* ---- text recognition page: the optional module, downloaded on a worker thread ------ */

static void ocr_show(void)
{
    HWND o = S.page[PG_OCR], f = GetFocus();
    bool packed = !ocr_installed() && ocr_packed(); /* in the program itself, unpacked when first used */
    bool there = ocr_installed() || packed;
    WCHAR t[160];
    if (there)
        wsprintfW(t, T(O_STATE_OK), ocr_size_mb());
    else
        lstrcpynW(t, T(O_STATE_NONE), COUNTOF(t));
    SetDlgItemTextW(o, IDC_O_STATE, t);
    SetDlgItemTextW(o, IDC_O_INSTALL, S.ocr_busy ? T(O_CANCEL_BTN) : T(O_INSTALL_BTN));
    bool install = !S.portable && (S.ocr_busy ? !S.ocr_cancel : !there), remove = !S.portable && !S.ocr_busy && there && !packed;
    if ((!install && f == GetDlgItem(o, IDC_O_INSTALL)) || (!remove && f == GetDlgItem(o, IDC_O_REMOVE)))
        SendMessageW(S.dlg, WM_NEXTDLGCTL, (WPARAM)S.tabs, TRUE); /* keep Esc/Tab working */
    EnableWindow(GetDlgItem(o, IDC_O_INSTALL), install);
    EnableWindow(GetDlgItem(o, IDC_O_REMOVE), remove);
    ShowWindow(GetDlgItem(o, IDC_O_BAR), S.ocr_busy ? SW_SHOW : SW_HIDE);
}

static void ocr_progress(int pct, void *ctx)
{
    (void)ctx;
    PostMessageW(S.dlg, WM_APP_OCR_PROGRESS, (WPARAM)pct, 0);
}

static DWORD WINAPI ocr_thread(void *p)
{
    (void)p;
    int r = ocr_get(&S.ocr_cancel, ocr_progress, NULL);
    PostMessageW(S.dlg, WM_APP_OCR_DONE, (WPARAM)r, 0);
    return 0;
}

static void ocr_install(void)
{
    if (S.ocr_busy) { /* the button says Cancel now */
        InterlockedExchange(&S.ocr_cancel, 1);
        ocr_show();
        return;
    }
    if (S.portable || ocr_installed())
        return;
    S.ocr_cancel = 0;
    HANDLE t = CreateThread(NULL, 0, ocr_thread, NULL, 0, NULL);
    if (!t)
        return;
    CloseHandle(t);
    S.ocr_busy = true;
    SendDlgItemMessageW(S.page[PG_OCR], IDC_O_BAR, PBM_SETPOS, 0, 0);
    SetDlgItemTextW(S.page[PG_OCR], IDC_O_STATUS, T(U_DOWNLOADING));
    ocr_show();
}

static void ocr_done(int result)
{
    S.ocr_busy = false;
    S.ocr_cancel = 0;
    SetDlgItemTextW(S.page[PG_OCR], IDC_O_STATUS,
                    result == OCR_GET_NET ? T(U_DOWNLOAD_FAILED) : result == OCR_GET_CHECK ? T(O_CHECK_FAILED)
                    : result == OCR_GET_WRITE ? T(O_WRITE_FAILED) : L"");
    ocr_show();
    if (result == OCR_GET_OK)
        daemon_cmd(L"_reload", NULL); /* its toolbar gets the text buttons */
}

static void ensure_ini(WCHAR *path)
{
    config_path(path, MAX_PATH);
    if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES)
        config_save(&S.cfg);
}

/* Another language: keep it, tell the background process, and show this window
 * again in it, where it was. A dialog is laid out once, for the font it is created
 * with, so it is not changed in place. */
static void set_language(int lang)
{
    lang_choose(lang);
    apply();
    RECT rc;
    GetWindowRect(S.dlg, &rc);
    S.at.x = rc.left;
    S.at.y = rc.top;
    S.reopen = true;
    EndDialog(S.dlg, 0);
}

static void page_command(HWND page, int id, int code, HWND ctl)
{
    WCHAR path[MAX_PATH], arg[MAX_PATH + 16];
    if (id == IDC_LANG) {
        int lang = (int)SendMessageW(ctl, CB_GETCURSEL, 0, 0) - 1; /* the first entry is LG_AUTO */
        if (code != CBN_SELCHANGE || lang == lang_choice())
            return;
        if (S.busy || S.ocr_busy) /* a worker thread is about to report to this window */
            SendMessageW(ctl, CB_SETCURSEL, (WPARAM)(lang_choice() + 1), 0);
        else
            set_language(lang);
        return;
    }
    int *choice = id == IDC_THEME ? &S.cfg.theme : id == IDC_DETECT ? &S.cfg.detect : id == IDC_NAME ? &S.cfg.name : NULL;
    if (choice) { /* a list of a setting's values, in their order */
        int i = (int)SendMessageW(ctl, CB_GETCURSEL, 0, 0);
        if (code == CBN_SELCHANGE && i >= 0) {
            *choice = i;
            apply();
        }
        return;
    }
    if (id >= IDC_HK_FIELD1 && id <= IDC_HK_FIELD8) {
        int hk = id - IDC_HK_FIELD1 + 1;
        if (code == HKN_BEGIN) {
            daemon_cmd(L"_hotkeys", L"off"); /* let our own hotkeys reach the field */
        } else if (code == HKN_DONE) {
            HkField *f = (HkField *)GetWindowLongPtrW(ctl, GWLP_USERDATA);
            S.cfg.mod[hk] = f->mod;
            S.cfg.vk[hk] = f->vk;
            apply();
        }
        return;
    }
    if (id >= IDC_HK_CLEAR1 && id <= IDC_HK_CLEAR8) {
        int hk = id - IDC_HK_CLEAR1 + 1;
        S.cfg.mod[hk] = S.cfg.vk[hk] = 0;
        show_hotkeys();
        apply();
        return;
    }
    if (code != BN_CLICKED)
        return;
    switch (id) {
    case IDC_AUTOSTART: {
        bool on = IsDlgButtonChecked(page, IDC_AUTOSTART) == BST_CHECKED;
        if (!autostart_set(on)) {
            MessageBoxW(S.dlg, on ? T(AUTOSTART_ADD_FAILED) : T(AUTOSTART_DEL_FAILED), T(SETTINGS_TITLE),
                        MB_OK | MB_ICONWARNING);
            CheckDlgButton(page, IDC_AUTOSTART, autostart_on() ? BST_CHECKED : BST_UNCHECKED);
        }
        break;
    }
    case IDC_PIN_TOP:
        S.cfg.pin_top = IsDlgButtonChecked(page, IDC_PIN_TOP) == BST_CHECKED;
        apply();
        break;
    case IDC_PIN_TEXT:
        S.cfg.pin_text = IsDlgButtonChecked(page, IDC_PIN_TEXT) == BST_CHECKED;
        apply();
        break;
    case IDC_TRAY:
        S.cfg.tray = IsDlgButtonChecked(page, IDC_TRAY) == BST_CHECKED;
        apply();
        if (!S.cfg.tray) /* the icon was the way to this window: say which ways are left */
            MessageBoxW(S.dlg, T(G_TRAY_HIDDEN), T(SETTINGS_TITLE), MB_OK | MB_ICONINFORMATION);
        break;
    case IDC_DXGI:
    case IDC_GDI:
        S.cfg.gdi = id == IDC_GDI;
        apply();
        break;
    case IDC_OPEN_INI:
        ensure_ini(path);
        if (S.shell_exec)
            S.shell_exec(S.dlg, L"open", path, NULL, NULL, SW_SHOWNORMAL);
        break;
    case IDC_OPEN_DIR: { /* Explorer by its full path: by name alone the current folder, the program's, comes first */
        WCHAR explorer[MAX_PATH + 16];
        UINT n = GetSystemWindowsDirectoryW(explorer, MAX_PATH);
        ensure_ini(path);
        wsprintfW(arg, L"/select,\"%s\"", path);
        if (S.shell_exec && n && n < MAX_PATH) {
            lstrcatW(explorer, L"\\explorer.exe");
            S.shell_exec(S.dlg, NULL, explorer, arg, NULL, SW_SHOWNORMAL);
        }
        break;
    }
    case IDC_PROJECT:
        if (S.shell_exec)
            S.shell_exec(S.dlg, L"open", L"https://" UPDATE_HOST UPDATE_REPO, NULL, NULL, SW_SHOWNORMAL);
        break;
    case IDC_U_CHECK:
        upd_check();
        break;
    case IDC_U_INSTALL:
        upd_install();
        break;
    case IDC_O_INSTALL:
        ocr_install();
        break;
    case IDC_O_REMOVE:
        SetDlgItemTextW(page, IDC_O_STATUS, ocr_remove() ? L"" : T(O_WRITE_FAILED));
        ocr_show();
        daemon_cmd(L"_reload", NULL); /* its toolbar no longer has the text buttons */
        break;
    case IDC_U_AUTO:
        S.cfg.auto_update = IsDlgButtonChecked(page, IDC_U_AUTO) == BST_CHECKED;
        apply();
        break;
    case IDC_EXIT_ASK:
        S.cfg.exit_ask = IsDlgButtonChecked(page, IDC_EXIT_ASK) == BST_CHECKED;
        apply();
        break;
    case IDC_HK_FULLSCREEN:
        S.cfg.block_fullscreen = IsDlgButtonChecked(page, IDC_HK_FULLSCREEN) == BST_CHECKED;
        apply();
        break;
    case IDC_SAVE_PICK:
        if (pick_path(S.dlg, S.cfg.save_dir, COUNTOF(S.cfg.save_dir), false)) {
            show_save_dir();
            apply();
        }
        break;
    case IDC_REC_PICK:
        if (pick_path(S.dlg, S.cfg.rec_dir, COUNTOF(S.cfg.rec_dir), false)) {
            show_rec_dir();
            apply();
        }
        break;
    case IDC_ALSO_SAVE:
        S.cfg.also_save = IsDlgButtonChecked(page, IDC_ALSO_SAVE) == BST_CHECKED;
        apply();
        break;
    case IDC_HELPBTN:
    case IDC_BUILTIN:
        show_help(S.dlg);
        break;
    case IDC_HK_APPS:
        lang_dialog_box(S.inst, IDD_APPS, S.dlg, apps_proc);
        break;
    case IDC_DEFAULTS: {
        Config d;
        config_defaults(&d);
        if (page == S.page[PG_GENERAL]) {
            S.cfg.tray = d.tray;
            CheckDlgButton(page, IDC_TRAY, d.tray ? BST_CHECKED : BST_UNCHECKED);
            S.cfg.pin_top = d.pin_top;
            CheckDlgButton(page, IDC_PIN_TOP, d.pin_top ? BST_CHECKED : BST_UNCHECKED);
            S.cfg.pin_text = d.pin_text;
            CheckDlgButton(page, IDC_PIN_TEXT, d.pin_text ? BST_CHECKED : BST_UNCHECKED);
            S.cfg.theme = d.theme;
            SendDlgItemMessageW(page, IDC_THEME, CB_SETCURSEL, (WPARAM)d.theme, 0);
            if (!S.portable && (autostart_on() || autostart_set(true))) /* on by default */
                CheckDlgButton(page, IDC_AUTOSTART, BST_CHECKED);
            if (lang_choice() != LG_AUTO && !S.busy && !S.ocr_busy) { /* as for the list of languages */
                set_language(LG_AUTO);
                return;
            }
        } else if (page == S.page[PG_CAPTURE]) {
            S.cfg.gdi = d.gdi;
            CheckRadioButton(page, IDC_DXGI, IDC_GDI, d.gdi ? IDC_GDI : IDC_DXGI);
            S.cfg.detect = d.detect;
            SendDlgItemMessageW(page, IDC_DETECT, CB_SETCURSEL, (WPARAM)d.detect, 0);
            S.cfg.exit_ask = d.exit_ask;
            CheckDlgButton(page, IDC_EXIT_ASK, d.exit_ask ? BST_CHECKED : BST_UNCHECKED);
            S.cfg.save_dir[0] = 0;
            show_save_dir();
            S.cfg.rec_dir[0] = 0;
            show_rec_dir();
            S.cfg.name = d.name;
            SendDlgItemMessageW(page, IDC_NAME, CB_SETCURSEL, (WPARAM)d.name, 0);
            S.cfg.also_save = d.also_save;
            CheckDlgButton(page, IDC_ALSO_SAVE, d.also_save ? BST_CHECKED : BST_UNCHECKED);
        } else if (page == S.page[PG_HOTKEYS]) {
            memcpy(S.cfg.mod, d.mod, sizeof d.mod);
            memcpy(S.cfg.vk, d.vk, sizeof d.vk);
            show_hotkeys();
            S.cfg.block_fullscreen = d.block_fullscreen;
            CheckDlgButton(page, IDC_HK_FULLSCREEN, d.block_fullscreen ? BST_CHECKED : BST_UNCHECKED);
            S.cfg.block_apps[0] = 0;
        } else if (page == S.page[PG_UPDATE] && !S.portable) {
            S.cfg.auto_update = d.auto_update;
            CheckDlgButton(page, IDC_U_AUTO, d.auto_update ? BST_CHECKED : BST_UNCHECKED);
        }
        apply();
        break;
    }
    }
}

static INT_PTR CALLBACK page_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    switch (m) {
    case WM_INITDIALOG:
        if (S.theme_tex)
            S.theme_tex(h, ETDT_ENABLETAB_); /* page background matches the tab body */
        return FALSE;
    case WM_COMMAND:
        page_command(h, LOWORD(wp), HIWORD(wp), (HWND)lp);
        return TRUE;
    case WM_DRAWITEM: {
        const DRAWITEMSTRUCT *di = (const DRAWITEMSTRUCT *)lp;
        int id = (int)di->CtlID, kind = RI_NONE;
        if (id >= IDC_HK_CLEAR1 && id <= IDC_HK_CLEAR8)
            kind = RI_CLEAR;
        else if (id >= IDC_HK_STATE1 && id <= IDC_HK_STATE8) {
            int hk = id - IDC_HK_STATE1 + 1;
            kind = !S.cfg.vk[hk] || S.state[hk] == 2 ? RI_NONE : S.state[hk] ? RI_OK : RI_FAIL;
        } else if (id == IDC_HELPBTN)
            kind = RI_HELP;
        draw_round_icon(di, kind);
        return TRUE;
    }
    case WM_CTLCOLORSTATIC:
        if (GetDlgCtrlID((HWND)lp) == IDC_HINT) { /* secondary text in gray */
            SetTextColor((HDC)wp, GetSysColor(COLOR_GRAYTEXT));
            SetBkMode((HDC)wp, TRANSPARENT);
            return (INT_PTR)GetStockObject(NULL_BRUSH);
        }
        break;
    }
    return FALSE;
}

/* ---- main window ------------------------------------------------------------------------- */

/* The portable version is the program by itself, not an installed copy (update.h). What only
 * an installed copy offers is listed here and shown gray in the portable one. */
static const struct {
    unsigned char page;
    unsigned char id; /* IDC_... */
} kInstalledOnly[] = {
    {PG_GENERAL, IDC_AUTOSTART}, /* a shortcut to a file that may be somewhere else tomorrow */
    {PG_UPDATE, IDC_U_CHECK},    /* an update is the installer: it would make an installation of this copy */
    {PG_UPDATE, IDC_U_AUTO},     /* so none is looked for either: unticked, whatever the file says */
    {PG_OCR, IDC_O_INSTALL},     /* the module comes with the portable program or not at all */
    {PG_OCR, IDC_O_REMOVE},
};

/* The controls with a text of their own (the .rc has the places and sizes only). */
static const struct {
    unsigned char page;
    unsigned char id; /* IDC_... */
    unsigned short s; /* S_... */
} kTexts[] = {
    {PG_GENERAL, IDC_AUTOSTART, S_G_AUTOSTART},
    {PG_GENERAL, IDC_TRAY, S_G_TRAY},
    {PG_GENERAL, IDC_PIN_TOP, S_G_PIN_TOP},
    {PG_GENERAL, IDC_PIN_TEXT, S_G_PIN_TEXT},
    {PG_GENERAL, IDC_LANG_LABEL, S_G_LANG},
    {PG_GENERAL, IDC_THEME_LABEL, S_G_THEME},
    {PG_GENERAL, IDC_INI_GROUP, S_G_INI_GROUP},
    {PG_GENERAL, IDC_PATH_LABEL, S_G_PATH},
    {PG_GENERAL, IDC_OPEN_DIR, S_G_OPEN_DIR},
    {PG_GENERAL, IDC_OPEN_INI, S_G_OPEN_INI},
    {PG_CAPTURE, IDC_MODE_LABEL, S_C_MODE},
    {PG_CAPTURE, IDC_DXGI, S_C_DXGI},
    {PG_CAPTURE, IDC_GDI, S_C_GDI},
    {PG_CAPTURE, IDC_DETECT_LABEL, S_C_DETECT},
    {PG_CAPTURE, IDC_EXIT_ASK, S_C_EXIT_ASK},
    {PG_CAPTURE, IDC_SAVE_LABEL, S_C_SAVE_DIR},
    {PG_CAPTURE, IDC_SAVE_PICK, S_C_CHANGE},
    {PG_CAPTURE, IDC_REC_DIR_LABEL, S_C_REC_DIR},
    {PG_CAPTURE, IDC_REC_PICK, S_C_CHANGE},
    {PG_CAPTURE, IDC_NAME_LABEL, S_C_NAME},
    {PG_CAPTURE, IDC_ALSO_SAVE, S_C_ALSO_SAVE},
    {PG_HOTKEYS, IDC_HK_LABEL1, S_H_CAPTURE}, /* the rows in the order of HK_* */
    {PG_HOTKEYS, IDC_HK_LABEL2, S_H_QUICK},
    {PG_HOTKEYS, IDC_HK_LABEL3, S_H_PIN},
    {PG_HOTKEYS, IDC_HK_LABEL4, S_H_TOGGLE},
    {PG_HOTKEYS, IDC_HK_LABEL5, S_H_OCR},
    {PG_HOTKEYS, IDC_HK_LABEL6, S_H_OCRCOPY},
    {PG_HOTKEYS, IDC_HK_LABEL7, S_H_PICK},
    {PG_HOTKEYS, IDC_HK_LABEL8, S_H_RECORD},
    {PG_HOTKEYS, IDC_HINT, S_H_HINT},
    {PG_HOTKEYS, IDC_HK_FULLSCREEN, S_H_FULLSCREEN},
    {PG_HOTKEYS, IDC_HK_APPS_LABEL, S_H_APPS},
    {PG_HOTKEYS, IDC_HK_APPS, S_H_APPS_BTN},
    {PG_HOTKEYS, IDC_BUILTIN, S_H_BUILTIN},
    {PG_UPDATE, IDC_U_CHECK, S_U_CHECK_BTN},
    {PG_UPDATE, IDC_U_INSTALL, S_U_INSTALL_BTN},
    {PG_UPDATE, IDC_U_AUTO, S_U_AUTO},
    {PG_UPDATE, IDC_HINT, S_U_HINT},
    {PG_OCR, IDC_O_REMOVE, S_O_REMOVE_BTN},
    {PG_OCR, IDC_HINT, S_O_HINT},
    {PG_ABOUT, IDC_TAGLINE, S_TAGLINE},
    {PG_ABOUT, IDC_LICENSE, S_A_LICENSE},
};
_Static_assert(S_COUNT <= 65536, "kTexts keeps text numbers in 16 bits");

/* The two ways to capture say what they cost when the mouse rests on them. */
static void mode_tips(HWND page)
{
    HWND tip = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, NULL, WS_POPUP | TTS_ALWAYSTIP, CW_USEDEFAULT,
                               CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, page, NULL, S.inst, NULL);
    for (int i = 0; i < 2; i++) { /* IDC_DXGI, IDC_GDI */
        TTTOOLINFOW ti = {sizeof ti, TTF_IDISHWND | TTF_SUBCLASS, page, (UINT_PTR)GetDlgItem(page, IDC_DXGI + i)};
        ti.lpszText = (WCHAR *)g_tr[S_C_DXGI_TIP + i];
        SendMessageW(tip, TTM_ADDTOOLW, 0, (LPARAM)&ti);
    }
}

static void select_page(int i)
{
    for (int k = 0; k < PG_COUNT; k++)
        ShowWindow(S.page[k], k == i ? SW_SHOW : SW_HIDE);
}

static INT_PTR CALLBACK main_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    switch (m) {
    case WM_INITDIALOG: {
        S.dlg = h;
        S.tabs = GetDlgItem(h, IDC_TABS);
        HICON big = LoadImageW(S.inst, MAKEINTRESOURCEW(IDI_APP), IMAGE_ICON, GetSystemMetrics(SM_CXICON),
                               GetSystemMetrics(SM_CYICON), 0);
        HICON small = LoadImageW(S.inst, MAKEINTRESOURCEW(IDI_APP), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                 GetSystemMetrics(SM_CYSMICON), 0);
        SendMessageW(h, WM_SETICON, ICON_BIG, (LPARAM)big);
        SendMessageW(h, WM_SETICON, ICON_SMALL, (LPARAM)small);
        SetPropW(h, SETTINGS_MARK, (HANDLE)1);
        SetWindowTextW(h, T(SETTINGS_TITLE));
        static const int ids[PG_COUNT] = {IDD_PAGE_GENERAL, IDD_PAGE_CAPTURE, IDD_PAGE_HOTKEYS, IDD_PAGE_UPDATE,
                                           IDD_PAGE_OCR,     IDD_PAGE_ABOUT};
        RECT rc;
        GetWindowRect(S.tabs, &rc);
        MapWindowPoints(NULL, h, (POINT *)&rc, 2);
        for (int i = 0; i < PG_COUNT; i++) {
            TCITEMW ti = {0};
            ti.mask = TCIF_TEXT;
            ti.pszText = (WCHAR *)g_tr[S_TAB_GENERAL + i];
            SendMessageW(S.tabs, TCM_INSERTITEMW, (WPARAM)i, (LPARAM)&ti);
        }
        SendMessageW(S.tabs, TCM_ADJUSTRECT, FALSE, (LPARAM)&rc);
        for (int i = 0; i < PG_COUNT; i++) {
            S.page[i] = lang_dialog_create(S.inst, ids[i], h, page_proc);
            SetWindowPos(S.page[i], HWND_TOP, rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top, SWP_NOACTIVATE);
            SetDlgItemTextW(S.page[i], IDC_DEFAULTS, T(DEFAULTS));
        }
        for (int i = 0; i < COUNTOF(kTexts); i++)
            SetDlgItemTextW(S.page[kTexts[i].page], kTexts[i].id, g_tr[kTexts[i].s]);
        S.portable = !update_installed_copy();
        for (int i = 0; S.portable && i < COUNTOF(kInstalledOnly); i++)
            EnableWindow(GetDlgItem(S.page[kInstalledOnly[i].page], kInstalledOnly[i].id), FALSE);
        HWND g = S.page[PG_GENERAL], c = S.page[PG_CAPTURE];
        CheckDlgButton(g, IDC_AUTOSTART, autostart_on() ? BST_CHECKED : BST_UNCHECKED);
        CheckDlgButton(g, IDC_TRAY, S.cfg.tray ? BST_CHECKED : BST_UNCHECKED);
        CheckDlgButton(g, IDC_PIN_TOP, S.cfg.pin_top ? BST_CHECKED : BST_UNCHECKED);
        CheckDlgButton(g, IDC_PIN_TEXT, S.cfg.pin_text ? BST_CHECKED : BST_UNCHECKED);
        WCHAR t[96]; /* the languages: what Windows uses, then each by its own name */
        wsprintfW(t, T(G_LANG_AUTO), lang_name(lang_system()));
        SendDlgItemMessageW(g, IDC_LANG, CB_ADDSTRING, 0, (LPARAM)t);
        for (int i = 0; i < LG_COUNT; i++)
            SendDlgItemMessageW(g, IDC_LANG, CB_ADDSTRING, 0, (LPARAM)lang_name(i));
        SendDlgItemMessageW(g, IDC_LANG, CB_SETCURSEL, (WPARAM)(lang_choice() + 1), 0);
        for (int i = 0; i <= THEME_DARK; i++) /* in the order of THEME_* */
            SendDlgItemMessageW(g, IDC_THEME, CB_ADDSTRING, 0, (LPARAM)g_tr[S_G_THEME_AUTO + i]);
        SendDlgItemMessageW(g, IDC_THEME, CB_SETCURSEL, (WPARAM)S.cfg.theme, 0);
        WCHAR ini[MAX_PATH];
        config_path(ini, MAX_PATH);
        SetDlgItemTextW(g, IDC_INI_PATH, ini);
        CheckRadioButton(c, IDC_DXGI, IDC_GDI, S.cfg.gdi ? IDC_GDI : IDC_DXGI);
        mode_tips(c);
        for (int i = 0; i <= DETECT_ELEMENTS; i++) /* in the order of DETECT_* */
            SendDlgItemMessageW(c, IDC_DETECT, CB_ADDSTRING, 0, (LPARAM)g_tr[S_C_DETECT_CONTROLS + i]);
        SendDlgItemMessageW(c, IDC_DETECT, CB_SETCURSEL, (WPARAM)S.cfg.detect, 0);
        CheckDlgButton(c, IDC_EXIT_ASK, S.cfg.exit_ask ? BST_CHECKED : BST_UNCHECKED);
        show_save_dir();
        show_rec_dir();
        show_names();
        CheckDlgButton(c, IDC_ALSO_SAVE, S.cfg.also_save ? BST_CHECKED : BST_UNCHECKED);
        SetDlgItemTextW(S.page[PG_ABOUT], IDC_VERSION,
                        S.portable ? L"sniplite " SNIPLITE_VERSION L" portable" : L"sniplite " SNIPLITE_VERSION);
        SetDlgItemTextW(S.page[PG_ABOUT], IDC_PROJECT, UPDATE_HOST UPDATE_REPO); /* the link is its own text */
        HWND u = S.page[PG_UPDATE];
        wsprintfW(t, T(U_VERSION), SNIPLITE_VERSION);
        SetDlgItemTextW(u, IDC_U_VERSION, t);
        CheckDlgButton(u, IDC_U_AUTO, S.cfg.auto_update && !S.portable ? BST_CHECKED : BST_UNCHECKED);
        ShowWindow(GetDlgItem(u, IDC_U_INSTALL), SW_HIDE);
        SendDlgItemMessageW(S.page[PG_OCR], IDC_O_BAR, PBM_SETRANGE, 0, MAKELPARAM(0, 100));
        ocr_show();
        show_hotkeys();
        HWND k = S.page[PG_HOTKEYS];
        CheckDlgButton(k, IDC_HK_FULLSCREEN, S.cfg.block_fullscreen ? BST_CHECKED : BST_UNCHECKED);
        daemon_cmd(L"_hkstate", NULL);
        SendMessageW(S.tabs, TCM_SETCURSEL, (WPARAM)S.start_page, 0);
        select_page(S.start_page);
        if (S.start_page == PG_UPDATE)
            upd_check();
        if (S.start_page == PG_OCR && S.ocr_auto)
            ocr_install();
        S.ocr_auto = false;
        SetForegroundWindow(h);
        if (S.reopen) { /* back where it was, on the control that was used */
            S.reopen = false;
            SetWindowPos(h, NULL, S.at.x, S.at.y, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
            SetFocus(GetDlgItem(g, IDC_LANG));
            return FALSE;
        }
        return TRUE;
    }
    case WM_DESTROY:
        RemovePropW(h, SETTINGS_MARK);
        return FALSE;
    case WM_NOTIFY: {
        const NMHDR *nm = (const NMHDR *)lp;
        if (nm->idFrom == IDC_TABS && nm->code == TCN_SELCHANGE)
            select_page((int)SendMessageW(S.tabs, TCM_GETCURSEL, 0, 0));
        return TRUE;
    }
    case WM_APP_UPD_CHECKED:
        upd_checked((int)wp);
        return TRUE;
    case WM_APP_UPD_PROGRESS: {
        WCHAR t[48];
        if ((int)wp >= 0)
            wsprintfW(t, T(U_DOWNLOAD_PCT), (int)wp);
        else
            lstrcpynW(t, T(U_DOWNLOADING), COUNTOF(t));
        upd_status(t);
        return TRUE;
    }
    case WM_APP_UPD_FETCHED:
        upd_fetched(wp != 0);
        return TRUE;
    case WM_APP_UPD_DONE:
        upd_done((DWORD)wp);
        return TRUE;
    case WM_ACTIVATE: /* back in front: a pin's menu and the exit question each change a switch of their own */
        if (LOWORD(wp) != WA_INACTIVE && IsWindow(S.page[PG_CAPTURE])) {
            Config f;
            config_load(&f);
            S.cfg.pin_top = f.pin_top;
            S.cfg.exit_ask = f.exit_ask;
            CheckDlgButton(S.page[PG_GENERAL], IDC_PIN_TOP, f.pin_top ? BST_CHECKED : BST_UNCHECKED);
            CheckDlgButton(S.page[PG_CAPTURE], IDC_EXIT_ASK, f.exit_ask ? BST_CHECKED : BST_UNCHECKED);
        }
        break;
    case WM_APP_SHOW_PAGE:
        if ((int)wp >= 0 && (int)wp < PG_COUNT) {
            SendMessageW(S.tabs, TCM_SETCURSEL, wp, 0);
            select_page((int)wp);
            if ((int)wp == PG_UPDATE)
                upd_check();
            if ((int)wp == PG_OCR) {
                ocr_show(); /* it may have been installed or removed meanwhile */
                if (lp && !S.ocr_busy)
                    ocr_install();
            }
        }
        return TRUE;
    case WM_APP_OCR_PROGRESS: {
        WCHAR t[48];
        wsprintfW(t, T(U_DOWNLOAD_PCT), (int)wp);
        SetDlgItemTextW(S.page[PG_OCR], IDC_O_STATUS, t);
        SendDlgItemMessageW(S.page[PG_OCR], IDC_O_BAR, PBM_SETPOS, wp, 0);
        return TRUE;
    }
    case WM_APP_OCR_DONE:
        ocr_done((int)wp);
        return TRUE;
    case WM_APP_SAVE_FAILED:
        MessageBoxW(h, T(O_WRITE_FAILED), T(SETTINGS_TITLE), MB_OK | MB_ICONWARNING);
        return TRUE;
    case WM_COMMAND:
        if (LOWORD(wp) == IDCANCEL && !S.installing) /* not while the installer is swapping files */
            EndDialog(h, 0);
        return TRUE;
    case WM_CLOSE:
        if (!S.installing)
            EndDialog(h, 0);
        return TRUE;
    }
    return FALSE;
}

static void helper_init(HINSTANCE inst)
{
    S.inst = inst;
    /* uxtheme.dll from System32: by name alone, unlike the other two, it is looked for in the program's folder first */
    HMODULE cc = LoadLibraryW(L"comctl32.dll"), sh = LoadLibraryW(L"shell32.dll"),
            ux = LoadLibraryExW(L"uxtheme.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    PFN_InitCommonControlsEx icc = cc ? (PFN_InitCommonControlsEx)(void *)GetProcAddress(cc, "InitCommonControlsEx") : NULL;
    if (icc) {
        INITCOMMONCONTROLSEX ic = {sizeof ic,
                                   ICC_TAB_CLASSES | ICC_LISTVIEW_CLASSES | ICC_STANDARD_CLASSES | ICC_PROGRESS_CLASS};
        icc(&ic);
    }
    if (sh) {
        S.folder = (PFN_SHGetFolderPathW)(void *)GetProcAddress(sh, "SHGetFolderPathW");
        S.shell_exec = (PFN_ShellExecuteW)(void *)GetProcAddress(sh, "ShellExecuteW");
    }
    if (ux) {
        S.theme_tex = (PFN_EnableThemeDialogTexture)(void *)GetProcAddress(ux, "EnableThemeDialogTexture");
        S.theme_bg = (PFN_DrawThemeParentBackground)(void *)GetProcAddress(ux, "DrawThemeParentBackground");
    }
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = hk_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(NULL, IDC_HAND);
    wc.lpszClassName = L"sniplite.hotkey";
    RegisterClassW(&wc);
    for (int id = 1; id < HK_COUNT; id++)
        S.state[id] = 2;
    config_load(&S.cfg);
}

int settings_main(HINSTANCE inst, const WCHAR *page)
{
    S.ocr_auto = page && arg_eq(page, L"ocr-install"); /* from the installer: download the module at once */
    S.start_page = !page                                  ? PG_GENERAL
                   : arg_eq(page, L"update")              ? PG_UPDATE
                   : arg_eq(page, L"ocr") || S.ocr_auto   ? PG_OCR
                   : arg_eq(page, L"about")               ? PG_ABOUT
                   : arg_eq(page, L"hotkeys")             ? PG_HOTKEYS
                                                          : PG_GENERAL;
    HWND open = ipc_find_dialog(SETTINGS_MARK);
    if (open) {
        if (S.start_page != PG_GENERAL)
            PostMessageW(open, WM_APP_SHOW_PAGE, (WPARAM)S.start_page, S.ocr_auto);
        ShowWindow(open, SW_RESTORE);
        SetForegroundWindow(open);
        return 0;
    }
    helper_init(inst);
    do { /* again after the language was changed */
        lang_dialog_box(inst, IDD_SETTINGS, NULL, main_proc);
        S.start_page = PG_GENERAL;
    } while (S.reopen);
    if (S.busy && !S.installing && S.setup[0]) /* closed right after a download */
        DeleteFileW(S.setup);
    if (g_relaunch) { /* show the new version: ask the new sniplite to open this page */
        HWND d = NULL;
        for (int i = 0; i < 50 && !(d = ipc_find()); i++)
            Sleep(100);
        WCHAR *argv[2] = {L"settings", L"update"};
        Str r = {0};
        AllowSetForegroundWindow(ASFW_ANY);
        bool asked = d && ipc_call(d, 2, argv, &r) == 0;
        str_free(&r);
        WCHAR exe[MAX_PATH]; /* this program's name: the new one has it now */
        DWORD n = asked ? 0 : GetModuleFileNameW(NULL, exe, MAX_PATH);
        if (n && n < MAX_PATH) {
            Str cmd = {0};
            str_add_quoted(&cmd, exe);
            str_add(&cmd, L" --settings update");
            STARTUPINFOW si = {sizeof si};
            PROCESS_INFORMATION pi;
            if (cmd.p && CreateProcessW(exe, cmd.p, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
                CloseHandle(pi.hThread);
                CloseHandle(pi.hProcess);
            }
            str_free(&cmd);
        }
    }
    return 0;
}

int shortcuts_main(HINSTANCE inst)
{
    HWND open = ipc_find_dialog(SHORTCUTS_MARK);
    if (open) {
        SetForegroundWindow(open);
        return 0;
    }
    helper_init(inst);
    show_help(NULL);
    return 0;
}
