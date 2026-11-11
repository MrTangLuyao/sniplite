/* image.S: clipboard I/O, WIC encode/decode, text-to-image and the out-of-process
 * save dialog (see image.h), replacing image.c. ole32/WIC and comdlg32 are loaded
 * on first use only, never at startup.
 *
 * The pixel loops (24bpp rows for PNG/JPEG/BMP and CF_DIB, the clipboard's 32bpp
 * alpha handling, the white matte after decoding) use SSE2 or 64-bit integer
 * code and give exactly the bytes of the C version; tests/image_test.c compares
 * the two. Windows structure offsets, constants and COM vtable slots used below
 * are the #define lines of this file, checked by tests/image_check.c. */
#include "asm.inc"

/* ---- Windows constants --------------------------------------------------------- */
#define K_E_FAIL 0x80004005
#define K_CLSCTX_INPROC_SERVER 1
#define K_COINIT_FLAGS 6                /* COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE */
#define K_GENERIC_READ 0x80000000
#define K_GENERIC_WRITE 0x40000000
#define K_WICBitmapEncoderNoCache 2
#define K_WICDecodeMetadataCacheOnDemand 0
#define K_WICBitmapDitherTypeNone 0
#define K_WICBitmapPaletteTypeCustom 0
#define K_GMEM_MOVEABLE 2
#define K_CF_DIB 8
#define K_CF_UNICODETEXT 13
#define K_CF_HDROP 15
#define K_BI_RGB 0
#define K_BI_RLE8 1
#define K_BI_RLE4 2
#define K_BI_BITFIELDS 3
#define K_BI_ALPHABITFIELDS 6
#define K_DIB_RGB_COLORS 0
#define K_CP_ACP 0
#define K_MONITOR_DEFAULTTONEAREST 2
#define K_FW_NORMAL 400
#define K_DEFAULT_CHARSET 1
#define K_CLEARTYPE_QUALITY 5
#define K_TRANSPARENT 1
#define K_TEXT_FMT 0x2850               /* DT_WORDBREAK | DT_EXPANDTABS | DT_NOPREFIX | DT_EDITCONTROL */
#define K_DT_CALCRECT 0x400
#define K_TEXT_COLOR 0x1E1E1E           /* RGB(30, 30, 30) */
#define K_MAX_PATH 260
#define K_HANDLE_FLAG_INHERIT 1
#define K_STARTF_USESTDHANDLES 0x100
#define K_ASFW_ANY -1
#define K_INFINITE -1
#define K_QS_ALLINPUT 0x1CFF
#define K_WAIT_OBJECT_0 0
#define K_PM_REMOVE 1
#define K_WM_QUIT 0x12
#define K_CSIDL_MYPICTURES 0x27
#define K_OFN_FLAGS 0x88080E            /* EXPLORER OVERWRITEPROMPT PATHMUSTEXIST NOCHANGEDIR ENABLESIZING HIDEREADONLY */
#define K_STD_OUTPUT_HANDLE -11

/* ---- Windows structures --------------------------------------------------------- */
#define BIH_SIZE 0                      /* BITMAPINFOHEADER */
#define BIH_WIDTH 4
#define BIH_HEIGHT 8
#define BIH_PLANES 12
#define BIH_BITCOUNT 14
#define BIH_COMPRESSION 16
#define BIH_SIZEIMAGE 20
#define BIH_CLRUSED 32
#define BIH_BYTES 40
#define DF_PFILES 0                     /* DROPFILES */
#define DF_FWIDE 16
#define DF_BYTES 20
#define MI_RCWORK 20                    /* MONITORINFO */
#define MI_BYTES 40
#define ST_YEAR 0                       /* SYSTEMTIME */
#define ST_MONTH 2
#define ST_DAY 6
#define ST_HOUR 8
#define ST_MINUTE 10
#define ST_SECOND 12
#define ST_BYTES 16
#define SA_LENGTH 0                     /* SECURITY_ATTRIBUTES */
#define SA_DESCRIPTOR 8
#define SA_INHERIT 16
#define SA_BYTES 24
#define SI_CB 0                         /* STARTUPINFOW */
#define SI_FLAGS 60
#define SI_STDOUTPUT 88
#define SI_BYTES 104
#define PI_PROCESS 0                    /* PROCESS_INFORMATION */
#define PI_THREAD 8
#define PI_BYTES 24
#define MSG_MESSAGE 8                   /* MSG */
#define MSG_WPARAM 16
#define MSG_BYTES 48
#define OFN_STRUCTSIZE 0                /* OPENFILENAMEW */
#define OFN_FILTER 24
#define OFN_FILTERINDEX 44
#define OFN_FILE 48
#define OFN_MAXFILE 56
#define OFN_INITIALDIR 80
#define OFN_TITLE 88
#define OFN_FLAGS 96
#define OFN_DEFEXT 104
#define OFN_BYTES 152

/* ---- COM vtable slots ------------------------------------------------------------- */
#define V_Release 2
#define V_Factory_CreateDecoderFromFilename 3
#define V_Factory_CreateEncoder 8
#define V_Factory_CreateFormatConverter 10
#define V_Factory_CreateStream 14
#define V_Stream_InitializeFromFilename 15
#define V_Encoder_Initialize 3
#define V_Encoder_CreateNewFrame 10
#define V_Encoder_Commit 11
#define V_FrameEncode_Initialize 3
#define V_FrameEncode_SetSize 4
#define V_FrameEncode_SetPixelFormat 6
#define V_FrameEncode_WritePixels 10
#define V_FrameEncode_Commit 12
#define V_Decoder_GetFrame 13
#define V_Converter_GetSize 3
#define V_Converter_CopyPixels 7
#define V_Converter_Initialize 8

        .section .rdata,"dr"
        GUIDDEF g_clsid_wic, 0xcacaf262, 0x9370, 0x4615, 0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a
        GUIDDEF g_iid_wic, 0xec5ec8a9, 0xc395, 0x4314, 0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70
        GUIDDEF g_cf_bmp, 0x0af1d87e, 0xfcfe, 0x4188, 0xbd, 0xeb, 0xa7, 0x90, 0x64, 0x71, 0xcb, 0xe3
        GUIDDEF g_cf_png, 0x1b7cfaf4, 0x713f, 0x473c, 0xbb, 0xcd, 0x61, 0x37, 0x42, 0x5f, 0xae, 0xaf
        GUIDDEF g_cf_jpeg, 0x19e4a5aa, 0x5662, 0x4fc5, 0xa0, 0xc0, 0x17, 0x58, 0x02, 0x8e, 0x10, 0x57
        GUIDDEF g_pf_24bgr, 0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0c
        GUIDDEF g_pf_32bgr, 0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0e
        GUIDDEF g_pf_32bgra, 0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0f
        GUIDDEF g_pf_32pbgra, 0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x10

        .balign 16
k_alpha:        .long 0xFF000000, 0xFF000000, 0xFF000000, 0xFF000000
k_ff32:         .long 0xFF, 0xFF, 0xFF, 0xFF
k_ff16:         .short 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
k_div255:       .short 0x8081, 0x8081, 0x8081, 0x8081, 0x8081, 0x8081, 0x8081, 0x8081
k_14:           .long 0x41600000            /* 14.f */
k_10:           .long 0x41200000            /* 10.f */

a_CoInitializeEx:       .asciz "CoInitializeEx"
a_CoCreateInstance:     .asciz "CoCreateInstance"
a_GetSaveFileNameW:     .asciz "GetSaveFileNameW"
a_SHGetFolderPathW:     .asciz "SHGetFolderPathW"

        .balign 2
        /* L"ole32.dll" */
w_ole32:
        .short 0x006F, 0x006C, 0x0065, 0x0033, 0x0032, 0x002E, 0x0064, 0x006C, 0x006C, 0x0000
        /* L".jpg" */
w_jpg:
        .short 0x002E, 0x006A, 0x0070, 0x0067, 0x0000
        /* L".jpeg" */
w_jpeg:
        .short 0x002E, 0x006A, 0x0070, 0x0065, 0x0067, 0x0000
        /* L".bmp" */
w_bmp:
        .short 0x002E, 0x0062, 0x006D, 0x0070, 0x0000
        /* L"Microsoft YaHei UI" */
w_yahei:
        .short 0x004D, 0x0069, 0x0063, 0x0072, 0x006F, 0x0073, 0x006F, 0x0066, 0x0074, 0x0020, 0x0059, 0x0061
        .short 0x0048, 0x0065, 0x0069, 0x0020, 0x0055, 0x0049, 0x0000
        /* L"sniplite_%04d-%02d-%02d_%02d-%02d-%02d.png" */
w_namefmt:
        .short 0x0073, 0x006E, 0x0069, 0x0070, 0x006C, 0x0069, 0x0074, 0x0065, 0x005F, 0x0025, 0x0030, 0x0034
        .short 0x0064, 0x002D, 0x0025, 0x0030, 0x0032, 0x0064, 0x002D, 0x0025, 0x0030, 0x0032, 0x0064, 0x005F
        .short 0x0025, 0x0030, 0x0032, 0x0064, 0x002D, 0x0025, 0x0030, 0x0032, 0x0064, 0x002D, 0x0025, 0x0030
        .short 0x0032, 0x0064, 0x002E, 0x0070, 0x006E, 0x0067, 0x0000
        /* L" --save-dialog " */
w_arg:
        .short 0x0020, 0x002D, 0x002D, 0x0073, 0x0061, 0x0076, 0x0065, 0x002D, 0x0064, 0x0069, 0x0061, 0x006C
        .short 0x006F, 0x0067, 0x0020, 0x0000
        /* L" " */
w_space:
        .short 0x0020, 0x0000
        /* L"sniplite.png" */
w_defname:
        .short 0x0073, 0x006E, 0x0069, 0x0070, 0x006C, 0x0069, 0x0074, 0x0065, 0x002E, 0x0070, 0x006E, 0x0067
        .short 0x0000
        /* L"" */
w_empty:
        .short 0x0000
        /* L"comdlg32.dll" */
w_comdlg32:
        .short 0x0063, 0x006F, 0x006D, 0x0064, 0x006C, 0x0067, 0x0033, 0x0032, 0x002E, 0x0064, 0x006C, 0x006C
        .short 0x0000
        /* L"shell32.dll" */
w_shell32:
        .short 0x0073, 0x0068, 0x0065, 0x006C, 0x006C, 0x0033, 0x0032, 0x002E, 0x0064, 0x006C, 0x006C, 0x0000
        /* L"PNG 图片 (*.png)\0*.png\0JPEG 图片 (*.jpg)\0*.jpg;*.jpeg\0BMP 图片 (*.bmp)\0*.bmp\0" */
w_filter:
        .short 0x0050, 0x004E, 0x0047, 0x0020, 0x56FE, 0x7247, 0x0020, 0x0028, 0x002A, 0x002E, 0x0070, 0x006E
        .short 0x0067, 0x0029, 0x0000, 0x002A, 0x002E, 0x0070, 0x006E, 0x0067, 0x0000, 0x004A, 0x0050, 0x0045
        .short 0x0047, 0x0020, 0x56FE, 0x7247, 0x0020, 0x0028, 0x002A, 0x002E, 0x006A, 0x0070, 0x0067, 0x0029
        .short 0x0000, 0x002A, 0x002E, 0x006A, 0x0070, 0x0067, 0x003B, 0x002A, 0x002E, 0x006A, 0x0070, 0x0065
        .short 0x0067, 0x0000, 0x0042, 0x004D, 0x0050, 0x0020, 0x56FE, 0x7247, 0x0020, 0x0028, 0x002A, 0x002E
        .short 0x0062, 0x006D, 0x0070, 0x0029, 0x0000, 0x002A, 0x002E, 0x0062, 0x006D, 0x0070, 0x0000, 0x0000
        /* L"保存截图" */
w_title:
        .short 0x4FDD, 0x5B58, 0x622A, 0x56FE, 0x0000
        /* L"png" */
w_png:
        .short 0x0070, 0x006E, 0x0067, 0x0000

        .bss
        .balign 8
co_create:      .space 8                /* CoCreateInstance, once com_init succeeded */
com_state:      .space 4                /* 0 untried, 1 ok, -1 failed */
        .balign 2
g_last_dir:     .space 2 * K_MAX_PATH   /* folder of the last saved file */

/* ---- COM / WIC ------------------------------------------------------------------- */

/* bool com_init(void): loads ole32 and enters an STA, once. */
SFUNC com_init
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        mov eax, dword ptr [rip + com_state]
        test eax, eax
        jnz .Lci_done
        lea rcx, [rip + w_ole32]
        API LoadLibraryW
        test rax, rax
        jz .Lci_fail
        mov rbx, rax
        mov rcx, rax
        lea rdx, [rip + a_CoInitializeEx]
        API GetProcAddress
        mov rsi, rax
        mov rcx, rbx
        lea rdx, [rip + a_CoCreateInstance]
        API GetProcAddress
        mov qword ptr [rip + co_create], rax
        test rsi, rsi
        jz .Lci_fail
        test rax, rax
        jz .Lci_fail
        xor ecx, ecx
        mov edx, K_COINIT_FLAGS
        call rsi
        test eax, eax
        js .Lci_fail
        mov dword ptr [rip + com_state], 1
        jmp .Lci_done
.Lci_fail:
        mov dword ptr [rip + com_state], -1
.Lci_done:
        xor eax, eax
        cmp dword ptr [rip + com_state], 0
        setg al
        add rsp, 40
        pop rsi
        pop rbx
        ret
        ENDF

/* HRESULT com_create(const CLSID *cls, const IID *iid, void **out) */
FUNC com_create
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 48
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        mov rdi, r8
        mov qword ptr [r8], 0
        call com_init
        test eax, eax
        jz .Lcc_fail
        mov rcx, rbx
        xor edx, edx
        mov r8d, K_CLSCTX_INPROC_SERVER
        mov r9, rsi
        mov qword ptr [rsp + 32], rdi
        call qword ptr [rip + co_create]
        jmp .Lcc_ret
.Lcc_fail:
        mov eax, K_E_FAIL
.Lcc_ret:
        add rsp, 48
        pop rdi
        pop rsi
        pop rbx
        ret
        ENDF

/* IWICImagingFactory *wic(void): a new factory, or NULL */
SFUNC wic
        ALLOC 56
        ENDPROLOG
        mov qword ptr [rsp + 40], 0
        call com_init
        test eax, eax
        jz .Lwi_null
        lea rcx, [rip + g_clsid_wic]
        xor edx, edx
        mov r8d, K_CLSCTX_INPROC_SERVER
        lea r9, [rip + g_iid_wic]
        lea rax, [rsp + 40]
        mov qword ptr [rsp + 32], rax
        call qword ptr [rip + co_create]
        test eax, eax
        js .Lwi_null
        mov rax, qword ptr [rsp + 40]
        add rsp, 56
        ret
.Lwi_null:
        xor eax, eax
        add rsp, 56
        ret
        ENDF

/* const GUID *container_for(const WCHAR *path): the encoder for the extension */
SFUNC container_for
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        xor eax, eax                    /* last '.' */
        xor edx, edx                    /* last '\' */
.Lcf_scan:
        movzx r8d, word ptr [rcx]
        test r8d, r8d
        jz .Lcf_end
        cmp r8d, 0x2E
        cmove rax, rcx
        cmp r8d, 0x5C
        cmove rdx, rcx
        add rcx, 2
        jmp .Lcf_scan
.Lcf_end:
        test rax, rax
        jz .Lcf_png
        cmp rdx, rax                    /* a backslash after the dot: no extension */
        ja .Lcf_png
        mov rbx, rax
        mov rcx, rbx
        lea rdx, [rip + w_jpg]
        call arg_eq
        test al, al
        jnz .Lcf_jpeg
        mov rcx, rbx
        lea rdx, [rip + w_jpeg]
        call arg_eq
        test al, al
        jnz .Lcf_jpeg
        mov rcx, rbx
        lea rdx, [rip + w_bmp]
        call arg_eq
        test al, al
        jnz .Lcf_bmp
.Lcf_png:
        lea rax, [rip + g_cf_png]
        jmp .Lcf_ret
.Lcf_jpeg:
        lea rax, [rip + g_cf_jpeg]
        jmp .Lcf_ret
.Lcf_bmp:
        lea rax, [rip + g_cf_bmp]
.Lcf_ret:
        add rsp, 32
        pop rbx
        ret
        ENDF

/* ---- pixel rows (leaf functions: rcx = destination, rdx = source, r8d = pixels) ---- */

/* 32bpp -> 24bpp BGR, 3 * n bytes written; returns rcx just past them. */
SFUNC bgr_row
        ENDPROLOG
        test r8d, r8d
        jle .Lbr_ret
        mov r9d, r8d
        shr r9d, 2
        jz .Lbr_tail
.Lbr_4:                                 /* 4 pixels -> one qword and one dword */
        mov eax, dword ptr [rdx]
        mov r10d, dword ptr [rdx + 4]
        mov r11d, dword ptr [rdx + 8]
        and eax, 0xFFFFFF
        shl r10, 40
        shr r10, 16                     /* pixel 1 at bytes 3..5 */
        or rax, r10
        mov r10, r11
        shl r10, 48                     /* blue and green of pixel 2 at bytes 6..7 */
        or rax, r10
        mov qword ptr [rcx], rax
        shr r11d, 16
        movzx r11d, r11b                /* red of pixel 2 */
        mov r10d, dword ptr [rdx + 12]
        shl r10d, 8                     /* pixel 3 at bytes 9..11 */
        or r10d, r11d
        mov dword ptr [rcx + 8], r10d
        add rdx, 16
        add rcx, 12
        dec r9d
        jnz .Lbr_4
.Lbr_tail:
        and r8d, 3
        jz .Lbr_ret
.Lbr_1:
        mov eax, dword ptr [rdx]
        mov word ptr [rcx], ax
        shr eax, 16
        mov byte ptr [rcx + 2], al
        add rdx, 4
        add rcx, 3
        dec r8d
        jnz .Lbr_1
.Lbr_ret:
        ret
        ENDF

/* d[i] = s[i] | 0xFF000000 */
SFUNC opaque_row
        ENDPROLOG
        test r8d, r8d
        jle .Lor_ret
        movdqa xmm1, xmmword ptr [rip + k_alpha]
        mov eax, r8d
        shr eax, 2
        jz .Lor_tail
.Lor_4:
        movdqu xmm0, xmmword ptr [rdx]
        por xmm0, xmm1
        movdqu xmmword ptr [rcx], xmm0
        add rdx, 16
        add rcx, 16
        dec eax
        jnz .Lor_4
.Lor_tail:
        and r8d, 3
        jz .Lor_ret
.Lor_1:
        mov eax, dword ptr [rdx]
        or eax, 0xFF000000
        mov dword ptr [rcx], eax
        add rdx, 4
        add rcx, 4
        dec r8d
        jnz .Lor_1
.Lor_ret:
        ret
        ENDF

/* Straight alpha over white: each channel c becomes c * a / 255 + (255 - a), alpha 255.
 * (a = 255 leaves the pixel as it is, like the C, which skips it.) x / 255 for
 * x <= 65535 is (x * 0x8081) >> 23, done as pmulhuw then >> 7. */
.macro BLEND4 src                       /* xmm0 = 4 blended pixels of \src; xmm1-xmm4 clobbered */
        movdqu xmm0, xmmword ptr \src
        pxor xmm4, xmm4
        movdqa xmm1, xmm0
        punpcklbw xmm0, xmm4            /* pixels 0, 1 as words */
        punpckhbw xmm1, xmm4            /* pixels 2, 3 */
        pshuflw xmm2, xmm0, 0xFF
        pshufhw xmm2, xmm2, 0xFF        /* each pixel's alpha in its 4 words */
        movdqa xmm3, xmmword ptr [rip + k_ff16]
        psubw xmm3, xmm2                /* 255 - a */
        pmullw xmm0, xmm2
        pmulhuw xmm0, xmmword ptr [rip + k_div255]
        psrlw xmm0, 7
        paddw xmm0, xmm3
        pshuflw xmm2, xmm1, 0xFF
        pshufhw xmm2, xmm2, 0xFF
        movdqa xmm3, xmmword ptr [rip + k_ff16]
        psubw xmm3, xmm2
        pmullw xmm1, xmm2
        pmulhuw xmm1, xmmword ptr [rip + k_div255]
        psrlw xmm1, 7
        paddw xmm1, xmm3
        packuswb xmm0, xmm1
        por xmm0, xmmword ptr [rip + k_alpha]
.endm

SFUNC blend_row
        ENDPROLOG
        test r8d, r8d
        jle .Lbl_ret
        mov r9d, r8d
        shr r9d, 2
        jz .Lbl_tail
.Lbl_4:
        BLEND4 [rdx]
        movdqu xmmword ptr [rcx], xmm0
        add rdx, 16
        add rcx, 16
        dec r9d
        jnz .Lbl_4
.Lbl_tail:
        and r8d, 3
        jz .Lbl_ret
        xor r9d, r9d                    /* the last 1..3 pixels go through the home space */
.Lbl_in:
        mov eax, dword ptr [rdx + r9 * 4]
        mov dword ptr [rsp + 8 + r9 * 4], eax
        inc r9d
        cmp r9d, r8d
        jb .Lbl_in
        BLEND4 [rsp + 8]
        movdqu xmmword ptr [rsp + 8], xmm0
        xor r9d, r9d
.Lbl_out:
        mov eax, dword ptr [rsp + 8 + r9 * 4]
        mov dword ptr [rcx + r9 * 4], eax
        inc r9d
        cmp r9d, r8d
        jb .Lbl_out
.Lbl_ret:
        ret
        ENDF

/* Premultiplied pixels over white, in place: k = 255 - a; if k, the pixel becomes
 * (r + k) << 16 | (g + k) << 8 | (b + k), alpha byte 0, sums ORed like the C.
 * rcx = pixels, rdx = count (64-bit). */
SFUNC white_matte
        ENDPROLOG
        mov r8, rdx
        shr r8, 2
        jz .Lwm_tail
        movdqa xmm5, xmmword ptr [rip + k_ff32]
.Lwm_4:
        movdqu xmm0, xmmword ptr [rcx]
        movdqa xmm1, xmm0
        psrld xmm1, 24
        movdqa xmm2, xmm5
        psubd xmm2, xmm1                /* k */
        pxor xmm1, xmm1
        pcmpeqd xmm1, xmm2              /* lanes with k == 0 stay */
        pmovmskb eax, xmm1
        cmp eax, 0xFFFF
        je .Lwm_next                    /* all opaque */
        movdqa xmm3, xmm0
        pand xmm3, xmm5
        paddd xmm3, xmm2                /* b + k */
        movdqa xmm4, xmm0
        psrld xmm4, 8
        pand xmm4, xmm5
        paddd xmm4, xmm2
        pslld xmm4, 8
        por xmm3, xmm4                  /* | (g + k) << 8 */
        movdqa xmm4, xmm0
        psrld xmm4, 16
        pand xmm4, xmm5
        paddd xmm4, xmm2
        pslld xmm4, 16
        por xmm3, xmm4                  /* | (r + k) << 16 */
        pand xmm0, xmm1
        pandn xmm1, xmm3
        por xmm0, xmm1
        movdqu xmmword ptr [rcx], xmm0
.Lwm_next:
        add rcx, 16
        dec r8
        jnz .Lwm_4
.Lwm_tail:
        and edx, 3
        jz .Lwm_ret
.Lwm_1:
        mov eax, dword ptr [rcx]
        mov r8d, eax
        shr r8d, 24
        xor r8d, 255                    /* k */
        jz .Lwm_skip
        movzx r9d, al
        add r9d, r8d
        mov r10d, eax
        shr r10d, 8
        movzx r10d, r10b
        add r10d, r8d
        shl r10d, 8
        or r9d, r10d
        shr eax, 16
        movzx eax, al
        add eax, r8d
        shl eax, 16
        or eax, r9d
        mov dword ptr [rcx], eax
.Lwm_skip:
        add rcx, 4
        dec edx
        jnz .Lwm_1
.Lwm_ret:
        ret
        ENDF

/* ---- WIC files --------------------------------------------------------------------- */

/* bool image_save(const WCHAR *path, const uint32_t *px, int stride, int w, int h) */
#define IS_ST 40
#define IS_ENC 48
#define IS_FR 56
#define IS_BAG 64
#define IS_ROWS 72
#define IS_FMT 80
#define IS_RB 96
#define IS_IS24 100
#define IS_Y 104
#define IS_CREATED 108
#define IS_OK 109
#define IS_N 112
#define IS_J 116
#define IS_H 224                        /* the 5th argument */
FUNC image_save
        PUSHREG rbx
        PUSHREG rbp
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 120
        ENDPROLOG
        mov r12, rcx                    /* path */
        mov r13, rdx                    /* px */
        movsxd r14, r8d                 /* stride */
        mov r15d, r9d                   /* w */
        mov ebp, dword ptr [rsp + IS_H] /* h */
        call wic
        test rax, rax
        jz .Lis_ret
        mov rbx, rax                    /* factory */
        xor eax, eax
        mov qword ptr [rsp + IS_ST], rax
        mov qword ptr [rsp + IS_ENC], rax
        mov qword ptr [rsp + IS_FR], rax
        mov qword ptr [rsp + IS_BAG], rax
        mov qword ptr [rsp + IS_ROWS], rax
        mov word ptr [rsp + IS_CREATED], ax     /* created = ok = false */
        mov rcx, rbx
        lea rdx, [rsp + IS_ST]
        COM V_Factory_CreateStream
        test eax, eax
        js .Lis_out
        mov rcx, qword ptr [rsp + IS_ST]
        mov rdx, r12
        mov r8d, K_GENERIC_WRITE
        COM V_Stream_InitializeFromFilename
        test eax, eax
        js .Lis_out
        mov byte ptr [rsp + IS_CREATED], 1
        mov rcx, r12
        call container_for
        mov rcx, rbx
        mov rdx, rax
        xor r8d, r8d
        lea r9, [rsp + IS_ENC]
        COM V_Factory_CreateEncoder
        test eax, eax
        js .Lis_out
        mov rcx, qword ptr [rsp + IS_ENC]
        mov rdx, qword ptr [rsp + IS_ST]
        mov r8d, K_WICBitmapEncoderNoCache
        COM V_Encoder_Initialize
        test eax, eax
        js .Lis_out
        mov rcx, qword ptr [rsp + IS_ENC]
        lea rdx, [rsp + IS_FR]
        lea r8, [rsp + IS_BAG]
        COM V_Encoder_CreateNewFrame
        test eax, eax
        js .Lis_out
        mov rcx, qword ptr [rsp + IS_FR]
        mov rdx, qword ptr [rsp + IS_BAG]
        COM V_FrameEncode_Initialize
        test eax, eax
        js .Lis_out
        mov rcx, qword ptr [rsp + IS_FR]
        mov edx, r15d
        mov r8d, ebp
        COM V_FrameEncode_SetSize
        test eax, eax
        js .Lis_out
        movdqu xmm0, xmmword ptr [rip + g_pf_24bgr]
        movdqu xmmword ptr [rsp + IS_FMT], xmm0
        mov rcx, qword ptr [rsp + IS_FR]
        lea rdx, [rsp + IS_FMT]
        COM V_FrameEncode_SetPixelFormat
        test eax, eax
        js .Lis_out
        /* the encoder may have picked another format: 24bpp, or 32bpp BGRA / BGR */
        movdqu xmm1, xmmword ptr [rsp + IS_FMT]
        movdqu xmm0, xmmword ptr [rip + g_pf_24bgr]
        pcmpeqb xmm0, xmm1
        pmovmskb eax, xmm0
        cmp eax, 0xFFFF
        sete byte ptr [rsp + IS_IS24]
        je .Lis_fmt_ok
        movdqu xmm0, xmmword ptr [rip + g_pf_32bgra]
        pcmpeqb xmm0, xmm1
        pmovmskb eax, xmm0
        cmp eax, 0xFFFF
        je .Lis_fmt_ok
        movdqu xmm0, xmmword ptr [rip + g_pf_32bgr]
        pcmpeqb xmm0, xmm1
        pmovmskb eax, xmm0
        cmp eax, 0xFFFF
        jne .Lis_out
.Lis_fmt_ok:
        lea eax, [r15 + r15 * 2 + 3]    /* is24: (w * 3 + 3) & ~3, else w * 4 */
        and eax, -4
        lea ecx, [r15 * 4]
        cmp byte ptr [rsp + IS_IS24], 0
        cmove eax, ecx
        mov dword ptr [rsp + IS_RB], eax
        mov ecx, eax
        shl rcx, 7                      /* 128 rows per chunk */
        call mem_alloc
        mov qword ptr [rsp + IS_ROWS], rax
        test rax, rax
        jz .Lis_out
        mov dword ptr [rsp + IS_Y], 0
        mov rsi, r13                    /* source row */
.Lis_chunk:
        mov eax, dword ptr [rsp + IS_Y]
        cmp eax, ebp
        jge .Lis_commit
        mov ecx, ebp
        sub ecx, eax
        mov edx, 128
        cmp ecx, edx
        cmovg ecx, edx                  /* n = min(128, h - y) */
        mov dword ptr [rsp + IS_N], ecx
        mov dword ptr [rsp + IS_J], ecx
        mov rdi, qword ptr [rsp + IS_ROWS]
.Lis_row:
        mov rcx, rdi
        mov rdx, rsi
        mov r8d, r15d
        cmp byte ptr [rsp + IS_IS24], 0
        je .Lis_row32
        call bgr_row
        jmp .Lis_row_next
.Lis_row32:
        call opaque_row
.Lis_row_next:
        lea rsi, [rsi + r14 * 4]
        mov eax, dword ptr [rsp + IS_RB]
        add rdi, rax
        dec dword ptr [rsp + IS_J]
        jnz .Lis_row
        mov rcx, qword ptr [rsp + IS_FR]
        mov edx, dword ptr [rsp + IS_N]
        mov r8d, dword ptr [rsp + IS_RB]
        mov r9d, r8d
        imul r9d, edx
        mov rax, qword ptr [rsp + IS_ROWS]
        mov qword ptr [rsp + 32], rax
        COM V_FrameEncode_WritePixels
        test eax, eax
        js .Lis_out
        add dword ptr [rsp + IS_Y], 128
        jmp .Lis_chunk
.Lis_commit:
        mov rcx, qword ptr [rsp + IS_FR]
        COM V_FrameEncode_Commit
        test eax, eax
        js .Lis_out
        mov rcx, qword ptr [rsp + IS_ENC]
        COM V_Encoder_Commit
        test eax, eax
        js .Lis_out
        mov byte ptr [rsp + IS_OK], 1
.Lis_out:
        mov rcx, qword ptr [rsp + IS_ROWS]
        call mem_free
        mov rcx, qword ptr [rsp + IS_BAG]
        test rcx, rcx
        jz 1f
        COM V_Release
1:      mov rcx, qword ptr [rsp + IS_FR]
        test rcx, rcx
        jz 1f
        COM V_Release
1:      mov rcx, qword ptr [rsp + IS_ENC]
        test rcx, rcx
        jz 1f
        COM V_Release
1:      mov rcx, qword ptr [rsp + IS_ST]
        test rcx, rcx
        jz 1f
        COM V_Release
1:      mov rcx, rbx
        COM V_Release
        movzx eax, byte ptr [rsp + IS_OK]
        test eax, eax
        jnz .Lis_ret
        cmp byte ptr [rsp + IS_CREATED], 0
        je .Lis_ret
        mov rcx, r12
        API DeleteFileW                 /* never leave a truncated file behind */
        xor eax, eax
.Lis_ret:
        add rsp, 120
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

/* bool image_load(const WCHAR *path, Img *out) */
#define IL_DEC 56
#define IL_FR 64
#define IL_CV 72
#define IL_W 80
#define IL_H 84
#define IL_OK 88
FUNC image_load
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 104
        ENDPROLOG
        mov rdi, rcx                    /* path */
        mov rsi, rdx                    /* out */
        xorps xmm0, xmm0
        movups xmmword ptr [rsi], xmm0
        movups xmmword ptr [rsi + 16], xmm0
        mov qword ptr [rsi + 32], 0
        call wic
        test rax, rax
        jz .Lil_ret
        mov rbx, rax
        xor eax, eax
        mov qword ptr [rsp + IL_DEC], rax
        mov qword ptr [rsp + IL_FR], rax
        mov qword ptr [rsp + IL_CV], rax
        mov qword ptr [rsp + IL_W], rax         /* w = h = 0 */
        mov byte ptr [rsp + IL_OK], al
        mov rcx, rbx
        mov rdx, rdi
        xor r8d, r8d
        mov r9d, K_GENERIC_READ
        mov qword ptr [rsp + 32], K_WICDecodeMetadataCacheOnDemand
        lea rax, [rsp + IL_DEC]
        mov qword ptr [rsp + 40], rax
        COM V_Factory_CreateDecoderFromFilename
        test eax, eax
        js .Lil_out
        mov rcx, qword ptr [rsp + IL_DEC]
        xor edx, edx
        lea r8, [rsp + IL_FR]
        COM V_Decoder_GetFrame
        test eax, eax
        js .Lil_out
        mov rcx, rbx
        lea rdx, [rsp + IL_CV]
        COM V_Factory_CreateFormatConverter
        test eax, eax
        js .Lil_out
        mov rcx, qword ptr [rsp + IL_CV]
        mov rdx, qword ptr [rsp + IL_FR]
        lea r8, [rip + g_pf_32pbgra]
        mov r9d, K_WICBitmapDitherTypeNone
        mov qword ptr [rsp + 32], 0     /* palette */
        mov qword ptr [rsp + 40], 0     /* alpha threshold 0.0 */
        mov qword ptr [rsp + 48], K_WICBitmapPaletteTypeCustom
        COM V_Converter_Initialize
        test eax, eax
        js .Lil_out
        mov rcx, qword ptr [rsp + IL_CV]
        lea rdx, [rsp + IL_W]
        lea r8, [rsp + IL_H]
        COM V_Converter_GetSize
        test eax, eax
        js .Lil_out
        mov rcx, rsi
        mov edx, dword ptr [rsp + IL_W]
        mov r8d, dword ptr [rsp + IL_H]
        call img_create
        test al, al
        jz .Lil_out
        mov rcx, qword ptr [rsp + IL_CV]
        xor edx, edx
        mov r8d, dword ptr [rsp + IL_W]
        shl r8d, 2
        mov r9d, r8d
        imul r9d, dword ptr [rsp + IL_H]
        mov rax, qword ptr [rsi + IMG_PX]
        mov qword ptr [rsp + 32], rax
        COM V_Converter_CopyPixels
        test eax, eax
        jns .Lil_matte
        mov rcx, rsi
        call img_destroy
        jmp .Lil_out
.Lil_matte:
        mov rcx, qword ptr [rsi + IMG_PX]
        mov eax, dword ptr [rsp + IL_W]
        mov edx, dword ptr [rsp + IL_H]
        imul rdx, rax
        call white_matte
        mov byte ptr [rsp + IL_OK], 1
.Lil_out:
        mov rcx, qword ptr [rsp + IL_CV]
        test rcx, rcx
        jz 1f
        COM V_Release
1:      mov rcx, qword ptr [rsp + IL_FR]
        test rcx, rcx
        jz 1f
        COM V_Release
1:      mov rcx, qword ptr [rsp + IL_DEC]
        test rcx, rcx
        jz 1f
        COM V_Release
1:      mov rcx, rbx
        COM V_Release
        movzx eax, byte ptr [rsp + IL_OK]
.Lil_ret:
        add rsp, 104
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
        ENDF

/* ---- clipboard ---------------------------------------------------------------------- */

/* bool clip_open(HWND owner): another app may hold the clipboard for a moment */
SFUNC clip_open
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        mov rbx, rcx
        mov esi, 25
.Lco_try:
        mov rcx, rbx
        API OpenClipboard
        test eax, eax
        jnz .Lco_yes
        mov ecx, 8
        API Sleep
        dec esi
        jnz .Lco_try
        xor eax, eax
        jmp .Lco_ret
.Lco_yes:
        mov eax, 1
.Lco_ret:
        add rsp, 40
        pop rsi
        pop rbx
        ret
        ENDF

/* bool clip_put_image(HWND owner, const uint32_t *px, int stride, int w, int h):
 * 24bpp bottom-up CF_DIB is understood by every application. */
FUNC clip_put_image
        PUSHREG rbx
        PUSHREG rbp
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 40
        ENDPROLOG
        mov rbx, rcx                    /* owner */
        mov r12, rdx                    /* source row */
        movsxd r13, r8d                 /* stride */
        mov r14d, r9d                   /* w */
        mov r15d, dword ptr [rsp + 144] /* h */
        movsxd rax, r9d
        lea rbp, [rax + rax * 2 + 3]
        and rbp, -4                     /* rb */
        movsxd rdx, r15d
        imul rdx, rbp
        mov rdi, rdx                    /* rb * h */
        add rdx, BIH_BYTES
        mov ecx, K_GMEM_MOVEABLE
        API GlobalAlloc
        test rax, rax
        jz .Lpi_ret
        mov rsi, rax                    /* g */
        mov rcx, rax
        API GlobalLock
        xorps xmm0, xmm0
        movups xmmword ptr [rax], xmm0
        movups xmmword ptr [rax + 16], xmm0
        mov qword ptr [rax + 32], 0
        mov dword ptr [rax + BIH_SIZE], BIH_BYTES
        mov dword ptr [rax + BIH_WIDTH], r14d
        mov dword ptr [rax + BIH_HEIGHT], r15d
        mov word ptr [rax + BIH_PLANES], 1
        mov word ptr [rax + BIH_BITCOUNT], 24
        mov dword ptr [rax + BIH_SIZEIMAGE], edi
        /* rows bottom-up: image row 0 is the last one in memory */
        lea rdi, [rax + BIH_BYTES]
        mov eax, r15d
        sub eax, 1
        movsxd rax, eax
        imul rax, rbp
        add rdi, rax                    /* d for y = 0 */
        test r15d, r15d
        jle .Lpi_unlock
.Lpi_row:
        test r14d, r14d
        jle .Lpi_next
        mov dword ptr [rdi + rbp - 4], 0        /* the row padding (pixels overwrite the rest) */
        mov rcx, rdi
        mov rdx, r12
        mov r8d, r14d
        call bgr_row
.Lpi_next:
        lea r12, [r12 + r13 * 4]
        sub rdi, rbp
        dec r15d
        jnz .Lpi_row
.Lpi_unlock:
        mov rcx, rsi
        API GlobalUnlock
        mov rcx, rbx
        call clip_open
        test eax, eax
        jz .Lpi_free
        API EmptyClipboard
        mov ecx, K_CF_DIB
        mov rdx, rsi
        API SetClipboardData
        mov rbx, rax
        API CloseClipboard
        test rbx, rbx
        jz .Lpi_free
        mov eax, 1
        jmp .Lpi_ret
.Lpi_free:
        mov rcx, rsi
        API GlobalFree
        xor eax, eax
.Lpi_ret:
        add rsp, 40
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

/* bool clip_put_text(HWND owner, const WCHAR *text) */
FUNC clip_put_text
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 40
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        mov rax, rdx
.Lpt_len:
        cmp word ptr [rax], 0
        je .Lpt_len_done
        add rax, 2
        jmp .Lpt_len
.Lpt_len_done:
        sub rax, rsi
        lea r12, [rax + 2]              /* bytes with the terminator */
        mov ecx, K_GMEM_MOVEABLE
        mov rdx, r12
        API GlobalAlloc
        test rax, rax
        jz .Lpt_ret
        mov rdi, rax
        mov rcx, rax
        API GlobalLock
        mov rdx, rdi
        mov rdi, rax
        mov rcx, r12
        rep movsb
        mov rdi, rdx
        mov rcx, rdi
        API GlobalUnlock
        mov rcx, rbx
        call clip_open
        test eax, eax
        jz .Lpt_free
        API EmptyClipboard
        mov ecx, K_CF_UNICODETEXT
        mov rdx, rdi
        API SetClipboardData
        mov rsi, rax
        API CloseClipboard
        test rsi, rsi
        jz .Lpt_free
        mov eax, 1
        jmp .Lpt_ret
.Lpt_free:
        mov rcx, rdi
        API GlobalFree
        xor eax, eax
.Lpt_ret:
        add rsp, 40
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
        ENDF

/* bool dib_to_img(const BITMAPINFOHEADER *bh, size_t size, Img *out) */
SFUNC dib_to_img
        PUSHREG rbx
        PUSHREG rbp
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 104
        ENDPROLOG
        mov rbx, rcx                    /* bh */
        mov rsi, rdx                    /* size */
        mov rdi, r8                     /* out */
        cmp rsi, BIH_BYTES
        jb .Ldi_fail
        mov eax, dword ptr [rbx + BIH_SIZE]
        cmp rax, BIH_BYTES
        jb .Ldi_fail
        cmp rax, rsi
        ja .Ldi_fail
        mov r12d, dword ptr [rbx + BIH_WIDTH]   /* w */
        mov r13d, dword ptr [rbx + BIH_HEIGHT]
        mov ecx, r13d
        neg ecx
        test r13d, r13d
        cmovs r13d, ecx                 /* h = |biHeight| */
        test r12d, r12d
        jle .Ldi_fail
        test r13d, r13d
        jle .Ldi_fail
        cmp word ptr [rbx + BIH_PLANES], 1
        jne .Ldi_fail
        /* off = biSize + colors * 4 (+ the masks of a plain BITMAPINFOHEADER) */
        mov ecx, dword ptr [rbx + BIH_CLRUSED]
        test ecx, ecx
        jnz .Ldi_colors
        movzx ecx, word ptr [rbx + BIH_BITCOUNT]
        cmp ecx, 8
        ja .Ldi_nocolors
        mov eax, 1
        shl eax, cl
        mov ecx, eax
        jmp .Ldi_colors
.Ldi_nocolors:
        xor ecx, ecx
.Ldi_colors:
        mov r15d, dword ptr [rbx + BIH_SIZE]
        lea r15, [r15 + rcx * 4]        /* off */
        mov eax, dword ptr [rbx + BIH_COMPRESSION]
        cmp dword ptr [rbx + BIH_SIZE], BIH_BYTES
        jne .Ldi_stride
        cmp eax, K_BI_BITFIELDS
        jne 1f
        add r15, 12
        jmp .Ldi_stride
1:      cmp eax, K_BI_ALPHABITFIELDS
        jne .Ldi_stride
        add r15, 16
.Ldi_stride:
        movzx ecx, word ptr [rbx + BIH_BITCOUNT]
        mov r14d, r12d
        imul r14, rcx
        add r14, 31
        shr r14, 5
        shl r14, 2                      /* stride */
        cmp eax, K_BI_RLE8
        je .Ldi_rle
        cmp eax, K_BI_RLE4
        je .Ldi_rle
        mov rax, r14
        imul rax, r13                   /* need = stride * h */
        jmp .Ldi_need
.Ldi_rle:
        mov eax, dword ptr [rbx + BIH_SIZEIMAGE]
.Ldi_need:
        cmp r15, rsi
        ja .Ldi_fail
        mov rcx, rsi
        sub rcx, r15
        cmp rax, rcx
        ja .Ldi_fail
        test rax, rax
        jz .Ldi_fail
        lea rsi, [rbx + r15]            /* bits */
        mov rcx, rdi
        mov edx, r12d
        mov r8d, r13d
        call img_create
        test al, al
        jz .Ldi_fail
        /* plain 32bpp BGR(A)? */
        cmp word ptr [rbx + BIH_BITCOUNT], 32
        jne .Ldi_gdi
        mov eax, dword ptr [rbx + BIH_COMPRESSION]
        test eax, eax
        jz .Ldi_std32
        cmp eax, K_BI_BITFIELDS
        jne .Ldi_gdi
        cmp dword ptr [rbx + BIH_BYTES], 0xFF0000       /* masks after the 40-byte header */
        jne .Ldi_gdi
        cmp dword ptr [rbx + BIH_BYTES + 4], 0xFF00
        jne .Ldi_gdi
        cmp dword ptr [rbx + BIH_BYTES + 8], 0xFF
        jne .Ldi_gdi
.Ldi_std32:
        /* Use alpha only when it carries information (all 0 or all 255 means opaque):
         * the AND and OR of every pixel tell whether any alpha is below 255 or above 0. */
        mov eax, r12d
        mov ecx, r13d
        imul rcx, rax                   /* w * h pixels */
        mov rdx, rsi
        pcmpeqd xmm0, xmm0              /* AND */
        pxor xmm1, xmm1                 /* OR */
        mov rax, rcx
        shr rax, 2
        jz .Ldi_scan_tail
.Ldi_scan4:
        movdqu xmm2, xmmword ptr [rdx]
        pand xmm0, xmm2
        por xmm1, xmm2
        add rdx, 16
        dec rax
        jnz .Ldi_scan4
.Ldi_scan_tail:
        movdqa xmm2, xmm0
        psrldq xmm2, 8
        pand xmm0, xmm2
        pshufd xmm2, xmm0, 1
        pand xmm0, xmm2
        movdqa xmm2, xmm1
        psrldq xmm2, 8
        por xmm1, xmm2
        pshufd xmm2, xmm1, 1
        por xmm1, xmm2
        movd r8d, xmm0
        movd r9d, xmm1
        and ecx, 3
        jz .Ldi_scan_done
.Ldi_scan1:
        mov eax, dword ptr [rdx]
        and r8d, eax
        or r9d, eax
        add rdx, 4
        dec ecx
        jnz .Ldi_scan1
.Ldi_scan_done:
        xor ebp, ebp                    /* alpha = any below 255 && any above 0 */
        shr r8d, 24
        cmp r8d, 255
        je 1f
        shr r9d, 24
        setnz bpl
1:      /* rows: d = out->px + y * w, s = bits + stride * (top-down ? y : h - 1 - y) */
        mov r15, rsi
        cmp dword ptr [rbx + BIH_HEIGHT], 0
        jl 1f
        lea eax, [r13 - 1]
        imul rax, r14
        add r15, rax                    /* bottom-up: start at the last row */
        neg r14
1:      mov rsi, qword ptr [rdi + IMG_PX]
        mov ebx, r13d                   /* rows left (bh is not needed any more) */
.Ldi_row:
        mov rcx, rsi
        mov rdx, r15
        mov r8d, r12d
        test ebp, ebp
        jz 1f
        call blend_row
        jmp 2f
1:      call opaque_row
2:      add r15, r14
        lea rsi, [rsi + r12 * 4]
        dec ebx
        jnz .Ldi_row
        mov eax, 1
        jmp .Ldi_ret
.Ldi_gdi:
        mov rcx, qword ptr [rdi + IMG_DC]
        xor edx, edx
        xor r8d, r8d
        mov r9d, r12d
        mov dword ptr [rsp + 32], r13d          /* h */
        mov qword ptr [rsp + 40], 0             /* xSrc */
        mov qword ptr [rsp + 48], 0             /* ySrc */
        mov qword ptr [rsp + 56], 0             /* first scan line */
        mov dword ptr [rsp + 64], r13d          /* lines */
        mov qword ptr [rsp + 72], rsi           /* bits */
        mov qword ptr [rsp + 80], rbx           /* header */
        mov qword ptr [rsp + 88], K_DIB_RGB_COLORS
        API SetDIBitsToDevice
        test eax, eax
        jnz 1f
        mov rcx, rdi
        call img_destroy
        jmp .Ldi_fail
1:      API GdiFlush
        mov eax, 1
        jmp .Ldi_ret
.Ldi_fail:
        xor eax, eax
.Ldi_ret:
        add rsp, 104
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

/* WCHAR *hdrop_first(HANDLE h): the first file of a CF_HDROP, or NULL */
SFUNC hdrop_first
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        ALLOC 56
        ENDPROLOG
        mov rbx, rcx
        API GlobalLock
        test rax, rax
        jz .Lhd_ret
        mov rsi, rax                    /* base */
        mov rcx, rbx
        API GlobalSize
        mov rdi, rax                    /* size */
        xor r12d, r12d                  /* result */
        cmp rdi, DF_BYTES
        jb .Lhd_unlock
        mov eax, dword ptr [rsi + DF_PFILES]
        cmp rax, rdi
        jae .Lhd_unlock
        lea r13, [rsi + rax]            /* p */
        mov r14, rdi
        sub r14, rax                    /* bytes after pFiles */
        cmp dword ptr [rsi + DF_FWIDE], 0
        je .Lhd_ansi
        shr r14, 1
        xor edx, edx
.Lhd_wlen:
        cmp rdx, r14
        jae .Lhd_wend
        cmp word ptr [r13 + rdx * 2], 0
        je .Lhd_wend
        inc rdx
        jmp .Lhd_wlen
.Lhd_wend:
        test rdx, rdx
        jz .Lhd_unlock
        cmp rdx, r14
        jae .Lhd_unlock                 /* no terminator */
        mov rcx, r13
        call wcs_dup
        mov r12, rax
        jmp .Lhd_unlock
.Lhd_ansi:
        xor eax, eax
.Lhd_alen:
        cmp rax, r14
        jae .Lhd_aend
        cmp byte ptr [r13 + rax], 0
        je .Lhd_aend
        inc rax
        jmp .Lhd_alen
.Lhd_aend:
        test rax, rax
        jz .Lhd_unlock
        mov r14, rax                    /* n */
        xor ecx, ecx
        xor edx, edx
        mov r8, r13
        mov r9d, r14d
        mov qword ptr [rsp + 32], 0
        mov qword ptr [rsp + 40], 0
        API MultiByteToWideChar
        test eax, eax
        jle .Lhd_unlock
        mov edi, eax                    /* wn */
        lea rcx, [rax * 2 + 2]
        call mem_alloc
        test rax, rax
        jz .Lhd_unlock
        mov r12, rax
        xor ecx, ecx
        xor edx, edx
        mov r8, r13
        mov r9d, r14d
        mov qword ptr [rsp + 32], rax
        mov qword ptr [rsp + 40], rdi
        API MultiByteToWideChar
.Lhd_unlock:
        mov rcx, rbx
        API GlobalUnlock
        mov rax, r12
.Lhd_ret:
        add rsp, 56
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
        ENDF

/* int clip_get_image(HWND owner, Img *out) */
FUNC clip_get_image
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        ALLOC 40
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        xorps xmm0, xmm0
        movups xmmword ptr [rsi], xmm0
        movups xmmword ptr [rsi + 16], xmm0
        mov qword ptr [rsi + 32], 0
        mov rcx, rbx
        call clip_open
        test eax, eax
        jnz 1f
        mov eax, EXIT_FAIL
        jmp .Lgi_ret
1:      mov edi, EXIT_NOTHING           /* rc */
        xor r12d, r12d                  /* file */
        xor r13d, r13d                  /* text */
        mov ecx, K_CF_DIB
        API IsClipboardFormatAvailable
        test eax, eax
        jz .Lgi_drop
        mov ecx, K_CF_DIB
        API GetClipboardData
        test rax, rax
        jz .Lgi_drop
        mov rbx, rax
        mov rcx, rax
        API GlobalLock
        test rax, rax
        jz .Lgi_close
        mov r14, rax
        mov rcx, rbx
        API GlobalSize
        mov rcx, r14
        mov rdx, rax
        mov r8, rsi
        call dib_to_img
        xor edi, edi
        test al, al
        setz dil                        /* EXIT_OK or EXIT_FAIL */
        mov rcx, rbx
        API GlobalUnlock
        jmp .Lgi_close
.Lgi_drop:
        mov ecx, K_CF_HDROP
        API IsClipboardFormatAvailable
        test eax, eax
        jz .Lgi_text
        mov ecx, K_CF_HDROP
        API GetClipboardData
        test rax, rax
        jz .Lgi_text
        mov rcx, rax
        call hdrop_first
        mov r12, rax
        jmp .Lgi_close
.Lgi_text:
        mov ecx, K_CF_UNICODETEXT
        API IsClipboardFormatAvailable
        test eax, eax
        jz .Lgi_close
        mov ecx, K_CF_UNICODETEXT
        API GetClipboardData
        test rax, rax
        jz .Lgi_close
        mov rbx, rax
        mov rcx, rax
        API GlobalLock
        test rax, rax
        jz .Lgi_close
        mov r14, rax
        mov rcx, rbx
        API GlobalSize
        shr rax, 1                      /* chars in the block */
        xor edx, edx
.Lgi_tlen:
        cmp rdx, rax
        jae .Lgi_tend
        cmp rdx, 20000
        jae .Lgi_tend
        cmp word ptr [r14 + rdx * 2], 0
        je .Lgi_tend
        inc rdx
        jmp .Lgi_tlen
.Lgi_tend:
        mov rcx, r14
        call wcs_dup
        mov r13, rax
        mov rcx, rbx
        API GlobalUnlock
.Lgi_close:
        API CloseClipboard              /* slow work below happens without holding the clipboard */
        test r12, r12
        jz .Lgi_notfile
        mov rcx, r12
        mov rdx, rsi
        call image_load
        movzx eax, al
        xor eax, 1
        lea edi, [rax * 4]              /* EXIT_OK or EXIT_NOTHING */
        mov rcx, r12
        call mem_free
        jmp .Lgi_rc
.Lgi_notfile:
        test r13, r13
        jz .Lgi_rc
        mov rax, r13
.Lgi_blank:
        movzx ecx, word ptr [rax]
        test ecx, ecx
        jz .Lgi_free_text               /* only blanks: nothing */
        add rax, 2
        cmp ecx, 0x20
        je .Lgi_blank
        cmp ecx, 9
        je .Lgi_blank
        cmp ecx, 13
        je .Lgi_blank
        cmp ecx, 10
        je .Lgi_blank
        mov rcx, r13
        mov rdx, rsi
        call text_image
        movzx edi, al
        xor edi, 1                      /* EXIT_OK or EXIT_FAIL */
.Lgi_free_text:
        mov rcx, r13
        call mem_free
.Lgi_rc:
        mov eax, edi
.Lgi_ret:
        add rsp, 40
        pop r14
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
        ENDF

/* ---- text to image ---------------------------------------------------------------------- */

/* bool text_image(const WCHAR *text, Img *out): sized for the monitor under the cursor */
FUNC text_image
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 80
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        mov qword ptr [rsp + 32], 0
        lea rcx, [rsp + 32]
        API GetCursorPos
        mov rcx, qword ptr [rsp + 32]
        mov edx, K_MONITOR_DEFAULTTONEAREST
        API MonitorFromPoint
        mov rdi, rax
        xorps xmm0, xmm0
        movups xmmword ptr [rsp + 40], xmm0
        movups xmmword ptr [rsp + 56], xmm0
        mov qword ptr [rsp + 72], 0
        mov dword ptr [rsp + 40], MI_BYTES
        mov rcx, rdi
        lea rdx, [rsp + 40]
        API GetMonitorInfoW
        mov rcx, rdi
        call dpi_scale_of
        movaps xmm1, xmm0
        mov eax, dword ptr [rsp + 40 + MI_RCWORK + RC_R]
        sub eax, dword ptr [rsp + 40 + MI_RCWORK + RC_L]
        imul eax, eax, 3
        cdq
        mov ecx, 5
        idiv ecx
        mov ecx, 240
        cmp eax, ecx
        cmovl eax, ecx
        mov r8d, eax
        mov rcx, rbx
        mov r9, rsi
        call text_image_at
        add rsp, 80
        pop rdi
        pop rsi
        pop rbx
        ret
        ENDF

/* bool text_image_at(const WCHAR *text, float scale, int max_width, Img *out) */
#define TA_RC 112
#define TA_TR 128
#define TA_S 144
FUNC text_image_at
        PUSHREG rbx
        PUSHREG rbp
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        PUSHREG r13
        PUSHREG r14
        PUSHREG r15
        ALLOC 152
        ENDPROLOG
        mov rbx, rcx                    /* text */
        mov rsi, r9                     /* out */
        mov ebp, r8d                    /* max width */
        movss dword ptr [rsp + TA_S], xmm1
        xorps xmm0, xmm0
        movups xmmword ptr [rsi], xmm0
        movups xmmword ptr [rsi + 16], xmm0
        mov qword ptr [rsi + 32], 0
        movss xmm0, dword ptr [rip + k_14]
        mulss xmm0, xmm1
        LROUNDF ecx, xmm0, xmm2
        neg ecx                         /* height -(int)lroundf(14 * s) */
        xor edx, edx
        xor r8d, r8d
        xor r9d, r9d
        mov qword ptr [rsp + 32], K_FW_NORMAL
        mov qword ptr [rsp + 40], 0
        mov qword ptr [rsp + 48], 0
        mov qword ptr [rsp + 56], 0
        mov qword ptr [rsp + 64], K_DEFAULT_CHARSET
        mov qword ptr [rsp + 72], 0     /* OUT_DEFAULT_PRECIS */
        mov qword ptr [rsp + 80], 0     /* CLIP_DEFAULT_PRECIS */
        mov qword ptr [rsp + 88], K_CLEARTYPE_QUALITY
        mov qword ptr [rsp + 96], 0     /* DEFAULT_PITCH */
        lea rax, [rip + w_yahei]
        mov qword ptr [rsp + 104], rax
        API CreateFontW
        mov rdi, rax                    /* font */
        xor ecx, ecx
        API CreateCompatibleDC
        mov r12, rax
        mov rcx, rax
        mov rdx, rdi
        API SelectObject
        mov r13, rax
        mov qword ptr [rsp + TA_RC], 0
        mov dword ptr [rsp + TA_RC + RC_R], ebp
        mov dword ptr [rsp + TA_RC + RC_B], 0
        mov rcx, r12
        mov rdx, rbx
        mov r8d, -1
        lea r9, [rsp + TA_RC]
        mov qword ptr [rsp + 32], K_DT_CALCRECT | K_TEXT_FMT
        API DrawTextW
        mov rcx, r12
        mov rdx, r13
        API SelectObject
        mov rcx, r12
        API DeleteDC
        mov r12, rdi                    /* font */
        movss xmm0, dword ptr [rip + k_10]
        mulss xmm0, dword ptr [rsp + TA_S]
        LROUNDF r13d, xmm0, xmm1        /* pad */
        mov r14d, dword ptr [rsp + TA_RC + RC_R]
        lea r14d, [r14 + r13 * 2]       /* w */
        mov r15d, dword ptr [rsp + TA_RC + RC_B]
        lea r15d, [r15 + r13 * 2]
        mov eax, 16000
        cmp r15d, eax
        cmovg r15d, eax                 /* h */
        xor ebp, ebp                    /* ok */
        mov rcx, rsi
        mov edx, r14d
        mov r8d, r15d
        call img_create
        test al, al
        jz .Lta_done
        mov rdi, qword ptr [rsi + IMG_PX]
        mov eax, r14d
        mov ecx, r15d
        imul rcx, rax
        mov eax, -1
        rep stosd                       /* white */
        mov rcx, qword ptr [rsi + IMG_DC]
        mov rdx, r12
        API SelectObject
        mov rdi, rax                    /* old font */
        mov rcx, qword ptr [rsi + IMG_DC]
        mov edx, K_TRANSPARENT
        API SetBkMode
        mov rcx, qword ptr [rsi + IMG_DC]
        mov edx, K_TEXT_COLOR
        API SetTextColor
        mov dword ptr [rsp + TA_TR + RC_L], r13d
        mov dword ptr [rsp + TA_TR + RC_T], r13d
        mov eax, r14d
        sub eax, r13d
        mov dword ptr [rsp + TA_TR + RC_R], eax
        mov eax, r15d
        sub eax, r13d
        mov dword ptr [rsp + TA_TR + RC_B], eax
        mov rcx, qword ptr [rsi + IMG_DC]
        mov rdx, rbx
        mov r8d, -1
        lea r9, [rsp + TA_TR]
        mov qword ptr [rsp + 32], K_TEXT_FMT
        API DrawTextW
        API GdiFlush
        mov rcx, qword ptr [rsi + IMG_DC]
        mov rdx, rdi
        API SelectObject
        mov ebp, 1
.Lta_done:
        mov rcx, r12
        API DeleteObject
        mov eax, ebp
        add rsp, 152
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

/* ---- save dialog (out of process) ---------------------------------------------------------- */

/* bool save_dialog(WCHAR *path, int cap) */
#define SD_EXE 112                      /* WCHAR[MAX_PATH] */
#define SD_NAME 632                     /* WCHAR[64] */
#define SD_T 760                        /* SYSTEMTIME */
#define SD_CMD 776                      /* Str */
#define SD_SA 792
#define SD_RD 816
#define SD_WR 824
#define SD_SI 832
#define SD_PI 936
#define SD_MSG 960
#define SD_CODE 1008
#define SD_N 1012
#define SD_BUF 1024                     /* WCHAR[MAX_PATH * 2 + 1] */
#define SD_BUFBYTES 1042
FUNC save_dialog
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 2072
        ENDPROLOG
        mov rbx, rcx                    /* path */
        mov esi, edx                    /* cap */
        xor ecx, ecx
        lea rdx, [rsp + SD_EXE]
        mov r8d, K_MAX_PATH
        API GetModuleFileNameW
        test eax, eax
        jz .Lsd_false
        lea rcx, [rsp + SD_T]
        API GetLocalTime
        lea rcx, [rsp + SD_NAME]
        lea rdx, [rip + w_namefmt]
        movzx r8d, word ptr [rsp + SD_T + ST_YEAR]
        movzx r9d, word ptr [rsp + SD_T + ST_MONTH]
        movzx eax, word ptr [rsp + SD_T + ST_DAY]
        mov qword ptr [rsp + 32], rax
        movzx eax, word ptr [rsp + SD_T + ST_HOUR]
        mov qword ptr [rsp + 40], rax
        movzx eax, word ptr [rsp + SD_T + ST_MINUTE]
        mov qword ptr [rsp + 48], rax
        movzx eax, word ptr [rsp + SD_T + ST_SECOND]
        mov qword ptr [rsp + 56], rax
        API wsprintfW
        xorps xmm0, xmm0
        movups xmmword ptr [rsp + SD_CMD], xmm0
        lea rcx, [rsp + SD_CMD]
        lea rdx, [rsp + SD_EXE]
        call str_add_quoted
        lea rcx, [rsp + SD_CMD]
        lea rdx, [rip + w_arg]
        call str_add
        lea rcx, [rsp + SD_CMD]
        lea rdx, [rsp + SD_NAME]
        call str_add_quoted
        lea rcx, [rsp + SD_CMD]
        lea rdx, [rip + w_space]
        call str_add
        lea rcx, [rsp + SD_CMD]
        lea rdx, [rip + g_last_dir]
        call str_add_quoted
        cmp qword ptr [rsp + SD_CMD + STR_P], 0
        je .Lsd_false
        mov qword ptr [rsp + SD_SA + SA_LENGTH], SA_BYTES
        mov qword ptr [rsp + SD_SA + SA_DESCRIPTOR], 0
        mov qword ptr [rsp + SD_SA + SA_INHERIT], 1
        lea rcx, [rsp + SD_RD]
        lea rdx, [rsp + SD_WR]
        lea r8, [rsp + SD_SA]
        xor r9d, r9d
        API CreatePipe
        test eax, eax
        jnz 1f
        lea rcx, [rsp + SD_CMD]
        call str_free
        jmp .Lsd_false
1:      mov rcx, qword ptr [rsp + SD_RD]
        mov edx, K_HANDLE_FLAG_INHERIT
        xor r8d, r8d
        API SetHandleInformation
        lea rdi, [rsp + SD_SI]
        xor eax, eax
        mov ecx, SI_BYTES / 8
        rep stosq
        mov dword ptr [rsp + SD_SI + SI_CB], SI_BYTES
        mov dword ptr [rsp + SD_SI + SI_FLAGS], K_STARTF_USESTDHANDLES
        mov rax, qword ptr [rsp + SD_WR]
        mov qword ptr [rsp + SD_SI + SI_STDOUTPUT], rax
        mov ecx, K_ASFW_ANY
        API AllowSetForegroundWindow
        lea rcx, [rsp + SD_EXE]
        mov rdx, qword ptr [rsp + SD_CMD + STR_P]
        xor r8d, r8d
        xor r9d, r9d
        mov qword ptr [rsp + 32], 1     /* inherit handles */
        mov qword ptr [rsp + 40], 0
        mov qword ptr [rsp + 48], 0
        mov qword ptr [rsp + 56], 0
        lea rax, [rsp + SD_SI]
        mov qword ptr [rsp + 64], rax
        lea rax, [rsp + SD_PI]
        mov qword ptr [rsp + 72], rax
        API CreateProcessW
        mov edi, eax                    /* started */
        mov rcx, qword ptr [rsp + SD_WR]
        API CloseHandle
        lea rcx, [rsp + SD_CMD]
        call str_free
        test edi, edi
        jnz .Lsd_wait
        mov rcx, qword ptr [rsp + SD_RD]
        API CloseHandle
        jmp .Lsd_false
.Lsd_wait:                              /* keep serving hotkeys, pins and IPC while the dialog is open */
        mov ecx, 1
        lea rdx, [rsp + SD_PI + PI_PROCESS]
        xor r8d, r8d
        mov r9d, K_INFINITE
        mov qword ptr [rsp + 32], K_QS_ALLINPUT
        API MsgWaitForMultipleObjects
        cmp eax, K_WAIT_OBJECT_0 + 1
        jne .Lsd_done
.Lsd_peek:
        lea rcx, [rsp + SD_MSG]
        xor edx, edx
        xor r8d, r8d
        xor r9d, r9d
        mov qword ptr [rsp + 32], K_PM_REMOVE
        API PeekMessageW
        test eax, eax
        jz .Lsd_wait
        cmp dword ptr [rsp + SD_MSG + MSG_MESSAGE], K_WM_QUIT
        jne 1f
        mov ecx, dword ptr [rsp + SD_MSG + MSG_WPARAM]
        API PostQuitMessage
        mov rcx, qword ptr [rsp + SD_PI + PI_PROCESS]
        mov edx, 1
        API TerminateProcess
        jmp .Lsd_done
1:      lea rcx, [rsp + SD_MSG]
        API TranslateMessage
        lea rcx, [rsp + SD_MSG]
        API DispatchMessageW
        jmp .Lsd_peek
.Lsd_done:
        mov rcx, qword ptr [rsp + SD_PI + PI_PROCESS]
        mov edx, K_INFINITE
        API WaitForSingleObject
        mov dword ptr [rsp + SD_CODE], 1
        mov rcx, qword ptr [rsp + SD_PI + PI_PROCESS]
        lea rdx, [rsp + SD_CODE]
        API GetExitCodeProcess
        xor edi, edi                    /* bytes read */
.Lsd_read:
        cmp edi, SD_BUFBYTES - 2
        jae .Lsd_read_done
        mov rcx, qword ptr [rsp + SD_RD]
        lea rdx, [rsp + SD_BUF + rdi]
        mov r8d, SD_BUFBYTES - 2
        sub r8d, edi
        lea r9, [rsp + SD_N]
        mov qword ptr [rsp + 32], 0
        API ReadFile
        test eax, eax
        jz .Lsd_read_done
        mov eax, dword ptr [rsp + SD_N]
        test eax, eax
        jz .Lsd_read_done
        add edi, eax
        jmp .Lsd_read
.Lsd_read_done:
        shr edi, 1
        mov word ptr [rsp + SD_BUF + rdi * 2], 0
        mov rcx, qword ptr [rsp + SD_RD]
        API CloseHandle
        mov rcx, qword ptr [rsp + SD_PI + PI_PROCESS]
        API CloseHandle
        mov rcx, qword ptr [rsp + SD_PI + PI_THREAD]
        API CloseHandle
        cmp dword ptr [rsp + SD_CODE], 0
        jne .Lsd_false
        cmp word ptr [rsp + SD_BUF], 0
        je .Lsd_false
        mov rcx, rbx
        lea rdx, [rsp + SD_BUF]
        mov r8d, esi
        API lstrcpynW
        lea rcx, [rip + g_last_dir]
        lea rdx, [rsp + SD_BUF]
        mov r8d, K_MAX_PATH
        API lstrcpynW
        lea rcx, [rip + g_last_dir]
        xor eax, eax                    /* last backslash */
        mov rdx, rcx
.Lsd_slash:
        movzx r8d, word ptr [rdx]
        test r8d, r8d
        jz .Lsd_slash_done
        cmp r8d, 0x5C
        cmove rax, rdx
        add rdx, 2
        jmp .Lsd_slash
.Lsd_slash_done:
        test rax, rax
        jz .Lsd_true
        sub rcx, rax
        cmp rcx, -4                     /* "C:\": keep the backslash of a drive root */
        jne 1f
        add rax, 2
1:      mov word ptr [rax], 0
.Lsd_true:
        mov eax, 1
        jmp .Lsd_ret
.Lsd_false:
        xor eax, eax
.Lsd_ret:
        add rsp, 2072
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
        ENDF

/* int save_dialog_helper(int argc, WCHAR **argv): body of `sniplite.exe --save-dialog` */
#define SH_OFN 48
#define SH_N 200
#define SH_INIT 208                     /* WCHAR[MAX_PATH] */
#define SH_FILE 728                     /* WCHAR[MAX_PATH * 2] */
FUNC save_dialog_helper
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        ALLOC 1776
        ENDPROLOG
        lea rbx, [rip + w_defname]      /* name */
        lea rsi, [rip + w_empty]        /* dir */
        cmp ecx, 2
        jle 1f
        mov rbx, qword ptr [rdx + 16]
1:      cmp ecx, 3
        jle 1f
        mov rsi, qword ptr [rdx + 24]
1:      call com_init                   /* the Explorer-style dialog needs an STA */
        lea rcx, [rip + w_comdlg32]
        API LoadLibraryW
        test rax, rax
        jz .Lsh_2
        mov rcx, rax
        lea rdx, [rip + a_GetSaveFileNameW]
        API GetProcAddress
        test rax, rax
        jz .Lsh_2
        mov rdi, rax
        lea rcx, [rsp + SH_INIT]
        mov rdx, rsi
        mov r8d, K_MAX_PATH
        API lstrcpynW
        cmp word ptr [rsp + SH_INIT], 0
        jne .Lsh_have_dir
        lea rcx, [rip + w_shell32]
        API LoadLibraryW
        test rax, rax
        jz .Lsh_no_dir
        mov rcx, rax
        lea rdx, [rip + a_SHGetFolderPathW]
        API GetProcAddress
        test rax, rax
        jz .Lsh_no_dir
        xor ecx, ecx
        mov edx, K_CSIDL_MYPICTURES
        xor r8d, r8d
        xor r9d, r9d
        lea r10, [rsp + SH_INIT]
        mov qword ptr [rsp + 32], r10
        call rax
        test eax, eax
        jns .Lsh_have_dir
.Lsh_no_dir:
        mov word ptr [rsp + SH_INIT], 0
.Lsh_have_dir:
        lea rcx, [rsp + SH_FILE]
        mov rdx, rbx
        mov r8d, 2 * K_MAX_PATH
        API lstrcpynW
        mov rsi, rdi                    /* GetSaveFileNameW */
        lea rdi, [rsp + SH_OFN]
        xor eax, eax
        mov ecx, OFN_BYTES / 8
        rep stosq
        mov dword ptr [rsp + SH_OFN + OFN_STRUCTSIZE], OFN_BYTES
        lea rax, [rip + w_filter]
        mov qword ptr [rsp + SH_OFN + OFN_FILTER], rax
        mov dword ptr [rsp + SH_OFN + OFN_FILTERINDEX], 1
        lea rax, [rsp + SH_FILE]
        mov qword ptr [rsp + SH_OFN + OFN_FILE], rax
        mov dword ptr [rsp + SH_OFN + OFN_MAXFILE], 2 * K_MAX_PATH
        xor eax, eax
        lea rdx, [rsp + SH_INIT]
        cmp word ptr [rdx], 0
        cmovne rax, rdx
        mov qword ptr [rsp + SH_OFN + OFN_INITIALDIR], rax
        lea rax, [rip + w_title]
        mov qword ptr [rsp + SH_OFN + OFN_TITLE], rax
        mov dword ptr [rsp + SH_OFN + OFN_FLAGS], K_OFN_FLAGS
        lea rax, [rip + w_png]
        mov qword ptr [rsp + SH_OFN + OFN_DEFEXT], rax
        lea rcx, [rsp + SH_OFN]
        call rsi
        test eax, eax
        jz .Lsh_1
        mov ecx, K_STD_OUTPUT_HANDLE
        API GetStdHandle
        mov rbx, rax
        lea rcx, [rsp + SH_FILE]
        API lstrlenW
        lea r8d, [rax + rax]
        mov rcx, rbx
        lea rdx, [rsp + SH_FILE]
        lea r9, [rsp + SH_N]
        mov qword ptr [rsp + 32], 0
        API WriteFile
        xor eax, eax
        jmp .Lsh_ret
.Lsh_1:
        mov eax, 1
        jmp .Lsh_ret
.Lsh_2:
        mov eax, 2
.Lsh_ret:
        add rsp, 1776
        pop rdi
        pop rsi
        pop rbx
        ret
        ENDF
