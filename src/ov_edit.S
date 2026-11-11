/* ov_edit.S: the overlay's editing part in x86-64 assembly (replaces ov_edit.c):
 * the annotation list and its undo history, picking, hit testing, the text tool,
 * restyling and nudging. Same symbols, signatures and observable behaviour as the
 * C (src/ov_int.h, group "ov_edit.c"); tests/ov_edit_diff.c compares the two.
 *
 * Faster than the C by construction, not only by instructions:
 * - hit testing (every mouse move) inlines S(), rect_corners and rect_inflate,
 *   computes the scaled tolerances once per anno_at instead of per annotation,
 *   and drops anno_bounds where the shape test already implies it (all tools
 *   but the ellipse; for text that saves a whole measuring pass through GDI),
 *   and does not measure a text at all for a point left of or above it.
 *   Pen strokes skip a segment by four integer compares when its box is farther
 *   than the tolerance (plus a margin far above float rounding), so only the
 *   few nearby segments compute the exact float distance;
 * - the distance itself runs on (x, y) pairs in one register, operation for
 *   operation the C expression, so results are bit-exact;
 * - starting or re-entering text measures once instead of two or three times.
 * Two internal helpers are global only so tests/ov_edit_unwind.c can trace
 * them: ove_hit, ove_caret_place. */
#include "asm.inc"
#include "ov_layout.inc"

/* Windows values used here (checked by tests/ov_edit_layout.c) */
#define W_CFS_POINT 0x0002
#define W_CFS_CANDIDATEPOS 0x0040
#define W_CF_UNICODETEXT 13
#define W_INFINITE 0xFFFFFFFF
#define W_CF_STYLE 0            /* COMPOSITIONFORM */
#define W_CF_POS 4
#define W_CF_AREA 12
#define W_CF_BYTES 28
#define W_CAND_INDEX 0          /* CANDIDATEFORM */
#define W_CAND_STYLE 4
#define W_CAND_POS 8
#define W_CAND_AREA 16
#define W_CAND_BYTES 32

#define OV(f) [rip + O + f]

/* Hit-test context (16-byte aligned, built once per query by CTX) */
#define CX_P 0                  /* float x + .5, y + .5, 0, 0: the pixel's center */
#define CX_PX 16                /* POINT */
#define CX_PY 20
#define CX_S2 24                /* S(2), S(3), S(4) */
#define CX_S3 28
#define CX_S4 32
#define CX_BYTES 48

        .section .rdata$ov_edit,"dr"
        .balign 16
.Lhalf2:        .long 0x3F000000, 0x3F000000, 0, 0      /* .5f, .5f */
.Labsmask:      .long 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF
.Lcodes:        .long 3, 2, 6, 1, 4, 9, 8, 12           /* EDGE_* of the 8 box handles */
.Lhalf:         .long 0x3F000000        /* 0.5f */
.Lone:          .long 0x3F800000        /* 1.0f */
.Leps:          .long 0x358637BD        /* 1e-6f */
.Lk15:          .long 0x3FC00000        /* 1.5f */
.Lk2:           .long 0x40000000        /* 2.0f */
.Lk3:           .long 0x40400000        /* 3.0f */
.Lk4:           .long 0x40800000        /* 4.0f */
.Lk7:           .long 0x40E00000        /* 7.0f */
.Lempty:        .short 0                /* L"" */

/* ---- macros ---------------------------------------------------------------------- */

/* dst (32-bit) = S(k) = max(1, lroundf(k * O.s)); k: label of a float constant */
.macro SCALE dst, k, xa, xb
        movss \xa, dword ptr [rip + \k]
        mulss \xa, dword ptr OV(OV_S)
        LROUNDF \dst, \xa, \xb
        test \dst, \dst
        jg 98f
        mov \dst, 1
98:
.endm

/* dst = the size table of tool (as tool_px picks it) */
.macro TOOLTAB dst, tool, tmp
        lea \dst, [rip + kStroke]
        lea \tmp, [rip + kMarker]
        cmp \tool, T_MARKER
        cmove \dst, \tmp
        lea \tmp, [rip + kBlock]
        cmp \tool, T_MOSAIC
        cmove \dst, \tmp
        lea \tmp, [rip + kFont]
        cmp \tool, T_TEXT
        cmove \dst, \tmp
        lea \tmp, [rip + kNumber]
        cmp \tool, T_NUMBER
        cmove \dst, \tmp
.endm

/* dst (32-bit) = tool_px: max(1, lroundf((float)table entry * O.s)); m: its address */
.macro TOOLPX dst, m, xa, xb
        xorps \xa, \xa
        cvtsi2ss \xa, dword ptr \m
        mulss \xa, dword ptr OV(OV_S)
        LROUNDF \dst, \xa, \xb
        test \dst, \dst
        jg 98f
        mov \dst, 1
98:
.endm

/* dst = &O.ann[idx]; idx: a 64-bit register holding a valid index */
.macro ANNP dst, idx
        lea \dst, [\idx + \idx*2]
        shl \dst, 4
        add \dst, qword ptr OV(OV_ANN)
.endm

/* 48 bytes (an Anno) through xmm0-xmm2; operands without spaces */
.macro COPY48 dst, src
        movups xmm0, xmmword ptr [\src]
        movups xmm1, xmmword ptr [\src + 16]
        movups xmm2, xmmword ptr [\src + 32]
        movups xmmword ptr [\dst], xmm0
        movups xmmword ptr [\dst + 16], xmm1
        movups xmmword ptr [\dst + 32], xmm2
.endm

.macro ZERO48 dst
        xorps xmm0, xmm0
        movups xmmword ptr [\dst], xmm0
        movups xmmword ptr [\dst + 16], xmm0
        movups xmmword ptr [\dst + 32], xmm0
.endm

/* anno_free(r): r is a non-volatile register; needs a call frame */
.macro AFREE r
        mov rcx, qword ptr [\r + AN_PT]
        test rcx, rcx
        jz 97f
        call mem_free
97:
        mov rcx, qword ptr [\r + AN_TEXT]
        test rcx, rcx
        jz 96f
        call mem_free
96:
        ZERO48 \r
.endm

/* Build the hit-test context at register c for the POINT in rdx (eax, xmm0, xmm1) */
.macro CTX c
        mov qword ptr [\c + CX_PX], rdx
        movq xmm0, rdx
        cvtdq2ps xmm0, xmm0
        addps xmm0, xmmword ptr [rip + .Lhalf2]
        movaps xmmword ptr [\c + CX_P], xmm0
        SCALE eax, .Lk2, xmm0, xmm1
        mov dword ptr [\c + CX_S2], eax
        SCALE eax, .Lk3, xmm0, xmm1
        mov dword ptr [\c + CX_S3], eax
        SCALE eax, .Lk4, xmm0, xmm1
        mov dword ptr [\c + CX_S4], eax
.endm

/* seg_dist on pairs: xmm0 = P (x, y, 0, 0), xmm2 = a, xmm3 = b (POINTs in the low 8
 * bytes, the rest zero) -> xmm5 = the distance; xmm1-xmm4 clobbered. Lane 0 does the
 * x terms and lane 1 the y terms of the C expressions, summed in the C order. */
.macro SEGD
        psubd xmm3, xmm2
        cvtdq2ps xmm2, xmm2
        addps xmm2, xmmword ptr [rip + .Lhalf2]         /* ax, ay */
        cvtdq2ps xmm3, xmm3                             /* dx, dy */
        movaps xmm4, xmm3
        mulps xmm4, xmm3
        pshufd xmm1, xmm4, 0x55
        addss xmm4, xmm1                                /* l2 = dx * dx + dy * dy */
        xorps xmm5, xmm5
        comiss xmm4, xmm5
        jbe 81f                                         /* t = 0 */
        movaps xmm5, xmm0
        subps xmm5, xmm2
        mulps xmm5, xmm3
        pshufd xmm1, xmm5, 0x55
        addss xmm5, xmm1                                /* (x - ax) * dx + (y - ay) * dy */
        divss xmm5, xmm4
        xorps xmm1, xmm1
        maxss xmm1, xmm5                                /* t < 0 ? 0 : t (NaN stays) */
        movss xmm5, dword ptr [rip + .Lone]
        minss xmm5, xmm1                                /* t > 1 ? 1 : t */
81:
        shufps xmm5, xmm5, 0
        mulps xmm5, xmm3
        addps xmm5, xmm2
        subps xmm5, xmm0                                /* ex = ax + t * dx - x, ey */
        mulps xmm5, xmm5
        pshufd xmm1, xmm5, 0x55
        addss xmm5, xmm1
        sqrtss xmm5, xmm5
.endm

/* In ove_hit (rdi = p0, r12 = p1): rect_corners -> r8d left, r9d top, r10d right, r11d bottom */
.macro CORNERS
        mov r8d, dword ptr [rdi]
        mov r10d, dword ptr [r12]
        mov eax, r8d
        cmp r8d, r10d
        cmovg r8d, r10d
        cmovg r10d, eax
        inc r10d
        mov r9d, dword ptr [rdi + 4]
        mov r11d, dword ptr [r12 + 4]
        mov eax, r9d
        cmp r9d, r11d
        cmovg r9d, r11d
        cmovg r11d, eax
        inc r11d
.endm

/* In ove_hit (rsi = context): eax = min(px - left, right - 1 - px, py - top, bottom - 1 - py)
 * for the rectangle in r8d-r11d. The point is in the rectangle inflated by d iff
 * eax >= -d. Clobbers ecx, edx. */
.macro MDIST
        mov eax, dword ptr [rsi + CX_PX]
        mov ecx, r10d
        sub ecx, eax
        dec ecx
        sub eax, r8d
        cmp ecx, eax
        cmovl eax, ecx
        mov edx, dword ptr [rsi + CX_PY]
        mov ecx, r11d
        sub ecx, edx
        dec ecx
        cmp ecx, eax
        cmovl eax, ecx
        sub edx, r9d
        cmp edx, eax
        cmovl eax, edx
.endm

/* In ove_hit: d = tol = (float)S(4) + (float)a->size * 0.5f */
.macro TOL d, t
        xorps \d, \d
        cvtsi2ss \d, dword ptr [rsi + CX_S4]
        xorps \t, \t
        cvtsi2ss \t, dword ptr [rbx + AN_SIZE]
        mulss \t, dword ptr [rip + .Lhalf]
        addss \d, \t
.endm

/* text_box(rcx, te.buf, te.len, te.pos, te.px, rsp + c, rsp + lh) */
.macro TEXTBOX_TE c, lh
        mov rdx, qword ptr OV(OV_TE_BUF)
        mov r8d, dword ptr OV(OV_TE_LEN)
        mov r9, qword ptr OV(OV_TE_POS)
        mov eax, dword ptr OV(OV_TE_PX)
        mov dword ptr [rsp + 32], eax
        lea rax, [rsp + \c]
        mov qword ptr [rsp + 40], rax
        lea rax, [rsp + \lh]
        mov qword ptr [rsp + 48], rax
        call text_box
.endm

/* ---- the annotation list and its undo history ------------------------------------ */

/* bool list_insert(int i, Anno *a): takes over *a (zeroed) on success */
FUNC list_insert
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 32
        ENDPROLOG
        movsxd rbx, ecx
        mov rsi, rdx
        mov eax, dword ptr OV(OV_NANN)
        cmp eax, dword ptr OV(OV_ANN_CAP)
        jne .Lli_room
        lea edi, [rax + rax]            /* cap = ann_cap ? ann_cap * 2 : 16 */
        mov ecx, 16
        test eax, eax
        cmovz edi, ecx
        movsxd rdx, edi
        lea rdx, [rdx + rdx*2]
        shl rdx, 4
        mov rcx, qword ptr OV(OV_ANN)
        call mem_grow
        test rax, rax
        jz .Lli_ret                     /* false */
        mov qword ptr OV(OV_ANN), rax
        mov dword ptr OV(OV_ANN_CAP), edi
.Lli_room:
        movsxd rax, dword ptr OV(OV_NANN)
        lea edx, [rax + 1]
        mov dword ptr OV(OV_NANN), edx
        mov rcx, qword ptr OV(OV_ANN)
        lea rax, [rax + rax*2]
        shl rax, 4
        add rax, rcx                    /* end of the list */
        lea rdx, [rbx + rbx*2]
        shl rdx, 4
        add rdx, rcx                    /* &ann[i] */
        cmp rax, rdx
        jbe .Lli_put
.Lli_move:                              /* ann[i..n) up by one, from the top */
        sub rax, AN_BYTES
        movups xmm0, xmmword ptr [rax]
        movups xmm1, xmmword ptr [rax + 16]
        movups xmm2, xmmword ptr [rax + 32]
        movups xmmword ptr [rax + 48], xmm0
        movups xmmword ptr [rax + 64], xmm1
        movups xmmword ptr [rax + 80], xmm2
        cmp rax, rdx
        ja .Lli_move
.Lli_put:
        COPY48 rdx, rsi
        ZERO48 rsi
        mov eax, 1
.Lli_ret:
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void list_remove(int i, Anno *out) */
FUNC list_remove
        ENDPROLOG
        movsxd rax, ecx
        lea rax, [rax + rax*2]
        shl rax, 4
        mov rcx, qword ptr OV(OV_ANN)
        add rax, rcx                    /* &ann[i] */
        COPY48 rdx, rax
        movsxd rdx, dword ptr OV(OV_NANN)
        dec rdx
        mov dword ptr OV(OV_NANN), edx
        lea rdx, [rdx + rdx*2]
        shl rdx, 4
        add rdx, rcx                    /* the old last one */
        cmp rax, rdx
        jae .Llr_zero
.Llr_move:                              /* ann(i..n) down by one */
        movups xmm0, xmmword ptr [rax + 48]
        movups xmm1, xmmword ptr [rax + 64]
        movups xmm2, xmmword ptr [rax + 80]
        movups xmmword ptr [rax], xmm0
        movups xmmword ptr [rax + 16], xmm1
        movups xmmword ptr [rax + 32], xmm2
        add rax, AN_BYTES
        cmp rax, rdx
        jb .Llr_move
.Llr_zero:
        ZERO48 rdx
        ret
ENDF

/* void ops_truncate(int n): drop the redoable steps from n on */
FUNC ops_truncate
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 32
        ENDPROLOG
        mov esi, ecx
        movsxd rax, ecx
        movsxd rdi, dword ptr OV(OV_NOPS_ALL)
        cmp rax, rdi
        jge .Lot_set
        mov rcx, qword ptr OV(OV_OPS)
        imul rbx, rax, OPR_BYTES
        imul rdi, rdi, OPR_BYTES
        lea rbx, [rbx + rcx + OPR_A]
        lea rdi, [rdi + rcx + OPR_A]
.Lot_free:
        AFREE rbx
        add rbx, OPR_BYTES
        cmp rbx, rdi
        jb .Lot_free
.Lot_set:
        mov dword ptr OV(OV_NOPS_ALL), esi
        cmp dword ptr OV(OV_NOPS), esi
        jle .Lot_ret
        mov dword ptr OV(OV_NOPS), esi
.Lot_ret:
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* bool op_push(int kind, int idx, Anno *a): records a step just done; *a (OP_DEL:
 * the removed annotation, OP_EDIT: the version before) is taken over, NULL for OP_ADD */
FUNC op_push
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 40
        ENDPROLOG
        mov ebx, ecx
        mov esi, edx
        mov rdi, r8
        mov byte ptr OV(OV_NUDGING), 0
        mov ecx, dword ptr OV(OV_NOPS)
        cmp ecx, dword ptr OV(OV_NOPS_ALL)
        jge .Lop_cap                    /* nothing to redo: ops_truncate would change nothing */
        call ops_truncate
.Lop_cap:
        mov eax, dword ptr OV(OV_NOPS)
        cmp eax, dword ptr OV(OV_OPS_CAP)
        jne .Lop_room
        lea r12d, [rax + rax]           /* cap = ops_cap ? ops_cap * 2 : 32 */
        mov ecx, 32
        test eax, eax
        cmovz r12d, ecx
        movsxd rdx, r12d
        imul rdx, rdx, OPR_BYTES
        mov rcx, qword ptr OV(OV_OPS)
        call mem_grow
        test rax, rax
        jnz .Lop_grown
        test rdi, rdi
        jz .Lop_ret                     /* false (eax = 0) */
        AFREE rdi
        xor eax, eax
        jmp .Lop_ret
.Lop_grown:
        mov qword ptr OV(OV_OPS), rax
        mov dword ptr OV(OV_OPS_CAP), r12d
.Lop_room:
        movsxd rax, dword ptr OV(OV_NOPS)
        lea edx, [rax + 1]
        mov dword ptr OV(OV_NOPS), edx
        mov dword ptr OV(OV_NOPS_ALL), edx
        imul rax, rax, OPR_BYTES
        add rax, qword ptr OV(OV_OPS)
        mov dword ptr [rax + OPR_KIND], ebx
        mov dword ptr [rax + OPR_IDX], esi
        test rdi, rdi
        jz .Lop_none
        COPY48 rax+OPR_A, rdi
        ZERO48 rdi
        jmp .Lop_true
.Lop_none:
        ZERO48 rax+OPR_A
.Lop_true:
        mov eax, 1
.Lop_ret:
        add rsp, 40
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void op_apply(Op *o, bool back). The list never shrinks below a size it once had,
 * so the inserts here cannot fail. */
FUNC op_apply
        ENDPROLOG
        mov eax, dword ptr [rcx + OPR_KIND]
        mov r8, rcx
        mov ecx, dword ptr [r8 + OPR_IDX]
        cmp eax, OP_EDIT
        je .Lap_edit
        cmp eax, OP_DEL
        ja .Lap_ret
        movzx edx, dl
        cmp eax, edx                    /* insert: OP_ADD forward, OP_DEL back */
        lea rdx, [r8 + OPR_A]
        je list_insert
        jmp list_remove
.Lap_edit:                              /* swap ann[idx] and o->a */
        movsxd rcx, ecx
        ANNP rax, rcx
        movups xmm0, xmmword ptr [rax]
        movups xmm1, xmmword ptr [rax + 16]
        movups xmm2, xmmword ptr [rax + 32]
        movups xmm3, xmmword ptr [r8 + OPR_A]
        movups xmm4, xmmword ptr [r8 + OPR_A + 16]
        movups xmm5, xmmword ptr [r8 + OPR_A + 32]
        movups xmmword ptr [rax], xmm3
        movups xmmword ptr [rax + 16], xmm4
        movups xmmword ptr [rax + 32], xmm5
        movups xmmword ptr [r8 + OPR_A], xmm0
        movups xmmword ptr [r8 + OPR_A + 16], xmm1
        movups xmmword ptr [r8 + OPR_A + 32], xmm2
.Lap_ret:
        ret
ENDF

/* void annos_reset(void) */
FUNC annos_reset
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        mov rbx, qword ptr OV(OV_ANN)
        mov esi, dword ptr OV(OV_NANN)
        test esi, esi
        jle .Lar_list
.Lar_free:
        AFREE rbx
        add rbx, AN_BYTES
        dec esi
        jnz .Lar_free
.Lar_list:
        mov dword ptr OV(OV_NANN), 0
        xor ecx, ecx
        call ops_truncate
        mov dword ptr OV(OV_PICK), -1
        mov byte ptr OV(OV_NUDGING), 0
        lea rbx, OV(OV_ORIG)
        AFREE rbx
        lea rbx, OV(OV_ACT)
        AFREE rbx
        mov byte ptr OV(OV_HAS_ACT), 0
        add rsp, 40
        pop rsi
        pop rbx
        ret
ENDF

/* ---- picking ----------------------------------------------------------------------- */

/* void pick_clear(void): deselect, drawing the annotation back into the canvas */
FUNC pick_clear
        ENDPROLOG
        mov eax, dword ptr OV(OV_PICK)
        test eax, eax
        js .Lpc_ret
        mov dword ptr OV(OV_PICK), -1
        mov byte ptr OV(OV_NUDGING), 0
        inc dword ptr OV(OV_ACT_VER)
        mov ecx, dword ptr OV(OV_NANN)
        dec ecx
        cmp eax, ecx
        je canvas_add_top
        jmp canvas_rebuild
.Lpc_ret:
        ret
ENDF

/* void pick_set(int i) */
FUNC pick_set
        ENDPROLOG
        cmp dword ptr OV(OV_PICK), ecx
        je .Lps_ret
        mov dword ptr OV(OV_PICK), ecx  /* a previous pick goes back into the canvas */
        mov byte ptr OV(OV_NUDGING), 0
        inc dword ptr OV(OV_ACT_VER)
        jmp canvas_rebuild
.Lps_ret:
        ret
ENDF

/* void undo(void) */
FUNC undo
        ALLOC 40
        ENDPROLOG
        cmp byte ptr OV(OV_TE_ON), 0
        jne .Lun_ret
        cmp dword ptr OV(OV_DRAG), DR_NONE
        jne .Lun_ret
        mov ecx, dword ptr OV(OV_NOPS)
        test ecx, ecx
        jle .Lun_ret
        dec ecx
        mov dword ptr OV(OV_NOPS), ecx
        mov dword ptr OV(OV_PICK), -1
        mov byte ptr OV(OV_NUDGING), 0
        inc dword ptr OV(OV_ACT_VER)
        imul rcx, rcx, OPR_BYTES
        add rcx, qword ptr OV(OV_OPS)
        mov edx, 1
        call op_apply
        add rsp, 40
        jmp canvas_rebuild
.Lun_ret:
        add rsp, 40
        ret
ENDF

/* void redo(void) */
FUNC redo
        ALLOC 40
        ENDPROLOG
        cmp byte ptr OV(OV_TE_ON), 0
        jne .Lre_ret
        cmp dword ptr OV(OV_DRAG), DR_NONE
        jne .Lre_ret
        mov ecx, dword ptr OV(OV_NOPS)
        cmp ecx, dword ptr OV(OV_NOPS_ALL)
        jge .Lre_ret
        lea eax, [rcx + 1]
        mov dword ptr OV(OV_NOPS), eax
        mov dword ptr OV(OV_PICK), -1
        mov byte ptr OV(OV_NUDGING), 0
        inc dword ptr OV(OV_ACT_VER)
        movsxd rcx, ecx
        imul rcx, rcx, OPR_BYTES
        add rcx, qword ptr OV(OV_OPS)
        xor edx, edx
        call op_apply
        add rsp, 40
        jmp canvas_rebuild
.Lre_ret:
        add rsp, 40
        ret
ENDF

/* void commit_anno(Anno *a, bool pick): shapes stay picked after drawing */
FUNC commit_anno
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        movzx esi, dl
        call pick_clear
        mov edi, dword ptr OV(OV_NANN)
        mov ecx, edi
        mov rdx, rbx
        call list_insert
        test al, al
        jz .Lca_fail
        xor ecx, ecx                    /* OP_ADD */
        mov edx, edi
        xor r8d, r8d
        call op_push
        test esi, esi
        jz .Lca_top
        mov dword ptr OV(OV_PICK), edi
        inc dword ptr OV(OV_ACT_VER)
        jmp .Lca_ret
.Lca_top:
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        jmp canvas_add_top
.Lca_fail:
        AFREE rbx
.Lca_ret:
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void pick_delete(void) */
FUNC pick_delete
        PUSHREG rbx
        ALLOC 80
        ENDPROLOG
        mov ebx, dword ptr OV(OV_PICK)
        test ebx, ebx
        js .Lpd_ret
        mov dword ptr OV(OV_PICK), -1
        inc dword ptr OV(OV_ACT_VER)
        mov ecx, ebx
        lea rdx, [rsp + 32]
        call list_remove
        mov ecx, OP_DEL
        mov edx, ebx
        lea r8, [rsp + 32]
        call op_push
        cmp ebx, dword ptr OV(OV_NANN)
        jge .Lpd_ret                    /* the ones above it were drawn live */
        add rsp, 80
        pop rbx
        jmp canvas_rebuild
.Lpd_ret:
        add rsp, 80
        pop rbx
        ret
ENDF

/* int next_number(void) */
FUNC next_number
        ENDPROLOG
        mov rcx, qword ptr OV(OV_ANN)
        mov edx, dword ptr OV(OV_NANN)
        xor eax, eax
        test edx, edx
        jle .Lnn_done
.Lnn_loop:
        cmp dword ptr [rcx + AN_TOOL], T_NUMBER
        jne .Lnn_next
        mov r8d, dword ptr [rcx + AN_NUM]
        cmp r8d, eax
        cmovg eax, r8d
.Lnn_next:
        add rcx, AN_BYTES
        dec edx
        jnz .Lnn_loop
.Lnn_done:
        inc eax
        ret
ENDF

/* ---- hit testing ------------------------------------------------------------------- */

/* float seg_dist(float x, float y, POINT a, POINT b) */
FUNC seg_dist
        ENDPROLOG
        unpcklps xmm0, xmm1
        movq xmm0, xmm0
        movq xmm2, r8
        movq xmm3, r9
        SEGD
        movaps xmm0, xmm5
        ret
ENDF

/* ove_hit: anno_hit for annotation rcx and the context at rdx -> eax = 0 / 1.
 *
 * anno_hit first requires p inside anno_bounds inflated by S(4). Every shape test
 * but the ellipse's lies inside that box already (the margins of anno_bounds
 * exceed each test's reach by at least two pixels), so only the ellipse checks it. */
FUNC ove_hit
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 72
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        xor eax, eax
        movsxd r8, dword ptr [rbx + AN_NPT]
        test r8d, r8d
        jle .Lh_ret
        mov ecx, dword ptr [rbx + AN_TOOL]
        cmp ecx, T_NUMBER
        ja .Lh_ret
        mov rdi, qword ptr [rbx + AN_PT]        /* p0 */
        lea r12, [rdi + r8*8 - 8]               /* p1 */
        lea rdx, [rip + .Lh_tab]
        movsxd rcx, dword ptr [rdx + rcx*4]
        add rcx, rdx
        jmp rcx

.Lh_rect:                                       /* near the outline: in the rectangle */
        CORNERS                                 /* inflated by S(4), not in the one */
        MDIST                                   /* deflated by size + S(4) */
        mov ecx, dword ptr [rsi + CX_S4]
        mov edx, dword ptr [rbx + AN_SIZE]
        add edx, ecx
        neg ecx
        cmp eax, ecx
        jl .Lh_no
        xor ecx, ecx
        cmp eax, edx
        setl cl
        mov eax, ecx
        jmp .Lh_ret

.Lh_mosaic:                                     /* in the rectangle inflated by S(2) */
        CORNERS
        MDIST
        mov ecx, dword ptr [rsi + CX_S2]
        neg ecx
        xor edx, edx
        cmp eax, ecx
        setge dl
        mov eax, edx
        jmp .Lh_ret

.Lh_ellipse:
        CORNERS
        mov ecx, r10d
        sub ecx, r8d                            /* w */
        mov edx, r11d
        sub edx, r9d                            /* h */
        cmp edx, ecx
        cmovl ecx, edx
        mov eax, ecx
        shr eax, 31
        add ecx, eax
        sar ecx, 1                              /* min(w, h) / 2 */
        mov eax, dword ptr [rbx + AN_SIZE]
        add eax, 2
        sub eax, ecx
        mov ecx, 2
        cmp eax, ecx
        cmovl eax, ecx                          /* anno_bounds' margin */
        add eax, dword ptr [rsi + CX_S4]
        mov edi, eax
        MDIST
        neg edi
        cmp eax, edi
        jl .Lh_no
        xorps xmm0, xmm0
        cvtsi2ss xmm0, dword ptr [rbx + AN_SIZE]
        mulss xmm0, dword ptr [rip + .Lhalf]    /* hw */
        mov eax, r10d
        sub eax, r8d
        xorps xmm1, xmm1
        cvtsi2ss xmm1, eax
        mulss xmm1, dword ptr [rip + .Lhalf]
        subss xmm1, xmm0
        maxss xmm1, dword ptr [rip + .Lone]     /* rx = fmaxf(w * .5f - hw, 1.f) */
        mov eax, r11d
        sub eax, r9d
        xorps xmm2, xmm2
        cvtsi2ss xmm2, eax
        mulss xmm2, dword ptr [rip + .Lhalf]
        subss xmm2, xmm0
        maxss xmm2, dword ptr [rip + .Lone]     /* ry */
        lea eax, [r8 + r10]
        xorps xmm3, xmm3
        cvtsi2ss xmm3, eax
        mulss xmm3, dword ptr [rip + .Lhalf]
        movss xmm4, dword ptr [rsi + CX_P]
        subss xmm4, xmm3                        /* u */
        lea eax, [r9 + r11]
        xorps xmm3, xmm3
        cvtsi2ss xmm3, eax
        mulss xmm3, dword ptr [rip + .Lhalf]
        movss xmm5, dword ptr [rsi + CX_P + 4]
        subss xmm5, xmm3                        /* v */
        mulss xmm4, xmm4                        /* u * u */
        mulss xmm5, xmm5                        /* v * v */
        movaps xmm0, xmm1
        mulss xmm0, xmm1                        /* rx * rx */
        movaps xmm3, xmm0
        mulss xmm3, xmm1
        mulss xmm1, xmm3                        /* rx * rx * rx * rx */
        movaps xmm3, xmm4
        divss xmm3, xmm1                        /* u * u / rx^4 */
        movaps xmm1, xmm4
        divss xmm1, xmm0                        /* u * u / (rx * rx) */
        movaps xmm0, xmm2
        mulss xmm0, xmm2                        /* ry * ry */
        movaps xmm4, xmm0
        mulss xmm4, xmm2
        mulss xmm2, xmm4                        /* ry^4 */
        movaps xmm4, xmm5
        divss xmm4, xmm2                        /* v * v / ry^4 */
        divss xmm5, xmm0                        /* v * v / (ry * ry) */
        addss xmm1, xmm5
        subss xmm1, dword ptr [rip + .Lone]     /* f */
        addss xmm3, xmm4
        sqrtss xmm3, xmm3
        addss xmm3, xmm3                        /* g = 2.f * sqrtf(...) */
        comiss xmm3, dword ptr [rip + .Leps]
        jbe .Lh_no                              /* g > 1e-6f */
        andps xmm1, xmmword ptr [rip + .Labsmask]
        divss xmm1, xmm3                        /* fabsf(f) / g: distance to the outline */
        TOL xmm0, xmm2
        xor eax, eax
        comiss xmm0, xmm1
        setae al
        jmp .Lh_ret

.Lh_line:
        movaps xmm0, xmmword ptr [rsi + CX_P]
        movq xmm2, qword ptr [rdi]
        movq xmm3, qword ptr [r12]
        SEGD
        TOL xmm0, xmm1
        jmp .Lh_cmp
.Lh_arrow:
        movaps xmm0, xmmword ptr [rsi + CX_P]
        movq xmm2, qword ptr [rdi]
        movq xmm3, qword ptr [r12]
        SEGD
        TOL xmm0, xmm1
        xorps xmm1, xmm1
        cvtsi2ss xmm1, dword ptr [rbx + AN_SIZE]
        addss xmm0, xmm1                        /* tol + size */
.Lh_cmp:
        xor eax, eax
        comiss xmm0, xmm5
        setae al
        jmp .Lh_ret

.Lh_pen:
        movaps xmm0, xmmword ptr [rsi + CX_P]
        TOL xmm1, xmm2
        movss dword ptr [rsp + 56], xmm1
        cmp rdi, r12
        jne .Lh_pen_segs
        movq xmm2, qword ptr [rdi]              /* one point */
        movq xmm3, qword ptr [rdi]
        SEGD
        movss xmm1, dword ptr [rsp + 56]
        xor eax, eax
        comiss xmm1, xmm5
        setae al
        jmp .Lh_ret
.Lh_pen_segs:
        /* a segment whose box is more than T = S(4) + size / 2 + 2 away on x or y is
         * at least tol + 1.5 away: skipped without computing its distance */
        mov eax, dword ptr [rbx + AN_SIZE]
        mov ecx, eax
        shr ecx, 31
        add eax, ecx
        sar eax, 1
        add eax, dword ptr [rsi + CX_S4]
        add eax, 2
        mov r8d, dword ptr [rsi + CX_PX]
        mov r9d, r8d
        sub r8d, eax                            /* px - T */
        add r9d, eax                            /* px + T */
        mov r10d, dword ptr [rsi + CX_PY]
        mov r11d, r10d
        sub r10d, eax
        add r11d, eax
.Lh_seg:
        mov eax, dword ptr [rdi]
        mov ecx, dword ptr [rdi + 8]
        mov edx, eax
        cmp eax, ecx
        cmovg eax, ecx                          /* min x */
        cmovg ecx, edx                          /* max x */
        cmp ecx, r8d
        jl .Lh_seg_next
        cmp eax, r9d
        jg .Lh_seg_next
        mov eax, dword ptr [rdi + 4]
        mov ecx, dword ptr [rdi + 12]
        mov edx, eax
        cmp eax, ecx
        cmovg eax, ecx
        cmovg ecx, edx
        cmp ecx, r10d
        jl .Lh_seg_next
        cmp eax, r11d
        jg .Lh_seg_next
        movq xmm2, qword ptr [rdi]
        movq xmm3, qword ptr [rdi + 8]
        SEGD
        movss xmm1, dword ptr [rsp + 56]
        comiss xmm1, xmm5
        jae .Lh_yes
.Lh_seg_next:
        add rdi, 8
        cmp rdi, r12
        jb .Lh_seg
        jmp .Lh_no

.Lh_number:                                     /* in the disc of radius size + S(3) */
        movq xmm1, qword ptr [rdi]
        cvtdq2ps xmm1, xmm1
        addps xmm1, xmmword ptr [rip + .Lhalf2]
        movaps xmm0, xmmword ptr [rsi + CX_P]
        subps xmm0, xmm1
        mulps xmm0, xmm0
        pshufd xmm1, xmm0, 0x55
        addss xmm0, xmm1                        /* dx * dx + dy * dy */
        mov eax, dword ptr [rbx + AN_SIZE]
        add eax, dword ptr [rsi + CX_S3]
        xorps xmm1, xmm1
        cvtsi2ss xmm1, eax
        mulss xmm1, xmm1
        xor eax, eax
        comiss xmm1, xmm0
        setae al
        jmp .Lh_ret

.Lh_text:                                       /* in its text box inflated by S(3) */
        mov eax, dword ptr [rsi + CX_S3]        /* the box starts at the position (text_box): */
        mov ecx, dword ptr [rsi + CX_PX]        /* left of it or above it, no need to measure */
        add ecx, eax
        cmp ecx, dword ptr [rdi]
        jl .Lh_no
        mov ecx, dword ptr [rsi + CX_PY]
        add ecx, eax
        cmp ecx, dword ptr [rdi + 4]
        jl .Lh_no
        lea rcx, [rsp + 56]
        mov rdx, qword ptr [rbx + AN_TEXT]
        mov r8d, dword ptr [rbx + AN_NTEXT]
        mov r9, qword ptr [rdi]
        mov eax, dword ptr [rbx + AN_SIZE]
        mov dword ptr [rsp + 32], eax
        xor eax, eax
        mov qword ptr [rsp + 40], rax
        mov qword ptr [rsp + 48], rax
        call text_box
        mov r8d, dword ptr [rsp + 56 + RC_L]
        mov r9d, dword ptr [rsp + 56 + RC_T]
        mov r10d, dword ptr [rsp + 56 + RC_R]
        mov r11d, dword ptr [rsp + 56 + RC_B]
        cmp r10d, r8d
        jle .Lh_no                              /* empty: rect_inflate leaves it */
        cmp r11d, r9d
        jle .Lh_no
        MDIST
        mov ecx, dword ptr [rsi + CX_S3]
        neg ecx
        xor edx, edx
        cmp eax, ecx
        setge dl
        mov eax, edx
        jmp .Lh_ret

.Lh_yes:
        mov eax, 1
        jmp .Lh_ret
.Lh_no:
        xor eax, eax
.Lh_ret:
        add rsp, 72
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

        .section .rdata$ove_hit,"dr"
        .balign 4
.Lh_tab:
        .long .Lh_ret - .Lh_tab                 /* T_NONE */
        .long .Lh_rect - .Lh_tab
        .long .Lh_ellipse - .Lh_tab
        .long .Lh_line - .Lh_tab
        .long .Lh_arrow - .Lh_tab
        .long .Lh_pen - .Lh_tab
        .long .Lh_pen - .Lh_tab                 /* T_MARKER */
        .long .Lh_mosaic - .Lh_tab
        .long .Lh_text - .Lh_tab
        .long .Lh_number - .Lh_tab

/* bool anno_hit(const Anno *a, POINT p): is p on the visible part of a? Outlines
 * (rectangle, ellipse) only count near the stroke. */
FUNC anno_hit
        ALLOC 88
        ENDPROLOG
        lea r8, [rsp + 32]
        CTX r8
        mov rdx, r8
        call ove_hit
        add rsp, 88
        ret
ENDF

/* int anno_at(POINT p): the topmost annotation under p, -1 none. Only the part
 * inside the selection is visible. */
FUNC anno_at
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 88
        ENDPROLOG
        mov rdx, rcx
        mov rax, rcx
        sar rax, 32
        cmp ecx, dword ptr OV(OV_SEL + RC_L)
        jl .Laa_none
        cmp ecx, dword ptr OV(OV_SEL + RC_R)
        jge .Laa_none
        cmp eax, dword ptr OV(OV_SEL + RC_T)
        jl .Laa_none
        cmp eax, dword ptr OV(OV_SEL + RC_B)
        jge .Laa_none
        movsxd rsi, dword ptr OV(OV_NANN)
        dec rsi
        js .Laa_none
        lea r8, [rsp + 32]
        CTX r8
        ANNP rbx, rsi
.Laa_loop:
        mov rcx, rbx
        lea rdx, [rsp + 32]
        call ove_hit
        test eax, eax
        jnz .Laa_found
        sub rbx, AN_BYTES
        dec rsi
        jns .Laa_loop
.Laa_none:
        mov eax, -1
        jmp .Laa_ret
.Laa_found:
        mov eax, esi
.Laa_ret:
        add rsp, 88
        pop rsi
        pop rbx
        ret
ENDF

/* int pick_handles(POINT *hp, int *code): 8 on a box, the two ends of a line */
FUNC pick_handles
        ENDPROLOG
        movsxd rax, dword ptr OV(OV_PICK)
        test eax, eax
        js .Lph_none
        ANNP r8, rax
        mov eax, dword ptr [r8 + AN_TOOL]
        movsxd r9, dword ptr [r8 + AN_NPT]
        mov r8, qword ptr [r8 + AN_PT]
        lea r9, [r8 + r9*8 - 8]
        lea r10d, [rax - T_LINE]
        cmp r10d, 1
        jbe .Lph_seg
        cmp eax, T_RECT
        je .Lph_box
        cmp eax, T_ELLIPSE
        je .Lph_box
        cmp eax, T_MOSAIC
        je .Lph_box
.Lph_none:
        xor eax, eax
        ret
.Lph_seg:
        mov rax, qword ptr [r8]
        mov qword ptr [rcx], rax
        mov rax, qword ptr [r9]
        mov qword ptr [rcx + 8], rax
        mov dword ptr [rdx], END_A
        mov dword ptr [rdx + 4], END_B
        mov eax, 2
        ret
.Lph_box:                               /* rows top, middle, bottom; x left, middle, right */
        movups xmm0, xmmword ptr [rip + .Lcodes]
        movups xmm1, xmmword ptr [rip + .Lcodes + 16]
        movups xmmword ptr [rdx], xmm0
        movups xmmword ptr [rdx + 16], xmm1
        mov r10d, dword ptr [r8]
        mov r11d, dword ptr [r9]
        mov eax, r10d
        cmp r10d, r11d
        cmovg r10d, r11d                /* left */
        cmovg r11d, eax
        inc r11d                        /* right */
        mov dword ptr [rcx + 0], r10d
        mov dword ptr [rcx + 24], r10d
        mov dword ptr [rcx + 40], r10d
        mov dword ptr [rcx + 16], r11d
        mov dword ptr [rcx + 32], r11d
        mov dword ptr [rcx + 56], r11d
        lea eax, [r10 + r11]
        mov edx, eax
        shr edx, 31
        add eax, edx
        sar eax, 1                      /* (left + right) / 2 */
        mov dword ptr [rcx + 8], eax
        mov dword ptr [rcx + 48], eax
        mov r10d, dword ptr [r8 + 4]
        mov r11d, dword ptr [r9 + 4]
        mov eax, r10d
        cmp r10d, r11d
        cmovg r10d, r11d                /* top */
        cmovg r11d, eax
        inc r11d                        /* bottom */
        mov dword ptr [rcx + 4], r10d
        mov dword ptr [rcx + 12], r10d
        mov dword ptr [rcx + 20], r10d
        mov dword ptr [rcx + 44], r11d
        mov dword ptr [rcx + 52], r11d
        mov dword ptr [rcx + 60], r11d
        lea eax, [r10 + r11]
        mov edx, eax
        shr edx, 31
        add eax, edx
        sar eax, 1
        mov dword ptr [rcx + 28], eax
        mov dword ptr [rcx + 36], eax
        mov eax, 8
        ret
ENDF

/* int pick_grab_at(POINT p): the handle of the pick under p (EDGE_* / END_*), 0 none */
FUNC pick_grab_at
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 136
        ENDPROLOG
        mov rbx, rcx
        lea rcx, [rsp + 32]
        lea rdx, [rsp + 96]
        call pick_handles
        test eax, eax
        jz .Lpg_ret
        mov esi, eax
        SCALE eax, .Lk7, xmm0, xmm1
        or eax, 1                       /* handle_sz() */
        shr eax, 1
        SCALE ecx, .Lk3, xmm0, xmm1
        add ecx, eax                    /* tol = handle_sz() / 2 + S(3) */
        /* on a small shape the handles must not cover all of it, or it could not be moved */
        movsxd rax, dword ptr OV(OV_PICK)
        ANNP r8, rax
        movsxd r9, dword ptr [r8 + AN_NPT]
        mov r10, qword ptr [r8 + AN_PT]
        lea r9, [r10 + r9*8 - 8]
        mov eax, dword ptr [r9]
        sub eax, dword ptr [r10]
        mov edx, eax
        neg eax
        cmovl eax, edx                  /* w = abs */
        mov r11d, dword ptr [r9 + 4]
        sub r11d, dword ptr [r10 + 4]
        mov edx, r11d
        neg r11d
        cmovl r11d, edx                 /* h */
        mov edx, dword ptr [r8 + AN_TOOL]
        sub edx, T_LINE
        cmp edx, 1
        jbe .Lpg_seg
        cmp r11d, eax
        cmovl eax, r11d                 /* box: min(w, h) */
        jmp .Lpg_div
.Lpg_seg:
        cmp r11d, eax
        cmovg eax, r11d                 /* line: max(w, h) */
.Lpg_div:
        mov edx, 0xAAAAAAAB
        imul rax, rdx
        shr rax, 34                     /* / 6 */
        mov edx, 1
        cmp eax, edx
        cmovl eax, edx
        cmp ecx, eax
        cmovg ecx, eax                  /* tol = min(tol, max(1, ... / 6)) */
        mov r8d, ebx                    /* p.x */
        sar rbx, 32                     /* p.y */
        xor r9d, r9d
.Lpg_loop:
        mov eax, r8d
        sub eax, dword ptr [rsp + 32 + r9*8]
        mov edx, eax
        neg eax
        cmovl eax, edx
        cmp eax, ecx
        jg .Lpg_next
        mov eax, ebx
        sub eax, dword ptr [rsp + 36 + r9*8]
        mov edx, eax
        neg eax
        cmovl eax, edx
        cmp eax, ecx
        jg .Lpg_next
        mov eax, dword ptr [rsp + 96 + r9*4]
        jmp .Lpg_ret
.Lpg_next:
        inc r9d
        cmp r9d, esi
        jb .Lpg_loop
        xor eax, eax
.Lpg_ret:
        add rsp, 136
        pop rsi
        pop rbx
        ret
ENDF

/* bool pick_body_has(POINT p): with no tool, a picked annotation (not a line) can
 * also be dragged by its inside: p in its bounds and in the selection */
FUNC pick_body_has
        PUSHREG rbx
        ALLOC 48
        ENDPROLOG
        xor eax, eax
        movsxd rdx, dword ptr OV(OV_PICK)
        test edx, edx
        js .Lpb_ret
        cmp dword ptr OV(OV_TOOL), T_NONE
        jne .Lpb_ret
        ANNP r8, rdx
        mov r9d, dword ptr [r8 + AN_TOOL]
        sub r9d, T_LINE
        cmp r9d, 1
        jbe .Lpb_ret
        mov rbx, rcx
        mov r9, rcx
        sar r9, 32
        cmp ecx, dword ptr OV(OV_SEL + RC_L)
        jl .Lpb_ret
        cmp ecx, dword ptr OV(OV_SEL + RC_R)
        jge .Lpb_ret
        cmp r9d, dword ptr OV(OV_SEL + RC_T)
        jl .Lpb_ret
        cmp r9d, dword ptr OV(OV_SEL + RC_B)
        jge .Lpb_ret
        lea rcx, [rsp + 32]
        mov rdx, r8
        call anno_bounds
        xor eax, eax
        mov rdx, rbx
        sar rdx, 32
        cmp ebx, dword ptr [rsp + 32 + RC_L]
        jl .Lpb_ret
        cmp ebx, dword ptr [rsp + 32 + RC_R]
        jge .Lpb_ret
        cmp edx, dword ptr [rsp + 32 + RC_T]
        jl .Lpb_ret
        cmp edx, dword ptr [rsp + 32 + RC_B]
        jge .Lpb_ret
        mov eax, 1
.Lpb_ret:
        add rsp, 48
        pop rbx
        ret
ENDF

/* RECT pick_deco(void): the area the pick's handles and dashed box may cover */
FUNC pick_deco
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        movsxd rdx, dword ptr OV(OV_PICK)
        test edx, edx
        js .Lpk_zero
        ANNP rax, rdx
        mov rdx, rax
        call anno_bounds                /* straight into the result (rcx) */
        mov eax, dword ptr [rbx + RC_L]
        cmp dword ptr [rbx + RC_R], eax
        jle .Lpk_ret                    /* empty: rect_inflate leaves it */
        mov eax, dword ptr [rbx + RC_T]
        cmp dword ptr [rbx + RC_B], eax
        jle .Lpk_ret
        SCALE eax, .Lk7, xmm0, xmm1
        or eax, 1                       /* handle_sz() */
        SCALE ecx, .Lk4, xmm0, xmm1
        add eax, ecx
        sub dword ptr [rbx + RC_L], eax
        sub dword ptr [rbx + RC_T], eax
        add dword ptr [rbx + RC_R], eax
        add dword ptr [rbx + RC_B], eax
        jmp .Lpk_ret
.Lpk_zero:
        xor eax, eax
        mov qword ptr [rbx], rax
        mov qword ptr [rbx + 8], rax
.Lpk_ret:
        mov rax, rbx
        add rsp, 32
        pop rbx
        ret
ENDF

/* ---- text tool --------------------------------------------------------------------- */

/* RECT caret_rect(void) */
FUNC caret_rect
        PUSHREG rbx
        ALLOC 80
        ENDPROLOG
        mov rbx, rcx                    /* text_box's box goes to the result, then is replaced */
        TEXTBOX_TE 56, 64
        mov eax, dword ptr [rsp + 56]
        mov edx, dword ptr [rsp + 60]
        mov dword ptr [rbx + RC_L], eax
        mov dword ptr [rbx + RC_T], edx
        SCALE ecx, .Lk15, xmm0, xmm1    /* max(1, lroundf(1.5f * O.s)) */
        add ecx, eax
        mov dword ptr [rbx + RC_R], ecx
        add edx, dword ptr [rsp + 64]
        mov dword ptr [rbx + RC_B], edx
        mov rax, rbx
        add rsp, 80
        pop rbx
        ret
ENDF

/* ove_caret_place(POINT c, int lh): the caret to c, its blink restarted (composition
 * mode), the IME's composition and candidate windows to c (text_caret_update's part
 * after measuring) */
FUNC ove_caret_place
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 64
        ENDPROLOG
        mov rbx, rcx
        mov esi, edx
        mov rdx, rcx
        sar rdx, 32
        API SetCaretPos                 /* kept with composition too: IMEs and screen readers follow it */
        cmp byte ptr OV(OV_DC), 0
        je .Lcp_imm
        mov byte ptr OV(OV_TE_CARET_OFF), 0
        API GetCaretBlinkTime
        test eax, eax
        jz .Lcp_imm
        cmp eax, W_INFINITE
        je .Lcp_imm
        mov rcx, qword ptr OV(OV_HWND)
        mov edx, TIMER_CARET
        mov r8d, eax
        xor r9d, r9d
        API SetTimer
.Lcp_imm:
        mov rcx, qword ptr OV(OV_HWND)
        API ImmGetContext
        test rax, rax
        jz .Lcp_ret
        mov rdi, rax
        xorps xmm0, xmm0
        mov dword ptr [rsp + 32 + W_CF_STYLE], W_CFS_POINT
        mov qword ptr [rsp + 32 + W_CF_POS], rbx
        movups xmmword ptr [rsp + 32 + W_CF_AREA], xmm0
        mov rcx, rdi
        lea rdx, [rsp + 32]
        API ImmSetCompositionWindow
        xorps xmm0, xmm0
        mov dword ptr [rsp + 32 + W_CAND_INDEX], 0
        mov dword ptr [rsp + 32 + W_CAND_STYLE], W_CFS_CANDIDATEPOS
        mov dword ptr [rsp + 32 + W_CAND_POS], ebx
        mov rax, rbx
        sar rax, 32
        add eax, esi
        mov dword ptr [rsp + 32 + W_CAND_POS + 4], eax
        movups xmmword ptr [rsp + 32 + W_CAND_AREA], xmm0
        mov rcx, rdi
        lea rdx, [rsp + 32]
        API ImmSetCandidateWindow
        mov rcx, qword ptr OV(OV_HWND)
        mov rdx, rdi
        API ImmReleaseContext
.Lcp_ret:
        add rsp, 64
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void text_caret_update(void) */
FUNC text_caret_update
        ALLOC 88
        ENDPROLOG
        lea rcx, [rsp + 56]
        TEXTBOX_TE 72, 80
        mov rcx, qword ptr [rsp + 72]
        mov edx, dword ptr [rsp + 80]
        add rsp, 88
        jmp ove_caret_place
ENDF

/* void text_caret_create(void): one measuring gives the line height and the caret */
FUNC text_caret_create
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 88
        ENDPROLOG
        lea rcx, [rsp + 56]
        TEXTBOX_TE 72, 80
        mov rbx, qword ptr [rsp + 72]
        mov esi, dword ptr [rsp + 80]
        mov rcx, qword ptr OV(OV_HWND)
        xor edx, edx
        SCALE r8d, .Lk15, xmm0, xmm1
        mov r9d, esi
        API CreateCaret
        mov rcx, rbx
        mov edx, esi
        call ove_caret_place
        mov rcx, qword ptr OV(OV_HWND)
        add rsp, 88
        pop rsi
        pop rbx
        jmp qword ptr [rip + __imp_ShowCaret]
ENDF

/* void text_begin(POINT p): new text centered on p's line; empty, so the caret is
 * at its position and one measuring is enough */
FUNC text_begin
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 88
        ENDPROLOG
        mov rbx, rcx
        mov byte ptr OV(OV_TE_ON), 1
        xor eax, eax
        mov dword ptr OV(OV_TE_EDIT1), eax
        mov dword ptr OV(OV_TE_LEN), eax
        movsxd rax, dword ptr OV(OV_SIZE_IDX)
        lea rdx, [rip + kFont]
        TOOLPX ecx, [rdx+rax*4], xmm0, xmm1     /* tool_px(T_TEXT, size_idx) */
        mov dword ptr OV(OV_TE_PX), ecx
        movsxd rax, dword ptr OV(OV_COLOR_IDX)
        lea rdx, [rip + kColors]
        mov eax, dword ptr [rdx + rax*4]
        mov dword ptr OV(OV_TE_COLOR), eax
        lea rax, [rsp + 80]             /* text_box(L"", 0, p, px, NULL, &lh) */
        mov qword ptr [rsp + 48], rax
        xor eax, eax
        mov qword ptr [rsp + 40], rax
        mov dword ptr [rsp + 32], ecx
        mov r9, rbx
        xor r8d, r8d
        lea rdx, [rip + .Lempty]
        lea rcx, [rsp + 56]
        call text_box
        mov esi, dword ptr [rsp + 80]   /* lh */
        mov eax, esi
        shr eax, 31
        add eax, esi
        sar eax, 1                      /* lh / 2 */
        mov rcx, rbx
        sar rcx, 32
        sub ecx, eax
        shl rcx, 32
        mov eax, ebx
        or rcx, rax
        mov rbx, rcx                    /* pos = (p.x, p.y - lh / 2) */
        mov qword ptr OV(OV_TE_POS), rcx
        mov rcx, qword ptr OV(OV_HWND)
        mov rdx, qword ptr OV(OV_HIMC)
        API ImmAssociateContext
        mov rcx, qword ptr OV(OV_HWND)  /* text_caret_create */
        xor edx, edx
        SCALE r8d, .Lk15, xmm0, xmm1
        mov r9d, esi
        API CreateCaret
        mov rcx, rbx
        mov edx, esi
        call ove_caret_place
        mov rcx, qword ptr OV(OV_HWND)
        API ShowCaret
        inc dword ptr OV(OV_ACT_VER)
        add rsp, 88
        pop rsi
        pop rbx
        ret
ENDF

/* void text_edit(int i): type into an existing text annotation again; it is hidden
 * while the editor shows it */
FUNC text_edit
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 32
        ENDPROLOG
        movsxd rbx, ecx
        ANNP rsi, rbx
        cmp dword ptr [rsi + AN_TOOL], T_TEXT
        jne .Lte_ret
        mov edi, dword ptr [rsi + AN_NTEXT]
        inc edi
        cmp edi, TEXT_MAX
        jg .Lte_ret
        cmp edi, dword ptr OV(OV_TE_CAP)
        jle .Lte_fits
        mov rcx, qword ptr OV(OV_TE_BUF)
        movsxd rdx, edi
        add rdx, rdx
        call mem_grow
        test rax, rax
        jz .Lte_ret
        mov qword ptr OV(OV_TE_BUF), rax
        mov dword ptr OV(OV_TE_CAP), edi
.Lte_fits:
        mov ecx, ebx
        call pick_set
        ANNP rax, rbx
        mov ecx, dword ptr [rax + AN_SIZE]
        mov dword ptr OV(OV_TE_PX), ecx
        mov ecx, dword ptr [rax + AN_COLOR]
        mov dword ptr OV(OV_TE_COLOR), ecx
        mov rcx, qword ptr [rax + AN_PT]
        mov rcx, qword ptr [rcx]
        mov qword ptr OV(OV_TE_POS), rcx
        mov byte ptr OV(OV_TE_ON), 1
        lea edx, [rbx + 1]
        mov dword ptr OV(OV_TE_EDIT1), edx
        movsxd rcx, dword ptr [rax + AN_NTEXT]
        mov dword ptr OV(OV_TE_LEN), ecx
        mov rsi, qword ptr [rax + AN_TEXT]
        mov rdi, qword ptr OV(OV_TE_BUF)
        add rcx, rcx
        rep movsb
        mov rcx, qword ptr OV(OV_HWND)
        mov rdx, qword ptr OV(OV_HIMC)
        API ImmAssociateContext
        call text_caret_create
        inc dword ptr OV(OV_ACT_VER)
.Lte_ret:
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void text_end(bool keep) */
FUNC text_end
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 88
        ENDPROLOG
        cmp byte ptr OV(OV_TE_ON), 0
        je .Ltn_ret
        movzx r12d, cl                  /* keep */
        mov byte ptr OV(OV_TE_ON), 0
        API DestroyCaret
        mov rcx, qword ptr OV(OV_HWND)
        mov edx, TIMER_CARET
        API KillTimer
        mov rcx, qword ptr OV(OV_HWND)
        xor edx, edx
        API ImmAssociateContext
        mov rcx, qword ptr OV(OV_TE_BUF) /* blank: only spaces and newlines */
        movsxd rdx, dword ptr OV(OV_TE_LEN)
        mov esi, 1
        test rdx, rdx
        jle .Ltn_scanned
        lea rdx, [rcx + rdx*2]
.Ltn_scan:
        movzx eax, word ptr [rcx]
        cmp eax, 0x20
        je .Ltn_scan_next
        cmp eax, 0x0A
        je .Ltn_scan_next
        xor esi, esi
        jmp .Ltn_scanned
.Ltn_scan_next:
        add rcx, 2
        cmp rcx, rdx
        jb .Ltn_scan
.Ltn_scanned:
        mov ebx, dword ptr OV(OV_TE_EDIT1)
        dec ebx                         /* e */
        mov dword ptr OV(OV_TE_EDIT1), 0
        test ebx, ebx
        js .Ltn_new
        cmp ebx, dword ptr OV(OV_NANN)
        jge .Ltn_new
        test r12d, r12d                 /* editing an existing one */
        jz .Ltn_unpick
        movsxd rax, ebx
        ANNP rdi, rax
        test esi, esi
        jz .Ltn_changed
        cmp dword ptr OV(OV_PICK), ebx  /* kept blank: deleted */
        jne .Ltn_unpick
        call pick_delete
        jmp .Ltn_unpick
.Ltn_changed:
        mov eax, dword ptr OV(OV_TE_LEN)
        cmp dword ptr [rdi + AN_NTEXT], eax
        jne .Ltn_store
        mov ecx, dword ptr OV(OV_TE_PX)
        cmp dword ptr [rdi + AN_SIZE], ecx
        jne .Ltn_store
        mov ecx, dword ptr OV(OV_TE_COLOR)
        cmp dword ptr [rdi + AN_COLOR], ecx
        jne .Ltn_store
        mov rcx, qword ptr [rdi + AN_TEXT]
        mov rdx, qword ptr OV(OV_TE_BUF)
        xor r8d, r8d                    /* len > 0: not blank */
.Ltn_cmp:
        movzx r9d, word ptr [rcx + r8*2]
        cmp r9w, word ptr [rdx + r8*2]
        jne .Ltn_store
        inc r8
        cmp r8, rax
        jb .Ltn_cmp
        jmp .Ltn_unpick                 /* unchanged: no step */
.Ltn_store:
        mov rcx, qword ptr OV(OV_TE_BUF)
        mov edx, dword ptr OV(OV_TE_LEN)
        call wcs_dup
        mov rsi, rax
        test rax, rax
        jz .Ltn_unpick
        lea rcx, [rsp + 32]
        mov rdx, rdi
        call anno_copy
        test al, al
        jz .Ltn_nocopy
        mov rcx, qword ptr [rdi + AN_TEXT]
        call mem_free
        mov qword ptr [rdi + AN_TEXT], rsi
        mov eax, dword ptr OV(OV_TE_LEN)
        mov dword ptr [rdi + AN_NTEXT], eax
        mov eax, dword ptr OV(OV_TE_PX)
        mov dword ptr [rdi + AN_SIZE], eax
        mov eax, dword ptr OV(OV_TE_COLOR)
        mov dword ptr [rdi + AN_COLOR], eax
        mov ecx, OP_EDIT
        mov edx, ebx
        lea r8, [rsp + 32]
        call op_push
        jmp .Ltn_unpick
.Ltn_nocopy:
        mov rcx, rsi
        call mem_free
.Ltn_unpick:
        cmp dword ptr OV(OV_PICK), ebx
        jne .Ltn_done
        call pick_clear
        jmp .Ltn_done
.Ltn_new:
        test r12d, r12d
        jz .Ltn_done
        test esi, esi
        jnz .Ltn_done
        lea rdi, [rsp + 32]             /* a new text annotation */
        ZERO48 rdi
        mov dword ptr [rdi + AN_TOOL], T_TEXT
        mov eax, dword ptr OV(OV_TE_COLOR)
        mov dword ptr [rdi + AN_COLOR], eax
        mov eax, dword ptr OV(OV_TE_PX)
        mov dword ptr [rdi + AN_SIZE], eax
        mov rcx, qword ptr OV(OV_TE_BUF)
        mov edx, dword ptr OV(OV_TE_LEN)
        call wcs_dup
        mov qword ptr [rdi + AN_TEXT], rax
        mov ecx, dword ptr OV(OV_TE_LEN)
        mov dword ptr [rdi + AN_NTEXT], ecx
        test rax, rax
        jz .Ltn_newfail
        mov rcx, rdi
        mov rdx, qword ptr OV(OV_TE_POS)
        call anno_push
        test al, al
        jz .Ltn_newfail
        mov rcx, rdi
        xor edx, edx
        call commit_anno
        jmp .Ltn_done
.Ltn_newfail:
        AFREE rdi
.Ltn_done:
        mov dword ptr OV(OV_TE_LEN), 0
        inc dword ptr OV(OV_ACT_VER)
.Ltn_ret:
        add rsp, 88
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void text_at(POINT p): click with the text tool: edit the text under p, or start one */
FUNC text_at
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        call anno_at
        test eax, eax
        js .Lta_begin
        movsxd rdx, eax
        ANNP r8, rdx
        cmp dword ptr [r8 + AN_TOOL], T_TEXT
        jne .Lta_begin
        mov ecx, eax
        add rsp, 32
        pop rbx
        jmp text_edit
.Lta_begin:
        mov rcx, rbx
        add rsp, 32
        pop rbx
        jmp text_begin
ENDF

/* void text_insert(const WCHAR *t, int n) */
FUNC text_insert
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        ALLOC 40
        ENDPROLOG
        mov rsi, rcx
        movsxd rax, edx
        mov ebx, dword ptr OV(OV_TE_LEN)
        test eax, eax
        jle .Lti_store
        lea r12, [rcx + rax*2]          /* end */
        mov rdi, qword ptr OV(OV_TE_BUF)
        mov r13d, dword ptr OV(OV_TE_CAP)
.Lti_loop:
        movzx r14d, word ptr [rsi]
        add rsi, 2
        cmp r14d, 0x0D                  /* \r: dropped */
        je .Lti_next
        cmp r14d, 0x09                  /* \t: a space */
        jne .Lti_ctl
        mov r14d, 0x20
.Lti_ctl:
        cmp r14d, 0x20
        jae .Lti_ok
        cmp r14d, 0x0A                  /* other controls but \n: dropped */
        jne .Lti_next
.Lti_ok:
        cmp ebx, TEXT_MAX
        jge .Lti_store
        lea eax, [rbx + 1]
        cmp eax, r13d
        jl .Lti_put
        lea eax, [r13 + r13]            /* cap = cap ? cap * 2 : 64 */
        mov ecx, 64
        test r13d, r13d
        cmovz eax, ecx
        mov dword ptr [rsp + 32], eax
        mov rcx, rdi
        movsxd rdx, eax
        add rdx, rdx
        call mem_grow
        test rax, rax
        jz .Lti_store
        mov rdi, rax
        mov r13d, dword ptr [rsp + 32]
        mov qword ptr OV(OV_TE_BUF), rdi
        mov dword ptr OV(OV_TE_CAP), r13d
.Lti_put:
        mov word ptr [rdi + rbx*2], r14w
        inc ebx
.Lti_next:
        cmp rsi, r12
        jb .Lti_loop
.Lti_store:
        mov dword ptr OV(OV_TE_LEN), ebx
        inc dword ptr OV(OV_ACT_VER)
        add rsp, 40
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        jmp text_caret_update
ENDF

/* void text_backspace(void): a surrogate pair goes as one */
FUNC text_backspace
        ENDPROLOG
        mov eax, dword ptr OV(OV_TE_LEN)
        test eax, eax
        jle .Ltb_ret
        dec eax
        jz .Ltb_set
        mov rcx, qword ptr OV(OV_TE_BUF)
        movzx edx, word ptr [rcx + rax*2]
        and edx, 0xFC00
        cmp edx, 0xDC00                 /* IS_LOW_SURROGATE */
        jne .Ltb_set
        movzx edx, word ptr [rcx + rax*2 - 2]
        and edx, 0xFC00
        cmp edx, 0xD800                 /* IS_HIGH_SURROGATE */
        jne .Ltb_set
        dec eax
.Ltb_set:
        mov dword ptr OV(OV_TE_LEN), eax
        inc dword ptr OV(OV_ACT_VER)
        jmp text_caret_update
.Ltb_ret:
        ret
ENDF

/* void text_paste(void): the clipboard's text up to its terminator */
FUNC text_paste
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        mov rcx, qword ptr OV(OV_HWND)
        API OpenClipboard
        test eax, eax
        jz .Ltp_ret
        mov ecx, W_CF_UNICODETEXT
        API GetClipboardData
        test rax, rax
        jz .Ltp_close
        mov rbx, rax
        mov rcx, rax
        API GlobalLock
        test rax, rax
        jz .Ltp_close
        mov rsi, rax
        mov rcx, rbx
        API GlobalSize
        shr rax, 1                      /* WCHARs that fit */
        xor edx, edx                    /* n */
        pxor xmm1, xmm1
        cmp rax, 8
        jb .Ltp_tail
        lea r8, [rax - 8]
.Ltp_vec:                               /* eight at a time, inside the block */
        movdqu xmm0, xmmword ptr [rsi + rdx*2]
        pcmpeqw xmm0, xmm1
        pmovmskb ecx, xmm0
        test ecx, ecx
        jnz .Ltp_zero
        add rdx, 8
        cmp rdx, r8
        jbe .Ltp_vec
.Ltp_tail:
        cmp rdx, rax
        jae .Ltp_len
        cmp word ptr [rsi + rdx*2], 0
        je .Ltp_len
        inc rdx
        jmp .Ltp_tail
.Ltp_zero:
        bsf ecx, ecx
        shr ecx, 1
        add rdx, rcx
.Ltp_len:
        mov rcx, rsi
        call text_insert
        mov rcx, rbx
        API GlobalUnlock
.Ltp_close:
        API CloseClipboard
.Ltp_ret:
        add rsp, 40
        pop rsi
        pop rbx
        ret
ENDF

/* ---- style of the pick ------------------------------------------------------------- */

/* int prop_tool(void): the size/color bar shows the picked annotation's style, else the tool's */
FUNC prop_tool
        ENDPROLOG
        movsxd rax, dword ptr OV(OV_PICK)
        test eax, eax
        js .Lpt_tool
        ANNP rcx, rax
        mov eax, dword ptr [rcx + AN_TOOL]
        ret
.Lpt_tool:
        mov eax, dword ptr OV(OV_TOOL)
        ret
ENDF

/* int prop_size_idx(void): the nearest of the three sizes */
FUNC prop_size_idx
        ENDPROLOG
        cmp byte ptr OV(OV_TE_ON), 0
        jne .Lpz_te
        movsxd rax, dword ptr OV(OV_PICK)
        test eax, eax
        js .Lpz_cur
        ANNP rdx, rax
        mov ecx, dword ptr [rdx + AN_TOOL]
        mov r8d, dword ptr [rdx + AN_SIZE]
        jmp .Lpz_find
.Lpz_te:
        mov ecx, T_TEXT
        mov r8d, dword ptr OV(OV_TE_PX)
.Lpz_find:
        TOOLTAB rdx, ecx, r9
        TOOLPX eax, [rdx], xmm0, xmm1
        sub eax, r8d
        mov r9d, eax
        neg eax
        cmovl eax, r9d
        mov r10d, eax                   /* |px(0) - size| */
        TOOLPX eax, [rdx+4], xmm0, xmm1
        sub eax, r8d
        mov r9d, eax
        neg eax
        cmovl eax, r9d
        mov r11d, eax
        TOOLPX eax, [rdx+8], xmm0, xmm1
        sub eax, r8d
        mov r9d, eax
        neg eax
        cmovl eax, r9d
        mov ecx, eax
        xor eax, eax
        cmp r11d, r10d
        jge .Lpz_2
        mov eax, 1
        mov r10d, r11d
.Lpz_2:
        cmp ecx, r10d
        jge .Lpz_ret
        mov eax, 2
.Lpz_ret:
        ret
.Lpz_cur:
        mov eax, dword ptr OV(OV_SIZE_IDX)
        ret
ENDF

/* int prop_color_idx(void): -1 if not one of the eight */
FUNC prop_color_idx
        ENDPROLOG
        cmp byte ptr OV(OV_TE_ON), 0
        jne .Lpo_te
        movsxd rax, dword ptr OV(OV_PICK)
        test eax, eax
        js .Lpo_cur
        ANNP rdx, rax
        mov ecx, dword ptr [rdx + AN_COLOR]
        jmp .Lpo_find
.Lpo_te:
        mov ecx, dword ptr OV(OV_TE_COLOR)
.Lpo_find:
        lea rdx, [rip + kColors]
        xor eax, eax
.Lpo_loop:
        cmp dword ptr [rdx + rax*4], ecx
        je .Lpo_ret
        inc eax
        cmp eax, 8
        jb .Lpo_loop
        mov eax, -1
.Lpo_ret:
        ret
.Lpo_cur:
        mov eax, dword ptr OV(OV_COLOR_IDX)
        ret
ENDF

/* void pick_style(int size_idx, int color_idx): restyle the pick (-1 keeps that part) */
FUNC pick_style
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 80
        ENDPROLOG
        movsxd rax, dword ptr OV(OV_PICK)
        test eax, eax
        js .Lst_ret
        ANNP rbx, rax
        mov r8d, dword ptr [rbx + AN_TOOL]
        mov esi, dword ptr [rbx + AN_SIZE]
        test ecx, ecx
        js .Lst_color
        movsxd rcx, ecx
        TOOLTAB r9, r8d, r10
        TOOLPX esi, [r9+rcx*4], xmm0, xmm1
.Lst_color:
        mov edi, dword ptr [rbx + AN_COLOR]
        test edx, edx
        js .Lst_cmp
        cmp r8d, T_MOSAIC               /* a mosaic has no color */
        je .Lst_cmp
        movsxd rdx, edx
        lea r9, [rip + kColors]
        mov edi, dword ptr [r9 + rdx*4]
.Lst_cmp:
        cmp esi, dword ptr [rbx + AN_SIZE]
        jne .Lst_do
        cmp edi, dword ptr [rbx + AN_COLOR]
        je .Lst_ret
.Lst_do:
        lea rcx, [rsp + 32]
        mov rdx, rbx
        call anno_copy
        test al, al
        jz .Lst_ret
        mov dword ptr [rbx + AN_SIZE], esi
        mov dword ptr [rbx + AN_COLOR], edi
        mov ecx, OP_EDIT
        mov edx, dword ptr OV(OV_PICK)
        lea r8, [rsp + 32]
        call op_push
        inc dword ptr OV(OV_ACT_VER)
.Lst_ret:
        add rsp, 80
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void pick_nudge(int dx, int dy): arrow keys move the pick; a run of presses is one step */
FUNC pick_nudge
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 80
        ENDPROLOG
        mov ebx, ecx
        mov esi, edx
        mov edi, dword ptr OV(OV_PICK)
        test edi, edi
        js .Lng_ret
        cmp byte ptr OV(OV_NUDGING), 0
        jne .Lng_move
        movsxd rax, edi
        ANNP rdx, rax
        lea rcx, [rsp + 32]
        call anno_copy
        test al, al
        jz .Lng_ret
        mov ecx, OP_EDIT
        mov edx, edi
        lea r8, [rsp + 32]
        call op_push
        test al, al
        jz .Lng_ret
        mov byte ptr OV(OV_NUDGING), 1
.Lng_move:
        movsxd rax, edi
        ANNP rdx, rax
        mov ecx, dword ptr [rdx + AN_NPT]
        mov rdx, qword ptr [rdx + AN_PT]
        movd xmm1, ebx
        movd xmm2, esi
        punpckldq xmm1, xmm2
        punpcklqdq xmm1, xmm1           /* dx, dy, dx, dy */
        cmp ecx, 2
        jl .Lng_tail
.Lng_two:
        movdqu xmm0, xmmword ptr [rdx]
        paddd xmm0, xmm1
        movdqu xmmword ptr [rdx], xmm0
        add rdx, 16
        sub ecx, 2
        cmp ecx, 2
        jge .Lng_two
.Lng_tail:
        test ecx, ecx
        jle .Lng_done
        movq xmm0, qword ptr [rdx]
        paddd xmm0, xmm1
        movq qword ptr [rdx], xmm0
.Lng_done:
        inc dword ptr OV(OV_ACT_VER)
.Lng_ret:
        add rsp, 80
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF
