/* A stub of the Windows header, so that src/common.h can be compiled on a
 * machine that has no Windows: the encoder in src/gif.c is checked here, and
 * it needs nothing of Windows but the types. The real header is found through
 * the angle brackets of common.h; this one through -Itools/gifref/win.
 *
 * Only what common.h uses is here. */
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <wchar.h>

typedef wchar_t WCHAR;
typedef int BOOL;
typedef unsigned short WORD;
typedef unsigned char BYTE;
typedef BYTE *LPBYTE;
typedef unsigned int UINT;
typedef unsigned long DWORD;
typedef long LONG;
typedef void *HANDLE;
typedef void *HWND;
typedef void *HDC;
typedef void *HBITMAP;
typedef void *HGDIOBJ;
typedef void *HMONITOR;
typedef void *HINSTANCE;

typedef struct {
    LONG left, top, right, bottom;
} RECT;
typedef struct {
    LONG x, y;
} POINT;

typedef struct {
    DWORD cb;
    WCHAR *lpReserved, *lpDesktop, *lpTitle;
    DWORD dwX, dwY, dwFlags, dwShowWindow;
    WORD cbReserved2;
    LPBYTE lpReserved2, lpStdInput, lpStdOutput, lpStdError;
} STARTUPINFOW;
typedef struct {
    HANDLE hProcess, hThread;
    DWORD dwProcessId, dwThreadId;
} PROCESS_INFORMATION;
