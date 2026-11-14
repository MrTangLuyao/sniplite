/* Preferences window. Runs as `sniplite.exe --settings` so its DLLs (comctl32,
 * COM, shell) never load into the background process. */
#pragma once
#include "common.h"

/* Window properties that mark the two dialogs for ipc_find_dialog. */
#define SETTINGS_MARK L"sniplite.settings"
#define SHORTCUTS_MARK L"sniplite.shortcuts"

int settings_main(HINSTANCE inst, const WCHAR *page); /* `sniplite.exe --settings [update]` */
int shortcuts_main(HINSTANCE inst); /* `sniplite.exe --shortcuts`: the short shortcut list */
