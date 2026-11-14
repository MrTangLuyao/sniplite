@echo off
rem Build sniplite: x86-64 assembly where speed matters (capture, composition, drawing,
rem the capture overlay, images: src\*.S, GNU as through gcc) and C for the rest
rem (src\*.c). No C runtime: src\crt.c has the few library functions the C uses.
rem Each program carries its texts in every language (src\lang.c, src\lang_text.h).
rem Needs MinGW-w64 binutils and gcc on PATH (e.g. w64devkit). Output goes to build\.
setlocal
cd /d "%~dp0"
where gcc >nul 2>nul || (echo gcc not found: put MinGW-w64 ^(e.g. w64devkit^) on PATH & exit /b 1)
if not exist build mkdir build

rem src\start.S is the entry point (start); every program links only what it uses.
set CF=-Isrc -Ires -std=c11 -Os -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers ^
 -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -fno-math-errno -ffunction-sections -fdata-sections -fno-ident
set LDFLAGS=-nostdlib -nostartfiles -e start -s -Wl,--gc-sections -Wl,--nxcompat -Wl,--dynamicbase ^
 -Wl,--high-entropy-va

windres --input-format=rc -O coff -I res res\sniplite.rc build\sniplite.res || exit /b 1
windres --input-format=rc -O coff -I res -DSNIPLITE_CLI res\sniplite.rc build\cli.res || exit /b 1

gcc %CF% -Wl,--subsystem,windows -o build\sniplite.exe src\start.S src\main.c src\ov_base.S src\ov_edit.S ^
 src\ov_paint.S src\ov_show.S src\ov_input.S src\present.S src\shot.S src\draw.S src\pin.c src\image.S ^
 src\config.c src\settings.c src\update.c src\uninstall.c src\util.c src\ipc.c src\lang.c src\crt.c ^
 build\sniplite.res ^
 %LDFLAGS% -lkernel32 -luser32 -lgdi32 -ldwmapi -limm32 -luuid -lgcc || exit /b 1
gcc %CF% -DCONSOLE -Wl,--subsystem,console -o build\sniplite.com src\start.S src\cli.c src\update.c src\util.c ^
 src\ipc.c src\lang.c src\crt.c build\cli.res %LDFLAGS% -lkernel32 -luser32 -lgdi32 -lgcc || exit /b 1

rem The installer carries both files above as resources, so it is built last.
windres --input-format=rc -O coff -I res -I build res\setup.rc build\setup.res || exit /b 1
gcc %CF% -DSETUP -Wl,--subsystem,windows -o build\sniplite_win_setup_amd64.exe src\start.S src\setup.c ^
 src\util.c src\lang.c src\crt.c build\setup.res %LDFLAGS% -lkernel32 -luser32 -lgdi32 -lole32 -lshell32 -ladvapi32 -luuid -lgcc ^
 || exit /b 1

for %%f in (build\sniplite.exe build\sniplite.com build\sniplite_win_setup_amd64.exe) do echo %%~nxf  %%~zf bytes
