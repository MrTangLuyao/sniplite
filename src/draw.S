/* draw.S: the software rasterizer (see draw.h) in x86-64 assembly.
 *
 * Every function produces exactly the pixels of the C code it replaced
 * (tests/ref/draw.c); tests/draw_test.c compares the two bit for bit on random
 * input, on every CPU path. Floating point follows the C evaluation order
 * operation by operation, so results match to the last bit.
 *
 * The baseline is SSE2, which every x86-64 CPU has. Where it pays, an AVX2 path
 * is chosen at run time: draw_cpu is 0 = not probed yet, 1 = SSE2, 2 = AVX2.
 *
 * Faster than the C original by construction, not only by instructions: rows of
 * an arrow or polygon only visit the span its edges allow (the C walked the whole
 * bounding box), a stroke's mask skips empty runs eight bytes at a time, and the
 * hot loops run eight pixels per step with AVX2. */
#include "asm.inc"

        .section .rdata,"dr"
        .balign 32
.Lv_half:       .rept 8
                .long 0x3F000000        /* 0.5f */
                .endr
.Lv_one:        .rept 8
                .long 0x3F800000        /* 1.0f */
                .endr
.Lv_255:        .rept 8
                .long 0x437F0000        /* 255.0f */
                .endr
.Lv_bytemask:   .rept 8
                .long 0xFF
                .endr
.Lv_eight:      .rept 8
                .long 8
                .endr
.Lv_iota:       .long 0, 1, 2, 3, 4, 5, 6, 7
.Lv_lanes:      .long 0, 0, 0, 0, 0, 0, 0, 0    /* row k: the first k lanes selected */
                .long -1, 0, 0, 0, 0, 0, 0, 0
                .long -1, -1, 0, 0, 0, 0, 0, 0
                .long -1, -1, -1, 0, 0, 0, 0, 0
                .long -1, -1, -1, -1, 0, 0, 0, 0
                .long -1, -1, -1, -1, -1, 0, 0, 0
                .long -1, -1, -1, -1, -1, -1, 0, 0
                .long -1, -1, -1, -1, -1, -1, -1, 0
.Lv_1em9:       .rept 8
                .long 0x3089705F        /* 1e-9f */
                .endr
.Lv_256d:       .rept 8
                .long 256
                .endr
.Lv_256w:       .rept 16
                .short 256
                .endr
.Lv_alpha:      .rept 8
                .long 0xFF000000
                .endr
/* vpshufb: a pixel's 16-bit weight (from its dword) into the four channel words
 * of pixels 0-1 (wlo) or 2-3 (whi) of each 128-bit lane */
.Lv_wlo:        .byte 0, 1, 0, 1, 0, 1, 0, 1, 4, 5, 4, 5, 4, 5, 4, 5
                .byte 0, 1, 0, 1, 0, 1, 0, 1, 4, 5, 4, 5, 4, 5, 4, 5
.Lv_whi:        .byte 8, 9, 8, 9, 8, 9, 8, 9, 12, 13, 12, 13, 12, 13, 12, 13
                .byte 8, 9, 8, 9, 8, 9, 8, 9, 12, 13, 12, 13, 12, 13, 12, 13
.Lk_7f:         .long 0x7F7F7F, 0x7F7F7F, 0x7F7F7F, 0x7F7F7F
.Lk_0f:         .long 0x0F0F0F, 0x0F0F0F, 0x0F0F0F, 0x0F0F0F
.Lk_b:          .long 0x0000FF, 0x0000FF, 0x0000FF, 0x0000FF
.Lk_g:          .long 0x00FF00, 0x00FF00, 0x00FF00, 0x00FF00
.Lk_r:          .long 0xFF0000, 0xFF0000, 0xFF0000, 0xFF0000
.Lk_alpha:      .long 0xFF000000, 0xFF000000, 0xFF000000, 0xFF000000
.Lk_abs:        .long 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF
.Lk_sign:       .long 0x80000000, 0x80000000, 0x80000000, 0x80000000
.Lf_1em6:       .long 0x358637BD    /* 1e-6f */
.Lf_1em3:       .long 0x3A83126F    /* 1e-3f */
.Lf_1em4:       .long 0x38D1B717    /* 1e-4f */
.Lf_1em9:       .long 0x3089705F    /* 1e-9f */
.Lf_001:        .long 0x3C23D70A    /* 0.01f */
.Lf_075:        .long 0x3F400000    /* 0.75f */
.Lf_1e30:       .long 0x7149F2CA    /* 1e30f */
.Lf_m1e30:      .long 0xF149F2CA    /* -1e30f */
.Lf_20:         .long 0x41A00000    /* 20.0f */
.Lf_16:         .long 0x41800000    /* 16.0f */
.Lf_1_6:        .long 0x3FCCCCCD    /* 1.6f */
.Lf_1_25:       .long 0x3FA00000    /* 1.25f */
.Lf_1_15:       .long 0x3F933333    /* 1.15f */
.Lf_1_1:        .long 0x3F8CCCCD    /* 1.1f */
.Lf_5:          .long 0x40A00000    /* 5.0f */
.Lf_3:          .long 0x40400000    /* 3.0f */
.Lf_8:          .long 0x41000000    /* 8.0f */
.Lf_0_7:        .long 0x3F333333    /* 0.7f */
.Lf_0_6:        .long 0x3F19999A    /* 0.6f */
.Lf_0_2:        .long 0x3E4CCCCD    /* 0.2f */

        .bss
        .balign 8
g_mask:         .space 8                /* coverage mask of d_polyline, kept between calls */
g_mask_cap:     .space 8
        .globl draw_cpu
draw_cpu:       .space 4

/* ---- CPU level ------------------------------------------------------------------ */

/* eax = 1 (SSE2) or 2 (AVX2 usable); also stored in draw_cpu. Keeps every other register. */
SFUNC cpu_probe
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
        ret
ENDF

.macro CPU_LEVEL                        /* eax = draw_cpu, probing on first use */
        mov eax, dword ptr [rip + draw_cpu]
        test eax, eax
        jnz 98f
        call cpu_probe
98:
.endm

/* ---- pixel helpers -------------------------------------------------------------- */

/* [ptr] = d*(256-w)/256 + col*w/256 per channel, alpha 255; w in 1..255 (a 32-bit reg). */
.macro BLEND ptr, col, w, t1, t2, t3
        mov \t1, 256
        sub \t1, \w                     /* 256 - w */
        mov \t2, dword ptr [\ptr]
        mov \t3, \t2
        and \t2, 0xFF00FF
        imul \t2, \t1
        and \t3, 0x00FF00
        imul \t3, \t1
        mov \t1, \col
        and \t1, 0xFF00FF
        imul \t1, \w
        add \t2, \t1
        shr \t2, 8
        and \t2, 0xFF00FF
        mov \t1, \col
        and \t1, 0x00FF00
        imul \t1, \w
        add \t3, \t1
        shr \t3, 8
        and \t3, 0x00FF00
        or \t2, \t3
        or \t2, 0xFF000000
        mov dword ptr [\ptr], \t2
.endm

/* plot(): v = (int)(cov * a + 0.5); nothing if v <= 0, opaque if v >= 255, else blend
 * with weight v + (v >> 7). cov (xmm, clobbered), af = (float)a, half = 0.5f. */
.macro PLOT ptr, col, cov, af, half, t0, t1, t2, t3, t4
        mulss \cov, \af
        addss \cov, \half
        cvttss2si \t0, \cov
        test \t0, \t0
        jle 96f
        cmp \t0, 255
        jl 95f
        mov \t1, \col
        or \t1, 0xFF000000
        mov dword ptr [\ptr], \t1
        jmp 96f
95:     mov \t1, \t0
        shr \t1, 7
        add \t0, \t1
        BLEND \ptr, \col, \t0, \t1, \t2, \t3
96:
.endm

/* plot() for eight pixels at rdi (AVX2), exactly as the scalar PLOT per lane: lanes
 * of `mask` (dwords) with v = (int)(cov * a + 0.5) > 0 are blended with weight
 * w = v + (v >> 7), capped at 256 (which yields the opaque color like v >= 255 does).
 * The blend runs on 16-bit channels: (c * w + d * (256 - w)) >> 8, which is what the
 * scalar 32-bit formula computes per channel. Masked loads and stores never touch
 * other lanes, so a vector may run past the end of a row. cw = frame offset of the
 * color as 16 words (B, G, R, A, twice per lane). Uses ymm0, ymm1, ymm4, ymm5, eax;
 * cov and mask are clobbered. */
.macro PLOT8 cov, mask, af, half, cw
        vmulps ymm0, \cov, \af
        vaddps ymm0, ymm0, \half
        vcvttps2dq ymm0, ymm0                   /* v */
        vpxor ymm1, ymm1, ymm1
        vpcmpgtd ymm1, ymm0, ymm1               /* v > 0 */
        vpand \mask, \mask, ymm1
        vmovmskps eax, \mask
        test eax, eax
        jz 94f
        vpsrld ymm1, ymm0, 7
        vpaddd ymm0, ymm0, ymm1
        vpminsd ymm0, ymm0, ymmword ptr [rip + .Lv_256d]        /* w */
        vpmaskmovd \cov, \mask, ymmword ptr [rdi]               /* destination */
        vpshufb ymm1, ymm0, ymmword ptr [rip + .Lv_wlo]
        vpshufb ymm0, ymm0, ymmword ptr [rip + .Lv_whi]
        vpxor ymm5, ymm5, ymm5
        vpunpcklbw ymm4, \cov, ymm5
        vpunpckhbw \cov, \cov, ymm5
        vmovdqu ymm5, ymmword ptr [rip + .Lv_256w]
        vpsubw ymm5, ymm5, ymm1                 /* 256 - w */
        vpmullw ymm4, ymm4, ymm5
        vpmullw ymm1, ymm1, ymmword ptr [rsp + \cw]
        vpaddw ymm4, ymm4, ymm1
        vpsrlw ymm4, ymm4, 8
        vmovdqu ymm5, ymmword ptr [rip + .Lv_256w]
        vpsubw ymm5, ymm5, ymm0
        vpmullw \cov, \cov, ymm5
        vpmullw ymm0, ymm0, ymmword ptr [rsp + \cw]
        vpaddw \cov, \cov, ymm0
        vpsrlw \cov, \cov, 8
        vpackuswb ymm4, ymm4, \cov
        vpor ymm4, ymm4, ymmword ptr [rip + .Lv_alpha]
        vpmaskmovd ymmword ptr [rdi], \mask, ymm4
94:
.endm

/* [rsp + cw] = the color in eax as 16 words for PLOT8 (AVX2) */
.macro COLOR_WORDS cw
        vmovd xmm0, eax
        vpbroadcastd ymm0, xmm0
        vpxor ymm1, ymm1, ymm1
        vpunpcklbw ymm0, ymm0, ymm1
        vmovdqu ymmword ptr [rsp + \cw], ymm0
        vzeroupper
.endm

/* ---- void d_dim_row(uint32_t *d, const uint32_t *s, int n) -------------------------
 * d[i] = ((s[i] & 0xFEFEFE) >> 1) + ((s[i] & 0xF0F0F0) >> 4): 56% brightness. */

FUNC d_dim_row
        ENDPROLOG
        test r8d, r8d
        jle .Ldr_ret
        CPU_LEVEL
        cmp eax, 2
        jne .Ldr_sse
        cmp r8d, 8
        jb .Ldr_sse
        vpbroadcastd ymm4, dword ptr [rip + .Lk_7f]
        vpbroadcastd ymm5, dword ptr [rip + .Lk_0f]
        mov eax, r8d
        shr eax, 4                      /* 16 pixels per round */
        jz .Ldr_a8
.Ldr_a16:
        vmovdqu ymm0, ymmword ptr [rdx]
        vmovdqu ymm1, ymmword ptr [rdx + 32]
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
        vmovdqu ymmword ptr [rcx], ymm0
        vmovdqu ymmword ptr [rcx + 32], ymm1
        add rdx, 64
        add rcx, 64
        dec eax
        jnz .Ldr_a16
.Ldr_a8:
        test r8d, 8
        jz .Ldr_at
        vmovdqu ymm0, ymmword ptr [rdx]
        vpsrld ymm2, ymm0, 1
        vpsrld ymm0, ymm0, 4
        vpand ymm2, ymm2, ymm4
        vpand ymm0, ymm0, ymm5
        vpaddd ymm0, ymm0, ymm2
        vmovdqu ymmword ptr [rcx], ymm0
        add rdx, 32
        add rcx, 32
.Ldr_at:
        and r8d, 7
        jz .Ldr_avx_done
        /* the last 1..7 pixels: redo the final 8 (source and destination never overlap) */
        vmovdqu ymm0, ymmword ptr [rdx + r8*4 - 32]
        vpsrld ymm2, ymm0, 1
        vpsrld ymm0, ymm0, 4
        vpand ymm2, ymm2, ymm4
        vpand ymm0, ymm0, ymm5
        vpaddd ymm0, ymm0, ymm2
        vmovdqu ymmword ptr [rcx + r8*4 - 32], ymm0
.Ldr_avx_done:
        vzeroupper
        ret
.Ldr_sse:
        movdqa xmm4, xmmword ptr [rip + .Lk_7f]
        movdqa xmm5, xmmword ptr [rip + .Lk_0f]
        mov eax, r8d
        shr eax, 2
        jz .Ldr_s1
.Ldr_s4:
        movdqu xmm0, xmmword ptr [rdx]
        movdqa xmm1, xmm0
        psrld xmm0, 4
        psrld xmm1, 1
        pand xmm0, xmm5
        pand xmm1, xmm4
        paddd xmm0, xmm1
        movdqu xmmword ptr [rcx], xmm0
        add rdx, 16
        add rcx, 16
        dec eax
        jnz .Ldr_s4
.Ldr_s1:
        and r8d, 3
        jz .Ldr_ret
.Ldr_s1_loop:
        mov eax, dword ptr [rdx]
        mov r9d, eax
        shr eax, 1
        shr r9d, 4
        and eax, 0x7F7F7F
        and r9d, 0x0F0F0F
        add eax, r9d
        mov dword ptr [rcx], eax
        add rdx, 4
        add rcx, 4
        dec r8d
        jnz .Ldr_s1_loop
.Ldr_ret:
        ret
ENDF

/* ---- void d_fill(const Surf *s, RECT r, uint32_t c) ---------------------------------
 * rcx = s, rdx = &r, r8d = color. Leaf: uses no stack. */

FUNC d_fill
        ENDPROLOG
        mov eax, dword ptr [rdx + RC_L]
        mov r9d, dword ptr [rdx + RC_T]
        mov r10d, dword ptr [rdx + RC_R]
        mov r11d, dword ptr [rdx + RC_B]
        cmp eax, dword ptr [rcx + SURF_CL]
        cmovl eax, dword ptr [rcx + SURF_CL]
        cmp r9d, dword ptr [rcx + SURF_CT]
        cmovl r9d, dword ptr [rcx + SURF_CT]
        cmp r10d, dword ptr [rcx + SURF_CR]
        cmovg r10d, dword ptr [rcx + SURF_CR]
        cmp r11d, dword ptr [rcx + SURF_CB]
        cmovg r11d, dword ptr [rcx + SURF_CB]
        cmp r10d, eax
        jle .Lfi_ret
        cmp r11d, r9d
        jle .Lfi_ret
        sub r10d, eax                   /* width */
        sub r11d, r9d                   /* height */
        or r8d, 0xFF000000
        sub r9d, dword ptr [rcx + SURF_OY]
        movsxd r9, r9d
        movsxd rdx, dword ptr [rcx + SURF_STRIDE]
        imul r9, rdx
        sub eax, dword ptr [rcx + SURF_OX]
        cdqe
        add r9, rax
        mov rax, qword ptr [rcx + SURF_PX]
        lea r9, [rax + r9*4]            /* first pixel */
        shl rdx, 2                      /* bytes per row */
        cmp r10d, 4
        jb .Lfi_narrow
        movd xmm0, r8d
        pshufd xmm0, xmm0, 0
        lea ecx, [r10 - 4]              /* where the last, possibly overlapping, store goes */
.Lfi_row:
        mov rax, r9
        mov r8d, r10d
        shr r8d, 2
.Lfi_4:
        movdqu xmmword ptr [rax], xmm0
        add rax, 16
        dec r8d
        jnz .Lfi_4
        movdqu xmmword ptr [r9 + rcx*4], xmm0
        add r9, rdx
        dec r11d
        jnz .Lfi_row
        ret
.Lfi_narrow:                            /* 1 to 3 pixels wide */
        mov rax, r9
        mov ecx, r10d
.Lfi_n1:
        mov dword ptr [rax], r8d
        add rax, 4
        dec ecx
        jnz .Lfi_n1
        add r9, rdx
        dec r11d
        jnz .Lfi_narrow
.Lfi_ret:
        ret
ENDF

/* ---- void d_fill_alpha(const Surf *s, RECT r, uint32_t c, int a) -----------------------
 * Each channel becomes (c * w + d * (256 - w)) >> 8 with w = a + (a >> 7). */

FUNC d_fill_alpha
        cmp r9d, 255
        jge d_fill
        test r9d, r9d
        jle .Lfa_ret
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG rbp
        ENDPROLOG
        mov eax, dword ptr [rdx + RC_L]
        mov r10d, dword ptr [rdx + RC_T]
        mov r11d, dword ptr [rdx + RC_R]
        mov ebx, dword ptr [rdx + RC_B]
        cmp eax, dword ptr [rcx + SURF_CL]
        cmovl eax, dword ptr [rcx + SURF_CL]
        cmp r10d, dword ptr [rcx + SURF_CT]
        cmovl r10d, dword ptr [rcx + SURF_CT]
        cmp r11d, dword ptr [rcx + SURF_CR]
        cmovg r11d, dword ptr [rcx + SURF_CR]
        cmp ebx, dword ptr [rcx + SURF_CB]
        cmovg ebx, dword ptr [rcx + SURF_CB]
        cmp r11d, eax
        jle .Lfa_pop
        cmp ebx, r10d
        jle .Lfa_pop
        sub r11d, eax                   /* width */
        sub ebx, r10d                   /* height */
        sub r10d, dword ptr [rcx + SURF_OY]
        movsxd r10, r10d
        movsxd rdx, dword ptr [rcx + SURF_STRIDE]
        imul r10, rdx
        sub eax, dword ptr [rcx + SURF_OX]
        cdqe
        add r10, rax
        mov rax, qword ptr [rcx + SURF_PX]
        lea rsi, [rax + r10*4]          /* first pixel */
        shl rdx, 2                      /* bytes per row */
        mov eax, r9d
        shr eax, 7
        add r9d, eax                    /* w */
        mov r10d, 256
        sub r10d, r9d                   /* 256 - w */
        mov edi, r8d
        and edi, 0xFF00FF
        imul edi, r9d                   /* red and blue of c, times w */
        mov ecx, r8d
        and ecx, 0x00FF00
        imul ecx, r9d                   /* green of c, times w */
        pxor xmm5, xmm5
        mov eax, r8d
        and eax, 0xFFFFFF
        movd xmm3, eax
        punpcklbw xmm3, xmm5
        punpcklqdq xmm3, xmm3           /* B, G, R, 0 as words, twice */
        movd xmm1, r9d
        pshuflw xmm1, xmm1, 0
        punpcklqdq xmm1, xmm1
        pmullw xmm3, xmm1               /* c * w per channel */
        movd xmm4, r10d
        pshuflw xmm4, xmm4, 0
        punpcklqdq xmm4, xmm4           /* 256 - w in every word */
        movdqa xmm2, xmmword ptr [rip + .Lk_alpha]
.Lfa_row:
        mov rax, rsi
        mov r8d, r11d
        cmp r8d, 4
        jb .Lfa_tail
.Lfa_4:
        movdqu xmm0, xmmword ptr [rax]
        movdqa xmm1, xmm0
        punpcklbw xmm0, xmm5
        punpckhbw xmm1, xmm5
        pmullw xmm0, xmm4
        pmullw xmm1, xmm4
        paddw xmm0, xmm3
        paddw xmm1, xmm3
        psrlw xmm0, 8
        psrlw xmm1, 8
        packuswb xmm0, xmm1
        por xmm0, xmm2
        movdqu xmmword ptr [rax], xmm0
        add rax, 16
        sub r8d, 4
        cmp r8d, 4
        jae .Lfa_4
.Lfa_tail:
        test r8d, r8d
        jz .Lfa_next
.Lfa_1:
        mov r9d, dword ptr [rax]
        mov ebp, r9d
        and r9d, 0xFF00FF
        imul r9d, r10d
        add r9d, edi
        shr r9d, 8
        and r9d, 0xFF00FF
        and ebp, 0x00FF00
        imul ebp, r10d
        add ebp, ecx
        shr ebp, 8
        and ebp, 0x00FF00
        or r9d, ebp
        or r9d, 0xFF000000
        mov dword ptr [rax], r9d
        add rax, 4
        dec r8d
        jnz .Lfa_1
.Lfa_next:
        add rsi, rdx
        dec ebx
        jnz .Lfa_row
.Lfa_pop:
        pop rbp
        pop rdi
        pop rsi
        pop rbx
.Lfa_ret:
        ret
ENDF

/* ---- void d_frame(const Surf *s, RECT r, int t, uint32_t c) ------------------------------
 * A border of thickness t inside r: four fills. */

FUNC d_frame
        mov eax, dword ptr [rdx + RC_R]
        cmp eax, dword ptr [rdx + RC_L]
        jle .Lfr_ret
        mov r10d, dword ptr [rdx + RC_B]
        cmp r10d, dword ptr [rdx + RC_T]
        jle .Lfr_ret
        test r8d, r8d
        jle .Lfr_ret
        sub eax, dword ptr [rdx + RC_L]         /* width */
        sub r10d, dword ptr [rdx + RC_T]        /* height */
        lea r11d, [r8 + r8]
        cmp r11d, eax
        jge 1f
        cmp r11d, r10d
        jl 2f
1:      mov r8d, r9d                            /* too thick for a hole: one fill */
        jmp d_fill
2:      ALLOC 0x58
        ENDPROLOG
        mov qword ptr [rsp + 0x30], rcx         /* s */
        mov qword ptr [rsp + 0x38], rdx         /* &r */
        mov dword ptr [rsp + 0x40], r8d         /* t */
        mov dword ptr [rsp + 0x44], r9d         /* color */
        /* top: left, top, right, top + t */
        mov eax, dword ptr [rdx + RC_L]
        mov dword ptr [rsp + 0x20], eax
        mov eax, dword ptr [rdx + RC_R]
        mov dword ptr [rsp + 0x28], eax
        mov eax, dword ptr [rdx + RC_T]
        mov dword ptr [rsp + 0x24], eax
        add eax, r8d
        mov dword ptr [rsp + 0x2C], eax
        lea rdx, [rsp + 0x20]
        mov r8d, r9d
        call d_fill
        /* bottom: left, bottom - t, right, bottom */
        mov rdx, qword ptr [rsp + 0x38]
        mov eax, dword ptr [rdx + RC_B]
        mov dword ptr [rsp + 0x2C], eax
        sub eax, dword ptr [rsp + 0x40]
        mov dword ptr [rsp + 0x24], eax
        mov rcx, qword ptr [rsp + 0x30]
        lea rdx, [rsp + 0x20]
        mov r8d, dword ptr [rsp + 0x44]
        call d_fill
        /* left: left, top + t, left + t, bottom - t */
        mov rdx, qword ptr [rsp + 0x38]
        mov eax, dword ptr [rdx + RC_T]
        add eax, dword ptr [rsp + 0x40]
        mov dword ptr [rsp + 0x24], eax
        mov eax, dword ptr [rdx + RC_B]
        sub eax, dword ptr [rsp + 0x40]
        mov dword ptr [rsp + 0x2C], eax
        mov eax, dword ptr [rdx + RC_L]
        mov dword ptr [rsp + 0x20], eax
        add eax, dword ptr [rsp + 0x40]
        mov dword ptr [rsp + 0x28], eax
        mov rcx, qword ptr [rsp + 0x30]
        lea rdx, [rsp + 0x20]
        mov r8d, dword ptr [rsp + 0x44]
        call d_fill
        /* right: right - t, top + t, right, bottom - t (top and bottom still set) */
        mov rdx, qword ptr [rsp + 0x38]
        mov eax, dword ptr [rdx + RC_R]
        mov dword ptr [rsp + 0x28], eax
        sub eax, dword ptr [rsp + 0x40]
        mov dword ptr [rsp + 0x20], eax
        mov rcx, qword ptr [rsp + 0x30]
        lea rdx, [rsp + 0x20]
        mov r8d, dword ptr [rsp + 0x44]
        call d_fill
        add rsp, 0x58
.Lfr_ret:
        ret
ENDF

/* ---- void d_dash_frame(const Surf *s, RECT r, uint32_t c1, uint32_t c2, int dash) -------
 * One-pixel outline alternating c1 and c2 every `dash` pixels. */

FUNC d_dash_frame
        mov eax, dword ptr [rdx + RC_R]
        cmp eax, dword ptr [rdx + RC_L]
        jle .Ldf_ret0
        mov eax, dword ptr [rdx + RC_B]
        cmp eax, dword ptr [rdx + RC_T]
        jle .Ldf_ret0
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        PUSHREG rbp
        ENDPROLOG
        mov ebx, dword ptr [rsp + 40 + 64]      /* dash */
        mov eax, 1
        cmp ebx, 1
        cmovl ebx, eax
        or r8d, 0xFF000000                      /* c1 */
        or r9d, 0xFF000000
        xor r9d, r8d                            /* c1 ^ c2: toggles the color */
        mov r10d, dword ptr [rdx + RC_L]
        mov r11d, dword ptr [rdx + RC_T]
        mov esi, dword ptr [rdx + RC_R]
        mov edi, dword ptr [rdx + RC_B]
        movsxd r12, dword ptr [rcx + SURF_STRIDE]
        movsxd r13, dword ptr [rcx + SURF_OX]
        mov r14, qword ptr [rcx + SURF_PX]
        /* rax, rdx = address of pixel (0, y) on the top and the bottom row, 0 when clipped away */
        xor eax, eax
        cmp r11d, dword ptr [rcx + SURF_CT]
        jl 1f
        cmp r11d, dword ptr [rcx + SURF_CB]
        jge 1f
        mov eax, r11d
        sub eax, dword ptr [rcx + SURF_OY]
        cdqe
        imul rax, r12
        sub rax, r13
        lea rax, [r14 + rax*4]
1:
        xor edx, edx
        lea ebp, [rdi - 1]
        cmp ebp, dword ptr [rcx + SURF_CT]
        jl 2f
        cmp ebp, dword ptr [rcx + SURF_CB]
        jge 2f
        sub ebp, dword ptr [rcx + SURF_OY]
        movsxd rdx, ebp
        imul rdx, r12
        sub rdx, r13
        lea rdx, [r14 + rdx*4]
2:
        mov r15d, ebx                           /* pixels left in this dash */
        mov ebp, r8d                            /* current color */
        movsxd r13, r10d                        /* x */
        movsxd r14, esi                         /* right */
.Ldf_h:
        cmp r13d, dword ptr [rcx + SURF_CL]
        jl .Ldf_hn
        cmp r13d, dword ptr [rcx + SURF_CR]
        jge .Ldf_hn
        test rax, rax
        jz 3f
        mov dword ptr [rax + r13*4], ebp
3:
        test rdx, rdx
        jz .Ldf_hn
        mov dword ptr [rdx + r13*4], ebp
.Ldf_hn:
        dec r15d
        jnz 4f
        mov r15d, ebx
        xor ebp, r9d
4:
        inc r13
        cmp r13, r14
        jl .Ldf_h
        /* the two columns */
        mov eax, r11d
        sub eax, dword ptr [rcx + SURF_OY]
        cdqe
        imul rax, r12
        movsxd r13, dword ptr [rcx + SURF_OX]
        sub rax, r13
        mov r14, qword ptr [rcx + SURF_PX]
        lea rax, [r14 + rax*4]                  /* pixel (0, top) */
        lea rdx, [r12*4]                        /* bytes per row */
        xor r13d, r13d                          /* left column inside the clip? */
        cmp r10d, dword ptr [rcx + SURF_CL]
        jl 5f
        cmp r10d, dword ptr [rcx + SURF_CR]
        jge 5f
        mov r13d, 1
5:
        movsxd r10, r10d
        lea r12d, [rsi - 1]
        xor r14d, r14d                          /* right column inside the clip? */
        cmp r12d, dword ptr [rcx + SURF_CL]
        jl 6f
        cmp r12d, dword ptr [rcx + SURF_CR]
        jge 6f
        mov r14d, 1
6:
        movsxd r12, r12d
        mov r15d, ebx
        mov ebp, r8d
.Ldf_v:
        cmp r11d, dword ptr [rcx + SURF_CT]
        jl .Ldf_vn
        cmp r11d, dword ptr [rcx + SURF_CB]
        jge .Ldf_vn
        test r13d, r13d
        jz 7f
        mov dword ptr [rax + r10*4], ebp
7:
        test r14d, r14d
        jz .Ldf_vn
        mov dword ptr [rax + r12*4], ebp
.Ldf_vn:
        dec r15d
        jnz 8f
        mov r15d, ebx
        xor ebp, r9d
8:
        add rax, rdx
        inc r11d
        cmp r11d, edi
        jl .Ldf_v
        pop rbp
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
.Ldf_ret0:
        ret
ENDF

/* ---- void d_mosaic(const Surf *dst, const Surf *src, RECT r, int b) -------------------------
 * Every b x b block of r becomes the average of its source pixels. The grid is
 * anchored at r's top-left corner. */

#define MO_FILL 0x20            /* RECT handed to d_fill */
#define MO_AL 0x30              /* area = r, clipped to both surfaces */
#define MO_AT 0x34
#define MO_AR 0x38
#define MO_AB 0x3C
#define MO_BX0 0x40
#define MO_CNT 0x44

.macro MOS_ACC                  /* add the B, G and R bytes of xmm0 to xmm2, xmm3, xmm4 */
        movdqa xmm1, xmm0
        pand xmm1, xmmword ptr [rip + .Lk_b]
        psadbw xmm1, xmm5
        paddq xmm2, xmm1
        movdqa xmm1, xmm0
        pand xmm1, xmmword ptr [rip + .Lk_g]
        psadbw xmm1, xmm5
        paddq xmm3, xmm1
        pand xmm0, xmmword ptr [rip + .Lk_r]
        psadbw xmm0, xmm5
        paddq xmm4, xmm0
.endm

FUNC d_mosaic
        PUSHREG rbx
        PUSHREG rbp
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 0x58
        ENDPROLOG
        mov r12, rcx                    /* dst */
        mov r13, rdx                    /* src */
        mov r14, r8                     /* &r */
        mov r15d, 2
        cmp r9d, 2
        cmovge r15d, r9d                /* block size, at least 2 */
        mov eax, dword ptr [r14 + RC_L]
        cmp eax, dword ptr [r12 + SURF_CL]
        cmovl eax, dword ptr [r12 + SURF_CL]
        cmp eax, dword ptr [r13 + SURF_CL]
        cmovl eax, dword ptr [r13 + SURF_CL]
        mov dword ptr [rsp + MO_AL], eax
        mov eax, dword ptr [r14 + RC_T]
        cmp eax, dword ptr [r12 + SURF_CT]
        cmovl eax, dword ptr [r12 + SURF_CT]
        cmp eax, dword ptr [r13 + SURF_CT]
        cmovl eax, dword ptr [r13 + SURF_CT]
        mov dword ptr [rsp + MO_AT], eax
        mov eax, dword ptr [r14 + RC_R]
        cmp eax, dword ptr [r12 + SURF_CR]
        cmovg eax, dword ptr [r12 + SURF_CR]
        cmp eax, dword ptr [r13 + SURF_CR]
        cmovg eax, dword ptr [r13 + SURF_CR]
        mov dword ptr [rsp + MO_AR], eax
        cmp eax, dword ptr [rsp + MO_AL]
        jle .Lmo_ret
        mov eax, dword ptr [r14 + RC_B]
        cmp eax, dword ptr [r12 + SURF_CB]
        cmovg eax, dword ptr [r12 + SURF_CB]
        cmp eax, dword ptr [r13 + SURF_CB]
        cmovg eax, dword ptr [r13 + SURF_CB]
        mov dword ptr [rsp + MO_AB], eax
        cmp eax, dword ptr [rsp + MO_AT]
        jle .Lmo_ret
        /* the first block that reaches into the area */
        mov eax, dword ptr [rsp + MO_AL]
        sub eax, dword ptr [r14 + RC_L]
        cdq
        idiv r15d
        imul eax, r15d
        add eax, dword ptr [r14 + RC_L]
        mov dword ptr [rsp + MO_BX0], eax
        mov eax, dword ptr [rsp + MO_AT]
        sub eax, dword ptr [r14 + RC_T]
        cdq
        idiv r15d
        imul eax, r15d
        add eax, dword ptr [r14 + RC_T]
        mov ebp, eax                    /* by */
        pxor xmm5, xmm5
.Lmo_by:
        cmp ebp, dword ptr [rsp + MO_AB]
        jge .Lmo_ret
        mov ebx, dword ptr [rsp + MO_BX0]       /* bx */
.Lmo_bx:
        cmp ebx, dword ptr [rsp + MO_AR]
        jge .Lmo_by_next
        /* the block's source pixels: block, r and the source clip */
        mov esi, ebx
        cmp esi, dword ptr [r14 + RC_L]
        cmovl esi, dword ptr [r14 + RC_L]
        cmp esi, dword ptr [r13 + SURF_CL]
        cmovl esi, dword ptr [r13 + SURF_CL]
        mov edi, ebp
        cmp edi, dword ptr [r14 + RC_T]
        cmovl edi, dword ptr [r14 + RC_T]
        cmp edi, dword ptr [r13 + SURF_CT]
        cmovl edi, dword ptr [r13 + SURF_CT]
        lea r8d, [rbx + r15]
        cmp r8d, dword ptr [r14 + RC_R]
        cmovg r8d, dword ptr [r14 + RC_R]
        cmp r8d, dword ptr [r13 + SURF_CR]
        cmovg r8d, dword ptr [r13 + SURF_CR]
        lea r9d, [rbp + r15]
        cmp r9d, dword ptr [r14 + RC_B]
        cmovg r9d, dword ptr [r14 + RC_B]
        cmp r9d, dword ptr [r13 + SURF_CB]
        cmovg r9d, dword ptr [r13 + SURF_CB]
        cmp r8d, esi
        jle .Lmo_next
        cmp r9d, edi
        jle .Lmo_next
        sub r8d, esi                    /* width */
        sub r9d, edi                    /* height */
        mov eax, edi
        sub eax, dword ptr [r13 + SURF_OY]
        cdqe
        movsxd r11, dword ptr [r13 + SURF_STRIDE]
        imul rax, r11
        mov ecx, esi
        sub ecx, dword ptr [r13 + SURF_OX]
        movsxd rcx, ecx
        add rax, rcx
        mov r10, qword ptr [r13 + SURF_PX]
        lea r10, [r10 + rax*4]          /* first source pixel */
        shl r11, 2                      /* bytes per row */
        mov eax, r8d
        imul eax, r9d
        mov dword ptr [rsp + MO_CNT], eax
        pxor xmm2, xmm2                 /* blue, green, red sums */
        pxor xmm3, xmm3
        pxor xmm4, xmm4
.Lmo_row:
        mov rax, r10
        mov edx, r8d
        cmp edx, 4
        jb .Lmo_t
.Lmo_4:
        movdqu xmm0, xmmword ptr [rax]
        MOS_ACC
        add rax, 16
        sub edx, 4
        cmp edx, 4
        jae .Lmo_4
.Lmo_t:
        test edx, edx
        jz .Lmo_rn
.Lmo_1:
        movd xmm0, dword ptr [rax]
        MOS_ACC
        add rax, 4
        dec edx
        jnz .Lmo_1
.Lmo_rn:
        add r10, r11
        dec r9d
        jnz .Lmo_row
        pshufd xmm0, xmm2, 0xEE
        paddq xmm2, xmm0
        movd esi, xmm2                  /* blue */
        pshufd xmm0, xmm3, 0xEE
        paddq xmm3, xmm0
        movd edi, xmm3                  /* green */
        pshufd xmm0, xmm4, 0xEE
        paddq xmm4, xmm0
        movd r8d, xmm4                  /* red */
        mov ecx, dword ptr [rsp + MO_CNT]
        mov r9d, ecx
        shr r9d, 1                      /* round to nearest */
        lea eax, [r8 + r9]
        xor edx, edx
        div ecx
        shl eax, 16
        mov r8d, eax
        lea eax, [rdi + r9]
        xor edx, edx
        div ecx
        shl eax, 8
        or r8d, eax
        lea eax, [rsi + r9]
        xor edx, edx
        div ecx
        or r8d, eax                     /* the average color */
        /* fill the block's part of the area */
        mov eax, ebx
        cmp eax, dword ptr [rsp + MO_AL]
        cmovl eax, dword ptr [rsp + MO_AL]
        mov dword ptr [rsp + MO_FILL + RC_L], eax
        mov eax, ebp
        cmp eax, dword ptr [rsp + MO_AT]
        cmovl eax, dword ptr [rsp + MO_AT]
        mov dword ptr [rsp + MO_FILL + RC_T], eax
        lea eax, [rbx + r15]
        cmp eax, dword ptr [rsp + MO_AR]
        cmovg eax, dword ptr [rsp + MO_AR]
        mov dword ptr [rsp + MO_FILL + RC_R], eax
        lea eax, [rbp + r15]
        cmp eax, dword ptr [rsp + MO_AB]
        cmovg eax, dword ptr [rsp + MO_AB]
        mov dword ptr [rsp + MO_FILL + RC_B], eax
        mov rcx, r12
        lea rdx, [rsp + MO_FILL]
        call d_fill
        pxor xmm5, xmm5
.Lmo_next:
        add ebx, r15d
        jmp .Lmo_bx
.Lmo_by_next:
        add ebp, r15d
        jmp .Lmo_by
.Lmo_ret:
        add rsp, 0x58
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbp
        pop rbx
        ret
ENDF

/* ---- coverage mask ------------------------------------------------------------------------ */

FUNC draw_release
        ALLOC 0x28
        ENDPROLOG
        mov rcx, qword ptr [rip + g_mask]
        call mem_free
        xor eax, eax
        mov qword ptr [rip + g_mask], rax
        mov qword ptr [rip + g_mask_cap], rax
        add rsp, 0x28
        ret
ENDF

/* rax = zeroed buffer of rcx bytes (plus 8 spare, so 8-byte steps may run past the
 * end), or NULL. The buffer is reused between calls. */
SFUNC mask_get
        PUSHREG rdi
        PUSHREG rsi
        ALLOC 0x28
        ENDPROLOG
        lea rsi, [rcx + 8]
        cmp rsi, qword ptr [rip + g_mask_cap]
        jbe 1f
        mov rcx, qword ptr [rip + g_mask]
        call mem_free
        mov rcx, rsi
        call mem_alloc                  /* returns zeroed memory */
        mov qword ptr [rip + g_mask], rax
        xor ecx, ecx
        test rax, rax
        cmovnz rcx, rsi
        mov qword ptr [rip + g_mask_cap], rcx
        jmp 2f
1:      mov rdi, qword ptr [rip + g_mask]
        mov rcx, rsi
        xor eax, eax
        rep stosb
        mov rax, qword ptr [rip + g_mask]
2:      add rsp, 0x28
        pop rsi
        pop rdi
        ret
ENDF

/* ---- void d_polyline(const Surf *s, const float *xy, int n, float w, uint32_t c, int a, bool mult)
 * rcx = s, rdx = xy, r8d = n, xmm3 = w, then c, a, mult on the stack.
 *
 * Every segment is a capsule. Its coverage goes into a byte mask (the maximum
 * over all segments), and the mask is composited once at the end, so joints and
 * translucent strokes never blend twice. Per row only the pixels within reach
 * of the segment's line are visited. */

#define PL_BOX_L 0x20           /* bounding box of the stroke, clipped */
#define PL_BOX_T 0x24
#define PL_BOX_R 0x28
#define PL_BOX_B 0x2C
#define PL_BW 0x30
#define PL_BH 0x34
#define PL_MASK 0x38
#define PL_LIM 0x40             /* radius + 0.5: where coverage reaches 0 */
#define PL_LIM2 0x44
#define PL_IN2 0x48             /* (radius - 0.5) squared: full coverage inside */
#define PL_HALFW 0x4C           /* half width of a row's span */
#define PL_AX 0x50
#define PL_AY 0x54
#define PL_DX 0x58
#define PL_DY 0x5C
#define PL_INV 0x60             /* 1 / squared length */
#define PL_SLOPE 0x64
#define PL_SPAN 0x68            /* segment not horizontal: rows can be narrowed */
#define PL_SB_L 0x70            /* this segment's box */
#define PL_SB_T 0x74
#define PL_SB_R 0x78
#define PL_SB_B 0x7C
#define PL_XMM 0x80             /* xmm6-15 */
#define PL_FRAME 0x128
#define PL_C (PL_FRAME + 64 + 40)
#define PL_A (PL_FRAME + 64 + 48)
#define PL_MULT (PL_FRAME + 64 + 56)

.macro PL_CLIP_SEG skip         /* eax, ecx, edx, r8d = segment box; clip to the stroke box */
        cmp eax, dword ptr [rsp + PL_BOX_L]
        cmovl eax, dword ptr [rsp + PL_BOX_L]
        cmp ecx, dword ptr [rsp + PL_BOX_T]
        cmovl ecx, dword ptr [rsp + PL_BOX_T]
        cmp edx, dword ptr [rsp + PL_BOX_R]
        cmovg edx, dword ptr [rsp + PL_BOX_R]
        cmp r8d, dword ptr [rsp + PL_BOX_B]
        cmovg r8d, dword ptr [rsp + PL_BOX_B]
        cmp edx, eax
        jle \skip
        cmp r8d, ecx
        jle \skip
        mov dword ptr [rsp + PL_SB_L], eax
        mov dword ptr [rsp + PL_SB_T], ecx
        mov dword ptr [rsp + PL_SB_R], edx
        mov dword ptr [rsp + PL_SB_B], r8d
.endm

.macro PL_ROW_PTR               /* r14 = mask row of y = ebp */
        mov eax, ebp
        sub eax, dword ptr [rsp + PL_BOX_T]
        cdqe
        movsxd rcx, dword ptr [rsp + PL_BW]
        imul rax, rcx
        add rax, qword ptr [rsp + PL_MASK]
        mov r14, rax
.endm

/* Eight pixels x = ymm4 of one row into the mask bytes at rdi.
 * ymm5 = py, ymm6 = (py - ay) * dy, ymm7 = 1/len2, ymm8 = dy, ymm9 = dx, ymm10 = ay,
 * ymm11 = ax, ymm12 = in2, ymm13 = lim2, ymm14 = lim, ymm15 = 0.
 * masked: only the lanes selected by the vector at [rdx + rax] count. */
.macro PIX8 masked
        vcvtdq2ps ymm0, ymm4
        vaddps ymm0, ymm0, ymmword ptr [rip + .Lv_half]         /* px */
        vsubps ymm1, ymm0, ymm11
        vmulps ymm1, ymm1, ymm9
        vaddps ymm1, ymm1, ymm6
        vmulps ymm1, ymm1, ymm7
        vmaxps ymm1, ymm15, ymm1
        vminps ymm1, ymm1, ymmword ptr [rip + .Lv_one]          /* t: position along the segment */
        vmulps ymm2, ymm1, ymm9
        vaddps ymm2, ymm2, ymm11
        vsubps ymm2, ymm2, ymm0                                 /* to the nearest point, x */
        vmulps ymm3, ymm1, ymm8
        vaddps ymm3, ymm3, ymm10
        vsubps ymm3, ymm3, ymm5                                 /* and y */
        vmulps ymm2, ymm2, ymm2
        vmulps ymm3, ymm3, ymm3
        vaddps ymm2, ymm2, ymm3                                 /* squared distance */
        vcmpltps ymm0, ymm2, ymm13                              /* within reach */
    .if \masked
        vandps ymm0, ymm0, ymmword ptr [rdx + rax]
    .endif
        vmovmskps eax, ymm0
        test eax, eax
        jz 97f
        vcmpleps ymm1, ymm2, ymm12                              /* fully inside */
        vsqrtps ymm2, ymm2
        vsubps ymm2, ymm14, ymm2
        vmaxps ymm2, ymm15, ymm2
        vminps ymm2, ymm2, ymmword ptr [rip + .Lv_one]
        vmulps ymm2, ymm2, ymmword ptr [rip + .Lv_255]
        vaddps ymm2, ymm2, ymmword ptr [rip + .Lv_half]
        vcvttps2dq ymm2, ymm2
        vpor ymm2, ymm2, ymm1
        vpand ymm2, ymm2, ymm0
        vpand ymm2, ymm2, ymmword ptr [rip + .Lv_bytemask]
        vextracti128 xmm3, ymm2, 1
        vpackssdw xmm2, xmm2, xmm3
        vpackuswb xmm2, xmm2, xmm2
        vmovq xmm3, qword ptr [rdi]
        vpmaxub xmm2, xmm2, xmm3
        vmovq qword ptr [rdi], xmm2
97:
.endm

FUNC d_polyline
        test r8d, r8d
        jle .Lpl_ret0
        cmp dword ptr [rsp + 48], 0
        jle .Lpl_ret0
        PUSHREG rbx
        PUSHREG rbp
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC PL_FRAME
        SAVEXMM xmm6, PL_XMM + 0x00
        SAVEXMM xmm7, PL_XMM + 0x10
        SAVEXMM xmm8, PL_XMM + 0x20
        SAVEXMM xmm9, PL_XMM + 0x30
        SAVEXMM xmm10, PL_XMM + 0x40
        SAVEXMM xmm11, PL_XMM + 0x50
        SAVEXMM xmm12, PL_XMM + 0x60
        SAVEXMM xmm13, PL_XMM + 0x70
        SAVEXMM xmm14, PL_XMM + 0x80
        SAVEXMM xmm15, PL_XMM + 0x90
        ENDPROLOG
        mov rbx, rcx                    /* s */
        mov rsi, rdx                    /* xy */
        mov r15d, r8d                   /* n */
        movss xmm0, dword ptr [rip + .Lv_half]
        mulss xmm3, xmm0
        maxss xmm3, xmm0                /* radius, at least 0.5 */
        movaps xmm1, xmm3
        addss xmm1, xmm0
        movss dword ptr [rsp + PL_LIM], xmm1
        movaps xmm2, xmm1
        mulss xmm2, xmm1
        movss dword ptr [rsp + PL_LIM2], xmm2
        subss xmm3, xmm0                /* radius - 0.5 */
        xorps xmm4, xmm4
        movaps xmm5, xmm3
        mulss xmm5, xmm3
        ucomiss xmm3, xmm4
        ja 1f
        xorps xmm5, xmm5
1:
        movss dword ptr [rsp + PL_IN2], xmm5
        /* bounding box of all points */
        movss xmm0, dword ptr [rsi]     /* min x */
        movaps xmm2, xmm0               /* max x */
        movss xmm4, dword ptr [rsi + 4] /* min y */
        movaps xmm5, xmm4               /* max y */
        mov eax, 1
.Lpl_bb:
        cmp eax, r15d
        jge .Lpl_bb_done
        minss xmm0, dword ptr [rsi + rax*8]
        maxss xmm2, dword ptr [rsi + rax*8]
        minss xmm4, dword ptr [rsi + rax*8 + 4]
        maxss xmm5, dword ptr [rsi + rax*8 + 4]
        inc eax
        jmp .Lpl_bb
.Lpl_bb_done:
        subss xmm0, xmm1
        subss xmm4, xmm1
        addss xmm2, xmm1
        addss xmm5, xmm1
        FLOORI eax, xmm0, xmm3
        FLOORI ecx, xmm4, xmm3
        CEILI edx, xmm2, xmm3
        CEILI r8d, xmm5, xmm3
        cmp eax, dword ptr [rbx + SURF_CL]
        cmovl eax, dword ptr [rbx + SURF_CL]
        cmp ecx, dword ptr [rbx + SURF_CT]
        cmovl ecx, dword ptr [rbx + SURF_CT]
        cmp edx, dword ptr [rbx + SURF_CR]
        cmovg edx, dword ptr [rbx + SURF_CR]
        cmp r8d, dword ptr [rbx + SURF_CB]
        cmovg r8d, dword ptr [rbx + SURF_CB]
        cmp edx, eax
        jle .Lpl_done
        cmp r8d, ecx
        jle .Lpl_done
        mov dword ptr [rsp + PL_BOX_L], eax
        mov dword ptr [rsp + PL_BOX_T], ecx
        mov dword ptr [rsp + PL_BOX_R], edx
        mov dword ptr [rsp + PL_BOX_B], r8d
        sub edx, eax
        mov dword ptr [rsp + PL_BW], edx
        sub r8d, ecx
        mov dword ptr [rsp + PL_BH], r8d
        movsxd rcx, edx
        movsxd r8, r8d
        imul rcx, r8
        call mask_get
        test rax, rax
        jz .Lpl_done
        mov qword ptr [rsp + PL_MASK], rax
        mov r13d, 1
        lea eax, [r15 - 1]
        cmp r15d, 1
        cmovg r13d, eax                 /* number of segments */
        xor r12d, r12d                  /* segment index */
        CPU_LEVEL
        cmp eax, 2
        je .Lpa_begin

        /* ---- SSE2: one pixel at a time ---- */
.Lps_seg:
        movss xmm0, dword ptr [rsi + r12*8]
        movss xmm1, dword ptr [rsi + r12*8 + 4]
        movaps xmm2, xmm0               /* a single point: b = a */
        movaps xmm3, xmm1
        cmp r15d, 1
        jle 1f
        movss xmm2, dword ptr [rsi + r12*8 + 8]
        movss xmm3, dword ptr [rsi + r12*8 + 12]
1:
        movss dword ptr [rsp + PL_AX], xmm0
        movss dword ptr [rsp + PL_AY], xmm1
        movss xmm5, dword ptr [rsp + PL_LIM]
        movaps xmm4, xmm2
        minss xmm4, dword ptr [rsp + PL_AX]
        subss xmm4, xmm5
        FLOORI eax, xmm4, xmm0
        movaps xmm4, xmm3
        minss xmm4, dword ptr [rsp + PL_AY]
        subss xmm4, xmm5
        FLOORI ecx, xmm4, xmm0
        movaps xmm4, xmm2
        maxss xmm4, dword ptr [rsp + PL_AX]
        addss xmm4, xmm5
        CEILI edx, xmm4, xmm0
        movaps xmm4, xmm3
        maxss xmm4, dword ptr [rsp + PL_AY]
        addss xmm4, xmm5
        CEILI r8d, xmm4, xmm0
        PL_CLIP_SEG .Lps_seg_next
        subss xmm2, dword ptr [rsp + PL_AX]     /* dx */
        subss xmm3, dword ptr [rsp + PL_AY]     /* dy */
        movss dword ptr [rsp + PL_DX], xmm2
        movss dword ptr [rsp + PL_DY], xmm3
        movaps xmm0, xmm2
        mulss xmm0, xmm2
        movaps xmm1, xmm3
        mulss xmm1, xmm3
        addss xmm0, xmm1                /* squared length */
        xorps xmm4, xmm4
        ucomiss xmm0, dword ptr [rip + .Lf_1em6]
        jbe 2f
        movss xmm4, dword ptr [rip + .Lv_one]
        divss xmm4, xmm0
2:
        movss dword ptr [rsp + PL_INV], xmm4
        movaps xmm1, xmm3
        andps xmm1, xmmword ptr [rip + .Lk_abs] /* |dy| */
        xor eax, eax
        xorps xmm4, xmm4                /* slope */
        xorps xmm5, xmm5                /* half width */
        ucomiss xmm1, dword ptr [rip + .Lf_1em3]
        jbe 3f
        mov eax, 1
        movaps xmm4, xmm2
        divss xmm4, xmm3
        sqrtss xmm5, xmm0
        mulss xmm5, dword ptr [rsp + PL_LIM]
        divss xmm5, xmm1
3:
        mov dword ptr [rsp + PL_SPAN], eax
        movss dword ptr [rsp + PL_SLOPE], xmm4
        movss dword ptr [rsp + PL_HALFW], xmm5
        mov ebp, dword ptr [rsp + PL_SB_T]      /* y */
        PL_ROW_PTR
.Lps_row:
        cvtsi2ss xmm0, ebp
        addss xmm0, dword ptr [rip + .Lv_half]  /* py */
        mov r8d, dword ptr [rsp + PL_SB_L]
        mov r9d, dword ptr [rsp + PL_SB_R]
        cmp dword ptr [rsp + PL_SPAN], 0
        je 4f
        movaps xmm1, xmm0
        subss xmm1, dword ptr [rsp + PL_AY]
        mulss xmm1, dword ptr [rsp + PL_SLOPE]
        addss xmm1, dword ptr [rsp + PL_AX]     /* where the line crosses this row */
        movaps xmm2, xmm1
        subss xmm2, dword ptr [rsp + PL_HALFW]
        subss xmm2, dword ptr [rip + .Lv_half]
        FLOORI eax, xmm2, xmm3
        addss xmm1, dword ptr [rsp + PL_HALFW]
        addss xmm1, dword ptr [rip + .Lv_half]
        CEILI ecx, xmm1, xmm3
        cmp eax, r8d
        cmovg r8d, eax
        cmp ecx, r9d
        cmovl r9d, ecx
4:
        cmp r8d, r9d
        jge .Lps_row_next
        movaps xmm1, xmm0
        subss xmm1, dword ptr [rsp + PL_AY]
        mulss xmm1, dword ptr [rsp + PL_DY]     /* (py - ay) * dy */
        mov eax, r8d
        sub eax, dword ptr [rsp + PL_BOX_L]
        cdqe
        lea rdi, [r14 + rax]
.Lps_px:
        xorps xmm2, xmm2
        cvtsi2ss xmm2, r8d
        addss xmm2, dword ptr [rip + .Lv_half]  /* px */
        movaps xmm3, xmm2
        subss xmm3, dword ptr [rsp + PL_AX]
        mulss xmm3, dword ptr [rsp + PL_DX]
        addss xmm3, xmm1
        mulss xmm3, dword ptr [rsp + PL_INV]
        xorps xmm4, xmm4
        maxss xmm4, xmm3
        movss xmm5, dword ptr [rip + .Lv_one]
        minss xmm5, xmm4                /* t */
        movaps xmm3, xmm5
        mulss xmm3, dword ptr [rsp + PL_DX]
        addss xmm3, dword ptr [rsp + PL_AX]
        subss xmm3, xmm2
        mulss xmm5, dword ptr [rsp + PL_DY]
        addss xmm5, dword ptr [rsp + PL_AY]
        subss xmm5, xmm0
        mulss xmm3, xmm3
        mulss xmm5, xmm5
        addss xmm3, xmm5                /* squared distance */
        ucomiss xmm3, dword ptr [rsp + PL_LIM2]
        jae .Lps_px_next
        mov eax, 255
        ucomiss xmm3, dword ptr [rsp + PL_IN2]
        jbe 5f
        sqrtss xmm3, xmm3
        movss xmm4, dword ptr [rsp + PL_LIM]
        subss xmm4, xmm3
        xorps xmm3, xmm3
        maxss xmm3, xmm4
        movss xmm4, dword ptr [rip + .Lv_one]
        minss xmm4, xmm3
        mulss xmm4, dword ptr [rip + .Lv_255]
        addss xmm4, dword ptr [rip + .Lv_half]
        cvttss2si eax, xmm4
5:
        cmp al, byte ptr [rdi]
        jbe .Lps_px_next
        mov byte ptr [rdi], al
.Lps_px_next:
        inc rdi
        inc r8d
        cmp r8d, r9d
        jl .Lps_px
.Lps_row_next:
        movsxd rax, dword ptr [rsp + PL_BW]
        add r14, rax
        inc ebp
        cmp ebp, dword ptr [rsp + PL_SB_B]
        jl .Lps_row
.Lps_seg_next:
        inc r12d
        cmp r12d, r13d
        jl .Lps_seg
        jmp .Lpl_comp

        /* ---- AVX2: eight pixels at a time ---- */
.Lpa_begin:
        vxorps xmm15, xmm15, xmm15
        vbroadcastss ymm14, dword ptr [rsp + PL_LIM]
        vbroadcastss ymm13, dword ptr [rsp + PL_LIM2]
        vbroadcastss ymm12, dword ptr [rsp + PL_IN2]
.Lpa_seg:
        vmovss xmm0, dword ptr [rsi + r12*8]            /* ax */
        vmovss xmm1, dword ptr [rsi + r12*8 + 4]        /* ay */
        vmovaps xmm2, xmm0
        vmovaps xmm3, xmm1
        cmp r15d, 1
        jle 1f
        vmovss xmm2, dword ptr [rsi + r12*8 + 8]        /* bx */
        vmovss xmm3, dword ptr [rsi + r12*8 + 12]       /* by */
1:
        vminss xmm4, xmm2, xmm0
        vsubss xmm4, xmm4, xmm14
        vroundss xmm4, xmm4, xmm4, 9
        vcvttss2si eax, xmm4
        vminss xmm4, xmm3, xmm1
        vsubss xmm4, xmm4, xmm14
        vroundss xmm4, xmm4, xmm4, 9
        vcvttss2si ecx, xmm4
        vmaxss xmm4, xmm2, xmm0
        vaddss xmm4, xmm4, xmm14
        vroundss xmm4, xmm4, xmm4, 10
        vcvttss2si edx, xmm4
        vmaxss xmm4, xmm3, xmm1
        vaddss xmm4, xmm4, xmm14
        vroundss xmm4, xmm4, xmm4, 10
        vcvttss2si r8d, xmm4
        PL_CLIP_SEG .Lpa_seg_next
        vsubss xmm2, xmm2, xmm0                 /* dx */
        vsubss xmm3, xmm3, xmm1                 /* dy */
        vmulss xmm4, xmm2, xmm2
        vmulss xmm5, xmm3, xmm3
        vaddss xmm4, xmm4, xmm5                 /* squared length */
        vxorps xmm5, xmm5, xmm5
        vucomiss xmm4, dword ptr [rip + .Lf_1em6]
        jbe 2f
        vmovss xmm5, dword ptr [rip + .Lv_one]
        vdivss xmm5, xmm5, xmm4
2:
        vbroadcastss ymm11, xmm0
        vbroadcastss ymm10, xmm1
        vbroadcastss ymm9, xmm2
        vbroadcastss ymm8, xmm3
        vbroadcastss ymm7, xmm5
        vandps xmm0, xmm3, xmmword ptr [rip + .Lk_abs]  /* |dy| */
        xor eax, eax
        vxorps xmm1, xmm1, xmm1                 /* slope */
        vxorps xmm5, xmm5, xmm5                 /* half width */
        vucomiss xmm0, dword ptr [rip + .Lf_1em3]
        jbe 3f
        mov eax, 1
        vdivss xmm1, xmm2, xmm3
        vsqrtss xmm5, xmm4, xmm4
        vmulss xmm5, xmm5, xmm14
        vdivss xmm5, xmm5, xmm0
3:
        mov dword ptr [rsp + PL_SPAN], eax
        vmovss dword ptr [rsp + PL_SLOPE], xmm1
        vmovss dword ptr [rsp + PL_HALFW], xmm5
        mov ebp, dword ptr [rsp + PL_SB_T]      /* y */
        PL_ROW_PTR
.Lpa_row:
        vcvtsi2ss xmm0, xmm15, ebp
        vaddss xmm0, xmm0, dword ptr [rip + .Lv_half]   /* py */
        mov r8d, dword ptr [rsp + PL_SB_L]
        mov r9d, dword ptr [rsp + PL_SB_R]
        cmp dword ptr [rsp + PL_SPAN], 0
        je 4f
        vsubss xmm1, xmm0, xmm10
        vmulss xmm1, xmm1, dword ptr [rsp + PL_SLOPE]
        vaddss xmm1, xmm1, xmm11                /* where the line crosses this row */
        vsubss xmm2, xmm1, dword ptr [rsp + PL_HALFW]
        vsubss xmm2, xmm2, dword ptr [rip + .Lv_half]
        vroundss xmm2, xmm2, xmm2, 9
        vcvttss2si eax, xmm2
        vaddss xmm1, xmm1, dword ptr [rsp + PL_HALFW]
        vaddss xmm1, xmm1, dword ptr [rip + .Lv_half]
        vroundss xmm1, xmm1, xmm1, 10
        vcvttss2si ecx, xmm1
        cmp eax, r8d
        cmovg r8d, eax
        cmp ecx, r9d
        cmovl r9d, ecx
4:
        cmp r8d, r9d
        jge .Lpa_row_next
        mov ecx, r9d
        sub ecx, r8d                            /* pixels in this row */
        vbroadcastss ymm5, xmm0
        vsubss xmm1, xmm0, xmm10
        vmulss xmm1, xmm1, xmm8
        vbroadcastss ymm6, xmm1                 /* (py - ay) * dy */
        vmovd xmm4, r8d
        vpbroadcastd ymm4, xmm4
        vpaddd ymm4, ymm4, ymmword ptr [rip + .Lv_iota]
        mov eax, r8d
        sub eax, dword ptr [rsp + PL_BOX_L]
        cdqe
        lea rdi, [r14 + rax]
.Lpa_vec:
        cmp ecx, 8
        jb .Lpa_tail
        PIX8 0
        vpaddd ymm4, ymm4, ymmword ptr [rip + .Lv_eight]
        add rdi, 8
        sub ecx, 8
        jmp .Lpa_vec
.Lpa_tail:
        test ecx, ecx
        jz .Lpa_row_next
        lea rdx, [rip + .Lv_lanes]
        mov eax, ecx
        shl eax, 5
        PIX8 1
.Lpa_row_next:
        movsxd rax, dword ptr [rsp + PL_BW]
        add r14, rax
        inc ebp
        cmp ebp, dword ptr [rsp + PL_SB_B]
        jl .Lpa_row
.Lpa_seg_next:
        inc r12d
        cmp r12d, r13d
        jl .Lpa_seg
        vzeroupper

        /* ---- composite the mask ---- */
.Lpl_comp:
        mov eax, dword ptr [rsp + PL_BOX_T]
        sub eax, dword ptr [rbx + SURF_OY]
        cdqe
        movsxd rdx, dword ptr [rbx + SURF_STRIDE]
        imul rax, rdx
        mov ecx, dword ptr [rsp + PL_BOX_L]
        sub ecx, dword ptr [rbx + SURF_OX]
        movsxd rcx, ecx
        add rax, rcx
        mov r14, qword ptr [rbx + SURF_PX]
        lea r14, [r14 + rax*4]                  /* pixel row */
        lea r15, [rdx*4]                        /* bytes per row */
        mov r13, qword ptr [rsp + PL_MASK]      /* mask row */
        movsxd rbp, dword ptr [rsp + PL_BW]
        mov esi, dword ptr [rsp + PL_C]
        mov edi, dword ptr [rsp + PL_A]
        movzx r11d, byte ptr [rsp + PL_MULT]
        mov r10d, 0x80808081                    /* x / 255 = (x * this) >> 39 */
.Lpl_crow:
        xor ecx, ecx
.Lpl_cx:
        lea rax, [rcx + 8]                      /* skip eight empty bytes at a time */
        cmp rax, rbp
        ja .Lpl_c1
        cmp qword ptr [r13 + rcx], 0
        jne .Lpl_c1
        mov rcx, rax
        jmp .Lpl_cx
.Lpl_c1:
        cmp rcx, rbp
        jae .Lpl_crow_next
        movzx eax, byte ptr [r13 + rcx]
        test eax, eax
        jz .Lpl_cnext
        imul eax, edi
        add eax, 127
        imul rax, r10
        shr rax, 39                             /* coverage times alpha */
        test eax, eax
        jz .Lpl_cnext
        mov r8d, dword ptr [r14 + rcx*4]        /* destination */
        mov r9d, esi                            /* color to lay down */
        test r11d, r11d
        jz 6f
        /* marker: multiply the destination by the color, per channel */
        movzx ebx, r8b
        movzx r12d, sil
        imul ebx, r12d
        add ebx, 128
        mov r12d, ebx
        shr r12d, 8
        add ebx, r12d
        shr ebx, 8
        mov r9d, ebx
        mov ebx, r8d
        shr ebx, 8
        movzx ebx, bl
        mov r12d, esi
        shr r12d, 8
        movzx r12d, r12b
        imul ebx, r12d
        add ebx, 128
        mov r12d, ebx
        shr r12d, 8
        add ebx, r12d
        shr ebx, 8
        shl ebx, 8
        or r9d, ebx
        mov ebx, r8d
        shr ebx, 16
        movzx ebx, bl
        mov r12d, esi
        shr r12d, 16
        movzx r12d, r12b
        imul ebx, r12d
        add ebx, 128
        mov r12d, ebx
        shr r12d, 8
        add ebx, r12d
        shr ebx, 8
        shl ebx, 16
        or r9d, ebx
6:
        cmp eax, 255
        jb 7f
        or r9d, 0xFF000000
        mov dword ptr [r14 + rcx*4], r9d
        jmp .Lpl_cnext
7:
        mov edx, eax
        shr edx, 7
        add eax, edx                            /* w, 0..256 */
        mov edx, 256
        sub edx, eax
        mov ebx, r9d
        and ebx, 0xFF00FF
        imul ebx, eax
        mov r12d, r8d
        and r12d, 0xFF00FF
        imul r12d, edx
        add ebx, r12d
        shr ebx, 8
        and ebx, 0xFF00FF
        and r9d, 0x00FF00
        imul r9d, eax
        and r8d, 0x00FF00
        imul r8d, edx
        add r9d, r8d
        shr r9d, 8
        and r9d, 0x00FF00
        or ebx, r9d
        or ebx, 0xFF000000
        mov dword ptr [r14 + rcx*4], ebx
.Lpl_cnext:
        inc rcx
        jmp .Lpl_cx
.Lpl_crow_next:
        add r13, rbp
        add r14, r15
        dec dword ptr [rsp + PL_BH]
        jnz .Lpl_crow
.Lpl_done:
        movaps xmm6, xmmword ptr [rsp + PL_XMM + 0x00]
        movaps xmm7, xmmword ptr [rsp + PL_XMM + 0x10]
        movaps xmm8, xmmword ptr [rsp + PL_XMM + 0x20]
        movaps xmm9, xmmword ptr [rsp + PL_XMM + 0x30]
        movaps xmm10, xmmword ptr [rsp + PL_XMM + 0x40]
        movaps xmm11, xmmword ptr [rsp + PL_XMM + 0x50]
        movaps xmm12, xmmword ptr [rsp + PL_XMM + 0x60]
        movaps xmm13, xmmword ptr [rsp + PL_XMM + 0x70]
        movaps xmm14, xmmword ptr [rsp + PL_XMM + 0x80]
        movaps xmm15, xmmword ptr [rsp + PL_XMM + 0x90]
        add rsp, PL_FRAME
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbp
        pop rbx
.Lpl_ret0:
        ret
ENDF

/* ---- void d_line(const Surf *s, float x0, float y0, float x1, float y1, float w, uint32_t c, int a)
 * rcx = s, xmm1 = x0, xmm2 = y0, xmm3 = x1, then y1, w, c, a on the stack. */

FUNC d_line
        ALLOC 0x58
        ENDPROLOG
        movss dword ptr [rsp + 0x40], xmm1
        movss dword ptr [rsp + 0x44], xmm2
        movss dword ptr [rsp + 0x48], xmm3
        movss xmm0, dword ptr [rsp + 0x58 + 40]
        movss dword ptr [rsp + 0x4C], xmm0
        movss xmm3, dword ptr [rsp + 0x58 + 48]         /* w */
        mov eax, dword ptr [rsp + 0x58 + 56]
        mov dword ptr [rsp + 0x20], eax                 /* c */
        mov eax, dword ptr [rsp + 0x58 + 64]
        mov dword ptr [rsp + 0x28], eax                 /* a */
        mov byte ptr [rsp + 0x30], 0                    /* not multiplying */
        lea rdx, [rsp + 0x40]
        mov r8d, 2
        call d_polyline
        add rsp, 0x58
        ret
ENDF

/* ---- void d_ellipse(const Surf *s, float cx, float cy, float rx, float ry, float w, uint32_t c, int a)
 * rcx = s, xmm1 = cx, xmm2 = cy, xmm3 = rx, then ry, w, c, a on the stack.
 *
 * Distance to the center-line ellipse uses the k0*(k0-1)/k1 approximation, which
 * is accurate near the curve. Each row only walks the ring, never the interior.
 * Flatter than 0.75 in either direction it is drawn as a line. */

#define EL_N 0x138
#define EL_ARG(o) (EL_N + 64 + (o))
#define EL_CY 0x20
#define EL_IRY2 0x24
#define EL_OX 0x28
#define EL_OY2 0x2C
#define EL_IX 0x30
#define EL_IY 0x34
#define EL_IY2 0x38
#define EL_INNER 0x3C
#define EL_BL 0x40
#define EL_BR 0x44
#define EL_BB 0x48
#define EL_NSP 0x4C
#define EL_SP 0x50              /* up to two spans, (start, end) floats */
#define EL_STR 0x60             /* bytes per row */
#define EL_LVL 0x68             /* draw_cpu */
#define EL_XMM 0x70
#define EL_CW 0x110             /* color words for PLOT8 */

FUNC d_ellipse
        movss xmm0, dword ptr [rsp + 40]        /* ry */
        movss xmm4, dword ptr [rip + .Lf_075]
        ucomiss xmm4, xmm3                      /* rx < 0.75 */
        ja 1f
        ucomiss xmm4, xmm0                      /* ry < 0.75 */
        jbe 2f
1:      /* d_line(s, cx - rx, cy - ry, cx + rx, cy + ry, w, c, a): w, c, a are already in place */
        movaps xmm4, xmm1
        addss xmm4, xmm3                        /* cx + rx */
        movaps xmm5, xmm2
        addss xmm5, xmm0                        /* cy + ry */
        movss dword ptr [rsp + 40], xmm5
        subss xmm1, xmm3
        subss xmm2, xmm0
        movaps xmm3, xmm4
        jmp d_line
2:      PUSHREG rbx
        PUSHREG rbp
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC EL_N
        SAVEXMM xmm6, EL_XMM + 0x00
        SAVEXMM xmm7, EL_XMM + 0x10
        SAVEXMM xmm8, EL_XMM + 0x20
        SAVEXMM xmm9, EL_XMM + 0x30
        SAVEXMM xmm10, EL_XMM + 0x40
        SAVEXMM xmm11, EL_XMM + 0x50
        SAVEXMM xmm12, EL_XMM + 0x60
        SAVEXMM xmm13, EL_XMM + 0x70
        SAVEXMM xmm14, EL_XMM + 0x80
        SAVEXMM xmm15, EL_XMM + 0x90
        ENDPROLOG
        mov rbx, rcx
        movss xmm6, xmm1                        /* cx */
        movss dword ptr [rsp + EL_CY], xmm2
        movss xmm12, dword ptr [rip + .Lv_half]
        movss xmm13, dword ptr [rip + .Lv_one]
        movss xmm4, dword ptr [rsp + EL_ARG(48)] /* w */
        mulss xmm4, xmm12                       /* hw = w * 0.5 */
        ucomiss xmm12, xmm4                     /* hw < 0.5: 0.5 */
        jbe 3f
        movaps xmm4, xmm12
3:
        movaps xmm10, xmm4
        addss xmm10, xmm12                      /* hw + 0.5 */
        movaps xmm5, xmm3
        addss xmm5, xmm4
        addss xmm5, xmm13                       /* ox = rx + hw + 1 */
        movss dword ptr [rsp + EL_OX], xmm5
        movaps xmm8, xmm0
        addss xmm8, xmm4
        addss xmm8, xmm13                       /* oy = ry + hw + 1 */
        movaps xmm9, xmm3
        subss xmm9, xmm4
        subss xmm9, xmm13                       /* ix = rx - hw - 1 */
        movss dword ptr [rsp + EL_IX], xmm9
        movaps xmm11, xmm0
        subss xmm11, xmm4
        subss xmm11, xmm13                      /* iy = ry - hw - 1 */
        movss dword ptr [rsp + EL_IY], xmm11
        /* inner ring exists: ix > 0 && iy > 0 */
        xor eax, eax
        xorps xmm14, xmm14
        ucomiss xmm9, xmm14
        jbe 4f
        ucomiss xmm11, xmm14
        jbe 4f
        mov eax, 1
4:      mov dword ptr [rsp + EL_INNER], eax
        movaps xmm14, xmm11
        mulss xmm14, xmm11
        movss dword ptr [rsp + EL_IY2], xmm14   /* iy * iy */
        movaps xmm14, xmm8
        mulss xmm14, xmm8
        movss dword ptr [rsp + EL_OY2], xmm14   /* oy * oy */
        movaps xmm7, xmm3
        mulss xmm7, xmm3
        movaps xmm14, xmm13
        divss xmm14, xmm7
        movaps xmm7, xmm14                      /* irx2 = 1 / (rx * rx) */
        movaps xmm14, xmm0
        mulss xmm14, xmm0
        movaps xmm15, xmm13
        divss xmm15, xmm14
        movss dword ptr [rsp + EL_IRY2], xmm15  /* iry2 */
        /* box: floor(cx - ox), floor(cy - oy), ceil(cx + ox), ceil(cy + oy), clipped */
        movaps xmm0, xmm6
        subss xmm0, xmm5
        FLOORI eax, xmm0, xmm1
        movss xmm0, dword ptr [rsp + EL_CY]
        subss xmm0, xmm8
        FLOORI ecx, xmm0, xmm1
        movaps xmm0, xmm6
        addss xmm0, xmm5
        CEILI edx, xmm0, xmm1
        movss xmm0, dword ptr [rsp + EL_CY]
        addss xmm0, xmm8
        CEILI r8d, xmm0, xmm1
        cmp eax, dword ptr [rbx + SURF_CL]
        cmovl eax, dword ptr [rbx + SURF_CL]
        cmp ecx, dword ptr [rbx + SURF_CT]
        cmovl ecx, dword ptr [rbx + SURF_CT]
        cmp edx, dword ptr [rbx + SURF_CR]
        cmovg edx, dword ptr [rbx + SURF_CR]
        cmp r8d, dword ptr [rbx + SURF_CB]
        cmovg r8d, dword ptr [rbx + SURF_CB]
        cmp edx, eax
        jle .Lel_done
        cmp r8d, ecx
        jle .Lel_done
        mov dword ptr [rsp + EL_BL], eax
        mov dword ptr [rsp + EL_BR], edx
        mov dword ptr [rsp + EL_BB], r8d
        mov r12d, ecx                           /* y */
        /* rsi = pixel (0, y) */
        movsxd rdx, dword ptr [rbx + SURF_STRIDE]
        mov eax, ecx
        sub eax, dword ptr [rbx + SURF_OY]
        cdqe
        imul rax, rdx
        movsxd rcx, dword ptr [rbx + SURF_OX]
        sub rax, rcx
        mov rsi, qword ptr [rbx + SURF_PX]
        lea rsi, [rsi + rax*4]
        shl rdx, 2
        mov qword ptr [rsp + EL_STR], rdx
        cvtsi2ss xmm11, dword ptr [rsp + EL_ARG(64)]    /* (float)a */
        mov r15d, dword ptr [rsp + EL_ARG(56)]          /* color */
        movss xmm14, dword ptr [rip + .Lf_1em9]
        movaps xmm15, xmmword ptr [rip + .Lk_abs]
        CPU_LEVEL
        mov dword ptr [rsp + EL_LVL], eax
        cmp eax, 2
        jne .Lel_row
        mov eax, r15d
        COLOR_WORDS EL_CW
.Lel_row:
        cvtsi2ss xmm0, r12d
        addss xmm0, xmm12
        subss xmm0, dword ptr [rsp + EL_CY]     /* fy */
        movaps xmm1, xmm0
        mulss xmm1, xmm0                        /* fy * fy */
        movaps xmm2, xmm1
        divss xmm2, dword ptr [rsp + EL_OY2]
        movaps xmm3, xmm13
        subss xmm3, xmm2                        /* t = 1 - fy^2 / oy^2 */
        xorps xmm2, xmm2
        ucomiss xmm3, xmm2
        jbe .Lel_next
        sqrtss xmm3, xmm3
        mulss xmm3, dword ptr [rsp + EL_OX]     /* xo */
        movaps xmm8, xmm1
        mulss xmm8, dword ptr [rsp + EL_IRY2]   /* qy = fy * fy * iry2 */
        movaps xmm9, xmm8
        mulss xmm9, dword ptr [rsp + EL_IRY2]   /* qy * iry2 */
        cmp dword ptr [rsp + EL_INNER], 0
        je .Lel_one
        movaps xmm2, xmm0
        andps xmm2, xmm15                       /* |fy| */
        movss xmm4, dword ptr [rsp + EL_IY]
        ucomiss xmm4, xmm2                      /* |fy| < iy */
        jbe .Lel_one
        movaps xmm4, xmm1
        divss xmm4, dword ptr [rsp + EL_IY2]
        movaps xmm5, xmm13
        subss xmm5, xmm4
        sqrtss xmm5, xmm5
        mulss xmm5, dword ptr [rsp + EL_IX]     /* xi */
        xorps xmm4, xmm4
        ucomiss xmm5, xmm4
        jbe .Lel_one
        /* two spans: [cx - xo, cx - xi] and [cx + xi, cx + xo] */
        movaps xmm4, xmm6
        subss xmm4, xmm3
        movss dword ptr [rsp + EL_SP + 0], xmm4
        movaps xmm4, xmm6
        subss xmm4, xmm5
        movss dword ptr [rsp + EL_SP + 4], xmm4
        movaps xmm4, xmm6
        addss xmm4, xmm5
        movss dword ptr [rsp + EL_SP + 8], xmm4
        movaps xmm4, xmm6
        addss xmm4, xmm3
        movss dword ptr [rsp + EL_SP + 12], xmm4
        mov dword ptr [rsp + EL_NSP], 2
        jmp .Lel_spans
.Lel_one:
        movaps xmm4, xmm6
        subss xmm4, xmm3
        movss dword ptr [rsp + EL_SP + 0], xmm4
        movaps xmm4, xmm6
        addss xmm4, xmm3
        movss dword ptr [rsp + EL_SP + 4], xmm4
        mov dword ptr [rsp + EL_NSP], 1
.Lel_spans:
        lea rbp, [rsp + EL_SP]
.Lel_span:
        movss xmm4, dword ptr [rbp]
        subss xmm4, xmm12
        FLOORI r13d, xmm4, xmm5
        cmp r13d, dword ptr [rsp + EL_BL]
        cmovl r13d, dword ptr [rsp + EL_BL]
        movss xmm4, dword ptr [rbp + 4]
        addss xmm4, xmm12
        CEILI r14d, xmm4, xmm5
        cmp r14d, dword ptr [rsp + EL_BR]
        cmovg r14d, dword ptr [rsp + EL_BR]
        cmp dword ptr [rsp + EL_LVL], 2
        jne .Lel_px
        /* AVX2: eight pixels per step, the same arithmetic per lane */
        mov ecx, r14d
        sub ecx, r13d
        jle .Lel_span_next
        vbroadcastss ymm6, xmm6                 /* cx */
        vbroadcastss ymm7, xmm7                 /* irx2 */
        vbroadcastss ymm8, xmm8                 /* qy */
        vbroadcastss ymm9, xmm9                 /* qy * iry2 */
        vbroadcastss ymm10, xmm10               /* hw + 0.5 */
        vbroadcastss ymm11, xmm11               /* (float)a */
        vbroadcastss ymm12, xmm12               /* 0.5 */
        vbroadcastss ymm13, xmm13               /* 1 */
        vmovd xmm0, r13d
        vpbroadcastd ymm14, xmm0
        vpaddd ymm14, ymm14, ymmword ptr [rip + .Lv_iota]       /* x of each lane */
        movsxd rdi, r13d
        lea rdi, [rsi + rdi*4]
.Lel_v8:
        vcvtdq2ps ymm0, ymm14
        vaddps ymm0, ymm0, ymm12
        vsubps ymm0, ymm0, ymm6                 /* px */
        vmulps ymm0, ymm0, ymm0
        vmulps ymm0, ymm0, ymm7                 /* qx */
        vaddps ymm1, ymm0, ymm8
        vsqrtps ymm1, ymm1                      /* k0 */
        vmulps ymm0, ymm0, ymm7
        vaddps ymm0, ymm0, ymm9
        vsqrtps ymm0, ymm0                      /* k1 */
        vcmpltps ymm2, ymm0, ymmword ptr [rip + .Lv_1em9]
        vpcmpeqd ymm3, ymm3, ymm3
        vpxor ymm2, ymm2, ymm3                  /* not k1 < 1e-9: not skipped */
        vsubps ymm3, ymm1, ymm13
        vmulps ymm3, ymm3, ymm1                 /* k0 * (k0 - 1) */
        vdivps ymm3, ymm3, ymm0                 /* d */
        vbroadcastss ymm0, dword ptr [rip + .Lk_abs]
        vandps ymm3, ymm3, ymm0
        vsubps ymm3, ymm10, ymm3                /* hw + 0.5 - |d| */
        vxorps ymm4, ymm4, ymm4
        vmaxps ymm3, ymm3, ymm4
        vminps ymm3, ymm3, ymm13                /* cov */
        cmp ecx, 8
        jae 1f
        lea rax, [rip + .Lv_lanes]
        mov edx, ecx
        shl edx, 5
        vpand ymm2, ymm2, ymmword ptr [rax + rdx]
1:      PLOT8 ymm3, ymm2, ymm11, ymm12, EL_CW
        add rdi, 32
        vpaddd ymm14, ymm14, ymmword ptr [rip + .Lv_eight]
        sub ecx, 8
        jg .Lel_v8
        vzeroupper
        jmp .Lel_span_next
.Lel_px:
        cmp r13d, r14d
        jge .Lel_span_next
        xorps xmm0, xmm0                        /* no dependency on the last pixel */
        cvtsi2ss xmm0, r13d
        addss xmm0, xmm12
        subss xmm0, xmm6                        /* px */
        mulss xmm0, xmm0
        mulss xmm0, xmm7                        /* qx = px * px * irx2 */
        movaps xmm1, xmm0
        addss xmm1, xmm8
        sqrtss xmm1, xmm1                       /* k0 */
        mulss xmm0, xmm7
        addss xmm0, xmm9
        sqrtss xmm0, xmm0                       /* k1 */
        ucomiss xmm0, xmm14
        jb .Lel_px_next
        movaps xmm2, xmm1
        subss xmm2, xmm13
        mulss xmm2, xmm1                        /* k0 * (k0 - 1) */
        divss xmm2, xmm0                        /* d */
        andps xmm2, xmm15
        movaps xmm3, xmm10
        subss xmm3, xmm2                        /* hw + 0.5 - |d| */
        xorps xmm4, xmm4
        maxss xmm3, xmm4
        minss xmm3, xmm13                       /* cov */
        ucomiss xmm3, xmm4
        jbe .Lel_px_next
        movsxd rdi, r13d                        /* x may be negative */
        lea rdi, [rsi + rdi*4]
        PLOT rdi, r15d, xmm3, xmm11, xmm12, eax, ecx, edx, r8d, r9d
.Lel_px_next:
        inc r13d
        jmp .Lel_px
.Lel_span_next:
        add rbp, 8
        dec dword ptr [rsp + EL_NSP]
        jnz .Lel_span
.Lel_next:
        add rsi, qword ptr [rsp + EL_STR]
        inc r12d
        cmp r12d, dword ptr [rsp + EL_BB]
        jl .Lel_row
.Lel_done:
        movaps xmm6, xmmword ptr [rsp + EL_XMM + 0x00]
        movaps xmm7, xmmword ptr [rsp + EL_XMM + 0x10]
        movaps xmm8, xmmword ptr [rsp + EL_XMM + 0x20]
        movaps xmm9, xmmword ptr [rsp + EL_XMM + 0x30]
        movaps xmm10, xmmword ptr [rsp + EL_XMM + 0x40]
        movaps xmm11, xmmword ptr [rsp + EL_XMM + 0x50]
        movaps xmm12, xmmword ptr [rsp + EL_XMM + 0x60]
        movaps xmm13, xmmword ptr [rsp + EL_XMM + 0x70]
        movaps xmm14, xmmword ptr [rsp + EL_XMM + 0x80]
        movaps xmm15, xmmword ptr [rsp + EL_XMM + 0x90]
        add rsp, EL_N
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbp
        pop rbx
        ret
ENDF

/* ---- void d_disc(const Surf *s, float cx, float cy, float r, uint32_t c, int a) -------------
 * rcx = s, xmm1 = cx, xmm2 = cy, xmm3 = r, then c, a on the stack. */

#define DI_N 0xF0
#define DI_ARG(o) (DI_N + 56 + (o))
#define DI_BL 0x20
#define DI_BB 0x24
#define DI_LVL 0x28
#define DI_STR 0x30
#define DI_XMM 0x40             /* xmm6-14 */
#define DI_CW 0xD0              /* color words for PLOT8 */

FUNC d_disc
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC DI_N
        SAVEXMM xmm6, DI_XMM + 0x00
        SAVEXMM xmm7, DI_XMM + 0x10
        SAVEXMM xmm8, DI_XMM + 0x20
        SAVEXMM xmm9, DI_XMM + 0x30
        SAVEXMM xmm10, DI_XMM + 0x40
        SAVEXMM xmm11, DI_XMM + 0x50
        SAVEXMM xmm12, DI_XMM + 0x60
        SAVEXMM xmm13, DI_XMM + 0x70
        SAVEXMM xmm14, DI_XMM + 0x80
        ENDPROLOG
        mov rbx, rcx
        movaps xmm6, xmm1                       /* cx */
        movaps xmm7, xmm2                       /* cy */
        movss xmm11, dword ptr [rip + .Lv_half]
        movss xmm12, dword ptr [rip + .Lv_one]
        /* box: floor(cx - r - 1), floor(cy - r - 1), ceil(cx + r + 1), ceil(cy + r + 1) */
        movaps xmm0, xmm6
        subss xmm0, xmm3
        subss xmm0, xmm12
        FLOORI eax, xmm0, xmm4
        movaps xmm0, xmm7
        subss xmm0, xmm3
        subss xmm0, xmm12
        FLOORI ecx, xmm0, xmm4
        movaps xmm0, xmm6
        addss xmm0, xmm3
        addss xmm0, xmm12
        CEILI edx, xmm0, xmm4
        movaps xmm0, xmm7
        addss xmm0, xmm3
        addss xmm0, xmm12
        CEILI r8d, xmm0, xmm4
        cmp eax, dword ptr [rbx + SURF_CL]
        cmovl eax, dword ptr [rbx + SURF_CL]
        cmp ecx, dword ptr [rbx + SURF_CT]
        cmovl ecx, dword ptr [rbx + SURF_CT]
        cmp edx, dword ptr [rbx + SURF_CR]
        cmovg edx, dword ptr [rbx + SURF_CR]
        cmp r8d, dword ptr [rbx + SURF_CB]
        cmovg r8d, dword ptr [rbx + SURF_CB]
        cmp edx, eax
        jle .Ldi_done
        cmp r8d, ecx
        jle .Ldi_done
        mov dword ptr [rsp + DI_BL], eax
        mov r14d, edx                           /* box.right */
        mov dword ptr [rsp + DI_BB], r8d
        mov r12d, ecx                           /* y */
        movsxd rdx, dword ptr [rbx + SURF_STRIDE]
        mov eax, ecx
        sub eax, dword ptr [rbx + SURF_OY]
        cdqe
        imul rax, rdx
        movsxd rcx, dword ptr [rbx + SURF_OX]
        sub rax, rcx
        mov rsi, qword ptr [rbx + SURF_PX]
        lea rsi, [rsi + rax*4]                  /* pixel (0, y) */
        shl rdx, 2
        mov qword ptr [rsp + DI_STR], rdx
        /* in = r - 0.5; in2 = in > 0 ? in * in : 0; r + 0.5 */
        movaps xmm8, xmm3
        subss xmm8, xmm11
        xorps xmm0, xmm0
        ucomiss xmm8, xmm0
        jbe 1f
        mulss xmm8, xmm8
        jmp 2f
1:      xorps xmm8, xmm8
2:      movaps xmm9, xmm3
        addss xmm9, xmm11
        cvtsi2ss xmm10, dword ptr [rsp + DI_ARG(48)]    /* (float)a */
        mov r15d, dword ptr [rsp + DI_ARG(40)]          /* color */
        CPU_LEVEL
        mov dword ptr [rsp + DI_LVL], eax
        cmp eax, 2
        jne .Ldi_row
        mov eax, r15d
        COLOR_WORDS DI_CW
.Ldi_row:
        xorps xmm13, xmm13
        cvtsi2ss xmm13, r12d
        addss xmm13, xmm11
        subss xmm13, xmm7
        mulss xmm13, xmm13                      /* dy * dy */
        mov r13d, dword ptr [rsp + DI_BL]
        cmp dword ptr [rsp + DI_LVL], 2
        jne .Ldi_px
        /* AVX2: eight pixels per step */
        mov ecx, r14d
        sub ecx, r13d
        vbroadcastss ymm6, xmm6                 /* cx */
        vbroadcastss ymm8, xmm8                 /* in2 */
        vbroadcastss ymm9, xmm9                 /* r + 0.5 */
        vbroadcastss ymm10, xmm10               /* (float)a */
        vbroadcastss ymm11, xmm11               /* 0.5 */
        vbroadcastss ymm12, xmm12               /* 1 */
        vbroadcastss ymm13, xmm13               /* dy * dy */
        vmovd xmm0, r13d
        vpbroadcastd ymm14, xmm0
        vpaddd ymm14, ymm14, ymmword ptr [rip + .Lv_iota]
        movsxd rdi, r13d
        lea rdi, [rsi + rdi*4]
.Ldi_v8:
        vcvtdq2ps ymm0, ymm14
        vaddps ymm0, ymm0, ymm11
        vsubps ymm0, ymm0, ymm6
        vmulps ymm0, ymm0, ymm0
        vaddps ymm0, ymm0, ymm13                /* d2 */
        vcmpleps ymm1, ymm0, ymm8               /* inside: coverage 1 */
        vsqrtps ymm0, ymm0
        vsubps ymm3, ymm9, ymm0
        vxorps ymm4, ymm4, ymm4
        vmaxps ymm3, ymm3, ymm4
        vminps ymm3, ymm3, ymm12
        vblendvps ymm3, ymm3, ymm12, ymm1       /* cov */
        vpcmpeqd ymm2, ymm2, ymm2
        cmp ecx, 8
        jae 4f
        lea rax, [rip + .Lv_lanes]
        mov edx, ecx
        shl edx, 5
        vpand ymm2, ymm2, ymmword ptr [rax + rdx]
4:      PLOT8 ymm3, ymm2, ymm10, ymm11, DI_CW
        add rdi, 32
        vpaddd ymm14, ymm14, ymmword ptr [rip + .Lv_eight]
        sub ecx, 8
        jg .Ldi_v8
        vzeroupper
        jmp .Ldi_row_next
.Ldi_px:
        xorps xmm0, xmm0                        /* no dependency on the last pixel */
        cvtsi2ss xmm0, r13d
        addss xmm0, xmm11
        subss xmm0, xmm6
        mulss xmm0, xmm0
        addss xmm0, xmm13                       /* d2 */
        movaps xmm1, xmm12                      /* inside: coverage 1 */
        ucomiss xmm0, xmm8
        jbe 3f
        sqrtss xmm0, xmm0
        movaps xmm1, xmm9
        subss xmm1, xmm0
        xorps xmm0, xmm0
        maxss xmm1, xmm0
        minss xmm1, xmm12
3:      movsxd rdi, r13d                        /* x may be negative */
        lea rdi, [rsi + rdi*4]
        PLOT rdi, r15d, xmm1, xmm10, xmm11, eax, ecx, edx, r8d, r9d
        inc r13d
        cmp r13d, r14d
        jl .Ldi_px
.Ldi_row_next:
        add rsi, qword ptr [rsp + DI_STR]
        inc r12d
        cmp r12d, dword ptr [rsp + DI_BB]
        jl .Ldi_row
.Ldi_done:
        movaps xmm6, xmmword ptr [rsp + DI_XMM + 0x00]
        movaps xmm7, xmmword ptr [rsp + DI_XMM + 0x10]
        movaps xmm8, xmmword ptr [rsp + DI_XMM + 0x20]
        movaps xmm9, xmmword ptr [rsp + DI_XMM + 0x30]
        movaps xmm10, xmmword ptr [rsp + DI_XMM + 0x40]
        movaps xmm11, xmmword ptr [rsp + DI_XMM + 0x50]
        movaps xmm12, xmmword ptr [rsp + DI_XMM + 0x60]
        movaps xmm13, xmmword ptr [rsp + DI_XMM + 0x70]
        movaps xmm14, xmmword ptr [rsp + DI_XMM + 0x80]
        add rsp, DI_N
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* ---- convex polygons --------------------------------------------------------------------
 * An edge is {nx, ny, k} (12 bytes): unit outward normal and offset, so the signed
 * distance of a point is nx * x + ny * y - k; inside a convex polygon all are <= 0. */

/* eax = edges_of(rcx = xy, edx = n, r8 = edges): degenerate edges are skipped.
 * Uses the caller's home slots for the centroid. */
SFUNC edges_of
        ENDPROLOG
        xorps xmm0, xmm0                /* centroid */
        xorps xmm1, xmm1
        xor eax, eax
1:      cmp eax, edx
        jge 2f
        addss xmm0, dword ptr [rcx + rax*8]
        addss xmm1, dword ptr [rcx + rax*8 + 4]
        inc eax
        jmp 1b
2:      cvtsi2ss xmm2, edx
        divss xmm0, xmm2
        divss xmm1, xmm2
        movss dword ptr [rsp + 8], xmm0
        movss dword ptr [rsp + 12], xmm1
        xor r9d, r9d                    /* i */
        xor eax, eax                    /* m */
3:      cmp r9d, edx
        jge 9f
        lea r10d, [r9 + 1]
        cmp r10d, edx
        jl 4f
        xor r10d, r10d                  /* j = (i + 1) % n */
4:      movss xmm2, dword ptr [rcx + r9*8]      /* x0 */
        movss xmm3, dword ptr [rcx + r9*8 + 4]  /* y0 */
        movss xmm4, dword ptr [rcx + r10*8]
        subss xmm4, xmm2                        /* ex */
        movss xmm5, dword ptr [rcx + r10*8 + 4]
        subss xmm5, xmm3                        /* ey */
        movaps xmm0, xmm4
        mulss xmm0, xmm4
        movaps xmm1, xmm5
        mulss xmm1, xmm5
        addss xmm0, xmm1
        sqrtss xmm0, xmm0                       /* l */
        ucomiss xmm0, dword ptr [rip + .Lf_1em4]
        jb 8f
        movaps xmm1, xmm5
        divss xmm1, xmm0                        /* nx = ey / l */
        xorps xmm4, xmmword ptr [rip + .Lk_sign]
        divss xmm4, xmm0                        /* ny = -ex / l */
        mulss xmm2, xmm1
        mulss xmm3, xmm4
        addss xmm2, xmm3                        /* k = nx * x0 + ny * y0 */
        movss xmm0, dword ptr [rsp + 8]
        mulss xmm0, xmm1
        movss xmm3, dword ptr [rsp + 12]
        mulss xmm3, xmm4
        addss xmm0, xmm3
        subss xmm0, xmm2                        /* nx * cx + ny * cy - k */
        xorps xmm3, xmm3
        ucomiss xmm0, xmm3
        jbe 5f
        movaps xmm3, xmmword ptr [rip + .Lk_sign]       /* normal points inwards: flip */
        xorps xmm1, xmm3
        xorps xmm4, xmm3
        xorps xmm2, xmm3
5:      imul r11d, eax, 12
        movss dword ptr [r8 + r11], xmm1
        movss dword ptr [r8 + r11 + 4], xmm4
        movss dword ptr [r8 + r11 + 8], xmm2
        inc eax
8:      inc r9d
        jmp 3b
9:      ret
ENDF

/* A conservative span of one row: eax = first and edx = end (exclusive) column that
 * may lie within 0.5 of the polygon, given rcx = edges, edx = m, xmm1 = py,
 * r8d / r9d = the row's limits. Exact per-pixel tests follow, so the span only has
 * to be wide enough: every bound gets 2-3 pixels of slack, and near-horizontal
 * edges (|nx| < 0.01) do not narrow it at all. */
SFUNC conv_span
        ENDPROLOG
        mov r10d, edx
        mov eax, r8d                    /* lo */
        mov edx, r9d                    /* hi */
        cvtsi2ss xmm4, r8d
        subss xmm4, dword ptr [rip + .Lf_16]    /* float limits for the bounds */
        cvtsi2ss xmm5, r9d
        addss xmm5, dword ptr [rip + .Lf_16]
1:      test r10d, r10d
        jz 9f
        movss xmm0, dword ptr [rcx]             /* nx */
        movaps xmm2, xmm0
        andps xmm2, xmmword ptr [rip + .Lk_abs]
        ucomiss xmm2, dword ptr [rip + .Lf_001]
        jb 8f
        movss xmm2, dword ptr [rcx + 8]         /* k */
        addss xmm2, dword ptr [rip + .Lv_half]
        movss xmm3, dword ptr [rcx + 4]
        mulss xmm3, xmm1
        subss xmm2, xmm3                        /* 0.5 + k - ny * py */
        divss xmm2, xmm0                        /* the px where the distance is 0.5 */
        subss xmm2, dword ptr [rip + .Lv_half]  /* as a column */
        maxss xmm2, xmm4
        minss xmm2, xmm5
        FLOORI r11d, xmm2, xmm3
        xorps xmm3, xmm3
        ucomiss xmm0, xmm3
        jbe 2f
        add r11d, 3                             /* nx > 0: columns left of the bound */
        cmp r11d, edx
        cmovl edx, r11d
        jmp 8f
2:      sub r11d, 2                             /* nx < 0: columns right of it */
        cmp r11d, eax
        cmovg eax, r11d
8:      add rcx, 12
        dec r10d
        jmp 1b
9:      ret
ENDF

/* eax = poly_box(rcx = s, rdx = xy, r8d = n, r9 = RECT *out): the bounding box of the
 * points widened by 1, clipped; 0 if empty. */
SFUNC poly_box
        ENDPROLOG
        movss xmm0, dword ptr [rdx]
        movaps xmm2, xmm0
        movss xmm1, dword ptr [rdx + 4]
        movaps xmm3, xmm1
        mov eax, 1
1:      cmp eax, r8d
        jge 2f
        minss xmm0, dword ptr [rdx + rax*8]
        maxss xmm2, dword ptr [rdx + rax*8]
        minss xmm1, dword ptr [rdx + rax*8 + 4]
        maxss xmm3, dword ptr [rdx + rax*8 + 4]
        inc eax
        jmp 1b
2:      movss xmm4, dword ptr [rip + .Lv_one]
        subss xmm0, xmm4
        subss xmm1, xmm4
        addss xmm2, xmm4
        addss xmm3, xmm4
        FLOORI eax, xmm0, xmm5
        FLOORI r10d, xmm1, xmm5
        CEILI r11d, xmm2, xmm5
        CEILI edx, xmm3, xmm5
        cmp eax, dword ptr [rcx + SURF_CL]
        cmovl eax, dword ptr [rcx + SURF_CL]
        cmp r10d, dword ptr [rcx + SURF_CT]
        cmovl r10d, dword ptr [rcx + SURF_CT]
        cmp r11d, dword ptr [rcx + SURF_CR]
        cmovg r11d, dword ptr [rcx + SURF_CR]
        cmp edx, dword ptr [rcx + SURF_CB]
        cmovg edx, dword ptr [rcx + SURF_CB]
        mov dword ptr [r9 + RC_L], eax
        mov dword ptr [r9 + RC_T], r10d
        mov dword ptr [r9 + RC_R], r11d
        mov dword ptr [r9 + RC_B], edx
        cmp r11d, eax
        jle 3f
        cmp edx, r10d
        jle 3f
        mov eax, 1
        ret
3:      xor eax, eax
        ret
ENDF

/* out = max over the cnt edges of nx * px + ny * py - k (cnt must hold the edge
 * count, clobbered), rowc = the row's ny * py values. Starts from -1e30 like the C. */
.macro POLY_DIST edges, rowc, px, out, tmp, cnt, ptr, rc
        movss \out, dword ptr [rip + .Lf_m1e30]
        mov \ptr, \edges
        mov \rc, \rowc
77:     movss \tmp, dword ptr [\ptr]
        mulss \tmp, \px
        addss \tmp, dword ptr [\rc]
        subss \tmp, dword ptr [\ptr + 8]
        maxss \out, \tmp
        add \ptr, 12
        add \rc, 4
        dec \cnt
        jnz 77b
.endm

/* ---- void d_convex(const Surf *s, const float *xy, int n, uint32_t c, int a) ---------------
 * Filled convex polygon of 3 to 8 points, anti-aliased by the distance to its edges. */

#define CV_N 0xE8
#define CV_ARG(o) (CV_N + 64 + (o))
#define CV_E 0x20               /* edges[8] */
#define CV_ROWC 0x80            /* ny * py per edge */
#define CV_BOX 0xA0
#define CV_STR 0xB0
#define CV_M 0xB8
#define CV_XMM 0xC0

FUNC d_convex
        cmp r8d, 3
        jl .Lcv_ret0
        cmp r8d, 8
        jg .Lcv_ret0
        PUSHREG rbx
        PUSHREG rbp
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC CV_N
        SAVEXMM xmm6, CV_XMM + 0x00
        SAVEXMM xmm7, CV_XMM + 0x10
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        mov r12d, r8d
        mov r15d, r9d                           /* color */
        mov rcx, rsi
        mov edx, r12d
        lea r8, [rsp + CV_E]
        call edges_of
        cmp eax, 3
        jl .Lcv_done
        mov dword ptr [rsp + CV_M], eax
        mov rcx, rbx
        mov rdx, rsi
        mov r8d, r12d
        lea r9, [rsp + CV_BOX]
        call poly_box
        test eax, eax
        jz .Lcv_done
        cvtsi2ss xmm6, dword ptr [rsp + CV_ARG(40)]     /* (float)a */
        movss xmm7, dword ptr [rip + .Lv_half]
        mov r12d, dword ptr [rsp + CV_BOX + RC_T]       /* y */
        movsxd rdx, dword ptr [rbx + SURF_STRIDE]
        mov eax, r12d
        sub eax, dword ptr [rbx + SURF_OY]
        cdqe
        imul rax, rdx
        movsxd rcx, dword ptr [rbx + SURF_OX]
        sub rax, rcx
        mov rsi, qword ptr [rbx + SURF_PX]
        lea rsi, [rsi + rax*4]                  /* pixel (0, y) */
        shl rdx, 2
        mov qword ptr [rsp + CV_STR], rdx
.Lcv_row:
        cvtsi2ss xmm1, r12d
        addss xmm1, xmm7                        /* py */
        /* ny * py of every edge */
        mov ecx, dword ptr [rsp + CV_M]
        lea rax, [rsp + CV_E]
        lea rdx, [rsp + CV_ROWC]
1:      movss xmm0, dword ptr [rax + 4]
        mulss xmm0, xmm1
        movss dword ptr [rdx], xmm0
        add rax, 12
        add rdx, 4
        dec ecx
        jnz 1b
        lea rcx, [rsp + CV_E]
        mov edx, dword ptr [rsp + CV_M]
        mov r8d, dword ptr [rsp + CV_BOX + RC_L]
        mov r9d, dword ptr [rsp + CV_BOX + RC_R]
        call conv_span
        mov r13d, eax                           /* x */
        mov r14d, edx                           /* end */
.Lcv_px:
        cmp r13d, r14d
        jge .Lcv_next
        xorps xmm1, xmm1
        cvtsi2ss xmm1, r13d
        addss xmm1, xmm7                        /* px */
        lea rcx, [rsp + CV_E]
        lea r8, [rsp + CV_ROWC]
        mov edx, dword ptr [rsp + CV_M]
        POLY_DIST rcx, r8, xmm1, xmm0, xmm2, edx, r9, r10
        movaps xmm2, xmm7
        subss xmm2, xmm0                        /* 0.5 - distance */
        xorps xmm3, xmm3
        maxss xmm2, xmm3
        minss xmm2, dword ptr [rip + .Lv_one]   /* cov */
        ucomiss xmm2, xmm3
        jbe 2f
        movsxd rdi, r13d                        /* x may be negative */
        lea rdi, [rsi + rdi*4]
        PLOT rdi, r15d, xmm2, xmm6, xmm7, eax, ecx, edx, r8d, r9d
2:      inc r13d
        jmp .Lcv_px
.Lcv_next:
        add rsi, qword ptr [rsp + CV_STR]
        inc r12d
        cmp r12d, dword ptr [rsp + CV_BOX + RC_B]
        jl .Lcv_row
.Lcv_done:
        movaps xmm6, xmmword ptr [rsp + CV_XMM + 0x00]
        movaps xmm7, xmmword ptr [rsp + CV_XMM + 0x10]
        add rsp, CV_N
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbp
        pop rbx
.Lcv_ret0:
        ret
ENDF

/* ---- void d_arrow(const Surf *s, float x0, float y0, float x1, float y1, float w, uint32_t c)
 * rcx = s, xmm1 = x0, xmm2 = y0, xmm3 = x1, then y1, w, c on the stack.
 * Tapered arrow: a thin-tailed shaft trapezoid unioned with a triangular head. */

#define AR_N 0x198
#define AR_ARG(o) (AR_N + 64 + (o))
#define AR_ET 0x20              /* triangle edges[3] */
#define AR_MT 0x44
#define AR_ES 0x48              /* shaft edges[4] */
#define AR_MS 0x78
#define AR_ALL 0x80             /* triangle (6 floats) then shaft (8 floats) */
#define AR_RCT 0xB8             /* ny * py per triangle edge */
#define AR_RCS 0xC4             /* per shaft edge */
#define AR_BOX 0xD4
#define AR_STR 0xE8
#define AR_XMM 0xF0

FUNC d_arrow
        PUSHREG rbx
        PUSHREG rbp
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC AR_N
        SAVEXMM xmm6, AR_XMM + 0x00
        SAVEXMM xmm7, AR_XMM + 0x10
        SAVEXMM xmm8, AR_XMM + 0x20
        SAVEXMM xmm9, AR_XMM + 0x30
        SAVEXMM xmm10, AR_XMM + 0x40
        SAVEXMM xmm11, AR_XMM + 0x50
        SAVEXMM xmm12, AR_XMM + 0x60
        SAVEXMM xmm13, AR_XMM + 0x70
        SAVEXMM xmm14, AR_XMM + 0x80
        SAVEXMM xmm15, AR_XMM + 0x90
        ENDPROLOG
        mov rbx, rcx
        movss xmm0, dword ptr [rsp + AR_ARG(40)]        /* y1 */
        /* dx, dy, len */
        movaps xmm4, xmm3
        subss xmm4, xmm1                        /* dx = x1 - x0 */
        movaps xmm5, xmm0
        subss xmm5, xmm2                        /* dy = y1 - y0 */
        movaps xmm6, xmm4
        mulss xmm6, xmm4
        movaps xmm7, xmm5
        mulss xmm7, xmm5
        addss xmm6, xmm7
        sqrtss xmm6, xmm6                       /* len */
        ucomiss xmm6, dword ptr [rip + .Lv_one]
        jb .Lar_done
        divss xmm4, xmm6                        /* ux */
        divss xmm5, xmm6                        /* uy */
        /* head = min(3w + 8, len * 0.7); hw = head / 2 */
        movss xmm7, dword ptr [rsp + AR_ARG(48)]        /* w */
        mulss xmm7, dword ptr [rip + .Lf_3]
        addss xmm7, dword ptr [rip + .Lf_8]
        mulss xmm6, dword ptr [rip + .Lf_0_7]
        ucomiss xmm7, xmm6
        jbe 1f
        movaps xmm7, xmm6                       /* head */
1:      /* xmm1 x0, xmm2 y0, xmm3 x1, xmm0 y1, xmm4 ux, xmm5 uy, xmm7 head */
        movss dword ptr [rsp + AR_ALL + 0], xmm3        /* tip */
        movss dword ptr [rsp + AR_ALL + 4], xmm0
        movaps xmm8, xmm4
        mulss xmm8, xmm7
        movaps xmm9, xmm3
        subss xmm9, xmm8                        /* bx = x1 - ux * head */
        movaps xmm8, xmm5
        mulss xmm8, xmm7
        movaps xmm10, xmm0
        subss xmm10, xmm8                       /* by = y1 - uy * head */
        movaps xmm11, xmm7
        mulss xmm11, dword ptr [rip + .Lv_half] /* hw */
        /* nx = -uy, ny = ux */
        movaps xmm12, xmm5
        xorps xmm12, xmmword ptr [rip + .Lk_sign]       /* nx */
        movaps xmm8, xmm12
        mulss xmm8, xmm11                       /* nx * hw */
        movaps xmm13, xmm4
        mulss xmm13, xmm11                      /* ny * hw */
        movaps xmm14, xmm9
        addss xmm14, xmm8
        movss dword ptr [rsp + AR_ALL + 8], xmm14       /* bx + nx * hw */
        movaps xmm14, xmm10
        addss xmm14, xmm13
        movss dword ptr [rsp + AR_ALL + 12], xmm14      /* by + ny * hw */
        movaps xmm14, xmm9
        subss xmm14, xmm8
        movss dword ptr [rsp + AR_ALL + 16], xmm14      /* bx - nx * hw */
        movaps xmm14, xmm10
        subss xmm14, xmm13
        movss dword ptr [rsp + AR_ALL + 20], xmm14      /* by - ny * hw */
        /* t0 = max(0.6, w * 0.2), t1 = max(t0, w * 0.5) */
        movss xmm8, dword ptr [rsp + AR_ARG(48)]
        mulss xmm8, dword ptr [rip + .Lf_0_2]
        movss xmm13, dword ptr [rip + .Lf_0_6]
        maxss xmm13, xmm8                       /* t0 */
        movss xmm8, dword ptr [rsp + AR_ARG(48)]
        mulss xmm8, dword ptr [rip + .Lv_half]
        movaps xmm14, xmm13
        maxss xmm14, xmm8                       /* t1 */
        /* ex = x1 - ux * head * 0.6, ey likewise */
        movaps xmm8, xmm4
        mulss xmm8, xmm7
        mulss xmm8, dword ptr [rip + .Lf_0_6]
        movaps xmm9, xmm3
        subss xmm9, xmm8                        /* ex */
        movaps xmm8, xmm5
        mulss xmm8, xmm7
        mulss xmm8, dword ptr [rip + .Lf_0_6]
        movaps xmm10, xmm0
        subss xmm10, xmm8                       /* ey */
        /* shaft: x0 + nx t0, y0 + ny t0, ex + nx t1, ey + ny t1, ex - nx t1, ey - ny t1, x0 - nx t0, y0 - ny t0 */
        movaps xmm8, xmm12
        mulss xmm8, xmm13                       /* nx * t0 */
        movaps xmm11, xmm4
        mulss xmm11, xmm13                      /* ny * t0 */
        movaps xmm15, xmm1
        addss xmm15, xmm8
        movss dword ptr [rsp + AR_ALL + 24], xmm15
        movaps xmm15, xmm2
        addss xmm15, xmm11
        movss dword ptr [rsp + AR_ALL + 28], xmm15
        movaps xmm15, xmm1
        subss xmm15, xmm8
        movss dword ptr [rsp + AR_ALL + 48], xmm15
        movaps xmm15, xmm2
        subss xmm15, xmm11
        movss dword ptr [rsp + AR_ALL + 52], xmm15
        movaps xmm8, xmm12
        mulss xmm8, xmm14                       /* nx * t1 */
        movaps xmm11, xmm4
        mulss xmm11, xmm14                      /* ny * t1 */
        movaps xmm15, xmm9
        addss xmm15, xmm8
        movss dword ptr [rsp + AR_ALL + 32], xmm15
        movaps xmm15, xmm10
        addss xmm15, xmm11
        movss dword ptr [rsp + AR_ALL + 36], xmm15
        movaps xmm15, xmm9
        subss xmm15, xmm8
        movss dword ptr [rsp + AR_ALL + 40], xmm15
        movaps xmm15, xmm10
        subss xmm15, xmm11
        movss dword ptr [rsp + AR_ALL + 44], xmm15
        /* edges of both parts */
        lea rcx, [rsp + AR_ALL]
        mov edx, 3
        lea r8, [rsp + AR_ET]
        call edges_of
        mov dword ptr [rsp + AR_MT], eax
        lea rcx, [rsp + AR_ALL + 24]
        mov edx, 4
        lea r8, [rsp + AR_ES]
        call edges_of
        mov dword ptr [rsp + AR_MS], eax
        cmp dword ptr [rsp + AR_MT], 3
        jge 2f
        cmp eax, 3
        jl .Lar_done                            /* neither part has an area */
2:      mov rcx, rbx
        lea rdx, [rsp + AR_ALL]
        mov r8d, 7
        lea r9, [rsp + AR_BOX]
        call poly_box
        test eax, eax
        jz .Lar_done
        movss xmm6, dword ptr [rip + .Lv_255]   /* (float)255 */
        movss xmm7, dword ptr [rip + .Lv_half]
        mov r15d, dword ptr [rsp + AR_ARG(56)]  /* color */
        mov r12d, dword ptr [rsp + AR_BOX + RC_T]
        movsxd rdx, dword ptr [rbx + SURF_STRIDE]
        mov eax, r12d
        sub eax, dword ptr [rbx + SURF_OY]
        cdqe
        imul rax, rdx
        movsxd rcx, dword ptr [rbx + SURF_OX]
        sub rax, rcx
        mov rsi, qword ptr [rbx + SURF_PX]
        lea rsi, [rsi + rax*4]                  /* pixel (0, y) */
        shl rdx, 2
        mov qword ptr [rsp + AR_STR], rdx
.Lar_row:
        cvtsi2ss xmm1, r12d
        addss xmm1, xmm7                        /* py */
        movss dword ptr [rsp + AR_BOX + 16], xmm1       /* (spare slot after the box) */
        /* columns that may be covered: the union of both parts' spans */
        mov r13d, 0x7FFFFFFF                    /* lo */
        mov r14d, 0x80000000                    /* hi */
        cmp dword ptr [rsp + AR_MT], 3
        jl 3f
        mov ecx, dword ptr [rsp + AR_MT]
        lea rax, [rsp + AR_ET]
        lea rdx, [rsp + AR_RCT]
4:      movss xmm0, dword ptr [rax + 4]
        mulss xmm0, xmm1
        movss dword ptr [rdx], xmm0
        add rax, 12
        add rdx, 4
        dec ecx
        jnz 4b
        lea rcx, [rsp + AR_ET]
        mov edx, dword ptr [rsp + AR_MT]
        mov r8d, dword ptr [rsp + AR_BOX + RC_L]
        mov r9d, dword ptr [rsp + AR_BOX + RC_R]
        call conv_span
        cmp eax, edx
        jge 3f
        mov r13d, eax
        mov r14d, edx
3:      cmp dword ptr [rsp + AR_MS], 3
        jl 5f
        movss xmm1, dword ptr [rsp + AR_BOX + 16]
        mov ecx, dword ptr [rsp + AR_MS]
        lea rax, [rsp + AR_ES]
        lea rdx, [rsp + AR_RCS]
6:      movss xmm0, dword ptr [rax + 4]
        mulss xmm0, xmm1
        movss dword ptr [rdx], xmm0
        add rax, 12
        add rdx, 4
        dec ecx
        jnz 6b
        lea rcx, [rsp + AR_ES]
        mov edx, dword ptr [rsp + AR_MS]
        mov r8d, dword ptr [rsp + AR_BOX + RC_L]
        mov r9d, dword ptr [rsp + AR_BOX + RC_R]
        call conv_span
        cmp eax, edx
        jge 5f
        cmp eax, r13d
        cmovl r13d, eax
        cmp edx, r14d
        cmovg r14d, edx
5:
.Lar_px:
        cmp r13d, r14d
        jge .Lar_next
        xorps xmm1, xmm1
        cvtsi2ss xmm1, r13d
        addss xmm1, xmm7                        /* px */
        movss xmm3, dword ptr [rip + .Lf_1e30]  /* d */
        cmp dword ptr [rsp + AR_MT], 3
        jl 7f
        lea rcx, [rsp + AR_ET]
        lea r8, [rsp + AR_RCT]
        mov edx, dword ptr [rsp + AR_MT]
        POLY_DIST rcx, r8, xmm1, xmm3, xmm2, edx, r9, r10
7:      cmp dword ptr [rsp + AR_MS], 3
        jl 8f
        lea rcx, [rsp + AR_ES]
        lea r8, [rsp + AR_RCS]
        mov edx, dword ptr [rsp + AR_MS]
        POLY_DIST rcx, r8, xmm1, xmm0, xmm2, edx, r9, r10
        minss xmm3, xmm0
8:      movaps xmm2, xmm7
        subss xmm2, xmm3                        /* 0.5 - d */
        xorps xmm3, xmm3
        maxss xmm2, xmm3
        minss xmm2, dword ptr [rip + .Lv_one]
        ucomiss xmm2, xmm3
        jbe 9f
        movsxd rdi, r13d                        /* x may be negative */
        lea rdi, [rsi + rdi*4]
        PLOT rdi, r15d, xmm2, xmm6, xmm7, eax, ecx, edx, r8d, r9d
9:      inc r13d
        jmp .Lar_px
.Lar_next:
        add rsi, qword ptr [rsp + AR_STR]
        inc r12d
        cmp r12d, dword ptr [rsp + AR_BOX + RC_B]
        jl .Lar_row
.Lar_done:
        movaps xmm6, xmmword ptr [rsp + AR_XMM + 0x00]
        movaps xmm7, xmmword ptr [rsp + AR_XMM + 0x10]
        movaps xmm8, xmmword ptr [rsp + AR_XMM + 0x20]
        movaps xmm9, xmmword ptr [rsp + AR_XMM + 0x30]
        movaps xmm10, xmmword ptr [rsp + AR_XMM + 0x40]
        movaps xmm11, xmmword ptr [rsp + AR_XMM + 0x50]
        movaps xmm12, xmmword ptr [rsp + AR_XMM + 0x60]
        movaps xmm13, xmmword ptr [rsp + AR_XMM + 0x70]
        movaps xmm14, xmmword ptr [rsp + AR_XMM + 0x80]
        movaps xmm15, xmmword ptr [rsp + AR_XMM + 0x90]
        add rsp, AR_N
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbp
        pop rbx
        ret
ENDF

/* ---- void d_icon(const Surf *s, int icon, float x, float y, float size, uint32_t c) ---------
 * rcx = s, edx = icon, xmm2 = x, xmm3 = y, then size, c on the stack. Runs the icon's
 * program from draw_icons.inc; the mosaic icon is a 4 x 4 checker of fills. */

#define IC_N 0x100
#define IC_ARG(o) (IC_N + 40 + (o))
#define IC_PTS 0x40             /* up to 11 points */
#define IC_RECT 0x98
#define IC_XMM 0xC0

FUNC d_icon
        cmp edx, 14
        ja .Lic_ret0
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        ALLOC IC_N
        SAVEXMM xmm6, IC_XMM + 0x00
        SAVEXMM xmm7, IC_XMM + 0x10
        SAVEXMM xmm8, IC_XMM + 0x20
        SAVEXMM xmm9, IC_XMM + 0x30
        ENDPROLOG
        mov rbx, rcx
        movaps xmm6, xmm2                       /* x */
        movaps xmm7, xmm3                       /* y */
        movss xmm8, dword ptr [rsp + IC_ARG(40)]        /* size */
        divss xmm8, dword ptr [rip + .Lf_20]    /* u */
        movss xmm9, dword ptr [rip + .Lf_1_6]
        mulss xmm9, xmm8
        movss xmm0, dword ptr [rip + .Lf_1_25]
        maxss xmm0, xmm9
        movaps xmm9, xmm0                       /* sw = max(1.25, 1.6 u) */
        mov r12d, dword ptr [rsp + IC_ARG(48)]  /* color */
        cmp edx, 6
        je .Lic_mosaic
        lea rax, [rip + .Lic_table]
        mov rsi, qword ptr [rax + rdx*8]
.Lic_op:
        movzx eax, byte ptr [rsi]
        test eax, eax
        jz .Lic_done
        movzx r13d, byte ptr [rsi + 1]          /* n */
        cmp eax, 3
        je .Lic_ell
        /* points: x + gx * u, y + gy * u */
        lea rdi, [rsi + 4]
        xor ecx, ecx
1:      movss xmm0, dword ptr [rdi + rcx*8]
        mulss xmm0, xmm8
        addss xmm0, xmm6
        movss dword ptr [rsp + IC_PTS + rcx*8], xmm0
        movss xmm0, dword ptr [rdi + rcx*8 + 4]
        mulss xmm0, xmm8
        addss xmm0, xmm7
        movss dword ptr [rsp + IC_PTS + rcx*8 + 4], xmm0
        inc ecx
        cmp ecx, r13d
        jl 1b
        cmp byte ptr [rsi], 2
        je .Lic_conv
        /* polyline: width by kind, alpha 255 or 110 */
        movzx eax, byte ptr [rsi + 2]
        movaps xmm3, xmm9
        cmp eax, 1
        jne 2f
        mulss xmm3, dword ptr [rip + .Lf_1_15]
2:      cmp eax, 2
        jne 3f
        mulss xmm3, dword ptr [rip + .Lf_1_1]
3:      cmp eax, 3
        jne 4f
        movss xmm3, dword ptr [rip + .Lf_5]
        mulss xmm3, xmm8
4:      mov eax, 255
        mov ecx, 110
        cmp byte ptr [rsi + 3], 0
        cmovne eax, ecx
        mov dword ptr [rsp + 0x28], eax         /* a */
        mov dword ptr [rsp + 0x20], r12d        /* c */
        mov byte ptr [rsp + 0x30], 0            /* not multiplying */
        mov rcx, rbx
        lea rdx, [rsp + IC_PTS]
        mov r8d, r13d
        call d_polyline
        jmp .Lic_skip
.Lic_conv:
        mov dword ptr [rsp + 0x20], 255
        mov rcx, rbx
        lea rdx, [rsp + IC_PTS]
        mov r8d, r13d
        mov r9d, r12d
        call d_convex
.Lic_skip:
        lea rsi, [rsi + 4 + r13*8]
        jmp .Lic_op
.Lic_ell:
        /* d_ellipse(s, x + gx u, y + gy u, rxm u, rym u, sw, c, 255) */
        movss xmm1, dword ptr [rsi + 4]
        mulss xmm1, xmm8
        addss xmm1, xmm6
        movss xmm2, dword ptr [rsi + 8]
        mulss xmm2, xmm8
        addss xmm2, xmm7
        movss xmm3, dword ptr [rsi + 12]
        mulss xmm3, xmm8
        movss xmm0, dword ptr [rsi + 16]
        mulss xmm0, xmm8
        movss dword ptr [rsp + 0x20], xmm0      /* ry */
        movss dword ptr [rsp + 0x28], xmm9      /* w */
        mov dword ptr [rsp + 0x30], r12d        /* c */
        mov dword ptr [rsp + 0x38], 255         /* a */
        mov rcx, rbx
        call d_ellipse
        add rsi, 20
        jmp .Lic_op
.Lic_mosaic:
        /* fills of the cells (i, j), opaque and translucent (70) alternating */
        xor r13d, r13d                          /* i */
5:      xor edi, edi                            /* j */
6:      lea rax, [rip + .Lic_mosaic_grid]
        movss xmm0, dword ptr [rax + r13*4]
        mulss xmm0, xmm8
        addss xmm0, xmm6
        LROUNDF ecx, xmm0, xmm1
        mov dword ptr [rsp + IC_RECT + RC_L], ecx
        movss xmm0, dword ptr [rax + rdi*4]
        mulss xmm0, xmm8
        addss xmm0, xmm7
        LROUNDF ecx, xmm0, xmm1
        mov dword ptr [rsp + IC_RECT + RC_T], ecx
        movss xmm0, dword ptr [rax + r13*4 + 4]
        mulss xmm0, xmm8
        addss xmm0, xmm6
        LROUNDF ecx, xmm0, xmm1
        mov dword ptr [rsp + IC_RECT + RC_R], ecx
        movss xmm0, dword ptr [rax + rdi*4 + 4]
        mulss xmm0, xmm8
        addss xmm0, xmm7
        LROUNDF ecx, xmm0, xmm1
        mov dword ptr [rsp + IC_RECT + RC_B], ecx
        lea eax, [r13 + rdi]
        and eax, 1
        mov r9d, 255
        mov ecx, 70
        test eax, eax
        cmovnz r9d, ecx
        mov rcx, rbx
        lea rdx, [rsp + IC_RECT]
        mov r8d, r12d
        call d_fill_alpha
        inc edi
        cmp edi, 4
        jl 6b
        inc r13d
        cmp r13d, 4
        jl 5b
.Lic_done:
        movaps xmm6, xmmword ptr [rsp + IC_XMM + 0x00]
        movaps xmm7, xmmword ptr [rsp + IC_XMM + 0x10]
        movaps xmm8, xmmword ptr [rsp + IC_XMM + 0x20]
        movaps xmm9, xmmword ptr [rsp + IC_XMM + 0x30]
        add rsp, IC_N
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
.Lic_ret0:
        ret
ENDF

        .section .rdata,"dr"
        .balign 8
.Lic_table:                             /* by icon id (draw.h); the mosaic is special */
        .quad .Lic_rect, .Lic_ellipse, .Lic_line, .Lic_arrow, .Lic_pen, .Lic_marker, 0
        .quad .Lic_text, .Lic_number, .Lic_undo, .Lic_redo, .Lic_pin, .Lic_save, .Lic_close, .Lic_ok
        .balign 4
#include "draw_icons.inc"
