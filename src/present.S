/* present.S: the capture overlay's DirectComposition presentation (see present.h).
 * Visual tree under one root, bottom to top: 16 screenshot tiles
 * (one surface per monitor, copied GPU to GPU from the duplicated frame or uploaded
 * from mapped pixels), four dim rectangles stretched from one premultiplied black
 * pixel (alpha 112), the UI layer (a virtual surface the size of the virtual
 * screen, clipped to the selection while editing), then the parts that move by
 * their offsets alone, so dragging the selection uploads nothing: the frame (four
 * rectangles stretched from one accent pixel), the eight selection handles (one
 * shared surface), the top layer (a second virtual surface) and the panels (label,
 * magnifier, tool bar, property bar, tooltip), a surface each.
 *
 * DirectComposition is C++-only in the headers: its methods are called by vtable
 * slot (DC_, TG_, VI_, SU_, VS_ below, measured from the real interfaces). The
 * D3D11 slots (V_), constants (K_) and D3D11_BOX offsets (BOX_) are from the
 * Windows headers. */
#include "asm.inc"
#include "ov_layout.inc"

/* ---- constants and structures ------------------------------------------------------- */
#define K_FORMAT_BGRA 87                /* DXGI_FORMAT_B8G8R8A8_UNORM */
#define K_ALPHA_PREMULTIPLIED 1         /* DXGI_ALPHA_MODE_PREMULTIPLIED */
#define K_ALPHA_IGNORE 3                /* DXGI_ALPHA_MODE_IGNORE */
#define K_DIM_PIXEL 0x70000000          /* alpha 112: 56% of the screen shows through */
#define K_FRAME_PIXEL 0xFF1A8CFF        /* ACCENT, opaque */
#define BOX_LEFT 0                      /* D3D11_BOX */
#define BOX_TOP 4
#define BOX_FRONT 8
#define BOX_RIGHT 12
#define BOX_BOTTOM 16
#define BOX_BACK 20
#define BOX_BYTES 24
#define PART_TOP 0                      /* present.h's PR_*: the parts above the UI layer */
#define PART_LABEL 1                    /* PART_LABEL..PART_TIP: the panels, with a visual each */
#define PART_TIP 5
#define PART_HANDLE 6                   /* the surface the eight handles share */
#define PART_N 7

/* ---- vtable slots ------------------------------------------------------------------- */
#define V_QueryInterface 0
#define V_Release 2
#define V_Context_UpdateSubresource 48
#define V_Context_CopySubresourceRegion 46
#define DC_COMMIT 3                     /* IDCompositionDevice */
#define DC_CREATE_TARGET 6
#define DC_CREATE_VISUAL 7
#define DC_CREATE_SURFACE 8
#define DC_CREATE_VSURFACE 9
#define TG_SET_ROOT 3                   /* IDCompositionTarget */
#define VI_SET_OFFSET_X 4               /* IDCompositionVisual (float overloads) */
#define VI_SET_OFFSET_Y 6
#define VI_SET_TRANSFORM 8              /* (const D2D_MATRIX_3X2_F &) */
#define VI_SET_INTERP 11
#define VI_SET_BORDER 12
#define VI_SET_CLIP 14                  /* (const D2D_RECT_F &) */
#define VI_SET_CONTENT 15
#define VI_ADD_VISUAL 16
#define SU_BEGIN_DRAW 3                 /* IDCompositionSurface */
#define SU_END_DRAW 4
#define VS_TRIM 9                       /* IDCompositionVirtualSurface */

/* ---- module state (g_pr) ------------------------------------------------------------- */
#define P_CREATE 0                      /* DCompositionCreateDevice */
#define P_D3D 8                         /* the ID3D11Device the composition device was made for */
#define P_CTX 16                        /* its ID3D11DeviceContext */
#define P_DC 24                         /* IDCompositionDevice */
#define P_TARGET 32
#define P_ROOT 40
#define P_HWND 48
#define P_TILEV 56                      /* visual[16] */
#define P_TILES 184                     /* surface[16] */
#define P_DIMV 312                      /* visual[4] */
#define P_DIMS 344                      /* the 1x1 dim surface */
#define P_UIV 352
#define P_UI 360                        /* virtual surface */
#define P_UITEX 368                     /* while drawing */
#define P_UIW 376
#define P_UIH 380
#define P_UIOFF 384                     /* POINT */
#define P_UIRECT 392                    /* RECT */
#define P_DIMON 408                     /* the dim visuals show their content */
#define P_FRAMEON 409                   /* the frame visuals show the accent pixel */
#define P_HANDON 410                    /* bit i: handle visual i shows the handle surface */
#define P_PARTON 411                    /* bit k: panel visual k shows its surface */
#define P_FRAMEV 416                    /* visual[4] */
#define P_FRAMES 448                    /* the 1x1 accent surface */
#define P_HANDV 456                     /* visual[8] */
#define P_TOPV 520
#define P_TOP 528                       /* virtual surface: the top layer */
#define P_PARTV 536                     /* visual[PART_N], the panels' */
#define P_PARTS 592                     /* surface[PART_N], the panels' and the handles' */
#define P_PARTW 648                     /* int[PART_N]: their sizes */
#define P_PARTH 676
#define P_CUR 704                       /* the surface being drawn */
#define P_BYTES 712

        .section .bss$present,"bw"
        .balign 16
g_pr:   .space P_BYTES
        .globl pr_gen                   /* int pr_gen: one more with every pr_begin */
        .balign 4
pr_gen: .space 4

        .section .rdata$present,"dr"
        .balign 4
dim_px: .long K_DIM_PIXEL
frame_px: .long K_FRAME_PIXEL
        GUIDDEF iid_dxgi_device, 0x54ec77fa, 0x1377, 0x44e6, 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c
        GUIDDEF iid_dcomp_device, 0xC37EA93A, 0xE7AA, 0x450D, 0xB1, 0x6F, 0x97, 0x46, 0xCB, 0x04, 0x07, 0xF3
        GUIDDEF iid_texture2d_p, 0x6f15aaf2, 0xd208, 0x4e89, 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c
        .balign 2
        /* L"dcomp.dll" */
w_dcomp:
        .short 0x0064, 0x0063, 0x006F, 0x006D, 0x0070, 0x002E, 0x0064, 0x006C, 0x006C, 0x0000
a_dcomp_create: .asciz "DCompositionCreateDevice"

/* ---- helpers ------------------------------------------------------------------------- */

/* Release *rcx if set, then clear it. */
SFUNC rel
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        mov rcx, qword ptr [rcx]
        test rcx, rcx
        jz 1f
        COM V_Release
        mov qword ptr [rbx], 0
1:      add rsp, 32
        pop rbx
        ret
ENDF

SFUNC release_all
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        lea rbx, [rip + g_pr]
        xor esi, esi
1:      lea rcx, [rbx + rsi*8 + P_TILES]
        call rel
        lea rcx, [rbx + rsi*8 + P_TILEV]
        call rel
        inc esi
        cmp esi, SHOT_MAX_TILES
        jb 1b
        xor esi, esi
2:      lea rcx, [rbx + rsi*8 + P_DIMV]
        call rel
        inc esi
        cmp esi, 4
        jb 2b
        lea rcx, [rbx + P_DIMS]
        call rel
        /* the frame visuals and pixel, the handle visuals, the top layer's visual and
         * surface, the panel visuals, the part surfaces: one run of pointers */
        mov esi, P_FRAMEV
3:      lea rcx, [rbx + rsi]
        call rel
        add esi, 8
        cmp esi, P_PARTW
        jb 3b
        lea rcx, [rbx + P_UI]
        call rel
        lea rcx, [rbx + P_UIV]
        call rel
        lea rcx, [rbx + P_ROOT]
        call rel
        lea rcx, [rbx + P_TARGET]
        call rel
        lea rcx, [rbx + P_DC]
        call rel
        xor eax, eax
        mov qword ptr [rbx + P_CTX], rax
        mov qword ptr [rbx + P_D3D], rax
        mov qword ptr [rbx + P_UIW], rax        /* uiw, uih */
        mov word ptr [rbx + P_FRAMEON], ax      /* frameon, handon */
        mov byte ptr [rbx + P_PARTON], al
        xorps xmm0, xmm0                        /* partw[], parth[] */
        movups xmmword ptr [rbx + P_PARTW], xmm0
        movups xmmword ptr [rbx + P_PARTW + 16], xmm0
        movups xmmword ptr [rbx + P_PARTW + 32], xmm0
        mov qword ptr [rbx + P_PARTW + 48], rax
        mov qword ptr [rbx + P_CUR], rax
        add rsp, 40
        pop rsi
        pop rbx
        ret
ENDF

/* A new visual on top of the root's children, or NULL. */
SFUNC new_visual
        ALLOC 40
        ENDPROLOG
        mov qword ptr [rsp + 32], 0
        mov rcx, qword ptr [rip + g_pr + P_DC]
        lea rdx, [rsp + 32]
        COM DC_CREATE_VISUAL
        test eax, eax
        js 1f
        mov rcx, qword ptr [rip + g_pr + P_ROOT]
        mov rdx, qword ptr [rsp + 32]
        xor r8d, r8d                    /* FALSE, NULL: on top */
        xor r9d, r9d
        COM VI_ADD_VISUAL
        mov rax, qword ptr [rsp + 32]
        add rsp, 40
        ret
1:      xor eax, eax
        add rsp, 40
        ret
ENDF

/* A new visual for content stretched by its transform (exact edges), or NULL. */
SFUNC stretched_visual
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        call new_visual
        mov rbx, rax
        test rax, rax
        jz 1f
        mov rcx, rax
        xor edx, edx                    /* nearest neighbor */
        COM VI_SET_INTERP
        mov rcx, rbx
        mov edx, 1                      /* hard */
        COM VI_SET_BORDER
1:      mov rax, rbx
        add rsp, 32
        pop rbx
        ret
ENDF

/* A BGRA surface ecx x edx with alpha mode r8d, or NULL. */
SFUNC new_surface
        ALLOC 56
        ENDPROLOG
        mov qword ptr [rsp + 48], 0
        mov dword ptr [rsp + 32], r8d
        lea rax, [rsp + 48]
        mov qword ptr [rsp + 40], rax
        mov r8d, edx
        mov edx, ecx
        mov r9d, K_FORMAT_BGRA
        mov rcx, qword ptr [rip + g_pr + P_DC]
        COM DC_CREATE_SURFACE
        test eax, eax
        js 1f
        mov rax, qword ptr [rsp + 48]
        add rsp, 56
        ret
1:      xor eax, eax
        add rsp, 56
        ret
ENDF

/* eax = CreateVirtualSurface(edx x r8d, premultiplied) into [rcx] */
SFUNC new_vsurface
        ALLOC 56
        ENDPROLOG
        mov qword ptr [rsp + 40], rcx
        mov qword ptr [rsp + 32], K_ALPHA_PREMULTIPLIED
        mov r9d, K_FORMAT_BGRA
        mov rcx, qword ptr [rip + g_pr + P_DC]
        COM DC_CREATE_VSURFACE
        add rsp, 56
        ret
ENDF

/* A 1x1 premultiplied surface holding the pixel at rcx, or NULL. */
#define PX_T 64
#define PX_OFF 72
#define PX_BOX 80
SFUNC pixel_surface
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 104
        ENDPROLOG
        mov rsi, rcx
        mov ecx, 1
        mov edx, 1
        mov r8d, K_ALPHA_PREMULTIPLIED
        call new_surface
        mov rbx, rax
        test rax, rax
        jz 9f
        mov qword ptr [rsp + PX_T], 0
        mov rcx, rax
        xor edx, edx
        lea r8, [rip + iid_texture2d_p]
        lea r9, [rsp + PX_T]
        lea rax, [rsp + PX_OFF]
        mov qword ptr [rsp + 32], rax
        COM SU_BEGIN_DRAW
        test eax, eax
        js 9f
        mov eax, dword ptr [rsp + PX_OFF + PT_X]
        mov dword ptr [rsp + PX_BOX + BOX_LEFT], eax
        inc eax
        mov dword ptr [rsp + PX_BOX + BOX_RIGHT], eax
        mov eax, dword ptr [rsp + PX_OFF + PT_Y]
        mov dword ptr [rsp + PX_BOX + BOX_TOP], eax
        inc eax
        mov dword ptr [rsp + PX_BOX + BOX_BOTTOM], eax
        mov dword ptr [rsp + PX_BOX + BOX_FRONT], 0
        mov dword ptr [rsp + PX_BOX + BOX_BACK], 1
        mov rcx, qword ptr [rip + g_pr + P_CTX]
        mov rdx, qword ptr [rsp + PX_T]
        xor r8d, r8d
        lea r9, [rsp + PX_BOX]
        mov qword ptr [rsp + 32], rsi
        mov qword ptr [rsp + 40], 4
        mov qword ptr [rsp + 48], 0
        COM V_Context_UpdateSubresource
        mov rcx, qword ptr [rsp + PX_T]
        COM V_Release
        mov rcx, rbx
        COM SU_END_DRAW
9:      mov rax, rbx
        add rsp, 104
        pop rsi
        pop rbx
        ret
ENDF

/* Visual rcx (may be NULL) shows its 1x1 content stretched over x (edx), y (r8d),
 * w (r9d) x h (r10d): its transform. Empty sizes give an empty rectangle. */
SFUNC stretch
        ALLOC 56
        ENDPROLOG
        test rcx, rcx
        jz 2f
        test r9d, r9d
        jle 1f
        test r10d, r10d
        jg 3f
1:      xor r9d, r9d
        xor r10d, r10d
3:      cvtsi2ss xmm0, r9d              /* D2D_MATRIX_3X2_F {w, 0, 0, h, x, y} */
        movss dword ptr [rsp + 32], xmm0
        mov qword ptr [rsp + 36], 0
        cvtsi2ss xmm0, r10d
        movss dword ptr [rsp + 44], xmm0
        cvtsi2ss xmm0, edx
        movss dword ptr [rsp + 48], xmm0
        cvtsi2ss xmm0, r8d
        movss dword ptr [rsp + 52], xmm0
        lea rdx, [rsp + 32]
        COM VI_SET_TRANSFORM
2:      add rsp, 56
        ret
ENDF

/* ---- setup ----------------------------------------------------------------------------- */

/* bool pr_setup(HWND hwnd): (re)build for the current GPU device; false: none, use GDI */
#define PS_DEV 64
#define PS_CTX 72
#define PS_XD 80
#define PS_FRAME 88
FUNC pr_setup
        PUSHREG rbx
        PUSHREG rsi
        ALLOC PS_FRAME
        ENDPROLOG
        mov rbx, rcx                    /* hwnd */
        lea rcx, [rsp + PS_DEV]
        lea rdx, [rsp + PS_CTX]
        call shot_gpu
        test al, al
        jz .Lps_fail
        cmp qword ptr [rip + g_pr + P_DC], 0
        je .Lps_build
        mov rax, qword ptr [rsp + PS_DEV]
        cmp rax, qword ptr [rip + g_pr + P_D3D]
        jne .Lps_build
        cmp rbx, qword ptr [rip + g_pr + P_HWND]
        jne .Lps_build
        mov eax, 1
        jmp .Lps_ret
.Lps_build:
        call release_all
        cmp qword ptr [rip + g_pr + P_CREATE], 0
        jne .Lps_have_create
        lea rcx, [rip + w_dcomp]
        API LoadLibraryW
        test rax, rax
        jz .Lps_false
        mov rcx, rax
        lea rdx, [rip + a_dcomp_create]
        API GetProcAddress
        mov qword ptr [rip + g_pr + P_CREATE], rax
        test rax, rax
        jz .Lps_false
.Lps_have_create:
        mov qword ptr [rsp + PS_XD], 0
        mov rcx, qword ptr [rsp + PS_DEV]
        lea rdx, [rip + iid_dxgi_device]
        lea r8, [rsp + PS_XD]
        COM V_QueryInterface
        test eax, eax
        js .Lps_false
        mov rcx, qword ptr [rsp + PS_XD]
        lea rdx, [rip + iid_dcomp_device]
        lea r8, [rip + g_pr + P_DC]
        call qword ptr [rip + g_pr + P_CREATE]
        mov esi, eax
        mov rcx, qword ptr [rsp + PS_XD]
        COM V_Release
        test esi, esi
        js .Lps_fail
        mov rcx, qword ptr [rip + g_pr + P_DC]
        mov rdx, rbx
        mov r8d, 1                      /* topmost */
        lea r9, [rip + g_pr + P_TARGET]
        COM DC_CREATE_TARGET
        test eax, eax
        js .Lps_fail
        mov rcx, qword ptr [rip + g_pr + P_DC]
        lea rdx, [rip + g_pr + P_ROOT]
        COM DC_CREATE_VISUAL
        test eax, eax
        js .Lps_fail
        mov rcx, qword ptr [rip + g_pr + P_TARGET]
        mov rdx, qword ptr [rip + g_pr + P_ROOT]
        COM TG_SET_ROOT
        test eax, eax
        js .Lps_fail
        mov rax, qword ptr [rsp + PS_DEV]
        mov qword ptr [rip + g_pr + P_D3D], rax
        mov rax, qword ptr [rsp + PS_CTX]
        mov qword ptr [rip + g_pr + P_CTX], rax
        mov qword ptr [rip + g_pr + P_HWND], rbx
        lea rbx, [rip + g_pr]
        xor esi, esi
1:      call new_visual
        mov qword ptr [rbx + rsi*8 + P_TILEV], rax
        inc esi
        cmp esi, SHOT_MAX_TILES
        jb 1b
        /* dimming: one translucent black pixel, stretched over four rectangles */
        lea rcx, [rip + dim_px]
        call pixel_surface
        mov qword ptr [rbx + P_DIMS], rax
        xor esi, esi
2:      call stretched_visual
        mov qword ptr [rbx + rsi*8 + P_DIMV], rax
        inc esi
        cmp esi, 4
        jb 2b
        call new_visual
        mov qword ptr [rbx + P_UIV], rax
        /* the frame: one opaque accent pixel, stretched over four rectangles */
        lea rcx, [rip + frame_px]
        call pixel_surface
        mov qword ptr [rbx + P_FRAMES], rax
        xor esi, esi
3:      call stretched_visual
        mov qword ptr [rbx + rsi*8 + P_FRAMEV], rax
        inc esi
        cmp esi, 4
        jb 3b
        xor esi, esi
4:      call new_visual
        mov qword ptr [rbx + rsi*8 + P_HANDV], rax
        inc esi
        cmp esi, 8
        jb 4b
        call new_visual
        mov qword ptr [rbx + P_TOPV], rax
        mov esi, PART_LABEL
5:      call new_visual
        mov qword ptr [rbx + rsi*8 + P_PARTV], rax
        inc esi
        cmp esi, PART_TIP
        jbe 5b
        mov rcx, qword ptr [rbx + P_DC]
        COM DC_COMMIT
        mov eax, 1
        jmp .Lps_ret
.Lps_fail:
        call release_all
.Lps_false:
        xor eax, eax
.Lps_ret:
        add rsp, PS_FRAME
        pop rsi
        pop rbx
        ret
ENDF

/* bool pr_begin(int vw, int vh): the UI and top layers for this capture */
FUNC pr_begin
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        cmp qword ptr [rip + g_pr + P_DC], 0
        je .Lpb_false
        mov ebx, ecx
        mov esi, edx
        cmp qword ptr [rip + g_pr + P_UI], 0
        je .Lpb_create
        cmp dword ptr [rip + g_pr + P_UIW], ebx
        jne 1f
        cmp dword ptr [rip + g_pr + P_UIH], esi
        je .Lpb_top
1:      lea rcx, [rip + g_pr + P_UI]
        call rel
        lea rcx, [rip + g_pr + P_TOP]
        call rel
.Lpb_create:
        lea rcx, [rip + g_pr + P_UI]
        mov edx, ebx
        mov r8d, esi
        call new_vsurface
        test eax, eax
        js .Lpb_false
        mov dword ptr [rip + g_pr + P_UIW], ebx
        mov dword ptr [rip + g_pr + P_UIH], esi
.Lpb_top:
        cmp qword ptr [rip + g_pr + P_TOP], 0
        jne .Lpb_content
        lea rcx, [rip + g_pr + P_TOP]
        mov edx, ebx
        mov r8d, esi
        call new_vsurface
        test eax, eax
        js .Lpb_false
.Lpb_content:
        mov rcx, qword ptr [rip + g_pr + P_UIV]
        test rcx, rcx                   /* no UI layer (setup failed half way) */
        jz 2f
        mov rdx, qword ptr [rip + g_pr + P_UI]
        COM VI_SET_CONTENT
2:      mov rcx, qword ptr [rip + g_pr + P_TOPV]
        test rcx, rcx
        jz 3f
        mov rdx, qword ptr [rip + g_pr + P_TOP]
        COM VI_SET_CONTENT
3:      inc dword ptr [rip + pr_gen]
        mov eax, 1
        jmp .Lpb_ret
.Lpb_false:
        xor eax, eax
.Lpb_ret:
        add rsp, 40
        pop rsi
        pop rbx
        ret
ENDF

/* void pr_end(void): drop this capture's surfaces, hide every part */
FUNC pr_end
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        lea rbx, [rip + g_pr]
        cmp qword ptr [rbx + P_DC], 0
        je .Lpe_ret
        xor esi, esi
1:      mov rcx, qword ptr [rbx + rsi*8 + P_TILEV]
        test rcx, rcx
        jz 2f
        xor edx, edx
        COM VI_SET_CONTENT
2:      lea rcx, [rbx + rsi*8 + P_TILES]
        call rel
        inc esi
        cmp esi, SHOT_MAX_TILES
        jb 1b
        xor esi, esi                    /* the window must be fully transparent when it next appears */
3:      mov rcx, qword ptr [rbx + rsi*8 + P_DIMV]
        test rcx, rcx
        jz 4f
        xor edx, edx
        COM VI_SET_CONTENT
4:      inc esi
        cmp esi, 4
        jb 3b
        mov byte ptr [rbx + P_DIMON], 0
        cmp byte ptr [rbx + P_FRAMEON], 0
        je 7f
        xor esi, esi
5:      mov rcx, qword ptr [rbx + rsi*8 + P_FRAMEV]
        test rcx, rcx
        jz 6f
        xor edx, edx
        COM VI_SET_CONTENT
6:      inc esi
        cmp esi, 4
        jb 5b
        mov byte ptr [rbx + P_FRAMEON], 0
7:      xor esi, esi
8:      movzx eax, byte ptr [rbx + P_HANDON]
        bt eax, esi
        jnc 9f
        mov rcx, qword ptr [rbx + rsi*8 + P_HANDV]
        xor edx, edx
        COM VI_SET_CONTENT
9:      inc esi
        cmp esi, 8
        jb 8b
        mov byte ptr [rbx + P_HANDON], 0
        xor esi, esi
10:     movzx eax, byte ptr [rbx + P_PARTON]
        bt eax, esi
        jnc 11f
        mov rcx, qword ptr [rbx + rsi*8 + P_PARTV]
        xor edx, edx
        COM VI_SET_CONTENT
11:     inc esi
        cmp esi, PART_N
        jb 10b
        mov byte ptr [rbx + P_PARTON], 0
        mov rcx, qword ptr [rbx + P_UI]
        test rcx, rcx                   /* keep the surfaces, drop their pixels */
        jz 12f
        xor edx, edx
        xor r8d, r8d
        COM VS_TRIM
12:     mov rcx, qword ptr [rbx + P_TOP]
        test rcx, rcx
        jz 13f
        xor edx, edx
        xor r8d, r8d
        COM VS_TRIM
13:     mov rcx, qword ptr [rbx + P_DC]
        COM DC_COMMIT
.Lpe_ret:
        add rsp, 40
        pop rsi
        pop rbx
        ret
ENDF

/* ---- screenshot tiles ------------------------------------------------------------------- */

/* bool tile_surface(int i, const RECT *rc): a fresh surface for tile i, placed at rc */
SFUNC tile_surface
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 32
        ENDPROLOG
        cmp ecx, SHOT_MAX_TILES
        jae .Lts_false
        movsxd rbx, ecx
        mov rsi, rdx
        lea rdi, [rip + g_pr]
        cmp qword ptr [rdi + rbx*8 + P_TILEV], 0
        je .Lts_false
        lea rcx, [rdi + rbx*8 + P_TILES]
        call rel
        mov ecx, dword ptr [rsi + RC_R]
        sub ecx, dword ptr [rsi + RC_L]
        mov edx, dword ptr [rsi + RC_B]
        sub edx, dword ptr [rsi + RC_T]
        mov r8d, K_ALPHA_IGNORE
        call new_surface
        mov qword ptr [rdi + rbx*8 + P_TILES], rax
        test rax, rax
        jz .Lts_false
        mov rcx, qword ptr [rdi + rbx*8 + P_TILEV]
        cvtsi2ss xmm1, dword ptr [rsi + RC_L]
        COM VI_SET_OFFSET_X
        mov rcx, qword ptr [rdi + rbx*8 + P_TILEV]
        cvtsi2ss xmm1, dword ptr [rsi + RC_T]
        COM VI_SET_OFFSET_Y
        mov rcx, qword ptr [rdi + rbx*8 + P_TILEV]
        mov rdx, qword ptr [rdi + rbx*8 + P_TILES]
        COM VI_SET_CONTENT
        mov eax, 1
        jmp .Lts_ret
.Lts_false:
        xor eax, eax
.Lts_ret:
        add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* bool pr_tile_gpu(int i, RECT rc, void *dev, void *tex): rdx = &rc. false if the
 * frame lives on another GPU. */
#define PG_T 72
#define PG_OFF 80
FUNC pr_tile_gpu
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 88
        ENDPROLOG
        cmp qword ptr [rip + g_pr + P_DC], 0
        je .Lpg_false
        cmp r8, qword ptr [rip + g_pr + P_D3D]
        jne .Lpg_false
        movsxd rbx, ecx
        mov rsi, r9                     /* tex */
        call tile_surface
        test al, al
        jz .Lpg_false
        lea rax, [rip + g_pr]
        mov rcx, qword ptr [rax + rbx*8 + P_TILES]
        mov qword ptr [rsp + PG_T], 0
        xor edx, edx
        lea r8, [rip + iid_texture2d_p]
        lea r9, [rsp + PG_T]
        lea rax, [rsp + PG_OFF]
        mov qword ptr [rsp + 32], rax
        COM SU_BEGIN_DRAW
        test eax, eax
        js .Lpg_false
        mov rcx, qword ptr [rip + g_pr + P_CTX]
        mov rdx, qword ptr [rsp + PG_T]
        xor r8d, r8d
        mov r9d, dword ptr [rsp + PG_OFF + PT_X]
        mov eax, dword ptr [rsp + PG_OFF + PT_Y]
        mov qword ptr [rsp + 32], rax
        xor eax, eax
        mov qword ptr [rsp + 40], rax
        mov qword ptr [rsp + 48], rsi
        mov qword ptr [rsp + 56], rax
        mov qword ptr [rsp + 64], rax   /* whole source */
        COM V_Context_CopySubresourceRegion
        mov rcx, qword ptr [rsp + PG_T]
        COM V_Release
        lea rax, [rip + g_pr]
        mov rcx, qword ptr [rax + rbx*8 + P_TILES]
        COM SU_END_DRAW
        mov eax, 1
        jmp .Lpg_ret
.Lpg_false:
        xor eax, eax
.Lpg_ret:
        add rsp, 88
        pop rsi
        pop rbx
        ret
ENDF

/* bool pr_tile_cpu(int i, const Tile *t): upload its mapped pixels */
#define PC_T 64
#define PC_OFF 72
#define PC_BOX 80
FUNC pr_tile_cpu
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 104
        ENDPROLOG
        cmp qword ptr [rip + g_pr + P_DC], 0
        je .Lpc_false
        cmp qword ptr [rdx + TILE_BITS], 0
        je .Lpc_false
        movsxd rbx, ecx
        mov rsi, rdx
        lea rdx, [rsi + TILE_RC]
        call tile_surface
        test al, al
        jz .Lpc_false
        lea rax, [rip + g_pr]
        mov rcx, qword ptr [rax + rbx*8 + P_TILES]
        mov qword ptr [rsp + PC_T], 0
        xor edx, edx
        lea r8, [rip + iid_texture2d_p]
        lea r9, [rsp + PC_T]
        lea rax, [rsp + PC_OFF]
        mov qword ptr [rsp + 32], rax
        COM SU_BEGIN_DRAW
        test eax, eax
        js .Lpc_false
        mov eax, dword ptr [rsp + PC_OFF + PT_X]
        mov dword ptr [rsp + PC_BOX + BOX_LEFT], eax
        add eax, dword ptr [rsi + TILE_RC + RC_R]
        sub eax, dword ptr [rsi + TILE_RC + RC_L]
        mov dword ptr [rsp + PC_BOX + BOX_RIGHT], eax
        mov eax, dword ptr [rsp + PC_OFF + PT_Y]
        mov dword ptr [rsp + PC_BOX + BOX_TOP], eax
        add eax, dword ptr [rsi + TILE_RC + RC_B]
        sub eax, dword ptr [rsi + TILE_RC + RC_T]
        mov dword ptr [rsp + PC_BOX + BOX_BOTTOM], eax
        mov dword ptr [rsp + PC_BOX + BOX_FRONT], 0
        mov dword ptr [rsp + PC_BOX + BOX_BACK], 1
        mov rcx, qword ptr [rip + g_pr + P_CTX]
        mov rdx, qword ptr [rsp + PC_T]
        xor r8d, r8d
        lea r9, [rsp + PC_BOX]
        mov rax, qword ptr [rsi + TILE_BITS]
        mov qword ptr [rsp + 32], rax
        mov eax, dword ptr [rsi + TILE_PITCH]
        mov qword ptr [rsp + 40], rax
        mov qword ptr [rsp + 48], 0
        COM V_Context_UpdateSubresource
        mov rcx, qword ptr [rsp + PC_T]
        COM V_Release
        lea rax, [rip + g_pr]
        mov rcx, qword ptr [rax + rbx*8 + P_TILES]
        COM SU_END_DRAW
        mov eax, 1
        jmp .Lpc_ret
.Lpc_false:
        xor eax, eax
.Lpc_ret:
        add rsp, 104
        pop rsi
        pop rbx
        ret
ENDF

/* ---- dimming --------------------------------------------------------------------------- */

/* void pr_dim(RECT bright): rcx = &bright, the undimmed area */
FUNC pr_dim
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        ALLOC 40
        ENDPROLOG
        lea rax, [rip + g_pr]
        cmp qword ptr [rax + P_DC], 0
        je .Lpd_ret
        mov esi, dword ptr [rcx + RC_L]
        mov edi, dword ptr [rcx + RC_T]
        mov r12d, dword ptr [rcx + RC_R]
        mov r13d, dword ptr [rcx + RC_B]
        cmp byte ptr [rax + P_DIMON], 0
        jne .Lpd_rects
        mov byte ptr [rax + P_DIMON], 1
        xor ebx, ebx
1:      lea rax, [rip + g_pr]
        mov rcx, qword ptr [rax + rbx*8 + P_DIMV]
        test rcx, rcx
        jz 2f
        mov rdx, qword ptr [rax + P_DIMS]
        COM VI_SET_CONTENT
2:      inc ebx
        cmp ebx, 4
        jb 1b
.Lpd_rects:
        lea rax, [rip + g_pr]
        mov ebx, dword ptr [rax + P_UIW]
        mov r14d, dword ptr [rax + P_UIH]
        cmp r12d, esi
        jle .Lpd_none
        cmp r13d, edi
        jle .Lpd_none
        mov rcx, qword ptr [rip + g_pr + P_DIMV]        /* above */
        xor edx, edx
        xor r8d, r8d
        mov r9d, ebx
        mov r10d, edi
        call stretch
        mov rcx, qword ptr [rip + g_pr + P_DIMV + 8]    /* below */
        xor edx, edx
        mov r8d, r13d
        mov r9d, ebx
        mov r10d, r14d
        sub r10d, r13d
        call stretch
        mov rcx, qword ptr [rip + g_pr + P_DIMV + 16]   /* left */
        xor edx, edx
        mov r8d, edi
        mov r9d, esi
        mov r10d, r13d
        sub r10d, edi
        call stretch
        mov rcx, qword ptr [rip + g_pr + P_DIMV + 24]   /* right */
        mov edx, r12d
        mov r8d, edi
        mov r9d, ebx
        sub r9d, r12d
        mov r10d, r13d
        sub r10d, edi
        call stretch
        jmp .Lpd_ret
.Lpd_none:                              /* nothing bright: one rectangle */
        mov rcx, qword ptr [rip + g_pr + P_DIMV]
        xor edx, edx
        xor r8d, r8d
        mov r9d, ebx
        mov r10d, r14d
        call stretch
        mov esi, 1
3:      lea rax, [rip + g_pr]
        mov rcx, qword ptr [rax + rsi*8 + P_DIMV]
        xor edx, edx
        xor r8d, r8d
        xor r9d, r9d
        xor r10d, r10d
        call stretch
        inc esi
        cmp esi, 4
        jb 3b
.Lpd_ret:
        add rsp, 40
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* ---- the parts above the UI layer ---------------------------------------------------------- */

/* void pr_frame(const RECT *r): rcx = the frame's four rectangles */
FUNC pr_frame
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 32
        ENDPROLOG
        lea rbx, [rip + g_pr]
        cmp qword ptr [rbx + P_DC], 0
        je 9f
        mov rdi, rcx
        cmp byte ptr [rbx + P_FRAMEON], 0
        jne 3f
        mov byte ptr [rbx + P_FRAMEON], 1
        xor esi, esi
1:      mov rcx, qword ptr [rbx + rsi*8 + P_FRAMEV]
        test rcx, rcx
        jz 2f
        mov rdx, qword ptr [rbx + P_FRAMES]
        COM VI_SET_CONTENT
2:      inc esi
        cmp esi, 4
        jb 1b
3:      xor esi, esi
4:      mov rcx, qword ptr [rbx + rsi*8 + P_FRAMEV]
        mov edx, dword ptr [rdi + RC_L]
        mov r8d, dword ptr [rdi + RC_T]
        mov r9d, dword ptr [rdi + RC_R]
        sub r9d, edx
        mov r10d, dword ptr [rdi + RC_B]
        sub r10d, r8d
        call stretch
        add rdi, 16
        inc esi
        cmp esi, 4
        jb 4b
9:      add rsp, 32
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void pr_handles(const POINT *p, int n): handle i at p[i] for i < n, the rest hidden */
FUNC pr_handles
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        ALLOC 32
        ENDPROLOG
        lea rbx, [rip + g_pr]
        cmp qword ptr [rbx + P_DC], 0
        je 9f
        mov rdi, rcx                    /* p */
        mov r12d, edx                   /* n */
        xor esi, esi                    /* i */
1:      mov r13, qword ptr [rbx + rsi*8 + P_HANDV]
        test r13, r13
        jz 8f
        cmp esi, r12d
        jge 5f
        cmp qword ptr [rbx + P_PARTS + PART_HANDLE * 8], 0
        je 5f
        mov rcx, r13
        cvtsi2ss xmm1, dword ptr [rdi + rsi*8 + PT_X]
        COM VI_SET_OFFSET_X
        mov rcx, r13
        cvtsi2ss xmm1, dword ptr [rdi + rsi*8 + PT_Y]
        COM VI_SET_OFFSET_Y
        movzx eax, byte ptr [rbx + P_HANDON]
        bt eax, esi
        jc 8f
        bts eax, esi
        mov byte ptr [rbx + P_HANDON], al
        mov rcx, r13
        mov rdx, qword ptr [rbx + P_PARTS + PART_HANDLE * 8]
        COM VI_SET_CONTENT
        jmp 8f
5:      movzx eax, byte ptr [rbx + P_HANDON]
        btr eax, esi
        jnc 8f
        mov byte ptr [rbx + P_HANDON], al
        mov rcx, r13
        xor edx, edx
        COM VI_SET_CONTENT
8:      inc esi
        cmp esi, 8
        jb 1b
9:      add rsp, 32
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void pr_clip(RECT r): rcx = &r, the part of the UI layer shown */
FUNC pr_clip
        ALLOC 56
        ENDPROLOG
        cmp qword ptr [rip + g_pr + P_DC], 0
        je 1f
        mov rax, rcx
        mov rcx, qword ptr [rip + g_pr + P_UIV]
        test rcx, rcx
        jz 1f
        cvtsi2ss xmm0, dword ptr [rax + RC_L]   /* D2D_RECT_F */
        movss dword ptr [rsp + 32], xmm0
        cvtsi2ss xmm0, dword ptr [rax + RC_T]
        movss dword ptr [rsp + 36], xmm0
        cvtsi2ss xmm0, dword ptr [rax + RC_R]
        movss dword ptr [rsp + 40], xmm0
        cvtsi2ss xmm0, dword ptr [rax + RC_B]
        movss dword ptr [rsp + 44], xmm0
        lea rdx, [rsp + 32]
        COM VI_SET_CLIP
1:      add rsp, 56
        ret
ENDF

/* bool pr_part_begin(int k, RECT r, RECT sub): ecx = k, rdx = &r, r8 = &sub. Then
 * pr_ui_rows and pr_ui_end as for the UI layer. */
#define PP_LOCAL 48                     /* RECT: sub in the surface */
FUNC pr_part_begin
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        ALLOC 64
        ENDPROLOG
        lea rbx, [rip + g_pr]
        xor eax, eax
        mov qword ptr [rbx + P_UITEX], rax
        mov qword ptr [rbx + P_CUR], rax
        cmp qword ptr [rbx + P_DC], 0
        je .Lpp_false
        cmp ecx, PART_N                 /* k < 0 or past the last: unsigned */
        jae .Lpp_false
        mov esi, ecx                    /* k */
        mov rdi, rdx                    /* &r */
        mov r12, r8                     /* &sub */
        mov eax, dword ptr [r12 + RC_R]
        cmp eax, dword ptr [r12 + RC_L]
        jle .Lpp_false
        mov eax, dword ptr [r12 + RC_B]
        cmp eax, dword ptr [r12 + RC_T]
        jle .Lpp_false
        movups xmm0, xmmword ptr [r12]
        movups xmmword ptr [rsp + PP_LOCAL], xmm0
        test esi, esi
        jnz .Lpp_panel
        mov r13, qword ptr [rbx + P_TOP]
        jmp .Lpp_draw
.Lpp_panel:
        mov eax, dword ptr [rdi + RC_R]
        sub eax, dword ptr [rdi + RC_L]
        jle .Lpp_false                  /* w */
        mov ecx, dword ptr [rdi + RC_B]
        sub ecx, dword ptr [rdi + RC_T]
        jle .Lpp_false                  /* h */
        cmp qword ptr [rbx + rsi*8 + P_PARTS], 0
        je .Lpp_new
        cmp dword ptr [rbx + rsi*4 + P_PARTW], eax
        jne 1f
        cmp dword ptr [rbx + rsi*4 + P_PARTH], ecx
        je .Lpp_local
1:      lea rcx, [rbx + rsi*8 + P_PARTS]
        call rel
        cmp esi, PART_HANDLE
        jne .Lpp_new
        xor r13d, r13d                  /* the handles show the old surface: hidden until pr_handles */
2:      movzx eax, byte ptr [rbx + P_HANDON]
        bt eax, r13d
        jnc 3f
        mov rcx, qword ptr [rbx + r13*8 + P_HANDV]
        xor edx, edx
        COM VI_SET_CONTENT
3:      inc r13d
        cmp r13d, 8
        jb 2b
        mov byte ptr [rbx + P_HANDON], 0
.Lpp_new:
        mov ecx, dword ptr [rdi + RC_R]
        sub ecx, dword ptr [rdi + RC_L]
        mov edx, dword ptr [rdi + RC_B]
        sub edx, dword ptr [rdi + RC_T]
        mov r8d, K_ALPHA_PREMULTIPLIED
        call new_surface
        mov qword ptr [rbx + rsi*8 + P_PARTS], rax
        test rax, rax
        jz .Lpp_false
        mov eax, dword ptr [rdi + RC_R]
        sub eax, dword ptr [rdi + RC_L]
        mov dword ptr [rbx + rsi*4 + P_PARTW], eax
        mov eax, dword ptr [rdi + RC_B]
        sub eax, dword ptr [rdi + RC_T]
        mov dword ptr [rbx + rsi*4 + P_PARTH], eax
.Lpp_local:
        mov r13, qword ptr [rbx + rsi*8 + P_PARTS]
        mov eax, dword ptr [rdi + RC_L]
        mov ecx, dword ptr [rdi + RC_T]
        sub dword ptr [rsp + PP_LOCAL + RC_L], eax
        sub dword ptr [rsp + PP_LOCAL + RC_T], ecx
        sub dword ptr [rsp + PP_LOCAL + RC_R], eax
        sub dword ptr [rsp + PP_LOCAL + RC_B], ecx
.Lpp_draw:
        test r13, r13
        jz .Lpp_false
        mov rcx, r13
        lea rdx, [rsp + PP_LOCAL]
        lea r8, [rip + iid_texture2d_p]
        lea r9, [rbx + P_UITEX]
        lea rax, [rbx + P_UIOFF]
        mov qword ptr [rsp + 32], rax
        COM SU_BEGIN_DRAW
        test eax, eax
        js .Lpp_failed
        mov qword ptr [rbx + P_CUR], r13
        movups xmm0, xmmword ptr [r12]
        movups xmmword ptr [rbx + P_UIRECT], xmm0
        mov eax, 1
        jmp .Lpp_ret
.Lpp_failed:
        mov qword ptr [rbx + P_UITEX], 0
.Lpp_false:
        xor eax, eax
.Lpp_ret:
        add rsp, 64
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void pr_part_at(int k, RECT r): ecx = k, rdx = &r; panel k there, or hidden */
FUNC pr_part_at
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 48                        /* [rsp + 32]: r.top */
        ENDPROLOG
        lea rbx, [rip + g_pr]
        cmp qword ptr [rbx + P_DC], 0
        je 9f
        lea eax, [rcx - PART_LABEL]
        cmp eax, PART_TIP - PART_LABEL
        ja 9f
        mov esi, ecx
        mov rdi, qword ptr [rbx + rsi*8 + P_PARTV]
        test rdi, rdi
        jz 9f
        mov eax, dword ptr [rdx + RC_R]
        cmp eax, dword ptr [rdx + RC_L]
        jle 5f
        mov eax, dword ptr [rdx + RC_B]
        cmp eax, dword ptr [rdx + RC_T]
        jle 5f
        cmp qword ptr [rbx + rsi*8 + P_PARTS], 0
        je 5f
        mov eax, dword ptr [rdx + RC_T]
        mov dword ptr [rsp + 32], eax
        mov rcx, rdi
        cvtsi2ss xmm1, dword ptr [rdx + RC_L]
        COM VI_SET_OFFSET_X
        mov rcx, rdi
        cvtsi2ss xmm1, dword ptr [rsp + 32]
        COM VI_SET_OFFSET_Y
        mov rcx, rdi                    /* the surface may be new */
        mov rdx, qword ptr [rbx + rsi*8 + P_PARTS]
        COM VI_SET_CONTENT
        movzx eax, byte ptr [rbx + P_PARTON]
        bts eax, esi
        mov byte ptr [rbx + P_PARTON], al
        jmp 9f
5:      movzx eax, byte ptr [rbx + P_PARTON]
        btr eax, esi
        jnc 9f
        mov byte ptr [rbx + P_PARTON], al
        mov rcx, rdi
        xor edx, edx
        COM VI_SET_CONTENT
9:      add rsp, 48
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* ---- UI layer ---------------------------------------------------------------------------- */

/* bool pr_ui_begin(RECT r): rcx = &r, the rectangle that will be fully covered */
FUNC pr_ui_begin
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        lea rbx, [rip + g_pr]
        mov rsi, rcx
        xor eax, eax
        mov qword ptr [rbx + P_UITEX], rax
        mov qword ptr [rbx + P_CUR], rax
        mov rax, qword ptr [rbx + P_UI]
        test rax, rax
        jz .Lpu_false
        mov edx, dword ptr [rcx + RC_R]
        cmp edx, dword ptr [rcx + RC_L]
        jle .Lpu_false
        mov edx, dword ptr [rcx + RC_B]
        cmp edx, dword ptr [rcx + RC_T]
        jle .Lpu_false
        mov rdx, rcx
        mov rcx, rax
        lea r8, [rip + iid_texture2d_p]
        lea r9, [rbx + P_UITEX]
        lea rax, [rbx + P_UIOFF]
        mov qword ptr [rsp + 32], rax
        COM SU_BEGIN_DRAW
        test eax, eax
        js .Lpu_failed
        mov rax, qword ptr [rbx + P_UI]
        mov qword ptr [rbx + P_CUR], rax
        movups xmm0, xmmword ptr [rsi]
        movups xmmword ptr [rbx + P_UIRECT], xmm0
        mov eax, 1
        jmp .Lpu_ret
.Lpu_failed:
        mov qword ptr [rbx + P_UITEX], 0
.Lpu_false:
        xor eax, eax
.Lpu_ret:
        add rsp, 40
        pop rsi
        pop rbx
        ret
ENDF

/* void pr_ui_rows(RECT part, const uint32_t *px, int stride): rcx = &part */
FUNC pr_ui_rows
        ALLOC 88
        ENDPROLOG
        lea r11, [rip + g_pr]
        mov rax, qword ptr [r11 + P_UITEX]
        test rax, rax
        jz 1f
        mov r9d, dword ptr [r11 + P_UIOFF + PT_X]
        sub r9d, dword ptr [r11 + P_UIRECT + RC_L]
        mov r10d, dword ptr [r11 + P_UIOFF + PT_Y]
        sub r10d, dword ptr [r11 + P_UIRECT + RC_T]
        mov r11d, dword ptr [rcx + RC_L]
        add r11d, r9d
        mov dword ptr [rsp + 56 + BOX_LEFT], r11d
        mov r11d, dword ptr [rcx + RC_T]
        add r11d, r10d
        mov dword ptr [rsp + 56 + BOX_TOP], r11d
        mov dword ptr [rsp + 56 + BOX_FRONT], 0
        mov r11d, dword ptr [rcx + RC_R]
        add r11d, r9d
        mov dword ptr [rsp + 56 + BOX_RIGHT], r11d
        mov r11d, dword ptr [rcx + RC_B]
        add r11d, r10d
        mov dword ptr [rsp + 56 + BOX_BOTTOM], r11d
        mov dword ptr [rsp + 56 + BOX_BACK], 1
        mov qword ptr [rsp + 32], rdx   /* px */
        shl r8d, 2
        mov qword ptr [rsp + 40], r8    /* row pitch in bytes */
        mov qword ptr [rsp + 48], 0
        mov rcx, qword ptr [rip + g_pr + P_CTX]
        mov rdx, rax
        xor r8d, r8d
        lea r9, [rsp + 56]
        COM V_Context_UpdateSubresource
1:      add rsp, 88
        ret
ENDF

/* void pr_ui_end(void): ends the UI layer's or a part's drawing */
FUNC pr_ui_end
        ALLOC 40
        ENDPROLOG
        mov rcx, qword ptr [rip + g_pr + P_UITEX]
        test rcx, rcx
        jz 1f
        COM V_Release
        mov qword ptr [rip + g_pr + P_UITEX], 0
        mov rcx, qword ptr [rip + g_pr + P_CUR]
        test rcx, rcx
        jz 1f
        mov qword ptr [rip + g_pr + P_CUR], 0
        COM SU_END_DRAW
1:      add rsp, 40
        ret
ENDF

/* void pr_commit(void) */
FUNC pr_commit
        ENDPROLOG
        mov rcx, qword ptr [rip + g_pr + P_DC]
        test rcx, rcx
        jz 1f
        mov rax, qword ptr [rcx]
        jmp qword ptr [rax + 8 * DC_COMMIT]
1:      ret
ENDF
