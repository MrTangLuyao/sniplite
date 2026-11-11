/* shot.S: whole-desktop capture (see shot.h), x86-64 assembly replacement for
 * shot.c. Same exported functions, same Shot contents and the same sequence of
 * DXGI, D3D11 and window calls (that order is what keeps the capture fast and
 * the overlay out of its own screenshot):
 *
 *   capture:  duplicate every usable output, show the 1x1 pokes and the caller's
 *             window in one DeferWindowPos batch, wait for one fresh frame per
 *             output, hand it to the frame callback (GPU copy for the overlay),
 *             keep the frames (or stage them now without a callback), GDI BitBlt
 *             for the monitors DXGI could not deliver;
 *   shot_map: copy the kept frames to staging textures, hide the pokes, flush,
 *             then map every staging texture (the tile's bits).
 *
 * The D3D11 devices are built on a worker thread (gpu_build), posted back with
 * WM_APP_GPU_READY. Rows are copied with rep movsb (fastest measured for the
 * freshly allocated DIBs shot_copy fills), small rows with SSE2.
 *
 * Windows constants (K_), structure offsets (OD_, OD1_, TD_, FI_, MS_, MIX_, WCL_)
 * and vtable slots (V_) are checked against the headers by tests/shot_check.c;
 * Shot/Tile/ShotShow offsets come from ov_layout.inc. */
#include "asm.inc"
#include "ov_layout.inc"

/* ---- Windows constants ------------------------------------------------------------ */
#define K_SM_XVIRTUALSCREEN 76
#define K_SM_YVIRTUALSCREEN 77
#define K_SM_CXVIRTUALSCREEN 78
#define K_SM_CYVIRTUALSCREEN 79
#define K_HWND_TOPMOST -1
#define K_SWP_SHOW 0x50                 /* SWP_NOACTIVATE | SWP_SHOWWINDOW */
#define K_SWP_HIDE 0x97                 /* SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOMOVE | SWP_NOSIZE | SWP_HIDEWINDOW */
#define K_POKE_EXSTYLE 0x08200088       /* WS_EX_NOREDIRECTIONBITMAP | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE */
#define K_WS_POPUP 0x80000000
#define K_SRCCOPY 0x00CC0020
#define K_DEVICE_FLAGS 0x29             /* D3D11_CREATE_DEVICE_SINGLETHREADED | BGRA_SUPPORT | PREVENT_INTERNAL_THREADING_OPTIMIZATIONS */
#define K_D3D_DRIVER_TYPE_UNKNOWN 0
#define K_D3D11_SDK_VERSION 7
#define K_ROTATION_UNSPECIFIED 0
#define K_ROTATION_IDENTITY 1
#define K_COLOR_SPACE_HDR 12            /* DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020 */
#define K_FORMAT_BGRA 87                /* DXGI_FORMAT_B8G8R8A8_UNORM */
#define K_USAGE_STAGING 3
#define K_CPU_ACCESS_READ 0x20000
#define K_MAP_READ 1
#define K_ERR_ACCESS_LOST 0x887A0026
#define K_ERR_DEVICE_REMOVED 0x887A0005
#define K_ERR_DEVICE_RESET 0x887A0007
#define K_ERR_INVALID_CALL 0x887A0001
#define K_E_INVALIDARG 0x80070057
#define K_ERR_WAIT_TIMEOUT 0x887A0027
#define K_GPU_MAX_DEV 4

/* ---- Windows structures ------------------------------------------------------------- */
#define OD_NAME 0                       /* DXGI_OUTPUT_DESC */
#define OD_COORDS 64
#define OD_ATTACHED 80
#define OD_ROTATION 84
#define OD_BYTES 96
#define OD1_COLORSPACE 100              /* DXGI_OUTPUT_DESC1 */
#define OD1_BYTES 152
#define TD_WIDTH 0                      /* D3D11_TEXTURE2D_DESC */
#define TD_HEIGHT 4
#define TD_MIPLEVELS 8
#define TD_ARRAYSIZE 12
#define TD_FORMAT 16
#define TD_USAGE 28
#define TD_BINDFLAGS 32
#define TD_CPUACCESS 36
#define TD_MISCFLAGS 40
#define TD_BYTES 44
#define FI_LASTPRESENT 0                /* DXGI_OUTDUPL_FRAME_INFO */
#define FI_BYTES 48
#define MS_PDATA 0                      /* D3D11_MAPPED_SUBRESOURCE */
#define MS_ROWPITCH 8
#define MS_BYTES 16
#define MIX_CBSIZE 0                    /* MONITORINFOEXW */
#define MIX_RCMONITOR 4
#define MIX_SZDEVICE 40
#define MIX_BYTES 104
#define WCL_WNDPROC 8                   /* WNDCLASSW */
#define WCL_HINSTANCE 24
#define WCL_CLASSNAME 64
#define WCL_BYTES 72

/* ---- COM vtable slots ----------------------------------------------------------------- */
#define V_QueryInterface 0
#define V_AddRef 1
#define V_Release 2
#define V_Factory1_EnumAdapters1 12
#define V_Adapter1_EnumOutputs 7
#define V_Output_GetDesc 7
#define V_Output1_DuplicateOutput 22
#define V_Output6_GetDesc1 27
#define V_Device_CreateTexture2D 5
#define V_Context_Map 14
#define V_Context_Unmap 15
#define V_Context_CopyResource 47
#define V_Context_ClearState 110
#define V_Context_Flush 111
#define V_Texture2D_GetDesc 10
#define V_Dupl_AcquireNextFrame 8
#define V_Dupl_ReleaseFrame 14
#define V_Device3_Trim 17

/* ---- this file's structures --------------------------------------------------------- */
/* GpuState (heap; built by gpu_build, handed over in WM_APP_GPU_READY's lParam) */
#define GD_DEV 0                        /* GDev: ID3D11Device, its context */
#define GD_CTX 8
#define GD_BYTES 16
#define GO_OUT 0                        /* GOut: IDXGIOutput1, device index, rect, name */
#define GO_DEV 8
#define GO_RC 12
#define GO_NAME 28
#define GO_BYTES 96
#define GS_DEV 0                        /* GDev[K_GPU_MAX_DEV] */
#define GS_NDEV 64
#define GS_OUT 72                       /* GOut[SHOT_MAX_TILES] */
#define GS_NOUT 1608
#define GS_BYTES 1616
/* Dup: one output's duplication during a capture */
#define DUP_DUP 0                       /* IDXGIOutputDuplication */
#define DUP_RES 8                       /* IDXGIResource of the acquired frame */
#define DUP_TEX 16                      /* the frame as ID3D11Texture2D, while held */
#define DUP_STAGE 24                    /* staging copy */
#define DUP_GD 32                       /* GDev * */
#define DUP_BYTES 40
/* MonList: the monitors of one capture */
#define ML_H 0                          /* HMONITOR[16] */
#define ML_RC 128                       /* RECT[16], screen coordinates */
#define ML_NAME 384                     /* WCHAR[16][32] */
#define ML_N 1408
#define ML_BYTES 1416
/* module state (g_shot) */
#define G_NOTIFY 0
#define G_ST 8                          /* GpuState * */
#define G_CREATE_FACTORY 16             /* CreateDXGIFactory1 */
#define G_CREATE_DEVICE 24              /* D3D11CreateDevice */
#define G_ON_READY 32
#define G_POKE 40                       /* HWND[16] */
#define G_ENABLED 168
#define G_BUILDING 169
#define G_REBUILD 170
#define G_REGISTERED 171                /* the poke window class */
#define H_DX 176                        /* Dup[16]: frames held after shot_take_gpu with a callback */
#define H_N 816
#define H_ON 820
#define G_BYTES 824

        .section .bss$shot,"bw"
        .balign 16
g_shot: .space G_BYTES

        .section .rdata$shot,"dr"
        .balign 8
d_100:  .quad 0x4059000000000000        /* 100.0 */
d_25:   .quad 0x4039000000000000        /* 25.0 */
        GUIDDEF iid_factory1, 0x770aae78, 0xf26f, 0x4dba, 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87
        GUIDDEF iid_output1, 0x00cddea8, 0x939b, 0x4b83, 0xa3, 0x40, 0xa6, 0x85, 0x22, 0x66, 0x66, 0xcc
        GUIDDEF iid_output6, 0x068346e8, 0xaaec, 0x4b84, 0xad, 0xd7, 0x13, 0x7f, 0x51, 0x3f, 0x77, 0xa1
        GUIDDEF iid_texture2d, 0x6f15aaf2, 0xd208, 0x4e89, 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c
        GUIDDEF iid_device3, 0x6007896c, 0x3244, 0x4afd, 0xbf, 0x18, 0xa6, 0xd3, 0xbe, 0xda, 0x50, 0x23
        .balign 2
        /* L"dxgi.dll" */
w_dxgi:
        .short 0x0064, 0x0078, 0x0067, 0x0069, 0x002E, 0x0064, 0x006C, 0x006C, 0x0000
        /* L"d3d11.dll" */
w_d3d11:
        .short 0x0064, 0x0033, 0x0064, 0x0031, 0x0031, 0x002E, 0x0064, 0x006C, 0x006C, 0x0000
        /* L"sniplite.poke" */
w_poke_class:
        .short 0x0073, 0x006E, 0x0069, 0x0070, 0x006C, 0x0069, 0x0074, 0x0065, 0x002E, 0x0070, 0x006F, 0x006B
        .short 0x0065, 0x0000
        /* L"" */
w_empty:
        .short 0x0000
        /* L"gdi" */
w_gdi:
        .short 0x0067, 0x0064, 0x0069, 0x0000
        /* L"dxgi" */
w_dxgi_name:
        .short 0x0064, 0x0078, 0x0067, 0x0069, 0x0000
        /* L"starting" */
w_starting:
        .short 0x0073, 0x0074, 0x0061, 0x0072, 0x0074, 0x0069, 0x006E, 0x0067, 0x0000
a_create_factory:       .asciz "CreateDXGIFactory1"
a_create_device:        .asciz "D3D11CreateDevice"

/* ---- small helpers ------------------------------------------------------------------- */

/* al = hr means the duplication or the device is gone: rebuild the GPU state (ecx = hr) */
SFUNC hr_rebuild
        ENDPROLOG
        mov eax, 1
        cmp ecx, K_ERR_ACCESS_LOST
        je 1f
        cmp ecx, K_ERR_DEVICE_REMOVED
        je 1f
        cmp ecx, K_ERR_DEVICE_RESET
        je 1f
        cmp ecx, K_ERR_INVALID_CALL
        je 1f
        cmp ecx, K_E_INVALIDARG
        je 1f
        xor eax, eax
1:      ret
ENDF

/* lstrcpynW(rcx, rdx, 32): at most 31 characters, always terminated */
SFUNC wcopy31
        ENDPROLOG
        mov r8d, 31
1:      movzx eax, word ptr [rdx]
        test eax, eax
        jz 2f
        mov word ptr [rcx], ax
        add rcx, 2
        add rdx, 2
        dec r8d
        jnz 1b
2:      mov word ptr [rcx], 0
        ret
ENDF

/* ---- GPU state ------------------------------------------------------------------------ */

/* void gpu_state_free(GpuState *st) */
SFUNC gpu_state_free
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 32
        ENDPROLOG
        test rcx, rcx
        jz .Lsf_ret
        mov rbx, rcx
        lea rsi, [rcx + GS_OUT]
        mov edi, dword ptr [rcx + GS_NOUT]
.Lsf_out:
        dec edi
        js .Lsf_devs
        mov rcx, qword ptr [rsi + GO_OUT]
        COM V_Release
        add rsi, GO_BYTES
        jmp .Lsf_out
.Lsf_devs:
        lea rsi, [rbx + GS_DEV]
        mov edi, dword ptr [rbx + GS_NDEV]
.Lsf_dev:
        dec edi
        js .Lsf_free
        mov rcx, qword ptr [rsi + GD_CTX]
        COM V_Release
        mov rcx, qword ptr [rsi + GD_DEV]
        COM V_Release
        add rsi, GD_BYTES
        jmp .Lsf_dev
.Lsf_free:
        mov rcx, rbx
        call mem_free
.Lsf_ret:
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* DWORD WINAPI gpu_build(void *): the worker thread. One D3D11 device per adapter
 * with a usable output (attached, not rotated, not HDR); posts the state to the
 * notify window (freed if that fails). */
#define GB_F 80                         /* IDXGIFactory1 * */
#define GB_AD 88                        /* IDXGIAdapter1 * */
#define GB_O 96                         /* IDXGIOutput * */
#define GB_O1 104
#define GB_O6 112
#define GB_DEV 120
#define GB_CTX 128
#define GB_D 136                        /* DXGI_OUTPUT_DESC */
#define GB_D1 232                       /* DXGI_OUTPUT_DESC1 */
#define GB_FRAME 384
SFUNC gpu_build
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        ALLOC GB_FRAME
        ENDPROLOG
        mov ecx, GS_BYTES
        call mem_alloc
        mov rbx, rax                    /* st */
        test rax, rax
        jz .Lgb_post
        lea rcx, [rip + iid_factory1]
        lea rdx, [rsp + GB_F]
        call qword ptr [rip + g_shot + G_CREATE_FACTORY]
        test eax, eax
        js .Lgb_post
        xor esi, esi                    /* adapter index */
.Lgb_adapter:
        mov rcx, qword ptr [rsp + GB_F]
        mov edx, esi
        lea r8, [rsp + GB_AD]
        COM V_Factory1_EnumAdapters1
        test eax, eax                   /* != S_OK */
        jnz .Lgb_adapters_done
        mov r13d, -1                    /* this adapter's device index */
        xor edi, edi                    /* output index */
.Lgb_output:
        cmp dword ptr [rbx + GS_NOUT], SHOT_MAX_TILES
        jge .Lgb_outputs_done
        mov rcx, qword ptr [rsp + GB_AD]
        mov edx, edi
        lea r8, [rsp + GB_O]
        COM V_Adapter1_EnumOutputs
        test eax, eax
        jnz .Lgb_outputs_done
        mov rcx, qword ptr [rsp + GB_O]
        lea rdx, [rsp + GB_D]
        COM V_Output_GetDesc
        test eax, eax
        js .Lgb_release_output
        /* usable: attached, identity rotation, not HDR */
        cmp dword ptr [rsp + GB_D + OD_ATTACHED], 0
        je .Lgb_release_output
        mov eax, dword ptr [rsp + GB_D + OD_ROTATION]
        cmp eax, K_ROTATION_IDENTITY
        je .Lgb_rot_ok
        cmp eax, K_ROTATION_UNSPECIFIED
        jne .Lgb_release_output
.Lgb_rot_ok:
        mov rcx, qword ptr [rsp + GB_O]
        lea rdx, [rip + iid_output6]
        lea r8, [rsp + GB_O6]
        COM V_QueryInterface
        test eax, eax
        js .Lgb_usable
        mov rcx, qword ptr [rsp + GB_O6]
        lea rdx, [rsp + GB_D1]
        COM V_Output6_GetDesc1
        mov r12d, 1                     /* ok */
        test eax, eax
        js .Lgb_rel6
        cmp dword ptr [rsp + GB_D1 + OD1_COLORSPACE], K_COLOR_SPACE_HDR
        jne .Lgb_rel6
        xor r12d, r12d                  /* HDR: legacy duplication is not tone-mapped */
.Lgb_rel6:
        mov rcx, qword ptr [rsp + GB_O6]
        COM V_Release
        test r12d, r12d
        jz .Lgb_release_output
.Lgb_usable:
        test r13d, r13d
        jns .Lgb_have_dev
        cmp dword ptr [rbx + GS_NDEV], K_GPU_MAX_DEV
        jge .Lgb_have_dev
        /* single-threaded, no driver worker threads: zero CPU while idle */
        mov rcx, qword ptr [rsp + GB_AD]
        mov edx, K_D3D_DRIVER_TYPE_UNKNOWN
        xor r8d, r8d
        mov r9d, K_DEVICE_FLAGS
        xor eax, eax
        mov qword ptr [rsp + 32], rax   /* feature levels */
        mov qword ptr [rsp + 40], rax
        mov qword ptr [rsp + 48], K_D3D11_SDK_VERSION
        lea rax, [rsp + GB_DEV]
        mov qword ptr [rsp + 56], rax
        mov qword ptr [rsp + 64], 0     /* feature level out */
        lea rax, [rsp + GB_CTX]
        mov qword ptr [rsp + 72], rax
        call qword ptr [rip + g_shot + G_CREATE_DEVICE]
        test eax, eax
        js .Lgb_have_dev
        mov r13d, dword ptr [rbx + GS_NDEV]
        lea eax, [r13 + 1]
        mov dword ptr [rbx + GS_NDEV], eax
        mov eax, r13d
        shl eax, 4
        mov rcx, qword ptr [rsp + GB_DEV]
        mov qword ptr [rbx + rax + GS_DEV + GD_DEV], rcx
        mov rcx, qword ptr [rsp + GB_CTX]
        mov qword ptr [rbx + rax + GS_DEV + GD_CTX], rcx
.Lgb_have_dev:
        test r13d, r13d
        js .Lgb_release_output
        mov rcx, qword ptr [rsp + GB_O]
        lea rdx, [rip + iid_output1]
        lea r8, [rsp + GB_O1]
        COM V_QueryInterface
        test eax, eax
        js .Lgb_release_output
        mov eax, dword ptr [rbx + GS_NOUT]
        lea ecx, [rax + 1]
        mov dword ptr [rbx + GS_NOUT], ecx
        imul eax, eax, GO_BYTES
        lea rcx, [rbx + rax + GS_OUT]
        mov rax, qword ptr [rsp + GB_O1]
        mov qword ptr [rcx + GO_OUT], rax
        mov dword ptr [rcx + GO_DEV], r13d
        movups xmm0, xmmword ptr [rsp + GB_D + OD_COORDS]
        movups xmmword ptr [rcx + GO_RC], xmm0
        add rcx, GO_NAME
        lea rdx, [rsp + GB_D + OD_NAME]
        call wcopy31
.Lgb_release_output:
        mov rcx, qword ptr [rsp + GB_O]
        COM V_Release
        inc edi
        jmp .Lgb_output
.Lgb_outputs_done:
        mov rcx, qword ptr [rsp + GB_AD]
        COM V_Release
        inc esi
        jmp .Lgb_adapter
.Lgb_adapters_done:
        mov rcx, qword ptr [rsp + GB_F]
        COM V_Release
.Lgb_post:
        mov rcx, qword ptr [rip + g_shot + G_NOTIFY]
        mov edx, WM_APP_GPU_READY
        xor r8d, r8d
        mov r9, rbx
        API PostMessageW
        test eax, eax
        jnz .Lgb_ret
        mov rcx, rbx
        call gpu_state_free
.Lgb_ret:
        xor eax, eax
        add rsp, GB_FRAME
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* Start the worker (default stack: GPU drivers need deep stacks). */
SFUNC gpu_spawn
        ALLOC 56
        ENDPROLOG
        xor ecx, ecx
        xor edx, edx
        lea r8, [rip + gpu_build]
        xor r9d, r9d
        mov qword ptr [rsp + 32], 0
        mov qword ptr [rsp + 40], 0
        API CreateThread
        test rax, rax
        jz .Lsp_ret
        mov byte ptr [rip + g_shot + G_BUILDING], 1
        mov rcx, rax
        add rsp, 56
        jmp qword ptr [rip + __imp_CloseHandle]
.Lsp_ret:
        add rsp, 56
        ret
ENDF

/* void gpu_start(HWND notify) */
FUNC gpu_start
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        mov qword ptr [rip + g_shot + G_NOTIFY], rcx
        cmp qword ptr [rip + g_shot + G_CREATE_FACTORY], 0
        jne .Lgs_enable
        lea rcx, [rip + w_dxgi]
        API LoadLibraryW
        mov rbx, rax
        lea rcx, [rip + w_d3d11]
        API LoadLibraryW
        mov rsi, rax
        test rbx, rbx
        jz .Lgs_ret
        test rsi, rsi
        jz .Lgs_ret
        mov rcx, rbx
        lea rdx, [rip + a_create_factory]
        API GetProcAddress
        mov rbx, rax
        mov rcx, rsi
        lea rdx, [rip + a_create_device]
        API GetProcAddress
        mov qword ptr [rip + g_shot + G_CREATE_DEVICE], rax
        test rbx, rbx
        jz .Lgs_ret
        test rax, rax
        jz .Lgs_ret
        mov qword ptr [rip + g_shot + G_CREATE_FACTORY], rbx
.Lgs_enable:
        mov byte ptr [rip + g_shot + G_ENABLED], 1
        cmp byte ptr [rip + g_shot + G_BUILDING], 0
        je .Lgs_spawn
        mov byte ptr [rip + g_shot + G_REBUILD], 1
        jmp .Lgs_ret
.Lgs_spawn:
        call gpu_spawn
.Lgs_ret:
        add rsp, 40
        pop rsi
        pop rbx
        ret
ENDF

/* void gpu_ready(void *state): WM_APP_GPU_READY */
FUNC gpu_ready
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov byte ptr [rip + g_shot + G_BUILDING], 0
        cmp byte ptr [rip + g_shot + G_ENABLED], 0
        jne .Lgr_take
        call gpu_state_free             /* stopped meanwhile */
        jmp .Lgr_ret
.Lgr_take:
        mov rbx, rcx
        call held_drop
        mov rcx, qword ptr [rip + g_shot + G_ST]
        call gpu_state_free
        mov qword ptr [rip + g_shot + G_ST], rbx
        cmp byte ptr [rip + g_shot + G_REBUILD], 0
        je .Lgr_cb
        mov byte ptr [rip + g_shot + G_REBUILD], 0
        call gpu_spawn
.Lgr_cb:
        cmp qword ptr [rip + g_shot + G_ON_READY], 0
        je .Lgr_ret
        add rsp, 32
        pop rbx                         /* (jmp [mem]: an epilogue form the unwinder knows; jmp reg is not) */
        jmp qword ptr [rip + g_shot + G_ON_READY]
.Lgr_ret:
        add rsp, 32
        pop rbx
        ret
ENDF

/* void gpu_stop(void): release everything, GDI only */
FUNC gpu_stop
        ALLOC 40
        ENDPROLOG
        mov byte ptr [rip + g_shot + G_ENABLED], 0
        mov byte ptr [rip + g_shot + G_REBUILD], 0
        mov rax, qword ptr [rip + g_shot + G_ON_READY]
        test rax, rax                   /* the presentation drops its device first */
        jz 1f
        call rax
1:      call held_drop
        mov rcx, qword ptr [rip + g_shot + G_ST]
        call gpu_state_free
        mov qword ptr [rip + g_shot + G_ST], 0
        add rsp, 40
        ret
ENDF

/* void shot_on_ready(void (*cb)(void)) */
FUNC shot_on_ready
        ENDPROLOG
        mov qword ptr [rip + g_shot + G_ON_READY], rcx
        ret
ENDF

/* bool shot_gpu(void **dev, void **ctx): the first GPU's device */
FUNC shot_gpu
        ENDPROLOG
        xor eax, eax
        cmp byte ptr [rip + g_shot + G_ENABLED], 0
        je 1f
        mov r8, qword ptr [rip + g_shot + G_ST]
        test r8, r8
        jz 1f
        cmp dword ptr [r8 + GS_NDEV], 0
        je 1f
        cmp dword ptr [r8 + GS_NOUT], 0
        je 1f
        mov r9, qword ptr [r8 + GS_DEV + GD_DEV]
        mov qword ptr [rcx], r9
        mov r9, qword ptr [r8 + GS_DEV + GD_CTX]
        mov qword ptr [rdx], r9
        mov eax, 1
1:      ret
ENDF

/* void gpu_display_changed(void) */
FUNC gpu_display_changed
        ENDPROLOG
        cmp byte ptr [rip + g_shot + G_ENABLED], 0
        je 1f
        cmp byte ptr [rip + g_shot + G_BUILDING], 0
        je gpu_spawn
        mov byte ptr [rip + g_shot + G_REBUILD], 1
1:      ret
ENDF

/* bool gpu_enabled(void) */
FUNC gpu_enabled
        ENDPROLOG
        movzx eax, byte ptr [rip + g_shot + G_ENABLED]
        ret
ENDF

/* const WCHAR *shot_backend(void): "dxgi", "gdi" or "starting" */
FUNC shot_backend
        ENDPROLOG
        lea rax, [rip + w_gdi]
        cmp byte ptr [rip + g_shot + G_ENABLED], 0
        je 1f
        mov rcx, qword ptr [rip + g_shot + G_ST]
        test rcx, rcx
        jz 2f
        cmp dword ptr [rcx + GS_NOUT], 0
        je 2f
        lea rax, [rip + w_dxgi_name]
        ret
2:      cmp byte ptr [rip + g_shot + G_BUILDING], 0
        je 1f
        lea rax, [rip + w_starting]
1:      ret
ENDF

/* ---- pokes: invisible 1x1 windows whose appearance makes DWM present a frame ---------- */

/* HWND poke_window(int i): created on first use. No redirection bitmap and no
 * content: nothing is ever drawn, yet DWM counts its appearance as a change. */
SFUNC poke_window
        PUSHREG rbx
        ALLOC 176
        ENDPROLOG
        movsxd rbx, ecx
        cmp byte ptr [rip + g_shot + G_REGISTERED], 0
        jne .Lpw_have_class
        xorps xmm0, xmm0
        movups xmmword ptr [rsp + 96], xmm0
        movups xmmword ptr [rsp + 112], xmm0
        movups xmmword ptr [rsp + 128], xmm0
        movups xmmword ptr [rsp + 144], xmm0
        movq qword ptr [rsp + 160], xmm0
        mov rax, qword ptr [rip + __imp_DefWindowProcW]
        mov qword ptr [rsp + 96 + WCL_WNDPROC], rax
        xor ecx, ecx
        API GetModuleHandleW
        mov qword ptr [rsp + 96 + WCL_HINSTANCE], rax
        lea rax, [rip + w_poke_class]
        mov qword ptr [rsp + 96 + WCL_CLASSNAME], rax
        lea rcx, [rsp + 96]
        API RegisterClassW
        mov byte ptr [rip + g_shot + G_REGISTERED], 1
.Lpw_have_class:
        lea rax, [rip + g_shot + G_POKE]
        mov rax, qword ptr [rax + rbx*8]
        test rax, rax
        jnz .Lpw_ret
        xor ecx, ecx
        API GetModuleHandleW
        mov qword ptr [rsp + 80], rax   /* hInstance */
        mov ecx, K_POKE_EXSTYLE
        lea rdx, [rip + w_poke_class]
        lea r8, [rip + w_empty]
        mov r9d, K_WS_POPUP
        xor eax, eax
        mov qword ptr [rsp + 32], rax   /* x, y */
        mov qword ptr [rsp + 40], rax
        mov qword ptr [rsp + 48], 1     /* 1x1 */
        mov qword ptr [rsp + 56], 1
        mov qword ptr [rsp + 64], rax   /* parent, menu */
        mov qword ptr [rsp + 72], rax
        mov qword ptr [rsp + 88], rax
        API CreateWindowExW
        lea rcx, [rip + g_shot + G_POKE]
        mov qword ptr [rcx + rbx*8], rax
.Lpw_ret:
        add rsp, 176
        pop rbx
        ret
ENDF

/* Show poke i at the bottom-right pixel of monitor rect rdx. */
SFUNC poke_fire
        PUSHREG rbx
        ALLOC 64
        ENDPROLOG
        mov rbx, rdx
        call poke_window
        test rax, rax
        jz .Lpf_ret
        mov rcx, rax
        mov rdx, K_HWND_TOPMOST
        mov r8d, dword ptr [rbx + RC_R]
        dec r8d
        mov r9d, dword ptr [rbx + RC_B]
        dec r9d
        mov qword ptr [rsp + 32], 1
        mov qword ptr [rsp + 40], 1
        mov qword ptr [rsp + 48], K_SWP_SHOW
        API SetWindowPos
.Lpf_ret:
        add rsp, 64
        pop rbx
        ret
ENDF

/* Hide poke i if it is visible. */
SFUNC poke_rest
        PUSHREG rbx
        ALLOC 64
        ENDPROLOG
        movsxd rcx, ecx
        lea rax, [rip + g_shot + G_POKE]
        mov rbx, qword ptr [rax + rcx*8]
        test rbx, rbx
        jz .Lpr_ret
        mov rcx, rbx
        API IsWindowVisible
        test eax, eax
        jz .Lpr_ret
        mov rcx, rbx
        xor edx, edx
        xor r8d, r8d
        xor r9d, r9d
        mov qword ptr [rsp + 32], 0
        mov qword ptr [rsp + 40], 0
        mov qword ptr [rsp + 48], K_SWP_HIDE
        API SetWindowPos
.Lpr_ret:
        add rsp, 64
        pop rbx
        ret
ENDF

/* Show the caller's window (rcx = ShotShow *) on top. */
SFUNC show_set
        ALLOC 56
        ENDPROLOG
        mov rax, rcx
        mov rcx, qword ptr [rax + SHOW_HWND]
        mov rdx, K_HWND_TOPMOST
        mov r8d, dword ptr [rax + SHOW_X]
        mov r9d, dword ptr [rax + SHOW_Y]
        mov r10d, dword ptr [rax + SHOW_W]
        mov qword ptr [rsp + 32], r10
        mov r10d, dword ptr [rax + SHOW_H]
        mov qword ptr [rsp + 40], r10
        mov qword ptr [rsp + 48], K_SWP_SHOW
        API SetWindowPos
        add rsp, 56
        ret
ENDF

/* BOOL CALLBACK mon_cb(HMONITOR h, HDC, LPRECT, LPARAM ml) */
SFUNC mon_cb
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 136
        ENDPROLOG
        mov rbx, r9
        mov rsi, rcx
        cmp dword ptr [rbx + ML_N], SHOT_MAX_TILES
        jge .Lmc_ret
        mov dword ptr [rsp + 32 + MIX_CBSIZE], MIX_BYTES
        lea rdx, [rsp + 32]
        API GetMonitorInfoW
        test eax, eax
        jz .Lmc_ret
        movsxd rax, dword ptr [rbx + ML_N]
        mov qword ptr [rbx + rax*8 + ML_H], rsi
        mov rcx, rax
        shl rcx, 4
        movups xmm0, xmmword ptr [rsp + 32 + MIX_RCMONITOR]
        movups xmmword ptr [rbx + rcx + ML_RC], xmm0
        shl rax, 6
        lea rcx, [rbx + rax + ML_NAME]
        lea rdx, [rsp + 32 + MIX_SZDEVICE]
        call wcopy31
        inc dword ptr [rbx + ML_N]
.Lmc_ret:
        mov eax, 1
        add rsp, 136
        pop rsi
        pop rbx
        ret
ENDF

/* GOut *find_output(const WCHAR *name, const RECT *rc): the duplicable output of a monitor */
SFUNC find_output
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 48
        ENDPROLOG
        mov rsi, rcx
        movups xmm1, xmmword ptr [rdx]
        movaps xmmword ptr [rsp + 32], xmm1
        mov rax, qword ptr [rip + g_shot + G_ST]
        test rax, rax
        jz .Lfo_none
        lea rbx, [rax + GS_OUT]
        mov edi, dword ptr [rax + GS_NOUT]
.Lfo_loop:
        dec edi
        js .Lfo_none
        movups xmm0, xmmword ptr [rbx + GO_RC]
        pcmpeqb xmm0, xmmword ptr [rsp + 32]
        pmovmskb eax, xmm0
        cmp eax, 0xFFFF
        jne .Lfo_next
        lea rcx, [rbx + GO_NAME]
        mov rdx, rsi
        API lstrcmpiW
        test eax, eax
        jz .Lfo_found
.Lfo_next:
        add rbx, GO_BYTES
        jmp .Lfo_loop
.Lfo_found:
        mov rax, rbx
        jmp .Lfo_ret
.Lfo_none:
        xor eax, eax
.Lfo_ret:
        add rsp, 48
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* GDI tile: void gdi_tile(Tile *t, HDC *scr, const RECT *mon) */
SFUNC gdi_tile
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        ALLOC 80
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        mov rdi, r8
        mov r12d, dword ptr [rcx + TILE_RC + RC_R]
        sub r12d, dword ptr [rcx + TILE_RC + RC_L]      /* w */
        mov r13d, dword ptr [rcx + TILE_RC + RC_B]
        sub r13d, dword ptr [rcx + TILE_RC + RC_T]      /* h */
        lea rcx, [rbx + TILE_GDI]
        mov edx, r12d
        mov r8d, r13d
        call img_create
        test al, al
        jz .Lgt_ret
        mov rax, qword ptr [rsi]
        test rax, rax
        jnz 1f
        xor ecx, ecx
        API GetDC
        mov qword ptr [rsi], rax
1:      mov rcx, qword ptr [rbx + TILE_GDI + IMG_DC]
        xor edx, edx
        xor r8d, r8d
        mov r9d, r12d
        mov qword ptr [rsp + 32], r13
        mov qword ptr [rsp + 40], rax
        movsxd rax, dword ptr [rdi + RC_L]
        mov qword ptr [rsp + 48], rax
        movsxd rax, dword ptr [rdi + RC_T]
        mov qword ptr [rsp + 56], rax
        mov qword ptr [rsp + 64], K_SRCCOPY
        API BitBlt
        mov rax, qword ptr [rbx + TILE_GDI + IMG_PX]
        mov qword ptr [rbx + TILE_BITS], rax
        shl r12d, 2
        mov dword ptr [rbx + TILE_PITCH], r12d
.Lgt_ret:
        add rsp, 80
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* Show the pokes and the caller's window in one batch: one window manager
 * transaction instead of one per window. A caller window that is a poke itself
 * (it covers every monitor) needs no others.
 * void show_batch(const MonList *ml, const Dup *dx, const ShotShow *show) */
SFUNC show_batch
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        ALLOC 64
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        mov rdi, r8
        test r8, r8
        jz .Lsb_batch
        cmp byte ptr [r8 + SHOW_POKE], 0
        je .Lsb_batch
        mov rcx, r8
        call show_set
        jmp .Lsb_ret
.Lsb_batch:
        mov ecx, dword ptr [rbx + ML_N]
        inc ecx
        API BeginDeferWindowPos
        mov r12, rax                    /* HDWP */
        xor r13d, r13d
.Lsb_loop:
        cmp r13d, dword ptr [rbx + ML_N]
        jge .Lsb_show
        test r12, r12
        jz .Lsb_show
        imul eax, r13d, DUP_BYTES
        cmp qword ptr [rsi + rax + DUP_DUP], 0
        je .Lsb_next
        mov ecx, r13d
        call poke_window
        test rax, rax
        jz .Lsb_next
        mov rcx, r12
        mov rdx, rax
        mov r8, K_HWND_TOPMOST
        mov eax, r13d
        shl eax, 4
        mov r9d, dword ptr [rbx + rax + ML_RC + RC_R]
        dec r9d
        mov eax, dword ptr [rbx + rax + ML_RC + RC_B]
        dec eax
        mov qword ptr [rsp + 32], rax
        mov qword ptr [rsp + 40], 1
        mov qword ptr [rsp + 48], 1
        mov qword ptr [rsp + 56], K_SWP_SHOW
        API DeferWindowPos
        mov r12, rax
.Lsb_next:
        inc r13d
        jmp .Lsb_loop
.Lsb_show:
        test rdi, rdi
        jz .Lsb_end
        test r12, r12
        jz .Lsb_end
        mov rcx, r12
        mov rdx, qword ptr [rdi + SHOW_HWND]
        mov r8, K_HWND_TOPMOST
        mov r9d, dword ptr [rdi + SHOW_X]
        mov eax, dword ptr [rdi + SHOW_Y]
        mov qword ptr [rsp + 32], rax
        mov eax, dword ptr [rdi + SHOW_W]
        mov qword ptr [rsp + 40], rax
        mov eax, dword ptr [rdi + SHOW_H]
        mov qword ptr [rsp + 48], rax
        mov qword ptr [rsp + 56], K_SWP_SHOW
        API DeferWindowPos
        mov r12, rax
.Lsb_end:
        test r12, r12
        jz .Lsb_one_by_one
        mov rcx, r12
        API EndDeferWindowPos
        test eax, eax
        jnz .Lsb_ret
.Lsb_one_by_one:                        /* the batch failed */
        xor r13d, r13d
.Lsb_fire:
        cmp r13d, dword ptr [rbx + ML_N]
        jge .Lsb_fired
        imul eax, r13d, DUP_BYTES
        cmp qword ptr [rsi + rax + DUP_DUP], 0
        je 1f
        mov ecx, r13d
        mov edx, r13d
        shl edx, 4
        lea rdx, [rbx + rdx + ML_RC]
        call poke_fire
1:      inc r13d
        jmp .Lsb_fire
.Lsb_fired:
        test rdi, rdi
        jz .Lsb_ret
        mov rcx, rdi
        call show_set
.Lsb_ret:
        add rsp, 64
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* Queue the copy of every held frame to a staging texture, then let the frames go
 * (hide the pokes, start the GPU work).
 * void stage_frames(Shot *sh, Dup *dx, int n) */
SFUNC stage_frames
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        ALLOC 80
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        mov edi, r8d
        xor r12d, r12d
        mov r13, rdx
.Lst_frame:
        cmp r12d, edi
        jge .Lst_pokes
        mov rcx, qword ptr [r13 + DUP_TEX]
        test rcx, rcx
        jz .Lst_next
        lea rdx, [rsp + 32]
        COM V_Texture2D_GetDesc
        imul eax, r12d, TILE_BYTES
        lea rax, [rbx + rax + SHOT_TILE]
        mov ecx, dword ptr [rax + TILE_RC + RC_R]
        sub ecx, dword ptr [rax + TILE_RC + RC_L]
        mov edx, dword ptr [rax + TILE_RC + RC_B]
        sub edx, dword ptr [rax + TILE_RC + RC_T]
        cmp dword ptr [rsp + 32 + TD_FORMAT], K_FORMAT_BGRA
        jne .Lst_release
        cmp dword ptr [rsp + 32 + TD_WIDTH], ecx
        jne .Lst_release
        cmp dword ptr [rsp + 32 + TD_HEIGHT], edx
        jne .Lst_release
        mov dword ptr [rsp + 32 + TD_MIPLEVELS], 1
        mov dword ptr [rsp + 32 + TD_ARRAYSIZE], 1
        mov dword ptr [rsp + 32 + TD_USAGE], K_USAGE_STAGING
        mov dword ptr [rsp + 32 + TD_BINDFLAGS], 0
        mov dword ptr [rsp + 32 + TD_CPUACCESS], K_CPU_ACCESS_READ
        mov dword ptr [rsp + 32 + TD_MISCFLAGS], 0
        mov rax, qword ptr [r13 + DUP_GD]
        mov rcx, qword ptr [rax + GD_DEV]
        lea rdx, [rsp + 32]
        xor r8d, r8d
        lea r9, [r13 + DUP_STAGE]
        COM V_Device_CreateTexture2D
        test eax, eax
        js .Lst_failed
        mov rax, qword ptr [r13 + DUP_GD]
        mov rcx, qword ptr [rax + GD_CTX]
        mov rdx, qword ptr [r13 + DUP_STAGE]
        mov r8, qword ptr [r13 + DUP_TEX]
        COM V_Context_CopyResource
        jmp .Lst_release
.Lst_failed:
        mov qword ptr [r13 + DUP_STAGE], 0
.Lst_release:
        mov rcx, qword ptr [r13 + DUP_TEX]
        COM V_Release
        mov qword ptr [r13 + DUP_TEX], 0
.Lst_next:
        inc r12d
        add r13, DUP_BYTES
        jmp .Lst_frame
.Lst_pokes:
        xor r12d, r12d
.Lst_poke:
        cmp r12d, edi
        jge .Lst_flushes
        lea rax, [rip + g_shot + G_POKE]
        cmp qword ptr [rax + r12*8], 0
        je 1f
        mov ecx, r12d
        call poke_rest
1:      inc r12d
        jmp .Lst_poke
.Lst_flushes:                           /* start the GPU work now; nothing waits for it yet */
        mov r13, rsi
.Lst_flush:
        dec edi
        js .Lst_ret
        cmp qword ptr [r13 + DUP_STAGE], 0
        je 1f
        mov rax, qword ptr [r13 + DUP_GD]
        mov rcx, qword ptr [rax + GD_CTX]
        COM V_Context_Flush
1:      add r13, DUP_BYTES
        jmp .Lst_flush
.Lst_ret:
        add rsp, 80
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* Staging textures become tiles; frames and duplications are released, dx[0..n)
 * cleared. sh NULL: only releases (held frames never have staging textures).
 * void adopt_frames(Shot *sh, Dup *dx, int n) */
SFUNC adopt_frames
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 40
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        mov edi, r8d
        lea r12, [rcx + SHOT_TILE]
.Laf_loop:
        dec edi
        js .Laf_ret
        test rbx, rbx
        jz 1f
        mov rax, qword ptr [rsi + DUP_STAGE]
        test rax, rax
        jz 1f
        mov qword ptr [r12 + TILE_TEX], rax
        mov rax, qword ptr [rsi + DUP_GD]
        mov rcx, qword ptr [rax + GD_CTX]
        mov qword ptr [r12 + TILE_CTX], rcx
        COM V_AddRef
        inc dword ptr [rbx + SHOT_NDXGI]
1:      mov rcx, qword ptr [rsi + DUP_TEX]
        test rcx, rcx
        jz 2f
        COM V_Release
2:      mov rcx, qword ptr [rsi + DUP_RES]
        test rcx, rcx
        jz 3f
        COM V_Release
        mov rcx, qword ptr [rsi + DUP_DUP]
        COM V_Dupl_ReleaseFrame
3:      mov rcx, qword ptr [rsi + DUP_DUP]
        test rcx, rcx
        jz 4f
        COM V_Release
4:      xorps xmm0, xmm0
        movups xmmword ptr [rsi], xmm0
        movups xmmword ptr [rsi + 16], xmm0
        movq qword ptr [rsi + 32], xmm0
        add rsi, DUP_BYTES
        add r12, TILE_BYTES
        jmp .Laf_loop
.Laf_ret:
        add rsp, 40
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* Held frames that will not be read back (shot freed, GPU state replaced). */
SFUNC held_drop
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        cmp byte ptr [rip + g_shot + H_ON], 0
        je .Lhd_ret
        mov byte ptr [rip + g_shot + H_ON], 0
        xor ebx, ebx
.Lhd_poke:
        cmp ebx, dword ptr [rip + g_shot + H_N]
        jge .Lhd_release
        lea rax, [rip + g_shot + G_POKE]
        cmp qword ptr [rax + rbx*8], 0
        je 1f
        mov ecx, ebx
        call poke_rest
1:      inc ebx
        jmp .Lhd_poke
.Lhd_release:
        xor ecx, ecx
        lea rdx, [rip + g_shot + H_DX]
        mov r8d, dword ptr [rip + g_shot + H_N]
        call adopt_frames
.Lhd_ret:
        add rsp, 32
        pop rbx
        ret
ENDF

/* ---- capture ---------------------------------------------------------------------------- */

/* bool shot_take(Shot *sh, void (*idle)(void *), void *ctx) */
FUNC shot_take
        PUSHREG rbx
        ALLOC 48
        ENDPROLOG
        mov rbx, rcx
        mov qword ptr [rsp + 32], r8
        xor r8d, r8d
        xor r9d, r9d
        call take
        test al, al
        jz .Lst2_ret
        mov rcx, rbx
        call shot_map
        mov eax, 1
.Lst2_ret:
        add rsp, 48
        pop rbx
        ret
ENDF

/* bool shot_take_gpu(Shot *sh, const ShotShow *show, ShotFrameFn frame, void *ctx) */
FUNC shot_take_gpu
        ALLOC 40
        ENDPROLOG
        mov qword ptr [rsp + 32], r9
        mov r9, r8
        mov r8, rdx
        xor edx, edx
        call take
        add rsp, 40
        ret
ENDF

/* bool take(Shot *sh, void (*idle)(void *), const ShotShow *show, ShotFrameFn frame, void *ctx) */
#define TK_T0 64                        /* double */
#define TK_DEADLINE 72                  /* double */
#define TK_FI 80                        /* DXGI_OUTDUPL_FRAME_INFO */
#define TK_RES 128                      /* IDXGIResource * */
#define TK_SCR 136                      /* screen HDC */
#define TK_COVERED 144                  /* int64 */
#define TK_REBUILD 152                  /* bools */
#define TK_ANY 153
#define TK_NUDGED 154
#define TK_HELD 155
#define TK_ML 160                       /* MonList */
#define TK_DX 1576                      /* Dup[16] */
#define TK_FRAME 2216
#define TK_CTX (TK_FRAME + 64 + 40)     /* 5th argument */
SFUNC take
        PUSHREG rbp
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC TK_FRAME
        ENDPROLOG
        mov rbx, rcx                    /* sh */
        mov r12, rdx                    /* idle */
        mov r13, r8                     /* show */
        mov r14, r9                     /* frame */
        mov r15, qword ptr [rsp + TK_CTX]
        call held_drop
        call now_ms
        movsd qword ptr [rsp + TK_T0], xmm0
        mov rdi, rbx
        xor eax, eax
        mov ecx, SHOT_BYTES
        rep stosb
        mov ecx, K_SM_XVIRTUALSCREEN
        API GetSystemMetrics
        mov dword ptr [rbx + SHOT_VX], eax
        mov ecx, K_SM_YVIRTUALSCREEN
        API GetSystemMetrics
        mov dword ptr [rbx + SHOT_VY], eax
        mov ecx, K_SM_CXVIRTUALSCREEN
        API GetSystemMetrics
        mov dword ptr [rbx + SHOT_VW], eax
        mov ecx, K_SM_CYVIRTUALSCREEN
        API GetSystemMetrics
        mov dword ptr [rbx + SHOT_VH], eax
        cmp dword ptr [rbx + SHOT_VW], 0
        jle .Ltk_false
        test eax, eax
        jle .Ltk_false

        lea rdi, [rsp + TK_ML]
        xor eax, eax
        mov ecx, ML_BYTES + 640         /* MonList and Dup[16] (adjacent) */
        rep stosb
        mov dword ptr [rsp + TK_REBUILD], 0     /* rebuild, any, nudged, held */
        xor ecx, ecx
        xor edx, edx
        lea r8, [rip + mon_cb]
        lea r9, [rsp + TK_ML]
        API EnumDisplayMonitors
        cmp dword ptr [rsp + TK_ML + ML_N], 0
        jne .Ltk_mons
        /* should not happen; treat the virtual screen as one monitor */
        mov eax, dword ptr [rbx + SHOT_VX]
        mov dword ptr [rsp + TK_ML + ML_RC + RC_L], eax
        add eax, dword ptr [rbx + SHOT_VW]
        mov dword ptr [rsp + TK_ML + ML_RC + RC_R], eax
        mov eax, dword ptr [rbx + SHOT_VY]
        mov dword ptr [rsp + TK_ML + ML_RC + RC_T], eax
        add eax, dword ptr [rbx + SHOT_VH]
        mov dword ptr [rsp + TK_ML + ML_RC + RC_B], eax
        mov dword ptr [rsp + TK_ML + ML_N], 1
.Ltk_mons:
        mov eax, dword ptr [rsp + TK_ML + ML_N]
        mov dword ptr [rbx + SHOT_NTILE], eax
        /* tiles: rects relative to the virtual screen, DPI scale, covered area */
        mov qword ptr [rsp + TK_COVERED], 0
        xor edi, edi
        lea rsi, [rbx + SHOT_TILE]
.Ltk_tile:
        cmp edi, dword ptr [rsp + TK_ML + ML_N]
        jge .Ltk_tiles_done
        mov eax, edi
        shl eax, 4
        lea rcx, [rsp + rax + TK_ML + ML_RC]
        mov eax, dword ptr [rcx + RC_L]
        sub eax, dword ptr [rbx + SHOT_VX]
        mov dword ptr [rsi + TILE_RC + RC_L], eax
        mov edx, dword ptr [rcx + RC_T]
        sub edx, dword ptr [rbx + SHOT_VY]
        mov dword ptr [rsi + TILE_RC + RC_T], edx
        mov r8d, dword ptr [rcx + RC_R]
        sub r8d, dword ptr [rbx + SHOT_VX]
        mov dword ptr [rsi + TILE_RC + RC_R], r8d
        mov r9d, dword ptr [rcx + RC_B]
        sub r9d, dword ptr [rbx + SHOT_VY]
        mov dword ptr [rsi + TILE_RC + RC_B], r9d
        sub r8d, eax
        sub r9d, edx
        movsxd r8, r8d
        movsxd r9, r9d
        imul r8, r9
        add qword ptr [rsp + TK_COVERED], r8
        mov rcx, qword ptr [rsp + rdi*8 + TK_ML + ML_H]
        call dpi_scale_of
        movss dword ptr [rsi + TILE_SCALE], xmm0
        inc edi
        add rsi, TILE_BYTES
        jmp .Ltk_tile
.Ltk_tiles_done:
        movsxd rax, dword ptr [rbx + SHOT_VW]
        movsxd rcx, dword ptr [rbx + SHOT_VH]
        imul rax, rcx
        cmp qword ptr [rsp + TK_COVERED], rax
        setl byte ptr [rbx + SHOT_GAPS]

        /* 1. Duplicate every usable output. */
        xor edi, edi
        lea rsi, [rsp + TK_DX]
.Ltk_dup:
        cmp edi, dword ptr [rsp + TK_ML + ML_N]
        jge .Ltk_dups_done
        cmp qword ptr [rsp + rdi*8 + TK_ML + ML_H], 0
        je .Ltk_dup_next
        mov ecx, edi
        shl ecx, 6
        lea rcx, [rsp + rcx + TK_ML + ML_NAME]
        mov edx, edi
        shl edx, 4
        lea rdx, [rsp + rdx + TK_ML + ML_RC]
        call find_output
        test rax, rax
        jz .Ltk_dup_next
        movsxd rbp, dword ptr [rax + GO_DEV]
        shl rbp, 4
        add rbp, qword ptr [rip + g_shot + G_ST]        /* gd = &G.st->dev[o->dev] */
        mov rcx, qword ptr [rax + GO_OUT]
        mov rdx, qword ptr [rbp + GD_DEV]
        lea r8, [rsi + DUP_DUP]
        COM V_Output1_DuplicateOutput
        test eax, eax
        jns .Ltk_dup_ok
        mov qword ptr [rsi + DUP_DUP], 0
        mov ecx, eax
        call hr_rebuild
        or byte ptr [rsp + TK_REBUILD], al
        jmp .Ltk_dup_next
.Ltk_dup_ok:
        mov qword ptr [rsi + DUP_GD], rbp
        mov byte ptr [rsp + TK_ANY], 1
.Ltk_dup_next:
        inc edi
        add rsi, DUP_BYTES
        jmp .Ltk_dup
.Ltk_dups_done:

        /* 2. Force one present per output, then take that frame. */
        cmp byte ptr [rsp + TK_ANY], 0
        je .Ltk_no_dup
        lea rcx, [rsp + TK_ML]
        lea rdx, [rsp + TK_DX]
        mov r8, r13
        call show_batch
        xor r13d, r13d                  /* shown */
        test r12, r12
        jz 1f
        mov rcx, r15                    /* the present takes a refresh interval: idle meanwhile */
        call r12
        xor r12d, r12d
1:      call now_ms
        addsd xmm0, qword ptr [rip + d_100]
        movsd qword ptr [rsp + TK_DEADLINE], xmm0
        xor edi, edi
        lea rsi, [rsp + TK_DX]
.Ltk_frame:
        cmp edi, dword ptr [rsp + TK_ML + ML_N]
        jge .Ltk_frames_done
        cmp qword ptr [rsi + DUP_DUP], 0
        je .Ltk_frame_next
.Ltk_acquire:
        call now_ms
        movsd xmm1, qword ptr [rsp + TK_DEADLINE]
        subsd xmm1, xmm0                /* left */
        xor edx, edx
        xorpd xmm2, xmm2
        comisd xmm1, xmm2
        jbe 2f                          /* left <= 0: 0 */
        mov edx, 25
        comisd xmm1, qword ptr [rip + d_25]
        ja 2f                           /* left > 25: 25 */
        cvttsd2si edx, xmm1
2:      mov rcx, qword ptr [rsi + DUP_DUP]
        lea r8, [rsp + TK_FI]
        lea r9, [rsp + TK_RES]
        mov qword ptr [r9], 0
        COM V_Dupl_AcquireNextFrame
        cmp eax, K_ERR_WAIT_TIMEOUT
        jne .Ltk_not_timeout
        call now_ms
        comisd xmm0, qword ptr [rsp + TK_DEADLINE]
        jae .Ltk_acquired
        cmp byte ptr [rsp + TK_NUDGED], 0
        jne .Ltk_acquire
        /* no frame yet: show the pokes again (a move is not reliable) */
        mov byte ptr [rsp + TK_NUDGED], 1
        xor ebp, ebp
.Ltk_nudge:
        cmp ebp, dword ptr [rsp + TK_ML + ML_N]
        jge .Ltk_acquire
        imul eax, ebp, DUP_BYTES
        cmp qword ptr [rsp + rax + TK_DX + DUP_DUP], 0
        je 3f
        mov ecx, ebp
        call poke_rest
        mov ecx, ebp
        mov edx, ebp
        shl edx, 4
        lea rdx, [rsp + rdx + TK_ML + ML_RC]
        call poke_fire
3:      inc ebp
        jmp .Ltk_nudge
.Ltk_not_timeout:
        test eax, eax
        jns .Ltk_got
        mov ecx, eax
        call hr_rebuild
        or byte ptr [rsp + TK_REBUILD], al
        jmp .Ltk_acquired
.Ltk_got:
        cmp qword ptr [rsp + TK_FI + FI_LASTPRESENT], 0
        jne .Ltk_keep
        mov rcx, qword ptr [rsp + TK_RES]       /* pointer-only or the empty first frame */
        COM V_Release
        mov rcx, qword ptr [rsi + DUP_DUP]
        COM V_Dupl_ReleaseFrame
        jmp .Ltk_acquire
.Ltk_keep:
        mov rax, qword ptr [rsp + TK_RES]
        mov qword ptr [rsi + DUP_RES], rax
.Ltk_acquired:
        mov rcx, qword ptr [rsi + DUP_RES]
        test rcx, rcx
        jz .Ltk_frame_next
        lea rdx, [rip + iid_texture2d]
        lea r8, [rsi + DUP_TEX]
        COM V_QueryInterface
        test eax, eax
        js .Ltk_no_tex
        test r14, r14
        jz .Ltk_frame_next
        mov rcx, r15                    /* the caller's GPU copy for display */
        mov edx, edi
        mov rax, qword ptr [rsi + DUP_GD]
        mov r8, qword ptr [rax + GD_DEV]
        mov r9, qword ptr [rsi + DUP_TEX]
        call r14
        jmp .Ltk_frame_next
.Ltk_no_tex:
        mov qword ptr [rsi + DUP_TEX], 0
.Ltk_frame_next:
        inc edi
        add rsi, DUP_BYTES
        jmp .Ltk_frame
.Ltk_frames_done:
        /* with a frame callback the read-back waits for shot_map: frames stay held */
        test r14, r14
        jnz .Ltk_no_dup
        mov rcx, rbx
        lea rdx, [rsp + TK_DX]
        mov r8d, dword ptr [rsp + TK_ML + ML_N]
        call stage_frames
.Ltk_no_dup:
        test r13, r13                   /* no duplication at all */
        jz 1f
        mov rcx, r13
        call show_set
1:      test r12, r12
        jz 2f
        mov rcx, r15
        call r12

        /* 3. GDI for everything DXGI could not deliver (overlaps the GPU copies). */
2:      mov qword ptr [rsp + TK_SCR], 0
        xor edi, edi
        lea rsi, [rsp + TK_DX]
        lea rbp, [rbx + SHOT_TILE]
.Ltk_gdi:
        cmp edi, dword ptr [rsp + TK_ML + ML_N]
        jge .Ltk_gdi_done
        cmp qword ptr [rsi + DUP_STAGE], 0
        jne 3f
        cmp qword ptr [rsi + DUP_TEX], 0
        jne 3f
        mov rcx, rbp
        lea rdx, [rsp + TK_SCR]
        mov r8d, edi
        shl r8d, 4
        lea r8, [rsp + r8 + TK_ML + ML_RC]
        call gdi_tile
3:      inc edi
        add rsi, DUP_BYTES
        add rbp, TILE_BYTES
        jmp .Ltk_gdi
.Ltk_gdi_done:

        /* 4. The staging textures become the tiles, or the frames are kept for shot_map. */
        xor eax, eax
        mov ecx, dword ptr [rsp + TK_ML + ML_N]
        lea rsi, [rsp + TK_DX]
.Ltk_held:
        dec ecx
        js 4f
        or rax, qword ptr [rsi + DUP_TEX]
        add rsi, DUP_BYTES
        jmp .Ltk_held
4:      test rax, rax
        setnz byte ptr [rsp + TK_HELD]
        jz .Ltk_adopt
        lea rsi, [rsp + TK_DX]
        lea rdi, [rip + g_shot + H_DX]
        mov ecx, SHOT_MAX_TILES * DUP_BYTES
        rep movsb
        mov eax, dword ptr [rsp + TK_ML + ML_N]
        mov dword ptr [rip + g_shot + H_N], eax
        mov byte ptr [rip + g_shot + H_ON], 1
        jmp .Ltk_release_dc
.Ltk_adopt:
        test r14, r14
        jz 5f
        cmp byte ptr [rsp + TK_ANY], 0
        je 5f
        mov rcx, rbx                    /* nothing to keep: hide the pokes */
        lea rdx, [rsp + TK_DX]
        mov r8d, dword ptr [rsp + TK_ML + ML_N]
        call stage_frames
5:      mov rcx, rbx
        lea rdx, [rsp + TK_DX]
        mov r8d, dword ptr [rsp + TK_ML + ML_N]
        call adopt_frames
.Ltk_release_dc:
        cmp qword ptr [rsp + TK_SCR], 0
        je 6f
        API GdiFlush
        xor ecx, ecx
        mov rdx, qword ptr [rsp + TK_SCR]
        API ReleaseDC
6:      /* a tile without pixels (allocation failure): treat as uncovered (black) */
        xor edi, edi
        lea rsi, [rbx + SHOT_TILE]
        lea rbp, [rip + g_shot + H_DX]
.Ltk_gap:
        cmp edi, dword ptr [rbx + SHOT_NTILE]
        jge .Ltk_gaps_done
        cmp qword ptr [rsi + TILE_BITS], 0
        jne 7f
        cmp qword ptr [rsi + TILE_TEX], 0
        jne 7f
        cmp byte ptr [rsp + TK_HELD], 0
        je 8f
        cmp qword ptr [rbp + DUP_TEX], 0
        jne 7f
8:      mov byte ptr [rbx + SHOT_GAPS], 1
7:      inc edi
        add rsi, TILE_BYTES
        add rbp, DUP_BYTES
        jmp .Ltk_gap
.Ltk_gaps_done:
        cmp byte ptr [rsp + TK_REBUILD], 0
        je 9f
        call gpu_display_changed
9:      call now_ms
        subsd xmm0, qword ptr [rsp + TK_T0]
        movsd qword ptr [rbx + SHOT_GRAB_MS], xmm0
        mov eax, 1
        jmp .Ltk_ret
.Ltk_false:
        xor eax, eax
.Ltk_ret:
        add rsp, TK_FRAME
        pop r15
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        pop rbp
        ret
ENDF

/* Drivers keep freed staging memory pooled for reuse (tens of MB for a 4K screen).
 * We only capture now and then, so hand it back: flush the deferred destruction
 * and ask DXGI to trim. Runs after the screenshot is done, off the fast path. */
SFUNC gpu_trim
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        xor esi, esi
.Lgt2_loop:
        mov rax, qword ptr [rip + g_shot + G_ST]
        test rax, rax
        jz .Lgt2_ret
        cmp esi, dword ptr [rax + GS_NDEV]
        jge .Lgt2_ret
        mov ebx, esi
        shl ebx, 4
        add rbx, rax
        mov rcx, qword ptr [rbx + GS_DEV + GD_CTX]
        COM V_Context_ClearState
        mov rcx, qword ptr [rbx + GS_DEV + GD_CTX]
        COM V_Context_Flush
        mov rcx, qword ptr [rbx + GS_DEV + GD_DEV]
        lea rdx, [rip + iid_device3]
        lea r8, [rsp + 32]
        COM V_QueryInterface
        test eax, eax
        js 1f
        mov rcx, qword ptr [rsp + 32]
        COM V_Device3_Trim
        mov rcx, qword ptr [rsp + 32]
        COM V_Release
1:      inc esi
        jmp .Lgt2_loop
.Lgt2_ret:
        add rsp, 40
        pop rsi
        pop rbx
        ret
ENDF

/* void shot_map(Shot *sh): afterwards every tile has bits, or none (black) */
#define SM_MP 48                        /* D3D11_MAPPED_SUBRESOURCE */
#define SM_HR 64
FUNC shot_map
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 80
        ENDPROLOG
        mov rbx, rcx
        cmp byte ptr [rip + g_shot + H_ON], 0
        je .Lsm_map
        mov byte ptr [rip + g_shot + H_ON], 0
        lea rdx, [rip + g_shot + H_DX]
        mov r8d, dword ptr [rip + g_shot + H_N]
        call stage_frames
        mov esi, dword ptr [rip + g_shot + H_N]
        lea rdi, [rip + g_shot + H_DX]
.Lsm_gap:
        dec esi
        js .Lsm_adopt
        cmp qword ptr [rdi + DUP_RES], 0
        je 1f
        cmp qword ptr [rdi + DUP_STAGE], 0
        jne 1f
        mov byte ptr [rbx + SHOT_GAPS], 1       /* no staging texture: this monitor stays black */
1:      add rdi, DUP_BYTES
        jmp .Lsm_gap
.Lsm_adopt:
        mov rcx, rbx
        lea rdx, [rip + g_shot + H_DX]
        mov r8d, dword ptr [rip + g_shot + H_N]
        call adopt_frames
.Lsm_map:
        xor esi, esi
        lea rdi, [rbx + SHOT_TILE]
.Lsm_tile:
        cmp esi, dword ptr [rbx + SHOT_NTILE]
        jge .Lsm_ret
        mov rdx, qword ptr [rdi + TILE_TEX]
        test rdx, rdx
        jz .Lsm_next
        cmp qword ptr [rdi + TILE_BITS], 0
        jne .Lsm_next
        mov rcx, qword ptr [rdi + TILE_CTX]
        xor r8d, r8d
        mov r9d, K_MAP_READ
        mov qword ptr [rsp + 32], 0
        lea rax, [rsp + SM_MP]
        mov qword ptr [rsp + 40], rax
        COM V_Context_Map
        test eax, eax
        js .Lsm_lost
        mov rax, qword ptr [rsp + SM_MP + MS_PDATA]
        mov qword ptr [rdi + TILE_BITS], rax
        mov eax, dword ptr [rsp + SM_MP + MS_ROWPITCH]
        mov dword ptr [rdi + TILE_PITCH], eax
        jmp .Lsm_next
.Lsm_lost:                              /* device lost meanwhile: this monitor stays black */
        mov dword ptr [rsp + SM_HR], eax
        mov rcx, qword ptr [rdi + TILE_TEX]
        COM V_Release
        mov rcx, qword ptr [rdi + TILE_CTX]
        COM V_Release
        mov qword ptr [rdi + TILE_TEX], 0
        mov qword ptr [rdi + TILE_CTX], 0
        mov byte ptr [rbx + SHOT_GAPS], 1
        mov ecx, dword ptr [rsp + SM_HR]
        call hr_rebuild
        test al, al
        jz .Lsm_next
        call gpu_display_changed
.Lsm_next:
        inc esi
        add rdi, TILE_BYTES
        jmp .Lsm_tile
.Lsm_ret:
        add rsp, 80
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void shot_free(Shot *sh) */
FUNC shot_free
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 40
        ENDPROLOG
        mov rbx, rcx
        call held_drop
        xor r12d, r12d                  /* GPU tiles released */
        mov esi, dword ptr [rbx + SHOT_NTILE]
        lea rdi, [rbx + SHOT_TILE]
.Lsf2_tile:
        dec esi
        js .Lsf2_clear
        mov rdx, qword ptr [rdi + TILE_TEX]
        test rdx, rdx
        jz 2f
        cmp qword ptr [rdi + TILE_BITS], 0
        je 1f
        mov rcx, qword ptr [rdi + TILE_CTX]
        xor r8d, r8d
        COM V_Context_Unmap
1:      mov rcx, qword ptr [rdi + TILE_TEX]
        COM V_Release
        mov rcx, qword ptr [rdi + TILE_CTX]
        COM V_Release
        mov r12d, 1
2:      lea rcx, [rdi + TILE_GDI]
        call img_destroy
        add rdi, TILE_BYTES
        jmp .Lsf2_tile
.Lsf2_clear:
        mov rdi, rbx
        xor eax, eax
        mov ecx, SHOT_BYTES
        rep stosb
        test r12d, r12d
        jz .Lsf2_ret
        call gpu_trim
.Lsf2_ret:
        add rsp, 40
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* ---- reading the pixels ---------------------------------------------------------------- */

/* uint32_t shot_pixel(const Shot *sh, int x, int y): 0 outside monitors */
FUNC shot_pixel
        ENDPROLOG
        mov r9d, dword ptr [rcx + SHOT_NTILE]
        lea r10, [rcx + SHOT_TILE]
.Lsp2_loop:
        dec r9d
        js .Lsp2_none
        mov rax, qword ptr [r10 + TILE_BITS]
        test rax, rax
        jz .Lsp2_next
        mov ecx, edx
        sub ecx, dword ptr [r10 + TILE_RC + RC_L]
        cmp edx, dword ptr [r10 + TILE_RC + RC_L]
        jl .Lsp2_next
        cmp edx, dword ptr [r10 + TILE_RC + RC_R]
        jge .Lsp2_next
        mov r11d, r8d
        sub r11d, dword ptr [r10 + TILE_RC + RC_T]
        cmp r8d, dword ptr [r10 + TILE_RC + RC_T]
        jl .Lsp2_next
        cmp r8d, dword ptr [r10 + TILE_RC + RC_B]
        jge .Lsp2_next
        movsxd r9, dword ptr [r10 + TILE_PITCH]
        imul r11, r9                    /* (size_t)(y - top) * pitch */
        add rax, r11
        mov eax, dword ptr [rax + rcx*4]
        and eax, 0xFFFFFF
        ret
.Lsp2_next:
        add r10, TILE_BYTES
        jmp .Lsp2_loop
.Lsp2_none:
        xor eax, eax
        ret
ENDF

/* int shot_tile_at(const Shot *sh, int x, int y): the nearest tile */
FUNC shot_tile_at
        PUSHREG rbx
        PUSHREG rsi
        ENDPROLOG
        mov r9d, dword ptr [rcx + SHOT_NTILE]
        lea r10, [rcx + SHOT_TILE]
        xor eax, eax                    /* best */
        mov r11, 0x7FFFFFFFFFFFFFFF     /* its squared distance */
        xor esi, esi
.Lta_loop:
        cmp esi, r9d
        jge .Lta_ret
        xor ecx, ecx                    /* dx */
        mov ebx, dword ptr [r10 + TILE_RC + RC_L]
        cmp edx, ebx
        jge 1f
        sub ebx, edx                    /* left - x */
        mov ecx, ebx
        jmp 2f
1:      mov ebx, dword ptr [r10 + TILE_RC + RC_R]
        cmp edx, ebx
        jl 2f
        mov ecx, edx                    /* x - right + 1 */
        sub ecx, ebx
        inc ecx
2:      xor ebx, ebx                    /* dy */
        cmp r8d, dword ptr [r10 + TILE_RC + RC_T]
        jge 3f
        mov ebx, dword ptr [r10 + TILE_RC + RC_T]
        sub ebx, r8d
        jmp 4f
3:      cmp r8d, dword ptr [r10 + TILE_RC + RC_B]
        jl 4f
        mov ebx, r8d
        sub ebx, dword ptr [r10 + TILE_RC + RC_B]
        inc ebx
4:      movsxd rcx, ecx
        movsxd rbx, ebx
        imul rcx, rcx
        imul rbx, rbx
        add rcx, rbx
        cmp rcx, r11
        jge 5f
        mov r11, rcx
        mov eax, esi
5:      inc esi
        add r10, TILE_BYTES
        jmp .Lta_loop
.Lta_ret:
        pop rsi
        pop rbx
        ret
ENDF

/* void shot_copy(const Shot *sh, RECT r, uint32_t *dst, int stride): r in client
 * coordinates, rdx = &r. Rows of 128 bytes and more with rep movsb (the fastest
 * measured into a fresh DIB section), shorter ones with overlapping SSE2/integer
 * moves. Black first where no monitor is (gaps). */
FUNC shot_copy
        PUSHREG rbx
        PUSHREG rbp
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ENDPROLOG
        mov rbx, rcx                    /* sh */
        mov r10d, dword ptr [rdx + RC_L]
        mov r11d, dword ptr [rdx + RC_T]
        mov r12d, dword ptr [rdx + RC_R]
        mov r13d, dword ptr [rdx + RC_B]
        movsxd r9, r9d
        shl r9, 2                       /* dst stride in bytes */
        cmp byte ptr [rbx + SHOT_GAPS], 0
        je .Lsc_tiles
        mov r14d, r12d
        sub r14d, r10d                  /* w */
        jle .Lsc_tiles
        mov r15d, r13d
        sub r15d, r11d                  /* rows */
        jle .Lsc_tiles
        shl r14, 2
        mov rdx, r8
        xor eax, eax
.Lsc_zero:
        mov rdi, rdx
        mov rcx, r14
        rep stosb
        add rdx, r9
        dec r15d
        jnz .Lsc_zero
.Lsc_tiles:
        mov ebp, dword ptr [rbx + SHOT_NTILE]
        lea rbx, [rbx + SHOT_TILE]
.Lsc_tile:
        dec ebp
        js .Lsc_ret
        mov rsi, qword ptr [rbx + TILE_BITS]
        test rsi, rsi
        jz .Lsc_next
        /* is = r & t->rc */
        mov eax, dword ptr [rbx + TILE_RC + RC_L]
        cmp eax, r10d
        cmovl eax, r10d                 /* is.left */
        mov ecx, dword ptr [rbx + TILE_RC + RC_R]
        cmp ecx, r12d
        cmovg ecx, r12d                 /* is.right */
        sub ecx, eax
        jle .Lsc_next
        mov edx, dword ptr [rbx + TILE_RC + RC_T]
        cmp edx, r11d
        cmovl edx, r11d                 /* is.top */
        mov r15d, dword ptr [rbx + TILE_RC + RC_B]
        cmp r15d, r13d
        cmovg r15d, r13d                /* is.bottom */
        sub r15d, edx                   /* rows */
        jle .Lsc_next
        mov r14d, ecx
        shl r14, 2                      /* bytes per row */
        /* src = bits + (is.top - t.top) * pitch + (is.left - t.left) * 4 */
        movsxd rdi, dword ptr [rbx + TILE_PITCH]
        mov ecx, edx
        sub ecx, dword ptr [rbx + TILE_RC + RC_T]
        imul rcx, rdi
        add rsi, rcx
        mov ecx, eax
        sub ecx, dword ptr [rbx + TILE_RC + RC_L]
        lea rsi, [rsi + rcx*4]
        /* dst + (is.top - r.top) * stride + (is.left - r.left) */
        sub edx, r11d
        imul rdx, r9
        sub eax, r10d
        lea rax, [r8 + rax*4]
        add rax, rdx
        mov rdx, rdi                    /* src pitch */
        mov rdi, rax
        cmp r14, 128
        jb .Lsc_small
        sub rdx, r14                    /* rep movsb leaves rsi, rdi at the row ends */
        mov rax, r9
        sub rax, r14
.Lsc_big:
        mov rcx, r14
        rep movsb
        add rsi, rdx
        add rdi, rax
        dec r15d
        jnz .Lsc_big
        jmp .Lsc_next
.Lsc_small:
        cmp r14, 16
        jb .Lsc_tiny
        lea rcx, [r14 - 16]
.Lsc_row16:
        xor eax, eax
1:      movdqu xmm0, xmmword ptr [rsi + rax]
        movdqu xmmword ptr [rdi + rax], xmm0
        add rax, 16
        cmp rax, rcx
        jb 1b
        movdqu xmm0, xmmword ptr [rsi + rcx]    /* the last 16 bytes (overlapping) */
        movdqu xmmword ptr [rdi + rcx], xmm0
        add rsi, rdx
        add rdi, r9
        dec r15d
        jnz .Lsc_row16
        jmp .Lsc_next
.Lsc_tiny:
        cmp r14, 8
        jb .Lsc_row4
.Lsc_row8:                              /* 8 or 12 bytes: first and last 8 */
        mov rax, qword ptr [rsi]
        mov rcx, qword ptr [rsi + r14 - 8]
        mov qword ptr [rdi], rax
        mov qword ptr [rdi + r14 - 8], rcx
        add rsi, rdx
        add rdi, r9
        dec r15d
        jnz .Lsc_row8
        jmp .Lsc_next
.Lsc_row4:
        mov eax, dword ptr [rsi]
        mov dword ptr [rdi], eax
        add rsi, rdx
        add rdi, r9
        dec r15d
        jnz .Lsc_row4
.Lsc_next:
        add rbx, TILE_BYTES
        jmp .Lsc_tile
.Lsc_ret:
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
