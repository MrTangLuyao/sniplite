/* ov_show.S: the capture overlay's lifetime: showing the overlay (ov_begin, the
 * hotkey-to-screen path), ending it, the output image and finish (copy, save,
 * pin), state transitions, edge hit testing and cursors, constrained drawing,
 * drawing and annotation drags.
 *
 * The order of the window, DWM and composition calls decides what is on screen:
 * with composition the overlay is transparent until the first commit, with GDI it
 * stays cloaked until the first full paint, so it never shows up in its own
 * screenshot and appears in one composition frame.
 *
 * What makes it fast: ov_begin reads each virtual-screen metric once; finish hides
 * the overlay before it builds the output, so it goes away sooner; output_image
 * skips the screenshot copy when the canvas covers the whole selection; inv,
 * inv_ring, ring_w, S, client_rect, is_pen and friends are inlined. */
#include "asm.inc"
#include "ov_layout.inc"
#include "lang.inc"

/* ---- Windows values ------------------------------------------------------------------ */
#define W_DWMWA_CLOAK 13
#define W_HWND_TOPMOST -1
#define W_SWP_SHOW 0x50                 /* SWP_NOACTIVATE | SWP_SHOWWINDOW */
#define W_SWP_SHRINK 0x94               /* SWP_NOZORDER | SWP_NOACTIVATE | SWP_HIDEWINDOW */
#define W_SW_HIDE 0
#define W_SM_XVIRTUALSCREEN 76
#define W_SM_YVIRTUALSCREEN 77
#define W_SM_CXVIRTUALSCREEN 78
#define W_SM_CYVIRTUALSCREEN 79
#define W_CREATE_SUSPENDED 4
#define W_INFINITE 0xFFFFFFFF
#define W_SRCCOPY 0x00CC0020
#define W_SI_NPROC 32                   /* SYSTEM_INFO.dwNumberOfProcessors */
#define W_SI_BYTES 48
#define W_VK_SHIFT 0x10
#define W_MB_SAVEFAIL 0x40010           /* MB_OK | MB_ICONERROR | MB_TOPMOST */
#define W_PATH_CAP 520                  /* MAX_PATH * 2 */

#define OV(f) [rip + O + (f)]

/* the code below relies on these neighbours */
.if OV_RUBBER - OV_LDOWN - 1
        .error "ldown and rubber are no longer adjacent bytes"
.endif
.if OV_TIP - OV_HOVER - 4
        .error "hover and tip are no longer adjacent ints"
.endif
.if OV_HOVER - OV_TE - 48
        .error "te is no longer 48 bytes"
.endif
.if AN_BYTES - 48
        .error "Anno is no longer 48 bytes"
.endif
.if DR_AGRAB - DR_AMOVE - 1
        .error "DR_AGRAB no longer follows DR_AMOVE"
.endif
.if T_MARKER - T_PEN - 1
        .error "T_MARKER no longer follows T_PEN"
.endif

        .section .rdata$ov_show,"dr"
        .balign 4
.Lf1_5: .long 0x3FC00000                /* 1.5f */
.Lf3:   .long 0x40400000                /* 3.0f */
.Lf4:   .long 0x40800000                /* 4.0f */
.Lf7:   .long 0x40E00000                /* 7.0f */
.Lf2_414: .long 0x401A7EFA              /* 2.414f */
        .balign 2
/* L"#%06X" */
.Lw_hex: .short 0x0023, 0x0025, 0x0030, 0x0036, 0x0058, 0
/* L"%d, %d, %d" */
.Lw_dec: .short 0x0025, 0x0064, 0x002C, 0x0020, 0x0025, 0x0064, 0x002C, 0x0020, 0x0025, 0x0064, 0
/* L"sniplite" */
.Lw_title: .short 0x0073, 0x006E, 0x0069, 0x0070, 0x006C, 0x0069, 0x0074, 0x0065, 0

/* dst (32-bit register) = S(v) = max(1, lroundf(v * O.s)), v the label of a float.
 * Clobbers xmm0, xmm1. */
.macro SPX dst, v
        movss xmm0, dword ptr [rip + \v]
        mulss xmm0, dword ptr [rip + O + OV_S]
        LROUNDF \dst, xmm0, xmm1
        test \dst, \dst
        jg 98f
        mov \dst, 1
98:
.endm

/* inv(O.vis.<off>): InvalidateRect(O.hwnd, &rect, FALSE) unless the rect is empty.
 * Clobbers the volatile registers. */
.macro INV_VIS off
        lea rdx, [rip + O + OV_VIS + \off]
        mov eax, dword ptr [rdx + RC_R]
        cmp eax, dword ptr [rdx + RC_L]
        jle 97f
        mov eax, dword ptr [rdx + RC_B]
        cmp eax, dword ptr [rdx + RC_T]
        jle 97f
        mov rcx, qword ptr OV(OV_HWND)
        xor r8d, r8d
        API InvalidateRect
97:
.endm

/* ---- showing / ending ---------------------------------------------------------------- */

/* void force_foreground(HWND h) */
FUNC force_foreground
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        API SetForegroundWindow
        API GetForegroundWindow
        cmp rax, rbx
        je .Lff_focus
        test rax, rax
        jz .Lff_focus
        mov rcx, rax
        xor edx, edx
        API GetWindowThreadProcessId
        mov esi, eax                    /* ft */
        test eax, eax
        jz .Lff_focus
        API GetCurrentThreadId
        mov edi, eax                    /* me */
        cmp esi, edi
        je .Lff_focus
        mov ecx, edi
        mov edx, esi
        mov r8d, 1
        API AttachThreadInput
        test eax, eax
        jz .Lff_focus
        mov rcx, rbx
        API BringWindowToTop
        mov rcx, rbx
        API SetForegroundWindow
        mov ecx, edi
        mov edx, esi
        xor r8d, r8d
        API AttachThreadInput
.Lff_focus:
        mov rcx, rbx
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        jmp qword ptr [rip + __imp_SetFocus]
ENDF

/* Invalidate what the first frame leaves to WM_PAINT: the frame ring around the
 * bright area (inv_ring(v->bright, ring_w())) and the UI panels. */
SFUNC inv_ui
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 56
        ENDPROLOG
        SPX ebx, .Lf1_5                 /* border_t() */
        SPX esi, .Lf7                   /* handle_sz() = S(7) | 1 */
        or esi, 1
        lea ebx, [rbx + rsi + 3]        /* d = ring_w() */
        mov eax, dword ptr OV(OV_VIS + VIS_BRIGHT + RC_R)
        cmp eax, dword ptr OV(OV_VIS + VIS_BRIGHT + RC_L)
        jle .Lui_panels
        mov eax, dword ptr OV(OV_VIS + VIS_BRIGHT + RC_B)
        cmp eax, dword ptr OV(OV_VIS + VIS_BRIGHT + RC_T)
        jle .Lui_panels
        xor esi, esi                    /* the four sides: top, bottom, left, right */
.Lui_side:
        mov r8d, dword ptr OV(OV_VIS + VIS_BRIGHT + RC_L)
        mov r9d, dword ptr OV(OV_VIS + VIS_BRIGHT + RC_T)
        mov r10d, dword ptr OV(OV_VIS + VIS_BRIGHT + RC_R)
        mov r11d, dword ptr OV(OV_VIS + VIS_BRIGHT + RC_B)
        mov eax, r8d
        sub eax, ebx
        mov dword ptr [rsp + 32 + RC_L], eax    /* l - d (top, bottom, left) */
        mov eax, r9d
        sub eax, ebx
        mov dword ptr [rsp + 32 + RC_T], eax    /* t - d (top, left, right) */
        lea eax, [r10 + rbx]
        mov dword ptr [rsp + 32 + RC_R], eax    /* r + d (top, bottom, right) */
        lea eax, [r11 + rbx]
        mov dword ptr [rsp + 32 + RC_B], eax    /* b + d (bottom, left, right) */
        cmp esi, 1
        jb .Lui_top
        je .Lui_bottom
        cmp esi, 2
        je .Lui_left
        mov eax, r10d                   /* right: {r - d, t - d, r + d, b + d} */
        sub eax, ebx
        mov dword ptr [rsp + 32 + RC_L], eax
        jmp .Lui_inv
.Lui_top:                               /* {l - d, t - d, r + d, t + d} */
        lea eax, [r9 + rbx]
        mov dword ptr [rsp + 32 + RC_B], eax
        jmp .Lui_inv
.Lui_bottom:                            /* {l - d, b - d, r + d, b + d} */
        mov eax, r11d
        sub eax, ebx
        mov dword ptr [rsp + 32 + RC_T], eax
        jmp .Lui_inv
.Lui_left:                              /* {l - d, t - d, l + d, b + d} */
        lea eax, [r8 + rbx]
        mov dword ptr [rsp + 32 + RC_R], eax
.Lui_inv:
        mov rcx, qword ptr OV(OV_HWND)
        lea rdx, [rsp + 32]
        xor r8d, r8d
        API InvalidateRect
        inc esi
        cmp esi, 4
        jb .Lui_side
.Lui_panels:
        INV_VIS VIS_LABEL
        INV_VIS VIS_MAG
        INV_VIS VIS_TB
        INV_VIS VIS_PB
        INV_VIS VIS_TIP
        INV_VIS VIS_ACT
        add rsp, 56
        pop rsi
        pop rbx
        ret
ENDF

/* First frame with GDI: the backdrop of the whole virtual screen is composed and
 * blitted by two threads at once, each with its own band buffer and window DC
 * (measured: 2 beats 1 and 4, GDI serializes concurrent blits).
 * DWORD WINAPI paint_worker(void *arg): arg = PaintJob {int k, n}, paints the
 * bands k, k + n, k + 2n ... */
#define PW_H 72                         /* height of the current band */
#define PW_OWN 80                       /* Img */
#define PW_SURF 120                     /* Surf */
#define PW_RECT 160                     /* RECT, compose_base's copy */
#define PW_FRAME 176
FUNC paint_worker
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC PW_FRAME
        ENDPROLOG
        mov rsi, rcx                    /* j */
        lea rbx, OV(OV_BAND)            /* band */
        mov r12d, dword ptr [rcx]       /* b = j->k */
        test r12d, r12d
        jz .Lpw_dc
        lea rcx, [rsp + PW_OWN]
        mov edx, dword ptr OV(OV_SHOT + SHOT_VW)
        mov r8d, BAND_H
        call img_create
        test al, al
        jz .Lpw_fail
        lea rbx, [rsp + PW_OWN]
.Lpw_dc:
        mov rcx, qword ptr OV(OV_HWND)
        API GetDC
        mov rdi, rax                    /* wdc */
        mov eax, dword ptr OV(OV_SHOT + SHOT_VH)
        add eax, BAND_H - 1             /* nb = (vh + BAND_H - 1) / BAND_H */
        cdq
        and edx, BAND_H - 1
        add eax, edx
        sar eax, 6
        mov r13d, eax
        mov r14d, dword ptr [rsi + 4]   /* n */
        cmp r12d, r13d
        jge .Lpw_done
.Lpw_band:
        mov r15d, r12d
        shl r15d, 6                     /* B.top = b * BAND_H */
        lea eax, [r15 + BAND_H]
        mov ecx, dword ptr OV(OV_SHOT + SHOT_VH)
        cmp eax, ecx
        cmovg eax, ecx                  /* B.bottom */
        mov edx, eax
        sub edx, r15d
        mov dword ptr [rsp + PW_H], edx
        mov ecx, dword ptr OV(OV_SHOT + SHOT_VW)
        mov rdx, qword ptr [rbx + IMG_PX]
        mov qword ptr [rsp + PW_SURF + SURF_PX], rdx
        mov edx, dword ptr [rbx + IMG_W]
        mov dword ptr [rsp + PW_SURF + SURF_STRIDE], edx
        mov dword ptr [rsp + PW_SURF + SURF_OX], 0
        mov dword ptr [rsp + PW_SURF + SURF_OY], r15d
        mov dword ptr [rsp + PW_SURF + SURF_CL], 0
        mov dword ptr [rsp + PW_SURF + SURF_CT], r15d
        mov dword ptr [rsp + PW_SURF + SURF_CR], ecx
        mov dword ptr [rsp + PW_SURF + SURF_CB], eax
        mov dword ptr [rsp + PW_RECT + RC_L], 0
        mov dword ptr [rsp + PW_RECT + RC_T], r15d
        mov dword ptr [rsp + PW_RECT + RC_R], ecx
        mov dword ptr [rsp + PW_RECT + RC_B], eax
        lea rcx, [rsp + PW_SURF]
        lea rdx, [rsp + PW_RECT]
        call compose_base
        mov eax, dword ptr [rsp + PW_H] /* BitBlt(wdc, 0, top, vw, h, band->dc, 0, 0, SRCCOPY) */
        mov qword ptr [rsp + 32], rax
        mov rax, qword ptr [rbx + IMG_DC]
        mov qword ptr [rsp + 40], rax
        mov qword ptr [rsp + 48], 0
        mov qword ptr [rsp + 56], 0
        mov dword ptr [rsp + 64], W_SRCCOPY
        mov rcx, rdi
        xor edx, edx
        mov r8d, r15d
        mov r9d, dword ptr OV(OV_SHOT + SHOT_VW)
        API BitBlt
        add r12d, r14d
        cmp r12d, r13d
        jl .Lpw_band
.Lpw_done:
        API GdiFlush
        mov rcx, qword ptr OV(OV_HWND)
        mov rdx, rdi
        API ReleaseDC
        cmp dword ptr [rsi], 0
        je .Lpw_ok
        lea rcx, [rsp + PW_OWN]
        call img_destroy
.Lpw_ok:
        xor eax, eax
        jmp .Lpw_ret
.Lpw_fail:
        mov eax, 1
.Lpw_ret:
        add rsp, PW_FRAME
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void paint_all(void): the first GDI frame, then the UI through WM_PAINT */
#define PA_SI 48                        /* SYSTEM_INFO */
#define PA_JOBS 96                      /* PaintJob[2] */
#define PA_CODE 112
FUNC paint_all
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 120
        ENDPROLOG
        lea rcx, [rsp + PA_SI]
        API GetSystemInfo
        xor esi, esi                    /* started */
        cmp dword ptr [rsp + PA_SI + W_SI_NPROC], 2
        jl .Lpa_jobs                    /* CLAMPI(n, 1, 2) == 1 */
        mov dword ptr [rsp + PA_JOBS + 8], 1    /* jobs[1].k */
        xor ecx, ecx
        xor edx, edx
        lea r8, [rip + paint_worker]
        lea r9, [rsp + PA_JOBS + 8]
        mov qword ptr [rsp + 32], W_CREATE_SUSPENDED
        mov qword ptr [rsp + 40], 0
        API CreateThread
        mov rbx, rax
        test rax, rax
        jz .Lpa_jobs
        mov esi, 1
.Lpa_jobs:
        lea eax, [rsi + 1]              /* n = started + 1 */
        mov dword ptr [rsp + PA_JOBS], 0
        mov dword ptr [rsp + PA_JOBS + 4], eax
        mov dword ptr [rsp + PA_JOBS + 8], 1
        mov dword ptr [rsp + PA_JOBS + 12], eax
        test esi, esi
        jz .Lpa_own
        mov rcx, rbx
        API ResumeThread
.Lpa_own:
        lea rcx, [rsp + PA_JOBS]
        call paint_worker
        test esi, esi
        jz .Lpa_ok
        mov rcx, rbx
        mov edx, W_INFINITE
        API WaitForSingleObject
        mov dword ptr [rsp + PA_CODE], 1
        mov rcx, rbx
        lea rdx, [rsp + PA_CODE]
        API GetExitCodeThread
        mov rcx, rbx
        API CloseHandle
        cmp dword ptr [rsp + PA_CODE], 0
        je .Lpa_ok
        mov rcx, qword ptr OV(OV_HWND)  /* a worker had no buffer: paint everything normally */
        xor edx, edx
        xor r8d, r8d
        API InvalidateRect
        jmp .Lpa_update
.Lpa_ok:
        mov rcx, qword ptr OV(OV_HWND)
        xor edx, edx
        API ValidateRect
        call inv_ui
.Lpa_update:
        mov rcx, qword ptr OV(OV_HWND)
        add rsp, 120
        pop rsi
        pop rbx
        jmp qword ptr [rip + __imp_UpdateWindow]
ENDF

/* void show_overlay(void). With GDI, and with composition when the window was hidden
 * meanwhile (the save dialog was cancelled), the window is shown cloaked and
 * uncloaked once its content is there (a hidden window is not painted). */
#define SO_VAL 56                       /* BOOL for DWM, or RECT for pr_dim */
#define SO_T1 72
FUNC show_overlay
        PUSHREG rbx
        ALLOC 80
        ENDPROLOG
        mov ebx, 1                      /* cloak */
        cmp byte ptr OV(OV_DC), 0
        je .Lso_show
        mov rcx, qword ptr OV(OV_HWND)
        API IsWindowVisible
        xor ebx, ebx
        test eax, eax
        jnz .Lso_dc
        mov ebx, 1
.Lso_show:
        mov dword ptr [rsp + SO_VAL], 1
        mov rcx, qword ptr OV(OV_HWND)
        mov edx, W_DWMWA_CLOAK
        lea r8, [rsp + SO_VAL]
        mov r9d, 4
        API DwmSetWindowAttribute
        mov eax, dword ptr OV(OV_SHOT + SHOT_VW)
        mov qword ptr [rsp + 32], rax
        mov eax, dword ptr OV(OV_SHOT + SHOT_VH)
        mov qword ptr [rsp + 40], rax
        mov qword ptr [rsp + 48], W_SWP_SHOW
        mov rcx, qword ptr OV(OV_HWND)
        mov rdx, W_HWND_TOPMOST
        mov r8d, dword ptr OV(OV_SHOT + SHOT_VX)
        mov r9d, dword ptr OV(OV_SHOT + SHOT_VY)
        API SetWindowPos
        cmp byte ptr OV(OV_DC), 0
        je .Lso_gdi
.Lso_dc:
        /* transparent: DWM composes the screenshot and the dimming; paint only the
         * UI. Everything appears at once with the commit. */
        call now_ms
        movsd qword ptr [rsp + SO_T1], xmm0
        lea rcx, OV(OV_VIS)
        call compute_visual
        movups xmm0, xmmword ptr OV(OV_VIS + VIS_BRIGHT)
        movups xmmword ptr [rsp + SO_VAL], xmm0
        lea rcx, [rsp + SO_VAL]
        call pr_dim
        /* Shown by ov_begin (ebx 0): Windows marks the whole new window for painting,
         * but the UI layer is still transparent from pr_end, so only the UI parts
         * need painting. Repainting all of it cost 10 to 15 ms per capture (13.8
         * million pixels uploaded). Shown again from hidden (ebx 1): the layer holds
         * the old picture, so the full repaint stays. */
        test ebx, ebx
        jnz 1f
        mov rcx, qword ptr OV(OV_HWND)
        xor edx, edx
        API ValidateRect
1:      call inv_ui
        mov rcx, qword ptr OV(OV_HWND)
        API UpdateWindow
        call pr_commit                  /* also when nothing needed painting */
        jmp .Lso_uncloak
.Lso_gdi:
        call now_ms
        movsd qword ptr [rsp + SO_T1], xmm0
        lea rcx, OV(OV_VIS)
        call compute_visual
        call paint_all
.Lso_uncloak:
        test ebx, ebx
        jz .Lso_visible
        mov dword ptr [rsp + SO_VAL], 0
        mov rcx, qword ptr OV(OV_HWND)
        mov edx, W_DWMWA_CLOAK
        lea r8, [rsp + SO_VAL]
        mov r9d, 4
        API DwmSetWindowAttribute
.Lso_visible:
        call now_ms
        movsd qword ptr OV(OV_T_VISIBLE), xmm0
        mov rcx, qword ptr OV(OV_HWND)
        call force_foreground
        mov rcx, qword ptr OV(OV_CUR)
        call cursor_for
        mov rcx, rax
        API SetCursor
        call now_ms
        movsd xmm1, qword ptr OV(OV_T_VISIBLE)
        subsd xmm0, xmm1
        movsd qword ptr OV(OV_T + OVT_FOCUS), xmm0
        subsd xmm1, qword ptr [rsp + SO_T1]
        movsd qword ptr OV(OV_T + OVT_PAINT), xmm1
        add rsp, 80
        pop rbx
        ret
ENDF

/* void hide_overlay(void) */
FUNC hide_overlay
        ENDPROLOG
        mov rcx, qword ptr OV(OV_HWND)
        xor edx, edx                    /* SW_HIDE */
        jmp qword ptr [rip + __imp_ShowWindow]
ENDF

/* void release_capture(void): ReleaseCapture sends WM_CAPTURECHANGED at once;
 * that handler must only react to capture being taken away, not to ours. */
FUNC release_capture
        ALLOC 40
        ENDPROLOG
        API GetCapture
        cmp rax, qword ptr OV(OV_HWND)
        jne .Lrc_ret
        mov byte ptr OV(OV_RELEASING), 1
        API ReleaseCapture
        mov byte ptr OV(OV_RELEASING), 0
.Lrc_ret:
        add rsp, 40
        ret
ENDF

/* void ov_cancel(void) */
FUNC ov_cancel
        ALLOC 56
        ENDPROLOG
        cmp byte ptr OV(OV_ACTIVE), 0
        je .Lca_ret
        cmp byte ptr OV(OV_TE_ON), 0
        je .Lca_timer
        mov byte ptr OV(OV_TE_ON), 0
        API DestroyCaret
        mov rcx, qword ptr OV(OV_HWND)  /* composition mode blinks the caret it draws */
        mov edx, TIMER_CARET
        API KillTimer
        mov rcx, qword ptr OV(OV_HWND)
        xor edx, edx
        API ImmAssociateContext
.Lca_timer:
        mov rcx, qword ptr OV(OV_HWND)
        mov edx, TIMER_TIP
        API KillTimer
        call release_capture
        mov rcx, qword ptr OV(OV_HWND)  /* hide_overlay() */
        xor edx, edx
        API ShowWindow
        cmp byte ptr OV(OV_DC), 0
        je .Lca_shrink
        call pr_end
.Lca_shrink:                            /* so the system frees the full-screen redirection surface */
        mov qword ptr [rsp + 32], 1
        mov qword ptr [rsp + 40], 1
        mov qword ptr [rsp + 48], W_SWP_SHRINK
        mov rcx, qword ptr OV(OV_HWND)
        xor edx, edx
        xor r8d, r8d
        xor r9d, r9d
        API SetWindowPos
        call annos_reset
        mov rcx, qword ptr OV(OV_ANN)
        call mem_free
        mov qword ptr OV(OV_ANN), 0
        mov dword ptr OV(OV_ANN_CAP), 0
        mov rcx, qword ptr OV(OV_OPS)
        call mem_free
        mov qword ptr OV(OV_OPS), 0
        mov dword ptr OV(OV_OPS_CAP), 0
        mov rcx, qword ptr OV(OV_TE_BUF)
        call mem_free
        xorps xmm0, xmm0
        movups xmmword ptr OV(OV_TE), xmm0
        movups xmmword ptr OV(OV_TE + 16), xmm0
        movups xmmword ptr OV(OV_TE + 32), xmm0
        call canvas_free
        lea rcx, OV(OV_BAND)
        call img_destroy
        lea rcx, OV(OV_SHOT)
        call shot_free
        mov rcx, qword ptr OV(OV_WIN)
        call mem_free
        mov qword ptr OV(OV_WIN), 0
        mov dword ptr OV(OV_NWIN), 0
        mov rcx, qword ptr OV(OV_FBUF)
        call mem_free
        mov qword ptr OV(OV_FBUF), 0
        mov dword ptr OV(OV_FBUF_CAP), 0
        call free_fonts
        call draw_release
        mov byte ptr OV(OV_ACTIVE), 0
.Lca_ret:
        add rsp, 56
        ret
ENDF

/* bool ov_active(void) */
FUNC ov_active
        ENDPROLOG
        movzx eax, byte ptr OV(OV_ACTIVE)
        ret
ENDF

/* bool ov_last_timing(OvTiming *t): false before the first capture */
FUNC ov_last_timing
        ENDPROLOG
        movups xmm0, xmmword ptr OV(OV_T)
        movups xmm1, xmmword ptr OV(OV_T + 16)
        mov rax, qword ptr OV(OV_T + 32)
        movups xmmword ptr [rcx], xmm0
        movups xmmword ptr [rcx + 16], xmm1
        mov qword ptr [rcx + 32], rax
        xorpd xmm1, xmm1
        xor eax, eax
        ucomisd xmm0, xmm1              /* t.total > 0 */
        seta al
        ret
ENDF

/* void frame_cb(void *ctx, int i, void *dev, void *tex): a duplicated frame,
 * while it is held: copy it to the screen surface (GPU to GPU). */
FUNC frame_cb
        PUSHREG rbx
        ALLOC 48
        ENDPROLOG
        cmp edx, SHOT_MAX_TILES
        jae .Lfc_ret                    /* i < 0 || i >= SHOT_MAX_TILES */
        mov ebx, edx
        imul rax, rbx, TILE_BYTES
        lea rcx, OV(OV_SHOT + SHOT_TILE + TILE_RC)
        movups xmm0, xmmword ptr [rcx + rax]
        movups xmmword ptr [rsp + 32], xmm0
        mov ecx, ebx
        lea rdx, [rsp + 32]
        call pr_tile_gpu                /* r8 = dev, r9 = tex as they came */
        lea rcx, OV(OV_TILE_GPU)
        mov byte ptr [rcx + rbx], al
.Lfc_ret:
        add rsp, 48
        pop rbx
        ret
ENDF

/* bool ov_begin(void): start an interactive capture; false if busy or failed.
 * The overlay is shown during the capture without appearing in it: with
 * composition transparent (nothing committed yet), and its appearance is what
 * makes DWM present the frame; with GDI cloaked (cloaked windows are not
 * composed). The window enumeration runs on a thread meanwhile. */
#define BG_CLOAK 56
#define BG_SHOW 64                      /* ShotShow */
#define BG_T0 96
#define BG_PT 104
FUNC ov_begin
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 112
        ENDPROLOG
        xor eax, eax
        cmp byte ptr OV(OV_ACTIVE), 0
        jne .Lbg_ret
        call now_ms
        movsd qword ptr [rsp + BG_T0], xmm0
        mov ecx, W_SM_XVIRTUALSCREEN
        API GetSystemMetrics
        mov r12d, eax
        mov ecx, W_SM_YVIRTUALSCREEN
        API GetSystemMetrics
        mov r13d, eax
        mov ecx, W_SM_CXVIRTUALSCREEN
        API GetSystemMetrics
        mov r14d, eax
        mov ecx, W_SM_CYVIRTUALSCREEN
        API GetSystemMetrics
        mov r15d, eax
        /* composition when a GPU is there: the frame goes straight to the screen and
         * is read back only after the overlay is visible; otherwise GDI painting */
        xor edi, edi                    /* O.dc */
        mov rcx, qword ptr OV(OV_HWND_DC)
        test rcx, rcx
        jz .Lbg_mode
        call pr_setup
        test al, al
        jz .Lbg_mode
        mov ecx, r14d
        mov edx, r15d
        call pr_begin
        movzx edi, al
.Lbg_mode:
        mov byte ptr OV(OV_DC), dil
        mov rax, qword ptr OV(OV_HWND_GDI)
        test edi, edi
        cmovnz rax, qword ptr OV(OV_HWND_DC)
        mov qword ptr OV(OV_HWND), rax
        mov byte ptr OV(OV_PIXELS), 0
        xorps xmm0, xmm0
        movups xmmword ptr OV(OV_TILE_GPU), xmm0
        mov qword ptr OV(OV_WIN), 0
        mov dword ptr OV(OV_NWIN), 0
        xor ecx, ecx
        xor edx, edx
        lea r8, [rip + collect_windows]
        xor r9d, r9d
        mov qword ptr [rsp + 32], 0
        mov qword ptr [rsp + 40], 0
        API CreateThread
        mov rbx, rax                    /* th */
        test edi, edi
        jnz .Lbg_take
        mov dword ptr [rsp + BG_CLOAK], 1
        mov rcx, qword ptr OV(OV_HWND)
        mov edx, W_DWMWA_CLOAK
        lea r8, [rsp + BG_CLOAK]
        mov r9d, 4
        API DwmSetWindowAttribute
.Lbg_take:
        mov rax, qword ptr OV(OV_HWND)
        mov qword ptr [rsp + BG_SHOW + SHOW_HWND], rax
        mov dword ptr [rsp + BG_SHOW + SHOW_X], r12d
        mov dword ptr [rsp + BG_SHOW + SHOW_Y], r13d
        mov dword ptr [rsp + BG_SHOW + SHOW_W], r14d
        mov dword ptr [rsp + BG_SHOW + SHOW_H], r15d
        mov qword ptr [rsp + BG_SHOW + SHOW_POKE], rdi
        lea rcx, OV(OV_SHOT)
        lea rdx, [rsp + BG_SHOW]
        xor r8d, r8d
        test edi, edi
        jz 1f
        lea r8, [rip + frame_cb]
1:
        xor r9d, r9d
        call shot_take_gpu
        movzx esi, al                   /* ok */
        test esi, esi
        jz .Lbg_wait
        test edi, edi
        jz .Lbg_map
        /* monitors captured with GDI or on another GPU: upload their pixels */
        xor r12d, r12d
.Lbg_tile:
        cmp r12d, dword ptr OV(OV_SHOT + SHOT_NTILE)
        jge .Lbg_wait
        lea rax, OV(OV_TILE_GPU)
        cmp byte ptr [rax + r12], 0
        jne .Lbg_next
        imul r13, r12, TILE_BYTES
        lea rax, OV(OV_SHOT + SHOT_TILE)
        add r13, rax                    /* &O.shot.tile[i] */
        cmp qword ptr [r13 + TILE_BITS], 0
        jne 2f
        lea rcx, OV(OV_SHOT)
        call shot_map
2:
        mov ecx, r12d
        mov rdx, r13
        call pr_tile_cpu
.Lbg_next:
        inc r12d
        jmp .Lbg_tile
.Lbg_map:
        lea rcx, OV(OV_SHOT)
        call shot_map
        mov byte ptr OV(OV_PIXELS), 1
.Lbg_wait:
        test rbx, rbx
        jz .Lbg_enum
        mov rcx, rbx
        mov edx, W_INFINITE
        API WaitForSingleObject
        mov rcx, rbx
        API CloseHandle
        jmp .Lbg_check
.Lbg_enum:
        xor ecx, ecx
        call collect_windows
.Lbg_check:
        test esi, esi
        jz .Lbg_fail
        lea rcx, OV(OV_BAND)
        mov edx, dword ptr OV(OV_SHOT + SHOT_VW)
        mov r8d, BAND_H
        call img_create
        test al, al
        jnz .Lbg_ok
        lea rcx, OV(OV_SHOT)
        call shot_free
.Lbg_fail:
        mov rcx, qword ptr OV(OV_WIN)
        call mem_free
        mov qword ptr OV(OV_WIN), 0
        mov dword ptr OV(OV_NWIN), 0
        mov qword ptr [rsp + 32], 1
        mov qword ptr [rsp + 40], 1
        mov qword ptr [rsp + 48], W_SWP_SHRINK
        mov rcx, qword ptr OV(OV_HWND)
        xor edx, edx
        xor r8d, r8d
        xor r9d, r9d
        API SetWindowPos
        cmp byte ptr OV(OV_DC), 0
        je 3f
        call pr_end
3:
        xor eax, eax
        jmp .Lbg_ret
.Lbg_ok:
        movsd xmm0, qword ptr OV(OV_SHOT + SHOT_GRAB_MS)
        movsd qword ptr OV(OV_T + OVT_GRAB), xmm0
        movsd xmm0, qword ptr OV(OV_T_ENUM)
        movsd qword ptr OV(OV_T + OVT_WINDOWS), xmm0
        mov byte ptr OV(OV_ACTIVE), 1
        mov dword ptr OV(OV_PHASE), PH_SELECT
        mov word ptr OV(OV_LDOWN), 0    /* ldown, rubber */
        mov dword ptr OV(OV_DRAG), DR_NONE
        mov dword ptr OV(OV_TOOL), T_NONE
        mov dword ptr OV(OV_SIZE_IDX), 1
        mov dword ptr OV(OV_COLOR_IDX), 0
        mov qword ptr OV(OV_HOVER), 0   /* hover, tip */
        mov dword ptr OV(OV_LEVEL), 0
        mov byte ptr OV(OV_HAS_ACT), 0
        mov dword ptr OV(OV_PICK), -1
        mov byte ptr OV(OV_NUDGING), 0
        mov qword ptr [rsp + BG_PT], 0
        lea rcx, [rsp + BG_PT]
        API GetCursorPos
        mov eax, dword ptr [rsp + BG_PT + PT_X]
        sub eax, dword ptr OV(OV_SHOT + SHOT_VX)
        mov dword ptr OV(OV_CUR + PT_X), eax
        mov eax, dword ptr [rsp + BG_PT + PT_Y]
        sub eax, dword ptr OV(OV_SHOT + SHOT_VY)
        mov dword ptr OV(OV_CUR + PT_Y), eax
        call update_scale
        call update_chain
        call show_overlay
        movsd xmm0, qword ptr OV(OV_T_VISIBLE)
        subsd xmm0, qword ptr [rsp + BG_T0]
        movsd qword ptr OV(OV_T + OVT_TOTAL), xmm0
        cmp byte ptr OV(OV_PIXELS), 0
        jne .Lbg_true
        /* visible already; now wait for the pixels (magnifier, output) */
        lea rcx, OV(OV_SHOT)
        call shot_map
        mov byte ptr OV(OV_PIXELS), 1
        INV_VIS VIS_LABEL               /* its translucent background can show the screenshot now */
        call refresh
.Lbg_true:
        mov eax, 1
.Lbg_ret:
        add rsp, 112
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void ov_gpu_changed(void): the GPU state changed; build the composition for the
 * new device now, so the next capture does not pay for it. */
FUNC ov_gpu_changed
        ENDPROLOG
        cmp byte ptr OV(OV_ACTIVE), 0
        jne .Lgc_ret
        mov rcx, qword ptr OV(OV_HWND_DC)
        test rcx, rcx
        jz .Lgc_ret
        jmp pr_setup
.Lgc_ret:
        ret
ENDF

/* ---- output -------------------------------------------------------------------------- */

/* bool output_image(Img *out): the selection with its annotations */
FUNC output_image
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        ALLOC 56
        ENDPROLOG
        mov rbx, rcx
        mov r12d, dword ptr OV(OV_SEL + RC_R)
        sub r12d, dword ptr OV(OV_SEL + RC_L)   /* w */
        mov edx, r12d
        mov r8d, dword ptr OV(OV_SEL + RC_B)
        sub r8d, dword ptr OV(OV_SEL + RC_T)
        call img_create
        test al, al
        jz .Loi_ret
        cmp byte ptr OV(OV_CANVAS_OK), 0
        je .Loi_shot
        /* the canvas covers the selection: it overwrites every pixel of the screenshot */
        mov eax, dword ptr OV(OV_CRECT + RC_L)
        cmp eax, dword ptr OV(OV_SEL + RC_L)
        jg .Loi_shot
        mov eax, dword ptr OV(OV_CRECT + RC_T)
        cmp eax, dword ptr OV(OV_SEL + RC_T)
        jg .Loi_shot
        mov eax, dword ptr OV(OV_CRECT + RC_R)
        cmp eax, dword ptr OV(OV_SEL + RC_R)
        jl .Loi_shot
        mov eax, dword ptr OV(OV_CRECT + RC_B)
        cmp eax, dword ptr OV(OV_SEL + RC_B)
        jge .Loi_canvas
.Loi_shot:
        movups xmm0, xmmword ptr OV(OV_SEL)
        movups xmmword ptr [rsp + 32], xmm0
        lea rcx, OV(OV_SHOT)
        lea rdx, [rsp + 32]
        mov r8, qword ptr [rbx + IMG_PX]
        mov r9d, r12d
        call shot_copy
        cmp byte ptr OV(OV_CANVAS_OK), 0
        je .Loi_true
.Loi_canvas:                            /* the annotated part: I = sel & crect */
        mov eax, dword ptr OV(OV_SEL + RC_L)
        mov ecx, dword ptr OV(OV_CRECT + RC_L)
        cmp eax, ecx
        cmovl eax, ecx                  /* I.left */
        mov edx, dword ptr OV(OV_SEL + RC_T)
        mov ecx, dword ptr OV(OV_CRECT + RC_T)
        cmp edx, ecx
        cmovl edx, ecx                  /* I.top */
        mov r8d, dword ptr OV(OV_SEL + RC_R)
        mov ecx, dword ptr OV(OV_CRECT + RC_R)
        cmp r8d, ecx
        cmovg r8d, ecx                  /* I.right */
        mov r9d, dword ptr OV(OV_SEL + RC_B)
        mov ecx, dword ptr OV(OV_CRECT + RC_B)
        cmp r9d, ecx
        cmovg r9d, ecx                  /* I.bottom */
        sub r8d, eax                    /* columns */
        jle .Loi_true
        sub r9d, edx                    /* rows */
        jle .Loi_true
        movsxd r13, r12d                /* dst stride in pixels (w) */
        mov ecx, edx
        sub ecx, dword ptr OV(OV_SEL + RC_T)
        movsxd rcx, ecx
        imul rcx, r13
        mov r10d, eax
        sub r10d, dword ptr OV(OV_SEL + RC_L)
        movsxd r10, r10d
        add rcx, r10
        mov rdi, qword ptr [rbx + IMG_PX]
        lea rdi, [rdi + rcx*4]          /* dst row */
        movsxd r14, dword ptr OV(OV_CANVAS + IMG_W)     /* src stride */
        sub edx, dword ptr OV(OV_CRECT + RC_T)
        movsxd rdx, edx
        imul rdx, r14
        sub eax, dword ptr OV(OV_CRECT + RC_L)
        movsxd rax, eax
        add rdx, rax
        mov rsi, qword ptr OV(OV_CANVAS + IMG_PX)
        lea rsi, [rsi + rdx*4]          /* src row */
        mov r8d, r8d
        shl r8, 2                       /* bytes per row */
        shl r13, 2
        sub r13, r8                     /* dst stride minus the row */
        shl r14, 2
        sub r14, r8
.Loi_row:
        mov rcx, r8
        rep movsb
        add rdi, r13
        add rsi, r14
        dec r9d
        jnz .Loi_row
.Loi_true:
        mov eax, 1
.Loi_ret:
        add rsp, 56
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void finish(int act): ACT_COPY, ACT_SAVE or ACT_PIN the selection */
#define FI_OUT 48                       /* Img */
#define FI_PATH 96                      /* WCHAR[MAX_PATH * 2] */
#define FI_FRAME (FI_PATH + 2 * W_PATH_CAP)
FUNC finish
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC FI_FRAME
        ENDPROLOG
        mov ebx, ecx
        cmp dword ptr OV(OV_PHASE), PH_SELECT
        jne .Lfi_edit
        mov eax, dword ptr OV(OV_HL + RC_R)
        cmp eax, dword ptr OV(OV_HL + RC_L)
        jle .Lfi_ret
        mov eax, dword ptr OV(OV_HL + RC_B)
        cmp eax, dword ptr OV(OV_HL + RC_T)
        jle .Lfi_ret
        movups xmm0, xmmword ptr OV(OV_HL)
        movups xmmword ptr OV(OV_SEL), xmm0
        mov dword ptr OV(OV_PHASE), PH_EDIT
        call canvas_free
.Lfi_edit:
        /* gone from the screen first: nothing is painted until the next message */
        mov rcx, qword ptr OV(OV_HWND)
        xor edx, edx
        API ShowWindow
        mov ecx, 1
        call text_end
        call end_grab                   /* e.g. Ctrl+C mid-drag: keep what is shown */
        call pick_clear                 /* so the canvas holds every annotation */
        lea rcx, [rsp + FI_OUT]
        call output_image
        test al, al
        jz .Lfi_cancel
        mov esi, dword ptr OV(OV_SHOT + SHOT_VX)
        add esi, dword ptr OV(OV_SEL + RC_L)    /* sx */
        mov edi, dword ptr OV(OV_SHOT + SHOT_VY)
        add edi, dword ptr OV(OV_SEL + RC_T)    /* sy */
        cmp ebx, ACT_COPY
        jne .Lfi_notcopy
        mov eax, dword ptr [rsp + FI_OUT + IMG_H]
        mov qword ptr [rsp + 32], rax
        mov rcx, qword ptr OV(OV_DAEMON)
        mov rdx, qword ptr [rsp + FI_OUT + IMG_PX]
        mov r8d, dword ptr [rsp + FI_OUT + IMG_W]
        mov r9d, r8d
        call clip_put_image
        lea rcx, [rsp + FI_OUT]
        call img_destroy
        jmp .Lfi_cancel
.Lfi_notcopy:
        cmp ebx, ACT_PIN
        jne .Lfi_save
        call ov_cancel
        lea rcx, [rsp + FI_OUT]
        mov edx, esi
        mov r8d, edi
        xor r9d, r9d
        call pin_add
        jmp .Lfi_ret
.Lfi_save:
        lea rcx, [rsp + FI_PATH]
        mov edx, W_PATH_CAP
        call save_dialog
        movzx esi, al
        cmp byte ptr OV(OV_ACTIVE), 0
        je .Lfi_drop                    /* quit while the dialog was open */
        test esi, esi
        jz .Lfi_back
        mov eax, dword ptr [rsp + FI_OUT + IMG_H]
        mov qword ptr [rsp + 32], rax
        lea rcx, [rsp + FI_PATH]
        mov rdx, qword ptr [rsp + FI_OUT + IMG_PX]
        mov r8d, dword ptr [rsp + FI_OUT + IMG_W]
        mov r9d, r8d
        call image_save
        test al, al
        jnz .Lfi_saved
        xor ecx, ecx
        TR rdx, OV_SAVE_FAILED
        lea r8, [rip + .Lw_title]
        mov r9d, W_MB_SAVEFAIL
        API MessageBoxW
.Lfi_saved:
        lea rcx, [rsp + FI_OUT]
        call img_destroy
        jmp .Lfi_cancel
.Lfi_back:                              /* cancelled: back to editing */
        lea rcx, [rsp + FI_OUT]
        call img_destroy
        call show_overlay
        jmp .Lfi_ret
.Lfi_drop:
        lea rcx, [rsp + FI_OUT]
        call img_destroy
        jmp .Lfi_ret
.Lfi_cancel:
        call ov_cancel
.Lfi_ret:
        add rsp, FI_FRAME
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void ov_pin_hotkey(void): pin hotkey pressed while capturing */
FUNC ov_pin_hotkey
        ENDPROLOG
        cmp byte ptr OV(OV_ACTIVE), 0
        je .Lph_ret
        mov ecx, ACT_PIN
        jmp finish
.Lph_ret:
        ret
ENDF

/* void copy_color(void): the color under the cursor as text */
#define CC_TEXT 48                      /* WCHAR[32] */
FUNC copy_color
        ALLOC 120
        ENDPROLOG
        lea rcx, OV(OV_SHOT)
        mov edx, dword ptr OV(OV_CUR + PT_X)
        mov r8d, dword ptr OV(OV_CUR + PT_Y)
        call shot_pixel
        lea rcx, [rsp + CC_TEXT]
        cmp byte ptr OV(OV_HEX), 0
        je .Lcc_dec
        lea rdx, [rip + .Lw_hex]
        mov r8d, eax
        API wsprintfW
        jmp .Lcc_put
.Lcc_dec:
        lea rdx, [rip + .Lw_dec]
        movzx r8d, al
        mov qword ptr [rsp + 32], r8    /* b */
        mov r8d, eax
        shr r8d, 16
        and r8d, 255                    /* r */
        mov r9d, eax
        shr r9d, 8
        movzx r9d, r9b                  /* g */
        API wsprintfW
.Lcc_put:
        mov rcx, qword ptr OV(OV_HWND)  /* hide_overlay() */
        xor edx, edx
        API ShowWindow
        mov rcx, qword ptr OV(OV_DAEMON)
        lea rdx, [rsp + CC_TEXT]
        call clip_put_text
        add rsp, 120
        jmp ov_cancel
ENDF

/* ---- state transitions --------------------------------------------------------------- */

/* void enter_edit(RECT r) */
FUNC enter_edit
        ALLOC 40
        ENDPROLOG
        xor eax, eax                    /* r & client_rect() */
        mov r8d, dword ptr [rcx + RC_L]
        test r8d, r8d
        cmovl r8d, eax
        mov r9d, dword ptr [rcx + RC_T]
        test r9d, r9d
        cmovl r9d, eax
        mov r10d, dword ptr [rcx + RC_R]
        mov eax, dword ptr OV(OV_SHOT + SHOT_VW)
        cmp r10d, eax
        cmovg r10d, eax
        mov r11d, dword ptr [rcx + RC_B]
        mov eax, dword ptr OV(OV_SHOT + SHOT_VH)
        cmp r11d, eax
        cmovg r11d, eax
        cmp r10d, r8d
        jle .Lee_ret
        cmp r11d, r9d
        jle .Lee_ret
        mov dword ptr OV(OV_PHASE), PH_EDIT
        mov dword ptr OV(OV_SEL + RC_L), r8d
        mov dword ptr OV(OV_SEL + RC_T), r9d
        mov dword ptr OV(OV_SEL + RC_R), r10d
        mov dword ptr OV(OV_SEL + RC_B), r11d
        mov word ptr OV(OV_LDOWN), 0    /* rubber, ldown */
        mov dword ptr OV(OV_DRAG), DR_NONE
        call canvas_free
        call update_scale
        add rsp, 40
        jmp refresh
.Lee_ret:
        add rsp, 40
        ret
ENDF

/* void back_to_select(void) */
FUNC back_to_select
        ALLOC 40
        ENDPROLOG
        xor ecx, ecx
        call text_end
        call annos_reset
        call canvas_free
        mov dword ptr OV(OV_PHASE), PH_SELECT
        mov dword ptr OV(OV_TOOL), T_NONE
        mov dword ptr OV(OV_DRAG), DR_NONE
        mov qword ptr OV(OV_HOVER), 0   /* hover, tip */
        mov rcx, qword ptr OV(OV_HWND)
        mov edx, TIMER_TIP
        API KillTimer
        call update_scale
        call update_chain
        add rsp, 40
        jmp refresh
ENDF

/* void sel_changed(void): the selection moved or changed size. Annotations stay
 * where they are on the screen and the canvas already covers them; only a mosaic
 * drawn live (picked, or above the pick) reads from the canvas, which must cover
 * its part that is now visible. */
FUNC sel_changed
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 56
        ENDPROLOG
        cmp dword ptr OV(OV_NANN), 0
        jne 1f
        cmp byte ptr OV(OV_CANVAS_OK), 0
        je 1f
        cmp byte ptr OV(OV_HAS_ACT), 0
        jne 1f
        call canvas_free                /* only the mosaic tool's copy of the old selection */
1:
        mov ebx, dword ptr OV(OV_PICK)
        test ebx, ebx
        jns .Lsc_loop
        mov ebx, dword ptr OV(OV_NANN)
.Lsc_loop:
        cmp ebx, dword ptr OV(OV_NANN)
        jge .Lsc_done
        movsxd rsi, ebx
        imul rsi, rsi, AN_BYTES
        add rsi, qword ptr OV(OV_ANN)
        cmp dword ptr [rsi + AN_TOOL], T_MOSAIC
        jne .Lsc_next
        cmp byte ptr OV(OV_CANVAS_OK), 0
        je .Lsc_build
        lea rcx, [rsp + 32]
        mov rdx, rsi
        call anno_bounds
        /* v = bounds & sel & client_rect(); empty counts as covered */
        mov eax, dword ptr [rsp + 32 + RC_L]
        mov ecx, dword ptr OV(OV_SEL + RC_L)
        cmp eax, ecx
        cmovl eax, ecx
        xor ecx, ecx
        cmp eax, ecx
        cmovl eax, ecx
        mov edx, dword ptr [rsp + 32 + RC_T]
        mov ecx, dword ptr OV(OV_SEL + RC_T)
        cmp edx, ecx
        cmovl edx, ecx
        xor ecx, ecx
        cmp edx, ecx
        cmovl edx, ecx
        mov r8d, dword ptr [rsp + 32 + RC_R]
        mov ecx, dword ptr OV(OV_SEL + RC_R)
        cmp r8d, ecx
        cmovg r8d, ecx
        mov ecx, dword ptr OV(OV_SHOT + SHOT_VW)
        cmp r8d, ecx
        cmovg r8d, ecx
        mov r9d, dword ptr [rsp + 32 + RC_B]
        mov ecx, dword ptr OV(OV_SEL + RC_B)
        cmp r9d, ecx
        cmovg r9d, ecx
        mov ecx, dword ptr OV(OV_SHOT + SHOT_VH)
        cmp r9d, ecx
        cmovg r9d, ecx
        cmp r8d, eax
        jle .Lsc_next
        cmp r9d, edx
        jle .Lsc_next
        cmp eax, dword ptr OV(OV_CRECT + RC_L)
        jl .Lsc_build
        cmp edx, dword ptr OV(OV_CRECT + RC_T)
        jl .Lsc_build
        cmp r8d, dword ptr OV(OV_CRECT + RC_R)
        jg .Lsc_build
        cmp r9d, dword ptr OV(OV_CRECT + RC_B)
        jle .Lsc_next
.Lsc_build:
        mov ecx, 1
        call canvas_build
        jmp .Lsc_done
.Lsc_next:
        inc ebx
        jmp .Lsc_loop
.Lsc_done:
        add rsp, 56
        pop rsi
        pop rbx
        jmp update_scale
ENDF

/* void set_tool(int tool): the same tool again switches it off */
FUNC set_tool
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov ebx, ecx
        mov ecx, 1
        call text_end
        call pick_clear
        xor eax, eax
        cmp dword ptr OV(OV_TOOL), ebx
        cmovne eax, ebx
        mov dword ptr OV(OV_TOOL), eax
        add rsp, 32
        pop rbx
        ret
ENDF

/* int hit_edges(POINT p): the selection's handles, then (without a tool) its edges */
FUNC hit_edges
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ENDPROLOG
        mov r8, rcx
        shr r8, 32                      /* p.y */
        SPX r9d, .Lf7
        or r9d, 1                       /* handle_sz() */
        shr r9d, 1
        SPX eax, .Lf3
        add r9d, eax                    /* tol = hs / 2 + S(3) */
        /* bit i of esi: |p.x - xs[i]| <= tol, xs = {l, (l + r) / 2, r}; edi: the same in y */
        mov r10d, dword ptr OV(OV_SEL + RC_L)
        mov r11d, dword ptr OV(OV_SEL + RC_R)
        xor esi, esi
        mov eax, ecx
        sub eax, r10d
        mov edx, eax
        neg edx
        cmovs edx, eax
        cmp edx, r9d
        jg 1f
        or esi, 1
1:
        lea eax, [r10 + r11]
        mov edx, eax
        shr edx, 31
        add eax, edx
        sar eax, 1
        neg eax
        add eax, ecx
        mov edx, eax
        neg edx
        cmovs edx, eax
        cmp edx, r9d
        jg 2f
        or esi, 2
2:
        mov eax, ecx
        sub eax, r11d
        mov edx, eax
        neg edx
        cmovs edx, eax
        cmp edx, r9d
        jg 3f
        or esi, 4
3:
        mov r10d, dword ptr OV(OV_SEL + RC_T)
        mov r11d, dword ptr OV(OV_SEL + RC_B)
        xor edi, edi
        mov eax, r8d
        sub eax, r10d
        mov edx, eax
        neg edx
        cmovs edx, eax
        cmp edx, r9d
        jg 4f
        or edi, 1
4:
        lea eax, [r10 + r11]
        mov edx, eax
        shr edx, 31
        add eax, edx
        sar eax, 1
        neg eax
        add eax, r8d
        mov edx, eax
        neg edx
        cmovs edx, eax
        cmp edx, r9d
        jg 5f
        or edi, 2
5:
        mov eax, r8d
        sub eax, r11d
        mov edx, eax
        neg edx
        cmovs edx, eax
        cmp edx, r9d
        jg 6f
        or edi, 4
6:
        /* the first (j, i) in row order, the center excluded: ex = {L, 0, R}, ey = {T, 0, B} */
        test edi, 1
        jz 7f
        mov ebx, EDGE_T
        mov edx, esi
        test edx, edx
        jnz .Lhe_handle
7:
        test edi, 2
        jz 8f
        xor ebx, ebx
        mov edx, esi
        and edx, 5                      /* not the center */
        jnz .Lhe_handle
8:
        test edi, 4
        jz .Lhe_edges
        mov ebx, EDGE_B
        mov edx, esi
        test edx, edx
        jnz .Lhe_handle
        jmp .Lhe_edges
.Lhe_handle:
        mov eax, edx                    /* lowest bit i: 1 -> L, 2 -> 0, 4 -> R */
        neg eax
        and eax, edx
        and eax, 5
        or eax, ebx
        jmp .Lhe_ret
.Lhe_edges:
        xor eax, eax
        cmp dword ptr OV(OV_TOOL), T_NONE
        jne .Lhe_ret
        SPX r9d, .Lf4                   /* t */
        xor eax, eax                    /* e */
        /* iny: top - t <= p.y < bottom + t */
        xor esi, esi
        mov edx, dword ptr OV(OV_SEL + RC_T)
        sub edx, r9d
        cmp r8d, edx
        jl 1f
        mov edx, dword ptr OV(OV_SEL + RC_B)
        add edx, r9d
        cmp r8d, edx
        jge 1f
        mov esi, 1
1:
        xor edi, edi                    /* inx */
        mov edx, dword ptr OV(OV_SEL + RC_L)
        sub edx, r9d
        cmp ecx, edx
        jl 2f
        mov edx, dword ptr OV(OV_SEL + RC_R)
        add edx, r9d
        cmp ecx, edx
        jge 2f
        mov edi, 1
2:
        test esi, esi
        jz 4f
        mov edx, ecx
        sub edx, dword ptr OV(OV_SEL + RC_L)
        mov r10d, edx
        neg r10d
        cmovs r10d, edx
        cmp r10d, r9d
        jg 3f
        or eax, EDGE_L
        jmp 4f
3:
        mov edx, ecx
        sub edx, dword ptr OV(OV_SEL + RC_R)
        mov r10d, edx
        neg r10d
        cmovs r10d, edx
        cmp r10d, r9d
        jg 4f
        or eax, EDGE_R
4:
        test edi, edi
        jz .Lhe_ret
        mov edx, r8d
        sub edx, dword ptr OV(OV_SEL + RC_T)
        mov r10d, edx
        neg r10d
        cmovs r10d, edx
        cmp r10d, r9d
        jg 5f
        or eax, EDGE_T
        jmp .Lhe_ret
5:
        mov edx, r8d
        sub edx, dword ptr OV(OV_SEL + RC_B)
        mov r10d, edx
        neg r10d
        cmovs r10d, edx
        cmp r10d, r9d
        jg .Lhe_ret
        or eax, EDGE_B
.Lhe_ret:
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* HCURSOR edge_cursor(int e) */
FUNC edge_cursor
        ENDPROLOG
        test ecx, END_A | END_B
        jnz .Lec_move
        mov eax, ecx
        and eax, EDGE_L | EDGE_T
        cmp eax, EDGE_L | EDGE_T
        je .Lec_nwse
        mov eax, ecx
        and eax, EDGE_R | EDGE_B
        cmp eax, EDGE_R | EDGE_B
        je .Lec_nwse
        mov eax, ecx
        and eax, EDGE_R | EDGE_T
        cmp eax, EDGE_R | EDGE_T
        je .Lec_nesw
        mov eax, ecx
        and eax, EDGE_L | EDGE_B
        cmp eax, EDGE_L | EDGE_B
        je .Lec_nesw
        mov rax, qword ptr OV(OV_C_NS)
        test ecx, EDGE_L | EDGE_R
        cmovnz rax, qword ptr OV(OV_C_WE)
        ret
.Lec_move:
        mov rax, qword ptr OV(OV_C_MOVE)
        ret
.Lec_nwse:
        mov rax, qword ptr OV(OV_C_NWSE)
        ret
.Lec_nesw:
        mov rax, qword ptr OV(OV_C_NESW)
        ret
ENDF

/* int grab_target(POINT p): which annotation a click at p grabs. Pens keep
 * drawing over annotations; the text tool edits text instead (see text_at). */
FUNC grab_target
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov eax, dword ptr OV(OV_TOOL)
        sub eax, T_PEN
        cmp eax, T_MARKER - T_PEN
        jbe .Lgt_none
        mov rbx, rcx
        call anno_at
        test eax, eax
        jns .Lgt_ret
        mov rcx, rbx
        call pick_body_has
        mov ecx, eax
        mov eax, -1
        test cl, cl
        cmovnz eax, dword ptr OV(OV_PICK)
        jmp .Lgt_ret
.Lgt_none:
        mov eax, -1
.Lgt_ret:
        add rsp, 32
        pop rbx
        ret
ENDF

/* HCURSOR cursor_for(POINT p) */
FUNC cursor_for
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        cmp dword ptr OV(OV_PHASE), PH_EDIT
        jne .Lcf_cross
        mov eax, dword ptr OV(OV_DRAG)
        cmp eax, DR_MOVE
        je .Lcf_move
        cmp eax, DR_AMOVE
        je .Lcf_move
        cmp eax, DR_RESIZE
        je .Lcf_resize
        cmp eax, DR_AGRAB
        je .Lcf_agrab
        cmp eax, DR_DRAW
        je .Lcf_cross
        cmp eax, DR_BUTTON
        je .Lcf_arrow
        call tb_hit                     /* rcx = p */
        test eax, eax
        jnz .Lcf_arrow
        mov rcx, rbx
        call pick_grab_at
        test eax, eax
        jnz .Lcf_edge
        mov rcx, rbx
        call hit_edges
        test eax, eax
        jnz .Lcf_edge
        mov eax, dword ptr OV(OV_TOOL)
        cmp eax, T_TEXT
        je .Lcf_text
        sub eax, T_PEN                  /* grab_target(p) >= 0: never for pens */
        cmp eax, T_MARKER - T_PEN
        jbe .Lcf_tool
        mov rcx, rbx
        call anno_at
        test eax, eax
        jns .Lcf_move
        mov rcx, rbx
        call pick_body_has
        test al, al
        jnz .Lcf_move
.Lcf_tool:
        cmp dword ptr OV(OV_TOOL), T_NONE
        jne .Lcf_cross
        mov rax, qword ptr OV(OV_C_MOVE)
        jmp .Lcf_in
.Lcf_text:
        mov rax, qword ptr OV(OV_C_IBEAM)
.Lcf_in:                                /* rax if p is in the selection, else the arrow */
        mov ecx, ebx
        shr rbx, 32
        cmp ecx, dword ptr OV(OV_SEL + RC_L)
        jl .Lcf_arrow
        cmp ecx, dword ptr OV(OV_SEL + RC_R)
        jge .Lcf_arrow
        cmp ebx, dword ptr OV(OV_SEL + RC_T)
        jl .Lcf_arrow
        cmp ebx, dword ptr OV(OV_SEL + RC_B)
        jge .Lcf_arrow
        jmp .Lcf_ret
.Lcf_move:
        mov rax, qword ptr OV(OV_C_MOVE)
        jmp .Lcf_ret
.Lcf_cross:
        mov rax, qword ptr OV(OV_C_CROSS)
        jmp .Lcf_ret
.Lcf_arrow:
        mov rax, qword ptr OV(OV_C_ARROW)
.Lcf_ret:
        add rsp, 32
        pop rbx
        ret
.Lcf_resize:
        mov ecx, dword ptr OV(OV_EDGES)
        jmp .Lcf_ec
.Lcf_agrab:
        mov ecx, dword ptr OV(OV_GRAB)
        jmp .Lcf_ec
.Lcf_edge:
        mov ecx, eax
.Lcf_ec:
        add rsp, 32
        pop rbx
        jmp edge_cursor
ENDF

/* POINT constrain(POINT a, POINT b, int tool): with Shift, lines and arrows snap
 * to 45 degrees, other shapes become squares and circles */
FUNC constrain
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        mov edi, r8d
        mov ecx, W_VK_SHIFT
        API GetKeyState
        mov rdx, rsi
        test ax, ax
        jns .Lco_b
        mov ecx, esi
        sub ecx, ebx                    /* dx */
        shr rdx, 32
        mov rax, rbx
        shr rax, 32
        sub edx, eax                    /* dy */
        mov r9d, ecx
        neg r9d
        cmovs r9d, ecx                  /* ax */
        mov r10d, edx
        neg r10d
        cmovs r10d, edx                 /* ay */
        cmp edi, T_LINE
        je 1f
        cmp edi, T_ARROW
        jne .Lco_square
1:
        xorps xmm0, xmm0
        cvtsi2ss xmm0, r9d
        xorps xmm1, xmm1
        cvtsi2ss xmm1, r10d
        movss xmm2, dword ptr [rip + .Lf2_414]
        mulss xmm2, xmm1
        ucomiss xmm0, xmm2              /* ax > ay * 2.414f */
        ja .Lco_flat
        movss xmm2, dword ptr [rip + .Lf2_414]
        mulss xmm2, xmm0
        ucomiss xmm1, xmm2              /* ay > ax * 2.414f */
        ja .Lco_upright
.Lco_square:
        mov eax, r9d                    /* m = MAXI(ax, ay), with the signs of dx, dy */
        cmp eax, r10d
        cmovl eax, r10d
        mov r8d, eax
        neg r8d
        test ecx, ecx
        mov ecx, eax
        cmovs ecx, r8d
        test edx, edx
        mov edx, eax
        cmovs edx, r8d
        jmp .Lco_out
.Lco_flat:
        xor edx, edx
        jmp .Lco_out
.Lco_upright:
        xor ecx, ecx
.Lco_out:
        add ecx, ebx
        shr rbx, 32
        add edx, ebx
        shl rdx, 32
        or rdx, rcx
.Lco_b:
        mov rax, rdx
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* ---- drawing and annotation drags ------------------------------------------------------ */

/* void begin_draw(POINT p) */
FUNC begin_draw
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        cmp dword ptr OV(OV_TOOL), T_MOSAIC
        jne 1f
        call canvas_cover_sel           /* the mosaic reads the pixels under it from the canvas */
1:
        lea rcx, OV(OV_ACT)
        call anno_free
        mov ecx, dword ptr OV(OV_TOOL)
        mov dword ptr OV(OV_ACT + AN_TOOL), ecx
        movsxd rax, dword ptr OV(OV_COLOR_IDX)
        lea rdx, [rip + kColors]
        mov eax, dword ptr [rdx + rax*4]
        mov dword ptr OV(OV_ACT + AN_COLOR), eax
        mov edx, dword ptr OV(OV_SIZE_IDX)
        call tool_px
        mov dword ptr OV(OV_ACT + AN_SIZE), eax
        lea rcx, OV(OV_ACT)
        mov rdx, rbx
        call anno_push
        mov eax, dword ptr OV(OV_TOOL)
        sub eax, T_PEN
        cmp eax, T_MARKER - T_PEN
        jbe 2f
        lea rcx, OV(OV_ACT)
        mov rdx, rbx
        call anno_push
2:
        mov byte ptr OV(OV_HAS_ACT), 1
        mov dword ptr OV(OV_DRAG), DR_DRAW
        inc dword ptr OV(OV_ACT_VER)
        add rsp, 32
        pop rbx
        ret
ENDF

/* void end_draw(void): keep the drawn annotation unless it is too small */
FUNC end_draw
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        mov dword ptr OV(OV_DRAG), DR_NONE
        cmp byte ptr OV(OV_HAS_ACT), 0
        je .Led_ret
        mov rbx, qword ptr OV(OV_ACT + AN_PT)   /* &pt[0] */
        movsxd rsi, dword ptr OV(OV_ACT + AN_NPT)
        lea rsi, [rbx + rsi*8 - 8]              /* &pt[npt - 1] */
        mov ecx, dword ptr [rbx + PT_X]         /* p0 */
        mov edx, dword ptr [rbx + PT_Y]
        mov r8d, dword ptr [rsi + PT_X]         /* p1 */
        mov r9d, dword ptr [rsi + PT_Y]
        mov byte ptr OV(OV_HAS_ACT), 0
        inc dword ptr OV(OV_ACT_VER)
        mov eax, dword ptr OV(OV_ACT + AN_TOOL)
        cmp eax, T_RECT
        je .Led_box
        cmp eax, T_ELLIPSE
        je .Led_box
        cmp eax, T_MOSAIC
        je .Led_box
        cmp eax, T_LINE
        je .Led_seg
        cmp eax, T_ARROW
        je .Led_seg
        xor edx, edx                    /* pens, text, numbers: kept, not picked */
        jmp .Led_commit
.Led_seg:                               /* |dx| + |dy| >= 3 */
        mov eax, r8d
        sub eax, ecx
        mov r10d, eax
        neg r10d
        cmovs r10d, eax
        mov eax, r9d
        sub eax, edx
        mov r11d, eax
        neg r11d
        cmovs r11d, eax
        add r10d, r11d
        cmp r10d, 3
        jl .Led_drop
        mov edx, 1
        jmp .Led_commit
.Led_box:                               /* |dx| >= 2 && |dy| >= 2 */
        mov eax, r8d
        sub eax, ecx
        mov r10d, eax
        neg r10d
        cmovs r10d, eax
        cmp r10d, 2
        jl .Led_drop
        mov eax, r9d
        sub eax, edx
        mov r11d, eax
        neg r11d
        cmovs r11d, eax
        cmp r11d, 2
        jl .Led_drop
        /* stored as top-left / bottom-right (rect_corners) for the handles */
        mov eax, ecx
        cmp eax, r8d
        cmovg eax, r8d                  /* left */
        mov r11d, ecx
        cmp r11d, r8d
        cmovl r11d, r8d                 /* right - 1 */
        mov r10d, edx
        cmp r10d, r9d
        cmovg r10d, r9d                 /* top */
        cmp r9d, edx
        cmovl r9d, edx                  /* bottom - 1 */
        mov dword ptr [rbx + PT_X], eax
        mov dword ptr [rbx + PT_Y], r10d
        mov dword ptr [rsi + PT_X], r11d
        mov dword ptr [rsi + PT_Y], r9d
        mov edx, 1
.Led_commit:
        lea rcx, OV(OV_ACT)
        add rsp, 40
        pop rsi
        pop rbx
        jmp commit_anno
.Led_drop:
        lea rcx, OV(OV_ACT)
        add rsp, 40
        pop rsi
        pop rbx
        jmp anno_free
.Led_ret:
        add rsp, 40
        pop rsi
        pop rbx
        ret
ENDF

/* void begin_grab(int code, POINT p): start moving the picked annotation (code 0)
 * or dragging one of its handles */
FUNC begin_grab
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        mov ebx, ecx
        mov rsi, rdx
        lea rcx, OV(OV_ORIG)
        call anno_free
        movsxd rax, dword ptr OV(OV_PICK)
        test eax, eax
        js .Lbr_ret
        imul rdx, rax, AN_BYTES
        add rdx, qword ptr OV(OV_ANN)
        lea rcx, OV(OV_ORIG)
        call anno_copy
        test al, al
        jz .Lbr_ret
        movsxd rax, dword ptr OV(OV_PICK)
        imul rax, rax, AN_BYTES
        add rax, qword ptr OV(OV_ANN)
        cmp dword ptr [rax + AN_TOOL], T_MOSAIC
        jne 1f
        call canvas_cover_sel
1:
        xor eax, eax
        test ebx, ebx
        setnz al
        add eax, DR_AMOVE               /* code ? DR_AGRAB : DR_AMOVE */
        mov dword ptr OV(OV_DRAG), eax
        mov dword ptr OV(OV_GRAB), ebx
        mov qword ptr OV(OV_DRAG0), rsi
        mov byte ptr OV(OV_NUDGING), 0
.Lbr_ret:
        add rsp, 40
        pop rsi
        pop rbx
        ret
ENDF

/* void grab_update(POINT p): the picked annotation follows the drag */
FUNC grab_update
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 32
        ENDPROLOG
        movsxd rbx, dword ptr OV(OV_PICK)
        imul rbx, rbx, AN_BYTES
        add rbx, qword ptr OV(OV_ANN)   /* a */
        mov eax, ecx
        sub eax, dword ptr OV(OV_DRAG0 + PT_X)  /* dx */
        shr rcx, 32
        sub ecx, dword ptr OV(OV_DRAG0 + PT_Y)  /* dy */
        cmp dword ptr OV(OV_DRAG), DR_AMOVE
        jne .Lgu_handle
        movd xmm1, eax                  /* a->pt[k] = o->pt[k] + (dx, dy), two at a time */
        movd xmm2, ecx
        punpckldq xmm1, xmm2
        punpcklqdq xmm1, xmm1
        mov r8, qword ptr [rbx + AN_PT]
        mov r9, qword ptr OV(OV_ORIG + AN_PT)
        movsxd r10, dword ptr [rbx + AN_NPT]
        xor r11d, r11d
.Lgu_pair:
        lea rax, [r11 + 2]
        cmp rax, r10
        jg .Lgu_last
        movdqu xmm0, xmmword ptr [r9 + r11*8]
        paddd xmm0, xmm1
        movdqu xmmword ptr [r8 + r11*8], xmm0
        mov r11, rax
        jmp .Lgu_pair
.Lgu_last:
        cmp r11, r10
        jge .Lgu_done
        movq xmm0, qword ptr [r9 + r11*8]
        paddd xmm0, xmm1
        movq qword ptr [r8 + r11*8], xmm0
        jmp .Lgu_done
.Lgu_handle:
        mov edx, dword ptr OV(OV_GRAB)
        test edx, END_A | END_B
        jz .Lgu_box
        /* a line end: k follows the drag, constrained against the other end */
        mov r8d, dword ptr [rbx + AN_NPT]
        dec r8d
        xor esi, esi                    /* k */
        xor edi, edi                    /* other */
        cmp edx, END_A
        jne 1f
        mov edi, r8d
        jmp 2f
1:
        mov esi, r8d
2:
        mov r9, qword ptr OV(OV_ORIG + AN_PT)
        movsxd rsi, esi
        mov r11d, dword ptr [r9 + rsi*8 + PT_X]
        add r11d, eax
        mov edx, dword ptr [r9 + rsi*8 + PT_Y]
        add edx, ecx
        shl rdx, 32
        or rdx, r11                     /* q */
        mov r9, qword ptr [rbx + AN_PT]
        movsxd rdi, edi
        mov rcx, qword ptr [r9 + rdi*8] /* a->pt[other] */
        mov r8d, dword ptr [rbx + AN_TOOL]
        call constrain
        mov r9, qword ptr [rbx + AN_PT]
        mov qword ptr [r9 + rsi*8], rax
        jmp .Lgu_done
.Lgu_box:                               /* a box edge or corner */
        mov r9, qword ptr OV(OV_ORIG + AN_PT)
        movsxd r10, dword ptr OV(OV_ORIG + AN_NPT)
        lea r10, [r9 + r10*8 - 8]
        mov r8d, dword ptr [r9 + PT_X]  /* o->pt[0] */
        mov r9d, dword ptr [r9 + PT_Y]
        mov r11d, dword ptr [r10 + PT_Y]        /* o->pt[npt - 1] */
        mov r10d, dword ptr [r10 + PT_X]
        mov esi, r8d                    /* r = rect_corners(...) */
        cmp esi, r10d
        cmovg esi, r10d                 /* left */
        mov edi, r8d
        cmp edi, r10d
        cmovl edi, r10d
        inc edi                         /* right */
        mov r8d, r9d
        cmp r8d, r11d
        cmovg r8d, r11d                 /* top */
        mov r10d, r9d
        cmp r10d, r11d
        cmovl r10d, r11d
        inc r10d                        /* bottom */
        test edx, EDGE_L
        jz 3f
        add esi, eax
3:
        test edx, EDGE_R
        jz 4f
        add edi, eax
4:
        test edx, EDGE_T
        jz 5f
        add r8d, ecx
5:
        test edx, EDGE_B
        jz 6f
        add r10d, ecx
6:
        mov eax, esi                    /* n: normalized, at least 2 x 2 */
        cmp eax, edi
        cmovg eax, edi
        cmp edi, esi
        cmovl edi, esi
        mov ecx, r8d
        cmp ecx, r10d
        cmovg ecx, r10d
        cmp r10d, r8d
        cmovl r10d, r8d
        mov edx, edi
        sub edx, eax
        cmp edx, 2
        jge 7f
        lea edi, [rax + 2]
7:
        mov edx, r10d
        sub edx, ecx
        cmp edx, 2
        jge 8f
        lea r10d, [rcx + 2]
8:
        mov r9, qword ptr [rbx + AN_PT]
        mov dword ptr [r9 + PT_X], eax
        mov dword ptr [r9 + PT_Y], ecx
        movsxd r11, dword ptr [rbx + AN_NPT]
        lea r11, [r9 + r11*8 - 8]
        dec edi
        mov dword ptr [r11 + PT_X], edi
        dec r10d
        mov dword ptr [r11 + PT_Y], r10d
.Lgu_done:
        inc dword ptr OV(OV_ACT_VER)
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void end_grab(void): finish a move or handle drag, one undo step if anything changed */
FUNC end_grab
        ALLOC 40
        ENDPROLOG
        mov eax, dword ptr OV(OV_DRAG)
        sub eax, DR_AMOVE
        cmp eax, DR_AGRAB - DR_AMOVE
        ja .Leg_ret
        mov dword ptr OV(OV_DRAG), DR_NONE
        movsxd rax, dword ptr OV(OV_PICK)
        test eax, eax
        js .Leg_free
        imul rcx, rax, AN_BYTES
        add rcx, qword ptr OV(OV_ANN)
        lea rdx, OV(OV_ORIG)
        call anno_same
        test al, al
        jnz .Leg_free
        mov ecx, OP_EDIT
        mov edx, dword ptr OV(OV_PICK)
        lea r8, OV(OV_ORIG)
        call op_push
        jmp .Leg_ver
.Leg_free:
        lea rcx, OV(OV_ORIG)
        call anno_free
.Leg_ver:
        inc dword ptr OV(OV_ACT_VER)
.Leg_ret:
        add rsp, 40
        ret
ENDF

/* void cancel_grab(void): right-click or capture loss mid-drag puts the annotation back */
FUNC cancel_grab
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov eax, dword ptr OV(OV_DRAG)
        sub eax, DR_AMOVE
        cmp eax, DR_AGRAB - DR_AMOVE
        ja .Lcg_ret
        mov dword ptr OV(OV_DRAG), DR_NONE
        movsxd rbx, dword ptr OV(OV_PICK)
        test ebx, ebx
        js .Lcg_free
        imul rbx, rbx, AN_BYTES
        add rbx, qword ptr OV(OV_ANN)
        mov rcx, rbx
        call anno_free
        movups xmm0, xmmword ptr OV(OV_ORIG)    /* O.ann[O.pick] = O.orig, then O.orig is empty */
        movups xmm1, xmmword ptr OV(OV_ORIG + 16)
        movups xmm2, xmmword ptr OV(OV_ORIG + 32)
        movups xmmword ptr [rbx], xmm0
        movups xmmword ptr [rbx + 16], xmm1
        movups xmmword ptr [rbx + 32], xmm2
        xorps xmm0, xmm0
        movups xmmword ptr OV(OV_ORIG), xmm0
        movups xmmword ptr OV(OV_ORIG + 16), xmm0
        movups xmmword ptr OV(OV_ORIG + 32), xmm0
        jmp .Lcg_ver
.Lcg_free:
        lea rcx, OV(OV_ORIG)
        call anno_free
.Lcg_ver:
        inc dword ptr OV(OV_ACT_VER)
.Lcg_ret:
        add rsp, 32
        pop rbx
        ret
ENDF

/* void on_button(int id): a toolbar button was clicked */
FUNC on_button
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov ebx, ecx
        cmp byte ptr OV(OV_TE_ON), 0
        je .Lob_normal
        lea eax, [rbx - B_SIZE]
        cmp eax, B_COLOR + 8 - B_SIZE
        jae .Lob_normal
        cmp eax, 3                      /* restyle the text being typed */
        jae .Lob_tecolor
        mov dword ptr OV(OV_SIZE_IDX), eax
        mov ecx, T_TEXT
        mov edx, eax
        call tool_px
        mov dword ptr OV(OV_TE_PX), eax
        API DestroyCaret
        call text_caret_create
        jmp .Lob_teshown
.Lob_tecolor:
        lea eax, [rbx - B_COLOR]
        mov dword ptr OV(OV_COLOR_IDX), eax
        movsxd rax, eax
        lea rcx, [rip + kColors]
        mov eax, dword ptr [rcx + rax*4]
        mov dword ptr OV(OV_TE_COLOR), eax
.Lob_teshown:
        inc dword ptr OV(OV_ACT_VER)
        jmp .Lob_refresh
.Lob_normal:
        mov ecx, 1
        call text_end
        lea eax, [rbx - T_RECT]
        cmp eax, T_NUMBER - T_RECT
        ja 1f
        mov ecx, ebx
        call set_tool
        jmp .Lob_refresh
1:
        lea eax, [rbx - B_SIZE]
        cmp eax, 3
        jae 2f
        mov dword ptr OV(OV_SIZE_IDX), eax
        mov ecx, eax
        mov edx, -1
        call pick_style
        jmp .Lob_refresh
2:
        lea eax, [rbx - B_COLOR]
        cmp eax, 8
        jae 3f
        mov dword ptr OV(OV_COLOR_IDX), eax
        mov ecx, -1
        mov edx, eax
        call pick_style
        jmp .Lob_refresh
3:
        cmp ebx, B_UNDO
        jne 4f
        call undo
        jmp .Lob_refresh
4:
        cmp ebx, B_REDO
        jne 5f
        call redo
        jmp .Lob_refresh
5:
        mov ecx, ACT_PIN
        cmp ebx, B_PIN
        je .Lob_finish
        mov ecx, ACT_SAVE
        cmp ebx, B_SAVE
        je .Lob_finish
        mov ecx, ACT_COPY
        cmp ebx, B_OK
        je .Lob_finish
        cmp ebx, B_CLOSE
        jne .Lob_refresh
        add rsp, 32
        pop rbx
        jmp ov_cancel
.Lob_finish:
        add rsp, 32
        pop rbx
        jmp finish
.Lob_refresh:
        add rsp, 32
        pop rbx
        jmp refresh
ENDF
