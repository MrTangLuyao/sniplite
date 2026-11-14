/* The language of everything the user reads.
 *
 * Every text has a number S_<name> (lang_text.h lists them with their wording in each
 * language) and is read through T(name). The Chinese texts are part of the program as
 * they are; another language is unpacked once, when it is first chosen. Nothing here
 * needs a call before T() works: without lang_init the language is Chinese.
 *
 * The choice is `lang=` in sniplite.ini: missing or `auto` follows the Windows display
 * language, otherwise one of the codes of lang_code(). */
#pragma once
#include "common.h"

enum {
#define X(name, ...) S_##name,
#include "lang_text.h"
#undef X
    S_COUNT
};

/* the languages, in the order of the columns of lang_text.h */
enum { LG_AUTO = -1, LG_ZH_CN, LG_ZH_TW, LG_EN, LG_JA, LG_KO, LG_FR, LG_DE, LG_ES, LG_COUNT };

extern const WCHAR *const *g_tr; /* the texts of the language in use, by S_<name> */
#define T(name) (g_tr[S_##name])

void ini_path(WCHAR *out, int cap); /* sniplite.ini next to this program; "" if that path is too long */
void lang_init(const WCHAR *ini); /* the choice in that file; NULL: sniplite.ini next to this program */
void lang_choose(int lang);       /* LG_AUTO or a language; takes effect at once (config_save keeps it) */
int lang_choice(void);            /* what was chosen: LG_AUTO or a language */
int lang_system(void);            /* the language LG_AUTO stands for on this computer */
const WCHAR *lang_name(int lang); /* in that language itself: "English", "日本語" */
const WCHAR *lang_code(int lang); /* as written in sniplite.ini: "en", "ja", "zh-CN" */
const WCHAR *lang_text(int lang, int s); /* text S_... in a language other than the one in use */

#if !defined(CONSOLE) && !defined(SETUP)
/* The file types of the save dialog: in S_SAVE_FILTER a | ends each part, where the
 * dialog wants a 0, which a text cannot hold. */
const WCHAR *lang_save_filter(void);
#endif

#ifndef CONSOLE
/* A dialog of this program in the font of the language in use (the resource names the
 * Chinese one). Both work like the functions they are named after. */
INT_PTR lang_dialog_box(HINSTANCE inst, int id, HWND owner, DLGPROC proc);
HWND lang_dialog_create(HINSTANCE inst, int id, HWND owner, DLGPROC proc);
#endif
