/* sniplite_win_setup_amd64.exe: the installer.
 *
 * Per-user (no admin, no UAC), no registry. Copies the two program files that are
 * embedded as resources into %LOCALAPPDATA%\Programs\sniplite, adds a Start menu
 * folder (sniplite, 卸载 sniplite), optionally the Startup shortcut, then starts
 * sniplite. The new files are written first (*.new); only then is a running
 * sniplite closed and both files swapped in, or neither. Replaced files are moved
 * aside as *.old (allowed even while they run); sniplite deletes them on its next start.
 *
 *   sniplite_win_setup_amd64.exe            window with one checkbox (开机启动)
 *   sniplite_win_setup_amd64.exe /S         silent; a fresh install turns 开机启动 on
 *   sniplite_win_setup_amd64.exe /update    silent, keeps the current 开机启动 choice
 * Exit code 0 = installed, 1 = failed or cancelled. */
#include "common.h"
#include "install.h"
#include "resource.h"
#include <shlobj.h>

static struct {
    WCHAR dir[MAX_PATH], exe[MAX_PATH];
    HFONT title_font;
    bool done;
} I;

static bool exists(const WCHAR *p) { return GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES; }

static bool join(WCHAR *out, const WCHAR *a, const WCHAR *b)
{
    if (lstrlenW(a) + lstrlenW(b) + 2 > MAX_PATH)
        return false;
    wsprintfW(out, L"%s\\%s", a, b);
    return true;
}

static bool special(int csidl, const WCHAR *name, WCHAR *out)
{
    WCHAR base[MAX_PATH];
    return SUCCEEDED(SHGetFolderPathW(NULL, csidl, NULL, 0, base)) && join(out, base, name);
}

static bool make_link(const WCHAR *lnk, const WCHAR *args)
{
    IShellLinkW *sl = NULL;
    IPersistFile *pf = NULL;
    bool ok = false;
    if (SUCCEEDED(CoCreateInstance(&CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, (void **)&sl))) {
        IShellLinkW_SetPath(sl, I.exe);
        if (args)
            IShellLinkW_SetArguments(sl, args);
        IShellLinkW_SetWorkingDirectory(sl, I.dir);
        IShellLinkW_SetIconLocation(sl, I.exe, 0);
        if (SUCCEEDED(IShellLinkW_QueryInterface(sl, &IID_IPersistFile, (void **)&pf))) {
            ok = SUCCEEDED(IPersistFile_Save(pf, lnk, TRUE));
            IPersistFile_Release(pf);
        }
        IShellLinkW_Release(sl);
    }
    return ok;
}

static bool autostart_on(void)
{
    WCHAR p[MAX_PATH];
    return special(CSIDL_STARTUP, STARTUP_LNK, p) && exists(p);
}

/* Close the background process (and its pins). Helper processes started from the
 * installed exe (preferences, save dialog) may keep running: their exe is moved aside. */
static void stop_running(void)
{
    HWND d = FindWindowW(DAEMON_CLASS, NULL);
    if (!d)
        return;
    DWORD pid = 0;
    GetWindowThreadProcessId(d, &pid);
    HANDLE p = pid ? OpenProcess(SYNCHRONIZE, FALSE, pid) : NULL;
    PostMessageW(d, WM_CLOSE, 0, 0);
    if (p) {
        WaitForSingleObject(p, 5000);
        CloseHandle(p);
    }
}

/* The two program files, embedded as resources. */
static const struct {
    int id;
    const WCHAR *name;
} kFiles[] = {{IDR_APP_EXE, L"sniplite.exe"}, {IDR_APP_COM, L"sniplite.com"}};
static bool g_had[2]; /* the file existed and was moved to *.old by swap() */

static bool paths(int i, WCHAR *path, WCHAR *tmp, WCHAR *old)
{
    if (!join(path, I.dir, kFiles[i].name) || lstrlenW(path) + 5 > MAX_PATH)
        return false;
    wsprintfW(tmp, L"%s.new", path);
    wsprintfW(old, L"%s.old", path);
    return true;
}

/* A virus scanner often holds a freshly written exe for a moment: retry for ~2 s. */
static bool move_retry(const WCHAR *from, const WCHAR *to, DWORD flags)
{
    for (int k = 0; k < 20; k++) {
        if (MoveFileExW(from, to, flags))
            return true;
        if (GetFileAttributesW(from) == INVALID_FILE_ATTRIBUTES)
            return false;
        Sleep(100);
    }
    return false;
}

/* Step 1: write <name>.new next to the current file. Nothing in use is touched. */
static bool write_new(int i)
{
    HRSRC r = FindResourceW(NULL, MAKEINTRESOURCEW(kFiles[i].id), (LPCWSTR)RT_RCDATA);
    HGLOBAL g = r ? LoadResource(NULL, r) : NULL;
    const void *data = g ? LockResource(g) : NULL;
    DWORD size = r ? SizeofResource(NULL, r) : 0;
    WCHAR path[MAX_PATH], tmp[MAX_PATH], old[MAX_PATH];
    if (!data || !size || !paths(i, path, tmp, old))
        return false;
    HANDLE f = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE)
        return false;
    DWORD w = 0;
    bool ok = WriteFile(f, data, size, &w, NULL) && w == size;
    if (!CloseHandle(f) || !ok) {
        DeleteFileW(tmp);
        return false;
    }
    return true;
}

/* Step 2: move the current file to <name>.old (Windows allows that even while it
 * runs), then <name>.new into place. On failure the current file is put back. */
static bool swap(int i)
{
    WCHAR path[MAX_PATH], tmp[MAX_PATH], old[MAX_PATH];
    if (!paths(i, path, tmp, old))
        return false;
    /* an .old from the last update may still run (a window left open): move it to a
     * unique name; sniplite deletes every sniplite.*.old on its next start */
    if (!DeleteFileW(old) && exists(old) && lstrlenW(path) + 16 < MAX_PATH) {
        WCHAR aside[MAX_PATH];
        wsprintfW(aside, L"%s.%lu.old", path, GetTickCount());
        MoveFileExW(old, aside, 0);
    }
    g_had[i] = exists(path);
    if (g_had[i] && !move_retry(path, old, MOVEFILE_REPLACE_EXISTING))
        return false;
    if (move_retry(tmp, path, 0))
        return true;
    if (g_had[i])
        move_retry(old, path, 0);
    return false;
}

/* Undo a successful swap(i). */
static void unswap(int i)
{
    WCHAR path[MAX_PATH], tmp[MAX_PATH], old[MAX_PATH];
    if (!paths(i, path, tmp, old))
        return;
    if (g_had[i])
        move_retry(old, path, MOVEFILE_REPLACE_EXISTING);
    else
        for (int k = 0; k < 20 && !DeleteFileW(path) && exists(path); k++)
            Sleep(100);
}

static void delete_new(void)
{
    WCHAR path[MAX_PATH], tmp[MAX_PATH], old[MAX_PATH];
    for (int i = 0; i < COUNTOF(kFiles); i++)
        if (paths(i, path, tmp, old))
            DeleteFileW(tmp);
}

/* autostart: 1 on, 0 off, -1 leave as it is */
static bool install(int autostart)
{
    int e = SHCreateDirectoryExW(NULL, I.dir, NULL);
    if (e != ERROR_SUCCESS && e != ERROR_ALREADY_EXISTS && e != ERROR_FILE_EXISTS)
        return false;
    for (int i = 0; i < COUNTOF(kFiles); i++)
        if (!write_new(i)) { /* e.g. disk full: sniplite keeps running untouched */
            delete_new();
            return false;
        }
    stop_running();
    bool ok = swap(0); /* both files are replaced, or neither */
    if (ok && !(ok = swap(1)))
        unswap(0);
    delete_new();
    if (ok) {
        WCHAR menu[MAX_PATH], lnk[MAX_PATH];
        if (special(CSIDL_PROGRAMS, MENU_FOLDER, menu)) {
            CreateDirectoryW(menu, NULL);
            if (join(lnk, menu, MENU_APP_LNK))
                make_link(lnk, NULL);
            if (join(lnk, menu, MENU_UNINSTALL_LNK))
                make_link(lnk, L"--uninstall");
        }
        if (autostart >= 0 && special(CSIDL_STARTUP, STARTUP_LNK, lnk)) {
            if (autostart)
                make_link(lnk, NULL);
            else
                DeleteFileW(lnk);
        }
    }
    /* Start sniplite again: the new version, or the old one if the swap failed.
     * Break away from a terminal's job (`sniplite update --install`) like the CLI does. */
    if (!exists(I.exe)) { /* last resort: never leave the folder without a working exe */
        WCHAR o[MAX_PATH + 8];
        wsprintfW(o, L"%s.old", I.exe);
        move_retry(o, I.exe, 0);
    }
    if (exists(I.exe)) {
        WCHAR cmd[MAX_PATH + 16];
        wsprintfW(cmd, L"\"%s\" start", I.exe);
        STARTUPINFOW si = {sizeof si};
        PROCESS_INFORMATION pi;
        if (CreateProcessW(I.exe, cmd, NULL, NULL, FALSE, CREATE_BREAKAWAY_FROM_JOB, NULL, I.dir, &si, &pi) ||
            CreateProcessW(I.exe, cmd, NULL, NULL, FALSE, 0, NULL, I.dir, &si, &pi)) {
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
        }
    }
    return ok;
}

static INT_PTR CALLBACK dlg_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    (void)lp;
    switch (m) {
    case WM_INITDIALOG: {
        HINSTANCE inst = GetModuleHandleW(NULL);
        SendMessageW(h, WM_SETICON, ICON_BIG,
                     (LPARAM)LoadImageW(inst, MAKEINTRESOURCEW(IDI_APP), IMAGE_ICON, GetSystemMetrics(SM_CXICON),
                                        GetSystemMetrics(SM_CYICON), 0));
        SendMessageW(h, WM_SETICON, ICON_SMALL,
                     (LPARAM)LoadImageW(inst, MAKEINTRESOURCEW(IDI_APP), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                        GetSystemMetrics(SM_CYSMICON), 0));
        LOGFONTW lf;
        GetObjectW((HFONT)SendMessageW(h, WM_GETFONT, 0, 0), sizeof lf, &lf);
        lf.lfWeight = FW_SEMIBOLD;
        lf.lfHeight = lf.lfHeight * 4 / 3;
        I.title_font = CreateFontIndirectW(&lf);
        SendDlgItemMessageW(h, IDC_S_TITLE, WM_SETFONT, (WPARAM)I.title_font, TRUE);
        SetDlgItemTextW(h, IDC_S_TITLE, L"sniplite " SNIPLITE_VERSION);
        WCHAR t[MAX_PATH + 16];
        wsprintfW(t, L"安装到 %s", I.dir);
        SetDlgItemTextW(h, IDC_S_PATH, t);
        /* first install: on by default; reinstall/upgrade: show the current choice */
        CheckDlgButton(h, IDC_S_AUTOSTART, !exists(I.exe) || autostart_on() ? BST_CHECKED : BST_UNCHECKED);
        SetForegroundWindow(h);
        return TRUE;
    }
    case WM_COMMAND:
        if (LOWORD(wp) == IDOK) {
            if (I.done) {
                EndDialog(h, 0);
                return TRUE;
            }
            EnableWindow(GetDlgItem(h, IDOK), FALSE);
            EnableWindow(GetDlgItem(h, IDCANCEL), FALSE);
            HCURSOR old = SetCursor(LoadCursorW(NULL, IDC_WAIT));
            bool ok = install(IsDlgButtonChecked(h, IDC_S_AUTOSTART) == BST_CHECKED);
            SetCursor(old);
            if (ok) {
                I.done = true;
                WCHAR ini[MAX_PATH]; /* own settings may use other keys */
                bool own = join(ini, I.dir, L"sniplite.ini") && exists(ini);
                SetDlgItemTextW(h, IDC_S_PATH, own ? L"装好了，sniplite 已在后台运行。" : L"装好了，按 F1 截图，按 F3 贴图。");
                ShowWindow(GetDlgItem(h, IDC_S_AUTOSTART), SW_HIDE);
                ShowWindow(GetDlgItem(h, IDCANCEL), SW_HIDE);
                SetDlgItemTextW(h, IDOK, L"完成");
                EnableWindow(GetDlgItem(h, IDOK), TRUE);
                SetFocus(GetDlgItem(h, IDOK));
            } else {
                MessageBoxW(h, L"安装失败：无法写入程序文件。", L"安装 sniplite", MB_OK | MB_ICONERROR);
                EnableWindow(GetDlgItem(h, IDOK), TRUE);
                EnableWindow(GetDlgItem(h, IDCANCEL), TRUE);
                SendMessageW(h, WM_NEXTDLGCTL, (WPARAM)GetDlgItem(h, IDOK), TRUE);
            }
            return TRUE;
        }
        if (LOWORD(wp) == IDCANCEL) {
            EndDialog(h, I.done ? 0 : 1);
            return TRUE;
        }
        break;
    case WM_CLOSE:
        EndDialog(h, I.done ? 0 : 1);
        return TRUE;
    }
    return FALSE;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmdline, int show)
{
    (void)prev;
    (void)cmdline;
    (void)show;
    int argc;
    WCHAR **argv = cmdline_split(GetCommandLineW(), &argc);
    bool silent = false, update = false;
    for (int i = 1; i < argc; i++) {
        if (arg_eq(argv[i], L"/S") || arg_eq(argv[i], L"-S"))
            silent = true;
        else if (arg_eq(argv[i], L"/update") || arg_eq(argv[i], L"--update"))
            update = true;
    }
    if (!ExpandEnvironmentStringsW(INSTALL_DIR, I.dir, MAX_PATH) || I.dir[0] == L'%' || !join(I.exe, I.dir, L"sniplite.exe"))
        return 1;
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (silent || update)
        return install(update || exists(I.exe) ? -1 : 1) ? 0 : 1;
    return (int)DialogBoxParamW(inst, MAKEINTRESOURCEW(IDD_SETUP), NULL, dlg_proc, 0);
}
