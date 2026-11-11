/* Settings file and hotkey names.
 * sniplite.ini lives next to the exe and is only written from the preferences window;
 * without it everything uses the defaults. */
#include "config.h"

static const struct {
    const WCHAR *name;
    UINT vk;
} kKeys[] = {
    {L"PrtSc", VK_SNAPSHOT}, {L"PrintScreen", VK_SNAPSHOT}, {L"Print", VK_SNAPSHOT}, {L"Insert", VK_INSERT},
    {L"Ins", VK_INSERT},     {L"Delete", VK_DELETE},       {L"Del", VK_DELETE},     {L"Home", VK_HOME},
    {L"End", VK_END},        {L"PgUp", VK_PRIOR},          {L"PageUp", VK_PRIOR},   {L"PgDn", VK_NEXT},
    {L"PageDown", VK_NEXT},  {L"Pause", VK_PAUSE},         {L"ScrollLock", VK_SCROLL}, {L"Space", VK_SPACE},
    {L"Tab", VK_TAB},        {L"`", VK_OEM_3},             {L"Up", VK_UP},          {L"Down", VK_DOWN},
    {L"Left", VK_LEFT},      {L"Right", VK_RIGHT},
};

bool hotkey_parse(const WCHAR *s, UINT *mod, UINT *vk)
{
    *mod = *vk = 0;
    if (!*s || arg_eq(s, L"none") || arg_eq(s, L"off"))
        return true;
    WCHAR buf[64];
    lstrcpynW(buf, s, COUNTOF(buf));
    for (WCHAR *tok = buf, *next; tok; tok = next) {
        next = wcschr(tok, L'+');
        if (next)
            *next++ = 0;
        if (!*tok)
            return false;
        if (arg_eq(tok, L"ctrl") || arg_eq(tok, L"control"))
            *mod |= MOD_CONTROL;
        else if (arg_eq(tok, L"alt"))
            *mod |= MOD_ALT;
        else if (arg_eq(tok, L"shift"))
            *mod |= MOD_SHIFT;
        else if (arg_eq(tok, L"win"))
            *mod |= MOD_WIN;
        else if (*vk)
            return false; /* two keys */
        else if (!tok[1] && ((tok[0] >= L'a' && tok[0] <= L'z') || (tok[0] >= L'A' && tok[0] <= L'Z') ||
                             (tok[0] >= L'0' && tok[0] <= L'9')))
            *vk = (UINT)(tok[0] >= L'a' ? tok[0] - 32 : tok[0]);
        else if ((tok[0] == L'f' || tok[0] == L'F') && tok[1] >= L'1' && tok[1] <= L'9') {
            int n = 0;
            for (WCHAR *p = tok + 1; *p; p++) {
                if (*p < L'0' || *p > L'9')
                    return false;
                n = n * 10 + (*p - L'0');
            }
            if (n < 1 || n > 24)
                return false;
            *vk = VK_F1 + (UINT)n - 1;
        } else if ((tok[0] == L'n' || tok[0] == L'N') && !wcsncmp(tok + 1, L"um", 2) && tok[3] >= L'0' &&
                   tok[3] <= L'9' && !tok[4]) {
            *vk = VK_NUMPAD0 + (UINT)(tok[3] - L'0');
        } else {
            for (int i = 0; i < COUNTOF(kKeys) && !*vk; i++)
                if (arg_eq(tok, kKeys[i].name))
                    *vk = kKeys[i].vk;
            if (!*vk)
                return false;
        }
    }
    return *vk != 0;
}

void hotkey_format(UINT mod, UINT vk, WCHAR *out)
{
    out[0] = 0;
    if (!vk) {
        lstrcpyW(out, L"none");
        return;
    }
    if (mod & MOD_CONTROL) lstrcatW(out, L"Ctrl+");
    if (mod & MOD_ALT) lstrcatW(out, L"Alt+");
    if (mod & MOD_SHIFT) lstrcatW(out, L"Shift+");
    if (mod & MOD_WIN) lstrcatW(out, L"Win+");
    WCHAR k[16] = {0};
    if (vk >= VK_F1 && vk <= VK_F24)
        wsprintfW(k, L"F%u", vk - VK_F1 + 1);
    else if ((vk >= 'A' && vk <= 'Z') || (vk >= '0' && vk <= '9'))
        k[0] = (WCHAR)vk;
    else if (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9)
        wsprintfW(k, L"Num%u", vk - VK_NUMPAD0);
    else
        for (int i = 0; i < COUNTOF(kKeys); i++)
            if (kKeys[i].vk == vk) {
                lstrcpyW(k, kKeys[i].name);
                break;
            }
    lstrcatW(out, k);
}

void config_defaults(Config *c)
{
    memset(c, 0, sizeof *c);
    hotkey_parse(L"F1", &c->mod[HK_CAPTURE], &c->vk[HK_CAPTURE]);
    hotkey_parse(L"F3", &c->mod[HK_PIN], &c->vk[HK_PIN]);
    hotkey_parse(L"Shift+F3", &c->mod[HK_TOGGLE], &c->vk[HK_TOGGLE]);
    c->tray = true;
    c->auto_update = true;
}

void config_path(WCHAR *out, int cap)
{
    DWORD n = GetModuleFileNameW(NULL, out, (DWORD)cap);
    WCHAR *sl = n && n < (DWORD)cap ? wcsrchr(out, L'\\') : NULL;
    if (sl && (sl - out) + 13 < cap)
        lstrcpyW(sl + 1, L"sniplite.ini");
    else
        out[0] = 0;
}

static const WCHAR *kHkKeys[HK_COUNT] = {NULL, L"hotkey", L"pin_hotkey", L"toggle_hotkey"};

bool config_load(Config *c)
{
    config_defaults(c);
    WCHAR path[MAX_PATH];
    config_path(path, MAX_PATH);
    if (!path[0] || GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES)
        return false;
    WCHAR v[64];
    for (int id = 1; id < HK_COUNT; id++) {
        UINT mod, vk;
        GetPrivateProfileStringW(L"sniplite", kHkKeys[id], L"\x1F", v, COUNTOF(v), path);
        if (v[0] != 0x1F && hotkey_parse(v, &mod, &vk)) { /* a bad value keeps the default */
            c->mod[id] = mod;
            c->vk[id] = vk;
        }
    }
    GetPrivateProfileStringW(L"sniplite", L"capture", L"dxgi", v, COUNTOF(v), path);
    c->gdi = arg_eq(v, L"gdi");
    c->tray = GetPrivateProfileIntW(L"sniplite", L"tray", 1, path) != 0;
    c->auto_update = GetPrivateProfileIntW(L"sniplite", L"auto_update", 1, path) != 0;
    return true;
}

bool config_save(const Config *c)
{
    WCHAR path[MAX_PATH];
    config_path(path, MAX_PATH);
    if (!path[0])
        return false;
    Str s = {0};
    str_add(&s, L"; sniplite 设置（删除本文件即恢复默认）\r\n");
    str_add(&s, L"; 热键写法：F1、Ctrl+Alt+A、Shift+PrtSc，none 表示不用\r\n");
    str_add(&s, L"; capture：dxgi 最快，gdi 最省内存\r\n");
    str_add(&s, L"[sniplite]\r\n");
    for (int id = 1; id < HK_COUNT; id++) {
        WCHAR k[40];
        hotkey_format(c->mod[id], c->vk[id], k);
        str_addf(&s, L"%s=%s\r\n", kHkKeys[id], k);
    }
    str_addf(&s, L"capture=%s\r\ntray=%d\r\nauto_update=%d\r\n", c->gdi ? L"gdi" : L"dxgi", c->tray ? 1 : 0,
             c->auto_update ? 1 : 0);
    /* UTF-8 without BOM: Notepad shows the comments, and the ASCII keys/values
     * read back fine through GetPrivateProfileString. */
    int n = WideCharToMultiByte(CP_UTF8, 0, s.p, s.n, NULL, 0, NULL, NULL);
    char *b = n > 0 ? mem_alloc((size_t)n) : NULL;
    bool ok = false;
    if (b) {
        WideCharToMultiByte(CP_UTF8, 0, s.p, s.n, b, n, NULL, NULL);
        HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        DWORD w = 0;
        if (f != INVALID_HANDLE_VALUE) {
            ok = WriteFile(f, b, (DWORD)n, &w, NULL) && w == (DWORD)n;
            CloseHandle(f);
        }
        mem_free(b);
    }
    str_free(&s);
    return ok;
}
