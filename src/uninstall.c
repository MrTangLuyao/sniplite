/* `sniplite.exe --uninstall [/S]`: removes exactly what the installer and the app
 * created, by name: the Start menu folder, the Startup shortcut, the program files
 * and sniplite.ini next to this exe. Never deletes anything recursively; the folder
 * itself is only removed when it is empty. The running exe is deleted by a small
 * hidden cmd.exe after this process exits. */
#include "common.h"
#include "install.h"
#include "lang.h"
#include "settings.h"
#include <shlobj.h>

typedef HRESULT(WINAPI *PFN_SHGetFolderPathW)(HWND, int, HANDLE, DWORD, LPWSTR);

static bool join(WCHAR *out, const WCHAR *a, const WCHAR *b)
{
    if (lstrlenW(a) + lstrlenW(b) + 2 > MAX_PATH)
        return false;
    wsprintfW(out, L"%s\\%s", a, b);
    return true;
}

static bool special(PFN_SHGetFolderPathW get, int csidl, const WCHAR *name, WCHAR *out)
{
    WCHAR base[MAX_PATH];
    return get && SUCCEEDED(get(NULL, csidl, NULL, 0, base)) && join(out, base, name);
}

/* Close a sniplite window (and with it its process) and wait for the process to end,
 * so its exe is no longer in use. */
static void close_wait(HWND w)
{
    if (!w)
        return;
    DWORD pid = 0;
    GetWindowThreadProcessId(w, &pid);
    HANDLE h = pid ? OpenProcess(SYNCHRONIZE, FALSE, pid) : NULL;
    HWND front = GetWindow(w, GW_ENABLEDPOPUP); /* a message box in front of it goes first */
    if (front && front != w)
        PostMessageW(front, WM_CLOSE, 0, 0);
    for (HWND o = w; o; o = GetWindow(o, GW_OWNER)) /* the shortcut list, then the window it belongs to */
        PostMessageW(o, WM_CLOSE, 0, 0);
    if (h) {
        WaitForSingleObject(h, 5000);
        CloseHandle(h);
    }
}

int uninstall_main(bool silent)
{
    WCHAR exe[MAX_PATH], dir[MAX_PATH], p[MAX_PATH], q[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, exe, MAX_PATH);
    if (!n || n >= MAX_PATH)
        return EXIT_FAIL;
    lstrcpyW(dir, exe);
    WCHAR *sl = wcsrchr(dir, L'\\');
    if (!sl)
        return EXIT_FAIL;
    *sl = 0;
    if (!silent &&
        MessageBoxW(NULL, T(UNINST_CONFIRM), T(UNINST_TITLE), MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) != IDYES)
        return EXIT_FAIL;

    /* the helper windows first (they could write the settings file again), then the
     * background process and its pins */
    close_wait(ipc_find_dialog(SHORTCUTS_MARK));
    close_wait(ipc_find_dialog(SETTINGS_MARK));
    close_wait(FindWindowW(DAEMON_CLASS, NULL));

    HMODULE sh = LoadLibraryW(L"shell32.dll");
    PFN_SHGetFolderPathW get = sh ? (PFN_SHGetFolderPathW)(void *)GetProcAddress(sh, "SHGetFolderPathW") : NULL;
    if (special(get, CSIDL_PROGRAMS, MENU_FOLDER, p)) {
        if (join(q, p, MENU_APP_LNK))
            DeleteFileW(q);
        for (int i = 0; i < LG_COUNT; i++) { /* named in the language it was installed in */
            WCHAR name[UNINSTALL_LNK_MAX];
            uninstall_lnk(i, name);
            if (join(q, p, name))
                DeleteFileW(q);
        }
        RemoveDirectoryW(p); /* only succeeds when empty */
    }
    if (special(get, CSIDL_STARTUP, STARTUP_LNK, p))
        DeleteFileW(p);

    static const WCHAR *files[] = {L"sniplite.com", L"sniplite.ini", L"sniplite.exe.new", L"sniplite.com.new"};
    for (int i = 0; i < COUNTOF(files); i++)
        if (join(p, dir, files[i]))
            DeleteFileW(p);
    WIN32_FIND_DATAW fd; /* sniplite.exe.old, sniplite.com.old, sniplite.exe.<n>.old */
    HANDLE fh = join(q, dir, L"sniplite.*.old") ? FindFirstFileW(q, &fd) : INVALID_HANDLE_VALUE;
    if (fh != INVALID_HANDLE_VALUE) {
        do
            if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && join(p, dir, fd.cFileName))
                DeleteFileW(p);
        while (FindNextFileW(fh, &fd));
        FindClose(fh);
    }

    if (!silent)
        MessageBoxW(NULL, T(UNINST_DONE), T(UNINST_TITLE), MB_OK | MB_ICONINFORMATION);

    /* This exe is still running: let a hidden cmd.exe delete it (and the then empty
     * folder) once we have exited. rmdir without /s never removes a non-empty folder. */
    WCHAR sys[MAX_PATH], cmd[3 * MAX_PATH + 96];
    if (GetSystemDirectoryW(sys, MAX_PATH)) {
        wsprintfW(cmd, L"\"%s\\cmd.exe\" /d /c ping -n 3 127.0.0.1 >nul & del /f /q \"%s\" & rmdir \"%s\"", sys, exe, dir);
        STARTUPINFOW si = {sizeof si};
        PROCESS_INFORMATION pi;
        WCHAR tmp[MAX_PATH];
        if (!GetTempPathW(MAX_PATH, tmp))
            lstrcpyW(tmp, sys);
        if (CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, tmp, &si, &pi)) {
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
        }
    }
    return EXIT_OK;
}
