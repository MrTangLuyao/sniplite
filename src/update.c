/* Update check: GitHub answers /releases/latest with a redirect to
 * /releases/tag/<newest tag>, so one request without following redirects gives
 * the newest version: no API, no JSON, no rate limit worries. The installer is
 * then at /releases/download/<tag>/sniplite_win_setup_amd64.exe.
 * WinHTTP is loaded on demand and uses the system proxy settings. */
#include "update.h"
#include "install.h"
#include <winhttp.h>

#ifndef WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY
#define WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY 4
#endif

typedef HINTERNET(WINAPI *PFN_Open)(LPCWSTR, DWORD, LPCWSTR, LPCWSTR, DWORD);
typedef HINTERNET(WINAPI *PFN_Connect)(HINTERNET, LPCWSTR, INTERNET_PORT, DWORD);
typedef HINTERNET(WINAPI *PFN_OpenRequest)(HINTERNET, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR *, DWORD);
typedef BOOL(WINAPI *PFN_SetOption)(HINTERNET, DWORD, LPVOID, DWORD);
typedef BOOL(WINAPI *PFN_SetTimeouts)(HINTERNET, int, int, int, int);
typedef BOOL(WINAPI *PFN_Send)(HINTERNET, LPCWSTR, DWORD, LPVOID, DWORD, DWORD, DWORD_PTR);
typedef BOOL(WINAPI *PFN_Receive)(HINTERNET, LPVOID);
typedef BOOL(WINAPI *PFN_QueryHeaders)(HINTERNET, DWORD, LPCWSTR, LPVOID, LPDWORD, LPDWORD);
typedef BOOL(WINAPI *PFN_ReadData)(HINTERNET, LPVOID, DWORD, LPDWORD);
typedef BOOL(WINAPI *PFN_Close)(HINTERNET);

static struct {
    PFN_Open open;
    PFN_Connect connect;
    PFN_OpenRequest request;
    PFN_SetOption set_option;
    PFN_SetTimeouts timeouts;
    PFN_Send send;
    PFN_Receive receive;
    PFN_QueryHeaders headers;
    PFN_ReadData read;
    PFN_Close close;
} WH;

static bool wh_load(void)
{
    if (WH.close)
        return true;
    HMODULE h = LoadLibraryW(L"winhttp.dll");
    if (!h)
        return false;
#define GET(field, name) WH.field = (void *)GetProcAddress(h, name)
    GET(open, "WinHttpOpen");
    GET(connect, "WinHttpConnect");
    GET(request, "WinHttpOpenRequest");
    GET(set_option, "WinHttpSetOption");
    GET(timeouts, "WinHttpSetTimeouts");
    GET(send, "WinHttpSendRequest");
    GET(receive, "WinHttpReceiveResponse");
    GET(headers, "WinHttpQueryHeaders");
    GET(read, "WinHttpReadData");
#undef GET
    PFN_Close close = (PFN_Close)(void *)GetProcAddress(h, "WinHttpCloseHandle");
    if (!WH.open || !WH.connect || !WH.request || !WH.set_option || !WH.timeouts || !WH.send || !WH.receive ||
        !WH.headers || !WH.read || !close)
        return false;
    WH.close = close;
    return true;
}

typedef struct {
    HINTERNET s, c, r;
} Http;

static void http_close(Http *h)
{
    if (h->r) WH.close(h->r);
    if (h->c) WH.close(h->c);
    if (h->s) WH.close(h->s);
    memset(h, 0, sizeof *h);
}

static bool http_get(Http *h, const WCHAR *path, bool follow, DWORD *status)
{
    memset(h, 0, sizeof *h);
    *status = 0;
    const WCHAR *ua = L"sniplite/" SNIPLITE_VERSION;
    h->s = WH.open(ua, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!h->s) /* before Windows 8.1 */
        h->s = WH.open(ua, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!h->s)
        return false;
    WH.timeouts(h->s, 8000, 8000, 15000, 15000);
    h->c = WH.connect(h->s, UPDATE_HOST, INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (h->c)
        h->r = WH.request(h->c, L"GET", path, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    if (!h->r)
        return false;
    if (!follow) {
        DWORD f = WINHTTP_DISABLE_REDIRECTS;
        WH.set_option(h->r, WINHTTP_OPTION_DISABLE_FEATURE, &f, sizeof f);
    }
    if (!WH.send(h->r, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) || !WH.receive(h->r, NULL))
        return false;
    DWORD sz = sizeof *status;
    return WH.headers(h->r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, status,
                      &sz, WINHTTP_NO_HEADER_INDEX) != 0;
}

/* ---- versions ------------------------------------------------------------------- */

static void version_parse(const WCHAR *s, int v[3])
{
    v[0] = v[1] = v[2] = 0;
    if (*s == L'v' || *s == L'V')
        s++;
    for (int i = 0; i < 3; i++) {
        while (*s >= L'0' && *s <= L'9' && v[i] < 100000)
            v[i] = v[i] * 10 + (*s++ - L'0');
        if (*s != L'.')
            break;
        s++;
    }
}

int version_cmp(const WCHAR *a, const WCHAR *b)
{
    int x[3], y[3];
    version_parse(a, x);
    version_parse(b, y);
    for (int i = 0; i < 3; i++)
        if (x[i] != y[i])
            return x[i] < y[i] ? -1 : 1;
    return 0;
}

static bool tag_char_ok(WCHAR c)
{
    return (c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') || c == L'.' ||
           c == L'-' || c == L'_';
}

/* ---- check ------------------------------------------------------------------------- */

void update_check(UpdateResult *r)
{
    memset(r, 0, sizeof *r);
    r->state = UPD_ERROR;
    if (!wh_load())
        return;
    Http h;
    DWORD status;
    if (http_get(&h, UPDATE_REPO L"/releases/latest", false, &status)) {
        if (status >= 300 && status < 400) {
            WCHAR loc[1024];
            DWORD sz = sizeof loc;
            if (WH.headers(h.r, WINHTTP_QUERY_LOCATION, WINHTTP_HEADER_NAME_BY_INDEX, loc, &sz, WINHTTP_NO_HEADER_INDEX)) {
                const WCHAR *t = wcsstr(loc, L"/releases/tag/");
                if (t) {
                    t += 14;
                    int n = 0;
                    while (n < COUNTOF(r->tag) - 1 && tag_char_ok(t[n]))
                        n++;
                    memcpy(r->tag, t, (size_t)n * sizeof(WCHAR));
                    r->tag[n] = 0;
                    if (n > 0)
                        r->state = version_cmp(r->tag, SNIPLITE_VERSION) > 0 ? UPD_NEWER : UPD_LATEST;
                } else {
                    r->state = UPD_NONE; /* sent to /releases: nothing published yet */
                }
            }
        } else if (status == 404) {
            r->state = UPD_NONE;
        }
    }
    http_close(&h);
}

/* ---- download ----------------------------------------------------------------------- */

bool update_download(const WCHAR *tag, WCHAR *path, int cap, void (*progress)(int, void *), void *ctx)
{
    for (const WCHAR *p = tag; *p; p++)
        if (!tag_char_ok(*p))
            return false;
    if (!*tag || !wh_load())
        return false;
    WCHAR tmp[MAX_PATH], part[MAX_PATH + 8], url[256];
    DWORD n = GetTempPathW(MAX_PATH, tmp);
    if (!n || n + lstrlenW(SETUP_FILE) + 8 >= MAX_PATH || cap < MAX_PATH)
        return false;
    wsprintfW(path, L"%s%s", tmp, SETUP_FILE);
    wsprintfW(part, L"%s.part", path);
    wsprintfW(url, L"%s/releases/download/%s/%s", UPDATE_REPO, tag, SETUP_FILE);

    Http h;
    DWORD status;
    bool ok = false;
    if (http_get(&h, url, true, &status) && status == 200) {
        DWORD len = 0, sz = sizeof len;
        if (!WH.headers(h.r, WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &len,
                        &sz, WINHTTP_NO_HEADER_INDEX))
            len = 0;
        enum { BUF = 64 * 1024 };
        BYTE *buf = mem_alloc(BUF); /* on the heap: a static buffer would sit in the exe's data */
        HANDLE f = buf ? CreateFileW(part, GENERIC_WRITE | DELETE, FILE_SHARE_DELETE, NULL, CREATE_ALWAYS,
                                     FILE_ATTRIBUTE_NORMAL, NULL)
                       : INVALID_HANDLE_VALUE;
        if (f != INVALID_HANDLE_VALUE) {
            /* delete on close, so a cancelled or killed download leaves nothing in %TEMP% */
            FILE_DISPOSITION_INFO del = {TRUE};
            SetFileInformationByHandle(f, FileDispositionInfo, &del, sizeof del);
            DWORD total = 0, got, w;
            BYTE head[2] = {0, 0};
            ok = true;
            for (;;) {
                if (!WH.read(h.r, buf, BUF, &got)) {
                    ok = false;
                    break;
                }
                if (!got)
                    break;
                if (total < 2)
                    memcpy(head + total, buf, MINI(2 - total, got));
                if (!WriteFile(f, buf, got, &w, NULL) || w != got || total + got > 64u * 1024 * 1024) {
                    ok = false;
                    break;
                }
                total += got;
                if (progress)
                    progress(len ? (int)((unsigned long long)total * 100 / len) : -1, ctx);
            }
            /* a Windows executable of plausible size, complete if the size was announced */
            ok = ok && head[0] == 'M' && head[1] == 'Z' && total >= 32 * 1024 && (!len || total == len);
            if (ok) {
                del.DeleteFile = FALSE; /* keep it */
                ok = SetFileInformationByHandle(f, FileDispositionInfo, &del, sizeof del) != 0;
            }
            CloseHandle(f);
            if (ok)
                ok = MoveFileExW(part, path, MOVEFILE_REPLACE_EXISTING) != 0;
            if (!ok)
                DeleteFileW(part);
        }
        mem_free(buf);
    }
    http_close(&h);
    return ok;
}

bool update_installed_copy(void)
{
    WCHAR me[MAX_PATH], dir[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, me, MAX_PATH);
    WCHAR *sl = n && n < MAX_PATH ? wcsrchr(me, L'\\') : NULL;
    if (!sl || !ExpandEnvironmentStringsW(INSTALL_DIR, dir, MAX_PATH) || dir[0] == L'%')
        return false;
    *sl = 0;
    GetLongPathNameW(me, me, MAX_PATH); /* 8.3 names vs long names */
    GetLongPathNameW(dir, dir, MAX_PATH);
    return !lstrcmpiW(me, dir);
}

int update_check_main(void)
{
    UpdateResult r;
    update_check(&r);
    if (r.state != UPD_NEWER)
        return EXIT_NOTHING;
    HWND d = ipc_find();
    if (d) {
        WCHAR *argv[2] = {L"_update", r.tag};
        Str reply = {0};
        ipc_call(d, 2, argv, &reply);
        str_free(&reply);
    }
    return EXIT_OK;
}
