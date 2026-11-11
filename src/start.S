/* Process entry point (link with -e start). There is no C runtime: the loader
 * jumps here, the program's main function runs, and its result is the process
 * exit code.
 *   default:    wWinMain(module, NULL, NULL, SW_SHOWDEFAULT)   (sniplite.exe, setup)
 *   -DCONSOLE:  wmain(argc, argv), argv split from GetCommandLineW by the same
 *               rules as the C runtime (cmdline_split, util.S)  (sniplite.com) */
#include "asm.inc"

#ifndef CONSOLE
FUNC start
        ALLOC 40
        ENDPROLOG
        xor ecx, ecx
        API GetModuleHandleW
        mov rcx, rax
        xor edx, edx
        xor r8d, r8d
        mov r9d, 10                     /* SW_SHOWDEFAULT */
        call wWinMain
        mov ecx, eax
        API ExitProcess
        int3
ENDF
#else
FUNC start
        ALLOC 56                        /* argc at [rsp+40] */
        ENDPROLOG
        API GetCommandLineW
        mov rcx, rax
        lea rdx, [rsp + 40]
        call cmdline_split
        mov ecx, 1                      /* out of memory: exit code 1 */
        test rax, rax
        jz 1f
        mov rdx, rax
        mov ecx, dword ptr [rsp + 40]
        call wmain
        mov ecx, eax
1:      API ExitProcess
        int3
ENDF
#endif
