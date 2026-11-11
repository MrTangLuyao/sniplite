/* Client side of the WM_COPYDATA protocol: send cwd + argv, receive text + exit code. */
#include "common.h"

static Str *g_reply;

static LRESULT CALLBACK reply_proc(HWND h, UINT m, WPARAM wp, LPARAM lp)
{
    if (m == WM_COPYDATA) {
        const COPYDATASTRUCT *cd = (const COPYDATASTRUCT *)lp;
        if (cd && cd->dwData == IPC_REPLY && g_reply && cd->cbData >= sizeof(WCHAR)) {
            const WCHAR *t = cd->lpData;
            int n = (int)(cd->cbData / sizeof(WCHAR));
            while (n > 0 && !t[n - 1])
                n--;
            str_addn(g_reply, t, n);
        }
        return TRUE;
    }
    return DefWindowProcW(h, m, wp, lp);
}

HWND ipc_find(void) { return FindWindowW(DAEMON_CLASS, NULL); }

int ipc_call(HWND daemon, int argc, WCHAR **argv, Str *reply)
{
    HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = reply_proc;
    wc.hInstance = inst;
    wc.lpszClassName = L"sniplite.reply";
    RegisterClassW(&wc); /* fails harmlessly when already registered */
    HWND rw = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, inst, NULL);
    if (rw)
        ChangeWindowMessageFilterEx(rw, WM_COPYDATA, MSGFLT_ALLOW, NULL);

    Str req = {0};
    WCHAR cwd[MAX_PATH * 2];
    DWORD n = GetCurrentDirectoryW(COUNTOF(cwd), cwd);
    str_add(&req, n && n < COUNTOF(cwd) ? cwd : L"");
    for (int i = 0; i < argc; i++) {
        WCHAR sep = IPC_SEP;
        str_addn(&req, &sep, 1);
        str_add(&req, argv[i]);
    }
    COPYDATASTRUCT cd = {IPC_REQ, (DWORD)((req.n + 1) * sizeof(WCHAR)), req.p ? req.p : (WCHAR *)L""};

    DWORD pid = 0;
    GetWindowThreadProcessId(daemon, &pid);
    AllowSetForegroundWindow(pid); /* so the capture overlay may take focus */
    g_reply = reply;
    DWORD_PTR res = 0;
    LRESULT ok = SendMessageTimeoutW(daemon, WM_COPYDATA, (WPARAM)rw, (LPARAM)&cd, SMTO_ABORTIFHUNG, 60000, &res);
    g_reply = NULL;
    if (rw)
        DestroyWindow(rw);
    str_free(&req);
    if (!ok || res < IPC_BASE || res > IPC_BASE + 255)
        return -1;
    return (int)(res - IPC_BASE);
}
