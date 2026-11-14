/* asm.inc: conventions shared by every assembly source of sniplite.
 *
 * Toolchain: GNU as through gcc (files end in .S, so the C preprocessor runs
 * first: #include, #define and C comments work). Intel syntax, x86-64, Windows.
 *
 * Calling convention (Windows x64):
 *   integer/pointer arguments: rcx, rdx, r8, r9, then [rsp+40], [rsp+48] ... at entry
 *   float/double arguments:    xmm0-xmm3 in the same positions; results in rax / xmm0
 *   the caller reserves 32 bytes of shadow space above the return address
 *   rsp is 16-byte aligned before every call (so it is 8 mod 16 at function entry)
 *   volatile:     rax, rcx, rdx, r8-r11, xmm0-xmm5
 *   non-volatile: rbx, rbp, rdi, rsi, r12-r15, xmm6-xmm15 (save before use)
 *   structs of 1, 2, 4 or 8 bytes are passed and returned in a register; larger
 *   ones (RECT included) are passed by pointer to a copy, and returned through a
 *   hidden pointer in rcx (the other arguments shift right by one)
 *
 * Every function carries unwind information (.seh_* directives), so a crash or
 * a debugger can walk the stack: start with FUNC (or SFUNC for file-local ones),
 * record each prologue step (PUSHREG, ALLOC, SAVEXMM), close the prologue with
 * ENDPROLOG and the function with ENDF. A function without a prologue still
 * needs ENDPROLOG right after FUNC. Inside the body rsp must not move except in
 * epilogues (add rsp / pop / ret); use the frame for temporaries.
 * Stack frames stay under 4 KB (no __chkstk without the C runtime); bigger
 * buffers go to the heap.
 *
 * No C runtime: never call memcpy, memset, wcslen, sqrtf, ... Use kernel32,
 * user32 etc. (call qword ptr [rip + __imp_Name]), the helpers in util.S, or
 * inline code (rep movsb / rep stosb are fast on every current CPU). */
        .intel_syntax noprefix

/* ---- functions ---------------------------------------------------------------- */

.macro FUNC name                /* exported */
        .section .text$\name,"x"
        .globl \name
        .def \name; .scl 2; .type 32; .endef
        .balign 16
\name:
        .seh_proc \name
.endm

.macro SFUNC name               /* local to the file */
        .section .text$\name,"x"
        .def \name; .scl 3; .type 32; .endef
        .balign 16
\name:
        .seh_proc \name
.endm

.macro PUSHREG r
        push \r
        .seh_pushreg \r
.endm

.macro ALLOC n
        sub rsp, \n
        .seh_stackalloc \n
.endm

.macro SAVEXMM r, off           /* [rsp + off] must be 16-byte aligned */
        movaps xmmword ptr [rsp + \off], \r
        .seh_savexmm \r, \off
.endm

.macro ENDPROLOG
        .seh_endprologue
.endm

.macro ENDF
        .seh_endproc
.endm

/* Call a Windows API function through its import: API MessageBoxW */
.macro API name
        call qword ptr [rip + __imp_\name]
.endm

/* Call a COM method: rcx = interface pointer, slot = index in its vtable
 * (0 QueryInterface, 1 AddRef, 2 Release, then the interface's own methods). */
.macro COM slot
        mov rax, qword ptr [rcx]
        call qword ptr [rax + 8 * \slot]
.endm

/* A GUID in memory: GUIDDEF label, 0x01234567, 0x89AB, 0xCDEF, 0x01, 0x23, ... (8 bytes) */
.macro GUIDDEF name, d1, d2, d3, b0, b1, b2, b3, b4, b5, b6, b7
        .balign 4
\name:  .long \d1
        .short \d2, \d3
        .byte \b0, \b1, \b2, \b3, \b4, \b5, \b6, \b7
.endm

/* UTF-16 text: GNU as has no UTF-16 strings, so text is written as code units
 * with the readable text in a comment above, in .rdata:
 *         / * L"截图" * /
 *   w_capture: .short 0x622A, 0x56FE, 0
 * Generate the lists with a script; never type them by hand. Texts the user reads
 * are not written this way: they come from the language table (lang.inc). */

/* ---- shared constants (common.h, config.h) --------------------------------------- */

#define EXIT_OK 0
#define EXIT_FAIL 1
#define EXIT_USAGE 2
#define EXIT_NOT_RUNNING 3
#define EXIT_NOTHING 4
#define EXIT_HOTKEY 5

#define IPC_REQ 0x4C534E01
#define IPC_REPLY 0x4C534E02
#define IPC_BASE 0x1000
#define IPC_SEP 0x1F

#define WM_APP 0x8000
#define WM_APP_GPU_READY (WM_APP + 1)

#define HK_CAPTURE 1
#define HK_PIN 2
#define HK_TOGGLE 3
#define HK_COUNT 4

/* ---- shared structures ------------------------------------------------------------ */

/* RECT */
#define RC_L 0
#define RC_T 4
#define RC_R 8
#define RC_B 12
#define RC_SIZE 16

/* POINT */
#define PT_X 0
#define PT_Y 4

/* Surf (draw.h): a drawing target */
#define SURF_PX 0
#define SURF_STRIDE 8
#define SURF_OX 12
#define SURF_OY 16
#define SURF_CL 20
#define SURF_CT 24
#define SURF_CR 28
#define SURF_CB 32
#define SURF_SIZE 40

/* Img (common.h): top-down 32bpp DIB in its own memory DC */
#define IMG_BMP 0
#define IMG_DC 8
#define IMG_OLD 16
#define IMG_PX 24
#define IMG_W 32
#define IMG_H 36
#define IMG_SIZE 40

/* Str (common.h): growable UTF-16 string */
#define STR_P 0
#define STR_N 8
#define STR_CAP 12
#define STR_SIZE 16

/* OvTiming (overlay.h): doubles */
#define OVT_TOTAL 0
#define OVT_GRAB 8
#define OVT_WINDOWS 16
#define OVT_PAINT 24
#define OVT_FOCUS 32
#define OVT_SIZE 40

/* ---- floating point without the C runtime (SSE2) --------------------------------------- */

/* dst = (int)floorf(src). Out-of-range values give 0x80000000, like a C cast. */
.macro FLOORI dst, src, tmp
        cvttss2si \dst, \src
        cmp \dst, 0x80000000
        je 99f
        cvtsi2ss \tmp, \dst
        ucomiss \src, \tmp              /* src below its truncation: negative with a fraction */
        sbb \dst, 0
99:
.endm

/* dst = (int)ceilf(src) */
.macro CEILI dst, src, tmp
        cvttss2si \dst, \src
        cmp \dst, 0x80000000
        je 99f
        cvtsi2ss \tmp, \dst
        ucomiss \tmp, \src              /* truncation below src: positive with a fraction */
        adc \dst, 0
99:
.endm

/* dst = lroundf(src): nearest, halfway cases away from zero (not the CPU's
 * round-to-even). tmp is clobbered. Adds +-0.49999997f (the float just below 0.5)
 * and truncates, which is exact for every float (checked against 20 million
 * values; mingw's own lroundf differs only at +-0.49999997, where it is wrong). */
.macro LROUNDF dst, src, tmp
        movd \dst, \src
        and \dst, 0x80000000            /* the sign of src */
        or \dst, 0x3EFFFFFF             /* +-0.49999997f */
        movd \tmp, \dst
        addss \tmp, \src
        cvttss2si \dst, \tmp
.endm
