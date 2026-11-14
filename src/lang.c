/* The texts in every language, and the choice between them (lang.h).
 *
 * lang_text.h is included once per language, each time keeping one column. Chinese is
 * a table of strings, usable as it is. Every other language is one block, text after
 * text in the order of the numbers, each ending in 0: UTF-16 where the characters
 * need it, UTF-8 where that is half the size. A block becomes a table like the
 * Chinese one the first time its language is used, and stays. */
#include "lang.h"

#define X(name, zh, tw, en, ja, ko, fr, de, es) L##zh,
static const WCHAR *const kChinese[S_COUNT] = {
#include "lang_text.h"
};
#undef X

/* a block in UTF-16 (W) or UTF-8 (A) */
#define W(text) L##text L"\0"
#define A(text) text "\0"

#define X(name, zh, tw, en, ja, ko, fr, de, es) W(tw)
static const WCHAR kTw[] =
#include "lang_text.h"
    ;
#undef X
#define X(name, zh, tw, en, ja, ko, fr, de, es) A(en)
static const char kEn[] =
#include "lang_text.h"
    ;
#undef X
#define X(name, zh, tw, en, ja, ko, fr, de, es) W(ja)
static const WCHAR kJa[] =
#include "lang_text.h"
    ;
#undef X
#define X(name, zh, tw, en, ja, ko, fr, de, es) W(ko)
static const WCHAR kKo[] =
#include "lang_text.h"
    ;
#undef X
#define X(name, zh, tw, en, ja, ko, fr, de, es) A(fr)
static const char kFr[] =
#include "lang_text.h"
    ;
#undef X
#define X(name, zh, tw, en, ja, ko, fr, de, es) A(de)
static const char kDe[] =
#include "lang_text.h"
    ;
#undef X
#define X(name, zh, tw, en, ja, ko, fr, de, es) A(es)
static const char kEs[] =
#include "lang_text.h"
    ;
#undef X

static const struct {
    const WCHAR *code, *name;
    const void *block; /* NULL: Chinese */
    int bytes;
    bool utf8;
} kLang[LG_COUNT] = {
    {L"zh-CN", L"简体中文", NULL, 0, false},
    {L"zh-TW", L"繁體中文", kTw, sizeof kTw, false},
    {L"en", L"English", kEn, sizeof kEn, true},
    {L"ja", L"日本語", kJa, sizeof kJa, false},
    {L"ko", L"한국어", kKo, sizeof kKo, false},
    {L"fr", L"Français", kFr, sizeof kFr, true},
    {L"de", L"Deutsch", kDe, sizeof kDe, true},
    {L"es", L"Español", kEs, sizeof kEs, true},
};

const WCHAR *const *g_tr = kChinese;
static int g_choice = LG_AUTO;

/* The table of a language. Made once and kept: a window may still hold a text of
 * the language that was in use before. */
static const WCHAR *const *table(int lang)
{
    static const WCHAR *const *made[LG_COUNT];
    if (!kLang[lang].block)
        return kChinese;
    if (!made[lang]) {
        int bytes = kLang[lang].bytes;
        bool utf8 = kLang[lang].utf8;
        /* the table, then (UTF-8) room for the texts: never more characters than bytes */
        const WCHAR **t = mem_alloc(S_COUNT * sizeof *t + (utf8 ? (size_t)bytes * sizeof(WCHAR) : 0));
        if (!t)
            return kChinese;
        const WCHAR *w = kLang[lang].block;
        if (utf8) {
            MultiByteToWideChar(CP_UTF8, 0, kLang[lang].block, bytes, (WCHAR *)(t + S_COUNT), bytes);
            w = (const WCHAR *)(t + S_COUNT);
        }
        for (int s = 0; s < S_COUNT; s++, w += lstrlenW(w) + 1)
            t[s] = w;
        made[lang] = t;
    }
    return made[lang];
}

int lang_system(void)
{
    LANGID id = GetUserDefaultUILanguage();
    switch (PRIMARYLANGID(id)) {
    case LANG_CHINESE:
        switch (SUBLANGID(id)) {
        case SUBLANG_CHINESE_TRADITIONAL:
        case SUBLANG_CHINESE_HONGKONG:
        case SUBLANG_CHINESE_MACAU:
            return LG_ZH_TW;
        }
        return LG_ZH_CN;
    case LANG_JAPANESE:
        return LG_JA;
    case LANG_KOREAN:
        return LG_KO;
    case LANG_FRENCH:
        return LG_FR;
    case LANG_GERMAN:
        return LG_DE;
    case LANG_SPANISH:
        return LG_ES;
    }
    return LG_EN;
}

void lang_choose(int lang)
{
    g_choice = lang >= 0 && lang < LG_COUNT ? lang : LG_AUTO;
    g_tr = table(g_choice == LG_AUTO ? lang_system() : g_choice);
}

int lang_choice(void) { return g_choice; }
const WCHAR *lang_name(int lang) { return kLang[lang].name; }
const WCHAR *lang_code(int lang) { return kLang[lang].code; }
const WCHAR *lang_text(int lang, int s) { return table(lang)[s]; }

void ini_path(WCHAR *out, int cap)
{
    DWORD n = GetModuleFileNameW(NULL, out, (DWORD)cap);
    WCHAR *sl = n && n < (DWORD)cap ? wcsrchr(out, L'\\') : NULL;
    if (sl && (sl - out) + 13 < cap)
        lstrcpyW(sl + 1, L"sniplite.ini");
    else
        out[0] = 0;
}

void lang_init(const WCHAR *ini)
{
    WCHAR own[MAX_PATH], v[16];
    if (!ini) {
        ini_path(own, MAX_PATH);
        ini = own;
    }
    int lang = LG_AUTO; /* also for a code this version does not know */
    if (ini[0] && GetPrivateProfileStringW(L"sniplite", L"lang", L"", v, COUNTOF(v), ini))
        for (int i = 0; i < LG_COUNT; i++)
            if (arg_eq(v, kLang[i].code))
                lang = i;
    lang_choose(lang);
}

#if !defined(CONSOLE) && !defined(SETUP)
const WCHAR *lang_save_filter(void)
{
    static WCHAR filter[160]; /* the longest is under 90 */
    int n = lstrlenW(lstrcpynW(filter, T(SAVE_FILTER), COUNTOF(filter) - 1));
    for (int i = 0; i < n; i++)
        if (filter[i] == L'|')
            filter[i] = 0;
    return filter;
}
#endif

#ifndef CONSOLE
/* ---- dialogs ------------------------------------------------------------------------
 * A dialog takes its font, and from the font its size on screen, out of its template.
 * The templates in the .rc name one font, so each is copied with the font of the
 * language in use written in its place.
 *
 * DLGTEMPLATEEX: a fixed head of 26 bytes; menu, class and title, each a string (the
 * first two may instead be 0xFFFF and a number); point size, weight, italic and
 * character set; the font name; then, on the next multiple of 4 bytes, the controls. */
static DLGTEMPLATE *dialog(HINSTANCE inst, int id)
{
    HRSRC r = FindResourceW(inst, MAKEINTRESOURCEW(id), (LPCWSTR)RT_DIALOG);
    HGLOBAL g = r ? LoadResource(inst, r) : NULL;
    const WORD *src = g ? LockResource(g) : NULL;
    size_t size = r ? SizeofResource(inst, r) : 0;
    if (!src || size < 32 || src[0] != 1 || src[1] != 0xFFFF || !(*(const DWORD *)(src + 6) & DS_SETFONT))
        return NULL;
    const WORD *p = src + 13;
    for (int k = 0; k < 2; k++) { /* menu, class */
        if (*p == 0xFFFF)
            p += 2;
        else
            while (*p++) {
            }
    }
    while (*p++) { /* title */
    }
    p += 3;
    size_t head = (size_t)((const BYTE *)p - (const BYTE *)src); /* everything before the font name */
    while (*p++) {
    }
    size_t ctl = ((size_t)((const BYTE *)p - (const BYTE *)src) + 3) & ~(size_t)3;
    size_t rest = size > ctl ? size - ctl : 0;

    const WCHAR *face = T(FONT);
    size_t name = ((size_t)lstrlenW(face) + 1) * sizeof(WCHAR);
    size_t ctl2 = (head + name + 3) & ~(size_t)3;
    BYTE *out = mem_alloc(ctl2 + rest);
    if (!out)
        return NULL;
    memcpy(out, src, head);
    out[head - 1] = DEFAULT_CHARSET; /* the template asks for the Chinese one */
    memcpy(out + head, face, name);
    memcpy(out + ctl2, (const BYTE *)src + ctl, rest);
    return (DLGTEMPLATE *)out;
}

INT_PTR lang_dialog_box(HINSTANCE inst, int id, HWND owner, DLGPROC proc)
{
    DLGTEMPLATE *t = dialog(inst, id);
    INT_PTR r = t ? DialogBoxIndirectParamW(inst, t, owner, proc, 0)
                  : DialogBoxParamW(inst, MAKEINTRESOURCEW(id), owner, proc, 0);
    mem_free(t);
    return r;
}

HWND lang_dialog_create(HINSTANCE inst, int id, HWND owner, DLGPROC proc)
{
    DLGTEMPLATE *t = dialog(inst, id);
    HWND h = t ? CreateDialogIndirectParamW(inst, t, owner, proc, 0)
               : CreateDialogParamW(inst, MAKEINTRESOURCEW(id), owner, proc, 0);
    mem_free(t);
    return h;
}
#endif
