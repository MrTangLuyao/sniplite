/* Resource ids shared by sniplite.rc and the C sources. */
#pragma once

#define IDI_APP 1

#define IDD_SETTINGS 100
#define IDC_TABS 101

#define IDD_PAGE_GENERAL 110
#define IDD_PAGE_CAPTURE 111
#define IDD_PAGE_HOTKEYS 112
#define IDD_PAGE_ABOUT 113

#define IDC_AUTOSTART 120
#define IDC_TRAY 121
#define IDC_INI_PATH 122
#define IDC_OPEN_DIR 123
#define IDC_OPEN_INI 124
#define IDC_DEFAULTS 125 /* every page has its own reset button with this id */
#define IDC_DXGI 126
#define IDC_GDI 127
#define IDC_BUILTIN 128
#define IDC_VERSION 129
#define IDC_HINT 130

#define IDC_HK_FIELD 140 /* + HK_* - 1 */
#define IDC_HK_CLEAR 150 /* + HK_* - 1 */
#define IDC_HK_STATE 160 /* + HK_* - 1 */
#define IDC_HELPBTN 131
#define IDC_LANG 132 /* the language list, and the labels that get their text from lang_text.h */
#define IDC_LANG_LABEL 133
#define IDC_INI_GROUP 134
#define IDC_PATH_LABEL 135
#define IDC_MODE_LABEL 136
#define IDC_HK_LABEL1 137
#define IDC_HK_LABEL2 138
#define IDC_HK_LABEL3 139
#define IDC_TAGLINE 143
#define IDC_LICENSE 144

/* explicit per-row ids (resource scripts cannot do arithmetic reliably) */
#define IDC_HK_FIELD1 140
#define IDC_HK_FIELD2 141
#define IDC_HK_FIELD3 142
#define IDC_HK_CLEAR1 150
#define IDC_HK_CLEAR2 151
#define IDC_HK_CLEAR3 152
#define IDC_HK_STATE1 160
#define IDC_HK_STATE2 161
#define IDC_HK_STATE3 162

#define IDD_SHORTCUTS 170
#define IDC_LIST 171

/* preferences: the update page */
#define IDD_PAGE_UPDATE 180
#define IDC_U_VERSION 181
#define IDC_U_CHECK 182
#define IDC_U_STATUS 183
#define IDC_U_INSTALL 184
#define IDC_U_AUTO 185

/* installer */
#define IDD_SETUP 200
#define IDC_S_TITLE 201
#define IDC_S_SUB 202
#define IDC_S_PATH 203
#define IDC_S_AUTOSTART 204
#define IDR_APP_EXE 210
#define IDR_APP_COM 211
