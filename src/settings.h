/* Preferences window. Runs as `sniplite.exe --settings` so its DLLs (comctl32,
 * COM, shell) never load into the background process. */
#pragma once
#include "common.h"

#define SETTINGS_TITLE L"sniplite 首选项"
#define SHORTCUTS_TITLE L"sniplite 快捷键"

int settings_main(HINSTANCE inst, const WCHAR *page); /* `sniplite.exe --settings [update]` */
int shortcuts_main(HINSTANCE inst); /* `sniplite.exe --shortcuts`: the short shortcut list */
