/* ov_base.S: the capture overlay's basics: its state O, helpers, window detection,
 * annotations and their rendering, the canvas.
 *
 * What makes it fast: the rect helpers (rect_isect, rect_union, rect_inflate,
 * rect_corners) are inlined; a pen stroke's bounds are a vectorized min/max; text
 * lines are found 8 characters at a time, and a text's measurements are memorized
 * per text and size, because painting asks for them on every band; the float
 * buffer for strokes grows geometrically and is not copied when it grows; the
 * number of a numbered marker is formatted inline. */
#include "asm.inc"
#include "ov_layout.inc"
#include "lang.inc"

/* ---- Windows values ----------------------------------------------------------------- */
#define OB_GWL_EXSTYLE (-20)
#define OB_WS_EX_TRANSPARENT 0x20
#define OB_WS_EX_LAYERED 0x80000
#define OB_LWA_ALPHA 2
#define OB_DWMWA_EXTENDED_FRAME_BOUNDS 9
#define OB_DWMWA_CLOAKED 14
#define OB_CWP_FLAGS 5                  /* CWP_SKIPINVISIBLE | CWP_SKIPTRANSPARENT */
#define OB_FW_NORMAL 400
#define OB_FW_BOLD 700
#define OB_DEFAULT_CHARSET 1
#define OB_ANTIALIASED_QUALITY 4
#define OB_CLEARTYPE_QUALITY 5
#define OB_TRANSPARENT 1
#define OB_DT_TEXT 0x900                /* DT_LEFT | DT_TOP | DT_NOPREFIX | DT_NOCLIP */
#define OB_DT_NUMBER 0x925              /* DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_NOCLIP */
#define OB_TM_HEIGHT 0                  /* TEXTMETRICW.tmHeight */
#define OB_TM_SIZE 60                   /* sizeof(TEXTMETRICW) */
/* ---- end of checked values ------------------------------------------------------------ */

#define OB_NFONTS 6                     /* OvState.fonts[] */
#define OB_FONT_PX (OV_FONTS_PX - OV_FONTS)
#define OB_FONT_BOLD (OV_FONTS_BOLD - OV_FONTS)
#define OB_FONT_F (OV_FONTS_F - OV_FONTS)
#define OB_INT_MAX 0x7FFFFFFF

/* fields of O */
#define o(f) [rip + O + f]
#define OV_VX (OV_SHOT + SHOT_VX)
#define OV_VY (OV_SHOT + SHOT_VY)
#define OV_VW (OV_SHOT + SHOT_VW)
#define OV_VH (OV_SHOT + SHOT_VH)
#define OV_TILE0 (OV_SHOT + SHOT_TILE)

        .if (OV_FBUF - OV_FONTS) != OB_NFONTS * OV_FONTS_BYTES
        .error "OvState.fonts is not 6 entries before fbuf"
        .endif

/* ---- data ----------------------------------------------------------------------------- */

        .section .bss$ov_base,"bw"
        .balign 32
        .globl O
O:      .space OV_BYTES
/* the language (g_tr) O.font_ui was made for; 0 before the first one */
.Lfont_tr:      .space 8

/* text_box's memo: its result is a function of the text, its length and the font
 * size (the position only moves it), but painting asks for it on every band. An
 * entry holds a private copy of the text; lines == 0 marks it unused. Cleared by
 * free_fonts, at the end of each capture. */
#define TC_COUNT 8                      /* a power of two */
#define TC_COPY 0
#define TC_LEN 8
#define TC_PX 12
#define TC_W 16                         /* the widest line */
#define TC_LINES 20
#define TC_LAST 24                      /* the last line's width */
#define TC_TMH 28                       /* the line height */
#define TC_BYTES 32
        .balign 16
.Ltc:           .space TC_COUNT * TC_BYTES
.Ltc_next:      .space 4                /* the entry replaced next */

        .section .rdata$ov_base,"dr"
        .balign 16
.Lsign4:        .long 0x80000000, 0x80000000, 0x80000000, 0x80000000
.Lalmost4:      .long 0x3EFFFFFF, 0x3EFFFFFF, 0x3EFFFFFF, 0x3EFFFFFF   /* 0.49999997f x4 */
.Lhalf4:        .long 0x3F000000, 0x3F000000, 0x3F000000, 0x3F000000   /* 0.5f x4 */
.Lnl8:          .short 10, 10, 10, 10, 10, 10, 10, 10                   /* L'\n' x8 */
.Lf_half:       .long 0x3F000000        /* 0.5f */
.Lf_1_5:        .long 0x3FC00000        /* 1.5f */
.Lf_7:          .long 0x40E00000        /* 7.0f */
.Lf_12:         .long 0x41400000        /* 12.0f */
.Lf_1_05:       .long 0x3F866666        /* 1.05f */
.Lf_1_25:       .long 0x3FA00000        /* 1.25f */

        .globl kTbOrder
kTbOrder:       .long T_RECT, T_ELLIPSE, T_LINE, T_ARROW, T_PEN, T_MARKER, T_MOSAIC, T_TEXT, T_NUMBER
                .long -1, B_UNDO, B_REDO, -1, B_PIN, B_SAVE, B_CLOSE, B_OK
        .globl kColors
kColors:        .long 0xE53935, 0xFB8C00, 0xFDD835, 0x43A047, 0x1E88E5, 0x8E24AA, 0x000000, 0xFFFFFF
/* tool_px indexes these five as one table: keep them together, in this order */
        .globl kStroke
kStroke:        .long 2, 4, 8
        .globl kMarker
kMarker:        .long 10, 16, 26
        .globl kBlock
kBlock:         .long 6, 10, 16
        .globl kFont
kFont:          .long 16, 24, 36
        .globl kNumber
kNumber:        .long 10, 13, 18

        .balign 2
/* L"Progman" */
.Lw_progman:    .short 0x0050, 0x0072, 0x006F, 0x0067, 0x006D, 0x0061, 0x006E, 0
/* L"WorkerW" */
.Lw_workerw:    .short 0x0057, 0x006F, 0x0072, 0x006B, 0x0065, 0x0072, 0x0057, 0
/* L"sniplite.poke" */
.Lw_poke:       .short 0x0073, 0x006E, 0x0069, 0x0070, 0x006C, 0x0069, 0x0074, 0x0065, 0x002E, 0x0070
                .short 0x006F, 0x006B, 0x0065, 0

/* ---- macros ------------------------------------------------------------------------------ */

/* eax = MAXI(1, lroundf(xmm0)); clobbers ecx, xmm1. The rounding is asm.inc's
 * LROUNDF (xmm0 + (+-0.49999997f with xmm0's sign), truncated) done without
 * leaving the SSE registers. */
.macro ROUND_MIN1
        movaps xmm1, xmm0
        andps xmm1, xmmword ptr [rip + .Lsign4]
        orps xmm1, xmmword ptr [rip + .Lalmost4]
        addss xmm1, xmm0
        cvttss2si eax, xmm1
        mov ecx, 1
        cmp eax, ecx
        cmovl eax, ecx
.endm

/* (l, t, r, b) = rect_corners of the POINTs at [pa] and [pb] (32-bit registers) */
.macro CORNERS l, t, r, b, pa, pb, tmp
        mov \l, dword ptr [\pa]
        mov \r, dword ptr [\pb]
        mov \tmp, \l
        cmp \l, \r
        cmovg \l, \r                    /* min x */
        cmp \r, \tmp
        cmovl \r, \tmp                  /* max x */
        mov \t, dword ptr [\pa + 4]
        mov \b, dword ptr [\pb + 4]
        mov \tmp, \t
        cmp \t, \b
        cmovg \t, \b
        cmp \b, \tmp
        cmovl \b, \tmp
        inc \r
        inc \b
.endm

/* (l, t, r, b) = rect_isect((l, t, r, b), client_rect()), zeros when empty; jumps
 * to \empty in that case if given */
.macro ISECT_CLIENT l, t, r, b, tmp, empty
        xor \tmp, \tmp
        cmp \l, \tmp
        cmovl \l, \tmp
        cmp \t, \tmp
        cmovl \t, \tmp
        mov \tmp, dword ptr o(OV_VW)
        cmp \r, \tmp
        cmovg \r, \tmp
        mov \tmp, dword ptr o(OV_VH)
        cmp \b, \tmp
        cmovg \b, \tmp
        cmp \r, \l
        jle 98f
        cmp \b, \t
        jg 99f
98:     xor \l, \l
        xor \t, \t
        xor \r, \r
        xor \b, \b
        .ifnb \empty
        jmp \empty
        .endif
99:
.endm

/* (l, t, r, b) = rect_isect((l, t, r, b), the RECT at [m]), zeros when empty */
.macro ISECT_MEM l, t, r, b, m, tmp
        mov \tmp, dword ptr [\m + RC_L]
        cmp \l, \tmp
        cmovl \l, \tmp
        mov \tmp, dword ptr [\m + RC_T]
        cmp \t, \tmp
        cmovl \t, \tmp
        mov \tmp, dword ptr [\m + RC_R]
        cmp \r, \tmp
        cmovg \r, \tmp
        mov \tmp, dword ptr [\m + RC_B]
        cmp \b, \tmp
        cmovg \b, \tmp
        cmp \r, \l
        jle 98f
        cmp \b, \t
        jg 99f
98:     xor \l, \l
        xor \t, \t
        xor \r, \r
        xor \b, \b
99:
.endm

/* Store (l, t, r, b) at [m] */
.macro STORE_RECT m, l, t, r, b
        mov dword ptr [\m + RC_L], \l
        mov dword ptr [\m + RC_T], \t
        mov dword ptr [\m + RC_R], \r
        mov dword ptr [\m + RC_B], \b
.endm

/* Jump to \no unless the RECT (l, t, r, b), assumed non-empty, lies inside [m] */
.macro WITHIN_MEM l, t, r, b, m, no
        cmp \l, dword ptr [\m + RC_L]
        jl \no
        cmp \t, dword ptr [\m + RC_T]
        jl \no
        cmp \r, dword ptr [\m + RC_R]
        jg \no
        cmp \b, dword ptr [\m + RC_B]
        jg \no
.endm

/* Jump to \no unless the n bytes (n in r8, even) at r9 and r10 are equal, 64 at a
 * time; clobbers rax, r8-r10, xmm0-xmm4 */
.macro MEMEQ no
        cmp r9, r10
        je 6f
1:      cmp r8, 64
        jb 2f
        movdqu xmm0, xmmword ptr [r9]
        movdqu xmm1, xmmword ptr [r10]
        pcmpeqb xmm0, xmm1
        movdqu xmm1, xmmword ptr [r9 + 16]
        movdqu xmm2, xmmword ptr [r10 + 16]
        pcmpeqb xmm1, xmm2
        movdqu xmm2, xmmword ptr [r9 + 32]
        movdqu xmm3, xmmword ptr [r10 + 32]
        pcmpeqb xmm2, xmm3
        movdqu xmm3, xmmword ptr [r9 + 48]
        movdqu xmm4, xmmword ptr [r10 + 48]
        pcmpeqb xmm3, xmm4
        pand xmm0, xmm1
        pand xmm2, xmm3
        pand xmm0, xmm2
        pmovmskb eax, xmm0
        cmp eax, 0xFFFF
        jne \no
        add r9, 64
        add r10, 64
        sub r8, 64
        jmp 1b
2:      cmp r8, 16
        jb 3f
        movdqu xmm0, xmmword ptr [r9]
        movdqu xmm1, xmmword ptr [r10]
        pcmpeqb xmm0, xmm1
        pmovmskb eax, xmm0
        cmp eax, 0xFFFF
        jne \no
        add r9, 16
        add r10, 16
        sub r8, 16
        jmp 2b
3:      cmp r8, 8
        jb 4f
        mov rax, qword ptr [r9]
        cmp rax, qword ptr [r10]
        jne \no
        add r9, 8
        add r10, 8
        sub r8, 8
4:      cmp r8, 4
        jb 5f
        mov eax, dword ptr [r9]
        cmp eax, dword ptr [r10]
        jne \no
        add r9, 4
        add r10, 4
        sub r8, 4
5:      test r8, r8
        jz 6f
        movzx eax, word ptr [r9]
        cmp ax, word ptr [r10]
        jne \no
6:
.endm

/* Copy n bytes (n in r10, even) from r9 to r8; clobbers rax, r8-r10, xmm0 */
.macro COPYW
1:      cmp r10, 16
        jb 2f
        movdqu xmm0, xmmword ptr [r9]
        movdqu xmmword ptr [r8], xmm0
        add r8, 16
        add r9, 16
        sub r10, 16
        jmp 1b
2:      test r10, r10
        jz 3f
        movzx eax, word ptr [r9]
        mov word ptr [r8], ax
        add r8, 2
        add r9, 2
        sub r10, 2
        jmp 2b
3:
.endm

/* ---- small helpers ------------------------------------------------------------------------ */

/* int S(float v): MAXI(1, lroundf(v * O.s)) */
FUNC S
        ENDPROLOG
        mulss xmm0, dword ptr o(OV_S)
        ROUND_MIN1
        ret
ENDF

/* COLORREF cref(uint32_t c): 0xRRGGBB -> 0x00BBGGRR */
FUNC cref
        ENDPROLOG
        mov eax, ecx
        bswap eax
        shr eax, 8
        ret
ENDF

/* RECT client_rect(void) */
FUNC client_rect
        ENDPROLOG
        mov rax, rcx
        mov rdx, qword ptr o(OV_VW)     /* vw, vh */
        mov qword ptr [rcx + RC_L], 0
        mov qword ptr [rcx + RC_R], rdx
        ret
ENDF

/* RECT mon_rect_at(int x, int y): the nearest monitor's rectangle (client coordinates) */
FUNC mon_rect_at
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        lea rcx, o(OV_SHOT)
        call shot_tile_at
        cdqe
        imul rax, rax, TILE_BYTES
        lea rdx, o(OV_TILE0 + TILE_RC)
        movdqu xmm0, xmmword ptr [rdx + rax]
        movdqu xmmword ptr [rbx], xmm0
        mov rax, rbx
        add rsp, 32
        pop rbx
        ret
ENDF

/* void inv(RECT r) */
FUNC inv
        ENDPROLOG
        mov eax, dword ptr [rcx + RC_L]
        cmp dword ptr [rcx + RC_R], eax
        jle 1f
        mov eax, dword ptr [rcx + RC_T]
        cmp dword ptr [rcx + RC_B], eax
        jle 1f
        mov rdx, rcx                    /* our copy of r, in the caller's frame */
        mov rcx, qword ptr o(OV_HWND)
        xor r8d, r8d
        jmp qword ptr [rip + __imp_InvalidateRect]
1:      ret
ENDF

/* void inv_ring(RECT r, int d): the four bands of width 2d along r's edges */
FUNC inv_ring
        PUSHREG rbx
        ALLOC 96                        /* [32]: the four rectangles */
        ENDPROLOG
        mov eax, dword ptr [rcx + RC_L]
        mov r8d, dword ptr [rcx + RC_T]
        mov r9d, dword ptr [rcx + RC_R]
        mov r10d, dword ptr [rcx + RC_B]
        cmp r9d, eax
        jle .Lir_ret
        cmp r10d, r8d
        jle .Lir_ret
        /* top {l-d, t-d, r+d, t+d}, bottom {l-d, b-d, r+d, b+d},
         * left {l-d, t-d, l+d, b+d}, right {r-d, t-d, r+d, b+d} */
        mov ecx, eax
        sub ecx, edx
        mov dword ptr [rsp + 32], ecx
        mov dword ptr [rsp + 48], ecx
        mov dword ptr [rsp + 64], ecx
        mov ecx, r8d
        sub ecx, edx
        mov dword ptr [rsp + 36], ecx
        mov dword ptr [rsp + 68], ecx
        mov dword ptr [rsp + 84], ecx
        mov ecx, r9d
        add ecx, edx
        mov dword ptr [rsp + 40], ecx
        mov dword ptr [rsp + 56], ecx
        mov dword ptr [rsp + 88], ecx
        add r8d, edx
        mov dword ptr [rsp + 44], r8d
        mov ecx, r10d
        sub ecx, edx
        mov dword ptr [rsp + 52], ecx
        add r10d, edx
        mov dword ptr [rsp + 60], r10d
        mov dword ptr [rsp + 76], r10d
        mov dword ptr [rsp + 92], r10d
        add eax, edx
        mov dword ptr [rsp + 72], eax
        sub r9d, edx
        mov dword ptr [rsp + 80], r9d
        lea rbx, [rsp + 32]
.Lir_loop:
        mov eax, dword ptr [rbx + RC_L]
        cmp dword ptr [rbx + RC_R], eax
        jle .Lir_next
        mov eax, dword ptr [rbx + RC_T]
        cmp dword ptr [rbx + RC_B], eax
        jle .Lir_next
        mov rcx, qword ptr o(OV_HWND)
        mov rdx, rbx
        xor r8d, r8d
        API InvalidateRect
.Lir_next:
        add rbx, 16
        lea rax, [rsp + 96]
        cmp rbx, rax
        jb .Lir_loop
.Lir_ret:
        add rsp, 96
        pop rbx
        ret
ENDF

/* int border_t(void): MAXI(1, lroundf(1.5f * O.s)) */
FUNC border_t
        ENDPROLOG
        movss xmm0, dword ptr [rip + .Lf_1_5]
        mulss xmm0, dword ptr o(OV_S)
        ROUND_MIN1
        ret
ENDF

/* int handle_sz(void): S(7) | 1 */
FUNC handle_sz
        ENDPROLOG
        movss xmm0, dword ptr [rip + .Lf_7]
        mulss xmm0, dword ptr o(OV_S)
        ROUND_MIN1
        or eax, 1
        ret
ENDF

/* int ring_w(void): border_t() + handle_sz() + 3 */
FUNC ring_w
        ENDPROLOG
        movss xmm2, dword ptr o(OV_S)
        movss xmm0, dword ptr [rip + .Lf_1_5]
        mulss xmm0, xmm2
        ROUND_MIN1
        mov edx, eax
        movss xmm0, dword ptr [rip + .Lf_7]
        mulss xmm0, xmm2
        ROUND_MIN1
        or eax, 1
        lea eax, [rax + rdx + 3]
        ret
ENDF

/* rax = CreateFontW(ecx, 0, 0, 0, edx, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
 * CLIP_DEFAULT_PRECIS, r8d, DEFAULT_PITCH, the font of the language in use) */
SFUNC ovb_font
#ifdef OB_TEST                          /* a global name, for tracing in tests */
        .globl ovb_font_t
ovb_font_t:
#endif
        ALLOC 120
        ENDPROLOG
        mov dword ptr [rsp + 32], edx   /* weight */
        xor eax, eax
        mov dword ptr [rsp + 40], eax   /* italic, underline, strike-out */
        mov dword ptr [rsp + 48], eax
        mov dword ptr [rsp + 56], eax
        mov dword ptr [rsp + 64], OB_DEFAULT_CHARSET
        mov dword ptr [rsp + 72], eax   /* OUT_DEFAULT_PRECIS */
        mov dword ptr [rsp + 80], eax   /* CLIP_DEFAULT_PRECIS */
        mov dword ptr [rsp + 88], r8d   /* quality */
        mov dword ptr [rsp + 96], eax   /* DEFAULT_PITCH */
        TR rax, FONT
        mov qword ptr [rsp + 104], rax
        xor edx, edx
        xor r8d, r8d
        xor r9d, r9d
        API CreateFontW
        add rsp, 120
        ret
ENDF

/* HFONT get_font(int px, bool bold): cached in O.fonts (6 entries; when full,
 * the first is replaced) */
FUNC get_font
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 32
        ENDPROLOG
        mov esi, ecx
        movzx edi, dl
        lea rbx, o(OV_FONTS)
        xor eax, eax                    /* entry offset */
        mov r9, -1                      /* first free entry */
.Lgf_find:
        mov rcx, qword ptr [rbx + rax + OB_FONT_F]
        test rcx, rcx
        jz .Lgf_free
        cmp dword ptr [rbx + rax + OB_FONT_PX], esi
        jne .Lgf_next
        cmp byte ptr [rbx + rax + OB_FONT_BOLD], dil
        jne .Lgf_next
        mov rax, rcx
        jmp .Lgf_ret
.Lgf_free:
        test r9, r9
        jns .Lgf_next
        mov r9, rax
.Lgf_next:
        add eax, OV_FONTS_BYTES
        cmp eax, OB_NFONTS * OV_FONTS_BYTES
        jb .Lgf_find
        test r9, r9
        jns .Lgf_slot
        mov rcx, qword ptr [rbx + OB_FONT_F]    /* all in use: replace the first */
        API DeleteObject
        xor r9d, r9d
.Lgf_slot:
        add rbx, r9
        mov ecx, esi
        neg ecx
        mov edx, OB_FW_NORMAL
        mov eax, OB_FW_BOLD
        test edi, edi
        cmovnz edx, eax
        mov r8d, OB_ANTIALIASED_QUALITY
        call ovb_font
        mov dword ptr [rbx + OB_FONT_PX], esi
        mov byte ptr [rbx + OB_FONT_BOLD], dil
        mov qword ptr [rbx + OB_FONT_F], rax
.Lgf_ret:
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void free_fonts(void) */
FUNC free_fonts
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        xor ebx, ebx
.Lff_loop:
        lea rax, o(OV_FONTS + OB_FONT_F)
        mov rcx, qword ptr [rax + rbx]
        test rcx, rcx
        jz .Lff_next
        API DeleteObject
.Lff_next:
        add ebx, OV_FONTS_BYTES
        cmp ebx, OB_NFONTS * OV_FONTS_BYTES
        jb .Lff_loop
        xorps xmm0, xmm0
        lea rax, o(OV_FONTS)
        movups xmmword ptr [rax], xmm0
        movups xmmword ptr [rax + 16], xmm0
        movups xmmword ptr [rax + 32], xmm0
        movups xmmword ptr [rax + 48], xmm0
        movups xmmword ptr [rax + 64], xmm0
        movups xmmword ptr [rax + 80], xmm0
        lea rbx, [rip + .Ltc]           /* and text_box's memo */
.Lff_memo:
        mov rcx, qword ptr [rbx + TC_COPY]
        call mem_free
        xorps xmm0, xmm0
        movaps xmmword ptr [rbx], xmm0
        movaps xmmword ptr [rbx + 16], xmm0
        add rbx, TC_BYTES
        lea rax, [rip + .Ltc + TC_COUNT * TC_BYTES]
        cmp rbx, rax
        jb .Lff_memo
        mov dword ptr [rip + .Ltc_next], 0
        add rsp, 32
        pop rbx
        ret
ENDF

/* void ensure_ui_font(void): O.font_ui at -S(12) px for the current scale, in the
 * font of the language in use. The font is kept from one capture to the next, so
 * this is also where a change of language is noticed: each language has its own
 * table, so another g_tr since the font was made means another language. */
FUNC ensure_ui_font
        ALLOC 40
        ENDPROLOG
        mov rax, qword ptr [rip + g_tr]
        mov rdx, qword ptr [rip + .Lfont_tr]
        mov qword ptr [rip + .Lfont_tr], rax
        mov rcx, qword ptr o(OV_FONT_UI)
        test rcx, rcx
        jz .Leu_create
        test rdx, rdx                   /* no language on record: the font is this one's */
        jz 1f
        cmp rdx, rax
        jne .Leu_delete
1:      movss xmm0, dword ptr o(OV_FONT_S)
        ucomiss xmm0, dword ptr o(OV_S)
        jp .Leu_delete
        je .Leu_ret
.Leu_delete:
        API DeleteObject
.Leu_create:
        movss xmm0, dword ptr [rip + .Lf_12]
        mulss xmm0, dword ptr o(OV_S)
        ROUND_MIN1
        mov ecx, eax
        neg ecx
        mov edx, OB_FW_NORMAL
        mov r8d, OB_CLEARTYPE_QUALITY
        call ovb_font
        mov qword ptr o(OV_FONT_UI), rax
        mov eax, dword ptr o(OV_S)
        mov dword ptr o(OV_FONT_S), eax
.Leu_ret:
        add rsp, 40
        ret
ENDF

/* SIZE text_size(HFONT f, const WCHAR *t, int n): measured on O.mdc */
FUNC text_size
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 48                        /* [32]: SIZE */
        ENDPROLOG
        mov rsi, rdx
        mov edi, r8d
        mov qword ptr [rsp + 32], 0
        mov rdx, rcx
        mov rcx, qword ptr o(OV_MDC)
        API SelectObject
        mov rbx, rax
        test edi, edi
        jle 1f
        mov rcx, qword ptr o(OV_MDC)
        mov rdx, rsi
        mov r8d, edi
        lea r9, [rsp + 32]
        API GetTextExtentPoint32W
1:      mov rcx, qword ptr o(OV_MDC)
        mov rdx, rbx
        API SelectObject
        mov rax, qword ptr [rsp + 32]
        add rsp, 48
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* int tool_px(int tool, int idx): the tool's size table entry, scaled */
FUNC tool_px
        ENDPROLOG
        lea eax, [rcx - T_PEN]          /* marker, mosaic, text, number: tables 1..4 */
        xor r8d, r8d
        cmp eax, 4
        cmova eax, r8d                  /* everything else: kStroke */
        lea rax, [rax + rax*2]
        movsxd rdx, edx
        add rax, rdx
        lea rcx, [rip + kStroke]
        xorps xmm0, xmm0
        cvtsi2ss xmm0, dword ptr [rcx + rax*4]
        mulss xmm0, dword ptr o(OV_S)
        ROUND_MIN1
        ret
ENDF

/* float *fbuf_get(int n): room for n floats in O.fbuf (contents not kept) */
FUNC fbuf_get
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rax, qword ptr o(OV_FBUF)
        mov edx, dword ptr o(OV_FBUF_CAP)
        cmp ecx, edx
        jle .Lfb_ret
        add edx, edx                    /* grow to MAXI(n, 2 * cap) */
        cmp edx, ecx
        cmovl edx, ecx
        mov ebx, edx
        mov rcx, rax
        call mem_free
        mov qword ptr o(OV_FBUF), 0
        mov dword ptr o(OV_FBUF_CAP), 0
        movsxd rcx, ebx
        shl rcx, 2
        call mem_alloc
        test rax, rax
        jz .Lfb_ret
        mov qword ptr o(OV_FBUF), rax
        mov dword ptr o(OV_FBUF_CAP), ebx
.Lfb_ret:
        add rsp, 32
        pop rbx
        ret
ENDF

/* void update_scale(void): O.s from the monitor under the cursor (editing: under
 * the selection's bottom-right corner) */
FUNC update_scale
        ALLOC 40
        ENDPROLOG
        mov edx, dword ptr o(OV_CUR + PT_X)
        mov r8d, dword ptr o(OV_CUR + PT_Y)
        cmp dword ptr o(OV_PHASE), PH_EDIT
        jne 1f
        mov edx, dword ptr o(OV_SEL + RC_R)
        dec edx
        mov r8d, dword ptr o(OV_SEL + RC_B)
        dec r8d
1:      lea rcx, o(OV_SHOT)
        call shot_tile_at
        cdqe
        imul rax, rax, TILE_BYTES
        lea rcx, o(OV_TILE0 + TILE_SCALE)
        mov eax, dword ptr [rcx + rax]
        mov dword ptr o(OV_S), eax
        add rsp, 40
        jmp ensure_ui_font
ENDF

/* ---- window detection ------------------------------------------------------------------------ */

/* BOOL CALLBACK enum_cb(HWND h, LPARAM lp): records the windows a capture can snap to */
FUNC enum_cb
        PUSHREG rbx
        ALLOC 96                        /* [32] RECT, [48] class name, [80] flags, [84] alpha, [88] cloaked */
        ENDPROLOG
        cmp dword ptr o(OV_NWIN), MAX_WINS
        jge .Lec_ret
        cmp rcx, qword ptr o(OV_HWND)
        je .Lec_ret
        mov rbx, rcx
        API IsWindowVisible
        test eax, eax
        jz .Lec_ret
        mov rcx, rbx
        API IsIconic
        test eax, eax
        jnz .Lec_ret
        mov rcx, rbx
        mov edx, OB_GWL_EXSTYLE
        API GetWindowLongW
        test eax, OB_WS_EX_TRANSPARENT
        jnz .Lec_ret                    /* click-through overlays */
        test eax, OB_WS_EX_LAYERED
        jz .Lec_cloak
        mov byte ptr [rsp + 84], 255
        mov dword ptr [rsp + 80], 0
        mov rcx, rbx
        xor edx, edx
        lea r8, [rsp + 84]
        lea r9, [rsp + 80]
        API GetLayeredWindowAttributes
        test eax, eax
        jz .Lec_cloak
        test byte ptr [rsp + 80], OB_LWA_ALPHA
        jz .Lec_cloak
        cmp byte ptr [rsp + 84], 0
        je .Lec_ret                     /* fully transparent */
.Lec_cloak:
        mov dword ptr [rsp + 88], 0
        mov rcx, rbx
        mov edx, OB_DWMWA_CLOAKED
        lea r8, [rsp + 88]
        mov r9d, 4
        API DwmGetWindowAttribute
        test eax, eax
        js .Lec_class
        cmp dword ptr [rsp + 88], 0
        jne .Lec_ret
.Lec_class:
        mov rcx, rbx
        lea rdx, [rsp + 48]
        mov r8d, 16
        API GetClassNameW
        test eax, eax                   /* no name: matches none of the classes below */
        jz .Lec_bounds
        lea rcx, [rsp + 48]
        lea rdx, [rip + .Lw_progman]
        API lstrcmpW
        test eax, eax
        jz .Lec_ret                     /* the desktop: fall back to the monitor */
        lea rcx, [rsp + 48]
        lea rdx, [rip + .Lw_workerw]
        API lstrcmpW
        test eax, eax
        jz .Lec_ret
        lea rcx, [rsp + 48]
        lea rdx, [rip + .Lw_poke]
        API lstrcmpW
        test eax, eax
        jz .Lec_ret                     /* ours, shown for the capture */
.Lec_bounds:
        mov rcx, rbx
        mov edx, OB_DWMWA_EXTENDED_FRAME_BOUNDS
        lea r8, [rsp + 32]
        mov r9d, 16
        API DwmGetWindowAttribute
        test eax, eax
        jns .Lec_have
        mov rcx, rbx
        lea rdx, [rsp + 32]
        API GetWindowRect
        test eax, eax
        jz .Lec_ret
.Lec_have:
        mov eax, dword ptr [rsp + 32 + RC_L]
        cmp dword ptr [rsp + 32 + RC_R], eax
        jle .Lec_ret
        mov eax, dword ptr [rsp + 32 + RC_T]
        cmp dword ptr [rsp + 32 + RC_B], eax
        jle .Lec_ret
        movsxd rax, dword ptr o(OV_NWIN)
        lea rcx, [rax + rax*2]          /* WIN_BYTES = 24 */
        mov rdx, qword ptr o(OV_WIN)
        lea rdx, [rdx + rcx*8]
        mov qword ptr [rdx + WIN_H], rbx
        movups xmm0, xmmword ptr [rsp + 32]
        movups xmmword ptr [rdx + WIN_RC], xmm0
        inc eax
        mov dword ptr o(OV_NWIN), eax
.Lec_ret:
        mov eax, 1
        add rsp, 96
        pop rbx
        ret
ENDF

/* DWORD WINAPI collect_windows(void *unused) */
FUNC collect_windows
        ALLOC 40                        /* [32]: start time */
        ENDPROLOG
        call now_ms
        movsd qword ptr [rsp + 32], xmm0
        mov ecx, WIN_BYTES * MAX_WINS
        call mem_alloc
        mov qword ptr o(OV_WIN), rax
        mov dword ptr o(OV_NWIN), 0
        test rax, rax
        jz 1f
        lea rcx, [rip + enum_cb]
        xor edx, edx
        API EnumWindows
1:      call now_ms
        subsd xmm0, qword ptr [rsp + 32]
        movsd qword ptr o(OV_T_ENUM), xmm0
        xor eax, eax
        add rsp, 40
        ret
ENDF

/* void chain_push(RECT r): r in screen coordinates; appended in client coordinates,
 * clipped, unless empty, a repeat of the last one, or the chain is full.
 * Does not write *rcx (update_chain passes its own rectangles). */
FUNC chain_push
        ENDPROLOG
        mov r10d, dword ptr o(OV_VX)
        mov r11d, dword ptr o(OV_VY)
        mov eax, dword ptr [rcx + RC_L]
        sub eax, r10d
        mov edx, dword ptr [rcx + RC_T]
        sub edx, r11d
        mov r8d, dword ptr [rcx + RC_R]
        sub r8d, r10d
        mov r9d, dword ptr [rcx + RC_B]
        sub r9d, r11d
        ISECT_CLIENT eax, edx, r8d, r9d, r10d, .Lcp_ret
        movsxd r10, dword ptr o(OV_NCHAIN)
        cmp r10d, MAX_CHAIN
        jge .Lcp_ret
        lea r11, o(OV_CHAIN)
        mov rcx, r10
        shl rcx, 4
        add r11, rcx
        test r10d, r10d
        jz .Lcp_store
        cmp dword ptr [r11 - 16 + RC_L], eax
        jne .Lcp_store
        cmp dword ptr [r11 - 16 + RC_T], edx
        jne .Lcp_store
        cmp dword ptr [r11 - 16 + RC_R], r8d
        jne .Lcp_store
        cmp dword ptr [r11 - 16 + RC_B], r9d
        je .Lcp_ret
.Lcp_store:
        STORE_RECT r11, eax, edx, r8d, r9d
        inc r10d
        mov dword ptr o(OV_NCHAIN), r10d
.Lcp_ret:
        ret
ENDF

/* void update_chain(void): candidate rectangles under the cursor, smallest
 * (deepest child) first, then the monitor; O.hl = the one at O.level */
#define UC_R 32                         /* RECT from GetWindowRect */
#define UC_CP 48                        /* POINT for ScreenToClient */
#define UC_KIDS 64                      /* RECT kids[12] */
FUNC update_chain
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 256
        ENDPROLOG
        mov dword ptr o(OV_NCHAIN), 0
        mov r12d, dword ptr o(OV_CUR + PT_X)
        add r12d, dword ptr o(OV_VX)    /* the cursor in screen coordinates */
        mov r13d, dword ptr o(OV_CUR + PT_Y)
        add r13d, dword ptr o(OV_VY)
        mov esi, dword ptr o(OV_NWIN)
        test esi, esi
        jle .Luc_mon
        mov r14, qword ptr o(OV_WIN)
.Luc_find:
        cmp r12d, dword ptr [r14 + WIN_RC + RC_L]
        jl .Luc_nextwin
        cmp r12d, dword ptr [r14 + WIN_RC + RC_R]
        jge .Luc_nextwin
        cmp r13d, dword ptr [r14 + WIN_RC + RC_T]
        jl .Luc_nextwin
        cmp r13d, dword ptr [r14 + WIN_RC + RC_B]
        jl .Luc_found
.Luc_nextwin:
        add r14, WIN_BYTES
        dec esi
        jnz .Luc_find
        jmp .Luc_mon
.Luc_found:
        mov rbx, qword ptr [r14 + WIN_H]
        xor edi, edi                    /* kids found */
.Luc_kid:
        mov dword ptr [rsp + UC_CP + PT_X], r12d
        mov dword ptr [rsp + UC_CP + PT_Y], r13d
        mov rcx, rbx
        lea rdx, [rsp + UC_CP]
        API ScreenToClient
        mov rcx, rbx
        mov rdx, qword ptr [rsp + UC_CP]
        mov r8d, OB_CWP_FLAGS
        API ChildWindowFromPointEx
        test rax, rax
        jz .Luc_push
        cmp rax, rbx
        je .Luc_push
        mov rbx, rax
        mov rcx, rax
        lea rdx, [rsp + UC_R]
        API GetWindowRect
        test eax, eax
        jz .Luc_push
        mov eax, dword ptr [rsp + UC_R + RC_L]
        mov edx, dword ptr [rsp + UC_R + RC_T]
        mov r8d, dword ptr [rsp + UC_R + RC_R]
        mov r9d, dword ptr [rsp + UC_R + RC_B]
        lea r10, [r14 + WIN_RC]
        ISECT_MEM eax, edx, r8d, r9d, r10, ecx
        mov ecx, edi
        shl ecx, 4
        lea r10, [rsp + UC_KIDS]
        add r10, rcx
        STORE_RECT r10, eax, edx, r8d, r9d
        inc edi
        cmp edi, 12
        jb .Luc_kid
.Luc_push:
        test edi, edi
        jz .Luc_pushwin
        dec edi
        mov ecx, edi
        shl ecx, 4
        lea rcx, [rsp + UC_KIDS + rcx]
        call chain_push
        jmp .Luc_push
.Luc_pushwin:
        lea rcx, [r14 + WIN_RC]
        call chain_push
.Luc_mon:
        lea rcx, o(OV_SHOT)
        mov edx, dword ptr o(OV_CUR + PT_X)
        mov r8d, dword ptr o(OV_CUR + PT_Y)
        call shot_tile_at
        cdqe
        imul rax, rax, TILE_BYTES
        lea rdx, o(OV_TILE0 + TILE_RC)
        movdqu xmm0, xmmword ptr [rdx + rax]
        movq xmm1, qword ptr o(OV_VX)   /* vx, vy */
        punpcklqdq xmm1, xmm1
        paddd xmm0, xmm1
        movdqu xmmword ptr [rsp + UC_R], xmm0
        lea rcx, [rsp + UC_R]
        call chain_push
        /* O.level = CLAMPI(O.level, 0, MAXI(0, nchain - 1)) */
        mov eax, dword ptr o(OV_LEVEL)
        mov edx, dword ptr o(OV_NCHAIN)
        xor r8d, r8d
        lea ecx, [rdx - 1]
        test ecx, ecx
        cmovl ecx, r8d
        cmp eax, ecx
        cmovg eax, ecx
        test eax, eax
        cmovl eax, r8d
        mov dword ptr o(OV_LEVEL), eax
        test edx, edx
        jz .Luc_client
        shl eax, 4
        lea rcx, o(OV_CHAIN)
        movdqu xmm0, xmmword ptr [rcx + rax]
        movdqu xmmword ptr o(OV_HL), xmm0
        jmp .Luc_ret
.Luc_client:
        mov rax, qword ptr o(OV_VW)
        mov qword ptr o(OV_HL + RC_L), 0
        mov qword ptr o(OV_HL + RC_R), rax
.Luc_ret:
        add rsp, 256
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* ---- annotations ----------------------------------------------------------------------------- */

/* void anno_free(Anno *a) */
FUNC anno_free
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        mov rcx, qword ptr [rcx + AN_PT]
        call mem_free
        mov rcx, qword ptr [rbx + AN_TEXT]
        call mem_free
        xorps xmm0, xmm0
        movups xmmword ptr [rbx], xmm0
        movups xmmword ptr [rbx + 16], xmm0
        movups xmmword ptr [rbx + 32], xmm0
        add rsp, 32
        pop rbx
        ret
ENDF

/* bool anno_push(Anno *a, POINT p) */
FUNC anno_push
        ENDPROLOG
        movsxd rax, dword ptr [rcx + AN_NPT]
        cmp eax, dword ptr [rcx + AN_CAP]
        je ovb_push_grow
        mov r8, qword ptr [rcx + AN_PT]
        mov qword ptr [r8 + rax*8], rdx
        inc eax
        mov dword ptr [rcx + AN_NPT], eax
        mov eax, 1
        ret
ENDF

/* anno_push when full: double the capacity (16 at first), then append */
SFUNC ovb_push_grow
#ifdef OB_TEST                          /* a global name, for tracing in tests */
        .globl ovb_push_grow_t
ovb_push_grow_t:
#endif
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40                        /* [32]: the new capacity */
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        lea edx, [rax + rax]
        mov ecx, 16
        test eax, eax
        cmovnz ecx, edx
        mov dword ptr [rsp + 32], ecx
        movsxd rdx, ecx
        shl rdx, 3
        mov rcx, qword ptr [rbx + AN_PT]
        call mem_grow
        test rax, rax
        jz .Lpg_ret
        mov qword ptr [rbx + AN_PT], rax
        mov ecx, dword ptr [rsp + 32]
        mov dword ptr [rbx + AN_CAP], ecx
        movsxd rcx, dword ptr [rbx + AN_NPT]
        mov qword ptr [rax + rcx*8], rsi
        inc ecx
        mov dword ptr [rbx + AN_NPT], ecx
        mov eax, 1
.Lpg_ret:
        add rsp, 40
        pop rsi
        pop rbx
        ret
ENDF

/* RECT text_box(const WCHAR *t, int n, POINT pos, int px, POINT *caret, int *line_h):
 * the box of n characters of text at pos, lines split at L'\n'; caret: the end of
 * the last line; line_h: the line height. Measured once per text and size (the
 * memo .Ltc), unless a GDI call failed. */
#define TB_FRAME 120
#define TB_SZ 32                        /* SIZE */
#define TB_LAST 40                      /* the last line's width */
#define TB_FAIL 44                      /* a GDI call failed: not memorized */
#define TB_TM 48                        /* TEXTMETRICW */
#define TB_TMH 108                      /* the line height */
#define TB_PX (TB_FRAME + 64 + 40)      /* stack arguments */
#define TB_CARET (TB_PX + 8)
#define TB_LINEH (TB_PX + 16)
        .if TB_TM + OB_TM_SIZE > TB_TMH
        .error "text_box frame too small"
        .endif
FUNC text_box
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG rbp
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC TB_FRAME
        ENDPROLOG
        mov r12, rcx                    /* result */
        mov rsi, rdx                    /* t */
        mov edi, r8d                    /* n */
        mov r13, r9                     /* pos */
        test edi, edi
        js .Ltb_measure
        mov ebp, dword ptr [rsp + TB_PX]
        lea rbx, [rip + .Ltc]
        lea r15, [rbx + TC_COUNT * TC_BYTES]
.Ltb_look:
        cmp dword ptr [rbx + TC_LINES], 0
        je .Ltb_other
        cmp dword ptr [rbx + TC_LEN], edi
        jne .Ltb_other
        cmp dword ptr [rbx + TC_PX], ebp
        jne .Ltb_other
        movsxd r8, edi
        add r8, r8
        mov r9, qword ptr [rbx + TC_COPY]
        mov r10, rsi
        MEMEQ .Ltb_other
        mov ebp, dword ptr [rbx + TC_W]
        mov r15d, dword ptr [rbx + TC_LINES]
        mov eax, dword ptr [rbx + TC_LAST]
        mov dword ptr [rsp + TB_LAST], eax
        mov ecx, dword ptr [rbx + TC_TMH]
        jmp .Ltb_result
.Ltb_other:
        add rbx, TC_BYTES
        cmp rbx, r15
        jb .Ltb_look
.Ltb_measure:
        mov dword ptr [rsp + TB_FAIL], 0
        mov ecx, dword ptr [rsp + TB_PX]
        xor edx, edx
        call get_font
        test rax, rax
        setz byte ptr [rsp + TB_FAIL]
        mov rcx, qword ptr o(OV_MDC)
        mov rdx, rax
        API SelectObject
        mov r14, rax                    /* old font */
        mov rcx, qword ptr o(OV_MDC)
        lea rdx, [rsp + TB_TM]
        API GetTextMetricsW
        test eax, eax
        jnz 1f
        mov byte ptr [rsp + TB_FAIL], 1
1:      xor ebp, ebp                    /* widest line */
        xor r15d, r15d                  /* lines */
        mov dword ptr [rsp + TB_LAST], 0
        test edi, edi
        js .Ltb_done
        xor ebx, ebx                    /* start of the line */
.Ltb_scan:
        mov eax, ebx
.Ltb_vec:                               /* 8 characters at a time */
        lea ecx, [rax + 8]
        cmp ecx, edi
        jg .Ltb_tail
        movdqu xmm0, xmmword ptr [rsi + rax*2]
        pcmpeqw xmm0, xmmword ptr [rip + .Lnl8]
        pmovmskb ecx, xmm0
        test ecx, ecx
        jnz .Ltb_hit
        add eax, 8
        jmp .Ltb_vec
.Ltb_hit:
        bsf ecx, ecx
        shr ecx, 1
        add eax, ecx
        jmp .Ltb_eol
.Ltb_tail:
        cmp eax, edi
        jge .Ltb_eol
        cmp word ptr [rsi + rax*2], 10
        je .Ltb_eol
        inc eax
        jmp .Ltb_tail
.Ltb_eol:                               /* the line is [ebx, eax) */
        mov r8d, eax
        sub r8d, ebx
        lea ecx, [rax + 1]
        xor edx, edx
        test r8d, r8d
        jle .Ltb_empty
        lea rdx, [rsi + rbx*2]
        mov ebx, ecx
        mov qword ptr [rsp + TB_SZ], 0
        mov rcx, qword ptr o(OV_MDC)
        lea r9, [rsp + TB_SZ]
        API GetTextExtentPoint32W
        test eax, eax
        jnz 2f
        mov byte ptr [rsp + TB_FAIL], 1
2:      mov edx, dword ptr [rsp + TB_SZ]
        jmp .Ltb_line
.Ltb_empty:
        mov ebx, ecx
.Ltb_line:
        cmp ebp, edx
        cmovl ebp, edx
        mov dword ptr [rsp + TB_LAST], edx
        inc r15d
        cmp ebx, edi
        jle .Ltb_scan                   /* the line did not end at n */
.Ltb_done:
        mov rcx, qword ptr o(OV_MDC)
        mov rdx, r14
        API SelectObject
        mov ecx, dword ptr [rsp + TB_TM + OB_TM_HEIGHT]
        test edi, edi
        js .Ltb_result
        cmp byte ptr [rsp + TB_FAIL], 0
        jne .Ltb_result
        /* memorize it, replacing the entries in turn */
        mov dword ptr [rsp + TB_TMH], ecx
        mov eax, dword ptr [rip + .Ltc_next]
        lea edx, [rax + 1]
        and edx, TC_COUNT - 1
        mov dword ptr [rip + .Ltc_next], edx
        shl eax, 5                      /* TC_BYTES */
        lea rbx, [rip + .Ltc]
        add rbx, rax
        mov rcx, qword ptr [rbx + TC_COPY]
        mov qword ptr [rbx + TC_COPY], 0
        mov dword ptr [rbx + TC_LINES], 0
        call mem_free
        test edi, edi
        jz .Ltb_keep
        movsxd rcx, edi
        add rcx, rcx
        call mem_alloc
        test rax, rax
        jz .Ltb_kept                    /* no memory: not memorized */
        mov qword ptr [rbx + TC_COPY], rax
        mov r8, rax
        mov r9, rsi
        movsxd r10, edi
        add r10, r10
        COPYW
.Ltb_keep:
        mov dword ptr [rbx + TC_LEN], edi
        mov eax, dword ptr [rsp + TB_PX]
        mov dword ptr [rbx + TC_PX], eax
        mov dword ptr [rbx + TC_W], ebp
        mov eax, dword ptr [rsp + TB_LAST]
        mov dword ptr [rbx + TC_LAST], eax
        mov eax, dword ptr [rsp + TB_TMH]
        mov dword ptr [rbx + TC_TMH], eax
        mov dword ptr [rbx + TC_LINES], r15d    /* >= 1: in use */
.Ltb_kept:
        mov ecx, dword ptr [rsp + TB_TMH]
.Ltb_result:                            /* ebp: widest, r15d: lines, ecx: line height */
        mov eax, r13d                   /* pos.x */
        mov rdx, r13
        shr rdx, 32                     /* pos.y */
        mov r8, qword ptr [rsp + TB_CARET]
        test r8, r8
        jz 1f
        mov r9d, dword ptr [rsp + TB_LAST]
        add r9d, eax
        mov dword ptr [r8 + PT_X], r9d
        lea r9d, [r15 - 1]
        imul r9d, ecx
        add r9d, edx
        mov dword ptr [r8 + PT_Y], r9d
1:      mov r8, qword ptr [rsp + TB_LINEH]
        test r8, r8
        jz 2f
        mov dword ptr [r8], ecx
2:      mov dword ptr [r12 + RC_L], eax
        mov dword ptr [r12 + RC_T], edx
        mov r9d, 1
        cmp ebp, r9d
        cmovl ebp, r9d
        add ebp, eax
        mov dword ptr [r12 + RC_R], ebp
        imul ecx, r15d
        add ecx, edx
        mov dword ptr [r12 + RC_B], ecx
        mov rax, r12
        add rsp, TB_FRAME
        pop r15
        pop r14
        pop r13
        pop r12
        pop rbp
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* RECT anno_bounds(const Anno *a): what rendering a can touch */
#define AB_FRAME 72
#define AB_TMP 56                       /* RECT from text_box */
FUNC anno_bounds
        PUSHREG rbx
        PUSHREG rsi
        ALLOC AB_FRAME
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        movsxd r10, dword ptr [rdx + AN_NPT]
        test r10d, r10d
        jle .Lab_zero
        mov r11, qword ptr [rdx + AN_PT]
        mov ecx, dword ptr [rdx + AN_TOOL]
        cmp ecx, T_TEXT
        je .Lab_text
        cmp ecx, T_PEN
        je .Lab_pen
        cmp ecx, T_MARKER
        je .Lab_pen
        cmp ecx, T_NUMBER
        je .Lab_number
        lea eax, [rcx - 1]
        cmp eax, T_MOSAIC - 1
        ja .Lab_zero                    /* T_NONE or unknown */
        /* box tools and segments: the corners pt[0], pt[npt - 1] */
        lea r9, [r11 + r10*8 - 8]
        CORNERS eax, edx, r8d, r9d, r11, r9, r10d
        cmp ecx, T_ELLIPSE
        je .Lab_ellipse
        cmp ecx, T_LINE
        je .Lab_seg
        cmp ecx, T_ARROW
        je .Lab_seg
        mov ecx, 2                      /* rectangle, mosaic */
        jmp .Lab_inflate
.Lab_seg:
        mov ecx, dword ptr [rsi + AN_SIZE]
        lea ecx, [rcx + rcx*2 + 12]
        jmp .Lab_inflate
.Lab_ellipse:                           /* a flat one is a thick line reaching past its box */
        mov ecx, r8d
        sub ecx, eax
        mov r10d, r9d
        sub r10d, edx
        cmp ecx, r10d
        cmovg ecx, r10d
        mov r10d, ecx                   /* MINI(w, h) / 2, rounded toward zero */
        shr r10d, 31
        add ecx, r10d
        sar ecx, 1
        mov r10d, dword ptr [rsi + AN_SIZE]
        add r10d, 2
        sub r10d, ecx
        mov ecx, 2
        cmp r10d, ecx
        cmovl r10d, ecx
        mov ecx, r10d
        jmp .Lab_inflate
.Lab_number:
        mov eax, dword ptr [r11 + PT_X]
        mov edx, dword ptr [r11 + PT_Y]
        lea r8d, [rax + 1]
        lea r9d, [rdx + 1]
        mov ecx, dword ptr [rsi + AN_SIZE]
        add ecx, 3
        jmp .Lab_inflate
.Lab_text:                              /* glyphs like j and f overhang the measured box */
        lea rcx, [rsp + AB_TMP]
        mov rdx, qword ptr [rsi + AN_TEXT]
        mov r8d, dword ptr [rsi + AN_NTEXT]
        mov r9, qword ptr [r11]
        mov eax, dword ptr [rsi + AN_SIZE]
        mov dword ptr [rsp + 32], eax
        mov qword ptr [rsp + 40], 0
        mov qword ptr [rsp + 48], 0
        call text_box
        mov eax, dword ptr [rsp + AB_TMP + RC_L]
        mov edx, dword ptr [rsp + AB_TMP + RC_T]
        mov r8d, dword ptr [rsp + AB_TMP + RC_R]
        mov r9d, dword ptr [rsp + AB_TMP + RC_B]
        mov ecx, dword ptr [rsi + AN_SIZE]
        mov r10d, ecx                   /* size / 4, rounded toward zero */
        sar r10d, 31
        shr r10d, 30
        add ecx, r10d
        sar ecx, 2
        add ecx, 2
        jmp .Lab_inflate
.Lab_pen:
        /* the union of every point's pixel: min/max over the points, 2 per step.
         * A point with x or y == INT_MAX has an empty pixel rectangle, which a
         * union leaves out; those strokes take the exact scalar loop. */
        movq xmm0, qword ptr [r11]
        punpcklqdq xmm0, xmm0           /* min (x, y, x, y) */
        movdqa xmm1, xmm0               /* max */
        mov eax, r10d
        and eax, 1                      /* odd count: pt[0] is done, pairs from 1 */
        lea rax, [r11 + rax*8]
        lea rcx, [r11 + r10*8]
        cmp rax, rcx
        jae .Lab_pen_reduce
.Lab_pen_loop:
        movdqu xmm2, xmmword ptr [rax]
        movdqa xmm3, xmm0
        pcmpgtd xmm3, xmm2              /* min > p */
        movdqa xmm4, xmm2
        pand xmm4, xmm3
        pandn xmm3, xmm0
        por xmm3, xmm4
        movdqa xmm0, xmm3
        movdqa xmm3, xmm2
        pcmpgtd xmm3, xmm1              /* p > max */
        pand xmm2, xmm3
        pandn xmm3, xmm1
        por xmm3, xmm2
        movdqa xmm1, xmm3
        add rax, 16
        cmp rax, rcx
        jb .Lab_pen_loop
.Lab_pen_reduce:
        pshufd xmm2, xmm0, 0x4E
        movdqa xmm3, xmm0
        pcmpgtd xmm3, xmm2
        pand xmm2, xmm3
        pandn xmm3, xmm0
        por xmm2, xmm3                  /* lanes 0, 1: min x, min y */
        pshufd xmm3, xmm1, 0x4E
        movdqa xmm4, xmm3
        pcmpgtd xmm4, xmm1
        pand xmm3, xmm4
        pandn xmm4, xmm1
        por xmm3, xmm4                  /* lanes 0, 1: max x, max y */
        movd eax, xmm2
        pshufd xmm2, xmm2, 0x55
        movd edx, xmm2
        movd r8d, xmm3
        pshufd xmm3, xmm3, 0x55
        movd r9d, xmm3
        cmp r8d, OB_INT_MAX
        je .Lab_pen_exact
        cmp r9d, OB_INT_MAX
        je .Lab_pen_exact
        inc r8d
        inc r9d
        jmp .Lab_pen_size
.Lab_pen_exact:                         /* r = corners(pt[0]); r = union(r, corners(pt[i])) */
        mov eax, dword ptr [r11 + PT_X]
        mov edx, dword ptr [r11 + PT_Y]
        lea r8d, [rax + 1]
        lea r9d, [rdx + 1]
        lea r10, [r11 + r10*8]
        add r11, 8
.Lab_ex_loop:
        cmp r11, r10
        jae .Lab_pen_size
        mov ecx, dword ptr [r11 + PT_X]
        cmp r8d, eax
        jle .Lab_ex_take                /* r empty: take the point's */
        cmp r9d, edx
        jle .Lab_ex_take
        cmp ecx, OB_INT_MAX
        je .Lab_ex_next                 /* the point's is empty: keep r */
        cmp dword ptr [r11 + PT_Y], OB_INT_MAX
        je .Lab_ex_next
        cmp eax, ecx
        cmovg eax, ecx
        inc ecx
        cmp r8d, ecx
        cmovl r8d, ecx
        mov ecx, dword ptr [r11 + PT_Y]
        cmp edx, ecx
        cmovg edx, ecx
        inc ecx
        cmp r9d, ecx
        cmovl r9d, ecx
        jmp .Lab_ex_next
.Lab_ex_take:
        mov eax, ecx
        lea r8d, [rcx + 1]
        mov edx, dword ptr [r11 + PT_Y]
        lea r9d, [rdx + 1]
.Lab_ex_next:
        add r11, 8
        jmp .Lab_ex_loop
.Lab_pen_size:
        mov ecx, dword ptr [rsi + AN_SIZE]
        mov r10d, ecx                   /* size / 2 + 3 */
        shr r10d, 31
        add ecx, r10d
        sar ecx, 1
        add ecx, 3
.Lab_inflate:                           /* rect_inflate((eax, edx, r8d, r9d), ecx) */
        cmp r8d, eax
        jle .Lab_store
        cmp r9d, edx
        jle .Lab_store
        sub eax, ecx
        sub edx, ecx
        add r8d, ecx
        add r9d, ecx
.Lab_store:
        STORE_RECT rbx, eax, edx, r8d, r9d
        mov rax, rbx
        add rsp, AB_FRAME
        pop rsi
        pop rbx
        ret
.Lab_zero:
        xorps xmm0, xmm0
        movups xmmword ptr [rbx], xmm0
        mov rax, rbx
        add rsp, AB_FRAME
        pop rsi
        pop rbx
        ret
ENDF

/* void text_draw(HDC dc, const WCHAR *t, int n, POINT pos, int px, uint32_t color) */
#define TD_FRAME 72
#define TD_OLD 40
#define TD_RC 48
#define TD_PX (TD_FRAME + 32 + 40)
#define TD_COLOR (TD_PX + 8)
FUNC text_draw
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC TD_FRAME
        ENDPROLOG
        test r8d, r8d
        jle .Ltd_ret
        mov rbx, rcx
        mov rsi, rdx
        mov edi, r8d
        mov r12, r9
        mov ecx, dword ptr [rsp + TD_PX]
        xor edx, edx
        call get_font
        mov rcx, rbx
        mov rdx, rax
        API SelectObject
        mov qword ptr [rsp + TD_OLD], rax
        mov rcx, rbx
        mov edx, OB_TRANSPARENT
        API SetBkMode
        mov edx, dword ptr [rsp + TD_COLOR]
        bswap edx                       /* cref */
        shr edx, 8
        mov rcx, rbx
        API SetTextColor
        mov eax, r12d
        mov rdx, r12
        shr rdx, 32
        mov dword ptr [rsp + TD_RC + RC_L], eax
        mov dword ptr [rsp + TD_RC + RC_T], edx
        add eax, 32000
        add edx, 32000
        mov dword ptr [rsp + TD_RC + RC_R], eax
        mov dword ptr [rsp + TD_RC + RC_B], edx
        mov rcx, rbx
        mov rdx, rsi
        mov r8d, edi
        lea r9, [rsp + TD_RC]
        mov dword ptr [rsp + 32], OB_DT_TEXT
        API DrawTextW
        mov rcx, rbx
        mov rdx, qword ptr [rsp + TD_OLD]
        API SelectObject
.Ltd_ret:
        add rsp, TD_FRAME
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void anno_render(const Anno *a, const Surf *s, HDC dc, const Surf *src): dc draws
 * into the same pixels as s (client coordinates), src is where mosaic reads from */
#define AR_FRAME 128
#define AR_RC 64                        /* RECT */
#define AR_NUM 80                       /* the number's digits end at AR_NUM + 24 */
#define AR_N 104
#define AR_OLD 112
FUNC anno_render
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        ALLOC AR_FRAME
        ENDPROLOG
        movsxd r10, dword ptr [rcx + AN_NPT]
        test r10d, r10d
        jle .Lar_ret
        mov rbx, rcx
        mov rsi, rdx
        mov rdi, r8
        mov r12, r9
        mov r11, qword ptr [rcx + AN_PT]        /* p0 */
        lea r13, [r11 + r10*8 - 8]              /* p1 */
        mov ecx, dword ptr [rcx + AN_TOOL]
        cmp ecx, T_PEN
        je .Lar_pen
        cmp ecx, T_MARKER
        je .Lar_pen
        cmp ecx, T_TEXT
        je .Lar_text
        cmp ecx, T_NUMBER
        je .Lar_number
        cmp ecx, T_LINE
        je .Lar_seg
        cmp ecx, T_ARROW
        je .Lar_seg
        cmp ecx, T_RECT
        je .Lar_rect
        cmp ecx, T_ELLIPSE
        je .Lar_ellipse
        cmp ecx, T_MOSAIC
        jne .Lar_ret
        /* mosaic */
        CORNERS eax, edx, r8d, r9d, r11, r13, ecx
        lea r10, [rsp + AR_RC]
        STORE_RECT r10, eax, edx, r8d, r9d
        mov rcx, rsi
        mov rdx, r12
        lea r8, [rsp + AR_RC]
        mov r9d, dword ptr [rbx + AN_SIZE]
        call d_mosaic
        jmp .Lar_ret
.Lar_rect:
        CORNERS eax, edx, r8d, r9d, r11, r13, ecx
        lea r10, [rsp + AR_RC]
        STORE_RECT r10, eax, edx, r8d, r9d
        mov rcx, rsi
        lea rdx, [rsp + AR_RC]
        mov r8d, dword ptr [rbx + AN_SIZE]
        mov r9d, dword ptr [rbx + AN_COLOR]
        call d_frame
        jmp .Lar_ret
.Lar_ellipse:
        CORNERS eax, edx, r8d, r9d, r11, r13, ecx
        xorps xmm4, xmm4
        cvtsi2ss xmm4, dword ptr [rbx + AN_SIZE]        /* w */
        movss xmm5, dword ptr [rip + .Lf_half]
        movss dword ptr [rsp + 40], xmm4
        mulss xmm4, xmm5                                /* hw */
        lea ecx, [rax + r8]
        xorps xmm1, xmm1
        cvtsi2ss xmm1, ecx
        mulss xmm1, xmm5                                /* cx */
        lea ecx, [rdx + r9]
        xorps xmm2, xmm2
        cvtsi2ss xmm2, ecx
        mulss xmm2, xmm5                                /* cy */
        sub r8d, eax
        xorps xmm3, xmm3
        cvtsi2ss xmm3, r8d
        mulss xmm3, xmm5
        subss xmm3, xmm4                                /* rx */
        sub r9d, edx
        xorps xmm0, xmm0
        cvtsi2ss xmm0, r9d
        mulss xmm0, xmm5
        subss xmm0, xmm4                                /* ry */
        movss dword ptr [rsp + 32], xmm0
        mov eax, dword ptr [rbx + AN_COLOR]
        mov dword ptr [rsp + 48], eax
        mov dword ptr [rsp + 56], 255
        mov rcx, rsi
        call d_ellipse
        jmp .Lar_ret
.Lar_seg:                               /* (x0 + .5, y0 + .5, x1 + .5, y1 + .5), w, color */
        movq xmm0, qword ptr [r11]
        movq xmm1, qword ptr [r13]
        punpcklqdq xmm0, xmm1
        cvtdq2ps xmm0, xmm0
        addps xmm0, xmmword ptr [rip + .Lhalf4]
        movaps xmm1, xmm0
        pshufd xmm2, xmm0, 0x55
        pshufd xmm3, xmm0, 0xAA
        shufps xmm0, xmm0, 0xFF
        movss dword ptr [rsp + 32], xmm0
        xorps xmm0, xmm0
        cvtsi2ss xmm0, dword ptr [rbx + AN_SIZE]
        movss dword ptr [rsp + 40], xmm0
        mov eax, dword ptr [rbx + AN_COLOR]
        mov dword ptr [rsp + 48], eax
        mov rcx, rsi
        cmp dword ptr [rbx + AN_TOOL], T_ARROW
        je 1f
        mov dword ptr [rsp + 56], 255
        call d_line
        jmp .Lar_ret
1:      call d_arrow
        jmp .Lar_ret
.Lar_pen:
        lea ecx, [r10 + r10]
        call fbuf_get
        test rax, rax
        jz .Lar_ret
        mov rdx, rax                    /* xy */
        mov r8d, dword ptr [rbx + AN_NPT]
        mov r9, qword ptr [rbx + AN_PT]
        movaps xmm4, xmmword ptr [rip + .Lhalf4]
        xor eax, eax                    /* byte offset */
        mov ecx, r8d
        shr ecx, 2                      /* 4 points per step */
        jz 2f
1:      movdqu xmm0, xmmword ptr [r9 + rax]
        movdqu xmm1, xmmword ptr [r9 + rax + 16]
        cvtdq2ps xmm0, xmm0
        cvtdq2ps xmm1, xmm1
        addps xmm0, xmm4
        addps xmm1, xmm4
        movups xmmword ptr [rdx + rax], xmm0
        movups xmmword ptr [rdx + rax + 16], xmm1
        add rax, 32
        dec ecx
        jnz 1b
2:      test r8d, 2
        jz 3f
        movdqu xmm0, xmmword ptr [r9 + rax]
        cvtdq2ps xmm0, xmm0
        addps xmm0, xmm4
        movups xmmword ptr [rdx + rax], xmm0
        add rax, 16
3:      test r8d, 1
        jz 4f
        movq xmm0, qword ptr [r9 + rax]
        cvtdq2ps xmm0, xmm0
        addps xmm0, xmm4
        movlps qword ptr [rdx + rax], xmm0
4:      xorps xmm3, xmm3
        cvtsi2ss xmm3, dword ptr [rbx + AN_SIZE]
        mov eax, dword ptr [rbx + AN_COLOR]
        mov dword ptr [rsp + 32], eax
        mov dword ptr [rsp + 40], 255   /* pen: opaque */
        mov dword ptr [rsp + 48], 0
        cmp dword ptr [rbx + AN_TOOL], T_PEN
        je 5f
        mov dword ptr [rsp + 40], 230   /* marker: multiplied */
        mov dword ptr [rsp + 48], 1
5:      mov rcx, rsi
        call d_polyline
        jmp .Lar_ret
.Lar_text:
        mov rcx, rdi
        mov rdx, qword ptr [rbx + AN_TEXT]
        mov r8d, dword ptr [rbx + AN_NTEXT]
        mov r9, qword ptr [r11]
        mov eax, dword ptr [rbx + AN_SIZE]
        mov dword ptr [rsp + 32], eax
        mov eax, dword ptr [rbx + AN_COLOR]
        mov dword ptr [rsp + 40], eax
        call text_draw
        jmp .Lar_flush
.Lar_number:
        movq xmm0, qword ptr [r11]
        cvtdq2ps xmm0, xmm0
        addps xmm0, xmmword ptr [rip + .Lhalf4]
        movaps xmm1, xmm0                               /* cx */
        pshufd xmm2, xmm0, 0x55                         /* cy */
        xorps xmm3, xmm3
        cvtsi2ss xmm3, dword ptr [rbx + AN_SIZE]        /* r */
        mov eax, dword ptr [rbx + AN_COLOR]
        mov dword ptr [rsp + 32], eax
        mov dword ptr [rsp + 40], 255
        mov ecx, eax                    /* luma = R * 3 + G * 6 + B */
        shr ecx, 16
        movzx ecx, cl
        lea r13d, [rcx + rcx*2]
        movzx ecx, ah
        lea ecx, [rcx + rcx*2]
        lea r13d, [r13 + rcx*2]
        movzx ecx, al
        add r13d, ecx
        mov rcx, rsi
        call d_disc
        /* the digits of a->num (wsprintfW L"%d"), backwards from AR_NUM + 24 */
        lea r12, [rsp + AR_NUM + 24]
        mov eax, dword ptr [rbx + AN_NUM]
        mov r8d, eax
        test eax, eax
        jns 1f
        neg eax
1:      mov r9d, 0xCCCCCCCD
2:      mov edx, eax
        imul rdx, r9
        shr rdx, 35                     /* eax / 10 */
        lea ecx, [rdx + rdx*4]
        add ecx, ecx
        sub eax, ecx
        add eax, 0x30
        sub r12, 2
        mov word ptr [r12], ax
        mov eax, edx
        test eax, eax
        jnz 2b
        test r8d, r8d
        jns 3f
        sub r12, 2
        mov word ptr [r12], 0x2D        /* '-' */
3:      lea rax, [rsp + AR_NUM + 24]
        sub rax, r12
        shr eax, 1
        mov dword ptr [rsp + AR_N], eax
        /* get_font(MAXI(8, (int)(r * (n > 1 ? 1.05f : 1.25f))), true) */
        movss xmm0, dword ptr [rip + .Lf_1_25]
        cmp eax, 1
        jle 4f
        movss xmm0, dword ptr [rip + .Lf_1_05]
4:      xorps xmm1, xmm1
        cvtsi2ss xmm1, dword ptr [rbx + AN_SIZE]
        mulss xmm0, xmm1
        cvttss2si ecx, xmm0
        mov eax, 8
        cmp ecx, eax
        cmovl ecx, eax
        mov edx, 1
        call get_font
        mov rcx, rdi
        mov rdx, rax
        API SelectObject
        mov qword ptr [rsp + AR_OLD], rax
        mov rcx, rdi
        mov edx, OB_TRANSPARENT
        API SetBkMode
        mov edx, 0xFFFFFF               /* white on dark discs, black on light ones */
        xor eax, eax
        cmp r13d, 1600
        cmovg edx, eax
        mov rcx, rdi
        API SetTextColor
        mov r11, qword ptr [rbx + AN_PT]
        mov ecx, dword ptr [rbx + AN_SIZE]
        mov eax, dword ptr [r11 + PT_X]
        mov edx, dword ptr [r11 + PT_Y]
        mov r8d, eax
        sub r8d, ecx
        mov dword ptr [rsp + AR_RC + RC_L], r8d
        mov r8d, edx
        sub r8d, ecx
        mov dword ptr [rsp + AR_RC + RC_T], r8d
        lea eax, [rax + rcx + 1]
        mov dword ptr [rsp + AR_RC + RC_R], eax
        lea edx, [rdx + rcx + 1]
        mov dword ptr [rsp + AR_RC + RC_B], edx
        mov rcx, rdi
        mov rdx, r12
        mov r8d, dword ptr [rsp + AR_N]
        lea r9, [rsp + AR_RC]
        mov dword ptr [rsp + 32], OB_DT_NUMBER
        API DrawTextW
        mov rcx, rdi
        mov rdx, qword ptr [rsp + AR_OLD]
        API SelectObject
.Lar_flush:
        add rsp, AR_FRAME
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        jmp qword ptr [rip + __imp_GdiFlush]
.Lar_ret:
        add rsp, AR_FRAME
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* rdi = rsi = n bytes copied from rsi to rdi (n in rcx, a multiple of 8) */
.macro COPY8
        cmp rcx, 512
        jae 3f
1:      cmp rcx, 16
        jb 2f
        movdqu xmm0, xmmword ptr [rsi]
        movdqu xmmword ptr [rdi], xmm0
        add rsi, 16
        add rdi, 16
        sub rcx, 16
        jmp 1b
2:      test rcx, rcx
        jz 4f
        mov rax, qword ptr [rsi]
        mov qword ptr [rdi], rax
        jmp 4f
3:      rep movsb
4:
.endm

/* bool anno_copy(Anno *d, const Anno *s): a deep copy; false (d zeroed) when out of memory */
FUNC anno_copy
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        mov rdi, rdx                    /* s (rdi/rsi swap around the copy) */
        movdqu xmm0, xmmword ptr [rdx]
        movdqu xmm1, xmmword ptr [rdx + 16]
        movdqu xmm2, xmmword ptr [rdx + 32]
        movdqu xmmword ptr [rcx], xmm0
        movdqu xmmword ptr [rcx + 16], xmm1
        movdqu xmmword ptr [rcx + 32], xmm2
        xor eax, eax
        mov qword ptr [rcx + AN_PT], rax
        mov qword ptr [rcx + AN_TEXT], rax
        mov dword ptr [rcx + AN_CAP], eax
        movsxd rcx, dword ptr [rdx + AN_NPT]
        test ecx, ecx
        jle .Lac_text
        shl rcx, 3
        call mem_alloc
        mov qword ptr [rbx + AN_PT], rax
        test rax, rax
        jz .Lac_fail
        mov rsi, qword ptr [rdi + AN_PT]
        movsxd rcx, dword ptr [rdi + AN_NPT]
        shl rcx, 3
        mov rdx, rdi
        mov rdi, rax
        COPY8
        mov rdi, rdx
        mov eax, dword ptr [rdi + AN_NPT]
        mov dword ptr [rbx + AN_CAP], eax
.Lac_text:
        mov rcx, qword ptr [rdi + AN_TEXT]
        test rcx, rcx
        jz .Lac_ok
        mov edx, dword ptr [rdi + AN_NTEXT]
        call wcs_dup
        mov qword ptr [rbx + AN_TEXT], rax
        test rax, rax
        jz .Lac_fail_pt
.Lac_ok:
        mov eax, 1
        jmp .Lac_ret
.Lac_fail_pt:
        mov rcx, qword ptr [rbx + AN_PT]
        call mem_free
.Lac_fail:
        xorps xmm0, xmm0
        movups xmmword ptr [rbx], xmm0
        movups xmmword ptr [rbx + 16], xmm0
        movups xmmword ptr [rbx + 32], xmm0
        xor eax, eax
.Lac_ret:
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF


/* bool anno_same(const Anno *a, const Anno *b) */
FUNC anno_same
        ENDPROLOG
        mov eax, dword ptr [rcx + AN_TOOL]
        cmp eax, dword ptr [rdx + AN_TOOL]
        jne .Las_no
        mov eax, dword ptr [rcx + AN_COLOR]
        cmp eax, dword ptr [rdx + AN_COLOR]
        jne .Las_no
        mov eax, dword ptr [rcx + AN_SIZE]
        cmp eax, dword ptr [rdx + AN_SIZE]
        jne .Las_no
        mov eax, dword ptr [rcx + AN_NPT]
        cmp eax, dword ptr [rdx + AN_NPT]
        jne .Las_no
        mov eax, dword ptr [rcx + AN_NTEXT]
        cmp eax, dword ptr [rdx + AN_NTEXT]
        jne .Las_no
        mov eax, dword ptr [rcx + AN_NUM]
        cmp eax, dword ptr [rdx + AN_NUM]
        jne .Las_no
        movsxd r8, dword ptr [rcx + AN_NPT]
        shl r8, 3
        mov r9, qword ptr [rcx + AN_PT]
        mov r10, qword ptr [rdx + AN_PT]
        MEMEQ .Las_no
        movsxd r8, dword ptr [rcx + AN_NTEXT]
        test r8d, r8d
        jz .Las_yes
        add r8, r8
        mov r9, qword ptr [rcx + AN_TEXT]
        mov r10, qword ptr [rdx + AN_TEXT]
        MEMEQ .Las_no
.Las_yes:
        mov eax, 1
        ret
.Las_no:
        xor eax, eax
        ret
ENDF

/* bool is_box(int tool): rectangle, ellipse, mosaic */
FUNC is_box
        ENDPROLOG
        cmp ecx, T_MOSAIC
        sete al
        dec ecx
        cmp ecx, 1
        setbe dl
        or al, dl
        movzx eax, al
        ret
ENDF

/* bool is_seg(int tool): line, arrow */
FUNC is_seg
        ENDPROLOG
        sub ecx, T_LINE
        xor eax, eax
        cmp ecx, 1
        setbe al
        ret
ENDF

/* bool is_pen(int tool): pen, marker */
FUNC is_pen
        ENDPROLOG
        sub ecx, T_PEN
        xor eax, eax
        cmp ecx, 1
        setbe al
        ret
ENDF

/* ---- canvas ---------------------------------------------------------------------------------
 * The canvas is the screenshot with the annotations drawn in (all of them, or
 * while one is picked, those below it). It covers the selection and all
 * annotations, so moving or resizing the selection never redraws anything. */

/* void canvas_free(void) */
FUNC canvas_free
        ENDPROLOG
        mov byte ptr o(OV_CANVAS_OK), 0
        lea rcx, o(OV_CANVAS)
        jmp img_destroy
ENDF

/* Surf canvas_surf(void) */
FUNC canvas_surf
        ENDPROLOG
        mov rax, rcx
        mov rdx, qword ptr o(OV_CANVAS + IMG_PX)
        mov qword ptr [rax + SURF_PX], rdx
        mov edx, dword ptr o(OV_CANVAS + IMG_W)
        mov dword ptr [rax + SURF_STRIDE], edx
        mov ecx, dword ptr o(OV_CRECT + RC_L)
        mov r8d, dword ptr o(OV_CRECT + RC_T)
        mov dword ptr [rax + SURF_OX], ecx
        mov dword ptr [rax + SURF_OY], r8d
        mov dword ptr [rax + SURF_CL], ecx
        mov dword ptr [rax + SURF_CT], r8d
        add ecx, edx
        mov dword ptr [rax + SURF_CR], ecx
        add r8d, dword ptr o(OV_CANVAS + IMG_H)
        mov dword ptr [rax + SURF_CB], r8d
        ret
ENDF

/* bool rect_within(RECT inner, RECT outer): inner is empty or inside outer */
FUNC rect_within
        ENDPROLOG
        mov eax, dword ptr [rcx + RC_L]
        mov r8d, dword ptr [rcx + RC_R]
        cmp r8d, eax
        jle .Lrw_yes
        mov r9d, dword ptr [rcx + RC_T]
        mov r10d, dword ptr [rcx + RC_B]
        cmp r10d, r9d
        jle .Lrw_yes
        WITHIN_MEM eax, r9d, r8d, r10d, rdx, .Lrw_no
.Lrw_yes:
        mov eax, 1
        ret
.Lrw_no:
        xor eax, eax
        ret
ENDF

/* bool canvas_build(bool force): rebuild the canvas (it includes the selection when
 * there are annotations or when force, e.g. for the mosaic tool, which reads from it) */
#define CB_TMP 32                       /* RECT from anno_bounds */
#define CB_R 48                         /* the area */
#define CB_CS 64                        /* Surf */
#define CB_COPY 112                     /* RECT argument of shot_copy */
FUNC canvas_build
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 128
        ENDPROLOG
        mov ebx, ecx
        mov byte ptr o(OV_CANVAS_OK), 0
        lea rcx, o(OV_CANVAS)
        call img_destroy
        inc dword ptr o(OV_CANVAS_VER)
        xorps xmm0, xmm0
        test bl, bl
        jnz 1f
        cmp dword ptr o(OV_NANN), 0
        jle 2f
1:      movdqu xmm0, xmmword ptr o(OV_SEL)
2:      movdqa xmmword ptr [rsp + CB_R], xmm0
        xor esi, esi
.Lcb_bounds:                            /* r = rect_union(r, anno_bounds(&O.ann[i])) */
        cmp esi, dword ptr o(OV_NANN)
        jge .Lcb_clip
        movsxd rax, esi
        lea rax, [rax + rax*2]
        shl rax, 4                      /* AN_BYTES = 48 */
        mov rdx, qword ptr o(OV_ANN)
        add rdx, rax
        lea rcx, [rsp + CB_TMP]
        call anno_bounds
        inc esi
        mov ecx, dword ptr [rsp + CB_TMP + RC_L]
        mov r10d, dword ptr [rsp + CB_TMP + RC_R]
        cmp r10d, ecx
        jle .Lcb_bounds                 /* empty bounds: r unchanged */
        mov edx, dword ptr [rsp + CB_TMP + RC_T]
        mov r11d, dword ptr [rsp + CB_TMP + RC_B]
        cmp r11d, edx
        jle .Lcb_bounds
        mov eax, dword ptr [rsp + CB_R + RC_L]
        mov r8d, dword ptr [rsp + CB_R + RC_R]
        cmp r8d, eax
        jle .Lcb_take                   /* r empty: the bounds */
        mov r9d, dword ptr [rsp + CB_R + RC_B]
        cmp r9d, dword ptr [rsp + CB_R + RC_T]
        jle .Lcb_take
        cmp eax, ecx
        cmovg eax, ecx
        cmp r8d, r10d
        cmovl r8d, r10d
        cmp r9d, r11d
        cmovl r9d, r11d
        mov ecx, dword ptr [rsp + CB_R + RC_T]
        cmp ecx, edx
        cmovg ecx, edx
        lea rdx, [rsp + CB_R]
        STORE_RECT rdx, eax, ecx, r8d, r9d
        jmp .Lcb_bounds
.Lcb_take:
        movdqa xmm0, xmmword ptr [rsp + CB_TMP]
        movdqa xmmword ptr [rsp + CB_R], xmm0
        jmp .Lcb_bounds
.Lcb_clip:
        mov eax, dword ptr [rsp + CB_R + RC_L]
        mov edx, dword ptr [rsp + CB_R + RC_T]
        mov r8d, dword ptr [rsp + CB_R + RC_R]
        mov r9d, dword ptr [rsp + CB_R + RC_B]
        ISECT_CLIENT eax, edx, r8d, r9d, ecx, .Lcb_false
        lea rcx, [rsp + CB_R]
        STORE_RECT rcx, eax, edx, r8d, r9d
        sub r8d, eax
        sub r9d, edx
        mov edx, r8d
        mov r8d, r9d
        lea rcx, o(OV_CANVAS)
        call img_create
        test al, al
        jz .Lcb_false
        movdqa xmm0, xmmword ptr [rsp + CB_R]
        movdqu xmmword ptr o(OV_CRECT), xmm0
        movdqa xmmword ptr [rsp + CB_COPY], xmm0
        mov rcx, qword ptr o(OV_CANVAS + IMG_DC)
        mov edx, dword ptr [rsp + CB_R + RC_L]
        neg edx
        mov r8d, dword ptr [rsp + CB_R + RC_T]
        neg r8d
        xor r9d, r9d
        API SetViewportOrgEx
        lea rcx, o(OV_SHOT)
        lea rdx, [rsp + CB_COPY]
        mov r8, qword ptr o(OV_CANVAS + IMG_PX)
        mov r9d, dword ptr o(OV_CANVAS + IMG_W)
        call shot_copy
        mov byte ptr o(OV_CANVAS_OK), 1
        lea rcx, [rsp + CB_CS]
        call canvas_surf
        mov edi, dword ptr o(OV_PICK)   /* draw in those below the pick */
        test edi, edi
        jns 3f
        mov edi, dword ptr o(OV_NANN)
3:      xor esi, esi
.Lcb_render:
        cmp esi, edi
        jge .Lcb_true
        movsxd rax, esi
        lea rax, [rax + rax*2]
        shl rax, 4
        mov rcx, qword ptr o(OV_ANN)
        add rcx, rax
        lea rdx, [rsp + CB_CS]
        mov r8, qword ptr o(OV_CANVAS + IMG_DC)
        mov r9, rdx
        call anno_render
        inc esi
        jmp .Lcb_render
.Lcb_true:
        mov eax, 1
        jmp .Lcb_ret
.Lcb_false:
        xor eax, eax
.Lcb_ret:
        add rsp, 128
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void canvas_rebuild(void) */
FUNC canvas_rebuild
        ENDPROLOG
        xor ecx, ecx
        jmp canvas_build
ENDF

/* void canvas_cover_sel(void): the mosaic tool reads the pixels under it from the canvas */
FUNC canvas_cover_sel
        ENDPROLOG
        cmp byte ptr o(OV_CANVAS_OK), 0
        je .Lcs_build
        mov eax, dword ptr o(OV_SEL + RC_L)
        mov edx, dword ptr o(OV_SEL + RC_T)
        mov r8d, dword ptr o(OV_SEL + RC_R)
        mov r9d, dword ptr o(OV_SEL + RC_B)
        ISECT_CLIENT eax, edx, r8d, r9d, ecx, .Lcs_ret
        lea rcx, o(OV_CRECT)
        WITHIN_MEM eax, edx, r8d, r9d, rcx, .Lcs_build
.Lcs_ret:
        ret
.Lcs_build:
        mov ecx, 1
        jmp canvas_build
ENDF

/* void canvas_add_top(void): the top annotation was committed or unpicked: draw
 * it in, or rebuild if it reaches outside the canvas */
FUNC canvas_add_top
        PUSHREG rbx
        ALLOC 96                        /* [32] RECT, [48] Surf */
        ENDPROLOG
        movsxd rax, dword ptr o(OV_NANN)
        lea rax, [rax + rax*2]
        shl rax, 4
        mov rbx, qword ptr o(OV_ANN)
        lea rbx, [rbx + rax - AN_BYTES]
        lea rcx, [rsp + 32]
        mov rdx, rbx
        call anno_bounds
        mov eax, dword ptr [rsp + 32 + RC_L]
        mov edx, dword ptr [rsp + 32 + RC_T]
        mov r8d, dword ptr [rsp + 32 + RC_R]
        mov r9d, dword ptr [rsp + 32 + RC_B]
        ISECT_CLIENT eax, edx, r8d, r9d, ecx
        lea rcx, [rsp + 32]
        STORE_RECT rcx, eax, edx, r8d, r9d
        cmp byte ptr o(OV_CANVAS_OK), 0
        je .Lat_rebuild
        cmp r8d, eax
        jle .Lat_draw                   /* empty: within */
        lea rcx, o(OV_CRECT)
        WITHIN_MEM eax, edx, r8d, r9d, rcx, .Lat_rebuild
.Lat_draw:
        lea rcx, [rsp + 48]
        call canvas_surf
        mov rcx, rbx
        lea rdx, [rsp + 48]
        mov r8, qword ptr o(OV_CANVAS + IMG_DC)
        mov r9, rdx
        call anno_render
        mov eax, dword ptr [rsp + 32 + RC_L]
        mov edx, dword ptr [rsp + 32 + RC_T]
        mov r8d, dword ptr [rsp + 32 + RC_R]
        mov r9d, dword ptr [rsp + 32 + RC_B]
        lea rcx, o(OV_SEL)
        ISECT_MEM eax, edx, r8d, r9d, rcx, r10d
        cmp r8d, eax
        jle .Lat_ret
        lea rcx, [rsp + 32]
        STORE_RECT rcx, eax, edx, r8d, r9d
        mov rdx, rcx
        mov rcx, qword ptr o(OV_HWND)
        xor r8d, r8d
        API InvalidateRect
.Lat_ret:
        add rsp, 96
        pop rbx
        ret
.Lat_rebuild:
        xor ecx, ecx                    /* before the epilogue: the unwinder only knows add/pop/jmp there */
        add rsp, 96
        pop rbx
        jmp canvas_build
ENDF
