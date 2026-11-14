/* util.S: small helpers shared by every module and by the console client
 * (declared in common.h): memory, growable strings, rectangles, command-line
 * splitting, DPI, the Img bitmap. */
#include "asm.inc"

/* Windows values used here */
#define W_HEAP_ZERO_MEMORY 8
#define W_CSTR_EQUAL 2
#define W_MONITOR_DEFAULTTONEAREST 2
#define W_DIB_RGB_COLORS 0
#define BIH_biSize 0
#define BIH_biWidth 4
#define BIH_biHeight 8
#define BIH_biPlanes 12
#define BIH_biBitCount 14
#define BIH_biCompression 16
#define SIZEOF_BITMAPINFOHEADER 40
#define SIZEOF_BITMAPINFO 44
#define IMG_MAX_PIXELS 0x10000000       /* 1 << 28 */

        .section .bss$util,"bw"
        .balign 8
.Lfreq:         .space 8                /* QueryPerformanceFrequency, 0 = not read yet */
.Lget_dpi:      .space 8                /* GetDpiForMonitor from shcore.dll, or 0 */
.Ltried:        .space 1                /* shcore.dll looked up */

/* ---- memory --------------------------------------------------------------------- */

/* void *mem_alloc(size_t n): zero-filled, NULL on failure */
FUNC mem_alloc
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        API GetProcessHeap
        mov rcx, rax
        mov edx, W_HEAP_ZERO_MEMORY
        mov r8d, 1                      /* n ? n : 1 */
        test rbx, rbx
        cmovnz r8, rbx
        add rsp, 32
        pop rbx
        jmp qword ptr [rip + __imp_HeapAlloc]
ENDF

/* void *mem_grow(void *p, size_t n): realloc, new tail zero-filled */
FUNC mem_grow
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 40
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        test rcx, rcx
        jz .Lmg_new
        API GetProcessHeap
        mov rcx, rax
        mov edx, W_HEAP_ZERO_MEMORY
        mov r8, rbx
        mov r9d, 1                      /* n ? n : 1 */
        test rsi, rsi
        cmovnz r9, rsi
        add rsp, 40
        pop rsi
        pop rbx
        jmp qword ptr [rip + __imp_HeapReAlloc]
.Lmg_new:
        mov rcx, rsi
        add rsp, 40
        pop rsi
        pop rbx
        jmp mem_alloc
ENDF

/* void mem_free(void *p) */
FUNC mem_free
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        test rcx, rcx
        jz .Lmf_ret
        mov rbx, rcx
        API GetProcessHeap
        mov rcx, rax
        xor edx, edx
        mov r8, rbx
        add rsp, 32
        pop rbx
        jmp qword ptr [rip + __imp_HeapFree]
.Lmf_ret:
        add rsp, 32
        pop rbx
        ret
ENDF

/* WCHAR *wcs_dup(const WCHAR *s, int n): n < 0 copies up to the terminator */
FUNC wcs_dup
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rsi, rcx
        movsxd rbx, edx
        test edx, edx
        jns .Lwd_alloc
        mov rax, rcx                    /* n = (int)wcslen(s) */
.Lwd_len:
        cmp word ptr [rax], 0
        je .Lwd_end
        add rax, 2
        jmp .Lwd_len
.Lwd_end:
        sub rax, rsi
        shr rax, 1
        movsxd rbx, eax
.Lwd_alloc:
        lea rcx, [rbx*2 + 2]            /* ((size_t)n + 1) * sizeof(WCHAR) */
        call mem_alloc
        test rax, rax
        jz .Lwd_ret
        mov rdi, rax
        lea rcx, [rbx + rbx]
        rep movsb
.Lwd_ret:
        add rsp, 32
        pop rbx
        pop rdi
        pop rsi
        ret
ENDF

/* double now_ms(void) */
        .section .rdata$now_ms,"dr"
        .balign 8
.Ld_1000:       .quad 0x408F400000000000        /* 1000.0 */

FUNC now_ms
        ALLOC 40
        ENDPROLOG
        cmp qword ptr [rip + .Lfreq], 0
        jne .Lnm_count
        lea rcx, [rip + .Lfreq]
        API QueryPerformanceFrequency
.Lnm_count:
        lea rcx, [rsp + 32]
        API QueryPerformanceCounter
        pxor xmm0, xmm0
        cvtsi2sd xmm0, qword ptr [rsp + 32]
        mulsd xmm0, qword ptr [rip + .Ld_1000]
        pxor xmm1, xmm1
        cvtsi2sd xmm1, qword ptr [rip + .Lfreq]
        divsd xmm0, xmm1
        add rsp, 40
        ret
ENDF

/* ---- RECT (returned through the hidden pointer in rcx, arguments by pointer) ------ */

/* RECT rect_isect(RECT a, RECT b): rcx = result, rdx = &a, r8 = &b */
FUNC rect_isect
        ENDPROLOG
        mov eax, dword ptr [rdx + RC_L]
        mov r9d, dword ptr [rdx + RC_T]
        mov r10d, dword ptr [rdx + RC_R]
        mov r11d, dword ptr [rdx + RC_B]
        mov edx, dword ptr [r8 + RC_L]
        cmp eax, edx
        cmovl eax, edx                  /* left = max */
        mov edx, dword ptr [r8 + RC_T]
        cmp r9d, edx
        cmovl r9d, edx                  /* top = max */
        mov edx, dword ptr [r8 + RC_R]
        cmp r10d, edx
        cmovg r10d, edx                 /* right = min */
        mov edx, dword ptr [r8 + RC_B]
        cmp r11d, edx
        cmovg r11d, edx                 /* bottom = min */
        cmp r10d, eax
        jle .Lri_empty
        cmp r11d, r9d
        jle .Lri_empty
        mov dword ptr [rcx + RC_L], eax
        mov dword ptr [rcx + RC_T], r9d
        mov dword ptr [rcx + RC_R], r10d
        mov dword ptr [rcx + RC_B], r11d
        mov rax, rcx
        ret
.Lri_empty:
        xor eax, eax
        mov qword ptr [rcx + RC_L], rax
        mov qword ptr [rcx + RC_R], rax
        mov rax, rcx
        ret
ENDF

/* RECT rect_union(RECT a, RECT b): empty inputs are ignored */
FUNC rect_union
        ENDPROLOG
        mov eax, dword ptr [rdx + RC_R]
        cmp eax, dword ptr [rdx + RC_L]
        jle .Lru_b                      /* a empty: b */
        mov eax, dword ptr [rdx + RC_B]
        cmp eax, dword ptr [rdx + RC_T]
        jle .Lru_b
        mov eax, dword ptr [r8 + RC_R]
        cmp eax, dword ptr [r8 + RC_L]
        jle .Lru_a                      /* b empty: a */
        mov eax, dword ptr [r8 + RC_B]
        cmp eax, dword ptr [r8 + RC_T]
        jle .Lru_a
        mov eax, dword ptr [rdx + RC_L]
        mov r9d, dword ptr [rdx + RC_T]
        mov r10d, dword ptr [rdx + RC_R]
        mov r11d, dword ptr [rdx + RC_B]
        mov edx, dword ptr [r8 + RC_L]
        cmp eax, edx
        cmovg eax, edx                  /* left = min */
        mov edx, dword ptr [r8 + RC_T]
        cmp r9d, edx
        cmovg r9d, edx                  /* top = min */
        mov edx, dword ptr [r8 + RC_R]
        cmp r10d, edx
        cmovl r10d, edx                 /* right = max */
        mov edx, dword ptr [r8 + RC_B]
        cmp r11d, edx
        cmovl r11d, edx                 /* bottom = max */
        mov dword ptr [rcx + RC_L], eax
        mov dword ptr [rcx + RC_T], r9d
        mov dword ptr [rcx + RC_R], r10d
        mov dword ptr [rcx + RC_B], r11d
        mov rax, rcx
        ret
.Lru_a:
        mov r8, rdx
.Lru_b:
        movdqu xmm0, xmmword ptr [r8]
        movdqu xmmword ptr [rcx], xmm0
        mov rax, rcx
        ret
ENDF

/* RECT rect_inflate(RECT r, int d): rcx = result, rdx = &r, r8d = d */
FUNC rect_inflate
        ENDPROLOG
        mov eax, dword ptr [rdx + RC_L]
        mov r9d, dword ptr [rdx + RC_T]
        mov r10d, dword ptr [rdx + RC_R]
        mov r11d, dword ptr [rdx + RC_B]
        cmp r10d, eax
        jle .Lrf_store                  /* empty: unchanged */
        cmp r11d, r9d
        jle .Lrf_store
        sub eax, r8d
        sub r9d, r8d
        add r10d, r8d
        add r11d, r8d
.Lrf_store:
        mov dword ptr [rcx + RC_L], eax
        mov dword ptr [rcx + RC_T], r9d
        mov dword ptr [rcx + RC_R], r10d
        mov dword ptr [rcx + RC_B], r11d
        mov rax, rcx
        ret
ENDF

/* RECT rect_corners(POINT a, POINT b): POINTs come by value, rdx = a, r8 = b
 * (x in the low half, y in the high half). Two inclusive corners -> half-open rect. */
FUNC rect_corners
        ENDPROLOG
        mov rax, rdx
        shr rax, 32                     /* a.y */
        mov r9, r8
        shr r9, 32                      /* b.y */
        mov r10d, edx                   /* min x */
        cmp r10d, r8d
        cmovg r10d, r8d
        cmp edx, r8d                    /* max x */
        cmovl edx, r8d
        mov r11d, eax                   /* min y */
        cmp r11d, r9d
        cmovg r11d, r9d
        cmp eax, r9d                    /* max y */
        cmovl eax, r9d
        inc edx
        inc eax
        mov dword ptr [rcx + RC_L], r10d
        mov dword ptr [rcx + RC_T], r11d
        mov dword ptr [rcx + RC_R], edx
        mov dword ptr [rcx + RC_B], eax
        mov rax, rcx
        ret
ENDF

/* ---- Str ---------------------------------------------------------------------------- */

        .section .rdata$util_str,"dr"
        .balign 2
/* L"\"" */
.Lw_quote:      .short 0x0022, 0x0000
/* L"\\" */
.Lw_bs:         .short 0x005C, 0x0000
/* L"\\n" */
.Lw_esc_n:      .short 0x005C, 0x006E, 0x0000
/* L"\\r" */
.Lw_esc_r:      .short 0x005C, 0x0072, 0x0000
/* L"\\t" */
.Lw_esc_t:      .short 0x005C, 0x0074, 0x0000
/* L"%d.%d" */
.Lw_ms_fmt:     .short 0x0025, 0x0064, 0x002E, 0x0025, 0x0064, 0x0000
.Lhex:          .ascii "0123456789abcdef"
        .balign 8
.Ld_10:         .quad 0x4024000000000000        /* 10.0 */
.Ld_half:       .quad 0x3FE0000000000000        /* 0.5 */

/* void str_addn(Str *s, const WCHAR *t, int n): nothing when n <= 0 or out of memory */
FUNC str_addn
        PUSHREG rbx
        PUSHREG rsi
        PUSHREG rdi
        PUSHREG r12
        ALLOC 40                        /* [rsp + 32]: the new capacity */
        ENDPROLOG
        test r8d, r8d
        jle .Lsn_ret
        mov rbx, rcx
        mov rsi, rdx
        mov r12d, r8d
        mov eax, dword ptr [rcx + STR_N]
        lea eax, [rax + r8 + 1]         /* needed: s->n + n + 1 */
        mov edx, dword ptr [rcx + STR_CAP]
        cmp eax, edx
        jle .Lsn_copy
        add edx, edx                    /* cap = MAXI(64, cap * 2), doubled until it fits */
        mov ecx, 64
        cmp edx, ecx
        cmovl edx, ecx
.Lsn_double:
        cmp edx, eax
        jge .Lsn_grow
        add edx, edx
        jmp .Lsn_double
.Lsn_grow:
        mov dword ptr [rsp + 32], edx
        mov rcx, qword ptr [rbx + STR_P]
        movsxd rdx, edx
        add rdx, rdx
        call mem_grow
        test rax, rax
        jz .Lsn_ret
        mov qword ptr [rbx + STR_P], rax
        mov ecx, dword ptr [rsp + 32]
        mov dword ptr [rbx + STR_CAP], ecx
.Lsn_copy:
        movsxd rax, dword ptr [rbx + STR_N]
        mov rdi, qword ptr [rbx + STR_P]
        lea rdi, [rdi + rax*2]
        movsxd rcx, r12d
        add rcx, rcx
        rep movsb
        mov word ptr [rdi], 0
        add dword ptr [rbx + STR_N], r12d
.Lsn_ret:
        add rsp, 40
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void str_add(Str *s, const WCHAR *t) */
FUNC str_add
        ENDPROLOG
        mov rax, rdx
.Lsa_len:
        cmp word ptr [rax], 0
        je .Lsa_end
        add rax, 2
        jmp .Lsa_len
.Lsa_end:
        sub rax, rdx
        shr rax, 1
        mov r8d, eax                    /* (int)wcslen(t) */
        jmp str_addn
ENDF

/* void str_addf(Str *s, const WCHAR *fmt, ...): wvsprintfW, at most 1024 characters */
#define SAF_FRAME 2096                  /* 32 shadow + WCHAR buf[1025], rounded */
FUNC str_addf
        mov qword ptr [rsp + 16], rdx   /* the register arguments go to their home */
        mov qword ptr [rsp + 24], r8    /* slots, so the variadic ones are contiguous */
        mov qword ptr [rsp + 32], r9
        PUSHREG rbx
        ALLOC SAF_FRAME
        ENDPROLOG
        mov rbx, rcx
        lea rcx, [rsp + 32]
        lea r8, [rsp + SAF_FRAME + 8 + 24]      /* va_list: the first variadic slot */
        API wvsprintfW
        test eax, eax
        jle .Lsf_ret
        mov r8d, eax
        mov rcx, rbx
        lea rdx, [rsp + 32]
        call str_addn
.Lsf_ret:
        add rsp, SAF_FRAME
        pop rbx
        ret
ENDF

/* void str_add_ms(Str *s, double ms): "12.3"; ms comes in xmm1 */
FUNC str_add_ms
        ENDPROLOG
        mulsd xmm1, qword ptr [rip + .Ld_10]
        addsd xmm1, qword ptr [rip + .Ld_half]
        cvttsd2si eax, xmm1             /* t = (int)(ms * 10.0 + 0.5) */
        xor edx, edx
        test eax, eax
        cmovs eax, edx                  /* t < 0: 0 */
        mov r10d, 10
        div r10d
        mov r8d, eax                    /* t / 10 */
        mov r9d, edx                    /* t % 10 */
        lea rdx, [rip + .Lw_ms_fmt]
        jmp str_addf
ENDF

/* void str_add_json(Str *s, const WCHAR *t): quoted JSON string, non-ASCII as \uXXXX */
FUNC str_add_json
        PUSHREG rbx
        PUSHREG rsi
        ALLOC 56                        /* [rsp + 32]: up to 6 WCHARs of escape */
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        lea rdx, [rip + .Lw_quote]
        mov r8d, 1
        call str_addn
.Lsj_loop:
        movzx eax, word ptr [rsi]
        test eax, eax
        jz .Lsj_end
        lea rdx, [rsp + 32]
        cmp eax, 0x22                   /* " */
        je .Lsj_esc
        cmp eax, 0x5C                   /* backslash */
        je .Lsj_esc
        lea rdx, [rip + .Lw_esc_n]
        cmp eax, 0x0A
        je .Lsj_two
        lea rdx, [rip + .Lw_esc_r]
        cmp eax, 0x0D
        je .Lsj_two
        lea rdx, [rip + .Lw_esc_t]
        cmp eax, 0x09
        je .Lsj_two
        lea rdx, [rsp + 32]
        mov word ptr [rsp + 32], ax
        mov r8d, 1
        cmp eax, 0x20
        jb .Lsj_hex
        cmp eax, 0x7E
        jbe .Lsj_add                    /* printable ASCII: itself */
.Lsj_hex:                               /* what wvsprintfW makes of L"\\u%04x" */
        mov dword ptr [rsp + 32], 0x0075005C    /* \u */
        lea r9, [rip + .Lhex]
        mov ecx, eax
        shr ecx, 12
        movzx ecx, byte ptr [r9 + rcx]
        mov word ptr [rsp + 36], cx
        mov ecx, eax
        shr ecx, 8
        and ecx, 15
        movzx ecx, byte ptr [r9 + rcx]
        mov word ptr [rsp + 38], cx
        mov ecx, eax
        shr ecx, 4
        and ecx, 15
        movzx ecx, byte ptr [r9 + rcx]
        mov word ptr [rsp + 40], cx
        and eax, 15
        movzx ecx, byte ptr [r9 + rax]
        mov word ptr [rsp + 42], cx
        mov r8d, 6
        jmp .Lsj_add
.Lsj_esc:                               /* backslash, then the character */
        mov word ptr [rsp + 32], 0x5C
        mov word ptr [rsp + 34], ax
.Lsj_two:
        mov r8d, 2
.Lsj_add:
        mov rcx, rbx
        call str_addn
        add rsi, 2
        jmp .Lsj_loop
.Lsj_end:
        mov rcx, rbx
        lea rdx, [rip + .Lw_quote]
        mov r8d, 1
        call str_addn
        add rsp, 56
        pop rsi
        pop rbx
        ret
ENDF

/* void str_add_quoted(Str *s, const WCHAR *a): one command-line argument, MSVC quoting */
FUNC str_add_quoted
        PUSHREG rbx                     /* s */
        PUSHREG rsi                     /* p */
        PUSHREG rdi                     /* pending backslashes */
        PUSHREG r12                     /* counter */
        ALLOC 40
        ENDPROLOG
        mov rbx, rcx
        mov rsi, rdx
        lea rdx, [rip + .Lw_quote]
        mov r8d, 1
        call str_addn
        xor edi, edi
.Lsq_loop:
        movzx eax, word ptr [rsi]
        test eax, eax
        jz .Lsq_end
        cmp eax, 0x5C                   /* backslash: count it */
        jne .Lsq_char
        inc edi
        add rsi, 2
        jmp .Lsq_loop
.Lsq_char:
        mov r12d, edi                   /* bs, or bs * 2 + 1 before a quote */
        cmp eax, 0x22
        jne .Lsq_bs
        lea r12d, [rdi + rdi + 1]
.Lsq_bs:
        test r12d, r12d
        jle .Lsq_put
.Lsq_bs_loop:
        mov rcx, rbx
        lea rdx, [rip + .Lw_bs]
        mov r8d, 1
        call str_addn
        dec r12d
        jnz .Lsq_bs_loop
.Lsq_put:
        xor edi, edi
        mov rcx, rbx
        mov rdx, rsi
        mov r8d, 1
        call str_addn
        add rsi, 2
        jmp .Lsq_loop
.Lsq_end:                               /* backslashes before the closing quote are doubled */
        lea r12d, [rdi + rdi]
        test r12d, r12d
        jle .Lsq_close
.Lsq_end_loop:
        mov rcx, rbx
        lea rdx, [rip + .Lw_bs]
        mov r8d, 1
        call str_addn
        dec r12d
        jnz .Lsq_end_loop
.Lsq_close:
        mov rcx, rbx
        lea rdx, [rip + .Lw_quote]
        mov r8d, 1
        call str_addn
        add rsp, 40
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void str_free(Str *s) */
FUNC str_free
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        mov rcx, qword ptr [rcx + STR_P]
        call mem_free
        xor eax, eax
        mov qword ptr [rbx + STR_P], rax
        mov dword ptr [rbx + STR_N], eax
        mov dword ptr [rbx + STR_CAP], eax
        add rsp, 32
        pop rbx
        ret
ENDF

/* ---- command line ------------------------------------------------------------------ */

/* WCHAR **cmdline_split(const WCHAR *cmd, int *argc): MSVC rules. One block holds
 * len / 2 + 2 pointers, then the strings. */
FUNC cmdline_split
        PUSHREG rbx                     /* argv */
        PUSHREG rsi                     /* p */
        PUSHREG rdi                     /* out */
        PUSHREG r12                     /* argc */
        PUSHREG r13                     /* maxargs, then n */
        ALLOC 32
        ENDPROLOG
        mov rsi, rcx
        mov r12, rdx
        mov rax, rcx                    /* len = wcslen(cmd) */
.Lcs_len:
        cmp word ptr [rax], 0
        je .Lcs_len_end
        add rax, 2
        jmp .Lcs_len
.Lcs_len_end:
        sub rax, rcx
        shr rax, 1
        mov ecx, eax                    /* maxargs = (int)len / 2 + 2 */
        mov edx, ecx
        shr edx, 31
        add ecx, edx
        sar ecx, 1
        add ecx, 2
        movsxd r13, ecx
        lea rcx, [rax + r13]            /* maxargs * 8 + (len + maxargs) * 2 */
        add rcx, rcx
        lea rcx, [rcx + r13*8]
        call mem_alloc
        test rax, rax
        jnz .Lcs_ok
        mov dword ptr [r12], 0
        jmp .Lcs_ret
.Lcs_ok:
        mov rbx, rax
        lea rdi, [rax + r13*8]
        xor r13d, r13d
        /* argv[0]: quotes delimit, backslashes are literal */
.Lcs_skip0:
        movzx eax, word ptr [rsi]
        cmp eax, 0x20
        je .Lcs_skip0_next
        cmp eax, 0x09
        jne .Lcs_skip0_end
.Lcs_skip0_next:
        add rsi, 2
        jmp .Lcs_skip0
.Lcs_skip0_end:
        test eax, eax
        jz .Lcs_next
        mov qword ptr [rbx + r13*8], rdi
        inc r13d
        cmp eax, 0x22
        jne .Lcs_plain0
        add rsi, 2
.Lcs_quoted0:
        movzx eax, word ptr [rsi]
        test eax, eax
        jz .Lcs_end0
        cmp eax, 0x22
        je .Lcs_close0
        mov word ptr [rdi], ax
        add rdi, 2
        add rsi, 2
        jmp .Lcs_quoted0
.Lcs_close0:
        add rsi, 2
        jmp .Lcs_end0
.Lcs_plain0:
        movzx eax, word ptr [rsi]
        test eax, eax
        jz .Lcs_end0
        cmp eax, 0x20
        je .Lcs_end0
        cmp eax, 0x09
        je .Lcs_end0
        mov word ptr [rdi], ax
        add rdi, 2
        add rsi, 2
        jmp .Lcs_plain0
.Lcs_end0:
        mov word ptr [rdi], 0
        add rdi, 2
        /* the other arguments */
.Lcs_next:
        movzx eax, word ptr [rsi]
        cmp eax, 0x20
        je .Lcs_next_skip
        cmp eax, 0x09
        jne .Lcs_next_start
.Lcs_next_skip:
        add rsi, 2
        jmp .Lcs_next
.Lcs_next_start:
        test eax, eax
        jz .Lcs_done
        mov qword ptr [rbx + r13*8], rdi
        inc r13d
        xor r8d, r8d                    /* quoted */
.Lcs_char:
        movzx eax, word ptr [rsi]
        test eax, eax
        jz .Lcs_arg_end
        test r8d, r8d
        jnz .Lcs_inside
        cmp eax, 0x20
        je .Lcs_arg_end
        cmp eax, 0x09
        je .Lcs_arg_end
.Lcs_inside:
        cmp eax, 0x5C
        je .Lcs_bslash
        cmp eax, 0x22
        je .Lcs_quote
        mov word ptr [rdi], ax
        add rdi, 2
        add rsi, 2
        jmp .Lcs_char
.Lcs_bslash:                            /* a run of backslashes */
        xor edx, edx
.Lcs_bs_count:
        inc edx
        add rsi, 2
        cmp word ptr [rsi], 0x5C
        je .Lcs_bs_count
        mov eax, 0x5C
        cmp word ptr [rsi], 0x22
        jne .Lcs_bs_literal
        mov ecx, edx                    /* before a quote: half of them */
        shr ecx, 1
        rep stosw
        test edx, 1
        jz .Lcs_char                    /* even: the quote is processed next */
        mov word ptr [rdi], 0x22        /* odd: a literal quote */
        add rdi, 2
        add rsi, 2
        jmp .Lcs_char
.Lcs_bs_literal:
        mov ecx, edx
        rep stosw
        jmp .Lcs_char
.Lcs_quote:
        test r8d, r8d
        jz .Lcs_toggle
        cmp word ptr [rsi + 2], 0x22
        jne .Lcs_toggle
        mov word ptr [rdi], 0x22        /* "" inside quotes: one literal quote */
        add rdi, 2
        add rsi, 4
        jmp .Lcs_char
.Lcs_toggle:
        xor r8d, 1
        add rsi, 2
        jmp .Lcs_char
.Lcs_arg_end:
        mov word ptr [rdi], 0
        add rdi, 2
        jmp .Lcs_next
.Lcs_done:
        mov dword ptr [r12], r13d
        mov rax, rbx
.Lcs_ret:
        add rsp, 32
        pop r13
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* bool arg_eq(const WCHAR *a, const WCHAR *b): case-insensitive */
FUNC arg_eq
        ALLOC 40
        ENDPROLOG
        mov r8, rdx
        mov edx, -1
        mov r9d, -1
        mov dword ptr [rsp + 32], 1     /* bIgnoreCase */
        API CompareStringOrdinal
        xor ecx, ecx
        cmp eax, W_CSTR_EQUAL
        sete cl
        mov eax, ecx
        add rsp, 40
        ret
ENDF

/* ---- DPI ------------------------------------------------------------------------------ */

        .section .rdata$util_dpi,"dr"
        .balign 4
.Lf_96:         .long 0x42C00000                /* 96.0f */
/* L"shcore.dll" */
.Lw_shcore:     .short 0x0073, 0x0068, 0x0063, 0x006F, 0x0072, 0x0065, 0x002E, 0x0064, 0x006C, 0x006C, 0x0000
.La_get_dpi:    .asciz "GetDpiForMonitor"

/* float dpi_scale_of(HMONITOR mon): 1.0 = 96 dpi */
FUNC dpi_scale_of
        PUSHREG rbx
        ALLOC 48                        /* [rsp + 32]: x, [rsp + 36]: y */
        ENDPROLOG
        mov rbx, rcx
        cmp byte ptr [rip + .Ltried], 0
        jne .Lds_query
        mov byte ptr [rip + .Ltried], 1
        lea rcx, [rip + .Lw_shcore]
        API LoadLibraryW
        test rax, rax
        jz .Lds_query
        mov rcx, rax
        lea rdx, [rip + .La_get_dpi]
        API GetProcAddress
        mov qword ptr [rip + .Lget_dpi], rax
.Lds_query:
        mov qword ptr [rsp + 32], 0
        mov rax, qword ptr [rip + .Lget_dpi]
        test rax, rax
        jz .Lds_system
        test rbx, rbx
        jz .Lds_system
        mov rcx, rbx
        xor edx, edx                    /* MDT_EFFECTIVE_DPI */
        lea r8, [rsp + 32]
        lea r9, [rsp + 36]
        call rax
        test eax, eax
        js .Lds_system                  /* FAILED(hr) */
        mov eax, dword ptr [rsp + 32]
        test eax, eax
        jnz .Lds_scale
.Lds_system:
        API GetDpiForSystem
        mov eax, eax
.Lds_scale:
        pxor xmm0, xmm0
        cvtsi2ss xmm0, rax              /* (float)x, x unsigned */
        divss xmm0, dword ptr [rip + .Lf_96]
        add rsp, 48
        pop rbx
        ret
ENDF

/* float dpi_scale_at(POINT pt): pt comes by value in rcx */
FUNC dpi_scale_at
        ALLOC 40
        ENDPROLOG
        mov edx, W_MONITOR_DEFAULTTONEAREST
        API MonitorFromPoint
        mov rcx, rax
        add rsp, 40
        jmp dpi_scale_of
ENDF

/* ---- Img ------------------------------------------------------------------------------ */

/* bool img_create(Img *im, int w, int h): top-down 32bpp DIB in its own memory DC */
FUNC img_create
        PUSHREG rbx                     /* im */
        PUSHREG rsi                     /* w */
        PUSHREG rdi                     /* h */
        ALLOC 112                       /* [rsp + 48]: BITMAPINFO, [rsp + 96]: bits */
        ENDPROLOG
        mov rbx, rcx
        mov esi, edx
        mov edi, r8d
        xorps xmm0, xmm0
        movups xmmword ptr [rcx], xmm0  /* memset(im, 0, sizeof *im) */
        movups xmmword ptr [rcx + 16], xmm0
        mov qword ptr [rcx + 32], 0
        xor eax, eax
        test esi, esi
        jle .Lic_ret
        test edi, edi
        jle .Lic_ret
        movsxd rcx, esi
        movsxd rdx, edi
        imul rcx, rdx
        cmp rcx, IMG_MAX_PIXELS
        jg .Lic_ret
        movups xmmword ptr [rsp + 48], xmm0     /* bi = {0} */
        movups xmmword ptr [rsp + 64], xmm0
        movups xmmword ptr [rsp + 76], xmm0     /* up to byte 92: all 44 bytes */
        mov dword ptr [rsp + 48 + BIH_biSize], SIZEOF_BITMAPINFOHEADER
        mov dword ptr [rsp + 48 + BIH_biWidth], esi
        mov eax, edi
        neg eax
        mov dword ptr [rsp + 48 + BIH_biHeight], eax    /* top-down */
        mov word ptr [rsp + 48 + BIH_biPlanes], 1
        mov word ptr [rsp + 48 + BIH_biBitCount], 32
        mov qword ptr [rsp + 96], 0     /* bits = NULL */
        xor ecx, ecx
        lea rdx, [rsp + 48]
        mov r8d, W_DIB_RGB_COLORS
        lea r9, [rsp + 96]
        mov qword ptr [rsp + 32], 0     /* hSection */
        mov qword ptr [rsp + 40], 0     /* offset */
        API CreateDIBSection
        mov qword ptr [rbx + IMG_BMP], rax
        test rax, rax
        jz .Lic_fail
        xor ecx, ecx
        API CreateCompatibleDC
        mov qword ptr [rbx + IMG_DC], rax
        test rax, rax
        jnz .Lic_select
        mov rcx, qword ptr [rbx + IMG_BMP]
        API DeleteObject
        mov qword ptr [rbx + IMG_BMP], 0
.Lic_fail:
        xor eax, eax
        jmp .Lic_ret
.Lic_select:
        mov rcx, rax
        mov rdx, qword ptr [rbx + IMG_BMP]
        API SelectObject
        mov qword ptr [rbx + IMG_OLD], rax
        mov rax, qword ptr [rsp + 96]
        mov qword ptr [rbx + IMG_PX], rax
        mov dword ptr [rbx + IMG_W], esi
        mov dword ptr [rbx + IMG_H], edi
        mov eax, 1
.Lic_ret:
        add rsp, 112
        pop rdi
        pop rsi
        pop rbx
        ret
ENDF

/* void img_destroy(Img *im) */
FUNC img_destroy
        PUSHREG rbx
        ALLOC 32
        ENDPROLOG
        mov rbx, rcx
        mov rcx, qword ptr [rcx + IMG_DC]
        test rcx, rcx
        jz .Lid_bmp
        mov rdx, qword ptr [rbx + IMG_OLD]
        API SelectObject
        mov rcx, qword ptr [rbx + IMG_DC]
        API DeleteDC
.Lid_bmp:
        mov rcx, qword ptr [rbx + IMG_BMP]
        test rcx, rcx
        jz .Lid_clear
        API DeleteObject
.Lid_clear:
        xorps xmm0, xmm0
        movups xmmword ptr [rbx], xmm0
        movups xmmword ptr [rbx + 16], xmm0
        mov qword ptr [rbx + 32], 0
        add rsp, 32
        pop rbx
        ret
ENDF
