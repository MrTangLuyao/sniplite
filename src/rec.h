/* Recording: DXGI desktop duplication -> NV12 -> Media Foundation H.264/MP4.
 * The overlay starts `--record` when the user asks for a recording; --record-test
 * is the same path without a window, for measuring and for tests. */
#pragma once
#include "common.h"

int rec_test_main(int argc, WCHAR **argv); /* sniplite.exe --record-test x y w h seconds out.mp4 */
int rec_main(int argc, WCHAR **argv);      /* sniplite.exe --record x y w h out.mp4 */
