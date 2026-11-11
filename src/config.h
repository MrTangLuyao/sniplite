/* Settings (sniplite.ini next to the exe) and hotkey text <-> key codes. */
#pragma once
#include "common.h"

enum { HK_CAPTURE = 1, HK_PIN, HK_TOGGLE, HK_COUNT };

typedef struct {
    UINT mod[HK_COUNT], vk[HK_COUNT]; /* index HK_*; vk 0 = no hotkey */
    bool gdi;                         /* GDI capture instead of DXGI */
    bool tray;                        /* show the notification-area icon */
    bool auto_update;                 /* look for a newer release after start-up, then daily */
} Config;

void config_defaults(Config *c);             /* Snipaste-compatible: F1 / F3 / Shift+F3 */
bool config_load(Config *c);                 /* defaults + sniplite.ini if present */
bool config_save(const Config *c);
void config_path(WCHAR *out, int cap);

bool hotkey_parse(const WCHAR *s, UINT *mod, UINT *vk); /* "Ctrl+Alt+A", "F1", "none" */
void hotkey_format(UINT mod, UINT vk, WCHAR *out);      /* out: >= 40 chars; "none" if vk == 0 */
