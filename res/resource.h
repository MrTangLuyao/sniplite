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
#define IDC_TAGLINE 146
#define IDC_LICENSE 147
#define IDC_HK_LABEL4 148
#define IDC_HK_LABEL5 149

/* explicit per-row ids (resource scripts cannot do arithmetic reliably) */
#define IDC_HK_FIELD1 140
#define IDC_HK_FIELD2 141
#define IDC_HK_FIELD3 142
#define IDC_HK_FIELD4 143
#define IDC_HK_FIELD5 144
#define IDC_HK_FIELD6 145
#define IDC_HK_CLEAR1 150
#define IDC_HK_CLEAR2 151
#define IDC_HK_CLEAR3 152
#define IDC_HK_CLEAR4 153
#define IDC_HK_CLEAR5 154
#define IDC_HK_CLEAR6 155
#define IDC_HK_STATE1 160
#define IDC_HK_STATE2 161
#define IDC_HK_STATE3 162
#define IDC_HK_STATE4 163
#define IDC_HK_STATE5 164
#define IDC_HK_STATE6 165

#define IDD_SHORTCUTS 170
#define IDC_LIST 171

/* preferences: the update page */
#define IDD_PAGE_UPDATE 180
#define IDC_U_VERSION 181
#define IDC_U_CHECK 182
#define IDC_U_STATUS 183
#define IDC_U_INSTALL 184
#define IDC_U_AUTO 185

/* preferences: the text recognition page */
#define IDD_PAGE_OCR 186
#define IDC_O_STATE 187
#define IDC_O_INSTALL 188
#define IDC_O_REMOVE 189
#define IDC_O_BAR 190
#define IDC_O_STATUS 191

/* preferences, more: ids that are free between the pages above and the installer */
#define IDC_PIN_TOP 192
#define IDC_PROJECT 193 /* the About page: opens the project's page */
#define IDC_HK_LABEL6 194
#define IDC_EXIT_ASK 195
#define IDC_THEME 196
#define IDC_THEME_LABEL 197
#define IDC_SAVE_LABEL 198 /* where files go and how they are named */
#define IDC_SAVE_DIR 199
#define IDC_SAVE_PICK 220
#define IDC_NAME_LABEL 223
#define IDC_NAME 224
#define IDC_ALSO_SAVE 225
#define IDC_PIN_TEXT 226
#define IDC_DETECT_LABEL 227 /* what a capture offers under the mouse */
#define IDC_DETECT 228
#define IDC_HK_FULLSCREEN 229 /* the hotkeys step aside for a full-screen program and for the ones listed */
#define IDC_HK_APPS_LABEL 230
#define IDC_HK_APPS 231
#define IDC_FPS 212         /* the frame rate of a recording */
#define IDC_FPS_LABEL 213
#define IDC_COLOURS 214     /* the size of its palette */
#define IDC_COLOURS_LABEL 215

/* the list of programs the hotkeys step aside for (settings.c), and its text */
#define IDD_APPS 115
#define IDD_APPS_TEXT 116
#define IDC_APPS_NEW 232
#define IDC_APPS_EDIT 233
#define IDC_APPS_BROWSE 234
#define IDC_APPS_DELETE 235
#define IDC_APPS_TEXT 236
#define IDC_APPS_TEXT_LABEL 237
#define IDC_APPS_TEXT_EDIT 238

/* the question before a capture is left (main.c) */
#define IDD_LEAVE 114
#define IDC_L_TEXT 221
#define IDC_L_ASK 222

/* installer */
#define IDD_SETUP 200
#define IDC_S_TITLE 201
#define IDC_S_SUB 202
#define IDC_S_PATH 203
#define IDC_S_AUTOSTART 204
#define IDC_S_OCR 205
#define IDC_S_BROWSE 206
#define IDR_APP_EXE 210
#define IDR_APP_COM 211
