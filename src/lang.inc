/* The texts, for the assembly (lang.h, lang_text.h).
 *
 * g_tr points to the table of the language in use: one pointer per text, in the
 * order of the rows of lang_text.h. S_<name> is the number of a row, counted here
 * the way the C enum counts them, and
 *
 *         TR rdx, PIN_COPIED
 *
 * loads the address of that text. The table changes when the user picks another
 * language, so a text is looked up when it is needed, never kept. */
        .set .Lsn, 0
#define X(name, ...) .equ S_##name, .Lsn; .set .Lsn, .Lsn + 1
#include "lang_text.h"
#undef X

.macro TR reg, name
        mov \reg, qword ptr [rip + g_tr]
        mov \reg, qword ptr [\reg + 8 * S_\name]
.endm
