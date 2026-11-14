/* ov_paint.S: the capture overlay's picture: toolbar layout and hit testing, visual
 * state and invalidation, painting band by band. The pixels of every state are the
 * same in both modes: the GDI picture, and the premultiplied UI layer DWM composes.
 *
 * What makes it fast:
 *   - the S() values of the current scale are computed once per scale change;
 *   - the size label's and the tooltips' text widths are measured once per text and
 *     font, not on every mouse move;
 *   - refresh invalidates less: the bright area's change is covered by the frame
 *     rings when it lies inside them (no region objects), old and new ring sides
 *     are merged, and a toolbar whose bars stay put repaints only the buttons whose
 *     look changed (hover, press, tool, size, color, undo state) and the tooltip;
 *   - on_paint joins the pieces the update region cuts tall strips into, and paints
 *     a narrow rect that has no GDI text in tall bands at its own stride (one
 *     SetDIBitsToDevice or layer upload instead of one per BAND_H rows);
 *   - a band without GDI text skips the flush and the clip reset;
 *   - the magnifier fills its zoomed cells one pixel row per cell row and copies
 *     that row, and skips its two text lines in bands far from them;
 *   - the screenshot, canvas and layer rows are composed with SSE2, or AVX2 when
 *     draw_cpu says so (draw.S's dispatch variable, probed here too if need be).
 *
 * In composition mode nothing is repainted or uploaded that only moved: present.S
 * stacks parts that move by their offsets alone, so dragging the selection uploads
 * nothing but the size label. Bottom to top:
 *   - the UI layer: the canvas (all of it, the selection clips it) and, inside the
 *     selection, the live annotations, the text being typed and its caret;
 *   - the frame (four rectangles) and the eight handles (one surface);
 *   - the top layer: the picked annotation's handles;
 *   - the panels, a surface each: the size label and the magnifier (drawn over the
 *     GDI picture of what lies beneath, as they may be translucent), the tool bar,
 *     the property bar and the tooltip.
 * refresh invalidates only what the layers hold and keeps the parts in step
 * (ovp_sync); on_paint paints the layers, and the panels beneath which something
 * changed. */
#include "asm.inc"
#include "ov_layout.inc"
#include "lang.inc"

#define Ov(f) [rip + O + f]

/* Windows values used here */
#define W_SIMPLEREGION 2
#define W_COMPLEXREGION 3
#define W_TRANSPARENT 1
#define W_DT_LABEL 0x825                /* DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX */
#define W_SRCCOPY 0x00CC0020
#define W_DIB_RGB_COLORS 0
#define W_BIH_SIZE 0                    /* BITMAPINFOHEADER */
#define W_BIH_WIDTH 4
#define W_BIH_HEIGHT 8
#define W_BIH_PLANES 12
#define W_BIH_BITCOUNT 14
#define W_SIZEOF_BIH 40
#define PS_RCPAINT 12                   /* PAINTSTRUCT.rcPaint */
#define PS_BYTES 72
#define RGN_NCOUNT 8                    /* RGNDATAHEADER.nCount */
#define RGN_BUFFER 32                   /* RGNDATA.Buffer */
#define RGN_MAXRECTS 128                /* more: paint the bounding box */
#define RGN_BUFBYTES (RGN_BUFFER + RGN_MAXRECTS * 16)
/* draw.h icons */
#define DIC_RECT 0
#define DIC_UNDO 9
/* present.h parts */
#define PR_TOP 0
#define PR_LABEL 1
#define PR_HANDLE 6

/* composition mode: what a band paint is for (.Lpass), and what it draws */
#define PASS_UI 0                       /* the UI layer */
#define PASS_TOP 1                      /* the top layer: the picked annotation's handles */
#define PASS_LABEL 2                    /* the size label over what lies beneath it */
#define PASS_MAG 3                      /* the magnifier, likewise */
#define PASS_BAR 4                      /* the tool bar or the property bar */
#define PASS_TIP 5                      /* the tooltip */
#define PASS_HANDLE 6                   /* the selection handle, at 0, 0 */
#define D_ANNOS 1                       /* the live annotations and the text editor */
#define D_FRAME 2
#define D_PICK 4
#define D_LABEL 8
#define D_PANEL 16                      /* the magnifier (selecting) or the bars (editing) */
#define D_HANDLE 32
#define D_FIX_UI 64                     /* opaque: the canvas and the live annotations */
#define D_FIX_ALL 128                   /* opaque: the whole band */
#define D_GDI (D_ANNOS | D_FRAME | D_PICK | D_LABEL | D_PANEL)

/* the parts shown, as ovp_sync left them (.Lsh) */
#define SH_GEN 0                        /* the pr_gen they belong to */
#define SH_PIX 4                        /* O.pixels when the panels were drawn */
#define SH_HN 5                         /* handles shown: 0 or 8 */
#define SH_CLIPOK 6                     /* SH_CLIP is the UI layer's clip */
#define SH_L1CLEAN 7                    /* the UI layer holds nothing at all */
#define SH_PHASE 8
#define SH_HS 12                        /* the size the handle surface was drawn at, 0: none */
#define SH_FRAME 16                     /* RECT[4] */
#define SH_HPOS 80                      /* POINT[8] */
#define SH_CLIP 144
#define SH_PEND 160                     /* where the top layer must still be cleared */
#define SH_A 176                        /* the live area (unclipped) at the last refresh */
#define SH_PD 192                       /* the picked annotation's handles' area, likewise */
#define SH_OK 208                       /* byte[5] by panel: its surface holds its picture */
#define SH_DIRTY 213                    /* byte[5]: what lies beneath it changed */
#define SH_ON 218                       /* byte[5]: shown */
#define SH_NANN 224                     /* O.nann and O.nops at the last refresh */
#define SH_NOPS 228
#define SH_VIS 232                      /* the Visual they show */
#define SH_BYTES (SH_VIS + VIS_BYTES)

/* ---- constant data ------------------------------------------------------------------ */

        .section .rdata$ov_paint,"dr"
        .balign 4
.Lf_half:       .long 0x3F000000                /* 0.5f */
.Lf_1_5:        .long 0x3FC00000                /* 1.5f */
.Lf_rad:        .long 0x400CCCCD, 0x40666666, 0x40ACCCCD        /* 2.2f, 3.6f, 5.4f */
        .balign 2
/* L"" */
.Lw_empty: .short 0x0000
/* by pass: what it draws */
.Lpass_bits:
        .byte D_ANNOS | D_FIX_UI                                        /* PASS_UI */
        .byte D_PICK                                                    /* PASS_TOP */
        .byte D_ANNOS | D_FRAME | D_PICK | D_LABEL | D_FIX_ALL          /* PASS_LABEL */
        .byte D_ANNOS | D_FRAME | D_PICK | D_LABEL | D_PANEL | D_FIX_ALL /* PASS_MAG */
        .byte D_PANEL | D_FIX_ALL                                       /* PASS_BAR */
        .byte D_PANEL | D_FIX_ALL                                       /* PASS_TIP */
        .byte D_HANDLE                                                  /* PASS_HANDLE */
/* by panel (label, magnifier, tool bar, property bar, tooltip): its rect in a Visual,
 * its pass */
        .balign 2
.Lpanel_off: .short VIS_LABEL, VIS_MAG, VIS_TB, VIS_PB, VIS_TIP
.Lpanel_pass: .byte PASS_LABEL, PASS_MAG, PASS_BAR, PASS_BAR, PASS_TIP

/* ---- state of this part -------------------------------------------------------------- */

        .section .data$ov_paint,"dw"
        .balign 4
.Lst_key:       .long 0xFFFFFFFF        /* O.s (its bits) the scale table holds; never a real scale */

        .section .bss$ov_paint,"bw"
        .balign 16
/* scale table: S(v) of the current O.s, and what follows from it */
.Ls1:   .space 4
.Ls2:   .space 4
.Ls3:   .space 4
.Ls4:   .space 4
.Ls5:   .space 4
.Ls6:   .space 4
.Ls7:   .space 4
.Ls9:   .space 4
.Ls11:  .space 4
.Ls12:  .space 4
.Ls14:  .space 4
.Ls16:  .space 4
.Ls18:  .space 4
.Ls20:  .space 4
.Ls22:  .space 4
.Ls24:  .space 4
.Ls30:  .space 4
.Ls46:  .space 4
.Lborder:       .space 4                /* border_t() */
.Lhs:           .space 4                /* handle_sz() */
.Lring:         .space 4                /* ring_w() */
.Lcell:         .space 4                /* mag_cell() */
.Lrad:          .space 12               /* the size discs' radii: rad[i] * O.s */
.Ltw:           .space 4                /* tool bar width */
.Lth:           .space 4                /* bar height */
.Lpw:           .space 4                /* property bar width with colors */
.Lpw_mos:       .space 4                /* ... for the mosaic (sizes only) */
.Lmag_w:        .space 4
.Lmag_h:        .space 4
/* measured text widths: valid for one font (handle, scale), measuring DC and language */
        .balign 8
.Ltx_tr:        .space 8                /* g_tr when they were measured */
.Ltx_font:      .space 8
.Ltx_mdc:       .space 8
.Ltx_fs:        .space 4
.Llab_ok:       .space 4                /* the label's width below is valid */
.Llab_w:        .space 4                /* for this bright size */
.Llab_h:        .space 4
.Llab_cx:       .space 4
.Ltip_cx:       .space 4 * 64           /* by tooltip id */
.Ltip_ok:       .space 64
.Lclipped:      .space 1                /* band_clip ran since the band DC's clip was last reset */
.Lpass:         .space 1                /* composition mode: PASS_* of the band being painted */
.Lsent:         .space 1                /* refresh changed what is shown: a commit is due */
        .balign 16
.Lsh:           .space (SH_BYTES + 15) & ~15    /* sh_check clears it 16 bytes at a time */

/* ---- macros ------------------------------------------------------------------------- */

/* The scale table must be current (clobbers eax and flags only) */
.macro ST_ENSURE
        mov eax, dword ptr [rip + O + OV_S]
        cmp eax, dword ptr [rip + .Lst_key]
        je 97f
        call scale_tab
97:
.endm

/* draw_cpu must be probed (flags only) */
.macro CPU_READY
        cmp dword ptr [rip + draw_cpu], 0
        jne 96f
        call ovp_cpu
96:
.endm

/* v = CLAMPI(v, lo, hi): v < lo ? lo : v > hi ? hi : v (registers; t is clobbered) */
.macro CLAMP v, lo, hi, t
        mov \t, \v
        cmp \t, \hi
        cmovg \v, \hi
        cmp \t, \lo
        cmovl \v, \lo
.endm

/* jump to no unless the RECTs [r] and [q] overlap (clobbers eax, edx) */
.macro OVERLAP r, q, no
        mov eax, dword ptr [\r + RC_L]
        cmp eax, dword ptr [\q + RC_L]
        cmovl eax, dword ptr [\q + RC_L]
        mov edx, dword ptr [\r + RC_R]
        cmp edx, dword ptr [\q + RC_R]
        cmovg edx, dword ptr [\q + RC_R]
        cmp edx, eax
        jle \no
        mov eax, dword ptr [\r + RC_T]
        cmp eax, dword ptr [\q + RC_T]
        cmovl eax, dword ptr [\q + RC_T]
        mov edx, dword ptr [\r + RC_B]
        cmp edx, dword ptr [\q + RC_B]
        cmovg edx, dword ptr [\q + RC_B]
        cmp edx, eax
        jle \no
.endm

/* 16-byte copy through xmm0 (operands written without spaces) */
#define RCOPY(d, s) movdqu xmm0, xmmword ptr s; movdqu xmmword ptr d, xmm0
/* ZF = the two RECTs (16 bytes) are equal; clobbers eax, xmm0, xmm1 */
#define REQ(a, b) movdqu xmm0, xmmword ptr a; movdqu xmm1, xmmword ptr b; pcmpeqb xmm0, xmm1; pmovmskb eax, xmm0; cmp eax, 0xFFFF
/* jump to l if the RECT at base+off is empty (clobbers eax) */
#define JEMPTY(p, l) mov eax, dword ptr [p + RC_R]; cmp eax, dword ptr [p + RC_L]; jle l; mov eax, dword ptr [p + RC_B]; cmp eax, dword ptr [p + RC_T]; jle l

/* ---- scale table ------------------------------------------------------------------------ */

.macro SVAL v, dst                      /* dst = S(v) = MAXI(1, lroundf(v * O.s)); xmm1 = O.s */
        mov eax, \v
        xorps xmm0, xmm0
        cvtsi2ss xmm0, eax
        mulss xmm0, xmm1
        LROUNDF eax, xmm0, xmm2
        mov edx, 1
        cmp eax, edx
        cmovl eax, edx
        mov dword ptr [rip + \dst], eax
.endm

/* Fills the table for the current O.s. Keeps every register but rax and flags. */
SFUNC scale_tab
        PUSHREG rcx
        PUSHREG rdx
        PUSHREG r8
        ALLOC 48
        ENDPROLOG
        movdqu xmmword ptr [rsp], xmm0
        movdqu xmmword ptr [rsp + 16], xmm1
        movdqu xmmword ptr [rsp + 32], xmm2
        movss xmm1, dword ptr Ov(OV_S)
        SVAL 1, .Ls1
        SVAL 2, .Ls2
        SVAL 3, .Ls3
        SVAL 4, .Ls4
        SVAL 5, .Ls5
        SVAL 6, .Ls6
        SVAL 7, .Ls7
        SVAL 9, .Ls9
        SVAL 11, .Ls11
        SVAL 12, .Ls12
        SVAL 14, .Ls14
        SVAL 16, .Ls16
        SVAL 18, .Ls18
        SVAL 20, .Ls20
        SVAL 22, .Ls22
        SVAL 24, .Ls24
        SVAL 30, .Ls30
        SVAL 46, .Ls46
        movss xmm0, dword ptr [rip + .Lf_1_5]   /* border_t(): MAXI(1, lroundf(1.5f * O.s)) */
        mulss xmm0, xmm1
        LROUNDF eax, xmm0, xmm2
        mov edx, 1
        cmp eax, edx
        cmovl eax, edx
        mov dword ptr [rip + .Lborder], eax
        mov edx, dword ptr [rip + .Ls7]         /* handle_sz(): S(7) | 1 */
        or edx, 1
        mov dword ptr [rip + .Lhs], edx
        lea eax, [rax + rdx + 3]                /* ring_w() */
        mov dword ptr [rip + .Lring], eax
        mov eax, dword ptr [rip + .Ls5]         /* mag_cell(): MAXI(3, S(5)) */
        mov edx, 3
        cmp eax, edx
        cmovl eax, edx
        mov dword ptr [rip + .Lcell], eax
        imul edx, eax, MAG_COLS
        add edx, 2
        mov dword ptr [rip + .Lmag_w], edx
        imul edx, eax, MAG_ROWS
        add edx, 2
        add edx, dword ptr [rip + .Ls46]
        mov dword ptr [rip + .Lmag_h], edx
        movss xmm0, dword ptr [rip + .Lf_rad]
        mulss xmm0, xmm1
        movss dword ptr [rip + .Lrad], xmm0
        movss xmm0, dword ptr [rip + .Lf_rad + 4]
        mulss xmm0, xmm1
        movss dword ptr [rip + .Lrad + 4], xmm0
        movss xmm0, dword ptr [rip + .Lf_rad + 8]
        mulss xmm0, xmm1
        movss dword ptr [rip + .Lrad + 8], xmm0
        /* bars: buttons and separators of kTbOrder */
        xor ecx, ecx                            /* separators */
        xor edx, edx
        lea r8, [rip + kTbOrder]
1:      mov eax, dword ptr [r8 + rdx*4]
        shr eax, 31
        add ecx, eax
        inc edx
        cmp edx, 17
        jb 1b
        mov edx, 17
        sub edx, ecx                            /* buttons */
        imul edx, dword ptr [rip + .Ls30]
        imul ecx, dword ptr [rip + .Ls9]
        add edx, ecx
        mov eax, dword ptr [rip + .Ls4]
        lea edx, [rdx + rax*2]                  /* tw = 2 * pad + nbtn * bs + nsep * sep */
        mov dword ptr [rip + .Ltw], edx
        mov ecx, dword ptr [rip + .Ls30]
        lea edx, [rcx + rax*2]                  /* th = 2 * pad + bs */
        mov dword ptr [rip + .Lth], edx
        lea edx, [rcx + rcx*2]
        lea edx, [rdx + rax*2]                  /* 2 * pad + 3 * bs */
        mov dword ptr [rip + .Lpw_mos], edx
        lea edx, [rdx + rcx*8]
        add edx, dword ptr [rip + .Ls9]         /* + sep + 8 * bs */
        mov dword ptr [rip + .Lpw], edx
        mov eax, dword ptr Ov(OV_S)
        mov dword ptr [rip + .Lst_key], eax
        movdqu xmm0, xmmword ptr [rsp]
        movdqu xmm1, xmmword ptr [rsp + 16]
        movdqu xmm2, xmmword ptr [rsp + 32]
        add rsp, 48
        pop r8
        pop rdx
        pop rcx
        ret
ENDF

/* draw_cpu = 1 (SSE2) or 2 (AVX2 usable), as draw.S probes it. Keeps every register. */
SFUNC ovp_cpu
        PUSHREG rax
        PUSHREG rbx
        PUSHREG rcx
        PUSHREG rdx
        ENDPROLOG
        mov eax, 1
        xor ecx, ecx
        cpuid
        and ecx, 0x18000000             /* OSXSAVE and AVX */
        cmp ecx, 0x18000000
        jne 1f
        xor ecx, ecx
        xgetbv
        and eax, 6                      /* the OS saves xmm and ymm state */
        cmp eax, 6
        jne 1f
        mov eax, 7
        xor ecx, ecx
        cpuid
        test ebx, 0x20                  /* AVX2 */
        jz 1f
        mov eax, 2
        jmp 2f
1:      mov eax, 1
2:      mov dword ptr [rip + draw_cpu], eax
        pop rdx
        pop rcx
        pop rbx
        pop rax
        ret
ENDF

/* ---- RECT helpers (leaf; never write their inputs) ------------------------------------- */

/* [rcx] = rect_isect([rdx], [r8]). Keeps rcx, r8; clobbers rax, rdx, r9-r11. */
SFUNC ovp_isect
        ENDPROLOG
        mov eax, dword ptr [rdx + RC_L]
        mov r9d, dword ptr [rdx + RC_T]
        mov r10d, dword ptr [rdx + RC_R]
        mov r11d, dword ptr [rdx + RC_B]
        mov edx, dword ptr [r8 + RC_L]
        cmp eax, edx
        cmovl eax, edx
        mov edx, dword ptr [r8 + RC_T]
        cmp r9d, edx
        cmovl r9d, edx
        mov edx, dword ptr [r8 + RC_R]
        cmp r10d, edx
        cmovg r10d, edx
        mov edx, dword ptr [r8 + RC_B]
        cmp r11d, edx
        cmovg r11d, edx
        cmp r10d, eax
        jle 1f
        cmp r11d, r9d
        jle 1f
        mov dword ptr [rcx + RC_L], eax
        mov dword ptr [rcx + RC_T], r9d
        mov dword ptr [rcx + RC_R], r10d
        mov dword ptr [rcx + RC_B], r11d
        ret
1:      xor eax, eax
        mov qword ptr [rcx + RC_L], rax
        mov qword ptr [rcx + RC_R], rax
        ret
ENDF

/* [rcx] = rect_union([rdx], [r8]): empty inputs are ignored. Keeps rcx; clobbers rax, rdx, r8-r11. */
SFUNC ovp_union
        ENDPROLOG
        mov eax, dword ptr [rdx + RC_R]
        cmp eax, dword ptr [rdx + RC_L]
        jle 2f
        mov eax, dword ptr [rdx + RC_B]
        cmp eax, dword ptr [rdx + RC_T]
        jle 2f
        mov eax, dword ptr [r8 + RC_R]
        cmp eax, dword ptr [r8 + RC_L]
        jle 1f
        mov eax, dword ptr [r8 + RC_B]
        cmp eax, dword ptr [r8 + RC_T]
        jle 1f
        mov eax, dword ptr [rdx + RC_L]
        mov r9d, dword ptr [rdx + RC_T]
        mov r10d, dword ptr [rdx + RC_R]
        mov r11d, dword ptr [rdx + RC_B]
        mov edx, dword ptr [r8 + RC_L]
        cmp eax, edx
        cmovg eax, edx
        mov edx, dword ptr [r8 + RC_T]
        cmp r9d, edx
        cmovg r9d, edx
        mov edx, dword ptr [r8 + RC_R]
        cmp r10d, edx
        cmovl r10d, edx
        mov edx, dword ptr [r8 + RC_B]
        cmp r11d, edx
        cmovl r11d, edx
        mov dword ptr [rcx + RC_L], eax
        mov dword ptr [rcx + RC_T], r9d
        mov dword ptr [rcx + RC_R], r10d
        mov dword ptr [rcx + RC_B], r11d
        ret
1:      mov r8, rdx
2:      movdqu xmm0, xmmword ptr [r8]
        movdqu xmmword ptr [rcx], xmm0
        ret
ENDF

/* [rcx] = rect_inflate([rdx], r8d): an empty rect stays as it is. Keeps rcx, r8; clobbers rax, r9-r11. */
SFUNC ovp_inflate
        ENDPROLOG
        mov eax, dword ptr [rdx + RC_L]
        mov r9d, dword ptr [rdx + RC_T]
        mov r10d, dword ptr [rdx + RC_R]
        mov r11d, dword ptr [rdx + RC_B]
        cmp r10d, eax
        jle 1f
        cmp r11d, r9d
        jle 1f
        sub eax, r8d
        sub r9d, r8d
        add r10d, r8d
        add r11d, r8d
1:      mov dword ptr [rcx + RC_L], eax
        mov dword ptr [rcx + RC_T], r9d
        mov dword ptr [rcx + RC_R], r10d
        mov dword ptr [rcx + RC_B], r11d
        ret
ENDF

/* bool touches(const Surf *s, RECT r): r meets s->clip */
FUNC touches
        ENDPROLOG
        mov eax, dword ptr [rdx + RC_L]
        mov r8d, dword ptr [rdx + RC_R]
        cmp eax, dword ptr [rcx + SURF_CL]
        cmovl eax, dword ptr [rcx + SURF_CL]
        cmp r8d, dword ptr [rcx + SURF_CR]
        cmovg r8d, dword ptr [rcx + SURF_CR]
        cmp r8d, eax
        jle 1f
        mov eax, dword ptr [rdx + RC_T]
        mov r8d, dword ptr [rdx + RC_B]
        cmp eax, dword ptr [rcx + SURF_CT]
        cmovl eax, dword ptr [rcx + SURF_CT]
        cmp r8d, dword ptr [rcx + SURF_CB]
        cmovg r8d, dword ptr [rcx + SURF_CB]
        cmp r8d, eax
        jle 1f
        mov eax, 1
        ret
1:      xor eax, eax
        ret
ENDF

/* InvalidateRect(O.hwnd, rcx, FALSE) unless the rect is empty (inv() of ov_base) */
SFUNC inv_rect
        ALLOC 40
        ENDPROLOG
        mov eax, dword ptr [rcx + RC_R]
        cmp eax, dword ptr [rcx + RC_L]
        jle 1f
        mov eax, dword ptr [rcx + RC_B]
        cmp eax, dword ptr [rcx + RC_T]
        jle 1f
        mov rdx, rcx
        mov rcx, qword ptr Ov(OV_HWND)
        xor r8d, r8d
        API InvalidateRect
1:      add rsp, 40
        ret
ENDF

/* ---- pixel rows (leaf: r8 = destination, r9 = source, ecx = pixels, n <= 0 does
 * nothing; source and destination never overlap; clobber rax, rcx, rdx, xmm0-xmm5) */

SFUNC px_copy
        ENDPROLOG
        test ecx, ecx
        jle 9f
        cmp ecx, 4
        jb 5f
        cmp ecx, 8
        jb 3f
        cmp dword ptr [rip + draw_cpu], 2
        jne 3f
        mov eax, ecx
        shr eax, 5                      /* 32 pixels per round */
        jz 2f
1:      vmovdqu ymm0, ymmword ptr [r9]
        vmovdqu ymm1, ymmword ptr [r9 + 32]
        vmovdqu ymm2, ymmword ptr [r9 + 64]
        vmovdqu ymm3, ymmword ptr [r9 + 96]
        vmovdqu ymmword ptr [r8], ymm0
        vmovdqu ymmword ptr [r8 + 32], ymm1
        vmovdqu ymmword ptr [r8 + 64], ymm2
        vmovdqu ymmword ptr [r8 + 96], ymm3
        sub r9, -128
        sub r8, -128
        dec eax
        jnz 1b
2:      mov eax, ecx
        and eax, 31
        shr eax, 3
        jz 7f
6:      vmovdqu ymm0, ymmword ptr [r9]
        vmovdqu ymmword ptr [r8], ymm0
        add r9, 32
        add r8, 32
        dec eax
        jnz 6b
7:      and ecx, 7                      /* the last 1..7: redo the final 8 */
        jz 8f
        vmovdqu ymm0, ymmword ptr [r9 + rcx*4 - 32]
        vmovdqu ymmword ptr [r8 + rcx*4 - 32], ymm0
8:      vzeroupper
        ret
3:      mov eax, ecx                    /* SSE2, n >= 4 */
        shr eax, 2
4:      movdqu xmm0, xmmword ptr [r9]
        movdqu xmmword ptr [r8], xmm0
        add r9, 16
        add r8, 16
        dec eax
        jnz 4b
        and ecx, 3
        jz 9f
        movdqu xmm0, xmmword ptr [r9 + rcx*4 - 16]
        movdqu xmmword ptr [r8 + rcx*4 - 16], xmm0
        ret
5:      mov eax, dword ptr [r9]
        mov dword ptr [r8], eax
        add r9, 4
        add r8, 4
        dec ecx
        jnz 5b
9:      ret
ENDF

/* d[i] = ((s[i] & 0xFEFEFE) >> 1) + ((s[i] & 0xF0F0F0) >> 4), as d_dim_row */
SFUNC px_dim
        ENDPROLOG
        test ecx, ecx
        jle 9f
        cmp ecx, 4
        jb 5f
        cmp ecx, 8
        jb 3f
        cmp dword ptr [rip + draw_cpu], 2
        jne 3f
        mov eax, 0x7F7F7F
        vmovd xmm4, eax
        vpbroadcastd ymm4, xmm4
        mov eax, 0x0F0F0F
        vmovd xmm5, eax
        vpbroadcastd ymm5, xmm5
        mov eax, ecx
        shr eax, 4                      /* 16 pixels per round */
        jz 2f
1:      vmovdqu ymm0, ymmword ptr [r9]
        vmovdqu ymm1, ymmword ptr [r9 + 32]
        vpsrld ymm2, ymm0, 1
        vpsrld ymm0, ymm0, 4
        vpsrld ymm3, ymm1, 1
        vpsrld ymm1, ymm1, 4
        vpand ymm2, ymm2, ymm4
        vpand ymm0, ymm0, ymm5
        vpand ymm3, ymm3, ymm4
        vpand ymm1, ymm1, ymm5
        vpaddd ymm0, ymm0, ymm2
        vpaddd ymm1, ymm1, ymm3
        vmovdqu ymmword ptr [r8], ymm0
        vmovdqu ymmword ptr [r8 + 32], ymm1
        add r9, 64
        add r8, 64
        dec eax
        jnz 1b
2:      test ecx, 8
        jz 7f
        vmovdqu ymm0, ymmword ptr [r9]
        vpsrld ymm2, ymm0, 1
        vpsrld ymm0, ymm0, 4
        vpand ymm2, ymm2, ymm4
        vpand ymm0, ymm0, ymm5
        vpaddd ymm0, ymm0, ymm2
        vmovdqu ymmword ptr [r8], ymm0
        add r9, 32
        add r8, 32
7:      and ecx, 7
        jz 8f
        vmovdqu ymm0, ymmword ptr [r9 + rcx*4 - 32]
        vpsrld ymm2, ymm0, 1
        vpsrld ymm0, ymm0, 4
        vpand ymm2, ymm2, ymm4
        vpand ymm0, ymm0, ymm5
        vpaddd ymm0, ymm0, ymm2
        vmovdqu ymmword ptr [r8 + rcx*4 - 32], ymm0
8:      vzeroupper
        ret
3:      mov eax, 0x7F7F7F               /* SSE2, n >= 4 */
        movd xmm4, eax
        pshufd xmm4, xmm4, 0
        mov eax, 0x0F0F0F
        movd xmm5, eax
        pshufd xmm5, xmm5, 0
        mov eax, ecx
        shr eax, 2
4:      movdqu xmm0, xmmword ptr [r9]
        movdqa xmm1, xmm0
        psrld xmm0, 4
        psrld xmm1, 1
        pand xmm0, xmm5
        pand xmm1, xmm4
        paddd xmm0, xmm1
        movdqu xmmword ptr [r8], xmm0
        add r9, 16
        add r8, 16
        dec eax
        jnz 4b
        and ecx, 3
        jz 9f
        movdqu xmm0, xmmword ptr [r9 + rcx*4 - 16]
        movdqa xmm1, xmm0
        psrld xmm0, 4
        psrld xmm1, 1
        pand xmm0, xmm5
        pand xmm1, xmm4
        paddd xmm0, xmm1
        movdqu xmmword ptr [r8 + rcx*4 - 16], xmm0
        ret
5:      mov eax, dword ptr [r9]
        mov edx, eax
        shr eax, 1
        shr edx, 4
        and eax, 0x7F7F7F
        and edx, 0x0F0F0F
        add eax, edx
        mov dword ptr [r8], eax
        add r9, 4
        add r8, 4
        dec ecx
        jnz 5b
9:      ret
ENDF

/* r8: ecx pixels set to 0 */
SFUNC px_zero
        ENDPROLOG
        test ecx, ecx
        jle 9f
        cmp ecx, 4
        jb 5f
        cmp ecx, 8
        jb 3f
        cmp dword ptr [rip + draw_cpu], 2
        jne 3f
        vpxor ymm0, ymm0, ymm0
        mov eax, ecx
        shr eax, 4
        jz 2f
1:      vmovdqu ymmword ptr [r8], ymm0
        vmovdqu ymmword ptr [r8 + 32], ymm0
        add r8, 64
        dec eax
        jnz 1b
2:      test ecx, 8
        jz 7f
        vmovdqu ymmword ptr [r8], ymm0
        add r8, 32
7:      and ecx, 7
        jz 8f
        vmovdqu ymmword ptr [r8 + rcx*4 - 32], ymm0
8:      vzeroupper
        ret
3:      pxor xmm0, xmm0
        mov eax, ecx
        shr eax, 2
4:      movdqu xmmword ptr [r8], xmm0
        add r8, 16
        dec eax
        jnz 4b
        and ecx, 3
        jz 9f
        movdqu xmmword ptr [r8 + rcx*4 - 16], xmm0
        ret
5:      mov dword ptr [r8], 0
        add r8, 4
        dec ecx
        jnz 5b
9:      ret
ENDF

/* r8: ecx pixels |= 0xFF000000 */
SFUNC px_alpha
        ENDPROLOG
        test ecx, ecx
        jle 9f
        cmp ecx, 4
        jb 5f
        cmp ecx, 8
        jb 3f
        cmp dword ptr [rip + draw_cpu], 2
        jne 3f
        mov eax, 0xFF000000
        vmovd xmm1, eax
        vpbroadcastd ymm1, xmm1
        mov eax, ecx
        shr eax, 3
1:      vpor ymm0, ymm1, ymmword ptr [r8]
        vmovdqu ymmword ptr [r8], ymm0
        add r8, 32
        dec eax
        jnz 1b
        and ecx, 7
        jz 8f
        vpor ymm0, ymm1, ymmword ptr [r8 + rcx*4 - 32]
        vmovdqu ymmword ptr [r8 + rcx*4 - 32], ymm0
8:      vzeroupper
        ret
3:      mov eax, 0xFF000000
        movd xmm1, eax
        pshufd xmm1, xmm1, 0
        mov eax, ecx
        shr eax, 2
4:      movdqu xmm0, xmmword ptr [r8]
        por xmm0, xmm1
        movdqu xmmword ptr [r8], xmm0
        add r8, 16
        dec eax
        jnz 4b
        and ecx, 3
        jz 9f
        movdqu xmm0, xmmword ptr [r8 + rcx*4 - 16]
        por xmm0, xmm1
        movdqu xmmword ptr [r8 + rcx*4 - 16], xmm0
        ret
5:      or dword ptr [r8], 0xFF000000
        add r8, 4
        dec ecx
        jnz 5b
9:      ret
ENDF

/* ---- small helpers ---------------------------------------------------------------------- */

/* shot_pixel(&O.shot, edx, r8d) -> eax: 0 outside monitors. Clobbers rcx, r9-r11. */
SFUNC pix_at
        ENDPROLOG
        mov r9d, dword ptr Ov(OV_SHOT + SHOT_NTILE)
        lea r10, Ov(OV_SHOT + SHOT_TILE)
1:      test r9d, r9d
        jle 3f
        cmp qword ptr [r10 + TILE_BITS], 0
        je 2f
        cmp edx, dword ptr [r10 + TILE_RC + RC_L]
        jl 2f
        cmp edx, dword ptr [r10 + TILE_RC + RC_R]
        jge 2f
        cmp r8d, dword ptr [r10 + TILE_RC + RC_T]
        jl 2f
        cmp r8d, dword ptr [r10 + TILE_RC + RC_B]
        jge 2f
        mov eax, r8d
        sub eax, dword ptr [r10 + TILE_RC + RC_T]
        movsxd rax, eax
        movsxd r11, dword ptr [r10 + TILE_PITCH]
        imul rax, r11
        mov ecx, edx
        sub ecx, dword ptr [r10 + TILE_RC + RC_L]
        movsxd rcx, ecx
        lea rax, [rax + rcx*4]
        add rax, qword ptr [r10 + TILE_BITS]
        mov eax, dword ptr [rax]
        and eax, 0xFFFFFF
        ret
2:      add r10, TILE_BYTES
        dec r9d
        jmp 1b
3:      xor eax, eax
        ret
ENDF

/* r8 = destination: the decimal digits of eax (wsprintfW "%d"); r8 = past them.
 * Clobbers rax, rdx, r9, r10. */
SFUNC put_int
        ENDPROLOG
        test eax, eax
        jns 1f
        mov word ptr [r8], 0x2D         /* - */
        add r8, 2
        neg eax                         /* INT_MIN stays 0x80000000: right as unsigned */
1:      mov r9, r8
        mov r10d, 10
2:      xor edx, edx
        div r10d
        add edx, 0x30
        mov word ptr [r8], dx
        add r8, 2
        test eax, eax
        jnz 2b
        lea r10, [r8 - 2]               /* reverse the digits */
3:      cmp r9, r10
        jae 4f
        movzx eax, word ptr [r9]
        movzx edx, word ptr [r10]
        mov word ptr [r9], dx
        mov word ptr [r10], ax
        add r9, 2
        sub r10, 2
        jmp 3b
4:      ret
ENDF

/* ecx = toolbar id -> rax = its tooltip text in the language in use, "" for an id
 * without one. The nine tools, the six buttons, the three sizes and the eight colors
 * are each a run of consecutive ids, and a run of consecutive texts in the same
 * order (lang_text.h): the text is the run's first one plus the id's place in the
 * run. Clobbers rcx. */
SFUNC tip_text
        ENDPROLOG
        lea eax, [rcx - T_RECT]
        cmp eax, T_NUMBER - T_RECT
        ja 1f
        mov rcx, qword ptr [rip + g_tr]
        mov rax, qword ptr [rcx + rax*8 + 8 * S_TIP_TOOL1]
        ret
1:      lea eax, [rcx - B_UNDO]
        cmp eax, B_OK - B_UNDO
        ja 2f
        mov rcx, qword ptr [rip + g_tr]
        mov rax, qword ptr [rcx + rax*8 + 8 * S_TIP_UNDO]
        ret
2:      lea eax, [rcx - B_SIZE]
        cmp eax, 2
        ja 3f
        mov rcx, qword ptr [rip + g_tr]
        mov rax, qword ptr [rcx + rax*8 + 8 * S_TIP_SIZE0]
        ret
3:      lea eax, [rcx - B_COLOR]
        cmp eax, 7
        ja 4f
        mov rcx, qword ptr [rip + g_tr]
        mov rax, qword ptr [rcx + rax*8 + 8 * S_COLOR_RED]
        ret
4:      lea rax, [rip + .Lw_empty]
        ret
ENDF

/* eax = prop_tool(): the picked annotation's tool, else O.tool. Clobbers rcx. */
SFUNC prop_tool_
        ENDPROLOG
        movsxd rax, dword ptr Ov(OV_PICK)
        test eax, eax
        js 1f
        imul rax, rax, AN_BYTES
        add rax, qword ptr Ov(OV_ANN)
        mov eax, dword ptr [rax + AN_TOOL]
        ret
1:      mov eax, dword ptr Ov(OV_TOOL)
        ret
ENDF

/* The text width cache belongs to one font and one language (a tooltip's text is
 * another one in another language, and a font handle can come back with the same
 * value): forget it when either changed. Clobbers rax, rcx, flags. */
SFUNC tx_check
        ENDPROLOG
        mov rax, qword ptr [rip + g_tr]
        cmp rax, qword ptr [rip + .Ltx_tr]
        jne 1f
        mov rax, qword ptr Ov(OV_FONT_UI)
        cmp rax, qword ptr [rip + .Ltx_font]
        jne 1f
        mov rax, qword ptr Ov(OV_MDC)
        cmp rax, qword ptr [rip + .Ltx_mdc]
        jne 1f
        mov eax, dword ptr Ov(OV_FONT_S)
        cmp eax, dword ptr [rip + .Ltx_fs]
        jne 1f
        ret
1:      mov rax, qword ptr [rip + g_tr]
        mov qword ptr [rip + .Ltx_tr], rax
        mov rax, qword ptr Ov(OV_FONT_UI)
        mov qword ptr [rip + .Ltx_font], rax
        mov rax, qword ptr Ov(OV_MDC)
        mov qword ptr [rip + .Ltx_mdc], rax
        mov eax, dword ptr Ov(OV_FONT_S)
        mov dword ptr [rip + .Ltx_fs], eax
        mov dword ptr [rip + .Llab_ok], 0
        xor eax, eax
        mov ecx, 8
        lea rax, [rip + .Ltip_ok]
2:      mov qword ptr [rax], 0
        add rax, 8
        dec ecx
        jnz 2b
        ret
ENDF

/* ---- toolbar layout --------------------------------------------------------------------- */

/* int tb_items(const Visual *v, Item *it) */
FUNC tb_items
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 40
        ENDPROLOG
        ST_ENSURE
        xor eax, eax
        mov r8d, dword ptr [rcx + VIS_TB + RC_L]
        mov r9d, dword ptr [rcx + VIS_TB + RC_T]
        cmp dword ptr [rcx + VIS_TB + RC_R], r8d
        jle .Lti_ret
        cmp dword ptr [rcx + VIS_TB + RC_B], r9d
        jle .Lti_ret
        mov rbx, rcx
        mov rsi, rdx                            /* next item */
        mov qword ptr [rsp + 32], rdx           /* the first */
        mov r10d, dword ptr [rip + .Ls30]       /* bs */
        mov r11d, dword ptr [rip + .Ls4]        /* pad */
        add r8d, r11d                           /* x */
        add r9d, r11d                           /* y */
        lea r12d, [r9 + r10]                    /* y + bs */
        lea rdi, [rip + kTbOrder]
        xor ecx, ecx
.Lti_order:
        mov edx, dword ptr [rdi + rcx*4]
        test edx, edx
        jns 1f
        add r8d, dword ptr [rip + .Ls9]
        jmp 2f
1:      mov dword ptr [rsi + ITEM_ID], edx
        mov dword ptr [rsi + ITEM_RC + RC_L], r8d
        mov dword ptr [rsi + ITEM_RC + RC_T], r9d
        add r8d, r10d
        mov dword ptr [rsi + ITEM_RC + RC_R], r8d
        mov dword ptr [rsi + ITEM_RC + RC_B], r12d
        add rsi, ITEM_BYTES
2:      inc ecx
        cmp ecx, 17
        jb .Lti_order
        mov r8d, dword ptr [rbx + VIS_PB + RC_L]
        mov r9d, dword ptr [rbx + VIS_PB + RC_T]
        cmp dword ptr [rbx + VIS_PB + RC_R], r8d
        jle .Lti_count
        cmp dword ptr [rbx + VIS_PB + RC_B], r9d
        jle .Lti_count
        add r8d, r11d
        add r9d, r11d
        lea r12d, [r9 + r10]
        mov edx, B_SIZE
3:      mov dword ptr [rsi + ITEM_ID], edx
        mov dword ptr [rsi + ITEM_RC + RC_L], r8d
        mov dword ptr [rsi + ITEM_RC + RC_T], r9d
        add r8d, r10d
        mov dword ptr [rsi + ITEM_RC + RC_R], r8d
        mov dword ptr [rsi + ITEM_RC + RC_B], r12d
        add rsi, ITEM_BYTES
        inc edx
        cmp edx, B_SIZE + 3
        jb 3b
        call prop_tool_
        cmp eax, T_MOSAIC
        je .Lti_count
        add r8d, dword ptr [rip + .Ls9]
        mov edx, B_COLOR
4:      mov dword ptr [rsi + ITEM_ID], edx
        mov dword ptr [rsi + ITEM_RC + RC_L], r8d
        mov dword ptr [rsi + ITEM_RC + RC_T], r9d
        add r8d, r10d
        mov dword ptr [rsi + ITEM_RC + RC_R], r8d
        mov dword ptr [rsi + ITEM_RC + RC_B], r12d
        add rsi, ITEM_BYTES
        inc edx
        cmp edx, B_COLOR + 8
        jb 4b
.Lti_count:
        mov rax, rsi                            /* (end - it) / ITEM_BYTES */
        sub rax, qword ptr [rsp + 32]
        mov ecx, ITEM_BYTES
        xor edx, edx
        div ecx
.Lti_ret:
        add rsp, 40
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* int tb_hit(POINT p): rcx = p (x low, y high) */
FUNC tb_hit
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 832                               /* [rsp + 32]: Item it[40] */
        ENDPROLOG
        mov ebx, ecx                            /* x */
        shr rcx, 32
        mov esi, ecx                            /* y */
        lea rcx, Ov(OV_VIS)
        lea rdx, [rsp + 32]
        call tb_items
        lea rdi, [rsp + 32]
        mov ecx, eax
1:      test ecx, ecx
        jle 3f
        cmp ebx, dword ptr [rdi + ITEM_RC + RC_L]
        jl 2f
        cmp ebx, dword ptr [rdi + ITEM_RC + RC_R]
        jge 2f
        cmp esi, dword ptr [rdi + ITEM_RC + RC_T]
        jl 2f
        cmp esi, dword ptr [rdi + ITEM_RC + RC_B]
        jge 2f
        mov eax, dword ptr [rdi + ITEM_ID]
        jmp 9f
2:      add rdi, ITEM_BYTES
        dec ecx
        jmp 1b
3:      mov eax, -1                             /* the bars' background */
        cmp ebx, dword ptr Ov(OV_VIS + VIS_TB + RC_L)
        jl 4f
        cmp ebx, dword ptr Ov(OV_VIS + VIS_TB + RC_R)
        jge 4f
        cmp esi, dword ptr Ov(OV_VIS + VIS_TB + RC_T)
        jl 4f
        cmp esi, dword ptr Ov(OV_VIS + VIS_TB + RC_B)
        jl 9f
4:      cmp ebx, dword ptr Ov(OV_VIS + VIS_PB + RC_L)
        jl 5f
        cmp ebx, dword ptr Ov(OV_VIS + VIS_PB + RC_R)
        jge 5f
        cmp esi, dword ptr Ov(OV_VIS + VIS_PB + RC_T)
        jl 5f
        cmp esi, dword ptr Ov(OV_VIS + VIS_PB + RC_B)
        jl 9f
5:      xor eax, eax
9:      add rsp, 832
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void place_label(Visual *v): "w × h" above the bright area (below if no room) */
FUNC place_label
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 48                                /* [rsp + 32]: monitor */
        ENDPROLOG
        mov rbx, rcx
        ST_ENSURE
        JEMPTY(rbx + VIS_BRIGHT, .Lpl_ret)
        mov esi, dword ptr [rbx + VIS_BRIGHT + RC_R]
        sub esi, dword ptr [rbx + VIS_BRIGHT + RC_L]    /* w */
        mov edi, dword ptr [rbx + VIS_BRIGHT + RC_B]
        sub edi, dword ptr [rbx + VIS_BRIGHT + RC_T]    /* h */
        lea r8, [rbx + VIS_LABEL_TEXT]          /* L"%d \x00D7 %d" */
        mov eax, esi
        call put_int
        mov dword ptr [r8], 0x00D70020
        mov word ptr [r8 + 4], 0x0020
        add r8, 6
        mov eax, edi
        call put_int
        mov word ptr [r8], 0
        lea rax, [rbx + VIS_LABEL_TEXT]
        sub r8, rax
        shr r8d, 1                              /* its length */
        call tx_check
        cmp dword ptr [rip + .Llab_ok], 0
        je 1f
        cmp esi, dword ptr [rip + .Llab_w]
        jne 1f
        cmp edi, dword ptr [rip + .Llab_h]
        jne 1f
        mov eax, dword ptr [rip + .Llab_cx]
        jmp 2f
1:      mov rcx, qword ptr Ov(OV_FONT_UI)
        lea rdx, [rbx + VIS_LABEL_TEXT]
        call text_size
        mov dword ptr [rip + .Llab_cx], eax
        mov dword ptr [rip + .Llab_w], esi
        mov dword ptr [rip + .Llab_h], edi
        mov dword ptr [rip + .Llab_ok], 1
2:      add eax, dword ptr [rip + .Ls12]
        mov esi, eax                            /* w */
        mov edi, dword ptr [rip + .Ls22]        /* h */
        lea rcx, [rsp + 32]
        mov edx, dword ptr [rbx + VIS_BRIGHT + RC_L]
        mov r8d, dword ptr [rbx + VIS_BRIGHT + RC_T]
        call mon_rect_at
        mov eax, dword ptr [rbx + VIS_BRIGHT + RC_L]    /* x */
        mov edx, dword ptr [rbx + VIS_BRIGHT + RC_T]
        mov ecx, edx
        sub ecx, edi
        sub ecx, dword ptr [rip + .Ls4]         /* y = b.top - h - S(4) */
        cmp ecx, dword ptr [rsp + 32 + RC_T]
        jge 3f
        mov ecx, edx
        add ecx, dword ptr [rip + .Ls4]         /* no room above: b.top + S(4) */
3:      mov r8d, dword ptr [rsp + 32 + RC_L]
        mov r9d, dword ptr [rsp + 32 + RC_R]
        sub r9d, esi
        CLAMP eax, r8d, r9d, r10d
        mov r8d, dword ptr [rsp + 32 + RC_T]
        mov r9d, dword ptr [rsp + 32 + RC_B]
        sub r9d, edi
        CLAMP ecx, r8d, r9d, r10d
        mov dword ptr [rbx + VIS_LABEL + RC_L], eax
        mov dword ptr [rbx + VIS_LABEL + RC_T], ecx
        add eax, esi
        mov dword ptr [rbx + VIS_LABEL + RC_R], eax
        add ecx, edi
        mov dword ptr [rbx + VIS_LABEL + RC_B], ecx
.Lpl_ret:
        add rsp, 48
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* int mag_cell(void): MAXI(3, S(5)) */
FUNC mag_cell
        ENDPROLOG
        ST_ENSURE
        mov eax, dword ptr [rip + .Lcell]
        ret
ENDF

/* void place_magnifier(Visual *v): beside the cursor, on its monitor */
FUNC place_magnifier
        PUSHREG rbx
        ALLOC 48                                /* [rsp + 32]: monitor */
        ENDPROLOG
        mov rbx, rcx
        ST_ENSURE
        lea rcx, [rsp + 32]
        mov edx, dword ptr Ov(OV_CUR + PT_X)
        mov r8d, dword ptr Ov(OV_CUR + PT_Y)
        call mon_rect_at
        mov r8d, dword ptr [rip + .Lmag_w]
        mov r9d, dword ptr [rip + .Lmag_h]
        mov eax, dword ptr Ov(OV_CUR + PT_X)
        add eax, dword ptr [rip + .Ls20]        /* x */
        lea ecx, [rax + r8]
        cmp ecx, dword ptr [rsp + 32 + RC_R]
        jle 1f
        mov eax, dword ptr Ov(OV_CUR + PT_X)
        sub eax, dword ptr [rip + .Ls20]
        sub eax, r8d
1:      mov edx, dword ptr Ov(OV_CUR + PT_Y)
        add edx, dword ptr [rip + .Ls24]        /* y */
        lea ecx, [rdx + r9]
        cmp ecx, dword ptr [rsp + 32 + RC_B]
        jle 2f
        mov edx, dword ptr Ov(OV_CUR + PT_Y)
        sub edx, dword ptr [rip + .Ls24]
        sub edx, r9d
2:      mov r10d, dword ptr [rsp + 32 + RC_L]
        mov r11d, dword ptr [rsp + 32 + RC_R]
        sub r11d, r8d
        CLAMP eax, r10d, r11d, ecx
        mov r10d, dword ptr [rsp + 32 + RC_T]
        mov r11d, dword ptr [rsp + 32 + RC_B]
        sub r11d, r9d
        CLAMP edx, r10d, r11d, ecx
        mov dword ptr [rbx + VIS_MAG + RC_L], eax
        mov dword ptr [rbx + VIS_MAG + RC_T], edx
        add eax, r8d
        mov dword ptr [rbx + VIS_MAG + RC_R], eax
        add edx, r9d
        mov dword ptr [rbx + VIS_MAG + RC_B], edx
        mov rax, qword ptr Ov(OV_CUR)
        mov qword ptr [rbx + VIS_MAG_PT], rax
        mov al, byte ptr Ov(OV_HEX)
        mov byte ptr [rbx + VIS_MAG_HEX], al
        add rsp, 48
        pop rbx
        ret
ENDF

/* void place_toolbar(Visual *v): the bars below the selection (above, or inside it,
 * when there is no room), the tooltip, and tb_key (what the bars' look depends on) */
#define PT_M 32
#define PT_BELOW 48
#define PT_ABOVE 64
#define PT_TMP 80
#define PT_ITEMS 96
FUNC place_toolbar
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 896
        ENDPROLOG
        mov rbx, rcx
        ST_ENSURE
        call prop_tool_
        mov r12d, eax                           /* pt */
        mov r13d, dword ptr [rip + .Lth]        /* th */
        mov r14d, dword ptr [rip + .Ltw]        /* tw */
        mov r15d, dword ptr [rip + .Lpw]        /* pw */
        cmp eax, T_MOSAIC
        cmove r15d, dword ptr [rip + .Lpw_mos]
        mov esi, dword ptr [rip + .Ls6]         /* gap */
        mov edi, r13d                           /* total = th + (has_pb ? gap + th : 0) */
        test eax, eax
        jz 1f
        lea edi, [r13 + r13]
        add edi, esi
1:      lea rcx, [rsp + PT_M]
        mov edx, dword ptr Ov(OV_SEL + RC_R)
        dec edx
        mov r8d, dword ptr Ov(OV_SEL + RC_B)
        dec r8d
        call mon_rect_at
        mov eax, dword ptr Ov(OV_SEL + RC_R)    /* x = CLAMPI(sel.right - tw, m.left, m.right - tw) */
        sub eax, r14d
        mov ecx, dword ptr [rsp + PT_M + RC_L]
        mov edx, dword ptr [rsp + PT_M + RC_R]
        sub edx, r14d
        CLAMP eax, ecx, edx, r8d
        mov dword ptr [rsp + PT_TMP], eax
        mov eax, dword ptr Ov(OV_SEL + RC_B)
        add eax, esi
        add eax, edi
        cmp eax, dword ptr [rsp + PT_M + RC_B]
        jg 2f
        mov eax, dword ptr Ov(OV_SEL + RC_B)    /* below */
        add eax, esi                            /* ty */
        lea ecx, [rax + r13]
        add ecx, esi                            /* py = ty + th + gap */
        jmp 4f
2:      mov eax, dword ptr Ov(OV_SEL + RC_T)
        sub eax, esi
        sub eax, edi
        cmp eax, dword ptr [rsp + PT_M + RC_T]
        jl 3f
        mov eax, dword ptr Ov(OV_SEL + RC_T)    /* above */
        sub eax, esi
        sub eax, r13d                           /* ty */
        mov ecx, eax
        sub ecx, esi
        sub ecx, r13d                           /* py = ty - gap - th */
        jmp 4f
3:      mov eax, dword ptr [rsp + PT_M + RC_T]  /* inside */
        add eax, edi
        sub eax, r13d
        mov ecx, dword ptr Ov(OV_SEL + RC_B)
        sub ecx, esi
        sub ecx, r13d
        cmp eax, ecx
        cmovl eax, ecx
        mov ecx, dword ptr [rsp + PT_M + RC_B]
        sub ecx, r13d
        cmp eax, ecx
        cmovg eax, ecx
        mov ecx, eax
        sub ecx, esi
        sub ecx, r13d
4:      mov edx, dword ptr [rsp + PT_TMP]
        mov dword ptr [rbx + VIS_TB + RC_L], edx
        mov dword ptr [rbx + VIS_TB + RC_T], eax
        lea r8d, [rdx + r14]
        mov dword ptr [rbx + VIS_TB + RC_R], r8d
        lea r8d, [rax + r13]
        mov dword ptr [rbx + VIS_TB + RC_B], r8d
        test r12d, r12d
        jz .Lpt_tip
        mov r8d, dword ptr [rsp + PT_M + RC_L]  /* px = CLAMPI(x, m.left, m.right - pw) */
        mov r9d, dword ptr [rsp + PT_M + RC_R]
        sub r9d, r15d
        CLAMP edx, r8d, r9d, r10d
        mov dword ptr [rbx + VIS_PB + RC_L], edx
        mov dword ptr [rbx + VIS_PB + RC_T], ecx
        add edx, r15d
        mov dword ptr [rbx + VIS_PB + RC_R], edx
        add ecx, r13d
        mov dword ptr [rbx + VIS_PB + RC_B], ecx
.Lpt_tip:
        cmp dword ptr Ov(OV_TIP), 0
        je .Lpt_key
        mov rcx, rbx
        lea rdx, [rsp + PT_ITEMS]
        call tb_items
        lea rsi, [rsp + PT_ITEMS]
        mov ecx, eax
        mov edx, dword ptr Ov(OV_TIP)
5:      test ecx, ecx
        jle .Lpt_key
        cmp dword ptr [rsi + ITEM_ID], edx
        je 6f
        add rsi, ITEM_BYTES
        dec ecx
        jmp 5b
6:      call tx_check                           /* the text's width, measured once per id */
        mov ecx, dword ptr Ov(OV_TIP)
        cmp ecx, 63
        ja 7f
        lea rax, [rip + .Ltip_ok]
        cmp byte ptr [rax + rcx], 0
        je 7f
        lea rax, [rip + .Ltip_cx]
        mov eax, dword ptr [rax + rcx*4]
        jmp 8f
7:      call tip_text
        mov rdx, rax
        mov r8, rax
10:     cmp word ptr [r8], 0
        je 11f
        add r8, 2
        jmp 10b
11:     sub r8, rax
        shr r8d, 1
        mov rcx, qword ptr Ov(OV_FONT_UI)
        call text_size
        mov ecx, dword ptr Ov(OV_TIP)
        cmp ecx, 63
        ja 8f
        lea rdx, [rip + .Ltip_cx]
        mov dword ptr [rdx + rcx*4], eax
        lea rdx, [rip + .Ltip_ok]
        mov byte ptr [rdx + rcx], 1
8:      add eax, dword ptr [rip + .Ls14]
        mov edi, eax                            /* w */
        mov r15d, dword ptr [rip + .Ls24]       /* h */
        lea r14, [rbx + VIS_TB]                 /* bar: the one holding the button */
        mov eax, dword ptr [rsi + ITEM_RC + RC_L]
        mov ecx, dword ptr [rsi + ITEM_RC + RC_T]
        cmp eax, dword ptr [rbx + VIS_PB + RC_L]
        jl 9f
        cmp eax, dword ptr [rbx + VIS_PB + RC_R]
        jge 9f
        cmp ecx, dword ptr [rbx + VIS_PB + RC_T]
        jl 9f
        cmp ecx, dword ptr [rbx + VIS_PB + RC_B]
        jge 9f
        lea r14, [rbx + VIS_PB]
9:      mov eax, dword ptr [rsi + ITEM_RC + RC_L]       /* tx = CLAMPI((l + r - w) / 2, ...) */
        add eax, dword ptr [rsi + ITEM_RC + RC_R]
        sub eax, edi
        mov edx, eax
        shr edx, 31
        add eax, edx
        sar eax, 1
        mov ecx, dword ptr [rsp + PT_M + RC_L]
        mov edx, dword ptr [rsp + PT_M + RC_R]
        sub edx, edi
        CLAMP eax, ecx, edx, r8d
        mov ecx, dword ptr [r14 + RC_B]         /* below = {tx, bar.b + S(4), tx + w, bar.b + S(4) + h} */
        add ecx, dword ptr [rip + .Ls4]
        mov dword ptr [rsp + PT_BELOW + RC_L], eax
        mov dword ptr [rsp + PT_BELOW + RC_T], ecx
        lea edx, [rax + rdi]
        mov dword ptr [rsp + PT_BELOW + RC_R], edx
        lea edx, [rcx + r15]
        mov dword ptr [rsp + PT_BELOW + RC_B], edx
        mov ecx, dword ptr [r14 + RC_T]         /* above = {tx, bar.t - S(4) - h, tx + w, bar.t - S(4)} */
        sub ecx, dword ptr [rip + .Ls4]
        mov dword ptr [rsp + PT_ABOVE + RC_L], eax
        mov dword ptr [rsp + PT_ABOVE + RC_B], ecx
        sub ecx, r15d
        mov dword ptr [rsp + PT_ABOVE + RC_T], ecx
        lea edx, [rax + rdi]
        mov dword ptr [rsp + PT_ABOVE + RC_R], edx
        REQ([r14], [rbx+VIS_PB])                /* other = rect_eq(&bar, &v->pb) ? v->tb : v->pb */
        lea rdx, [rbx + VIS_PB]
        lea rax, [rbx + VIS_TB]
        cmove rdx, rax
        mov eax, dword ptr [rsp + PT_BELOW + RC_B]
        cmp eax, dword ptr [rsp + PT_M + RC_B]
        jg 12f
        mov r8, rdx
        lea rcx, [rsp + PT_TMP]
        lea rdx, [rsp + PT_BELOW]
        API IntersectRect
        test eax, eax
        jnz 12f
        RCOPY([rbx+VIS_TIP], [rsp+PT_BELOW])
        jmp .Lpt_key
12:     RCOPY([rbx+VIS_TIP], [rsp+PT_ABOVE])
.Lpt_key:
        call prop_size_idx
        movsxd rsi, eax
        shl rsi, 4
        call prop_color_idx
        inc eax
        movsxd rax, eax
        shl rax, 6
        or rsi, rax
        movsxd rax, dword ptr Ov(OV_TOOL)
        or rsi, rax
        mov eax, dword ptr Ov(OV_HOVER)
        and eax, 0x7F
        shl rax, 10
        or rsi, rax
        xor eax, eax
        cmp dword ptr Ov(OV_DRAG), DR_BUTTON
        jne 13f
        mov eax, dword ptr Ov(OV_BTN_DOWN)
        and eax, 0x7F
        shl rax, 17
13:     or rsi, rax
        xor ecx, ecx
        mov eax, dword ptr Ov(OV_NOPS)
        test eax, eax
        setg cl
        shl rcx, 24
        or rsi, rcx
        xor ecx, ecx
        cmp eax, dword ptr Ov(OV_NOPS_ALL)
        setl cl
        shl rcx, 25
        or rsi, rcx
        mov eax, dword ptr Ov(OV_TIP)
        and eax, 0x7F
        shl rax, 26
        or rsi, rax
        movsxd rax, r12d
        shl rax, 33
        or rsi, rax
        mov qword ptr [rbx + VIS_TB_KEY], rsi
        add rsp, 896
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void compute_visual(Visual *v): what the overlay shows for the current state */
#define CV_A 64
#define CV_T 80
#define CV_PB 96
#define CV_CL 112
FUNC compute_visual
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 128                               /* [rsp + 32..56): text_box's stack arguments */
        ENDPROLOG
        mov rbx, rcx
        ST_ENSURE
        xorps xmm0, xmm0                        /* memset(v, 0, sizeof *v) */
        xor eax, eax
1:      movups xmmword ptr [rbx + rax], xmm0
        add eax, 16
        cmp eax, VIS_BYTES - 8
        jb 1b
        mov qword ptr [rbx + VIS_BYTES - 8], 0
        mov eax, dword ptr Ov(OV_S)
        mov dword ptr [rbx + VIS_S], eax
        mov qword ptr [rsp + CV_CL], 0          /* client rect */
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VW)
        mov dword ptr [rsp + CV_CL + RC_R], eax
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VH)
        mov dword ptr [rsp + CV_CL + RC_B], eax
        cmp dword ptr Ov(OV_PHASE), PH_SELECT
        jne .Lcv_edit
        cmp byte ptr Ov(OV_RUBBER), 0
        je 2f
        mov eax, dword ptr Ov(OV_DOWN + PT_X)   /* rect_corners(O.down, O.cur) */
        mov ecx, dword ptr Ov(OV_CUR + PT_X)
        mov edx, eax
        cmp edx, ecx
        cmovg edx, ecx
        cmp eax, ecx
        cmovl eax, ecx
        inc eax
        mov dword ptr [rsp + CV_T + RC_L], edx
        mov dword ptr [rsp + CV_T + RC_R], eax
        mov eax, dword ptr Ov(OV_DOWN + PT_Y)
        mov ecx, dword ptr Ov(OV_CUR + PT_Y)
        mov edx, eax
        cmp edx, ecx
        cmovg edx, ecx
        cmp eax, ecx
        cmovl eax, ecx
        inc eax
        mov dword ptr [rsp + CV_T + RC_T], edx
        mov dword ptr [rsp + CV_T + RC_B], eax
        lea rcx, [rbx + VIS_BRIGHT]
        lea rdx, [rsp + CV_T]
        lea r8, [rsp + CV_CL]
        call ovp_isect
        jmp 3f
2:      RCOPY([rbx+VIS_BRIGHT], Ov(OV_HL))
3:      mov rcx, rbx
        call place_label
        cmp byte ptr Ov(OV_PIXELS), 0           /* it shows pixels: not before they are in memory */
        je .Lcv_ret
        mov rcx, rbx
        call place_magnifier
        jmp .Lcv_ret
.Lcv_edit:
        RCOPY([rbx+VIS_BRIGHT], Ov(OV_SEL))
        mov byte ptr [rbx + VIS_HANDLES], 1
        mov rcx, rbx
        call place_label
        mov rcx, rbx
        call place_toolbar
        xorps xmm0, xmm0
        movdqu xmmword ptr [rsp + CV_A], xmm0
        movdqu xmmword ptr [rsp + CV_PB], xmm0
        cmp byte ptr Ov(OV_HAS_ACT), 0
        je 4f
        lea rcx, [rsp + CV_A]
        lea rdx, Ov(OV_ACT)
        call anno_bounds
4:      cmp byte ptr Ov(OV_TE_ON), 0
        je 5f
        lea rcx, [rsp + CV_T]
        mov rdx, qword ptr Ov(OV_TE_BUF)
        mov r8d, dword ptr Ov(OV_TE_LEN)
        mov r9, qword ptr Ov(OV_TE_POS)
        mov eax, dword ptr Ov(OV_TE_PX)
        mov dword ptr [rsp + 32], eax
        mov qword ptr [rsp + 40], 0
        mov qword ptr [rsp + 48], 0
        call text_box
        lea rcx, [rsp + CV_T]
        mov rdx, rcx
        mov r8d, dword ptr [rip + .Ls4]
        add r8d, 2
        call ovp_inflate
        lea rcx, [rsp + CV_A]
        mov rdx, rcx
        lea r8, [rsp + CV_T]
        call ovp_union
5:      movsxd rdx, dword ptr Ov(OV_PICK)
        test edx, edx
        js 6f
        imul rdx, rdx, AN_BYTES
        add rdx, qword ptr Ov(OV_ANN)
        lea rcx, [rsp + CV_PB]
        call anno_bounds
        lea rcx, [rsp + CV_A]
        mov rdx, rcx
        lea r8, [rsp + CV_PB]
        call ovp_union
6:      lea rcx, [rbx + VIS_ACT]                /* act = isect(a, sel) */
        lea rdx, [rsp + CV_A]
        lea r8, Ov(OV_SEL)
        call ovp_isect
        lea rcx, [rsp + CV_PB]                  /* pick_deco(): handles may stick out */
        mov rdx, rcx
        mov r8d, dword ptr [rip + .Lhs]
        add r8d, dword ptr [rip + .Ls4]
        call ovp_inflate
        lea rcx, [rsp + CV_PB]
        mov rdx, rcx
        lea r8, [rsp + CV_CL]
        call ovp_isect
        lea rcx, [rbx + VIS_ACT]
        mov rdx, rcx
        lea r8, [rsp + CV_PB]
        call ovp_union
        mov eax, dword ptr Ov(OV_ACT_VER)
        mov dword ptr [rbx + VIS_ACT_VER], eax
        mov eax, dword ptr Ov(OV_CANVAS_VER)
        mov dword ptr [rbx + VIS_CANVAS_VER], eax
        cmp byte ptr Ov(OV_CANVAS_OK), 0
        je .Lcv_ret
        RCOPY([rbx+VIS_CRECT], Ov(OV_CRECT))
.Lcv_ret:
        add rsp, 128
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* ---- refresh ------------------------------------------------------------------------------ */

/* rcx = 4 RECTs: the ring of width 2d around the edges of [rdx] (inv_ring's rects), all
 * zero when [rdx] is empty. r8d = d. Leaf; clobbers rax, rdx, r9-r11. */
SFUNC ring4
        ENDPROLOG
        mov eax, dword ptr [rdx + RC_L]
        mov r9d, dword ptr [rdx + RC_T]
        mov r10d, dword ptr [rdx + RC_R]
        mov r11d, dword ptr [rdx + RC_B]
        cmp r10d, eax
        jle 1f
        cmp r11d, r9d
        jle 1f
        mov edx, eax
        sub edx, r8d                            /* l - d */
        mov dword ptr [rcx + 0 + RC_L], edx
        mov dword ptr [rcx + 16 + RC_L], edx
        mov dword ptr [rcx + 32 + RC_L], edx
        lea edx, [rax + r8]                     /* l + d */
        mov dword ptr [rcx + 32 + RC_R], edx
        mov edx, r9d
        sub edx, r8d                            /* t - d */
        mov dword ptr [rcx + 0 + RC_T], edx
        mov dword ptr [rcx + 32 + RC_T], edx
        mov dword ptr [rcx + 48 + RC_T], edx
        lea edx, [r9 + r8]                      /* t + d */
        mov dword ptr [rcx + 0 + RC_B], edx
        mov edx, r10d
        sub edx, r8d                            /* r - d */
        mov dword ptr [rcx + 48 + RC_L], edx
        lea edx, [r10 + r8]                     /* r + d */
        mov dword ptr [rcx + 0 + RC_R], edx
        mov dword ptr [rcx + 16 + RC_R], edx
        mov dword ptr [rcx + 48 + RC_R], edx
        mov edx, r11d
        sub edx, r8d                            /* b - d */
        mov dword ptr [rcx + 16 + RC_T], edx
        lea edx, [r11 + r8]                     /* b + d */
        mov dword ptr [rcx + 16 + RC_B], edx
        mov dword ptr [rcx + 32 + RC_B], edx
        mov dword ptr [rcx + 48 + RC_B], edx
        ret
1:      xorps xmm0, xmm0
        movdqu xmmword ptr [rcx], xmm0
        movdqu xmmword ptr [rcx + 16], xmm0
        movdqu xmmword ptr [rcx + 32], xmm0
        movdqu xmmword ptr [rcx + 48], xmm0
        ret
ENDF

/* [rdx] minus [r8] as up to 4 disjoint RECTs written at rcx; rax = past the last.
 * Nothing when [rdx] is empty. Clobbers rcx, rdx, r8-r11. */
SFUNC rect_sub
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ENDPROLOG
        mov rax, rcx
        mov ebx, dword ptr [rdx + RC_L]
        mov esi, dword ptr [rdx + RC_T]
        mov edi, dword ptr [rdx + RC_R]
        mov r12d, dword ptr [rdx + RC_B]
        cmp edi, ebx
        jle 9f
        cmp r12d, esi
        jle 9f
        mov r9d, dword ptr [r8 + RC_L]          /* the intersection */
        cmp r9d, ebx
        cmovl r9d, ebx
        mov r10d, dword ptr [r8 + RC_T]
        cmp r10d, esi
        cmovl r10d, esi
        mov r11d, dword ptr [r8 + RC_R]
        cmp r11d, edi
        cmovg r11d, edi
        mov ecx, dword ptr [r8 + RC_B]
        cmp ecx, r12d
        cmovg ecx, r12d
        cmp r11d, r9d
        jle 8f
        cmp ecx, r10d
        jle 8f
        cmp r10d, esi                           /* above it */
        jle 1f
        mov dword ptr [rax + RC_L], ebx
        mov dword ptr [rax + RC_T], esi
        mov dword ptr [rax + RC_R], edi
        mov dword ptr [rax + RC_B], r10d
        add rax, 16
1:      cmp ecx, r12d                           /* below */
        jge 2f
        mov dword ptr [rax + RC_L], ebx
        mov dword ptr [rax + RC_T], ecx
        mov dword ptr [rax + RC_R], edi
        mov dword ptr [rax + RC_B], r12d
        add rax, 16
2:      cmp r9d, ebx                            /* left */
        jle 3f
        mov dword ptr [rax + RC_L], ebx
        mov dword ptr [rax + RC_T], r10d
        mov dword ptr [rax + RC_R], r9d
        mov dword ptr [rax + RC_B], ecx
        add rax, 16
3:      cmp r11d, edi                           /* right */
        jge 9f
        mov dword ptr [rax + RC_L], r11d
        mov dword ptr [rax + RC_T], r10d
        mov dword ptr [rax + RC_R], edi
        mov dword ptr [rax + RC_B], ecx
        add rax, 16
        jmp 9f
8:      mov dword ptr [rax + RC_L], ebx         /* disjoint: all of it */
        mov dword ptr [rax + RC_T], esi
        mov dword ptr [rax + RC_R], edi
        mov dword ptr [rax + RC_B], r12d
        add rax, 16
9:      pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* eax = 1 if [rdx] lies inside one of the 8 RECTs at rcx. Leaf; clobbers rcx, r8-r11. */
SFUNC covered
        ENDPROLOG
        mov r8d, dword ptr [rdx + RC_L]
        mov r9d, dword ptr [rdx + RC_T]
        mov r10d, dword ptr [rdx + RC_R]
        mov r11d, dword ptr [rdx + RC_B]
        mov eax, 8
1:      cmp r8d, dword ptr [rcx + RC_L]
        jl 2f
        cmp r9d, dword ptr [rcx + RC_T]
        jl 2f
        cmp r10d, dword ptr [rcx + RC_R]
        jg 2f
        cmp r11d, dword ptr [rcx + RC_B]
        jg 2f
        mov eax, 1
        ret
2:      add rcx, 16
        dec eax
        jnz 1b
        xor eax, eax
        ret
ENDF

/* rax = what toolbar item ecx looks like under tb_key rdx (equal values: equal pixels,
 * for the same bars). Leaf; clobbers r8-r11. */
SFUNC item_look
        ENDPROLOG
        xor r8d, r8d                            /* active */
        mov eax, edx
        and eax, 15                             /* O.tool */
        lea r9d, [rcx - T_RECT]
        cmp r9d, T_NUMBER - T_RECT
        ja 1f
        cmp ecx, eax
        jne 1f
        mov r8d, 1
1:      mov rax, rdx
        shr rax, 4
        and eax, 3                              /* size index */
        add eax, B_SIZE
        cmp ecx, eax
        jne 2f
        mov r8d, 1
2:      xor r9d, r9d                            /* disabled */
        cmp ecx, B_UNDO
        jne 3f
        bt rdx, 24
        jc 3f
        mov r9d, 1
3:      cmp ecx, B_REDO
        jne 4f
        bt rdx, 25
        jc 4f
        mov r9d, 1
4:      xor r10d, r10d                          /* background: none, active, hover, pressed */
        test r8d, r8d
        jz 5f
        mov r10d, 1
        jmp 6f
5:      test r9d, r9d
        jnz 6f
        mov rax, rdx
        shr rax, 10
        and eax, 0x7F
        cmp ecx, eax
        jne 6f
        mov r10d, 2
        mov rax, rdx
        shr rax, 17
        and eax, 0x7F
        cmp ecx, eax
        jne 6f
#if OVP_BREAK != 2 /* broken: a pressed button looks like a hovered one */
        mov r10d, 3
#endif
6:      lea eax, [r10 + r9*4]
        lea eax, [rax + r8*8]
        lea r11d, [rcx - B_SIZE]
        cmp r11d, 2
        ja 8f
        mov r11, rdx                            /* a size disc: its color */
        shr r11, 6
        and r11d, 15                            /* color index + 1 */
        jz 7f
        shl r11d, 5
        or eax, r11d
        mov r11, rdx
        shr r11, 33
        cmp r11, T_MOSAIC
        jne 9f
        or eax, 0x10
9:      ret
7:      mov rax, rdx                            /* the picked annotation's own color: unknown */
        bts rax, 63
        ret
8:      lea r11d, [rcx - B_COLOR]
        cmp r11d, 7
        ja 9b
        mov r10, rdx                            /* a swatch: framed when chosen */
        shr r10, 6
        and r10d, 15
        dec r10d
        cmp r11d, r10d
        jne 9b
        or eax, 0x200
        ret
ENDF

/* void refresh(void): diff the new visual state against the painted one and
 * invalidate what changed (composition mode: refresh_dc) */
#define RF_N 32
#define RF_RING 288
#define RF_PIECE 416
#define RF_CU 544
#define RF_TMP 560
#define RF_SCH 576
#define RF_ITEMS 592
#define RF_MASK 1392
FUNC refresh
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 1520
        ENDPROLOG
        cmp byte ptr Ov(OV_ACTIVE), 0
        je .Lrf_ret
        cmp byte ptr Ov(OV_DC), 0
        je 0f
        call refresh_dc
        jmp .Lrf_ret
0:      ST_ENSURE
        lea rcx, [rsp + RF_N]
        call compute_visual
        lea rbx, Ov(OV_VIS)                     /* o: what is painted */
        movss xmm0, dword ptr [rsp + RF_N + VIS_S]
        ucomiss xmm0, dword ptr [rbx + VIS_S]
        setne al
        setp cl
        or al, cl
        mov byte ptr [rsp + RF_SCH], al         /* the scale changed */
        test al, al
        jz 1f
        mov rcx, qword ptr Ov(OV_HWND)          /* all of it */
        xor edx, edx
        xor r8d, r8d
        API InvalidateRect
        jmp .Lrf_store
1:      mov r12d, dword ptr [rip + .Lring]      /* the old ring was drawn at the old scale */
        cmp byte ptr [rsp + RF_SCH], 0
        je 2f
        lea r12d, [r12 + r12 + 8]
2:      REQ([rsp+RF_N+VIS_BRIGHT], [rbx+VIS_BRIGHT])
        jne 3f
        mov al, byte ptr [rsp + RF_N + VIS_HANDLES]
        cmp al, byte ptr [rbx + VIS_HANDLES]
        jne 3f
        cmp byte ptr [rsp + RF_SCH], 0
        je .Lrf_label
3:      lea rcx, [rsp + RF_RING]                /* the frame rings, old and new */
        lea rdx, [rbx + VIS_BRIGHT]
        mov r8d, r12d
        call ring4
        lea rcx, [rsp + RF_RING + 64]
        lea rdx, [rsp + RF_N + VIS_BRIGHT]
        mov r8d, r12d
        call ring4
        lea rcx, [rsp + RF_PIECE]               /* old XOR new, as rectangles */
        lea rdx, [rbx + VIS_BRIGHT]
        lea r8, [rsp + RF_N + VIS_BRIGHT]
        call rect_sub
        mov rcx, rax
        lea rdx, [rsp + RF_N + VIS_BRIGHT]
        lea r8, [rbx + VIS_BRIGHT]
        call rect_sub
        mov r13, rax
        /* all of the change, clipped to the screen */
        mov qword ptr [rsp + RF_MASK], 0
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VW)
        mov dword ptr [rsp + RF_MASK + RC_R], eax
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VH)
        mov dword ptr [rsp + RF_MASK + RC_B], eax
        mov r15d, 16                            /* masks * 16 */
        lea r14, [rsp + RF_PIECE]
6:      cmp r14, r13
        jae 9f
        xor esi, esi
7:      lea rcx, [rsp + RF_TMP]
        mov rdx, r14
        lea r8, [rsp + RF_MASK + rsi]
        call ovp_isect
        JEMPTY(rsp + RF_TMP, 71f)
        lea rcx, [rsp + RF_RING]                /* inside a ring part: repainted anyway */
        lea rdx, [rsp + RF_TMP]
        call covered
        test eax, eax
        jnz 71f
        lea rcx, [rsp + RF_TMP]
        call inv_rect
71:     add esi, 16
        cmp esi, r15d
        jb 7b
        add r14, 16
        jmp 6b
9:      xor r14d, r14d                          /* each side: old and new merged when they overlap */
10:     lea rsi, [rsp + RF_RING + r14]
        lea rdi, [rsp + RF_RING + 64 + r14]
        JEMPTY(rsi, 11f)
        JEMPTY(rdi, 11f)
        mov eax, dword ptr [rsi + RC_L]
        mov ecx, dword ptr [rdi + RC_L]
        cmp eax, ecx
        cmovl eax, ecx
        mov ecx, dword ptr [rsi + RC_R]
        mov edx, dword ptr [rdi + RC_R]
        cmp ecx, edx
        cmovg ecx, edx
        cmp ecx, eax
        jle 11f
        mov eax, dword ptr [rsi + RC_T]
        mov ecx, dword ptr [rdi + RC_T]
        cmp eax, ecx
        cmovl eax, ecx
        mov ecx, dword ptr [rsi + RC_B]
        mov edx, dword ptr [rdi + RC_B]
        cmp ecx, edx
        cmovg ecx, edx
        cmp ecx, eax
        jle 11f
        lea rcx, [rsp + RF_TMP]
        mov rdx, rsi
        mov r8, rdi
        call ovp_union
        lea rcx, [rsp + RF_TMP]
        call inv_rect
        jmp 12f
11:     mov rcx, rsi
        call inv_rect
        mov rcx, rdi
        call inv_rect
12:     add r14d, 16
        cmp r14d, 64
        jb 10b
.Lrf_label:
        REQ([rsp+RF_N+VIS_LABEL], [rbx+VIS_LABEL])
        jne 2f
        lea rsi, [rsp + RF_N + VIS_LABEL_TEXT]
        lea rdi, [rbx + VIS_LABEL_TEXT]
        mov ecx, 40
1:      movzx eax, word ptr [rsi]
        cmp ax, word ptr [rdi]
        jne 2f
        test eax, eax
        jz .Lrf_mag
        add rsi, 2
        add rdi, 2
        dec ecx
        jnz 1b
        jmp .Lrf_mag
2:      lea rcx, [rbx + VIS_LABEL]
        call inv_rect
        lea rcx, [rsp + RF_N + VIS_LABEL]
        call inv_rect
.Lrf_mag:
        REQ([rsp+RF_N+VIS_MAG], [rbx+VIS_MAG])
        jne 1f
        mov rax, qword ptr [rsp + RF_N + VIS_MAG_PT]
        cmp rax, qword ptr [rbx + VIS_MAG_PT]
        jne 1f
        mov al, byte ptr [rsp + RF_N + VIS_MAG_HEX]
        cmp al, byte ptr [rbx + VIS_MAG_HEX]
        je .Lrf_tb
1:      lea rcx, [rbx + VIS_MAG]
        call inv_rect
        lea rcx, [rsp + RF_N + VIS_MAG]
        call inv_rect
.Lrf_tb:
        cmp byte ptr [rsp + RF_SCH], 0
        jne .Lrf_tb_all
        REQ([rsp+RF_N+VIS_TB], [rbx+VIS_TB])
        jne .Lrf_tb_all
        REQ([rsp+RF_N+VIS_PB], [rbx+VIS_PB])
        jne .Lrf_tb_all
        /* the bars stay: the tooltip, and the buttons whose look changed */
        REQ([rsp+RF_N+VIS_TIP], [rbx+VIS_TIP])
        jne 1f
        mov rax, qword ptr [rsp + RF_N + VIS_TB_KEY]
        xor rax, qword ptr [rbx + VIS_TB_KEY]
        shr rax, 26
        test eax, 0x7F
        jz 2f
1:      lea rcx, [rbx + VIS_TIP]
        call inv_rect
        lea rcx, [rsp + RF_N + VIS_TIP]
        call inv_rect
2:      mov rax, qword ptr [rsp + RF_N + VIS_TB_KEY]
        cmp rax, qword ptr [rbx + VIS_TB_KEY]
        je .Lrf_act
        lea rcx, [rsp + RF_N]
        lea rdx, [rsp + RF_ITEMS]
        call tb_items
        mov r13d, eax
        lea r14, [rsp + RF_ITEMS]
3:      test r13d, r13d
        jle .Lrf_act
        mov ecx, dword ptr [r14 + ITEM_ID]
        mov rdx, qword ptr [rbx + VIS_TB_KEY]
        call item_look
        mov rsi, rax
        mov ecx, dword ptr [r14 + ITEM_ID]
        mov rdx, qword ptr [rsp + RF_N + VIS_TB_KEY]
        call item_look
        cmp rax, rsi
        je 4f
        lea rcx, [r14 + ITEM_RC]
        call inv_rect
4:      add r14, ITEM_BYTES
        dec r13d
        jmp 3b
.Lrf_tb_all:
        lea rcx, [rbx + VIS_TB]
        call inv_rect
        lea rcx, [rsp + RF_N + VIS_TB]
        call inv_rect
        lea rcx, [rbx + VIS_PB]
        call inv_rect
        lea rcx, [rsp + RF_N + VIS_PB]
        call inv_rect
        lea rcx, [rbx + VIS_TIP]
        call inv_rect
        lea rcx, [rsp + RF_N + VIS_TIP]
        call inv_rect
.Lrf_act:
        REQ([rsp+RF_N+VIS_ACT], [rbx+VIS_ACT])
        jne 1f
        mov eax, dword ptr [rsp + RF_N + VIS_ACT_VER]
        cmp eax, dword ptr [rbx + VIS_ACT_VER]
        je 2f
1:      lea rcx, [rbx + VIS_ACT]
        call inv_rect
        lea rcx, [rsp + RF_N + VIS_ACT]
        call inv_rect
2:      mov eax, dword ptr [rsp + RF_N + VIS_CANVAS_VER]
        cmp eax, dword ptr [rbx + VIS_CANVAS_VER]
        je .Lrf_store
        lea rcx, [rsp + RF_N + VIS_BRIGHT]
        call inv_rect
.Lrf_store:
        xor eax, eax                            /* O.vis = n */
1:      movdqu xmm0, xmmword ptr [rsp + RF_N + rax]
        movdqu xmmword ptr [rbx + rax], xmm0
        add eax, 16
        cmp eax, VIS_BYTES - 8
        jb 1b
        mov rax, qword ptr [rsp + RF_N + VIS_BYTES - 8]
        mov qword ptr [rbx + VIS_BYTES - 8], rax
.Lrf_ret:
        add rsp, 1520
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* ---- composition mode: the parts ------------------------------------------------------- */

/* eax = 1 if the r8d bytes (a multiple of 16) at rcx and rdx are equal. Leaf; clobbers
 * rcx, rdx, r8, xmm0, xmm1. */
SFUNC same16
        ENDPROLOG
1:      movdqu xmm0, xmmword ptr [rcx]
        movdqu xmm1, xmmword ptr [rdx]
        pcmpeqb xmm0, xmm1
        pmovmskb eax, xmm0
        cmp eax, 0xFFFF
        jne 2f
        add rcx, 16
        add rdx, 16
        sub r8d, 16
        jg 1b
        mov eax, 1
        ret
2:      xor eax, eax
        ret
ENDF

/* A new capture (pr_begin changed pr_gen): none of the parts shows anything, the
 * UI layer is empty. Leaf; clobbers rax, rcx, rdx, xmm0. */
SFUNC sh_check
        ENDPROLOG
        mov eax, dword ptr [rip + pr_gen]
        cmp eax, dword ptr [rip + .Lsh + SH_GEN]
        je 9f
        lea rdx, [rip + .Lsh]
        xorps xmm0, xmm0
        xor ecx, ecx
1:      movaps xmmword ptr [rdx + rcx], xmm0
        add ecx, 16
        cmp ecx, SH_BYTES
        jb 1b
        mov dword ptr [rdx + SH_GEN], eax
        mov byte ptr [rdx + SH_L1CLEAN], 1
9:      ret
ENDF

/* live_area(RECT *a, RECT *pd): editing, a = the live annotations' and the text
 * editor's area on the screen, not clipped to the selection, and the picked
 * annotation's handles (compute_visual's act before the selection clips it); pd = the
 * handles' area alone (the top layer's). Both empty while selecting. */
#define LA_T 64
#define LA_PB 80
#define LA_CL 96
SFUNC live_area
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 120                               /* [rsp + 32..56): text_box's stack arguments */
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        xorps xmm0, xmm0
        movdqu xmmword ptr [rbx], xmm0
        movdqu xmmword ptr [rsi], xmm0
        cmp dword ptr Ov(OV_PHASE), PH_EDIT
        jne 9f
        ST_ENSURE
        xorps xmm0, xmm0
        movdqu xmmword ptr [rsp + LA_PB], xmm0
        mov qword ptr [rsp + LA_CL], 0          /* client rect */
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VW)
        mov dword ptr [rsp + LA_CL + RC_R], eax
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VH)
        mov dword ptr [rsp + LA_CL + RC_B], eax
        cmp byte ptr Ov(OV_HAS_ACT), 0
        je 1f
        mov rcx, rbx
        lea rdx, Ov(OV_ACT)
        call anno_bounds
1:      cmp byte ptr Ov(OV_TE_ON), 0
        je 2f
        lea rcx, [rsp + LA_T]
        mov rdx, qword ptr Ov(OV_TE_BUF)
        mov r8d, dword ptr Ov(OV_TE_LEN)
        mov r9, qword ptr Ov(OV_TE_POS)
        mov eax, dword ptr Ov(OV_TE_PX)
        mov dword ptr [rsp + 32], eax
        mov qword ptr [rsp + 40], 0
        mov qword ptr [rsp + 48], 0
        call text_box
        lea rcx, [rsp + LA_T]
        mov rdx, rcx
        mov r8d, dword ptr [rip + .Ls4]
        add r8d, 2
        call ovp_inflate
        mov rcx, rbx
        mov rdx, rbx
        lea r8, [rsp + LA_T]
        call ovp_union
2:      movsxd rdx, dword ptr Ov(OV_PICK)
        test edx, edx
        js 3f
        imul rdx, rdx, AN_BYTES
        add rdx, qword ptr Ov(OV_ANN)
        lea rcx, [rsp + LA_PB]
        call anno_bounds
        mov rcx, rbx
        mov rdx, rbx
        lea r8, [rsp + LA_PB]
        call ovp_union
        mov rcx, rsi                            /* pick_deco(): handles may stick out */
        lea rdx, [rsp + LA_PB]
        mov r8d, dword ptr [rip + .Lhs]
        add r8d, dword ptr [rip + .Ls4]
        call ovp_inflate
        mov rcx, rsi
        mov rdx, rsi
        lea r8, [rsp + LA_CL]
        call ovp_isect
3:      mov rcx, rbx
        mov rdx, rbx
        lea r8, [rsp + LA_CL]
        call ovp_isect
        mov rcx, rbx
        mov rdx, rbx
        mov r8, rsi
        call ovp_union
9:      add rsp, 120
        pop rsi
        pop rbx
        ret
ENDF

/* live_x(RECT *x, const RECT *a): a and the annotations above the pick (also drawn
 * live, inside the selection), on the screen: where the UI layer changes when the
 * selection does */
SFUNC live_x
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 64                                /* [rsp + 32]: bounds, [rsp + 48]: client */
        ENDPROLOG
        mov rbx, rcx
        RCOPY([rbx], [rdx])
        mov esi, dword ptr Ov(OV_PICK)
        test esi, esi
        js 9f
        inc esi
1:      cmp esi, dword ptr Ov(OV_NANN)
        jge 2f
        movsxd rdx, esi
        imul rdx, rdx, AN_BYTES
        add rdx, qword ptr Ov(OV_ANN)
        lea rcx, [rsp + 32]
        call anno_bounds
        mov rcx, rbx
        mov rdx, rbx
        lea r8, [rsp + 32]
        call ovp_union
        inc esi
        jmp 1b
2:      mov qword ptr [rsp + 48], 0
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VW)
        mov dword ptr [rsp + 48 + RC_R], eax
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VH)
        mov dword ptr [rsp + 48 + RC_B], eax
        mov rcx, rbx
        mov rdx, rbx
        lea r8, [rsp + 48]
        call ovp_isect
9:      add rsp, 64
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* frame_rects(RECT out[4]): O.vis's frame as draw_frame's d_frame draws it, the four
 * sides of a ring border_t() wide around the bright area, clipped to the screen; one
 * rectangle when that is too thin for a hole; all empty when nothing is bright */
SFUNC frame_rects
        PUSHREG rbx
        ALLOC 48                                /* [rsp + 32]: client */
        ENDPROLOG
        mov rbx, rcx
        xorps xmm0, xmm0
        movdqu xmmword ptr [rbx], xmm0
        movdqu xmmword ptr [rbx + 16], xmm0
        movdqu xmmword ptr [rbx + 32], xmm0
        movdqu xmmword ptr [rbx + 48], xmm0
        lea rdx, Ov(OV_VIS + VIS_BRIGHT)
        JEMPTY(rdx, 9f)
        ST_ENSURE
        mov rcx, rbx
        lea rdx, Ov(OV_VIS + VIS_BRIGHT)
        mov r8d, dword ptr [rip + .Lborder]
        call ovp_inflate
        mov qword ptr [rsp + 32], 0
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VW)
        mov dword ptr [rsp + 32 + RC_R], eax
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VH)
        mov dword ptr [rsp + 32 + RC_B], eax
        mov rcx, rbx
        mov rdx, rbx
        lea r8, [rsp + 32]
        call ovp_isect
        JEMPTY(rbx, 9f)
        mov ecx, dword ptr [rip + .Lborder]     /* t */
        lea edx, [rcx + rcx]
        mov eax, dword ptr [rbx + RC_R]
        sub eax, dword ptr [rbx + RC_L]
        cmp edx, eax
        jge 9f                                  /* too thick for a hole: one fill */
        mov eax, dword ptr [rbx + RC_B]
        sub eax, dword ptr [rbx + RC_T]
        cmp edx, eax
        jge 9f
        mov eax, dword ptr [rbx + RC_L]
        mov r9d, dword ptr [rbx + RC_T]
        mov r10d, dword ptr [rbx + RC_R]
        mov r11d, dword ptr [rbx + RC_B]
        lea edx, [r9 + rcx]                     /* top: l, t, r, t + t */
        mov dword ptr [rbx + RC_B], edx
        mov dword ptr [rbx + 16 + RC_L], eax    /* bottom: l, b - t, r, b */
        mov edx, r11d
        sub edx, ecx
        mov dword ptr [rbx + 16 + RC_T], edx
        mov dword ptr [rbx + 16 + RC_R], r10d
        mov dword ptr [rbx + 16 + RC_B], r11d
        mov dword ptr [rbx + 32 + RC_L], eax    /* left: l, t + t, l + t, b - t */
        lea r8d, [r9 + rcx]
        mov dword ptr [rbx + 32 + RC_T], r8d
        lea r8d, [rax + rcx]
        mov dword ptr [rbx + 32 + RC_R], r8d
        mov dword ptr [rbx + 32 + RC_B], edx
        mov r8d, r10d                           /* right: r - t, t + t, r, b - t */
        sub r8d, ecx
        mov dword ptr [rbx + 48 + RC_L], r8d
        lea r8d, [r9 + rcx]
        mov dword ptr [rbx + 48 + RC_T], r8d
        mov dword ptr [rbx + 48 + RC_R], r10d
        mov dword ptr [rbx + 48 + RC_B], edx
9:      add rsp, 48
        pop rbx
        ret
ENDF

/* handle_pos(POINT out[8]): the handles' top-left corners, as draw_frame places them */
SFUNC handle_pos
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 72                                /* [rsp + 32]: xs[3], [rsp + 48]: ys[3] */
        ENDPROLOG
        mov rbx, rcx
        ST_ENSURE
        mov eax, dword ptr Ov(OV_VIS + VIS_BRIGHT + RC_L)       /* xs = {l, (l + r) / 2, r} */
        mov ecx, dword ptr Ov(OV_VIS + VIS_BRIGHT + RC_R)
        mov dword ptr [rsp + 32], eax
        mov dword ptr [rsp + 40], ecx
        add eax, ecx
        mov edx, eax
        shr edx, 31
        add eax, edx
        sar eax, 1
        mov dword ptr [rsp + 36], eax
        mov eax, dword ptr Ov(OV_VIS + VIS_BRIGHT + RC_T)       /* ys */
        mov ecx, dword ptr Ov(OV_VIS + VIS_BRIGHT + RC_B)
        mov dword ptr [rsp + 48], eax
        mov dword ptr [rsp + 56], ecx
        add eax, ecx
        mov edx, eax
        shr edx, 31
        add eax, edx
        sar eax, 1
        mov dword ptr [rsp + 52], eax
        mov r8d, dword ptr [rip + .Lhs]         /* hs */
        mov r9d, r8d
        shr r9d, 1                              /* hs / 2 */
        mov r10d, dword ptr Ov(OV_SHOT + SHOT_VW)
        sub r10d, r8d                           /* vw - hs */
        mov r11d, dword ptr Ov(OV_SHOT + SHOT_VH)
        sub r11d, r8d
        xor r12d, r12d                          /* 0 */
        xor esi, esi                            /* j */
1:      xor edi, edi                            /* i */
2:      cmp esi, 1
        jne 3f
        cmp edi, 1
        je 4f
3:      mov eax, dword ptr [rsp + rdi*4 + 32]   /* x = CLAMPI(xs[i] - hs / 2, 0, vw - hs) */
        sub eax, r9d
        CLAMP eax, r12d, r10d, ecx
        mov dword ptr [rbx + PT_X], eax
        mov eax, dword ptr [rsp + rsi*4 + 48]   /* y */
        sub eax, r9d
        CLAMP eax, r12d, r11d, ecx
        mov dword ptr [rbx + PT_Y], eax
        add rbx, 8
4:      inc edi
        cmp edi, 3
        jb 2b
        inc esi
        cmp esi, 3
        jb 1b
        add rsp, 72
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* eax = paint_part(int k, const RECT *r, const RECT *sub, int pass): part k of
 * present.h drawn in sub (all of r for a new surface) by pass, in bands */
SFUNC paint_part
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 48                                /* [rsp + 32]: the band */
        ENDPROLOG
        mov esi, r9d
        mov rdi, r8
        mov byte ptr [rip + .Lsent], 1
        call pr_part_begin
        test al, al
        jz 9f
        mov byte ptr [rip + .Lpass], sil
        mov ebx, dword ptr [rdi + RC_T]
1:      cmp ebx, dword ptr [rdi + RC_B]
        jge 2f
        mov eax, dword ptr [rdi + RC_L]
        mov dword ptr [rsp + 32 + RC_L], eax
        mov dword ptr [rsp + 32 + RC_T], ebx
        mov eax, dword ptr [rdi + RC_R]
        mov dword ptr [rsp + 32 + RC_R], eax
        lea eax, [rbx + BAND_H]
        cmp eax, dword ptr [rdi + RC_B]
        cmovg eax, dword ptr [rdi + RC_B]
        mov dword ptr [rsp + 32 + RC_B], eax
        xor ecx, ecx
        lea rdx, [rsp + 32]
        call paint_band
        add ebx, BAND_H
        jmp 1b
2:      mov byte ptr [rip + .Lpass], PASS_UI
        call pr_ui_end
        mov eax, 1
        jmp 8f
9:      xor eax, eax
8:      add rsp, 48
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* ovp_sync(void): composition mode, the parts in step with O.vis: the frame, the
 * handles, the UI layer's clip, and the panels, drawn again when their picture or
 * what lies beneath them changed, else only moved */
#define SY_FR 32                                /* RECT[4] */
#define SY_HP 96                                /* POINT[8] */
#define SY_R 160
#define SY_LOOK 176
#define SY_ITEMS 192                            /* Item[40] */
#define SY_LD 992                               /* byte: the label was drawn */
#define SY_FULL 993                             /* byte: the panel is drawn whole */
SFUNC ovp_sync
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 1008
        ENDPROLOG
        ST_ENSURE
        call sh_check
        lea rbx, Ov(OV_VIS)
        lea r12, [rip + .Lsh]
        /* the frame */
        lea rcx, [rsp + SY_FR]
        call frame_rects
        lea rcx, [rsp + SY_FR]
        lea rdx, [r12 + SH_FRAME]
        mov r8d, 64
        call same16
        test eax, eax
        jnz 1f
        mov byte ptr [rip + .Lsent], 1
        lea rcx, [rsp + SY_FR]
        call pr_frame
        xor eax, eax
2:      movdqu xmm0, xmmword ptr [rsp + rax + SY_FR]
        movdqu xmmword ptr [r12 + rax + SH_FRAME], xmm0
        add eax, 16
        cmp eax, 64
        jb 2b
1:      /* the handles: their surface, once per size, then their places */
        cmp byte ptr [rbx + VIS_HANDLES], 0
        je .Lsy_noh
        lea rdx, [rbx + VIS_BRIGHT]
        JEMPTY(rdx, .Lsy_noh)
        mov eax, dword ptr [rip + .Lhs]
        cmp eax, dword ptr [r12 + SH_HS]
        je 3f
        mov qword ptr [rsp + SY_R], 0
        mov dword ptr [rsp + SY_R + RC_R], eax
        mov dword ptr [rsp + SY_R + RC_B], eax
        mov ecx, PR_HANDLE
        lea rdx, [rsp + SY_R]
        lea r8, [rsp + SY_R]
        mov r9d, PASS_HANDLE
        call paint_part
        mov byte ptr [r12 + SH_HN], 0           /* placed and shown again below */
        mov dword ptr [r12 + SH_HS], 0
        test eax, eax
        jnz 12f
        xor ecx, ecx                            /* no picture: none shown */
        xor edx, edx
        call pr_handles
        jmp .Lsy_clip
12:     mov eax, dword ptr [rip + .Lhs]
        mov dword ptr [r12 + SH_HS], eax
3:      lea rcx, [rsp + SY_HP]
        call handle_pos
        cmp byte ptr [r12 + SH_HN], 8
        jne 4f
        lea rcx, [rsp + SY_HP]
        lea rdx, [r12 + SH_HPOS]
        mov r8d, 64
        call same16
        test eax, eax
        jnz .Lsy_clip
4:      mov byte ptr [rip + .Lsent], 1
        lea rcx, [rsp + SY_HP]
        mov edx, 8
        call pr_handles
        xor eax, eax
5:      movdqu xmm0, xmmword ptr [rsp + rax + SY_HP]
        movdqu xmmword ptr [r12 + rax + SH_HPOS], xmm0
        add eax, 16
        cmp eax, 64
        jb 5b
        mov byte ptr [r12 + SH_HN], 8
        jmp .Lsy_clip
.Lsy_noh:
        cmp byte ptr [r12 + SH_HN], 0
        je .Lsy_clip
        mov byte ptr [rip + .Lsent], 1
        xor ecx, ecx
        xor edx, edx
        call pr_handles
        mov byte ptr [r12 + SH_HN], 0
.Lsy_clip:
        /* the UI layer shows the selection only (selecting, it holds nothing) */
        cmp dword ptr Ov(OV_PHASE), PH_EDIT
        jne .Lsy_panels
        cmp byte ptr [r12 + SH_CLIPOK], 0
        je 6f
        REQ([r12+SH_CLIP], Ov(OV_SEL))
        je .Lsy_panels
6:      RCOPY([r12+SH_CLIP], Ov(OV_SEL))
        mov byte ptr [rip + .Lsent], 1
        lea rcx, [r12 + SH_CLIP]
        call pr_clip
        mov byte ptr [r12 + SH_CLIPOK], 1
.Lsy_panels:
        mov byte ptr [rsp + SY_LD], 0
        xor r13d, r13d                          /* k: label, magnifier, tool bar, property bar, tooltip */
.Lsy_panel:
        lea rax, [rip + .Lpanel_off]
        movzx r14d, word ptr [rax + r13*2]
        lea r15, [rbx + r14]                    /* where O.vis has it */
        lea rsi, [r12 + r14 + SH_VIS]           /* where it is shown */
        JEMPTY(r15, .Lsy_hide)
        mov byte ptr [rsp + SY_FULL], 1
        cmp byte ptr [r12 + r13 + SH_OK], 0
        je .Lsy_draw
        cmp byte ptr [r12 + r13 + SH_DIRTY], 0
        jne .Lsy_draw
        mov eax, dword ptr [r15 + RC_R]         /* the same size at the same scale */
        sub eax, dword ptr [r15 + RC_L]
        mov ecx, dword ptr [rsi + RC_R]
        sub ecx, dword ptr [rsi + RC_L]
        cmp eax, ecx
        jne .Lsy_draw
        mov eax, dword ptr [r15 + RC_B]
        sub eax, dword ptr [r15 + RC_T]
        mov ecx, dword ptr [rsi + RC_B]
        sub ecx, dword ptr [rsi + RC_T]
        cmp eax, ecx
        jne .Lsy_draw
        mov eax, dword ptr [rbx + VIS_S]
        cmp eax, dword ptr [r12 + SH_VIS + VIS_S]
        jne .Lsy_draw
        cmp r13d, 2
        jae .Lsy_opaque
        /* the label and the magnifier show what lies beneath: anywhere else they differ */
        REQ([r15], [rsi])
        jne .Lsy_draw
        REQ([rbx+VIS_BRIGHT], [r12+SH_VIS+VIS_BRIGHT])
        jne .Lsy_draw
        mov al, byte ptr [rbx + VIS_HANDLES]
        cmp al, byte ptr [r12 + SH_VIS + VIS_HANDLES]
        jne .Lsy_draw
        mov al, byte ptr Ov(OV_PIXELS)
        cmp al, byte ptr [r12 + SH_PIX]
        jne .Lsy_draw
        mov eax, dword ptr Ov(OV_PHASE)
        cmp eax, dword ptr [r12 + SH_PHASE]
        jne .Lsy_draw
        test r13d, r13d
        jnz 7f
        lea rcx, [rbx + VIS_LABEL_TEXT]         /* the label's text */
        lea rdx, [r12 + SH_VIS + VIS_LABEL_TEXT]
        mov r8d, 80
        call same16
        test eax, eax
        jz .Lsy_draw
        jmp .Lsy_place
7:      cmp byte ptr [rsp + SY_LD], 0           /* the magnifier: over the label (where it is or */
        je 13f                                  /* was), its pixels */
        lea r8, [rbx + VIS_LABEL]
        OVERLAP r15, r8, 14f
        jmp .Lsy_draw
14:     lea r8, [r12 + SH_VIS + VIS_LABEL]
        OVERLAP r15, r8, 13f
        jmp .Lsy_draw
13:     mov rax, qword ptr [rbx + VIS_MAG_PT]
        cmp rax, qword ptr [r12 + SH_VIS + VIS_MAG_PT]
        jne .Lsy_draw
        mov al, byte ptr [rbx + VIS_MAG_HEX]
        cmp al, byte ptr [r12 + SH_VIS + VIS_MAG_HEX]
        jne .Lsy_draw
        jmp .Lsy_place
.Lsy_opaque:                                    /* the bars and the tooltip: their look only */
        mov rax, qword ptr [rbx + VIS_TB_KEY]
        xor rax, qword ptr [r12 + SH_VIS + VIS_TB_KEY]
        mov rcx, rax
        shr rcx, 26
        and ecx, 0x7F                           /* the tooltip's id */
        cmp r13d, 4
        je 8f
        shl rcx, 26                             /* a bar: anything else, button by button */
        xor rax, rcx
        jz .Lsy_place
        mov byte ptr [rsp + SY_FULL], 0
        jmp .Lsy_draw
8:      test ecx, ecx
        jz .Lsy_place
.Lsy_draw:
        cmp byte ptr [rsp + SY_FULL], 0
        je .Lsy_items
        lea ecx, [r13 + 1]
        mov rdx, r15
        mov r8, r15
        lea rax, [rip + .Lpanel_pass]
        movzx r9d, byte ptr [rax + r13]
        call paint_part
        mov byte ptr [r12 + r13 + SH_OK], al
        mov byte ptr [r12 + r13 + SH_DIRTY], 0
        test al, al
        jz .Lsy_hide
        test r13d, r13d
        jnz .Lsy_show
        mov byte ptr [rsp + SY_LD], 1
        jmp .Lsy_show
.Lsy_items:                                     /* the buttons of this bar whose look changed */
        mov rcx, rbx
        lea rdx, [rsp + SY_ITEMS]
        call tb_items
        mov edi, eax
        lea r14, [rsp + SY_ITEMS]
9:      test edi, edi
        jle .Lsy_place
        mov eax, dword ptr [r14 + ITEM_RC + RC_L]
        cmp eax, dword ptr [r15 + RC_L]
        jl 10f
        cmp eax, dword ptr [r15 + RC_R]
        jge 10f
        mov eax, dword ptr [r14 + ITEM_RC + RC_T]
        cmp eax, dword ptr [r15 + RC_T]
        jl 10f
        cmp eax, dword ptr [r15 + RC_B]
        jge 10f
        mov ecx, dword ptr [r14 + ITEM_ID]
        mov rdx, qword ptr [r12 + SH_VIS + VIS_TB_KEY]
        call item_look
        mov qword ptr [rsp + SY_LOOK], rax
        mov ecx, dword ptr [r14 + ITEM_ID]
        mov rdx, qword ptr [rbx + VIS_TB_KEY]
        call item_look
        cmp rax, qword ptr [rsp + SY_LOOK]
        je 10f
        lea ecx, [r13 + 1]
        mov rdx, r15
        lea r8, [r14 + ITEM_RC]
        mov r9d, PASS_BAR
        call paint_part
        test eax, eax
        jnz 10f
        mov byte ptr [r12 + r13 + SH_OK], 0     /* a button is missing: all of it next time */
10:     add r14, ITEM_BYTES
        dec edi
        jmp 9b
.Lsy_place:
        cmp byte ptr [r12 + r13 + SH_ON], 0
        je .Lsy_show
        REQ([r15], [rsi])
        je .Lsy_next
.Lsy_show:
        mov byte ptr [rip + .Lsent], 1
        lea ecx, [r13 + 1]
        mov rdx, r15
        call pr_part_at
        mov byte ptr [r12 + r13 + SH_ON], 1
        jmp .Lsy_next
.Lsy_hide:
        mov byte ptr [r12 + r13 + SH_OK], 0     /* drawn again when it reappears */
        mov byte ptr [r12 + r13 + SH_DIRTY], 0
        cmp byte ptr [r12 + r13 + SH_ON], 0
        je .Lsy_next
        xorps xmm0, xmm0
        movdqu xmmword ptr [rsp + SY_R], xmm0
        mov byte ptr [rip + .Lsent], 1
        lea ecx, [r13 + 1]
        lea rdx, [rsp + SY_R]
        call pr_part_at
        mov byte ptr [r12 + r13 + SH_ON], 0
.Lsy_next:
        inc r13d
        cmp r13d, 5
        jb .Lsy_panel
        xor eax, eax                            /* what is shown now */
11:     movdqu xmm0, xmmword ptr [rbx + rax]
        movdqu xmmword ptr [r12 + rax + SH_VIS], xmm0
        add eax, 16
        cmp eax, VIS_BYTES - 8
        jb 11b
        mov rax, qword ptr [rbx + VIS_BYTES - 8]
        mov qword ptr [r12 + SH_VIS + VIS_BYTES - 8], rax
        mov al, byte ptr Ov(OV_PIXELS)
        mov byte ptr [r12 + SH_PIX], al
        mov eax, dword ptr Ov(OV_PHASE)
        mov dword ptr [r12 + SH_PHASE], eax
        add rsp, 1008
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* refresh_dc(void): refresh in composition mode. The layers are invalidated only where
 * their pixels change: the UI layer where the live annotations, the text editor or the
 * canvas changed, and where the selection moved over the live parts (the canvas is
 * there in full, the clip follows the selection); the top layer where the pick's
 * handles were and are. Everything else is moved or drawn by ovp_sync. Commits
 * unless a paint is due (on_paint commits then, everything at once). */
#define RD_N 64                                 /* Visual n */
#define RD_A 312
#define RD_PD 328
#define RD_X 344
#define RD_TMP 360
#define RD_PIECE 376                            /* RECT[8] */
#define RD_SCH 504
SFUNC refresh_dc
        PUSHREG rbx
        PUSHREG r13
        PUSHREG r14
        ALLOC 512                               /* [rsp + 32..64): call arguments */
        ENDPROLOG
        ST_ENSURE
        call sh_check
        lea rcx, [rsp + RD_N]
        call compute_visual
        lea rbx, Ov(OV_VIS)                     /* o: what is shown */
        movss xmm0, dword ptr [rsp + RD_N + VIS_S]
        ucomiss xmm0, dword ptr [rbx + VIS_S]
        setne al
        setp cl
        or al, cl
        mov byte ptr [rsp + RD_SCH], al         /* the scale changed */
        lea rcx, [rsp + RD_A]
        lea rdx, [rsp + RD_PD]
        call live_area
        /* the bright area: the dimming; editing, the live parts it now covers or uncovers */
        REQ([rsp+RD_N+VIS_BRIGHT], [rbx+VIS_BRIGHT])
        jne 1f
        mov al, byte ptr [rsp + RD_N + VIS_HANDLES]
        cmp al, byte ptr [rbx + VIS_HANDLES]
        jne 1f
        cmp byte ptr [rsp + RD_SCH], 0
        je .Lrd_live
1:      RCOPY([rsp+RD_TMP], [rsp+RD_N+VIS_BRIGHT])
        mov byte ptr [rip + .Lsent], 1
        lea rcx, [rsp + RD_TMP]
        call pr_dim
#if OVP_BREAK != 4 /* broken: the live parts are not repainted when the selection moves */
        cmp dword ptr Ov(OV_PHASE), PH_EDIT
        jne .Lrd_live
        lea rcx, [rsp + RD_X]
        lea rdx, [rsp + RD_A]
        call live_x
        JEMPTY(rsp + RD_X, .Lrd_live)
        lea rcx, [rsp + RD_PIECE]               /* old XOR new, as rectangles */
        lea rdx, [rbx + VIS_BRIGHT]
        lea r8, [rsp + RD_N + VIS_BRIGHT]
        call rect_sub
        mov rcx, rax
        lea rdx, [rsp + RD_N + VIS_BRIGHT]
        lea r8, [rbx + VIS_BRIGHT]
        call rect_sub
        mov r13, rax
        lea r14, [rsp + RD_PIECE]
2:      cmp r14, r13
        jae .Lrd_live
        lea rcx, [rsp + RD_TMP]
        mov rdx, r14
        lea r8, [rsp + RD_X]
        call ovp_isect
        lea rcx, [rsp + RD_TMP]
        call inv_rect
        add r14, 16
        jmp 2b
#endif
.Lrd_live:
        /* the live annotations and the text editor, unclipped */
        REQ([rsp+RD_A], [rip+.Lsh+SH_A])
        jne 3f
        mov eax, dword ptr [rsp + RD_N + VIS_ACT_VER]
        cmp eax, dword ptr [rbx + VIS_ACT_VER]
        jne 3f
        cmp byte ptr [rsp + RD_SCH], 0
        je .Lrd_pick
3:      lea rcx, [rip + .Lsh + SH_A]
        call inv_rect
        lea rcx, [rsp + RD_A]
        call inv_rect
.Lrd_pick:
        /* the pick's handles (the top layer): the old ones are cleared */
        REQ([rsp+RD_PD], [rip+.Lsh+SH_PD])
        jne 4f
        mov eax, dword ptr [rsp + RD_N + VIS_ACT_VER]
        cmp eax, dword ptr [rbx + VIS_ACT_VER]
        jne 4f
        cmp byte ptr [rsp + RD_SCH], 0
        je .Lrd_canvas
4:      lea rcx, [rip + .Lsh + SH_PD]
        call inv_rect
        lea rcx, [rsp + RD_PD]
        call inv_rect
        lea rcx, [rip + .Lsh + SH_PEND]
        mov rdx, rcx
        lea r8, [rip + .Lsh + SH_PD]
        call ovp_union
.Lrd_canvas:
        /* the canvas, all of it */
        mov eax, dword ptr [rsp + RD_N + VIS_CANVAS_VER]
        cmp eax, dword ptr [rbx + VIS_CANVAS_VER]
        jne 5f
        REQ([rsp+RD_N+VIS_CRECT], [rbx+VIS_CRECT])
        je .Lrd_store
5:      lea rcx, [rbx + VIS_CRECT]
        call inv_rect
        lea rcx, [rsp + RD_N + VIS_CRECT]
        call inv_rect
.Lrd_store:
        /* annotations drawn into the canvas as they came (canvas_add_top: the top one,
         * repainted only inside the selection by its caller): all of each */
        mov r13d, dword ptr Ov(OV_NANN)
        mov eax, dword ptr Ov(OV_NOPS)
#if OVP_BREAK == 5 /* broken: what canvas_add_top drew outside the selection is never painted */
        jmp 10f
#endif
        cmp r13d, dword ptr [rip + .Lsh + SH_NANN]
        jne 8f
        cmp eax, dword ptr [rip + .Lsh + SH_NOPS]
        je 10f
8:      mov dword ptr [rip + .Lsh + SH_NOPS], eax
        mov r14d, dword ptr [rip + .Lsh + SH_NANN]      /* from min(old count, top) on */
        mov dword ptr [rip + .Lsh + SH_NANN], r13d
        lea eax, [r13 - 1]
        cmp r14d, eax
        cmovg r14d, eax
        xor eax, eax
        test r14d, r14d
        cmovs r14d, eax
9:      cmp r14d, r13d
        jge 10f
        movsxd rdx, r14d
        imul rdx, rdx, AN_BYTES
        add rdx, qword ptr Ov(OV_ANN)
        lea rcx, [rsp + RD_TMP]
        call anno_bounds
        lea rcx, [rsp + RD_TMP]
        call inv_rect
        inc r14d
        jmp 9b
10:
        RCOPY([rip+.Lsh+SH_A], [rsp+RD_A])
        RCOPY([rip+.Lsh+SH_PD], [rsp+RD_PD])
        xor eax, eax                            /* O.vis = n */
6:      movdqu xmm0, xmmword ptr [rsp + RD_N + rax]
        movdqu xmmword ptr [rbx + rax], xmm0
        add eax, 16
        cmp eax, VIS_BYTES - 8
        jb 6b
        mov rax, qword ptr [rsp + RD_N + VIS_BYTES - 8]
        mov qword ptr [rbx + VIS_BYTES - 8], rax
        call ovp_sync
        cmp byte ptr [rip + .Lsent], 0          /* nothing new: nothing to commit */
        je 7f
        mov rcx, qword ptr Ov(OV_HWND)
        xor edx, edx
        xor r8d, r8d
        API GetUpdateRect
        test eax, eax
        jnz 7f
        mov byte ptr [rip + .Lsent], 0
        call pr_commit
7:      add rsp, 512
        pop r14
        pop r13
        pop rbx
        ret
ENDF

/* ---- painting ------------------------------------------------------------------------------ */

/* d = surf_at(s, x, y) (x, y: 32-bit registers other than eax and edx); clobbers rax, rdx */
.macro SURF_AT d, s, x, y
        mov eax, \y
        sub eax, dword ptr [\s + SURF_OY]
        movsxd rax, eax
        movsxd rdx, dword ptr [\s + SURF_STRIDE]
        imul rax, rdx
        mov edx, \x
        sub edx, dword ptr [\s + SURF_OX]
        movsxd rdx, edx
        add rax, rdx
        mov rdx, qword ptr [\s + SURF_PX]
        lea \d, [rdx + rax*4]
.endm

/* void band_clip(RECT r): the band DC draws inside r only */
FUNC band_clip
        PUSHREG rbx
        ALLOC 48
        ENDPROLOG
        mov rbx, rcx
        mov byte ptr [rip + .Lclipped], 1       /* GDI draws into this band: paint_band flushes and resets */
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        xor edx, edx
        API SelectClipRgn
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        mov edx, dword ptr [rbx + RC_L]
        mov r8d, dword ptr [rbx + RC_T]
        mov r9d, dword ptr [rbx + RC_R]
        mov eax, dword ptr [rbx + RC_B]
        mov dword ptr [rsp + 32], eax
        API IntersectClipRect
        add rsp, 48
        pop rbx
        ret
ENDF

/* void bright_rect(const Surf *s, RECT R): undimmed pixels of R, the canvas where
 * it covers, the screenshot elsewhere */
FUNC bright_rect
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 64                                /* [rsp + 32]: R, [rsp + 48]: I */
        ENDPROLOG
        mov rbx, rcx
        RCOPY([rsp+32], [rdx])
        JEMPTY(rsp + 32, .Lbr_ret)
        CPU_READY
        movsxd r15, dword ptr [rbx + SURF_STRIDE]
        shl r15, 2                              /* destination row step */
        xor esi, esi
.Lbr_tile:
        cmp esi, dword ptr Ov(OV_SHOT + SHOT_NTILE)
        jge .Lbr_canvas
        imul rdi, rsi, TILE_BYTES
        lea rax, Ov(OV_SHOT + SHOT_TILE)
        add rdi, rax                            /* t */
        inc esi
        cmp qword ptr [rdi + TILE_BITS], 0
        je .Lbr_tile
        lea rcx, [rsp + 48]
        lea rdx, [rsp + 32]
        lea r8, [rdi + TILE_RC]
        call ovp_isect
        JEMPTY(rsp + 48, .Lbr_tile)
        mov ecx, dword ptr [rsp + 48 + RC_L]
        mov r8d, dword ptr [rsp + 48 + RC_T]
        SURF_AT r12, rbx, ecx, r8d
        mov eax, r8d                            /* tile_row(t, I.left, I.top) */
        sub eax, dword ptr [rdi + TILE_RC + RC_T]
        movsxd rax, eax
        movsxd rdx, dword ptr [rdi + TILE_PITCH]
        imul rax, rdx
        sub ecx, dword ptr [rdi + TILE_RC + RC_L]
        movsxd rcx, ecx
        lea rax, [rax + rcx*4]
        add rax, qword ptr [rdi + TILE_BITS]
        mov r13, rax
        movsxd rdi, dword ptr [rdi + TILE_PITCH]
        mov r14d, dword ptr [rsp + 48 + RC_B]
        sub r14d, r8d                           /* rows */
1:      mov r8, r12
        mov r9, r13
        mov ecx, dword ptr [rsp + 48 + RC_R]
        sub ecx, dword ptr [rsp + 48 + RC_L]
        call px_copy
        add r12, r15
        add r13, rdi
        dec r14d
        jnz 1b
        jmp .Lbr_tile
.Lbr_canvas:
        cmp byte ptr Ov(OV_CANVAS_OK), 0
        je .Lbr_ret
        lea rcx, [rsp + 48]
        lea rdx, [rsp + 32]
        lea r8, Ov(OV_CRECT)
        call ovp_isect
        JEMPTY(rsp + 48, .Lbr_ret)
        mov ecx, dword ptr [rsp + 48 + RC_L]
        mov r8d, dword ptr [rsp + 48 + RC_T]
        SURF_AT r12, rbx, ecx, r8d
        mov eax, r8d                            /* O.canvas.px + (y - crect.top) * w + (x - crect.left) */
        sub eax, dword ptr Ov(OV_CRECT + RC_T)
        movsxd rax, eax
        movsxd rdi, dword ptr Ov(OV_CANVAS + IMG_W)
        imul rax, rdi
        sub ecx, dword ptr Ov(OV_CRECT + RC_L)
        movsxd rcx, ecx
        add rax, rcx
        mov rcx, qword ptr Ov(OV_CANVAS + IMG_PX)
        lea r13, [rcx + rax*4]
        shl rdi, 2
        mov r14d, dword ptr [rsp + 48 + RC_B]
        sub r14d, r8d
2:      mov r8, r12
        mov r9, r13
        mov ecx, dword ptr [rsp + 48 + RC_R]
        sub ecx, dword ptr [rsp + 48 + RC_L]
        call px_copy
        add r12, r15
        add r13, rdi
        dec r14d
        jnz 2b
.Lbr_ret:
        add rsp, 64
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* zero_rect(const Surf *s, RECT B): rdx = &B, its pixels transparent */
SFUNC zero_rect
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 56                                /* [rsp + 32]: B */
        ENDPROLOG
        mov rbx, rcx
        RCOPY([rsp+32], [rdx])
        CPU_READY
        mov edi, dword ptr [rsp + 32 + RC_B]
        mov r8d, dword ptr [rsp + 32 + RC_T]
        sub edi, r8d
        jle 2f
        mov ecx, dword ptr [rsp + 32 + RC_L]
        SURF_AT r12, rbx, ecx, r8d
        movsxd rsi, dword ptr [rbx + SURF_STRIDE]
        shl rsi, 2
1:      mov r8, r12
        mov ecx, dword ptr [rsp + 32 + RC_R]
        sub ecx, dword ptr [rsp + 32 + RC_L]
        call px_zero
        add r12, rsi
        dec edi
        jnz 1b
2:      add rsp, 56
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void compose_dc(const Surf *s, RECT B): the UI layer, transparent except the canvas
 * (all of it: the selection clips the layer) and the live annotations over the
 * bright area */
FUNC compose_dc
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 72                                /* [rsp + 32]: B, [rsp + 48]: tmp */
        ENDPROLOG
        mov rbx, rcx
        RCOPY([rsp+32], [rdx])
        call zero_rect
2:      cmp dword ptr Ov(OV_PHASE), PH_EDIT
        jne 4f
        cmp byte ptr Ov(OV_PIXELS), 0
        je 4f
        cmp byte ptr Ov(OV_CANVAS_OK), 0
        je 3f
        lea rcx, [rsp + 48]
        lea rdx, Ov(OV_CRECT)
        lea r8, [rsp + 32]
        call ovp_isect
        mov rcx, rbx
        lea rdx, [rsp + 48]
        call bright_rect
3:      lea rcx, [rsp + 48]
        lea rdx, Ov(OV_VIS + VIS_ACT)
        lea r8, Ov(OV_SEL)
        call ovp_isect
        lea rcx, [rsp + 48]
        lea rdx, [rsp + 32]
        mov r8, rcx
        call ovp_isect
        mov rcx, rbx
        lea rdx, [rsp + 48]
        call bright_rect
4:      add rsp, 72
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void alpha_fix(const Surf *s, RECT R): GDI text leaves alpha 0; opaque inside R */
FUNC alpha_fix
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 56                                /* [rsp + 32]: R within the clip */
        ENDPROLOG
        mov rbx, rcx
        CPU_READY
        lea rcx, [rsp + 32]
        lea r8, [rbx + SURF_CL]
        call ovp_isect
        JEMPTY(rsp + 32, 2f)
        mov ecx, dword ptr [rsp + 32 + RC_L]
        mov r8d, dword ptr [rsp + 32 + RC_T]
        SURF_AT r12, rbx, ecx, r8d
        movsxd rsi, dword ptr [rbx + SURF_STRIDE]
        shl rsi, 2
        mov edi, dword ptr [rsp + 32 + RC_B]
        sub edi, r8d
1:      mov r8, r12
        mov ecx, dword ptr [rsp + 32 + RC_R]
        sub ecx, dword ptr [rsp + 32 + RC_L]
        call px_alpha
        add r12, rsi
        dec edi
        jnz 1b
2:      add rsp, 56
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void compose_gdi(const Surf *s, RECT B): the screenshot dimmed outside the bright
 * area, the canvas inside it. Runs on several threads at once (paint_worker). */
#define CG_B 32
#define CG_BR 48
#define CG_CR 64
#define CG_I 80
#define CG_A 96                 /* a, b, ca, cb as offsets from I.left (pixels) */
#define CG_BB 100
#define CG_CA 104
#define CG_CB 108
#define CG_DSTEP 112
#define CG_SSTEP 120
#define CG_CSTEP 128
FUNC compose_gdi
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG rbp
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 136
        ENDPROLOG
        mov rsi, rcx
        RCOPY([rsp+CG_B], [rdx])
        CPU_READY
        RCOPY([rsp+CG_BR], Ov(OV_VIS+VIS_BRIGHT))
        xorps xmm0, xmm0
        movdqu xmmword ptr [rsp + CG_CR], xmm0
        cmp dword ptr Ov(OV_PHASE), PH_EDIT     /* inside the selection, the canvas where it has pixels */
        jne 1f
        cmp byte ptr Ov(OV_CANVAS_OK), 0
        je 1f
        lea rcx, [rsp + CG_CR]
        lea rdx, Ov(OV_CRECT)
        lea r8, [rsp + CG_BR]
        call ovp_isect
1:      cmp byte ptr Ov(OV_SHOT + SHOT_GAPS), 0
        je 2f
        RCOPY([rsp+CG_I], [rsp+CG_B])
        mov rcx, rsi
        lea rdx, [rsp + CG_I]
        xor r8d, r8d
        call d_fill
2:      movsxd rax, dword ptr [rsi + SURF_STRIDE]
        shl rax, 2
        mov qword ptr [rsp + CG_DSTEP], rax
        movsxd rax, dword ptr Ov(OV_CANVAS + IMG_W)
        shl rax, 2
        mov qword ptr [rsp + CG_CSTEP], rax
        xor ebp, ebp
.Lcg_tile:
        cmp ebp, dword ptr Ov(OV_SHOT + SHOT_NTILE)
        jge .Lcg_gaps
        imul rbx, rbp, TILE_BYTES
        lea rax, Ov(OV_SHOT + SHOT_TILE)
        add rbx, rax                            /* t */
        inc ebp
        cmp qword ptr [rbx + TILE_BITS], 0
        je .Lcg_tile
        lea rcx, [rsp + CG_I]
        lea rdx, [rsp + CG_B]
        lea r8, [rbx + TILE_RC]
        call ovp_isect
        JEMPTY(rsp + CG_I, .Lcg_tile)
        mov eax, dword ptr [rsp + CG_I + RC_L]
        mov ecx, dword ptr [rsp + CG_I + RC_R]
        mov r8d, dword ptr [rsp + CG_BR + RC_L]
        CLAMP r8d, eax, ecx, r10d               /* a */
        mov r9d, dword ptr [rsp + CG_BR + RC_R]
        CLAMP r9d, eax, ecx, r10d               /* b */
        mov r10d, dword ptr [rsp + CG_CR + RC_L]
        CLAMP r10d, r8d, r9d, r11d              /* ca */
        mov r11d, dword ptr [rsp + CG_CR + RC_R]
        CLAMP r11d, r8d, r9d, edx               /* cb */
        sub r8d, eax
        sub r9d, eax
        sub r10d, eax
        sub r11d, eax
        mov dword ptr [rsp + CG_A], r8d
        mov dword ptr [rsp + CG_BB], r9d
        mov dword ptr [rsp + CG_CA], r10d
        mov dword ptr [rsp + CG_CB], r11d
        movsxd rax, dword ptr [rbx + TILE_PITCH]
        mov qword ptr [rsp + CG_SSTEP], rax
        mov edi, dword ptr [rsp + CG_I + RC_T]  /* y */
        mov edx, edi                            /* src = tile_row(t, I.left, y) */
        sub edx, dword ptr [rbx + TILE_RC + RC_T]
        movsxd rdx, edx
        imul rdx, rax
        mov eax, dword ptr [rsp + CG_I + RC_L]
        sub eax, dword ptr [rbx + TILE_RC + RC_L]
        cdqe
        lea rdx, [rdx + rax*4]
        add rdx, qword ptr [rbx + TILE_BITS]
        mov r13, rdx
        mov ecx, dword ptr [rsp + CG_I + RC_L]  /* dst = surf_at(s, I.left, y) */
        SURF_AT r12, rsi, ecx, edi
        mov eax, edi                            /* the canvas at (ca, y) */
        sub eax, dword ptr Ov(OV_CRECT + RC_T)
        movsxd rax, eax
        movsxd rdx, dword ptr Ov(OV_CANVAS + IMG_W)
        imul rax, rdx
        mov edx, dword ptr [rsp + CG_I + RC_L]
        add edx, dword ptr [rsp + CG_CA]
        sub edx, dword ptr Ov(OV_CRECT + RC_L)
        movsxd rdx, edx
        add rax, rdx
        mov rdx, qword ptr Ov(OV_CANVAS + IMG_PX)
        lea r14, [rdx + rax*4]
        mov r15d, dword ptr [rsp + CG_I + RC_R]
        sub r15d, dword ptr [rsp + CG_I + RC_L] /* row width */
.Lcg_row:
        cmp edi, dword ptr [rsp + CG_I + RC_B]
        jge .Lcg_tile
        mov eax, dword ptr [rsp + CG_BB]
        cmp eax, dword ptr [rsp + CG_A]
        jle .Lcg_dim
        cmp edi, dword ptr [rsp + CG_BR + RC_T]
        jl .Lcg_dim
        cmp edi, dword ptr [rsp + CG_BR + RC_B]
        jge .Lcg_dim
        mov r8, r12                             /* dimmed left of the bright area */
        mov r9, r13
        mov ecx, dword ptr [rsp + CG_A]
        call px_dim
        mov eax, dword ptr [rsp + CG_CB]
        cmp eax, dword ptr [rsp + CG_CA]
        jle 2f
        cmp edi, dword ptr [rsp + CG_CR + RC_T]
        jl 2f
        cmp edi, dword ptr [rsp + CG_CR + RC_B]
        jge 2f
        movsxd rax, dword ptr [rsp + CG_A]      /* screenshot, canvas, screenshot */
        lea r8, [r12 + rax*4]
        lea r9, [r13 + rax*4]
        mov ecx, dword ptr [rsp + CG_CA]
        sub ecx, eax
        call px_copy
        movsxd rax, dword ptr [rsp + CG_CA]
        lea r8, [r12 + rax*4]
        mov r9, r14
        mov ecx, dword ptr [rsp + CG_CB]
        sub ecx, eax
        call px_copy
        movsxd rax, dword ptr [rsp + CG_CB]
        lea r8, [r12 + rax*4]
        lea r9, [r13 + rax*4]
        mov ecx, dword ptr [rsp + CG_BB]
        sub ecx, eax
        call px_copy
        jmp 3f
2:      movsxd rax, dword ptr [rsp + CG_A]      /* the screenshot */
        lea r8, [r12 + rax*4]
        lea r9, [r13 + rax*4]
        mov ecx, dword ptr [rsp + CG_BB]
        sub ecx, eax
        call px_copy
3:      movsxd rax, dword ptr [rsp + CG_BB]     /* dimmed right of it */
        lea r8, [r12 + rax*4]
        lea r9, [r13 + rax*4]
        mov ecx, r15d
        sub ecx, eax
        call px_dim
        jmp .Lcg_next
.Lcg_dim:
        mov r8, r12
        mov r9, r13
        mov ecx, r15d
#if OVP_BREAK == 1 /* a deliberately broken build, for the tests: the last pixel of dimmed rows is left out */
        dec ecx
#endif
        call px_dim
.Lcg_next:
        add r12, qword ptr [rsp + CG_DSTEP]
        add r13, qword ptr [rsp + CG_SSTEP]
        add r14, qword ptr [rsp + CG_CSTEP]
        inc edi
        jmp .Lcg_row
.Lcg_gaps:                                      /* annotations may cover parts outside every monitor */
        cmp byte ptr Ov(OV_SHOT + SHOT_GAPS), 0
        je .Lcg_ret
        lea rcx, [rsp + CG_I]
        lea rdx, [rsp + CG_B]
        lea r8, [rsp + CG_CR]
        call ovp_isect
        JEMPTY(rsp + CG_I, .Lcg_ret)
        mov ecx, dword ptr [rsp + CG_I + RC_L]
        mov edi, dword ptr [rsp + CG_I + RC_T]
        SURF_AT r12, rsi, ecx, edi
        mov eax, edi
        sub eax, dword ptr Ov(OV_CRECT + RC_T)
        movsxd rax, eax
        movsxd rdx, dword ptr Ov(OV_CANVAS + IMG_W)
        imul rax, rdx
        sub ecx, dword ptr Ov(OV_CRECT + RC_L)
        movsxd rcx, ecx
        add rax, rcx
        mov rdx, qword ptr Ov(OV_CANVAS + IMG_PX)
        lea r14, [rdx + rax*4]
        mov r15d, dword ptr [rsp + CG_I + RC_B]
        sub r15d, edi
4:      mov r8, r12
        mov r9, r14
        mov ecx, dword ptr [rsp + CG_I + RC_R]
        sub ecx, dword ptr [rsp + CG_I + RC_L]
        call px_copy
        add r12, qword ptr [rsp + CG_DSTEP]
        add r14, qword ptr [rsp + CG_CSTEP]
        dec r15d
        jnz 4b
.Lcg_ret:
        add rsp, 136
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

/* void compose_base(const Surf *s, RECT B): the picture under the UI */
FUNC compose_base
        ENDPROLOG
        cmp byte ptr Ov(OV_DC), 0
        je compose_gdi
        jmp compose_pass
ENDF

/* composition mode, by pass: the UI layer's own picture; under the label and the
 * magnifier (they may be translucent) the GDI picture, so they look the same (they
 * are made opaque after drawing); nothing under the rest, which is opaque */
SFUNC compose_pass
        ENDPROLOG
        movzx eax, byte ptr [rip + .Lpass]
        test eax, eax                           /* PASS_UI */
        jz compose_dc
        cmp eax, PASS_LABEL
        je 1f
        cmp eax, PASS_MAG
        jne zero_rect
1:      cmp byte ptr Ov(OV_PIXELS), 0
        jne compose_gdi
        jmp zero_rect
ENDF

/* void draw_frame(const Surf *s, const Visual *v): the accent frame and the handles */
FUNC draw_frame
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 80                                /* [rsp + 32]: rect, [rsp + 48]: xs[3], [rsp + 64]: ys[3] */
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        JEMPTY(rsi + VIS_BRIGHT, .Ldf_ret)
        ST_ENSURE
        mov edi, dword ptr [rip + .Lborder]
        lea rcx, [rsp + 32]
        lea rdx, [rsi + VIS_BRIGHT]
        mov r8d, edi
        call ovp_inflate
        mov qword ptr [rsp + 48], 0             /* client rect */
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VW)
        mov dword ptr [rsp + 56], eax
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VH)
        mov dword ptr [rsp + 60], eax
        lea rcx, [rsp + 32]
        mov rdx, rcx
        lea r8, [rsp + 48]
        call ovp_isect
        mov rcx, rbx
        lea rdx, [rsp + 32]
        call touches
        test eax, eax
        jz 1f
        mov rcx, rbx
        lea rdx, [rsp + 32]
        mov r8d, edi
        mov r9d, ACCENT
        call d_frame
1:      cmp byte ptr [rsi + VIS_HANDLES], 0
        je .Ldf_ret
        mov eax, dword ptr [rsi + VIS_BRIGHT + RC_L]    /* xs = {l, (l + r) / 2, r} */
        mov ecx, dword ptr [rsi + VIS_BRIGHT + RC_R]
        mov dword ptr [rsp + 48], eax
        mov dword ptr [rsp + 56], ecx
        add eax, ecx
        mov edx, eax
        shr edx, 31
        add eax, edx
        sar eax, 1
        mov dword ptr [rsp + 52], eax
        mov eax, dword ptr [rsi + VIS_BRIGHT + RC_T]    /* ys */
        mov ecx, dword ptr [rsi + VIS_BRIGHT + RC_B]
        mov dword ptr [rsp + 64], eax
        mov dword ptr [rsp + 72], ecx
        add eax, ecx
        mov edx, eax
        shr edx, 31
        add eax, edx
        sar eax, 1
        mov dword ptr [rsp + 68], eax
        mov r12d, dword ptr [rip + .Lhs]        /* hs */
        mov r13d, r12d
        shr r13d, 1                             /* hs / 2 */
        xor r14d, r14d                          /* j */
2:      xor r15d, r15d                          /* i */
3:      cmp r14d, 1
        jne 4f
        cmp r15d, 1
        je 5f
4:      mov edi, dword ptr [rsp + r15*4 + 48]   /* x = CLAMPI(xs[i] - hs / 2, 0, vw - hs) */
        sub edi, r13d
        xor eax, eax
        mov ecx, dword ptr Ov(OV_SHOT + SHOT_VW)
        sub ecx, r12d
        CLAMP edi, eax, ecx, edx
        mov esi, dword ptr [rsp + r14*4 + 64]   /* y */
        sub esi, r13d
        mov ecx, dword ptr Ov(OV_SHOT + SHOT_VH)
        sub ecx, r12d
        CLAMP esi, eax, ecx, edx
        mov dword ptr [rsp + 32 + RC_L], edi
        mov dword ptr [rsp + 32 + RC_T], esi
        lea eax, [rdi + r12]
        mov dword ptr [rsp + 32 + RC_R], eax
        lea eax, [rsi + r12]
        mov dword ptr [rsp + 32 + RC_B], eax
        mov rcx, rbx
        lea rdx, [rsp + 32]
        call touches
        test eax, eax
        jz 5f
        mov rcx, rbx
        lea rdx, [rsp + 32]
        mov r8d, ACCENT
        call d_fill
        mov dword ptr [rsp + 32 + RC_L], edi    /* d_fill owned the copy */
        mov dword ptr [rsp + 32 + RC_T], esi
        lea eax, [rdi + r12]
        mov dword ptr [rsp + 32 + RC_R], eax
        lea eax, [rsi + r12]
        mov dword ptr [rsp + 32 + RC_B], eax
        mov rcx, rbx
        lea rdx, [rsp + 32]
        mov r8d, 1
        mov r9d, 0xFFFFFF
        call d_frame
5:      inc r15d
        cmp r15d, 3
        jb 3b
        inc r14d
        cmp r14d, 3
        jb 2b
.Ldf_ret:
        add rsp, 80
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void draw_pick(const Surf *s): the picked annotation's handles, or a dashed box
 * around the kinds that can only be moved */
#define DP_BOX 56
#define DP_HP 72
#define DP_CODE 136
FUNC draw_pick
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        ALLOC 184
        ENDPROLOG
        mov rbx, rcx
        mov eax, dword ptr Ov(OV_PICK)
        test eax, eax
        js .Ldp_ret
        inc eax
        cmp eax, dword ptr Ov(OV_TE_EDIT1)      /* the editor shows the text instead */
        je .Ldp_ret
        ST_ENSURE
        lea rcx, [rsp + DP_HP]
        lea rdx, [rsp + DP_CODE]
        call pick_handles
        mov edi, eax                            /* n */
        mov r12d, dword ptr [rip + .Lhs]
        mov r13d, r12d
        shr r13d, 1
        test edi, edi
        jnz 2f
        movsxd r14, dword ptr Ov(OV_PICK)
        imul r14, r14, AN_BYTES
        add r14, qword ptr Ov(OV_ANN)           /* a */
        cmp dword ptr [r14 + AN_TOOL], T_TEXT
        jne 1f
        lea rcx, [rsp + DP_BOX]
        mov rdx, qword ptr [r14 + AN_TEXT]
        mov r8d, dword ptr [r14 + AN_NTEXT]
        mov rax, qword ptr [r14 + AN_PT]
        mov r9, qword ptr [rax]
        mov eax, dword ptr [r14 + AN_SIZE]
        mov dword ptr [rsp + 32], eax
        mov qword ptr [rsp + 40], 0
        mov qword ptr [rsp + 48], 0
        call text_box
        lea rcx, [rsp + DP_BOX]
        mov rdx, rcx
        mov r8d, dword ptr [rip + .Ls4]
        call ovp_inflate
        jmp 9f
1:      lea rcx, [rsp + DP_BOX]
        mov rdx, r14
        call anno_bounds
        lea rcx, [rsp + DP_BOX]
        mov rdx, rcx
        mov r8d, dword ptr [rip + .Ls2]
        call ovp_inflate
9:      mov rcx, rbx
        lea rdx, [rsp + DP_BOX]
        xor r8d, r8d
        mov r9d, 0xFFFFFF
        mov eax, dword ptr [rip + .Ls3]
        mov dword ptr [rsp + 32], eax
        call d_dash_frame
        jmp .Ldp_ret
2:      xor esi, esi                            /* k */
3:      cmp esi, edi
        jge .Ldp_ret
        mov eax, dword ptr [rsp + rsi*8 + DP_HP + PT_X]
        sub eax, r13d
        mov ecx, dword ptr [rsp + rsi*8 + DP_HP + PT_Y]
        sub ecx, r13d
        mov dword ptr [rsp + DP_BOX + RC_L], eax
        mov dword ptr [rsp + DP_BOX + RC_T], ecx
        add eax, r12d
        add ecx, r12d
        mov dword ptr [rsp + DP_BOX + RC_R], eax
        mov dword ptr [rsp + DP_BOX + RC_B], ecx
        mov rcx, rbx
        lea rdx, [rsp + DP_BOX]
        call touches
        test eax, eax
        jz 4f
        mov rcx, rbx
        lea rdx, [rsp + DP_BOX]
        mov r8d, 0xFFFFFF
        call d_fill
        mov eax, dword ptr [rsp + rsi*8 + DP_HP + PT_X]
        sub eax, r13d
        mov ecx, dword ptr [rsp + rsi*8 + DP_HP + PT_Y]
        sub ecx, r13d
        mov dword ptr [rsp + DP_BOX + RC_L], eax
        mov dword ptr [rsp + DP_BOX + RC_T], ecx
        add eax, r12d
        add ecx, r12d
        mov dword ptr [rsp + DP_BOX + RC_R], eax
        mov dword ptr [rsp + DP_BOX + RC_B], ecx
        mov rcx, rbx
        lea rdx, [rsp + DP_BOX]
        mov r8d, dword ptr [rip + .Ls1]
        mov r9d, ACCENT
        call d_frame
4:      inc esi
        jmp 3b
.Ldp_ret:
        add rsp, 184
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* COLORREF of 0xRRGGBB in eax (clobbers ecx) */
.macro CREF
        mov ecx, eax
        bswap eax
        shr eax, 8                              /* 0x00BBGGRR */
.endm

/* void draw_text_at(RECT B, int x, int y, const WCHAR *t, uint32_t color) */
FUNC draw_text_at
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        ALLOC 48
        ENDPROLOG
        mov esi, edx                            /* x */
        mov edi, r8d                            /* y */
        mov r12, r9                             /* t */
        mov r13d, dword ptr [rsp + 48 + 40 + 40]        /* color */
        call band_clip
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        mov rdx, qword ptr Ov(OV_FONT_UI)
        API SelectObject
        mov rbx, rax
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        mov edx, W_TRANSPARENT
        API SetBkMode
        mov eax, r13d
        CREF
        mov edx, eax
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        API SetTextColor
        mov rax, r12                            /* lstrlenW */
1:      cmp word ptr [rax], 0
        je 2f
        add rax, 2
        jmp 1b
2:      sub rax, r12
        shr eax, 1
        mov dword ptr [rsp + 32], eax
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        mov edx, esi
        mov r8d, edi
        mov r9, r12
        API TextOutW
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        mov rdx, rbx
        API SelectObject
        add rsp, 48
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void draw_text_in(RECT B, RECT r, const WCHAR *t, uint32_t color): centered in r */
FUNC draw_text_in
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 56                                /* [rsp + 40]: r */
        ENDPROLOG
        RCOPY([rsp+40], [rdx])
        mov rsi, r8                             /* t */
        mov edi, r9d                            /* color */
        call band_clip
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        mov rdx, qword ptr Ov(OV_FONT_UI)
        API SelectObject
        mov rbx, rax
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        mov edx, W_TRANSPARENT
        API SetBkMode
        mov eax, edi
        CREF
        mov edx, eax
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        API SetTextColor
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        mov rdx, rsi
        mov r8d, -1
        lea r9, [rsp + 40]
        mov dword ptr [rsp + 32], W_DT_LABEL
        API DrawTextW
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        mov rdx, rbx
        API SelectObject
        add rsp, 56
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void draw_label(const Surf *s, RECT B, const Visual *v): the size label */
FUNC draw_label
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 48                                /* [rsp + 32]: rect */
        ENDPROLOG
        mov rbx, rcx
        mov rdi, rdx
        mov rsi, r8
        JEMPTY(rsi + VIS_LABEL, 1f)
        lea rdx, [rsi + VIS_LABEL]
        call touches
        test eax, eax
        jz 1f
        RCOPY([rsp+32], [rsi+VIS_LABEL])
        mov rcx, rbx
        lea rdx, [rsp + 32]
        xor r8d, r8d
        mov r9d, 185
        call d_fill_alpha
        mov rcx, rdi
        lea rdx, [rsi + VIS_LABEL]
        lea r8, [rsi + VIS_LABEL_TEXT]
        mov r9d, 0xFFFFFF
        call draw_text_in
        API GdiFlush
1:      add rsp, 48
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void draw_magnifier(const Surf *s, RECT B, const Visual *v): the zoomed pixels
 * around the cursor, its position and color */
#define DM_B 48
#define DM_TMP 64
#define DM_GRID 80
#define DM_L1 96
#define DM_L2 192
#define DM_INFO 288
#define DM_CX 304
#define DM_CY 308
#define DM_COL 312
#define DM_TY 316
#define DM_XA 320
#define DM_XB 324
#define DM_X0 328
#define DM_X1 332
#define DM_ROW 336
#define DM_V 344
#define DM_SX0 352
FUNC draw_magnifier
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG rbp
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 360
        ENDPROLOG
        mov rbx, rcx
        mov rsi, r8
        mov qword ptr [rsp + DM_V], r8
        RCOPY([rsp+DM_B], [rdx])
        JEMPTY(rsi + VIS_MAG, .Ldm_ret)
        lea rdx, [rsi + VIS_MAG]
        call touches
        test eax, eax
        jz .Ldm_ret
        ST_ENSURE
        CPU_READY
        mov r15d, dword ptr [rip + .Lcell]      /* cell */
        mov eax, dword ptr [rsi + VIS_MAG + RC_L]       /* grid */
        inc eax
        mov dword ptr [rsp + DM_GRID + RC_L], eax
        imul ecx, r15d, MAG_COLS
        add eax, ecx
        mov dword ptr [rsp + DM_GRID + RC_R], eax
        mov eax, dword ptr [rsi + VIS_MAG + RC_T]
        inc eax
        mov dword ptr [rsp + DM_GRID + RC_T], eax
        imul ecx, r15d, MAG_ROWS
        add eax, ecx
        mov dword ptr [rsp + DM_GRID + RC_B], eax
        mov eax, dword ptr [rsi + VIS_MAG + RC_L]       /* gframe = {m.l, m.t, m.r, grid.b + 1} */
        mov dword ptr [rsp + DM_TMP + RC_L], eax
        mov eax, dword ptr [rsi + VIS_MAG + RC_T]
        mov dword ptr [rsp + DM_TMP + RC_T], eax
        mov eax, dword ptr [rsi + VIS_MAG + RC_R]
        mov dword ptr [rsp + DM_TMP + RC_R], eax
        mov eax, dword ptr [rsp + DM_GRID + RC_B]
        inc eax
        mov dword ptr [rsp + DM_TMP + RC_B], eax
        mov rcx, rbx
        lea rdx, [rsp + DM_TMP]
        mov r8d, 1
        xor r9d, r9d
        call d_frame
        mov eax, dword ptr [rsi + VIS_MAG_PT + PT_X]
        sub eax, MAG_COLS / 2
        mov dword ptr [rsp + DM_SX0], eax
        /* the cells: per cell row, one pixel row is filled and copied to the others */
        mov eax, dword ptr [rsp + DM_GRID + RC_L]
        cmp eax, dword ptr [rbx + SURF_CL]
        cmovl eax, dword ptr [rbx + SURF_CL]
        mov ecx, dword ptr [rsp + DM_GRID + RC_R]
        cmp ecx, dword ptr [rbx + SURF_CR]
        cmovg ecx, dword ptr [rbx + SURF_CR]
        cmp ecx, eax
        jle .Ldm_cells_done
        mov dword ptr [rsp + DM_XA], eax
        mov dword ptr [rsp + DM_XB], ecx
        xor r14d, r14d                          /* j */
.Ldm_crow:
        mov edi, r14d
        imul edi, r15d
        add edi, dword ptr [rsp + DM_GRID + RC_T]       /* cy */
        cmp edi, dword ptr [rbx + SURF_CB]
        jge .Ldm_crow_next
        lea eax, [rdi + r15]
        cmp eax, dword ptr [rbx + SURF_CT]
        jle .Ldm_crow_next
        mov esi, edi                            /* ya = MAXI(cy, clip.top) */
        cmp esi, dword ptr [rbx + SURF_CT]
        cmovl esi, dword ptr [rbx + SURF_CT]
        lea r13d, [rdi + r15]                   /* yb = MINI(cy + cell, clip.bottom) */
        cmp r13d, dword ptr [rbx + SURF_CB]
        cmovg r13d, dword ptr [rbx + SURF_CB]
        mov rax, qword ptr [rsp + DM_V]
        mov r12d, dword ptr [rax + VIS_MAG_PT + PT_Y]
        sub r12d, MAG_ROWS / 2
        add r12d, r14d                          /* py */
        mov ecx, dword ptr [rsp + DM_XA]
        SURF_AT rbp, rbx, ecx, esi
        xor edi, edi                            /* i */
.Ldm_cell:
        mov eax, edi
        imul eax, r15d
        add eax, dword ptr [rsp + DM_GRID + RC_L]       /* x0 */
        lea ecx, [rax + r15]                    /* x1 */
        cmp eax, dword ptr [rsp + DM_XA]
        cmovl eax, dword ptr [rsp + DM_XA]
        cmp ecx, dword ptr [rsp + DM_XB]
        cmovg ecx, dword ptr [rsp + DM_XB]
        cmp ecx, eax
        jle .Ldm_cell_next
        mov dword ptr [rsp + DM_X0], eax
        mov dword ptr [rsp + DM_X1], ecx
        mov edx, dword ptr [rsp + DM_SX0]
        add edx, edi                            /* px */
        xor eax, eax
        test edx, edx
        js 1f
        test r12d, r12d
        js 1f
        cmp edx, dword ptr Ov(OV_SHOT + SHOT_VW)
        jge 1f
        cmp r12d, dword ptr Ov(OV_SHOT + SHOT_VH)
        jge 1f
        mov r8d, r12d
        call pix_at
1:      or eax, 0xFF000000
        mov ecx, dword ptr [rsp + DM_X0]
        mov edx, dword ptr [rsp + DM_X1]
        sub edx, ecx
        sub ecx, dword ptr [rsp + DM_XA]
        lea r8, [rbp + rcx*4]
2:      mov dword ptr [r8], eax
        add r8, 4
        dec edx
        jnz 2b
.Ldm_cell_next:
        inc edi
        cmp edi, MAG_COLS
        jb .Ldm_cell
        mov qword ptr [rsp + DM_ROW], rbp
        movsxd rdi, dword ptr [rbx + SURF_STRIDE]
        shl rdi, 2
3:      inc esi
        cmp esi, r13d
        jge .Ldm_crow_next
        add rbp, rdi
        mov r8, rbp
        mov r9, qword ptr [rsp + DM_ROW]
        mov ecx, dword ptr [rsp + DM_XB]
        sub ecx, dword ptr [rsp + DM_XA]
        call px_copy
        jmp 3b
.Ldm_crow_next:
        inc r14d
        cmp r14d, MAG_ROWS
        jb .Ldm_crow
.Ldm_cells_done:
        mov rsi, qword ptr [rsp + DM_V]
        mov eax, dword ptr [rsp + DM_GRID + RC_L]       /* the cross through the center cell */
        imul ecx, r15d, MAG_COLS / 2
        add eax, ecx
        mov dword ptr [rsp + DM_CX], eax
        mov eax, dword ptr [rsp + DM_GRID + RC_T]
        imul ecx, r15d, MAG_ROWS / 2
        add eax, ecx
        mov dword ptr [rsp + DM_CY], eax
        mov eax, dword ptr [rsp + DM_GRID + RC_L]       /* h1 = {grid.l, cyy, cx, cyy + cell} */
        mov dword ptr [rsp + DM_TMP + RC_L], eax
        mov eax, dword ptr [rsp + DM_CY]
        mov dword ptr [rsp + DM_TMP + RC_T], eax
        add eax, r15d
        mov dword ptr [rsp + DM_TMP + RC_B], eax
        mov eax, dword ptr [rsp + DM_CX]
        mov dword ptr [rsp + DM_TMP + RC_R], eax
        mov rcx, rbx
        lea rdx, [rsp + DM_TMP]
        mov r8d, ACCENT
        mov r9d, 90
        call d_fill_alpha
        mov eax, dword ptr [rsp + DM_CX]        /* h2 = {cx + cell, cyy, grid.r, cyy + cell} */
        add eax, r15d
        mov dword ptr [rsp + DM_TMP + RC_L], eax
        mov eax, dword ptr [rsp + DM_CY]
        mov dword ptr [rsp + DM_TMP + RC_T], eax
        add eax, r15d
        mov dword ptr [rsp + DM_TMP + RC_B], eax
        mov eax, dword ptr [rsp + DM_GRID + RC_R]
        mov dword ptr [rsp + DM_TMP + RC_R], eax
        mov rcx, rbx
        lea rdx, [rsp + DM_TMP]
        mov r8d, ACCENT
        mov r9d, 90
        call d_fill_alpha
        mov eax, dword ptr [rsp + DM_CX]        /* v1 = {cx, grid.t, cx + cell, cyy} */
        mov dword ptr [rsp + DM_TMP + RC_L], eax
        add eax, r15d
        mov dword ptr [rsp + DM_TMP + RC_R], eax
        mov eax, dword ptr [rsp + DM_GRID + RC_T]
        mov dword ptr [rsp + DM_TMP + RC_T], eax
        mov eax, dword ptr [rsp + DM_CY]
        mov dword ptr [rsp + DM_TMP + RC_B], eax
        mov rcx, rbx
        lea rdx, [rsp + DM_TMP]
        mov r8d, ACCENT
        mov r9d, 90
        call d_fill_alpha
        mov eax, dword ptr [rsp + DM_CX]        /* v2 = {cx, cyy + cell, cx + cell, grid.b} */
        mov dword ptr [rsp + DM_TMP + RC_L], eax
        add eax, r15d
        mov dword ptr [rsp + DM_TMP + RC_R], eax
        mov eax, dword ptr [rsp + DM_CY]
        add eax, r15d
        mov dword ptr [rsp + DM_TMP + RC_T], eax
        mov eax, dword ptr [rsp + DM_GRID + RC_B]
        mov dword ptr [rsp + DM_TMP + RC_B], eax
        mov rcx, rbx
        lea rdx, [rsp + DM_TMP]
        mov r8d, ACCENT
        mov r9d, 90
        call d_fill_alpha
        mov eax, dword ptr [rsp + DM_CX]        /* ctr = {cx - 1, cyy - 1, cx + cell + 1, cyy + cell + 1} */
        dec eax
        mov dword ptr [rsp + DM_TMP + RC_L], eax
        lea eax, [rax + r15 + 2]
        mov dword ptr [rsp + DM_TMP + RC_R], eax
        mov eax, dword ptr [rsp + DM_CY]
        dec eax
        mov dword ptr [rsp + DM_TMP + RC_T], eax
        lea eax, [rax + r15 + 2]
        mov dword ptr [rsp + DM_TMP + RC_B], eax
        mov rcx, rbx
        lea rdx, [rsp + DM_TMP]
        mov r8d, 1
        mov r9d, 0xFFFFFF
        call d_frame
        mov eax, dword ptr [rsi + VIS_MAG + RC_L]       /* info = {m.l, grid.b + 1, m.r, m.b} */
        mov dword ptr [rsp + DM_INFO + RC_L], eax
        mov eax, dword ptr [rsp + DM_GRID + RC_B]
        inc eax
        mov dword ptr [rsp + DM_INFO + RC_T], eax
        mov eax, dword ptr [rsi + VIS_MAG + RC_R]
        mov dword ptr [rsp + DM_INFO + RC_R], eax
        mov eax, dword ptr [rsi + VIS_MAG + RC_B]
        mov dword ptr [rsp + DM_INFO + RC_B], eax
        RCOPY([rsp+DM_TMP], [rsp+DM_INFO])
        mov rcx, rbx
        lea rdx, [rsp + DM_TMP]
        mov r8d, 0x1E1E1E
        mov r9d, 235
        call d_fill_alpha
        mov edx, dword ptr [rsi + VIS_MAG_PT + PT_X]
        mov r8d, dword ptr [rsi + VIS_MAG_PT + PT_Y]
        call pix_at
        mov dword ptr [rsp + DM_COL], eax
        /* swr = {info.l + pad, info.t + pad + lh + (lh - sw) / 2, ... + sw} */
        mov eax, dword ptr [rip + .Ls18]
        sub eax, dword ptr [rip + .Ls11]
        mov edx, eax
        shr edx, 31
        add eax, edx
        sar eax, 1
        add eax, dword ptr [rsp + DM_INFO + RC_T]
        add eax, dword ptr [rip + .Ls7]
        add eax, dword ptr [rip + .Ls18]
        mov dword ptr [rsp + DM_TMP + RC_T], eax
        add eax, dword ptr [rip + .Ls11]
        mov dword ptr [rsp + DM_TMP + RC_B], eax
        mov eax, dword ptr [rsp + DM_INFO + RC_L]
        add eax, dword ptr [rip + .Ls7]
        mov dword ptr [rsp + DM_TMP + RC_L], eax
        add eax, dword ptr [rip + .Ls11]
        mov dword ptr [rsp + DM_TMP + RC_R], eax
        mov r12d, eax                           /* swr.right */
        mov r13d, dword ptr [rsp + DM_TMP + RC_T]
        mov rcx, rbx
        lea rdx, [rsp + DM_TMP]
        mov r8d, dword ptr [rsp + DM_COL]
        call d_fill
        mov eax, dword ptr [rsp + DM_INFO + RC_L]
        add eax, dword ptr [rip + .Ls7]
        mov dword ptr [rsp + DM_TMP + RC_L], eax
        mov dword ptr [rsp + DM_TMP + RC_R], r12d
        mov dword ptr [rsp + DM_TMP + RC_T], r13d
        add r13d, dword ptr [rip + .Ls11]
        mov dword ptr [rsp + DM_TMP + RC_B], r13d
        mov rcx, rbx
        lea rdx, [rsp + DM_TMP]
        mov r8d, 1
        mov r9d, 0xFFFFFF
        call d_frame
        /* ty = info.t + pad + (lh - S(16)) / 2; text lines at ty and ty + lh */
        mov eax, dword ptr [rip + .Ls18]
        sub eax, dword ptr [rip + .Ls16]
        mov edx, eax
        shr edx, 31
        add eax, edx
        sar eax, 1
        add eax, dword ptr [rsp + DM_INFO + RC_T]
        add eax, dword ptr [rip + .Ls7]
        mov dword ptr [rsp + DM_TY], eax
        /* the text's glyphs stay within [ty, ty + lh + 2 * S(12)): a band farther away
         * than one em (S(12)) gets no pixel of it, so GDI is not asked */
        mov ecx, dword ptr [rip + .Ls12]
        mov edx, eax
        sub edx, ecx
        cmp dword ptr [rsp + DM_B + RC_B], edx
        jle .Ldm_ret
        lea edx, [rcx + rcx*2]
        add edx, eax
        add edx, dword ptr [rip + .Ls18]
        cmp dword ptr [rsp + DM_B + RC_T], edx
        jge .Ldm_ret
        lea r8, [rsp + DM_L1]                   /* L"%d, %d" */
        mov eax, dword ptr [rsi + VIS_MAG_PT + PT_X]
        add eax, dword ptr Ov(OV_SHOT + SHOT_VX)
        call put_int
        mov dword ptr [r8], 0x0020002C
        add r8, 4
        mov eax, dword ptr [rsi + VIS_MAG_PT + PT_Y]
        add eax, dword ptr Ov(OV_SHOT + SHOT_VY)
        call put_int
        mov word ptr [r8], 0
        lea r8, [rsp + DM_L2]
        cmp byte ptr [rsi + VIS_MAG_HEX], 0
        je 5f
        mov word ptr [r8], 0x23                 /* L"#%06X" */
        mov edx, dword ptr [rsp + DM_COL]
        mov ecx, 20
4:      mov eax, edx
        shr eax, cl
        and eax, 15
        lea r9d, [rax + 0x30]
#if OVP_BREAK == 3 /* broken: lowercase hex digits */
        add eax, 0x57
#else
        add eax, 0x37                           /* 'A' - 10 */
#endif
        cmp r9d, 0x39
        cmovbe eax, r9d
        mov word ptr [r8 + 2], ax
        add r8, 2
        sub ecx, 4
        jns 4b
        mov word ptr [r8 + 2], 0
        jmp 6f
5:      mov eax, dword ptr [rsp + DM_COL]       /* L"%d, %d, %d" */
        shr eax, 16
        and eax, 255
        call put_int
        mov dword ptr [r8], 0x0020002C
        add r8, 4
        mov eax, dword ptr [rsp + DM_COL]
        shr eax, 8
        and eax, 255
        call put_int
        mov dword ptr [r8], 0x0020002C
        add r8, 4
        mov eax, dword ptr [rsp + DM_COL]
        and eax, 255
        call put_int
        mov word ptr [r8], 0
6:      lea rcx, [rsp + DM_B]
        mov edx, dword ptr [rsp + DM_INFO + RC_L]
        add edx, dword ptr [rip + .Ls7]
        mov r8d, dword ptr [rsp + DM_TY]
        lea r9, [rsp + DM_L1]
        mov dword ptr [rsp + 32], 0xFFFFFF
        call draw_text_at
        lea rcx, [rsp + DM_B]
        mov edx, r12d
        add edx, dword ptr [rip + .Ls6]
        mov r8d, dword ptr [rsp + DM_TY]
        add r8d, dword ptr [rip + .Ls18]
        lea r9, [rsp + DM_L2]
        mov dword ptr [rsp + 32], 0xFFFFFF
        call draw_text_at
        API GdiFlush
.Ldm_ret:
        add rsp, 360
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

/* void draw_toolbar(const Surf *s, RECT B, const Visual *v): bars, buttons, tooltip */
#define DT_B 48
#define DT_TMP 64
#define DT_HTIP 96
#define DT_PT 100
#define DT_PS 104
#define DT_PC 108
#define DT_ITEMS 112
FUNC draw_toolbar
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG rbp
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 920
        ENDPROLOG
        mov rbx, rcx
        mov rsi, r8
        RCOPY([rsp+DT_B], [rdx])
        JEMPTY(rsi + VIS_TB, .Ldt_ret)
        ST_ENSURE
        mov rcx, rbx
        lea rdx, [rsi + VIS_TB]
        call touches
        mov r12d, eax                           /* hit_tb */
        xor r13d, r13d                          /* hit_pb */
        JEMPTY(rsi + VIS_PB, 1f)
        mov rcx, rbx
        lea rdx, [rsi + VIS_PB]
        call touches
        mov r13d, eax
1:      xor r14d, r14d                          /* hit_tip */
        JEMPTY(rsi + VIS_TIP, 2f)
        mov rcx, rbx
        lea rdx, [rsi + VIS_TIP]
        call touches
        mov r14d, eax
2:      cmp byte ptr Ov(OV_DC), 0               /* composition: the bars and the tooltip apart */
        je 3f
        cmp byte ptr [rip + .Lpass], PASS_TIP
        jne 1f
        mov dword ptr [rsp + DT_HTIP], r14d
        test r14d, r14d
        jz .Ldt_ret
        jmp .Ldt_tip
1:      cmp byte ptr [rip + .Lpass], PASS_BAR
        jne 3f
        xor r14d, r14d
3:      mov dword ptr [rsp + DT_HTIP], r14d
        mov eax, r12d
        or eax, r13d
        or eax, r14d
        jz .Ldt_ret
        test r12d, r12d                         /* the bars */
        jz 3f
        RCOPY([rsp+DT_TMP], [rsi+VIS_TB])
        mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        mov r8d, 0xF7F7F7
        call d_fill
        RCOPY([rsp+DT_TMP], [rsi+VIS_TB])
        mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        mov r8d, 1
        mov r9d, 0xBDBDBD
        call d_frame
3:      test r13d, r13d
        jz 4f
        RCOPY([rsp+DT_TMP], [rsi+VIS_PB])
        mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        mov r8d, 0xF7F7F7
        call d_fill
        RCOPY([rsp+DT_TMP], [rsi+VIS_PB])
        mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        mov r8d, 1
        mov r9d, 0xBDBDBD
        call d_frame
4:      mov r14d, dword ptr [rip + .Ls30]       /* bs */
        mov edi, dword ptr [rsi + VIS_TB + RC_L]        /* separators */
        add edi, dword ptr [rip + .Ls4]         /* x */
        xor ebp, ebp
5:      lea rax, [rip + kTbOrder]
        cmp dword ptr [rax + rbp*4], 0
        jge 7f
        mov eax, dword ptr [rip + .Ls9]
        shr eax, 1
        add eax, edi
        mov dword ptr [rsp + DT_TMP + RC_L], eax
        inc eax
        mov dword ptr [rsp + DT_TMP + RC_R], eax
        mov eax, dword ptr [rsi + VIS_TB + RC_T]
        add eax, dword ptr [rip + .Ls4]
        add eax, dword ptr [rip + .Ls6]
        mov dword ptr [rsp + DT_TMP + RC_T], eax
        mov eax, dword ptr [rsi + VIS_TB + RC_B]
        sub eax, dword ptr [rip + .Ls4]
        sub eax, dword ptr [rip + .Ls6]
        mov dword ptr [rsp + DT_TMP + RC_B], eax
        mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        call touches
        test eax, eax
        jz 6f
        mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        mov r8d, 0xD0D0D0
        call d_fill
6:      add edi, dword ptr [rip + .Ls9]
        jmp 8f
7:      add edi, r14d
8:      inc ebp
        cmp ebp, 17
        jb 5b
        call prop_tool_
        mov dword ptr [rsp + DT_PT], eax
        call prop_size_idx
        mov dword ptr [rsp + DT_PS], eax
        call prop_color_idx
        mov dword ptr [rsp + DT_PC], eax
        JEMPTY(rsi + VIS_PB, 9f)                /* the property bar's separator */
        cmp dword ptr [rsp + DT_PT], T_MOSAIC
        je 9f
        mov eax, dword ptr [rsi + VIS_PB + RC_L]
        add eax, dword ptr [rip + .Ls4]
        lea ecx, [r14 + r14*2]
        add eax, ecx                            /* sx */
        mov ecx, dword ptr [rip + .Ls9]
        shr ecx, 1
        add eax, ecx
        mov dword ptr [rsp + DT_TMP + RC_L], eax
        inc eax
        mov dword ptr [rsp + DT_TMP + RC_R], eax
        mov eax, dword ptr [rsi + VIS_PB + RC_T]
        add eax, dword ptr [rip + .Ls4]
        add eax, dword ptr [rip + .Ls6]
        mov dword ptr [rsp + DT_TMP + RC_T], eax
        mov eax, dword ptr [rsi + VIS_PB + RC_B]
        sub eax, dword ptr [rip + .Ls4]
        sub eax, dword ptr [rip + .Ls6]
        mov dword ptr [rsp + DT_TMP + RC_B], eax
        mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        call touches
        test eax, eax
        jz 9f
        mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        mov r8d, 0xD0D0D0
        call d_fill
9:      mov rcx, rsi
        lea rdx, [rsp + DT_ITEMS]
        call tb_items
        mov r15d, eax                           /* items left */
        lea rdi, [rsp + DT_ITEMS]
.Ldt_item:
        test r15d, r15d
        jle .Ldt_tip
        mov rcx, rbx
        lea rdx, [rdi + ITEM_RC]
        call touches
        test eax, eax
        jz .Ldt_next
        mov ebp, dword ptr [rdi + ITEM_ID]      /* id */
        xor r12d, r12d                          /* active */
        lea eax, [rbp - T_RECT]
        cmp eax, T_NUMBER - T_RECT
        ja 1f
        cmp ebp, dword ptr Ov(OV_TOOL)
        jne 1f
        mov r12d, 1
1:      mov eax, dword ptr [rsp + DT_PS]
        add eax, B_SIZE
        cmp ebp, eax
        jne 2f
        mov r12d, 1
2:      xor r13d, r13d                          /* disabled */
        cmp ebp, B_UNDO
        jne 3f
        cmp dword ptr Ov(OV_NOPS), 0
        jne 3f
        mov r13d, 1
3:      cmp ebp, B_REDO
        jne 4f
        mov eax, dword ptr Ov(OV_NOPS)
        cmp eax, dword ptr Ov(OV_NOPS_ALL)
        jl 4f
        mov r13d, 1
4:      lea rcx, [rsp + DT_TMP]                 /* in = rect_inflate(r, -S(2)) */
        lea rdx, [rdi + ITEM_RC]
        mov r8d, dword ptr [rip + .Ls2]
        neg r8d
        call ovp_inflate
        mov r8d, 0xCCE4F7
        test r12d, r12d
        jnz 5f
        test r13d, r13d
        jnz 6f
        cmp ebp, dword ptr Ov(OV_HOVER)
        jne 6f
        mov r8d, 0xE5E5E5
        cmp dword ptr Ov(OV_DRAG), DR_BUTTON
        jne 5f
        cmp ebp, dword ptr Ov(OV_BTN_DOWN)
        jne 5f
        mov r8d, 0xD4D4D4
5:      mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        call d_fill
6:      mov eax, r14d                           /* ix = r.left + (bs - isz) * 0.5f, iy alike */
        sub eax, dword ptr [rip + .Ls18]
        xorps xmm0, xmm0
        cvtsi2ss xmm0, eax
        mulss xmm0, dword ptr [rip + .Lf_half]
        xorps xmm2, xmm2
        cvtsi2ss xmm2, dword ptr [rdi + ITEM_RC + RC_L]
        addss xmm2, xmm0
        xorps xmm3, xmm3
        cvtsi2ss xmm3, dword ptr [rdi + ITEM_RC + RC_T]
        addss xmm3, xmm0
        mov eax, 0x333333                       /* ic = disabled ? B4 : active ? 005FB8 : 333 */
        mov ecx, 0x005FB8
        test r12d, r12d
        cmovnz eax, ecx
        mov ecx, 0xB4B4B4
        test r13d, r13d
        cmovnz eax, ecx
        lea ecx, [rbp - T_RECT]
        cmp ecx, T_NUMBER - T_RECT
        ja 7f
        lea edx, [rcx + DIC_RECT]                /* a tool */
        jmp 8f
7:      lea ecx, [rbp - B_UNDO]
        cmp ecx, B_OK - B_UNDO
        ja 9f
        cmp ebp, B_OK                           /* a command */
        jne 10f
        test r13d, r13d
        jnz 10f
        mov eax, 0x107C10
10:     lea edx, [rcx + DIC_UNDO]
8:      mov dword ptr [rsp + 40], eax
        xorps xmm0, xmm0
        cvtsi2ss xmm0, dword ptr [rip + .Ls18]
        movss dword ptr [rsp + 32], xmm0
        mov rcx, rbx
        call d_icon
        jmp .Ldt_next
9:      lea ecx, [rbp - B_SIZE]
        cmp ecx, 2
        ja 11f
        mov eax, 0x333333                       /* a size: a disc in the color */
        cmp dword ptr [rsp + DT_PT], T_MOSAIC
        je 12f
        mov edx, dword ptr [rsp + DT_PC]
        test edx, edx
        js 13f
        lea rax, [rip + kColors]
        mov eax, dword ptr [rax + rdx*4]
        jmp 12f
13:     xor eax, eax                            /* not a palette color: the pick's own */
        movsxd rdx, dword ptr Ov(OV_PICK)
        test edx, edx
        js 12f
        imul rdx, rdx, AN_BYTES
        add rdx, qword ptr Ov(OV_ANN)
        mov eax, dword ptr [rdx + AN_COLOR]
12:     cmp eax, 0xFFFFFF
        jne 14f
        mov eax, 0x9E9E9E
14:     mov dword ptr [rsp + 32], eax
        mov dword ptr [rsp + 40], 255
        mov edx, dword ptr [rdi + ITEM_RC + RC_L]
        add edx, dword ptr [rdi + ITEM_RC + RC_R]
        xorps xmm1, xmm1
        cvtsi2ss xmm1, edx
        mulss xmm1, dword ptr [rip + .Lf_half]
        mov edx, dword ptr [rdi + ITEM_RC + RC_T]
        add edx, dword ptr [rdi + ITEM_RC + RC_B]
        xorps xmm2, xmm2
        cvtsi2ss xmm2, edx
        mulss xmm2, dword ptr [rip + .Lf_half]
        lea rdx, [rip + .Lrad]
        movss xmm3, dword ptr [rdx + rcx*4]
        mov rcx, rbx
        call d_disc
        jmp .Ldt_next
11:     lea ecx, [rbp - B_COLOR]
        cmp ecx, 7
        ja .Ldt_next
        mov r12d, ecx                           /* a color swatch */
        cmp ecx, dword ptr [rsp + DT_PC]
        jne 15f
        lea rcx, [rsp + DT_TMP]
        lea rdx, [rdi + ITEM_RC]
        mov r8d, dword ptr [rip + .Ls3]
        neg r8d
        call ovp_inflate
        mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        mov r8d, dword ptr [rip + .Ls2]
        mov r9d, 0x005FB8
        call d_frame
15:     lea rcx, [rsp + DT_TMP]
        lea rdx, [rdi + ITEM_RC]
        mov r8d, dword ptr [rip + .Ls7]
        neg r8d
        call ovp_inflate
        lea rax, [rip + kColors]
        mov r8d, dword ptr [rax + r12*4]
        mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        call d_fill
        lea rcx, [rsp + DT_TMP]
        lea rdx, [rdi + ITEM_RC]
        mov r8d, dword ptr [rip + .Ls7]
        neg r8d
        call ovp_inflate
        mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        mov r8d, 1
        mov r9d, 0x8A8A8A
        call d_frame
.Ldt_next:
        add rdi, ITEM_BYTES
        dec r15d
        jmp .Ldt_item
.Ldt_tip:
        cmp dword ptr [rsp + DT_HTIP], 0
        je .Ldt_ret
        RCOPY([rsp+DT_TMP], [rsi+VIS_TIP])
        mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        mov r8d, 0xFFFFFF
        call d_fill
        RCOPY([rsp+DT_TMP], [rsi+VIS_TIP])
        mov rcx, rbx
        lea rdx, [rsp + DT_TMP]
        mov r8d, 1
        mov r9d, 0x8C8C8C
        call d_frame
        mov ecx, dword ptr Ov(OV_TIP)
        call tip_text
        mov r8, rax
        lea rcx, [rsp + DT_B]
        lea rdx, [rsi + VIS_TIP]
        mov r9d, 0x1F1F1F
        call draw_text_in
        API GdiFlush
.Ldt_ret:
        add rsp, 920
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

/* void paint_band(HDC hdc, RECT B): paint B (at most BAND_H rows) through the band
 * buffer: blitted to hdc, or uploaded to the composition layer */
FUNC paint_band
        ENDPROLOG
        mov r8d, dword ptr Ov(OV_BAND + IMG_W)
        jmp paint_rect
ENDF

/* paint_rect(hdc, &B, stride): paint_band with the band buffer used at a given row
 * stride: the band's width (BAND_H rows at most; blitted from the band DC), or the
 * rect's own (more rows for a narrow rect that draws no GDI text, see on_paint;
 * sent with SetDIBitsToDevice). */
#define PB_B 96
#define PB_S 112
#define PB_SC 160
#define PB_SRC 208
#define PB_TMP 256
#define PB_TMP2 272
#define PB_C 288
#define PB_LH 296
#define PB_CS 304
#define PB_BMI 320
SFUNC paint_rect
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 368                               /* [rsp + 32..96): up to 12 call arguments */
        ENDPROLOG
        mov r12, rcx                            /* hdc */
        mov r13d, r8d                           /* stride */
        RCOPY([rsp+PB_B], [rdx])
        ST_ENSURE
        mov rax, qword ptr Ov(OV_BAND + IMG_PX) /* s = {band.px, stride, B.left, B.top, B} */
        mov qword ptr [rsp + PB_S + SURF_PX], rax
        mov dword ptr [rsp + PB_S + SURF_STRIDE], r13d
        mov eax, dword ptr [rsp + PB_B + RC_L]
        mov dword ptr [rsp + PB_S + SURF_OX], eax
        mov eax, dword ptr [rsp + PB_B + RC_T]
        mov dword ptr [rsp + PB_S + SURF_OY], eax
        RCOPY([rsp+PB_S+SURF_CL], [rsp+PB_B])
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        mov edx, dword ptr [rsp + PB_B + RC_L]
        neg edx
        mov r8d, dword ptr [rsp + PB_B + RC_T]
        neg r8d
        xor r9d, r9d
        API SetViewportOrgEx
        mov r14d, D_GDI                         /* what this band draws */
        cmp byte ptr Ov(OV_DC), 0
        je 1f
        movzx eax, byte ptr [rip + .Lpass]
        lea rcx, [rip + .Lpass_bits]
        movzx r14d, byte ptr [rcx + rax]
1:      lea rcx, [rsp + PB_S]
        lea rdx, [rsp + PB_B]
        call compose_base
        cmp dword ptr Ov(OV_PHASE), PH_EDIT
        jne .Lpb_deco
        test r14d, D_ANNOS
        jz .Lpb_deco
        lea rcx, [rsp + PB_CS]
        lea rdx, [rsp + PB_B]
        lea r8, Ov(OV_SEL)
        call ovp_isect
        JEMPTY(rsp + PB_CS, .Lpb_deco)
        cmp byte ptr Ov(OV_HAS_ACT), 0
        jne 1f
        cmp byte ptr Ov(OV_TE_ON), 0
        jne 1f
        cmp dword ptr Ov(OV_PICK), 0
        jl .Lpb_deco
1:      RCOPY([rsp+PB_SC], [rsp+PB_S])          /* sc = s, clipped to the selection */
        RCOPY([rsp+PB_SC+16], [rsp+PB_S+16])
        mov rax, qword ptr [rsp + PB_S + 32]
        mov qword ptr [rsp + PB_SC + 32], rax
        RCOPY([rsp+PB_SC+SURF_CL], [rsp+PB_CS])
        lea rcx, [rsp + PB_CS]
        call band_clip
        xorps xmm0, xmm0                        /* src: what a mosaic pixelates */
        movdqu xmmword ptr [rsp + PB_SRC], xmm0
        movdqu xmmword ptr [rsp + PB_SRC + 16], xmm0
        mov qword ptr [rsp + PB_SRC + 32], 0
        cmp byte ptr Ov(OV_CANVAS_OK), 0
        je 2f
        lea rcx, [rsp + PB_SRC]
        call canvas_surf
2:      mov esi, dword ptr Ov(OV_PICK)          /* the pick and everything above it */
        test esi, esi
        jns 3f
        mov esi, dword ptr Ov(OV_NANN)
3:      cmp esi, dword ptr Ov(OV_NANN)
        jge 5f
        cmp esi, dword ptr Ov(OV_PICK)
        jne 4f
        lea eax, [rsi + 1]
        cmp eax, dword ptr Ov(OV_TE_EDIT1)      /* the editor shows the text being edited */
        je 6f
4:      movsxd rdi, esi
        imul rdi, rdi, AN_BYTES
        add rdi, qword ptr Ov(OV_ANN)
        lea rcx, [rsp + PB_TMP]
        mov rdx, rdi
        call anno_bounds
        lea rcx, [rsp + PB_SC]
        lea rdx, [rsp + PB_TMP]
        call touches
        test eax, eax
        jz 6f
        mov rcx, rdi
        lea rdx, [rsp + PB_SC]
        mov r8, qword ptr Ov(OV_BAND + IMG_DC)
        lea r9, [rsp + PB_SRC]
        call anno_render
6:      inc esi
        jmp 3b
5:      cmp byte ptr Ov(OV_HAS_ACT), 0
        je 7f
        lea rcx, Ov(OV_ACT)
        lea rdx, [rsp + PB_SC]
        mov r8, qword ptr Ov(OV_BAND + IMG_DC)
        lea r9, [rsp + PB_SRC]
        call anno_render
7:      cmp byte ptr Ov(OV_TE_ON), 0
        je .Lpb_deco
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        mov rdx, qword ptr Ov(OV_TE_BUF)
        mov r8d, dword ptr Ov(OV_TE_LEN)
        mov r9, qword ptr Ov(OV_TE_POS)
        mov eax, dword ptr Ov(OV_TE_PX)
        mov dword ptr [rsp + 32], eax
        mov eax, dword ptr Ov(OV_TE_COLOR)
        mov dword ptr [rsp + 40], eax
        call text_draw
        API GdiFlush
        lea rcx, [rsp + PB_TMP]
        mov rdx, qword ptr Ov(OV_TE_BUF)
        mov r8d, dword ptr Ov(OV_TE_LEN)
        mov r9, qword ptr Ov(OV_TE_POS)
        mov eax, dword ptr Ov(OV_TE_PX)
        mov dword ptr [rsp + 32], eax
        lea rax, [rsp + PB_C]
        mov qword ptr [rsp + 40], rax
        lea rax, [rsp + PB_LH]
        mov qword ptr [rsp + 48], rax
        call text_box
        lea rcx, [rsp + PB_TMP]
        mov rdx, rcx
        mov r8d, dword ptr [rip + .Ls4]
        call ovp_inflate
        lea rcx, [rsp + PB_SC]
        lea rdx, [rsp + PB_TMP]
        xor r8d, r8d
        mov r9d, 0xFFFFFF
        mov eax, dword ptr [rip + .Ls3]
        mov dword ptr [rsp + 32], eax
        call d_dash_frame
        cmp byte ptr Ov(OV_DC), 0               /* the system caret is not composed: draw it */
        je .Lpb_deco
        cmp byte ptr Ov(OV_TE_CARET_OFF), 0
        jne .Lpb_deco
        lea rcx, [rsp + PB_TMP2]
        call caret_rect
        lea rcx, [rsp + PB_SC]
        lea rdx, [rsp + PB_TMP2]
        mov r8d, dword ptr Ov(OV_TE_COLOR)
        call d_fill
.Lpb_deco:
        test r14d, D_FRAME
        jz 1f
        lea rcx, [rsp + PB_S]
        lea rdx, Ov(OV_VIS)
        call draw_frame
1:      test r14d, D_PICK
        jz 2f
        cmp dword ptr Ov(OV_PHASE), PH_EDIT
        jne 2f
        lea rcx, [rsp + PB_S]
        call draw_pick
2:      test r14d, D_LABEL
        jz 3f
        lea rcx, [rsp + PB_S]
        lea rdx, [rsp + PB_B]
        lea r8, Ov(OV_VIS)
        call draw_label
3:      test r14d, D_PANEL
        jz 5f
        lea rcx, [rsp + PB_S]
        lea rdx, [rsp + PB_B]
        lea r8, Ov(OV_VIS)
        cmp dword ptr Ov(OV_PHASE), PH_SELECT
        jne 4f
        call draw_magnifier
        jmp 5f
4:      call draw_toolbar
5:      test r14d, D_HANDLE                     /* the selection handle, as draw_frame draws it */
        jz 6f
        RCOPY([rsp+PB_TMP], [rsp+PB_B])
        lea rcx, [rsp + PB_S]
        lea rdx, [rsp + PB_TMP]
        mov r8d, ACCENT
        call d_fill
        RCOPY([rsp+PB_TMP], [rsp+PB_B])
        lea rcx, [rsp + PB_S]
        lea rdx, [rsp + PB_TMP]
        mov r8d, 1
        mov r9d, 0xFFFFFF
        call d_frame
        /* GDI drew here only after band_clip (texts, text and number annotations): only
         * then is there anything to flush, and a clip to reset afterwards */
6:      cmp byte ptr [rip + .Lclipped], 0
        je 8f
        API GdiFlush
8:      test r14d, D_FIX_UI                     /* opaque by construction: the canvas, the live parts */
        jz 9f
        cmp byte ptr Ov(OV_CANVAS_OK), 0
        je 10f
        RCOPY([rsp+PB_TMP], Ov(OV_CRECT))
        lea rcx, [rsp + PB_S]
        lea rdx, [rsp + PB_TMP]
        call alpha_fix
10:     lea rcx, [rsp + PB_TMP]
        lea rdx, Ov(OV_VIS + VIS_ACT)
        lea r8, Ov(OV_SEL)
        call ovp_isect
        lea rcx, [rsp + PB_S]
        lea rdx, [rsp + PB_TMP]
        call alpha_fix
9:      test r14d, D_FIX_ALL                    /* the label, the magnifier, the bars */
        jz 4f
        RCOPY([rsp+PB_TMP], [rsp+PB_B])
        lea rcx, [rsp + PB_S]
        lea rdx, [rsp + PB_TMP]
        call alpha_fix
4:      mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        xor edx, edx
        xor r8d, r8d
        xor r9d, r9d
        API SetViewportOrgEx
        cmp byte ptr [rip + .Lclipped], 0
        je 9f
        mov byte ptr [rip + .Lclipped], 0
        mov rcx, qword ptr Ov(OV_BAND + IMG_DC)
        xor edx, edx
        API SelectClipRgn
9:      cmp byte ptr Ov(OV_DC), 0
        je 6f
        RCOPY([rsp+PB_TMP], [rsp+PB_B])
        lea rcx, [rsp + PB_TMP]
        mov rdx, qword ptr Ov(OV_BAND + IMG_PX)
        mov r8d, r13d
        call pr_ui_rows
        jmp 7f
6:      cmp r13d, dword ptr Ov(OV_BAND + IMG_W)
        je 10f
        xorps xmm0, xmm0                        /* a top-down 32bpp DIB, stride = width */
        movdqu xmmword ptr [rsp + PB_BMI], xmm0
        movdqu xmmword ptr [rsp + PB_BMI + 16], xmm0
        movdqu xmmword ptr [rsp + PB_BMI + 28], xmm0
        mov dword ptr [rsp + PB_BMI + W_BIH_SIZE], W_SIZEOF_BIH
        mov dword ptr [rsp + PB_BMI + W_BIH_WIDTH], r13d
        mov eax, dword ptr [rsp + PB_B + RC_B]
        sub eax, dword ptr [rsp + PB_B + RC_T]
        mov dword ptr [rsp + 32], eax           /* h */
        mov dword ptr [rsp + 64], eax           /* lines */
        neg eax
        mov dword ptr [rsp + PB_BMI + W_BIH_HEIGHT], eax
        mov word ptr [rsp + PB_BMI + W_BIH_PLANES], 1
        mov word ptr [rsp + PB_BMI + W_BIH_BITCOUNT], 32
        mov rcx, r12
        mov edx, dword ptr [rsp + PB_B + RC_L]
        mov r8d, dword ptr [rsp + PB_B + RC_T]
        mov r9d, r13d
        mov qword ptr [rsp + 40], 0             /* xSrc, ySrc, first line */
        mov qword ptr [rsp + 48], 0
        mov qword ptr [rsp + 56], 0
        mov rax, qword ptr Ov(OV_BAND + IMG_PX)
        mov qword ptr [rsp + 72], rax
        lea rax, [rsp + PB_BMI]
        mov qword ptr [rsp + 80], rax
        mov qword ptr [rsp + 88], W_DIB_RGB_COLORS
        API SetDIBitsToDevice
        jmp 7f
10:     mov rcx, r12
        mov edx, dword ptr [rsp + PB_B + RC_L]
        mov r8d, dword ptr [rsp + PB_B + RC_T]
        mov r9d, dword ptr [rsp + PB_B + RC_R]
        sub r9d, edx
        mov eax, dword ptr [rsp + PB_B + RC_B]
        sub eax, r8d
        mov dword ptr [rsp + 32], eax
        mov rax, qword ptr Ov(OV_BAND + IMG_DC)
        mov qword ptr [rsp + 40], rax
        mov qword ptr [rsp + 48], 0
        mov qword ptr [rsp + 56], 0
        mov dword ptr [rsp + 64], W_SRCCOPY
        API BitBlt
7:      add rsp, 368
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* eax = rows per band for painting [rcx] at stride = its width, or 0 to paint it in
 * BAND_H bands: only for a rect taller than that, narrow enough to get more rows
 * from the band buffer, and where nothing draws with GDI (texts: the label, the
 * magnifier, the tooltip; the live annotations, which may be text, inside the
 * selection), since GDI draws into the band DC at the band's own stride. Leaf. */
SFUNC tall_rows
        ENDPROLOG
        mov eax, dword ptr [rcx + RC_B]
        sub eax, dword ptr [rcx + RC_T]
        cmp eax, BAND_H
        jle 9f
        mov r8d, dword ptr [rcx + RC_R]
        sub r8d, dword ptr [rcx + RC_L]
        jle 9f
        mov eax, dword ptr Ov(OV_BAND + IMG_W)
        imul eax, dword ptr Ov(OV_BAND + IMG_H)
        xor edx, edx
        div r8d
        cmp eax, BAND_H
        jle 9f
        mov r9d, eax                            /* rows */
        lea r10, Ov(OV_VIS)
        cmp dword ptr Ov(OV_PHASE), PH_EDIT
        jne 2f
        cmp byte ptr Ov(OV_HAS_ACT), 0
        jne 1f
        cmp byte ptr Ov(OV_TE_ON), 0
        jne 1f
        cmp dword ptr Ov(OV_PICK), 0
        jl 2f
1:      lea r11, Ov(OV_SEL)
        OVERLAP rcx, r11, 2f
        jmp 9f
2:      lea r11, [r10 + VIS_LABEL]
        OVERLAP rcx, r11, 3f
        jmp 9f
3:      lea r11, [r10 + VIS_TIP]                /* draw_toolbar's text */
        cmp dword ptr Ov(OV_PHASE), PH_SELECT
        jne 4f
        lea r11, [r10 + VIS_MAG]                /* draw_magnifier's */
4:      OVERLAP rcx, r11, 5f
        jmp 9f
5:      mov eax, r9d
        ret
9:      xor eax, eax
        ret
ENDF

/* on_paint, composition mode, after the UI layer's rect at rcx: the top layer there,
 * where it holds or held handles (rdx: that area), and the panels over it drawn again */
SFUNC op_extra
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 56                                /* [rsp + 32]: RECT */
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        lea rcx, [rsp + 32]
        mov rdx, rbx
        lea r8, Ov(OV_VIS + VIS_LABEL)
        call ovp_isect
        JEMPTY(rsp + 32, 1f)
        mov byte ptr [rip + .Lsh + SH_DIRTY], 1
1:      lea rcx, [rsp + 32]
        mov rdx, rbx
        lea r8, Ov(OV_VIS + VIS_MAG)
        call ovp_isect
        JEMPTY(rsp + 32, 2f)
        mov byte ptr [rip + .Lsh + SH_DIRTY + 1], 1
2:      lea rcx, [rsp + 32]
        mov rdx, rbx
        mov r8, rsi
        call ovp_isect
        JEMPTY(rsp + 32, 9f)
        mov ecx, PR_TOP
        lea rdx, [rsp + 32]
        lea r8, [rsp + 32]
        mov r9d, PASS_TOP
        call paint_part
9:      add rsp, 56
        pop rsi
        pop rbx
        ret
ENDF

/* void on_paint(HWND hwnd): WM_PAINT, each rectangle of the update region in bands */
#define OP_ONE 32
#define OP_CL 48
#define OP_R 64
#define OP_BAND 80
#define OP_TMP 96
#define OP_PS 112
#define OP_RGN 192
#define OP_L2 2272                              /* the top layer's area to paint */
#define OP_A 2288
FUNC on_paint
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 2304                              /* [rsp + OP_RGN]: RGNDATA for 128 rects */
        ENDPROLOG
        mov rbx, rcx
        xor ecx, ecx
        xor edx, edx
        xor r8d, r8d
        xor r9d, r9d
        API CreateRectRgn
        mov rsi, rax                            /* rgn */
        mov rcx, rbx
        mov rdx, rsi
        xor r8d, r8d
        API GetUpdateRgn
        mov edi, eax                            /* kind */
        mov rcx, rbx
        lea rdx, [rsp + OP_PS]
        API BeginPaint
        mov r12, rax                            /* hdc */
        cmp byte ptr Ov(OV_ACTIVE), 0
        je .Lop_end
        cmp qword ptr Ov(OV_BAND + IMG_PX), 0
        je .Lop_end
        RCOPY([rsp+OP_ONE], [rsp+OP_PS+PS_RCPAINT])
        lea r13, [rsp + OP_ONE]                 /* rects */
        mov r14d, 1                             /* n */
        cmp byte ptr Ov(OV_DC), 0
        je 1f
        cmp edi, W_SIMPLEREGION
        je 2f
        cmp edi, W_COMPLEXREGION
        jne 1f
2:      mov rcx, rsi                            /* with a caret, BeginPaint reports an empty rcPaint */
        lea rdx, [rsp + OP_ONE]
        API GetRgnBox
1:      cmp edi, W_COMPLEXREGION
        jne 3f
        mov rcx, rsi                            /* more than 128 rects: the bounding box */
        mov edx, RGN_BUFBYTES
        lea r8, [rsp + OP_RGN]
        API GetRegionData
        test eax, eax
        jz 3f
        cmp eax, RGN_BUFBYTES
        ja 3f
        mov eax, dword ptr [rsp + OP_RGN + RGN_NCOUNT]
        cmp eax, RGN_MAXRECTS
        ja 3f
        lea r13, [rsp + OP_RGN + RGN_BUFFER]
        mov r14d, eax
        /* The region comes in y bands: a tall strip is cut wherever another rect
         * starts or ends beside it. Join such pieces again (same left and right, one
         * starting where the other ends): the same area in fewer, taller rects, so
         * fewer bands and fewer composition-surface updates. */
        xor ecx, ecx                            /* i */
10:     cmp ecx, r14d
        jge 3f
        mov eax, ecx
        shl rax, 4
        lea r8, [r13 + rax]                     /* rects[i] */
        lea edx, [rcx + 1]                      /* j */
11:     cmp edx, r14d
        jge 14f
        mov eax, edx
        shl rax, 4
        lea r9, [r13 + rax]                     /* rects[j] */
        mov eax, dword ptr [r9 + RC_T]
        cmp eax, dword ptr [r8 + RC_B]
        jg 14f                                  /* sorted by top: no later rect can follow on */
        jne 13f
        mov eax, dword ptr [r9 + RC_L]
        cmp eax, dword ptr [r8 + RC_L]
        jne 13f
        mov eax, dword ptr [r9 + RC_R]
        cmp eax, dword ptr [r8 + RC_R]
        jne 13f
        mov eax, dword ptr [r9 + RC_B]          /* rects[i] grows down over rects[j] */
        mov dword ptr [r8 + RC_B], eax
        dec r14d                                /* rects[j] goes: the rest moves up */
        mov r10d, edx
12:     cmp r10d, r14d
        jge 11b
        movdqu xmm0, xmmword ptr [r9 + 16]
        movdqu xmmword ptr [r9], xmm0
        add r9, 16
        inc r10d
        jmp 12b
13:     inc edx
        jmp 11b
14:     inc ecx
        jmp 10b
3:      mov qword ptr [rsp + OP_CL], 0          /* client rect */
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VW)
        mov dword ptr [rsp + OP_CL + RC_R], eax
        mov eax, dword ptr Ov(OV_SHOT + SHOT_VH)
        mov dword ptr [rsp + OP_CL + RC_B], eax
        cmp byte ptr Ov(OV_DC), 0
        je .Lop_rect
        call sh_check                           /* composition: the top layer where it has or had handles */
        lea rcx, [rsp + OP_A]
        lea rdx, [rsp + OP_L2]
        call live_area
        lea rcx, [rsp + OP_L2]
        mov rdx, rcx
        lea r8, [rip + .Lsh + SH_PEND]
        call ovp_union
#if OVP_BREAK != 6 /* broken: handles unpicked without a refresh stay on the top layer */
        lea rcx, [rsp + OP_L2]                  /* and where refresh last saw them: unpicked */
        mov rdx, rcx                            /* without a refresh (finish, then the save */
        lea r8, [rip + .Lsh + SH_PD]            /* dialog cancelled), they go now */
        call ovp_union
#endif
.Lop_rect:
        test r14d, r14d
        jle .Lop_commit
        lea rcx, [rsp + OP_R]
        mov rdx, r13
        lea r8, [rsp + OP_CL]
        call ovp_isect
        cmp byte ptr Ov(OV_DC), 0
        je 4f
        cmp dword ptr Ov(OV_PHASE), PH_SELECT   /* selecting, the UI layer may be known empty */
        jne 20f
        cmp byte ptr [rip + .Lsh + SH_L1CLEAN], 0
        jne .Lop_extra
        jmp 21f
20:     mov byte ptr [rip + .Lsh + SH_L1CLEAN], 0
21:     RCOPY([rsp+OP_TMP], [rsp+OP_R])
        lea rcx, [rsp + OP_TMP]
        call pr_ui_begin
        test al, al
        jz .Lop_extra
4:      lea rcx, [rsp + OP_R]                   /* tall and narrow, no GDI text: fewer, taller bands */
        call tall_rows
        test eax, eax
        jnz .Lop_tall
        mov r15d, dword ptr [rsp + OP_R + RC_T]
5:      cmp r15d, dword ptr [rsp + OP_R + RC_B]
        jge 6f
        mov eax, dword ptr [rsp + OP_R + RC_L]
        mov dword ptr [rsp + OP_BAND + RC_L], eax
        mov dword ptr [rsp + OP_BAND + RC_T], r15d
        mov eax, dword ptr [rsp + OP_R + RC_R]
        mov dword ptr [rsp + OP_BAND + RC_R], eax
        lea eax, [r15 + BAND_H]
        cmp eax, dword ptr [rsp + OP_R + RC_B]
        cmovg eax, dword ptr [rsp + OP_R + RC_B]
        mov dword ptr [rsp + OP_BAND + RC_B], eax
        mov rcx, r12
        lea rdx, [rsp + OP_BAND]
        call paint_band
        add r15d, BAND_H
        jmp 5b
6:      cmp byte ptr Ov(OV_DC), 0
        je .Lop_next
        call pr_ui_end
.Lop_extra:
        lea rcx, [rsp + OP_R]
        lea rdx, [rsp + OP_L2]
        call op_extra
        jmp .Lop_next
.Lop_tall:                                      /* eax rows per band, at stride = the rect's width */
        mov dword ptr [rsp + OP_TMP], eax
        mov r15d, dword ptr [rsp + OP_R + RC_T]
7:      cmp r15d, dword ptr [rsp + OP_R + RC_B]
        jge 6b
        mov eax, dword ptr [rsp + OP_R + RC_L]
        mov dword ptr [rsp + OP_BAND + RC_L], eax
        mov dword ptr [rsp + OP_BAND + RC_T], r15d
        mov eax, dword ptr [rsp + OP_R + RC_R]
        mov dword ptr [rsp + OP_BAND + RC_R], eax
        mov eax, r15d
        add eax, dword ptr [rsp + OP_TMP]
        cmp eax, dword ptr [rsp + OP_R + RC_B]
        cmovg eax, dword ptr [rsp + OP_R + RC_B]
        mov dword ptr [rsp + OP_BAND + RC_B], eax
        mov rcx, r12
        lea rdx, [rsp + OP_BAND]
        mov r8d, dword ptr [rsp + OP_R + RC_R]
        sub r8d, dword ptr [rsp + OP_R + RC_L]
        call paint_rect
        add r15d, dword ptr [rsp + OP_TMP]
        jmp 7b
.Lop_next:
        add r13, 16
        dec r14d
        jmp .Lop_rect
.Lop_commit:
        cmp byte ptr Ov(OV_DC), 0
        je .Lop_end
        xorps xmm0, xmm0                        /* the old handles are cleared */
        movups xmmword ptr [rip + .Lsh + SH_PEND], xmm0
        call ovp_sync
        mov byte ptr [rip + .Lsent], 0
        call pr_commit
.Lop_end:
        mov rcx, rbx
        lea rdx, [rsp + OP_PS]
        API EndPaint
        mov rcx, rsi
        API DeleteObject
        add rsp, 2304
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

#ifdef OV_PAINT_TEST
/* the file-local functions, for tracing in tests */
        .section .rdata$ov_paint_test,"dr"
        .balign 8
        .globl ovp_locals
ovp_locals:
        .quad scale_tab, ovp_cpu, ovp_isect, ovp_union, ovp_inflate, inv_rect, px_copy, px_dim, px_zero
        .quad px_alpha, pix_at, put_int, tip_text, prop_tool_, tx_check, ring4, rect_sub, covered
        .quad item_look, compose_pass, paint_rect, tall_rows, zero_rect, same16, sh_check, live_area
        .quad live_x, frame_rects, handle_pos, paint_part, ovp_sync, refresh_dc, op_extra, 0
#endif
