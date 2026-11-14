/* ov_input.S: the capture overlay's input: mouse and keyboard handling, the window
 * procedure, and start-up (ov_init).
 *
 * The state O and the constant tables live in ov_base; the other functions called
 * here are the overlay's other parts and Windows.
 *
 * What makes it fast: WM_MOUSEMOVE is tested first in ov_proc, every other message
 * goes through one table lookup; the handlers keep the state in O and tail-call
 * refresh. */
#include "asm.inc"
#include "ov_layout.inc"

/* ---- Windows values ---------------------------------------------------------------- */
#define W_WM_PAINT 0x000F
#define W_WM_CLOSE 0x0010
#define W_WM_ERASEBKGND 0x0014
#define W_WM_SETCURSOR 0x0020
#define W_WM_DISPLAYCHANGE 0x007E
#define W_WM_KEYDOWN 0x0100
#define W_WM_CHAR 0x0102
#define W_WM_SYSKEYDOWN 0x0104
#define W_WM_TIMER 0x0113
#define W_WM_MOUSEMOVE 0x0200
#define W_WM_LBUTTONDOWN 0x0201
#define W_WM_LBUTTONUP 0x0202
#define W_WM_LBUTTONDBLCLK 0x0203
#define W_WM_RBUTTONUP 0x0205
#define W_WM_MOUSEWHEEL 0x020A
#define W_WM_CAPTURECHANGED 0x0215
#define W_WM_DPICHANGED 0x02E0
#define W_HTCLIENT 1
#define W_VK_BACK 0x08
#define W_VK_RETURN 0x0D
#define W_VK_SHIFT 0x10
#define W_VK_CONTROL 0x11
#define W_VK_ESCAPE 0x1B
#define W_VK_LEFT 0x25
#define W_VK_UP 0x26
#define W_VK_RIGHT 0x27
#define W_VK_DOWN 0x28
#define W_VK_DELETE 0x2E
#define W_CS_DBLCLKS 0x0008
#define W_WS_POPUP 0x80000000
#define W_WS_EX_TOPMOST 0x00000008
#define W_WS_EX_TOOLWINDOW 0x00000080
#define W_WS_EX_NOREDIRECTIONBITMAP 0x00200000
#define W_DWMWA_TRANSITIONS_FORCEDISABLED 3
#define W_IDC_ARROW 32512               /* = (int)(uintptr_t)IDC_ARROW */
#define W_IDC_IBEAM 32513               /* = (int)(uintptr_t)IDC_IBEAM */
#define W_IDC_CROSS 32515               /* = (int)(uintptr_t)IDC_CROSS */
#define W_IDC_SIZENWSE 32642            /* = (int)(uintptr_t)IDC_SIZENWSE */
#define W_IDC_SIZENESW 32643            /* = (int)(uintptr_t)IDC_SIZENESW */
#define W_IDC_SIZEWE 32644              /* = (int)(uintptr_t)IDC_SIZEWE */
#define W_IDC_SIZENS 32645              /* = (int)(uintptr_t)IDC_SIZENS */
#define W_IDC_SIZEALL 32646             /* = (int)(uintptr_t)IDC_SIZEALL */
/* WNDCLASSW */
#define W_WC_STYLE 0                    /* = offsetof(WNDCLASSW, style) */
#define W_WC_LPFNWNDPROC 8              /* = offsetof(WNDCLASSW, lpfnWndProc) */
#define W_WC_HINSTANCE 24               /* = offsetof(WNDCLASSW, hInstance) */
#define W_WC_LPSZCLASSNAME 64           /* = offsetof(WNDCLASSW, lpszClassName) */
#define W_WC_SIZE 72                    /* = sizeof(WNDCLASSW) */
/* letter and digit keys are their ASCII codes */
#define K_0 0x30                        /* = '0' */
#define K_1 0x31                        /* = '1' */
#define K_A 0x41                        /* = 'A' */
#define K_C 0x43                        /* = 'C' */
#define K_S 0x53                        /* = 'S' */
#define K_T 0x54                        /* = 'T' */
#define K_V 0x56                        /* = 'V' */
#define K_Y 0x59                        /* = 'Y' */
#define K_Z 0x5A                        /* = 'Z' */

/* ---- what the code below assumes about the overlay's layout ------------------------- */
        .if OV_RUBBER != OV_LDOWN + 1
        .error "ldown and rubber are cleared together"
        .endif
        .if OV_CHAIN_BYTES != RC_SIZE
        .error "chain entries are RECTs"
        .endif
        .if AN_BYTES != 48
        .error "a new Anno is cleared with three 16-byte stores"
        .endif
        .if OV_C_ARROW != OV_C_CROSS + 8 || OV_C_MOVE != OV_C_CROSS + 16 || OV_C_IBEAM != OV_C_CROSS + 24 || OV_C_WE != OV_C_CROSS + 32 || OV_C_NS != OV_C_CROSS + 40 || OV_C_NWSE != OV_C_CROSS + 48 || OV_C_NESW != OV_C_CROSS + 56
        .error "the cursor handles are loaded in a loop"
        .endif

/* ---- constants ------------------------------------------------------------------------ */
        .section .rdata$ov_input,"dr"
        .balign 4
.Lf_3:          .long 0x40400000                /* 3.0f */
        .balign 2
/* L"sniplite.overlay" */
w_ov_class:     .short 0x0073, 0x006E, 0x0069, 0x0070, 0x006C, 0x0069, 0x0074, 0x0065, 0x002E, 0x006F, 0x0076, 0x0065, 0x0072, 0x006C, 0x0061, 0x0079, 0x0000
/* L"sniplite" */
w_ov_title:     .short 0x0073, 0x006E, 0x0069, 0x0070, 0x006C, 0x0069, 0x0074, 0x0065, 0x0000
/* L"0123 \x00D7 截图" */
w_ov_warm:      .short 0x0030, 0x0031, 0x0032, 0x0033, 0x0020, 0x00D7, 0x0020, 0x622A, 0x56FE, 0x0000
/* L"\n" */
w_ov_nl:        .short 0x000A, 0x0000
/* the cursor ids, in the order of O.c_cross .. O.c_nesw */
.Lcursor_ids:   .short W_IDC_CROSS, W_IDC_ARROW, W_IDC_SIZEALL, W_IDC_IBEAM
                .short W_IDC_SIZEWE, W_IDC_SIZENS, W_IDC_SIZENWSE, W_IDC_SIZENESW

/* ---- helpers --------------------------------------------------------------------------- */

/* \d = CLAMPI(\s, 0, \hi) for 32-bit registers; \d, \s and \z must differ (\z is zeroed) */
.macro CLAMP0 d, s, hi, z
        mov \d, \s
        cmp \s, \hi
        cmovg \d, \hi
        xor \z, \z
        test \s, \s
        cmovs \d, \z
.endm

/* Jump to \no unless rect_has(&O.sel, p.x, p.y), p packed in rbx (x low, y high). Clobbers eax. */
.macro SEL_HAS_RBX no
        cmp ebx, dword ptr [rip + O + OV_SEL + RC_L]
        jl \no
        cmp ebx, dword ptr [rip + O + OV_SEL + RC_R]
        jge \no
        mov rax, rbx
        shr rax, 32
        cmp eax, dword ptr [rip + O + OV_SEL + RC_T]
        jl \no
        cmp eax, dword ptr [rip + O + OV_SEL + RC_B]
        jge \no
.endm

/* \d = abs(\s) for 32-bit registers (\d != \s); INT_MIN stays INT_MIN */
.macro ABS32 d, s
        mov \d, \s
        neg \d
        cmovl \d, \s
.endm

/* rcx = POINT {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)} from lp in r9; clobbers rax */
.macro LPARAM_POINT
        movsx ecx, r9w
        mov eax, r9d
        sar eax, 16
        shl rax, 32
        or rcx, rax
.endm

/* ---- mouse ----------------------------------------------------------------------------- */

/* void on_mouse_move(POINT p) */
FUNC on_mouse_move
        PUSHREG rbx                     /* p, clamped */
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        mov edx, dword ptr [rip + O + OV_SHOT + SHOT_VW]
        dec edx
        CLAMP0 eax, ecx, edx, r8d       /* O.cur = p kept in the client area */
        shr rcx, 32
        mov edx, dword ptr [rip + O + OV_SHOT + SHOT_VH]
        dec edx
        CLAMP0 r9d, ecx, edx, r8d
        shl r9, 32
        or rax, r9
        mov qword ptr [rip + O + OV_CUR], rax
        mov rbx, rax
        cmp dword ptr [rip + O + OV_PHASE], PH_SELECT
        jne .Lmm_edit
        cmp byte ptr [rip + O + OV_LDOWN], 0
        je .Lmm_scale
        cmp byte ptr [rip + O + OV_RUBBER], 0
        jne .Lmm_refresh
        movss xmm0, dword ptr [rip + .Lf_3]     /* pressed: a rubber band once it moved S(3) */
        mulss xmm0, dword ptr [rip + O + OV_S]
        LROUNDF ecx, xmm0, xmm1
        mov edx, 1
        cmp ecx, edx
        cmovl ecx, edx
        mov eax, ebx
        sub eax, dword ptr [rip + O + OV_DOWN + PT_X]
        ABS32 edx, eax
        cmp edx, ecx
        jg .Lmm_rubber
        mov rax, rbx
        shr rax, 32
        sub eax, dword ptr [rip + O + OV_DOWN + PT_Y]
        ABS32 edx, eax
        cmp edx, ecx
        jle .Lmm_refresh
.Lmm_rubber:
        mov byte ptr [rip + O + OV_RUBBER], 1
        jmp .Lmm_refresh
.Lmm_scale:                             /* hovering: the scale and the window chain follow */
        mov esi, dword ptr [rip + O + OV_S]
        call update_scale
        movd xmm0, esi
        ucomiss xmm0, dword ptr [rip + O + OV_S]
        jp 1f
        je 2f
1:      call update_scale
2:      call update_chain
        jmp .Lmm_refresh

.Lmm_edit:
        mov eax, dword ptr [rip + O + OV_DRAG]
        test eax, eax
        jz .Lmm_hover
        cmp eax, DR_DRAW
        je .Lmm_draw
        cmp eax, DR_MOVE
        je .Lmm_move
        cmp eax, DR_RESIZE
        je .Lmm_resize
        cmp eax, DR_BUTTON
        je .Lmm_button
        cmp eax, DR_AMOVE
        je .Lmm_grab
        cmp eax, DR_AGRAB
        jne .Lmm_hover
.Lmm_grab:                              /* the picked annotation or one of its handles */
        cmp dword ptr [rip + O + OV_PICK], 0
        jl .Lmm_refresh
        mov rcx, rbx
        call grab_update
        jmp .Lmm_refresh

.Lmm_hover:                             /* no drag: the button under the cursor, its tooltip timer */
        mov rcx, rbx
        call tb_hit
        xor ecx, ecx
        test eax, eax
        cmovs eax, ecx
        cmp eax, dword ptr [rip + O + OV_HOVER]
        je .Lmm_refresh
        mov dword ptr [rip + O + OV_HOVER], eax
        mov dword ptr [rip + O + OV_TIP], 0
        mov esi, eax
        mov rcx, qword ptr [rip + O + OV_HWND]
        mov edx, TIMER_TIP
        API KillTimer
        test esi, esi
        jz .Lmm_refresh
        mov rcx, qword ptr [rip + O + OV_HWND]
        mov edx, TIMER_TIP
        mov r8d, 450
        xor r9d, r9d
        API SetTimer
        jmp .Lmm_refresh

.Lmm_button:                            /* pressed on a button: lit while over it */
        mov rcx, rbx
        call tb_hit
        xor ecx, ecx
        cmp eax, dword ptr [rip + O + OV_BTN_DOWN]
        cmovne eax, ecx
        mov dword ptr [rip + O + OV_HOVER], eax
        jmp .Lmm_refresh

.Lmm_draw:
        cmp byte ptr [rip + O + OV_HAS_ACT], 0
        je .Lmm_refresh
        mov r8d, dword ptr [rip + O + OV_ACT + AN_TOOL]
        mov rdx, qword ptr [rip + O + OV_ACT + AN_PT]
        lea eax, [r8 - T_PEN]
        cmp eax, T_MARKER - T_PEN
        jbe .Lmm_pen
        mov rcx, qword ptr [rdx]        /* pt[1] = constrain(pt[0], p, tool) */
        mov rdx, rbx
        call constrain
        mov rdx, qword ptr [rip + O + OV_ACT + AN_PT]
        mov qword ptr [rdx + 8], rax
        jmp .Lmm_ver
.Lmm_pen:                               /* pens: a new point unless it repeats the last */
        movsxd rax, dword ptr [rip + O + OV_ACT + AN_NPT]
        cmp qword ptr [rdx + rax*8 - 8], rbx
        je .Lmm_ver
        lea rcx, [rip + O + OV_ACT]
        mov rdx, rbx
        call anno_push
.Lmm_ver:
        inc dword ptr [rip + O + OV_ACT_VER]
        jmp .Lmm_refresh

.Lmm_move:                              /* the selection follows, kept on screen */
        mov r8d, dword ptr [rip + O + OV_SEL0 + RC_R]
        sub r8d, dword ptr [rip + O + OV_SEL0 + RC_L]   /* w */
        mov r9d, dword ptr [rip + O + OV_SEL0 + RC_B]
        sub r9d, dword ptr [rip + O + OV_SEL0 + RC_T]   /* h */
        mov ecx, dword ptr [rip + O + OV_SEL0 + RC_L]
        add ecx, ebx
        sub ecx, dword ptr [rip + O + OV_DRAG0 + PT_X]
        mov edx, dword ptr [rip + O + OV_SHOT + SHOT_VW]
        sub edx, r8d
        CLAMP0 eax, ecx, edx, r10d      /* x */
        mov rcx, rbx
        shr rcx, 32
        add ecx, dword ptr [rip + O + OV_SEL0 + RC_T]
        sub ecx, dword ptr [rip + O + OV_DRAG0 + PT_Y]
        mov edx, dword ptr [rip + O + OV_SHOT + SHOT_VH]
        sub edx, r9d
        CLAMP0 r11d, ecx, edx, r10d     /* y */
        cmp eax, dword ptr [rip + O + OV_SEL + RC_L]
        jne 1f
        cmp r11d, dword ptr [rip + O + OV_SEL + RC_T]
        je .Lmm_refresh
1:      mov dword ptr [rip + O + OV_SEL + RC_L], eax
        mov dword ptr [rip + O + OV_SEL + RC_T], r11d
        add eax, r8d
        mov dword ptr [rip + O + OV_SEL + RC_R], eax
        add r11d, r9d
        mov dword ptr [rip + O + OV_SEL + RC_B], r11d
        call sel_changed
        jmp .Lmm_refresh

.Lmm_resize:                            /* the grabbed edges follow; at least 1x1, on screen */
        mov eax, dword ptr [rip + O + OV_SEL0 + RC_L]
        mov ecx, dword ptr [rip + O + OV_SEL0 + RC_T]
        mov edx, dword ptr [rip + O + OV_SEL0 + RC_R]
        mov r8d, dword ptr [rip + O + OV_SEL0 + RC_B]
        mov r9d, ebx
        sub r9d, dword ptr [rip + O + OV_DRAG0 + PT_X]  /* dx */
        mov r10, rbx
        shr r10, 32
        sub r10d, dword ptr [rip + O + OV_DRAG0 + PT_Y] /* dy */
        mov r11d, dword ptr [rip + O + OV_EDGES]
        test r11d, EDGE_L
        jz 1f
        add eax, r9d
1:      test r11d, EDGE_R
        jz 1f
        add edx, r9d
1:      test r11d, EDGE_T
        jz 1f
        add ecx, r10d
1:      test r11d, EDGE_B
        jz 1f
        add r8d, r10d
1:      mov r9d, eax                    /* corners in order */
        cmp eax, edx
        cmovg eax, edx
        cmovg edx, r9d
        mov r9d, ecx
        cmp ecx, r8d
        cmovg ecx, r8d
        cmovg r8d, r9d
        mov r9d, edx
        sub r9d, eax
        cmp r9d, 1
        jge 1f
        lea edx, [rax + 1]
1:      mov r9d, r8d
        sub r9d, ecx
        cmp r9d, 1
        jge 1f
        lea r8d, [rcx + 1]
1:      xor r9d, r9d                    /* rect_isect with the client area */
        test eax, eax
        cmovs eax, r9d
        test ecx, ecx
        cmovs ecx, r9d
        cmp edx, dword ptr [rip + O + OV_SHOT + SHOT_VW]
        cmovg edx, dword ptr [rip + O + OV_SHOT + SHOT_VW]
        cmp r8d, dword ptr [rip + O + OV_SHOT + SHOT_VH]
        cmovg r8d, dword ptr [rip + O + OV_SHOT + SHOT_VH]
        cmp edx, eax                    /* empty: nothing */
        jle .Lmm_refresh
        cmp r8d, ecx
        jle .Lmm_refresh
        cmp eax, dword ptr [rip + O + OV_SEL + RC_L]
        jne 1f
        cmp ecx, dword ptr [rip + O + OV_SEL + RC_T]
        jne 1f
        cmp edx, dword ptr [rip + O + OV_SEL + RC_R]
        jne 1f
        cmp r8d, dword ptr [rip + O + OV_SEL + RC_B]
        je .Lmm_refresh
1:      mov dword ptr [rip + O + OV_SEL + RC_L], eax
        mov dword ptr [rip + O + OV_SEL + RC_T], ecx
        mov dword ptr [rip + O + OV_SEL + RC_R], edx
        mov dword ptr [rip + O + OV_SEL + RC_B], r8d
        call sel_changed
.Lmm_refresh:
        add rsp, 40
        pop rsi
        pop rbx
        jmp refresh
ENDF

/* void on_lbutton_down(POINT p) */
#define LD_A 32                         /* Anno: a new number */
FUNC on_lbutton_down
        PUSHREG rbx                     /* p */
        ALLOC 80
        ENDPROLOG
        mov rbx, rcx
        mov qword ptr [rip + O + OV_CUR], rcx
        mov rcx, qword ptr [rip + O + OV_HWND]
        API SetCapture
        cmp dword ptr [rip + O + OV_PHASE], PH_SELECT
        jne .Lld_edit
        mov byte ptr [rip + O + OV_LDOWN], 1
        mov qword ptr [rip + O + OV_DOWN], rbx
        mov byte ptr [rip + O + OV_RUBBER], 0
        jmp .Lld_refresh
.Lld_edit:
        mov rcx, rbx
        call tb_hit
        test eax, eax
        jz .Lld_canvas
        jns .Lld_button
        mov ecx, 1                      /* the bar's background (a button decides on release) */
        call text_end
        jmp .Lld_refresh
.Lld_button:
        mov dword ptr [rip + O + OV_DRAG], DR_BUTTON
        mov dword ptr [rip + O + OV_BTN_DOWN], eax
        mov dword ptr [rip + O + OV_HOVER], eax
        jmp .Lld_refresh
.Lld_canvas:
        mov dword ptr [rip + O + OV_TIP], 0
        cmp byte ptr [rip + O + OV_TE_ON], 0
        je .Lld_grab
        mov ecx, 1                      /* typing: the click ends the text */
        call text_end
        cmp dword ptr [rip + O + OV_TOOL], T_TEXT
        jne .Lld_refresh
        jmp .Lld_text_at
.Lld_grab:                              /* 1. a handle of the selected annotation */
        mov rcx, rbx
        call pick_grab_at
        test eax, eax
        jz .Lld_edges
        mov ecx, eax
        mov rdx, rbx
        call begin_grab
        jmp .Lld_refresh
.Lld_edges:                             /* 2. the selection's own handles and edges */
        mov rcx, rbx
        call hit_edges
        test eax, eax
        jz .Lld_tool
        mov dword ptr [rip + O + OV_DRAG], DR_RESIZE
        mov dword ptr [rip + O + OV_EDGES], eax
        jmp .Lld_drag0
.Lld_tool:
        cmp dword ptr [rip + O + OV_TOOL], T_TEXT
        jne .Lld_target
        call pick_clear
.Lld_text_at:
        SEL_HAS_RBX .Lld_refresh
        mov rcx, rbx
        call text_at
        jmp .Lld_refresh
.Lld_target:                            /* 3. an annotation: select it and drag it */
        mov rcx, rbx
        call grab_target
        test eax, eax
        js .Lld_new
        mov ecx, eax
        call pick_set
        xor ecx, ecx
        mov rdx, rbx
        call begin_grab
        jmp .Lld_refresh
.Lld_new:                               /* 4. the tool, or moving the selection */
        call pick_clear
        mov eax, dword ptr [rip + O + OV_TOOL]
        cmp eax, T_NUMBER
        je .Lld_number
        test eax, eax
        jz .Lld_move
        mov rcx, rbx
        call begin_draw
        jmp .Lld_refresh
.Lld_move:
        SEL_HAS_RBX .Lld_refresh
        mov dword ptr [rip + O + OV_DRAG], DR_MOVE
.Lld_drag0:
        movups xmm0, xmmword ptr [rip + O + OV_SEL]
        movups xmmword ptr [rip + O + OV_SEL0], xmm0
        mov qword ptr [rip + O + OV_DRAG0], rbx
        jmp .Lld_refresh
.Lld_number:                            /* the number tool places its disc at once */
        SEL_HAS_RBX .Lld_refresh
        xorps xmm0, xmm0
        movups xmmword ptr [rsp + LD_A], xmm0
        movups xmmword ptr [rsp + LD_A + 16], xmm0
        movups xmmword ptr [rsp + LD_A + 32], xmm0
        mov dword ptr [rsp + LD_A + AN_TOOL], T_NUMBER
        movsxd rax, dword ptr [rip + O + OV_COLOR_IDX]
        lea rcx, [rip + kColors]
        mov eax, dword ptr [rcx + rax*4]
        mov dword ptr [rsp + LD_A + AN_COLOR], eax
        mov ecx, T_NUMBER
        mov edx, dword ptr [rip + O + OV_SIZE_IDX]
        call tool_px
        mov dword ptr [rsp + LD_A + AN_SIZE], eax
        call next_number
        mov dword ptr [rsp + LD_A + AN_NUM], eax
        lea rcx, [rsp + LD_A]
        mov rdx, rbx
        call anno_push
        lea rcx, [rsp + LD_A]
        test al, al
        jz 1f
        xor edx, edx
        call commit_anno
        jmp .Lld_refresh
1:      call anno_free
.Lld_refresh:
        add rsp, 80
        pop rbx
        jmp refresh
ENDF

/* void on_lbutton_up(POINT p) */
FUNC on_lbutton_up
        PUSHREG rbx                     /* p */
        ALLOC 48                        /* RECT at 32 */
        ENDPROLOG
        mov rbx, rcx
        call release_capture
        cmp dword ptr [rip + O + OV_PHASE], PH_SELECT
        jne .Llu_edit
        cmp byte ptr [rip + O + OV_LDOWN], 0
        je .Llu_ret
        mov byte ptr [rip + O + OV_LDOWN], 0
        cmp byte ptr [rip + O + OV_RUBBER], 0
        je .Llu_hl
        mov byte ptr [rip + O + OV_RUBBER], 0
        mov eax, dword ptr [rip + O + OV_DOWN + PT_X]   /* the rubber band: rect_corners(O.down, O.cur) */
        mov ecx, dword ptr [rip + O + OV_CUR + PT_X]
        mov edx, eax
        cmp eax, ecx
        cmovg eax, ecx
        cmovg ecx, edx
        inc ecx
        mov dword ptr [rsp + 32 + RC_L], eax
        mov dword ptr [rsp + 32 + RC_R], ecx
        mov eax, dword ptr [rip + O + OV_DOWN + PT_Y]
        mov ecx, dword ptr [rip + O + OV_CUR + PT_Y]
        mov edx, eax
        cmp eax, ecx
        cmovg eax, ecx
        cmovg ecx, edx
        inc ecx
        mov dword ptr [rsp + 32 + RC_T], eax
        mov dword ptr [rsp + 32 + RC_B], ecx
        jmp .Llu_enter
.Llu_hl:                                /* a click: the highlighted window */
        movups xmm0, xmmword ptr [rip + O + OV_HL]
        movups xmmword ptr [rsp + 32], xmm0
.Llu_enter:
        lea rcx, [rsp + 32]
        call enter_edit
.Llu_ret:
        add rsp, 48
        pop rbx
        ret
.Llu_edit:
        mov eax, dword ptr [rip + O + OV_DRAG]
        cmp eax, DR_DRAW
        je .Llu_draw
        cmp eax, DR_BUTTON
        je .Llu_button
        cmp eax, DR_AMOVE
        je .Llu_grab
        cmp eax, DR_AGRAB
        je .Llu_grab
        mov dword ptr [rip + O + OV_DRAG], DR_NONE
        jmp .Llu_refresh
.Llu_draw:
        call end_draw
        jmp .Llu_refresh
.Llu_grab:
        call end_grab
        jmp .Llu_refresh
.Llu_button:                            /* released on the button pressed: its action */
        mov rcx, rbx
        call tb_hit
        mov ecx, dword ptr [rip + O + OV_BTN_DOWN]
        mov dword ptr [rip + O + OV_DRAG], DR_NONE
        mov dword ptr [rip + O + OV_BTN_DOWN], 0
        cmp eax, ecx
        jne .Llu_refresh
        add rsp, 48
        pop rbx
        jmp on_button
.Llu_refresh:
        add rsp, 48
        pop rbx
        jmp refresh
ENDF

/* void on_dblclick(POINT p): a text annotation opens for editing; elsewhere in the
 * selection (no tool, no annotation) copies like Enter; otherwise a press. */
FUNC on_dblclick
        PUSHREG rbx                     /* p */
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        cmp dword ptr [rip + O + OV_PHASE], PH_EDIT
        jne .Ldc_down
        cmp dword ptr [rip + O + OV_DRAG], DR_NONE
        jne .Ldc_down
        cmp byte ptr [rip + O + OV_TE_ON], 0
        jne .Ldc_down
        mov rcx, rbx
        call tb_hit
        test eax, eax
        jnz .Ldc_down
        mov rcx, rbx
        call anno_at
        test eax, eax
        js .Ldc_none
        movsxd rcx, eax
        imul rcx, rcx, AN_BYTES
        add rcx, qword ptr [rip + O + OV_ANN]
        cmp dword ptr [rcx + AN_TOOL], T_TEXT
        jne .Ldc_down
        mov ecx, eax
        call text_edit
        add rsp, 32
        pop rbx
        jmp refresh
.Ldc_none:
        cmp dword ptr [rip + O + OV_TOOL], T_NONE
        jne .Ldc_down
        SEL_HAS_RBX .Ldc_down
        mov rcx, rbx
        call pick_grab_at
        test eax, eax
        jnz .Ldc_down
        xor ecx, ecx                    /* ACT_COPY */
        add rsp, 32
        pop rbx
        jmp finish
.Ldc_down:
        mov rcx, rbx
        add rsp, 32
        pop rbx
        jmp on_lbutton_down
ENDF

/* void on_rbutton_up(void) */
FUNC on_rbutton_up
        ALLOC 40
        ENDPROLOG
        cmp dword ptr [rip + O + OV_PHASE], PH_SELECT
        jne .Lru_edit
        cmp byte ptr [rip + O + OV_LDOWN], 0
        je .Lru_cancel
        mov word ptr [rip + O + OV_LDOWN], 0    /* O.ldown = O.rubber = false */
        call release_capture
        jmp .Lru_refresh
.Lru_cancel:
        add rsp, 40
        jmp ov_cancel
.Lru_edit:
        mov eax, dword ptr [rip + O + OV_DRAG]
        cmp eax, DR_DRAW
        je .Lru_drag
        cmp eax, DR_AMOVE
        je .Lru_drag
        cmp eax, DR_AGRAB
        je .Lru_drag
        add rsp, 40
        jmp back_to_select
.Lru_drag:                              /* cancel the drag only */
        lea rcx, [rip + O + OV_ACT]
        call anno_free
        mov byte ptr [rip + O + OV_HAS_ACT], 0
        call cancel_grab
        inc dword ptr [rip + O + OV_ACT_VER]
        mov dword ptr [rip + O + OV_DRAG], DR_NONE
        call release_capture
.Lru_refresh:
        add rsp, 40
        jmp refresh
ENDF

/* void on_wheel(int delta) */
FUNC on_wheel
        PUSHREG rbx                     /* d */
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 32
        ENDPROLOG
        xor ebx, ebx                    /* d = delta > 0 ? 1 : -1 */
        test ecx, ecx
        setg bl
        lea ebx, [rbx + rbx - 1]
        cmp dword ptr [rip + O + OV_PHASE], PH_SELECT
        jne .Lwh_edit
        cmp byte ptr [rip + O + OV_LDOWN], 0    /* choosing: another level of the window chain */
        jne .Lwh_ret
        mov edx, dword ptr [rip + O + OV_NCHAIN]
        test edx, edx
        jz .Lwh_ret
        dec edx
        mov ecx, dword ptr [rip + O + OV_LEVEL]
        add ecx, ebx
        CLAMP0 eax, ecx, edx, r8d
        mov dword ptr [rip + O + OV_LEVEL], eax
        shl rax, 4
        lea rcx, [rip + O + OV_CHAIN]
        movups xmm0, xmmword ptr [rcx + rax]
        movups xmmword ptr [rip + O + OV_HL], xmm0
        jmp .Lwh_refresh
.Lwh_edit:
        cmp byte ptr [rip + O + OV_TE_ON], 0
        je .Lwh_pick
        mov ecx, T_TEXT                 /* the text being typed: from the size nearest its own */
        xor edx, edx
        call tool_px
        sub eax, dword ptr [rip + O + OV_TE_PX]
        ABS32 esi, eax                  /* best distance */
        xor edi, edi                    /* its index */
        mov ecx, T_TEXT
        mov edx, 1
        call tool_px
        sub eax, dword ptr [rip + O + OV_TE_PX]
        ABS32 ecx, eax
        cmp ecx, esi
        jge 1f
        mov esi, ecx
        mov edi, 1
1:      mov ecx, T_TEXT
        mov edx, 2
        call tool_px
        sub eax, dword ptr [rip + O + OV_TE_PX]
        ABS32 ecx, eax
        cmp ecx, esi
        jge 1f
        mov edi, 2
1:      add edi, ebx
        mov eax, 2
        CLAMP0 edx, edi, eax, ecx
        mov dword ptr [rip + O + OV_SIZE_IDX], edx
        mov ecx, T_TEXT
        call tool_px
        mov dword ptr [rip + O + OV_TE_PX], eax
        API DestroyCaret
        call text_caret_create
        inc dword ptr [rip + O + OV_ACT_VER]
        jmp .Lwh_refresh
.Lwh_pick:
        cmp dword ptr [rip + O + OV_PICK], 0
        jl .Lwh_tool
        cmp dword ptr [rip + O + OV_DRAG], DR_NONE
        jne .Lwh_tool
        call prop_size_idx              /* the selected annotation */
        add eax, ebx
        mov edx, 2
        CLAMP0 ecx, eax, edx, r8d
        mov dword ptr [rip + O + OV_SIZE_IDX], ecx
        mov edx, -1
        call pick_style
        jmp .Lwh_refresh
.Lwh_tool:
        cmp dword ptr [rip + O + OV_TOOL], T_NONE
        je .Lwh_refresh
        mov eax, dword ptr [rip + O + OV_SIZE_IDX]
        add eax, ebx
        mov edx, 2
        CLAMP0 ecx, eax, edx, r8d
        mov dword ptr [rip + O + OV_SIZE_IDX], ecx
.Lwh_refresh:
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        jmp refresh
.Lwh_ret:
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* ---- keyboard -------------------------------------------------------------------------- */

/* void arrow_key(UINT vk, bool ctrl, bool shift) */
FUNC arrow_key
        PUSHREG rbx                     /* dx */
        PUSHREG rsi                     /* dy */
        ALLOC 40                        /* POINT at 32 */
        ENDPROLOG
        xor ebx, ebx
        xor esi, esi
        mov eax, -1
        mov r9d, 1
        cmp ecx, W_VK_LEFT
        cmove ebx, eax
        cmp ecx, W_VK_RIGHT
        cmove ebx, r9d
        cmp ecx, W_VK_UP
        cmove esi, eax
        cmp ecx, W_VK_DOWN
        cmove esi, r9d
        cmp dword ptr [rip + O + OV_PHASE], PH_SELECT
        jne .Lak_edit
        lea rcx, [rsp + 32]             /* choosing: the arrows move the cursor */
        API GetCursorPos
        mov ecx, dword ptr [rsp + 32 + PT_X]
        add ecx, ebx
        mov edx, dword ptr [rsp + 32 + PT_Y]
        add edx, esi
        API SetCursorPos
        jmp .Lak_ret
.Lak_edit:
        cmp dword ptr [rip + O + OV_PICK], 0
        jl .Lak_sel
        cmp dword ptr [rip + O + OV_DRAG], DR_NONE    /* the selected annotation */
        jne .Lak_ret
        mov ecx, ebx
        mov edx, esi
        call pick_nudge
        jmp .Lak_refresh
.Lak_sel:                               /* the selection: eax, ecx, r9d, r10d = l, t, r, b */
        mov eax, dword ptr [rip + O + OV_SEL + RC_L]
        mov ecx, dword ptr [rip + O + OV_SEL + RC_T]
        mov r9d, dword ptr [rip + O + OV_SEL + RC_R]
        mov r10d, dword ptr [rip + O + OV_SEL + RC_B]
        test dl, dl
        jz .Lak_noctrl
        test ebx, ebx                   /* Ctrl: grow the edge in the arrow's direction */
        jns 1f
        dec eax
1:      test ebx, ebx
        jle 1f
        inc r9d
1:      test esi, esi
        jns 1f
        dec ecx
1:      test esi, esi
        jle .Lak_clip
        inc r10d
        jmp .Lak_clip
.Lak_noctrl:
        test r8b, r8b
        jz .Lak_move
        mov edx, r9d                    /* Shift: shrink, pulling the opposite edge in */
        sub edx, eax
        test ebx, ebx
        jns 1f
        cmp edx, 1
        jle 1f
        dec r9d
1:      test ebx, ebx
        jle 1f
        cmp edx, 1
        jle 1f
        inc eax
1:      mov edx, r10d
        sub edx, ecx
        test esi, esi
        jns 1f
        cmp edx, 1
        jle 1f
        dec r10d
1:      test esi, esi
        jle .Lak_clip
        cmp edx, 1
        jle .Lak_clip
        inc ecx
        jmp .Lak_clip
.Lak_move:                              /* plain: move, kept on screen */
        mov r8d, r9d
        sub r8d, eax                    /* w */
        mov r11d, r10d
        sub r11d, ecx                   /* h */
        lea edx, [rax + rbx]
        mov r9d, dword ptr [rip + O + OV_SHOT + SHOT_VW]
        sub r9d, r8d
        CLAMP0 eax, edx, r9d, r10d
        lea r9d, [rax + r8]
        lea edx, [rcx + rsi]
        mov r10d, dword ptr [rip + O + OV_SHOT + SHOT_VH]
        sub r10d, r11d
        CLAMP0 ecx, edx, r10d, r8d
        lea r10d, [rcx + r11]
.Lak_clip:                              /* rect_isect with the client area; empty or same: nothing */
        xor edx, edx
        test eax, eax
        cmovs eax, edx
        test ecx, ecx
        cmovs ecx, edx
        cmp r9d, dword ptr [rip + O + OV_SHOT + SHOT_VW]
        cmovg r9d, dword ptr [rip + O + OV_SHOT + SHOT_VW]
        cmp r10d, dword ptr [rip + O + OV_SHOT + SHOT_VH]
        cmovg r10d, dword ptr [rip + O + OV_SHOT + SHOT_VH]
        cmp r9d, eax
        jle .Lak_ret
        cmp r10d, ecx
        jle .Lak_ret
        cmp eax, dword ptr [rip + O + OV_SEL + RC_L]
        jne 1f
        cmp ecx, dword ptr [rip + O + OV_SEL + RC_T]
        jne 1f
        cmp r9d, dword ptr [rip + O + OV_SEL + RC_R]
        jne 1f
        cmp r10d, dword ptr [rip + O + OV_SEL + RC_B]
        je .Lak_ret
1:      mov dword ptr [rip + O + OV_SEL + RC_L], eax
        mov dword ptr [rip + O + OV_SEL + RC_T], ecx
        mov dword ptr [rip + O + OV_SEL + RC_R], r9d
        mov dword ptr [rip + O + OV_SEL + RC_B], r10d
        call sel_changed
.Lak_refresh:
        add rsp, 40
        pop rsi
        pop rbx
        jmp refresh
.Lak_ret:
        add rsp, 40
        pop rsi
        pop rbx
        ret
ENDF

/* void on_key(UINT vk, LPARAM lp) */
#define KY_R 32                         /* RECT */
FUNC on_key
        PUSHREG rbx                     /* vk */
        PUSHREG rsi                     /* lp */
        PUSHREG rdi                     /* ctrl */
        PUSHREG r12                     /* shift */
        ALLOC 56
        ENDPROLOG
        mov ebx, ecx
        mov rsi, rdx
        mov ecx, W_VK_CONTROL
        API GetKeyState
        xor edi, edi
        test ax, ax
        sets dil
        mov ecx, W_VK_SHIFT
        API GetKeyState
        xor r12d, r12d
        test ax, ax
        sets r12b
        cmp byte ptr [rip + O + OV_TE_ON], 0
        je .Lky_keys
        cmp ebx, W_VK_ESCAPE            /* typing: Esc ends the text, Ctrl+V pastes */
        jne 1f
        mov ecx, 1
        call text_end
        jmp .Lky_refresh
1:      test edi, edi
        jz .Lky_ret
        cmp ebx, K_V
        jne .Lky_ret
        call text_paste
        jmp .Lky_refresh
.Lky_keys:
        cmp ebx, W_VK_ESCAPE
        je .Lky_cancel
        cmp ebx, W_VK_RETURN
        je .Lky_copy
        cmp ebx, W_VK_DELETE
        je .Lky_delete
        cmp ebx, W_VK_BACK
        je .Lky_delete
        cmp ebx, W_VK_SHIFT
        je .Lky_shift
        lea eax, [rbx - W_VK_LEFT]
        cmp eax, W_VK_DOWN - W_VK_LEFT
        jbe .Lky_arrow
        test edi, edi                   /* the rest are Ctrl shortcuts, except C while choosing */
        jz .Lky_plain
        cmp ebx, K_C
        je .Lky_copy
        cmp ebx, K_S
        je .Lky_save
        cmp ebx, K_T
        je .Lky_pin
        cmp ebx, K_Z
        je .Lky_undo
        cmp ebx, K_Y
        je .Lky_redo
        cmp ebx, K_A
        je .Lky_all
        lea eax, [rbx - K_1]            /* Ctrl+1..9: the tools */
        cmp eax, 8
        ja .Lky_ret
        cmp dword ptr [rip + O + OV_DRAG], DR_NONE
        jne .Lky_ret
        cmp dword ptr [rip + O + OV_PHASE], PH_SELECT
        jne .Lky_tool
        cmp byte ptr [rip + O + OV_LDOWN], 0    /* choosing: take the highlight first */
        jne .Lky_ret
        mov eax, dword ptr [rip + O + OV_HL + RC_R]
        cmp eax, dword ptr [rip + O + OV_HL + RC_L]
        jle .Lky_ret
        mov eax, dword ptr [rip + O + OV_HL + RC_B]
        cmp eax, dword ptr [rip + O + OV_HL + RC_T]
        jle .Lky_ret
        movups xmm0, xmmword ptr [rip + O + OV_HL]
        movups xmmword ptr [rsp + KY_R], xmm0
        lea rcx, [rsp + KY_R]
        call enter_edit
.Lky_tool:
        lea ecx, [rbx - K_0]
        cmp ecx, dword ptr [rip + O + OV_TOOL]
        je .Lky_refresh
        call set_tool
        jmp .Lky_refresh
.Lky_plain:
        cmp ebx, K_C                    /* C while choosing: copy the color under the cursor */
        jne .Lky_ret
        cmp dword ptr [rip + O + OV_PHASE], PH_SELECT
        jne .Lky_ret
        add rsp, 56
        pop r12
        pop rdi
        pop rsi
        pop rbx
        jmp copy_color
.Lky_cancel:
        add rsp, 56
        pop r12
        pop rdi
        pop rsi
        pop rbx
        jmp ov_cancel
.Lky_save:
        mov ecx, ACT_SAVE
        jmp .Lky_finish
.Lky_pin:
        mov ecx, ACT_PIN
        jmp .Lky_finish
.Lky_copy:
        mov ecx, ACT_COPY
.Lky_finish:
        add rsp, 56
        pop r12
        pop rdi
        pop rsi
        pop rbx
        jmp finish
.Lky_arrow:
        mov ecx, ebx
        mov edx, edi
        mov r8d, r12d
        add rsp, 56
        pop r12
        pop rdi
        pop rsi
        pop rbx
        jmp arrow_key
.Lky_delete:
        cmp dword ptr [rip + O + OV_PICK], 0
        jl .Lky_ret
        cmp dword ptr [rip + O + OV_DRAG], DR_NONE
        jne .Lky_ret
        call pick_delete
        jmp .Lky_refresh
.Lky_shift:                             /* first press only, not auto-repeat: RGB / hex */
        cmp dword ptr [rip + O + OV_PHASE], PH_SELECT
        jne .Lky_ret
        bt rsi, 30
        jc .Lky_ret
        xor byte ptr [rip + O + OV_HEX], 1
        jmp .Lky_refresh
.Lky_undo:
        test r12d, r12d                 /* Ctrl+Shift+Z redoes */
        jnz .Lky_redo
        call undo
        jmp .Lky_refresh
.Lky_redo:
        call redo
        jmp .Lky_refresh
.Lky_all:                               /* Ctrl+A: the monitor under the cursor */
        cmp dword ptr [rip + O + OV_DRAG], DR_NONE
        jne .Lky_ret
        lea rcx, [rsp + KY_R]
        mov edx, dword ptr [rip + O + OV_CUR + PT_X]
        mov r8d, dword ptr [rip + O + OV_CUR + PT_Y]
        call mon_rect_at
        cmp dword ptr [rip + O + OV_PHASE], PH_SELECT
        jne 1f
        lea rcx, [rsp + KY_R]
        call enter_edit
        jmp .Lky_ret
1:      movups xmm0, xmmword ptr [rsp + KY_R]
        movups xmmword ptr [rip + O + OV_SEL], xmm0
        call sel_changed
.Lky_refresh:
        add rsp, 56
        pop r12
        pop rdi
        pop rsi
        pop rbx
        jmp refresh
.Lky_ret:
        add rsp, 56
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void on_char(WCHAR c) */
FUNC on_char
        ALLOC 40                        /* WCHAR at 32 */
        ENDPROLOG
        cmp byte ptr [rip + O + OV_TE_ON], 0
        je .Lch_ret
        movzx ecx, cx
        cmp ecx, 0x08
        je .Lch_back
        cmp ecx, 0x0A                   /* Ctrl+Enter */
        je .Lch_end
        cmp ecx, 0x0D
        je .Lch_newline
        cmp ecx, 0x20
        jae .Lch_insert
        cmp ecx, 0x09
        jne .Lch_refresh
.Lch_insert:
        mov word ptr [rsp + 32], cx
        lea rcx, [rsp + 32]
        mov edx, 1
        call text_insert
        jmp .Lch_refresh
.Lch_newline:
        lea rcx, [rip + w_ov_nl]
        mov edx, 1
        call text_insert
        jmp .Lch_refresh
.Lch_back:
        call text_backspace
        jmp .Lch_refresh
.Lch_end:
        mov ecx, 1
        call text_end
.Lch_refresh:
        add rsp, 40
        jmp refresh
.Lch_ret:
        add rsp, 40
        ret
ENDF

/* ---- the window procedure --------------------------------------------------------------- */

/* the handlers of ov_proc, by message: .Lp_map holds the index into .Lp_jt */
#define C_DEF 0
#define C_PAINT 1
#define C_ERASE 2
#define C_SETCURSOR 3
#define C_MOVE 4
#define C_LDOWN 5
#define C_DBLCLK 6
#define C_LUP 7
#define C_RUP 8
#define C_WHEEL 9
#define C_KEY 10
#define C_CHAR 11
#define C_TIMER 12
#define C_CAPTURE 13
#define C_CANCEL 14
#define MSG_LIMIT 0x0216                /* the map's size: up to WM_CAPTURECHANGED; WM_DPICHANGED is above */
        .if MSG_LIMIT != W_WM_CAPTURECHANGED + 1
        .error "message map size"
        .endif

        .section .rdata$ov_proc,"dr"
.Lp_map:
        .org .Lp_map + W_WM_PAINT
        .byte C_PAINT
        .org .Lp_map + W_WM_CLOSE
        .byte C_CANCEL
        .org .Lp_map + W_WM_ERASEBKGND
        .byte C_ERASE
        .org .Lp_map + W_WM_SETCURSOR
        .byte C_SETCURSOR
        .org .Lp_map + W_WM_DISPLAYCHANGE
        .byte C_CANCEL
        .org .Lp_map + W_WM_KEYDOWN
        .byte C_KEY
        .org .Lp_map + W_WM_CHAR
        .byte C_CHAR
        .org .Lp_map + W_WM_SYSKEYDOWN
        .byte C_KEY
        .org .Lp_map + W_WM_TIMER
        .byte C_TIMER
        .org .Lp_map + W_WM_MOUSEMOVE
        .byte C_MOVE
        .org .Lp_map + W_WM_LBUTTONDOWN
        .byte C_LDOWN
        .org .Lp_map + W_WM_LBUTTONUP
        .byte C_LUP
        .org .Lp_map + W_WM_LBUTTONDBLCLK
        .byte C_DBLCLK
        .org .Lp_map + W_WM_RBUTTONUP
        .byte C_RUP
        .org .Lp_map + W_WM_MOUSEWHEEL
        .byte C_WHEEL
        .org .Lp_map + W_WM_CAPTURECHANGED
        .byte C_CAPTURE
        .org .Lp_map + MSG_LIMIT

/* LRESULT CALLBACK ov_proc(HWND h, UINT m, WPARAM wp, LPARAM lp) */
#define PR_R 32                         /* RECT */
FUNC ov_proc
        cmp byte ptr [rip + O + OV_ACTIVE], 0   /* not capturing: everything is default */
        je .Lp_inactive
        ALLOC 56
        ENDPROLOG
        cmp edx, W_WM_MOUSEMOVE         /* first: it comes at input rate */
        jne .Lp_dispatch
.Lp_move:
        LPARAM_POINT
        call on_mouse_move
.Lp_zero:
        xor eax, eax
        add rsp, 56
        ret
.Lp_dispatch:
        cmp edx, MSG_LIMIT
        jae .Lp_high
        mov r11d, edx
        lea rax, [rip + .Lp_map]
        movzx eax, byte ptr [rax + r11]
        lea r10, [rip + .Lp_jt]
        movsxd rax, dword ptr [r10 + rax*4]
        add rax, r10
        jmp rax
.Lp_high:
        cmp edx, W_WM_DPICHANGED        /* we draw in physical pixels; never let the system resize us */
        je .Lp_zero
.Lp_def:
        add rsp, 56
.Lp_inactive:
        jmp qword ptr [rip + __imp_DefWindowProcW]
.Lp_paint:
        call on_paint
        jmp .Lp_zero
.Lp_erase:
        mov eax, 1
        add rsp, 56
        ret
.Lp_setcursor:
        cmp r9w, W_HTCLIENT
        jne .Lp_def
        mov rcx, qword ptr [rip + O + OV_CUR]
        call cursor_for
        mov rcx, rax
        API SetCursor
        mov eax, 1
        add rsp, 56
        ret
.Lp_ldown:
        LPARAM_POINT
        call on_lbutton_down
        jmp .Lp_zero
.Lp_dblclk:
        LPARAM_POINT
        call on_dblclick
        jmp .Lp_zero
.Lp_lup:
        LPARAM_POINT
        call on_lbutton_up
        jmp .Lp_zero
.Lp_rup:
        call on_rbutton_up
        jmp .Lp_zero
.Lp_wheel:
        mov ecx, r8d                    /* GET_WHEEL_DELTA_WPARAM */
        sar ecx, 16
        call on_wheel
        jmp .Lp_zero
.Lp_key:
        mov ecx, r8d
        mov rdx, r9
        call on_key
        jmp .Lp_zero
.Lp_char:
        movzx ecx, r8w
        call on_char
        jmp .Lp_zero
.Lp_timer:
        cmp r8, TIMER_CARET
        je .Lp_caret
        cmp r8, TIMER_TIP
        jne .Lp_zero
        mov edx, TIMER_TIP              /* the tooltip of the button under the cursor */
        API KillTimer
        mov eax, dword ptr [rip + O + OV_HOVER]
        mov dword ptr [rip + O + OV_TIP], eax
        call refresh
        jmp .Lp_zero
.Lp_caret:                              /* composition mode blinks the drawn caret */
        xor byte ptr [rip + O + OV_TE_CARET_OFF], 1
        cmp byte ptr [rip + O + OV_TE_ON], 0
        je .Lp_zero
        lea rcx, [rsp + PR_R]
        call caret_rect
        lea rcx, [rsp + PR_R]
        call inv
        jmp .Lp_zero
.Lp_capture:                            /* capture taken away (not our own release): end the drag */
        cmp r9, rcx
        je .Lp_zero
        cmp byte ptr [rip + O + OV_RELEASING], 0
        jne .Lp_zero
        cmp dword ptr [rip + O + OV_DRAG], DR_DRAW
        jne 1f
        call end_draw
1:      call end_grab
        mov dword ptr [rip + O + OV_DRAG], DR_NONE
        mov word ptr [rip + O + OV_LDOWN], 0    /* O.ldown = O.rubber = false */
        call refresh
        jmp .Lp_zero
.Lp_cancel:                             /* WM_CLOSE, WM_DISPLAYCHANGE */
        call ov_cancel
        jmp .Lp_zero
ENDF
        .balign 4
.Lp_jt:                                 /* by C_* */
        .long .Lp_def - .Lp_jt
        .long .Lp_paint - .Lp_jt
        .long .Lp_erase - .Lp_jt
        .long .Lp_setcursor - .Lp_jt
        .long .Lp_move - .Lp_jt
        .long .Lp_ldown - .Lp_jt
        .long .Lp_dblclk - .Lp_jt
        .long .Lp_lup - .Lp_jt
        .long .Lp_rup - .Lp_jt
        .long .Lp_wheel - .Lp_jt
        .long .Lp_key - .Lp_jt
        .long .Lp_char - .Lp_jt
        .long .Lp_timer - .Lp_jt
        .long .Lp_capture - .Lp_jt
        .long .Lp_cancel - .Lp_jt

/* ---- start-up ---------------------------------------------------------------------------- */

/* HWND ov_window(DWORD ex_style, HINSTANCE inst): a 1x1 overlay window, hidden */
SFUNC ov_window
        ALLOC 104                       /* 12 arguments */
        ENDPROLOG
        xor eax, eax
        mov qword ptr [rsp + 32], rax   /* x, y */
        mov qword ptr [rsp + 40], rax
        mov qword ptr [rsp + 48], 1     /* w, h */
        mov qword ptr [rsp + 56], 1
        mov qword ptr [rsp + 64], rax   /* parent, menu */
        mov qword ptr [rsp + 72], rax
        mov qword ptr [rsp + 80], rdx   /* instance */
        mov qword ptr [rsp + 88], rax   /* param */
        lea rdx, [rip + w_ov_class]
        lea r8, [rip + w_ov_title]
        mov r9d, W_WS_POPUP
        API CreateWindowExW
        add rsp, 104
        ret
ENDF

/* bool ov_init(HINSTANCE inst, HWND daemon) */
#define OI_WC 32                        /* WNDCLASSW */
#define OI_NO (OI_WC + W_WC_SIZE)       /* BOOL */
#define OI_FRAME 120
        .if OI_NO + 4 > OI_FRAME
        .error "ov_init frame"
        .endif
FUNC ov_init
        PUSHREG rbx                     /* inst */
        PUSHREG rsi
        ALLOC OI_FRAME
        ENDPROLOG
        mov rbx, rcx
        mov qword ptr [rip + O + OV_DAEMON], rdx
        xorps xmm0, xmm0                /* WNDCLASSW wc = {0} */
        movups xmmword ptr [rsp + OI_WC], xmm0
        movups xmmword ptr [rsp + OI_WC + 16], xmm0
        movups xmmword ptr [rsp + OI_WC + 32], xmm0
        movups xmmword ptr [rsp + OI_WC + 48], xmm0
        movq qword ptr [rsp + OI_WC + 64], xmm0
        mov dword ptr [rsp + OI_WC + W_WC_STYLE], W_CS_DBLCLKS
        lea rax, [rip + ov_proc]
        mov qword ptr [rsp + OI_WC + W_WC_LPFNWNDPROC], rax
        mov qword ptr [rsp + OI_WC + W_WC_HINSTANCE], rbx
        lea rax, [rip + w_ov_class]
        mov qword ptr [rsp + OI_WC + W_WC_LPSZCLASSNAME], rax
        lea rcx, [rsp + OI_WC]
        API RegisterClassW
        test ax, ax
        jz .Loi_fail
        mov ecx, W_WS_EX_TOPMOST | W_WS_EX_TOOLWINDOW
        mov rdx, rbx
        call ov_window
        mov qword ptr [rip + O + OV_HWND_GDI], rax
        mov qword ptr [rip + O + OV_HWND], rax
        test rax, rax
        jz .Loi_fail
        /* the same overlay for DirectComposition: no redirection surface at all */
        mov ecx, W_WS_EX_NOREDIRECTIONBITMAP | W_WS_EX_TOPMOST | W_WS_EX_TOOLWINDOW
        mov rdx, rbx
        call ov_window
        mov qword ptr [rip + O + OV_HWND_DC], rax
        mov dword ptr [rsp + OI_NO], 1  /* BOOL no = TRUE: no show / hide animations */
        mov rcx, qword ptr [rip + O + OV_HWND_GDI]
        mov edx, W_DWMWA_TRANSITIONS_FORCEDISABLED
        lea r8, [rsp + OI_NO]
        mov r9d, 4
        API DwmSetWindowAttribute
        mov rcx, qword ptr [rip + O + OV_HWND_DC]
        test rcx, rcx
        jz 1f
        mov edx, W_DWMWA_TRANSITIONS_FORCEDISABLED
        lea r8, [rsp + OI_NO]
        mov r9d, 4
        API DwmSetWindowAttribute
1:      lea rcx, [rip + ov_gpu_changed]
        call shot_on_ready
        /* keep the IME away unless the text tool is typing, so plain keys (C, Shift) work */
        mov rcx, qword ptr [rip + O + OV_HWND_GDI]
        xor edx, edx
        API ImmAssociateContext
        mov qword ptr [rip + O + OV_HIMC], rax
        mov rcx, qword ptr [rip + O + OV_HWND_DC]
        test rcx, rcx
        jz 1f
        xor edx, edx
        API ImmAssociateContext
1:      xor ecx, ecx
        API CreateCompatibleDC
        mov qword ptr [rip + O + OV_MDC], rax
        xor esi, esi                    /* O.c_cross .. O.c_nesw */
2:      lea rax, [rip + .Lcursor_ids]
        movzx edx, word ptr [rax + rsi*2]
        xor ecx, ecx
        API LoadCursorW
        lea rcx, [rip + O + OV_C_CROSS]
        mov qword ptr [rcx + rsi*8], rax
        inc esi
        cmp esi, 8
        jb 2b
        /* warm the UI font so the first capture does not pay for font realization */
        xor ecx, ecx                    /* (POINT){0, 0} */
        call dpi_scale_at
        movss dword ptr [rip + O + OV_S], xmm0
        call ensure_ui_font
        mov rcx, qword ptr [rip + O + OV_FONT_UI]
        lea rdx, [rip + w_ov_warm]
        mov r8d, 9
        call text_size
        mov eax, 1
        jmp .Loi_ret
.Loi_fail:
        xor eax, eax
.Loi_ret:
        add rsp, OI_FRAME
        pop rsi
        pop rbx
        ret
ENDF
