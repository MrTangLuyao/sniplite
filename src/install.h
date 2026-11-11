/* Where the installer puts things, shared by the installer and the uninstaller.
 * Per-user, no admin rights, no registry. */
#pragma once

#define INSTALL_DIR L"%LOCALAPPDATA%\\Programs\\sniplite"
#define MENU_FOLDER L"sniplite"                  /* under the user's Start menu Programs */
#define MENU_APP_LNK L"sniplite.lnk"
#define MENU_UNINSTALL_LNK L"卸载 sniplite.lnk"
#define STARTUP_LNK L"sniplite.lnk"              /* under the user's Startup folder (same as 首选项) */

int uninstall_main(bool silent); /* `sniplite.exe --uninstall [/S]` */
