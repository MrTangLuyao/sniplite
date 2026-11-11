/* pin.S: pinned image windows (see pin.h), replacing pin.c. Drag to move, wheel
 * to zoom, Ctrl+wheel for opacity, double-click or Esc to close, right-click for
 * a menu. Windows constants and structure offsets are the #define lines of this
 * file, checked by tests/pin_check.c; tests/pin_test.c drives the C and the
 * assembly windows with the same messages and compares them. */
#include "asm.inc"

/* ---- Windows constants --------------------------------------------------------- */
#define K_GWLP_USERDATA -21
#define K_GWL_EXSTYLE -20
#define K_WS_EX_LAYERED 0x80000
#define K_LWA_ALPHA 2
#define K_RDW_INVALIDATE_FRAME 0x401    /* RDW_INVALIDATE | RDW_FRAME */
#define K_SWP_NOZORDER_NOACTIVATE 0x14
#define K_SWP_MOVE_ONLY 0x15            /* SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE */
#define K_SWP_FRAMECHANGED_SHOW 0x60    /* SWP_FRAMECHANGED | SWP_SHOWWINDOW */
#define K_HWND_TOPMOST -1
#define K_MF_STRING 0
#define K_MF_GRAYED 1
#define K_MF_SEPARATOR 0x800
#define K_TPM_FLAGS 0x182               /* TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY */
#define K_WM_NULL 0
#define K_SRCCOPY 0xCC0020
#define K_HALFTONE 4
#define K_COLORONCOLOR 3
#define K_FW_NORMAL 400
#define K_DEFAULT_CHARSET 1
#define K_CLEARTYPE_QUALITY 5
#define K_TRANSPARENT 1
#define K_LABEL_BG 0x202020             /* RGB(32, 32, 32) */
#define K_LABEL_FG 0xFFFFFF
#define K_LABEL_FMT 0x825               /* DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX */
#define K_WM_PAINT 0x000F
#define K_WM_ERASEBKGND 0x0014
#define K_WM_GETMINMAXINFO 0x0024
#define K_WM_CONTEXTMENU 0x007B
#define K_WM_NCCREATE 0x0081
#define K_WM_NCDESTROY 0x0082
#define K_WM_NCCALCSIZE 0x0083
#define K_WM_NCHITTEST 0x0084
#define K_WM_NCACTIVATE 0x0086
#define K_WM_KEYDOWN 0x0100
#define K_WM_SYSCOMMAND 0x0112
#define K_WM_TIMER 0x0113
#define K_WM_MOUSEMOVE 0x0200
#define K_WM_LBUTTONDOWN 0x0201
#define K_WM_LBUTTONUP 0x0202
#define K_WM_LBUTTONDBLCLK 0x0203
#define K_WM_MOUSEWHEEL 0x020A
#define K_WM_CAPTURECHANGED 0x0215
#define K_WM_DPICHANGED 0x02E0
#define K_HTCLIENT 1
#define K_SC_SIZE 0xF000
#define K_SC_MINIMIZE 0xF020
#define K_SC_MAXIMIZE 0xF030
#define K_SC_RESTORE 0xF120
#define K_MK_CONTROL 8
#define K_VK_CONTROL 0x11
#define K_VK_ESCAPE 0x1B
#define K_CS_DBLCLKS 8
#define K_IDC_SIZEALL 32646
#define K_WS_EX_PIN 0x88                /* WS_EX_TOPMOST | WS_EX_TOOLWINDOW */
#define K_WS_PIN 0x80C00000             /* WS_POPUP | WS_CAPTION */
#define K_MONITOR_DEFAULTTONEAREST 2
#define K_DWMWA_WINDOW_CORNER_PREFERENCE 33
#define K_DWMWCP_DONOTROUND 1
#define K_SW_HIDE 0
#define K_SW_SHOWNOACTIVATE 4
#define K_MAX_PATH 260

/* ---- Windows structures --------------------------------------------------------- */
#define CS_PARAMS 0                     /* CREATESTRUCTW.lpCreateParams */
#define MMI_MINTRACK 24                 /* MINMAXINFO.ptMinTrackSize */
#define MMI_MAXTRACK 32                 /* MINMAXINFO.ptMaxTrackSize */
#define MI_RCWORK 20                    /* MONITORINFO */
#define MI_BYTES 40
#define PS_BYTES 72                     /* PAINTSTRUCT */
#define WC_STYLE 0                      /* WNDCLASSW */
#define WC_WNDPROC 8
#define WC_INSTANCE 24
#define WC_CURSOR 40
#define WC_CLASSNAME 64
#define WC_BYTES 72
#define MG_BOTTOM 12                    /* MARGINS.cyBottomHeight */
#define MG_BYTES 16

/* ---- Pin: one pinned image (private to this file) ---------------------------------- */
#define PIN_HWND 0
#define PIN_IMG 8                       /* Img */
#define PIN_ZOOM 48                     /* float */
#define PIN_ALPHA 52                    /* int, percent 10..100 */
#define PIN_DRAG 56                     /* bool */
#define PIN_SHOW_LABEL 57               /* bool */
#define PIN_DRAG_PT 60                  /* POINT: cursor when the drag started */
#define PIN_WIN_PT 68                   /* POINT: window position then */
#define PIN_NEXT 80
#define PIN_LABEL 88                    /* WCHAR[32] */
#define PIN_LABEL_LEN 32
#define PIN_SIZE 152

#define TIMER_LABEL 1
#define CM_COPY 1
#define CM_SAVE 2
#define CM_RESET 3
#define CM_CLOSE 4
#define CM_CLOSE_ALL 5

        .section .rdata,"dr"
        .balign 16
k_abs:          .long 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF
k_one:          .long 0x3F800000        /* 1.f */
k_zoom_in:      .long 0x3F8CCCCD        /* 1.1f */
k_zoom_out:     .long 0x3F68BA2E        /* 1.f / 1.1f */
k_snap:         .long 0x3CA3D70A        /* 0.02f */
k_min_zoom:     .long 0x3D4CCCCD        /* 0.05f */
k_16:           .long 0x41800000        /* 16.f */
k_16000:        .long 0x467A0000        /* 16000.f */
k_100:          .long 0x42C80000        /* 100.f */
k_fit:          .long 0x3F666666        /* 0.9f */
k_96:           .long 0x42C00000        /* 96.f */
k_12:           .long 0x41400000        /* 12.f */
k_6:            .long 0x40C00000        /* 6.f */

        .balign 2
        /* L"sniplite.pin" */
w_class:
        .short 0x0073, 0x006E, 0x0069, 0x0070, 0x006C, 0x0069, 0x0074, 0x0065, 0x002E, 0x0070, 0x0069, 0x006E
        .short 0x0000
        /* L"sniplite" */
w_name:
        .short 0x0073, 0x006E, 0x0069, 0x0070, 0x006C, 0x0069, 0x0074, 0x0065, 0x0000
        /* L"%d%%" */
w_pctfmt:
        .short 0x0025, 0x0064, 0x0025, 0x0025, 0x0000
        /* L"不透明度 %d%%" */
w_alphafmt:
        .short 0x4E0D, 0x900F, 0x660E, 0x5EA6, 0x0020, 0x0025, 0x0064, 0x0025, 0x0025, 0x0000
        /* L"已复制" */
w_copied:
        .short 0x5DF2, 0x590D, 0x5236, 0x0000
        /* L"已保存" */
w_saved:
        .short 0x5DF2, 0x4FDD, 0x5B58, 0x0000
        /* L"保存失败" */
w_savefail:
        .short 0x4FDD, 0x5B58, 0x5931, 0x8D25, 0x0000
        /* L"复制\tCtrl+C" */
w_m_copy:
        .short 0x590D, 0x5236, 0x0009, 0x0043, 0x0074, 0x0072, 0x006C, 0x002B, 0x0043, 0x0000
        /* L"另存为...\tCtrl+S" */
w_m_save:
        .short 0x53E6, 0x5B58, 0x4E3A, 0x002E, 0x002E, 0x002E, 0x0009, 0x0043, 0x0074, 0x0072, 0x006C, 0x002B
        .short 0x0053, 0x0000
        /* L"恢复原始大小" */
w_m_reset:
        .short 0x6062, 0x590D, 0x539F, 0x59CB, 0x5927, 0x5C0F, 0x0000
        /* L"关闭\tEsc" */
w_m_close:
        .short 0x5173, 0x95ED, 0x0009, 0x0045, 0x0073, 0x0063, 0x0000
        /* L"关闭所有贴图" */
w_m_closeall:
        .short 0x5173, 0x95ED, 0x6240, 0x6709, 0x8D34, 0x56FE, 0x0000
        /* L"Microsoft YaHei UI" */
w_yahei:
        .short 0x004D, 0x0069, 0x0063, 0x0072, 0x006F, 0x0073, 0x006F, 0x0066, 0x0074, 0x0020, 0x0059, 0x0061
        .short 0x0048, 0x0065, 0x0069, 0x0020, 0x0055, 0x0049, 0x0000

        .bss
        .balign 8
p_inst:         .space 8
p_daemon:       .space 8
p_list:         .space 8                /* Pin *, newest first */
p_count:        .space 4

/* ---- helpers ------------------------------------------------------------------------ */

/* void flash_label(Pin *p, const WCHAR *text): show text in the corner for 900 ms */
SFUNC flash_label
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        lea rcx, [rbx + PIN_LABEL]
        mov r8d, PIN_LABEL_LEN
        API lstrcpynW
        mov byte ptr [rbx + PIN_SHOW_LABEL], 1
        mov rcx, qword ptr [rbx + PIN_HWND]
        mov edx, TIMER_LABEL
        mov r8d, 900
        xor r9d, r9d
        API SetTimer
        mov rcx, qword ptr [rbx + PIN_HWND]
        xor edx, edx
        xor r8d, r8d
        API InvalidateRect
        add rsp, 32
        pop rbx
        ret
        ENDF

/* void set_zoom(Pin *p, float z, POINT anchor): resize around a screen point */
#define SZ_WR 56
#define SZ_T 72                         /* WCHAR[16] */
#define SZ_Z 104
#define SZ_FX 108
#define SZ_FY 112
SFUNC set_zoom
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        ALLOC 128
        ENDPROLOG
        mov rbx, rcx
        mov esi, r8d                    /* anchor.x */
        mov rdi, r8
        shr rdi, 32                     /* anchor.y */
        /* z = fmaxf(0.05, fminf(z, fminf(16, 16000 / max(w, h)))) */
        mov eax, dword ptr [rbx + PIN_IMG + IMG_W]
        mov ecx, dword ptr [rbx + PIN_IMG + IMG_H]
        cmp eax, ecx
        cmovl eax, ecx
        cvtsi2ss xmm0, eax
        movss xmm2, dword ptr [rip + k_16000]
        divss xmm2, xmm0
        movss xmm0, dword ptr [rip + k_16]
        minss xmm0, xmm2
        minss xmm1, xmm0
        maxss xmm1, dword ptr [rip + k_min_zoom]
        movss dword ptr [rsp + SZ_Z], xmm1
        mov rcx, qword ptr [rbx + PIN_HWND]
        lea rdx, [rsp + SZ_WR]
        API GetWindowRect
        /* the anchor keeps its relative position in the window */
        mov eax, esi
        sub eax, dword ptr [rsp + SZ_WR + RC_L]
        cvtsi2ss xmm0, eax
        mov eax, dword ptr [rsp + SZ_WR + RC_R]
        sub eax, dword ptr [rsp + SZ_WR + RC_L]
        mov ecx, 1
        cmp eax, ecx
        cmovl eax, ecx
        cvtsi2ss xmm1, eax
        divss xmm0, xmm1
        movss dword ptr [rsp + SZ_FX], xmm0
        mov eax, edi
        sub eax, dword ptr [rsp + SZ_WR + RC_T]
        cvtsi2ss xmm0, eax
        mov eax, dword ptr [rsp + SZ_WR + RC_B]
        sub eax, dword ptr [rsp + SZ_WR + RC_T]
        mov ecx, 1
        cmp eax, ecx
        cmovl eax, ecx
        cvtsi2ss xmm1, eax
        divss xmm0, xmm1
        movss dword ptr [rsp + SZ_FY], xmm0
        mov ecx, 8
        cvtsi2ss xmm0, dword ptr [rbx + PIN_IMG + IMG_W]
        mulss xmm0, dword ptr [rsp + SZ_Z]
        LROUNDF r12d, xmm0, xmm1
        cmp r12d, ecx
        cmovl r12d, ecx                 /* nw */
        cvtsi2ss xmm0, dword ptr [rbx + PIN_IMG + IMG_H]
        mulss xmm0, dword ptr [rsp + SZ_Z]
        LROUNDF r13d, xmm0, xmm1
        cmp r13d, ecx
        cmovl r13d, ecx                 /* nh */
        cvtsi2ss xmm0, r12d
        mulss xmm0, dword ptr [rsp + SZ_FX]
        LROUNDF eax, xmm0, xmm1
        sub esi, eax                    /* nx */
        cvtsi2ss xmm0, r13d
        mulss xmm0, dword ptr [rsp + SZ_FY]
        LROUNDF eax, xmm0, xmm1
        sub edi, eax                    /* ny */
        movss xmm0, dword ptr [rsp + SZ_Z]
        movss dword ptr [rbx + PIN_ZOOM], xmm0
        mov rcx, qword ptr [rbx + PIN_HWND]
        xor edx, edx
        mov r8d, esi
        mov r9d, edi
        mov dword ptr [rsp + 32], r12d
        mov dword ptr [rsp + 40], r13d
        mov dword ptr [rsp + 48], K_SWP_NOZORDER_NOACTIVATE
        API SetWindowPos
        movss xmm0, dword ptr [rsp + SZ_Z]
        mulss xmm0, dword ptr [rip + k_100]
        LROUNDF r8d, xmm0, xmm1
        lea rcx, [rsp + SZ_T]
        lea rdx, [rip + w_pctfmt]
        API wsprintfW
        mov rcx, rbx
        lea rdx, [rsp + SZ_T]
        call flash_label
        add rsp, 128
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
        ENDF

/* void set_alpha(Pin *p, int pct) */
#define SA_T 32                         /* WCHAR[24] */
SFUNC set_alpha
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 88
        ENDPROLOG
        mov rbx, rcx
        mov eax, edx
        mov ecx, 10
        cmp eax, ecx
        cmovl eax, ecx
        mov ecx, 100
        cmp eax, ecx
        cmovg eax, ecx
        mov dword ptr [rbx + PIN_ALPHA], eax
        mov rcx, qword ptr [rbx + PIN_HWND]
        mov edx, K_GWL_EXSTYLE
        API GetWindowLongW
        mov esi, eax                    /* ex */
        cmp dword ptr [rbx + PIN_ALPHA], 100
        jge .Lsa_opaque
        test esi, K_WS_EX_LAYERED
        jnz 1f
        mov rcx, qword ptr [rbx + PIN_HWND]
        mov edx, K_GWL_EXSTYLE
        mov r8d, esi
        or r8d, K_WS_EX_LAYERED
        API SetWindowLongW
1:      imul eax, dword ptr [rbx + PIN_ALPHA], 255
        xor edx, edx
        mov ecx, 100
        div ecx
        mov rcx, qword ptr [rbx + PIN_HWND]
        xor edx, edx
        movzx r8d, al
        mov r9d, K_LWA_ALPHA
        API SetLayeredWindowAttributes
        jmp .Lsa_label
.Lsa_opaque:                            /* fully opaque again: drop the layered style, it costs composition work */
        test esi, K_WS_EX_LAYERED
        jz .Lsa_label
        mov rcx, qword ptr [rbx + PIN_HWND]
        mov edx, K_GWL_EXSTYLE
        mov r8d, esi
        and r8d, ~K_WS_EX_LAYERED
        API SetWindowLongW
        mov rcx, qword ptr [rbx + PIN_HWND]
        xor edx, edx
        xor r8d, r8d
        mov r9d, K_RDW_INVALIDATE_FRAME
        API RedrawWindow
.Lsa_label:
        lea rcx, [rsp + SA_T]
        lea rdx, [rip + w_alphafmt]
        mov r8d, dword ptr [rbx + PIN_ALPHA]
        API wsprintfW
        mov rcx, rbx
        lea rdx, [rsp + SA_T]
        call flash_label
        add rsp, 88
        pop rsi
        pop rbx
        ret
        ENDF

/* void pin_copy(Pin *p) */
SFUNC pin_copy
        PUSHREG rbx
        ALLOC 48
        ENDPROLOG
        mov rbx, rcx
        mov rcx, qword ptr [rip + p_daemon]
        mov rdx, qword ptr [rbx + PIN_IMG + IMG_PX]
        mov r8d, dword ptr [rbx + PIN_IMG + IMG_W]
        mov r9d, r8d
        mov eax, dword ptr [rbx + PIN_IMG + IMG_H]
        mov dword ptr [rsp + 32], eax
        call clip_put_image
        mov rcx, rbx
        lea rdx, [rip + w_copied]
        call flash_label
        add rsp, 48
        pop rbx
        ret
        ENDF

/* void pin_save(Pin *p): the dialog runs a nested message loop in which this pin
 * may be closed, so save from a private copy and re-validate the window afterwards. */
#define PS_COPY 48                      /* Img */
#define PS_PATH 88                      /* WCHAR[MAX_PATH * 2] */
SFUNC pin_save
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 1136
        ENDPROLOG
        mov rbx, rcx
        lea rcx, [rsp + PS_COPY]
        mov edx, dword ptr [rbx + PIN_IMG + IMG_W]
        mov r8d, dword ptr [rbx + PIN_IMG + IMG_H]
        call img_create
        test al, al
        jz .Lps_ret
        mov rdi, qword ptr [rsp + PS_COPY + IMG_PX]
        mov rsi, qword ptr [rbx + PIN_IMG + IMG_PX]
        movsxd rcx, dword ptr [rbx + PIN_IMG + IMG_W]
        movsxd rax, dword ptr [rbx + PIN_IMG + IMG_H]
        imul rcx, rax
        shl rcx, 2
        rep movsb
        mov rsi, qword ptr [rbx + PIN_HWND]
        lea rcx, [rsp + PS_PATH]
        mov edx, 2 * K_MAX_PATH
        call save_dialog
        test al, al
        jz .Lps_destroy
        lea rcx, [rsp + PS_PATH]
        mov rdx, qword ptr [rsp + PS_COPY + IMG_PX]
        mov r8d, dword ptr [rsp + PS_COPY + IMG_W]
        mov r9d, r8d
        mov eax, dword ptr [rsp + PS_COPY + IMG_H]
        mov dword ptr [rsp + 32], eax
        call image_save
        movzx edi, al
        mov rcx, rsi
        API IsWindow
        test eax, eax
        jz .Lps_destroy
        mov rcx, rsi
        mov edx, K_GWLP_USERDATA
        API GetWindowLongPtrW
        cmp rax, rbx
        jne .Lps_destroy
        lea rdx, [rip + w_saved]
        lea rax, [rip + w_savefail]
        test edi, edi
        cmovz rdx, rax
        mov rcx, rbx
        call flash_label
.Lps_destroy:
        lea rcx, [rsp + PS_COPY]
        call img_destroy
.Lps_ret:
        add rsp, 1136
        pop rdi
        pop rsi
        pop rbx
        ret
        ENDF

/* void pin_menu(Pin *p, POINT at) */
#define PM_WR 56
SFUNC pin_menu
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 72
        ENDPROLOG
        mov rbx, rcx
        mov r12, rdx                    /* at */
        API CreatePopupMenu
        mov rsi, rax
        mov rcx, rsi
        mov edx, K_MF_STRING
        mov r8d, CM_COPY
        lea r9, [rip + w_m_copy]
        API AppendMenuW
        mov rcx, rsi
        mov edx, K_MF_STRING
        mov r8d, CM_SAVE
        lea r9, [rip + w_m_save]
        API AppendMenuW
        mov edx, K_MF_STRING            /* grayed at 100% and fully opaque */
        movss xmm0, dword ptr [rbx + PIN_ZOOM]
        ucomiss xmm0, dword ptr [rip + k_one]
        jp 1f
        jne 1f
        cmp dword ptr [rbx + PIN_ALPHA], 100
        jne 1f
        mov edx, K_MF_STRING | K_MF_GRAYED
1:      mov rcx, rsi
        mov r8d, CM_RESET
        lea r9, [rip + w_m_reset]
        API AppendMenuW
        mov rcx, rsi
        mov edx, K_MF_SEPARATOR
        xor r8d, r8d
        xor r9d, r9d
        API AppendMenuW
        mov rcx, rsi
        mov edx, K_MF_STRING
        mov r8d, CM_CLOSE
        lea r9, [rip + w_m_close]
        API AppendMenuW
        mov rcx, rsi
        mov edx, K_MF_STRING
        mov r8d, CM_CLOSE_ALL
        lea r9, [rip + w_m_closeall]
        API AppendMenuW
        mov rdi, qword ptr [rbx + PIN_HWND]
        mov rcx, rdi
        API SetForegroundWindow
        mov rcx, rsi
        mov edx, K_TPM_FLAGS
        mov r8d, r12d
        mov r9, r12
        shr r9, 32
        mov qword ptr [rsp + 32], 0
        mov qword ptr [rsp + 40], rdi
        mov qword ptr [rsp + 48], 0
        API TrackPopupMenu
        mov r12d, eax                   /* cmd */
        mov rcx, rsi
        API DestroyMenu
        mov rcx, rdi
        mov edx, K_WM_NULL
        xor r8d, r8d
        xor r9d, r9d
        API PostMessageW
        mov rcx, rdi
        API IsWindow
        test eax, eax
        jz .Lpm_ret
        cmp r12d, CM_COPY
        je .Lpm_copy
        cmp r12d, CM_SAVE
        je .Lpm_save
        cmp r12d, CM_RESET
        je .Lpm_reset
        cmp r12d, CM_CLOSE
        je .Lpm_close
        cmp r12d, CM_CLOSE_ALL
        jne .Lpm_ret
        call pin_close_all
        jmp .Lpm_ret
.Lpm_copy:
        mov rcx, rbx
        call pin_copy
        jmp .Lpm_ret
.Lpm_save:
        mov rcx, rbx
        call pin_save
        jmp .Lpm_ret
.Lpm_reset:
        mov rcx, rdi
        lea rdx, [rsp + PM_WR]
        API GetWindowRect
        mov rcx, rbx
        mov edx, 100
        call set_alpha
        mov rcx, rbx
        movss xmm1, dword ptr [rip + k_one]
        mov r8, qword ptr [rsp + PM_WR]         /* {left, top} */
        call set_zoom
        jmp .Lpm_ret
.Lpm_close:
        mov rcx, rdi
        API DestroyWindow
.Lpm_ret:
        add rsp, 72
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
        ENDF

/* void paint(Pin *p) */
#define PA_PS 112                       /* PAINTSTRUCT */
#define PA_RC 184
#define PA_SZ 200                       /* SIZE */
#define PA_LR 208
#define PA_S 224
#define PA_FONT 232
#define PA_OLDFONT 240
#define PA_BRUSH 248
SFUNC paint
        PUSHREG rbx
        PUSHREG rbp
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 264
        ENDPROLOG
        mov rbx, rcx
        mov rcx, qword ptr [rbx + PIN_HWND]
        lea rdx, [rsp + PA_PS]
        API BeginPaint
        mov rsi, rax                    /* dc */
        mov rcx, qword ptr [rbx + PIN_HWND]
        lea rdx, [rsp + PA_RC]
        API GetClientRect
        mov r15d, dword ptr [rsp + PA_RC + RC_R]        /* w */
        mov ebp, dword ptr [rsp + PA_RC + RC_B]         /* h */
        mov rdi, rsi                    /* target */
        xor r12d, r12d                  /* memory dc */
        xor r13d, r13d                  /* its bitmap */
        xor r14d, r14d                  /* its old bitmap */
        cmp byte ptr [rbx + PIN_SHOW_LABEL], 0
        je .Lpa_draw
        mov rcx, rsi                    /* compose off-screen so the label never flickers */
        API CreateCompatibleDC
        mov r12, rax
        mov rcx, rsi
        mov edx, r15d
        mov r8d, ebp
        API CreateCompatibleBitmap
        mov r13, rax
        test r12, r12
        jz .Lpa_draw
        test r13, r13
        jz .Lpa_draw
        mov rcx, r12
        mov rdx, r13
        API SelectObject
        mov r14, rax
        mov rdi, r12
.Lpa_draw:
        cmp r15d, dword ptr [rbx + PIN_IMG + IMG_W]
        jne .Lpa_stretch
        cmp ebp, dword ptr [rbx + PIN_IMG + IMG_H]
        jne .Lpa_stretch
        mov rcx, rdi
        xor edx, edx
        xor r8d, r8d
        mov r9d, r15d
        mov dword ptr [rsp + 32], ebp
        mov rax, qword ptr [rbx + PIN_IMG + IMG_DC]
        mov qword ptr [rsp + 40], rax
        mov qword ptr [rsp + 48], 0
        mov qword ptr [rsp + 56], 0
        mov qword ptr [rsp + 64], K_SRCCOPY
        API BitBlt
        jmp .Lpa_label
.Lpa_stretch:
        mov edx, K_COLORONCOLOR
        mov eax, K_HALFTONE
        cmp r15d, dword ptr [rbx + PIN_IMG + IMG_W]
        cmovl edx, eax
        mov rcx, rdi
        API SetStretchBltMode
        mov rcx, rdi
        xor edx, edx
        xor r8d, r8d
        xor r9d, r9d
        API SetBrushOrgEx
        mov rcx, rdi
        xor edx, edx
        xor r8d, r8d
        mov r9d, r15d
        mov dword ptr [rsp + 32], ebp
        mov rax, qword ptr [rbx + PIN_IMG + IMG_DC]
        mov qword ptr [rsp + 40], rax
        mov qword ptr [rsp + 48], 0
        mov qword ptr [rsp + 56], 0
        mov eax, dword ptr [rbx + PIN_IMG + IMG_W]
        mov dword ptr [rsp + 64], eax
        mov eax, dword ptr [rbx + PIN_IMG + IMG_H]
        mov dword ptr [rsp + 72], eax
        mov qword ptr [rsp + 80], K_SRCCOPY
        API StretchBlt
.Lpa_label:
        cmp rdi, r12
        jne .Lpa_cleanup
        mov rcx, qword ptr [rbx + PIN_HWND]
        API GetDpiForWindow
        mov eax, eax
        cvtsi2ss xmm0, rax
        divss xmm0, dword ptr [rip + k_96]
        movss dword ptr [rsp + PA_S], xmm0
        mulss xmm0, dword ptr [rip + k_12]
        LROUNDF ecx, xmm0, xmm1
        neg ecx
        xor edx, edx
        xor r8d, r8d
        xor r9d, r9d
        mov qword ptr [rsp + 32], K_FW_NORMAL
        mov qword ptr [rsp + 40], 0
        mov qword ptr [rsp + 48], 0
        mov qword ptr [rsp + 56], 0
        mov qword ptr [rsp + 64], K_DEFAULT_CHARSET
        mov qword ptr [rsp + 72], 0
        mov qword ptr [rsp + 80], 0
        mov qword ptr [rsp + 88], K_CLEARTYPE_QUALITY
        mov qword ptr [rsp + 96], 0
        lea rax, [rip + w_yahei]
        mov qword ptr [rsp + 104], rax
        API CreateFontW
        mov qword ptr [rsp + PA_FONT], rax
        mov rcx, r12
        mov rdx, rax
        API SelectObject
        mov qword ptr [rsp + PA_OLDFONT], rax
        lea rcx, [rbx + PIN_LABEL]
        API lstrlenW
        mov qword ptr [rsp + PA_SZ], 0
        mov rcx, r12
        lea rdx, [rbx + PIN_LABEL]
        mov r8d, eax
        lea r9, [rsp + PA_SZ]
        API GetTextExtentPoint32W
        movss xmm0, dword ptr [rip + k_6]
        mulss xmm0, dword ptr [rsp + PA_S]
        LROUNDF eax, xmm0, xmm1         /* pad */
        mov qword ptr [rsp + PA_LR], 0
        mov ecx, dword ptr [rsp + PA_SZ]
        lea ecx, [rcx + rax * 2]
        mov dword ptr [rsp + PA_LR + RC_R], ecx
        mov ecx, dword ptr [rsp + PA_SZ + 4]
        add ecx, eax
        mov dword ptr [rsp + PA_LR + RC_B], ecx
        mov ecx, K_LABEL_BG
        API CreateSolidBrush
        mov qword ptr [rsp + PA_BRUSH], rax
        mov rcx, r12
        lea rdx, [rsp + PA_LR]
        mov r8, rax
        API FillRect
        mov rcx, qword ptr [rsp + PA_BRUSH]
        API DeleteObject
        mov rcx, r12
        mov edx, K_TRANSPARENT
        API SetBkMode
        mov rcx, r12
        mov edx, K_LABEL_FG
        API SetTextColor
        mov rcx, r12
        lea rdx, [rbx + PIN_LABEL]
        mov r8d, -1
        lea r9, [rsp + PA_LR]
        mov qword ptr [rsp + 32], K_LABEL_FMT
        API DrawTextW
        mov rcx, r12
        mov rdx, qword ptr [rsp + PA_OLDFONT]
        API SelectObject
        mov rcx, qword ptr [rsp + PA_FONT]
        API DeleteObject
        mov rcx, rsi
        xor edx, edx
        xor r8d, r8d
        mov r9d, r15d
        mov dword ptr [rsp + 32], ebp
        mov qword ptr [rsp + 40], r12
        mov qword ptr [rsp + 48], 0
        mov qword ptr [rsp + 56], 0
        mov qword ptr [rsp + 64], K_SRCCOPY
        API BitBlt
.Lpa_cleanup:
        test r12, r12
        jz 2f
        test r14, r14
        jz 1f
        mov rcx, r12
        mov rdx, r14
        API SelectObject
1:      mov rcx, r12
        API DeleteDC
2:      test r13, r13
        jz 1f
        mov rcx, r13
        API DeleteObject
1:      mov rcx, qword ptr [rbx + PIN_HWND]
        lea rdx, [rsp + PA_PS]
        API EndPaint
        add rsp, 264
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

/* ---- window procedure --------------------------------------------------------------- */

#define PP_WR 56
#define PP_C 72
SFUNC pin_proc
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        ALLOC 80
        ENDPROLOG
        mov rbx, rcx                    /* hwnd */
        mov esi, edx                    /* message */
        mov rdi, r8                     /* wParam */
        mov r12, r9                     /* lParam */
        cmp esi, K_WM_NCCREATE
        jne 1f
        mov r8, qword ptr [r12 + CS_PARAMS]
        mov qword ptr [r8 + PIN_HWND], rbx
        mov rcx, rbx
        mov edx, K_GWLP_USERDATA
        API SetWindowLongPtrW
1:      mov rcx, rbx
        mov edx, K_GWLP_USERDATA
        API GetWindowLongPtrW
        test rax, rax
        jz .Lpp_default
        mov r13, rax                    /* Pin */
        cmp esi, K_WM_MOUSEMOVE
        je .Lpp_mousemove
        cmp esi, K_WM_NCHITTEST
        je .Lpp_nchittest
        cmp esi, K_WM_PAINT
        je .Lpp_paint
        cmp esi, K_WM_NCCALCSIZE
        je .Lpp_nccalcsize
        cmp esi, K_WM_NCACTIVATE
        je .Lpp_ncactivate
        cmp esi, K_WM_GETMINMAXINFO
        je .Lpp_getminmaxinfo
        cmp esi, K_WM_SYSCOMMAND
        je .Lpp_syscommand
        cmp esi, K_WM_DPICHANGED
        je .Lpp_zero
        cmp esi, K_WM_ERASEBKGND
        je .Lpp_one
        cmp esi, K_WM_LBUTTONDOWN
        je .Lpp_lbuttondown
        cmp esi, K_WM_LBUTTONUP
        je .Lpp_lbuttonup
        cmp esi, K_WM_CAPTURECHANGED
        je .Lpp_capturechanged
        cmp esi, K_WM_LBUTTONDBLCLK
        je .Lpp_destroy
        cmp esi, K_WM_MOUSEWHEEL
        je .Lpp_mousewheel
        cmp esi, K_WM_KEYDOWN
        je .Lpp_keydown
        cmp esi, K_WM_CONTEXTMENU
        je .Lpp_contextmenu
        cmp esi, K_WM_TIMER
        je .Lpp_timer
        cmp esi, K_WM_NCDESTROY
        je .Lpp_ncdestroy
.Lpp_default:
        mov rcx, rbx
        mov edx, esi
        mov r8, rdi
        mov r9, r12
        API DefWindowProcW
        jmp .Lpp_ret
.Lpp_nccalcsize:                        /* no non-client area: the image is the whole window */
        test rdi, rdi
        jz .Lpp_default
        jmp .Lpp_zero
.Lpp_nchittest:
        mov eax, K_HTCLIENT
        jmp .Lpp_ret
.Lpp_ncactivate:                        /* do not repaint a frame we do not have */
        mov rcx, rbx
        mov edx, esi
        mov r8, rdi
        mov r9, -1
        API DefWindowProcW
        jmp .Lpp_ret
.Lpp_getminmaxinfo:
        mov dword ptr [r12 + MMI_MINTRACK + PT_X], 1
        mov dword ptr [r12 + MMI_MINTRACK + PT_Y], 1
        mov dword ptr [r12 + MMI_MAXTRACK + PT_X], 32000
        mov dword ptr [r12 + MMI_MAXTRACK + PT_Y], 32000
        jmp .Lpp_zero
.Lpp_syscommand:
        mov eax, edi
        and eax, 0xFFF0
        cmp eax, K_SC_MAXIMIZE
        je .Lpp_zero
        cmp eax, K_SC_MINIMIZE
        je .Lpp_zero
        cmp eax, K_SC_SIZE
        je .Lpp_zero
        cmp eax, K_SC_RESTORE
        je .Lpp_zero
        jmp .Lpp_default
.Lpp_paint:
        mov rcx, r13
        call paint
        jmp .Lpp_zero
.Lpp_lbuttondown:
        mov rcx, rbx
        API SetCapture
        mov byte ptr [r13 + PIN_DRAG], 1
        lea rcx, [r13 + PIN_DRAG_PT]
        API GetCursorPos
        mov rcx, rbx
        lea rdx, [rsp + PP_WR]
        API GetWindowRect
        mov rax, qword ptr [rsp + PP_WR]        /* {left, top} */
        mov qword ptr [r13 + PIN_WIN_PT], rax
        jmp .Lpp_zero
.Lpp_mousemove:
        cmp byte ptr [r13 + PIN_DRAG], 0
        je .Lpp_zero
        lea rcx, [rsp + PP_C]
        API GetCursorPos
        mov r8d, dword ptr [r13 + PIN_WIN_PT + PT_X]
        add r8d, dword ptr [rsp + PP_C + PT_X]
        sub r8d, dword ptr [r13 + PIN_DRAG_PT + PT_X]
        mov r9d, dword ptr [r13 + PIN_WIN_PT + PT_Y]
        add r9d, dword ptr [rsp + PP_C + PT_Y]
        sub r9d, dword ptr [r13 + PIN_DRAG_PT + PT_Y]
        mov rcx, rbx
        xor edx, edx
        mov qword ptr [rsp + 32], 0
        mov qword ptr [rsp + 40], 0
        mov qword ptr [rsp + 48], K_SWP_MOVE_ONLY
        API SetWindowPos
        jmp .Lpp_zero
.Lpp_lbuttonup:
        cmp byte ptr [r13 + PIN_DRAG], 0
        je .Lpp_zero
        mov byte ptr [r13 + PIN_DRAG], 0
        API ReleaseCapture
        jmp .Lpp_zero
.Lpp_capturechanged:
        mov byte ptr [r13 + PIN_DRAG], 0
        jmp .Lpp_zero
.Lpp_mousewheel:
        mov eax, edi
        shr eax, 16
        movsx eax, ax                   /* wheel delta */
        test edi, K_MK_CONTROL
        jz .Lpp_zoom
        mov edx, dword ptr [r13 + PIN_ALPHA]
        mov ecx, -10
        mov r8d, 10
        test eax, eax
        cmovg ecx, r8d
        add edx, ecx
        mov rcx, r13
        call set_alpha
        jmp .Lpp_zero
.Lpp_zoom:
        movsx ecx, r12w                 /* the cursor in screen coordinates */
        mov edx, r12d
        shr edx, 16
        movsx edx, dx
        mov r8d, ecx
        shl rdx, 32
        or r8, rdx
        movss xmm1, dword ptr [rip + k_zoom_out]
        test eax, eax
        jle 1f
        movss xmm1, dword ptr [rip + k_zoom_in]
1:      movss xmm0, dword ptr [r13 + PIN_ZOOM]
        mulss xmm1, xmm0                /* z */
        movss xmm2, dword ptr [rip + k_one]
        /* always stop at 100% on the way through */
        ucomiss xmm2, xmm0
        jbe 1f
        ucomiss xmm1, xmm2              /* zoom < 1 && z > 1 */
        ja .Lpp_snap
1:      ucomiss xmm0, xmm2
        jbe 1f
        ucomiss xmm2, xmm1              /* zoom > 1 && z < 1 */
        ja .Lpp_snap
1:      movaps xmm3, xmm1
        subss xmm3, xmm2
        andps xmm3, xmmword ptr [rip + k_abs]
        movss xmm4, dword ptr [rip + k_snap]
        ucomiss xmm4, xmm3              /* |z - 1| < 0.02 */
        jbe 1f
.Lpp_snap:
        movaps xmm1, xmm2
1:      mov rcx, r13
        call set_zoom
        jmp .Lpp_zero
.Lpp_keydown:
        mov ecx, K_VK_CONTROL
        API GetKeyState
        mov esi, eax                    /* ctrl: bit 15 */
        cmp rdi, K_VK_ESCAPE
        je .Lpp_destroy
        test si, si
        jns .Lpp_zero
        cmp rdi, 0x43                   /* 'C' */
        jne 1f
        mov rcx, r13
        call pin_copy
        jmp .Lpp_zero
1:      cmp rdi, 0x53                   /* 'S' */
        jne .Lpp_zero
        mov rcx, r13
        call pin_save
        jmp .Lpp_zero
.Lpp_contextmenu:
        movsx eax, r12w
        mov edx, r12d
        shr edx, 16
        movsx edx, dx
        cmp eax, -1
        jne 1f
        cmp edx, -1
        jne 1f
        mov rcx, rbx                    /* from the keyboard: the window corner */
        lea rdx, [rsp + PP_WR]
        API GetWindowRect
        mov rdx, qword ptr [rsp + PP_WR]
        jmp 2f
1:      mov eax, eax
        shl rdx, 32
        or rdx, rax
2:      mov rcx, r13
        call pin_menu
        jmp .Lpp_zero
.Lpp_timer:
        cmp rdi, TIMER_LABEL
        jne .Lpp_zero
        mov rcx, rbx
        mov edx, TIMER_LABEL
        API KillTimer
        mov byte ptr [r13 + PIN_SHOW_LABEL], 0
        mov rcx, rbx
        xor edx, edx
        xor r8d, r8d
        API InvalidateRect
        jmp .Lpp_zero
.Lpp_destroy:
        mov rcx, rbx
        API DestroyWindow
        jmp .Lpp_zero
.Lpp_ncdestroy:
        mov rcx, rbx
        mov edx, K_GWLP_USERDATA
        xor r8d, r8d
        API SetWindowLongPtrW
        lea rax, [rip + p_list]
1:      mov rcx, qword ptr [rax]
        test rcx, rcx
        jz .Lpp_zero                    /* not listed yet = creation failed; pin_add frees it */
        cmp rcx, r13
        je 2f
        lea rax, [rcx + PIN_NEXT]
        jmp 1b
2:      mov rcx, qword ptr [r13 + PIN_NEXT]
        mov qword ptr [rax], rcx
        dec dword ptr [rip + p_count]
        lea rcx, [r13 + PIN_IMG]
        call img_destroy
        mov rcx, r13
        call mem_free
.Lpp_zero:
        xor eax, eax
        jmp .Lpp_ret
.Lpp_one:
        mov eax, 1
.Lpp_ret:
        add rsp, 80
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
        ENDF

/* ---- exported ------------------------------------------------------------------------- */

/* bool pin_init(HINSTANCE inst, HWND daemon) */
FUNC pin_init
        PUSHREG rbx
        ALLOC 112
        ENDPROLOG
        mov qword ptr [rip + p_inst], rcx
        mov qword ptr [rip + p_daemon], rdx
        mov rbx, rcx
        xorps xmm0, xmm0
        movups xmmword ptr [rsp + 32], xmm0
        movups xmmword ptr [rsp + 48], xmm0
        movups xmmword ptr [rsp + 64], xmm0
        movups xmmword ptr [rsp + 80], xmm0
        mov qword ptr [rsp + 96], 0
        mov dword ptr [rsp + 32 + WC_STYLE], K_CS_DBLCLKS
        lea rax, [rip + pin_proc]
        mov qword ptr [rsp + 32 + WC_WNDPROC], rax
        mov qword ptr [rsp + 32 + WC_INSTANCE], rbx
        xor ecx, ecx
        mov edx, K_IDC_SIZEALL
        API LoadCursorW
        mov qword ptr [rsp + 32 + WC_CURSOR], rax
        lea rax, [rip + w_class]
        mov qword ptr [rsp + 32 + WC_CLASSNAME], rax
        lea rcx, [rsp + 32]
        API RegisterClassW
        xor ecx, ecx
        test ax, ax
        setnz cl
        mov eax, ecx
        add rsp, 112
        pop rbx
        ret
        ENDF

/* bool pin_add(Img *img, int x, int y, bool at_cursor): takes ownership of img */
#define PD_C 96                         /* POINT */
#define PD_MI 104                       /* MONITORINFO */
#define PD_MG 144                       /* MARGINS */
#define PD_CORNER 160
FUNC pin_add
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 176
        ENDPROLOG
        mov rbx, rcx                    /* img */
        mov edi, edx                    /* x */
        mov r12d, r8d                   /* y */
        movzx r15d, r9b                 /* at_cursor */
        mov ecx, PIN_SIZE
        call mem_alloc
        test rax, rax
        jnz 1f
        mov rcx, rbx
        call img_destroy
        xor eax, eax
        jmp .Lpd_ret
1:      mov rsi, rax                    /* p */
        movups xmm0, xmmword ptr [rbx]
        movups xmm1, xmmword ptr [rbx + 16]
        mov rax, qword ptr [rbx + 32]
        movups xmmword ptr [rsi + PIN_IMG], xmm0
        movups xmmword ptr [rsi + PIN_IMG + 16], xmm1
        mov qword ptr [rsi + PIN_IMG + 32], rax
        xorps xmm0, xmm0
        movups xmmword ptr [rbx], xmm0
        movups xmmword ptr [rbx + 16], xmm0
        mov qword ptr [rbx + 32], 0
        mov dword ptr [rsi + PIN_ZOOM], 0x3F800000      /* 1.f */
        mov dword ptr [rsi + PIN_ALPHA], 100
        mov r13d, dword ptr [rsi + PIN_IMG + IMG_W]     /* w */
        mov r14d, dword ptr [rsi + PIN_IMG + IMG_H]     /* h */
        test r15d, r15d
        jz .Lpd_create
        /* center on the cursor and shrink to fit the monitor */
        lea rcx, [rsp + PD_C]
        API GetCursorPos
        mov rcx, qword ptr [rsp + PD_C]
        mov edx, K_MONITOR_DEFAULTTONEAREST
        API MonitorFromPoint
        xorps xmm0, xmm0
        movups xmmword ptr [rsp + PD_MI], xmm0
        movups xmmword ptr [rsp + PD_MI + 16], xmm0
        mov qword ptr [rsp + PD_MI + 32], 0
        mov dword ptr [rsp + PD_MI], MI_BYTES
        mov rcx, rax
        lea rdx, [rsp + PD_MI]
        API GetMonitorInfoW
        mov eax, dword ptr [rsp + PD_MI + MI_RCWORK + RC_R]
        sub eax, dword ptr [rsp + PD_MI + MI_RCWORK + RC_L]
        cvtsi2ss xmm0, eax
        mulss xmm0, dword ptr [rip + k_fit]
        cvtsi2ss xmm1, r13d
        divss xmm0, xmm1
        mov eax, dword ptr [rsp + PD_MI + MI_RCWORK + RC_B]
        sub eax, dword ptr [rsp + PD_MI + MI_RCWORK + RC_T]
        cvtsi2ss xmm2, eax
        mulss xmm2, dword ptr [rip + k_fit]
        cvtsi2ss xmm1, r14d
        divss xmm2, xmm1
        minss xmm0, xmm2                /* fit */
        movss xmm1, dword ptr [rip + k_one]
        ucomiss xmm1, xmm0
        jbe 1f
        movss dword ptr [rsi + PIN_ZOOM], xmm0
        mov ecx, 8
        cvtsi2ss xmm1, r13d
        mulss xmm1, xmm0
        LROUNDF r13d, xmm1, xmm2
        cmp r13d, ecx
        cmovl r13d, ecx
        cvtsi2ss xmm1, r14d
        mulss xmm1, xmm0
        LROUNDF r14d, xmm1, xmm2
        cmp r14d, ecx
        cmovl r14d, ecx
1:      /* x = CLAMPI(c.x - w / 2, left, right - w), y likewise */
        mov eax, r13d
        mov edx, eax
        shr edx, 31
        add eax, edx
        sar eax, 1
        mov edi, dword ptr [rsp + PD_C + PT_X]
        sub edi, eax
        mov eax, dword ptr [rsp + PD_MI + MI_RCWORK + RC_L]
        mov ecx, dword ptr [rsp + PD_MI + MI_RCWORK + RC_R]
        sub ecx, r13d
        cmp edi, eax
        jl 1f
        cmp edi, ecx
        jle 2f
        mov edi, ecx
        jmp 2f
1:      mov edi, eax
2:      mov eax, r14d
        mov edx, eax
        shr edx, 31
        add eax, edx
        sar eax, 1
        mov r12d, dword ptr [rsp + PD_C + PT_Y]
        sub r12d, eax
        mov eax, dword ptr [rsp + PD_MI + MI_RCWORK + RC_T]
        mov ecx, dword ptr [rsp + PD_MI + MI_RCWORK + RC_B]
        sub ecx, r14d
        cmp r12d, eax
        jl 1f
        cmp r12d, ecx
        jle .Lpd_create
        mov r12d, ecx
        jmp .Lpd_create
1:      mov r12d, eax
.Lpd_create:
        /* WS_CAPTION (non-client area removed in WM_NCCALCSIZE) gives the native DWM shadow. */
        mov ecx, K_WS_EX_PIN
        lea rdx, [rip + w_class]
        lea r8, [rip + w_name]
        mov r9d, K_WS_PIN
        mov dword ptr [rsp + 32], edi
        mov dword ptr [rsp + 40], r12d
        mov dword ptr [rsp + 48], r13d
        mov dword ptr [rsp + 56], r14d
        mov qword ptr [rsp + 64], 0
        mov qword ptr [rsp + 72], 0
        mov rax, qword ptr [rip + p_inst]
        mov qword ptr [rsp + 80], rax
        mov qword ptr [rsp + 88], rsi
        API CreateWindowExW
        test rax, rax
        jnz 1f
        lea rcx, [rsi + PIN_IMG]
        call img_destroy
        mov rcx, rsi
        call mem_free
        xor eax, eax
        jmp .Lpd_ret
1:      mov rbx, rax                    /* hwnd */
        mov rax, qword ptr [rip + p_list]
        mov qword ptr [rsi + PIN_NEXT], rax
        mov qword ptr [rip + p_list], rsi
        inc dword ptr [rip + p_count]
        xorps xmm0, xmm0
        movups xmmword ptr [rsp + PD_MG], xmm0
        mov dword ptr [rsp + PD_MG + MG_BOTTOM], 1
        mov rcx, rbx
        lea rdx, [rsp + PD_MG]
        API DwmExtendFrameIntoClientArea
        mov dword ptr [rsp + PD_CORNER], K_DWMWCP_DONOTROUND
        mov rcx, rbx
        mov edx, K_DWMWA_WINDOW_CORNER_PREFERENCE
        lea r8, [rsp + PD_CORNER]
        mov r9d, 4
        API DwmSetWindowAttribute
        mov rcx, rbx
        mov rdx, K_HWND_TOPMOST
        mov r8d, edi
        mov r9d, r12d
        mov dword ptr [rsp + 32], r13d
        mov dword ptr [rsp + 40], r14d
        mov dword ptr [rsp + 48], K_SWP_FRAMECHANGED_SHOW
        API SetWindowPos
        mov rcx, rbx
        API SetForegroundWindow
        mov eax, 1
.Lpd_ret:
        add rsp, 176
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
        ENDF

/* bool pin_any_visible(void) */
FUNC pin_any_visible
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rbx, qword ptr [rip + p_list]
1:      test rbx, rbx
        jz 2f
        mov rcx, qword ptr [rbx + PIN_HWND]
        API IsWindowVisible
        test eax, eax
        jnz 3f
        mov rbx, qword ptr [rbx + PIN_NEXT]
        jmp 1b
2:      xor eax, eax
        jmp 4f
3:      mov eax, 1
4:      add rsp, 32
        pop rbx
        ret
        ENDF

/* void pin_toggle_all(void): hide all if any is visible, else show all */
FUNC pin_toggle_all
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        xor esi, esi
        mov rbx, qword ptr [rip + p_list]
1:      test rbx, rbx
        jz 2f
        mov rcx, qword ptr [rbx + PIN_HWND]
        API IsWindowVisible
        test eax, eax
        jz 3f
        mov esi, 1
3:      mov rbx, qword ptr [rbx + PIN_NEXT]
        jmp 1b
2:      mov eax, K_SW_SHOWNOACTIVATE
        mov ecx, K_SW_HIDE
        test esi, esi
        cmovnz eax, ecx
        mov esi, eax
        mov rbx, qword ptr [rip + p_list]
1:      test rbx, rbx
        jz 2f
        mov rcx, qword ptr [rbx + PIN_HWND]
        mov edx, esi
        API ShowWindow
        mov rbx, qword ptr [rbx + PIN_NEXT]
        jmp 1b
2:      add rsp, 40
        pop rsi
        pop rbx
        ret
        ENDF

/* void pin_close_all(void) */
FUNC pin_close_all
        ALLOC 40
        ENDPROLOG
1:      mov rax, qword ptr [rip + p_list]
        test rax, rax
        jz 2f
        mov rcx, qword ptr [rax + PIN_HWND]
        API DestroyWindow
        jmp 1b
2:      add rsp, 40
        ret
        ENDF

/* int pin_count(void) */
FUNC pin_count
        ENDPROLOG
        mov eax, dword ptr [rip + p_count]
        ret
        ENDF
