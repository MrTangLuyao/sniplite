/* Update check and download (GitHub releases). Only ever runs in short-lived
 * helper processes, never in the background process. */
#pragma once
#include "common.h"

#ifndef UPDATE_REPO /* a test build may point elsewhere */
#define UPDATE_REPO L"/MrTangLuyao/sniplite"
#endif
#define UPDATE_HOST L"github.com"
#define SETUP_FILE L"sniplite_win_setup_amd64.exe"

typedef enum {
    UPD_ERROR,  /* no network, GitHub unreachable, ... */
    UPD_NONE,   /* no release published yet */
    UPD_LATEST, /* this is the newest version */
    UPD_NEWER,  /* tag holds a newer release */
} UpdState;

typedef struct {
    UpdState state;
    WCHAR tag[32]; /* e.g. "v1.0.1" */
} UpdateResult;

int version_cmp(const WCHAR *a, const WCHAR *b); /* "1.0.0" vs "v1.0.1": <0, 0, >0 */

/* Blocking (a few seconds at most); call from a worker thread. */
void update_check(UpdateResult *r);

/* Download the installer of `tag` to %TEMP%. progress(percent, ctx) may be called
 * repeatedly with 0..100, or with -1 when the size is unknown. Blocking. */
bool update_download(const WCHAR *tag, WCHAR *path, int cap, void (*progress)(int, void *), void *ctx);

/* Is this program running from the folder the installer uses? Only that copy can
 * be updated in place; a copy elsewhere (e.g. built from source) is left alone. */
bool update_installed_copy(void);

/* `sniplite.exe --update-check`: if a newer release exists, tell the background process. */
int update_check_main(void);
