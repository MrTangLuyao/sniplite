/* sniplite.com: console front end. Starts the background process when needed,
 * forwards the command, prints the reply and returns its exit code. */
#include "common.h"
#include "update.h"

static const WCHAR kHelp[] =
    L"sniplite " SNIPLITE_VERSION L"：又快又轻的截图工具\n"
    L"\n"
    L"  sniplite                     启动（已启动就看状态）\n"
    L"  sniplite capture             开始截图，和按 F1 一样\n"
    L"  sniplite capture --full --out a.png        整个屏幕存成文件\n"
    L"  sniplite capture --rect 0,0,800,600        截这块区域到剪贴板\n"
    L"  sniplite pin [图片]          贴到屏幕，不给图片就贴剪贴板\n"
    L"  sniplite settings            打开首选项\n"
    L"  sniplite update              检查更新，加 --install 直接装上新版本\n"
    L"  sniplite status              看状态\n"
    L"  sniplite quit                退出\n"
    L"\n"
    L"小提示：\n"
    L"  capture 还能加 --clip（复制）、--pin（贴图），可以一起用\n"
    L"  start 可以临时换热键：--hotkey Ctrl+Alt+A（另有 --pin-hotkey、--toggle-hotkey）\n"
    L"  start --gdi 用省内存的截屏方式，--dxgi 换回最快的\n"
    L"  任何命令加 --json，输出给程序读\n"
    L"\n"
    L"退出码：0 成功，1 失败，2 参数不对，3 没在运行，4 没东西可贴，5 热键被占用\n";

static void print(const WCHAR *s, bool err)
{
    HANDLE h = GetStdHandle(err ? STD_ERROR_HANDLE : STD_OUTPUT_HANDLE);
    int n = lstrlenW(s);
    DWORD mode, w;
    if (!n || !h || h == INVALID_HANDLE_VALUE)
        return;
    if (GetConsoleMode(h, &mode)) { /* a real console: UTF-16 straight through, any code page */
        WriteConsoleW(h, s, (DWORD)n, &w, NULL);
        return;
    }
    int bn = WideCharToMultiByte(CP_UTF8, 0, s, n, NULL, 0, NULL, NULL); /* pipes and files get UTF-8 */
    char *b = bn > 0 ? mem_alloc((size_t)bn) : NULL;
    if (!b)
        return;
    WideCharToMultiByte(CP_UTF8, 0, s, n, b, bn, NULL, NULL);
    WriteFile(h, b, (DWORD)bn, &w, NULL);
    mem_free(b);
}

static bool has_json(int argc, WCHAR **argv)
{
    for (int i = 1; i < argc; i++)
        if (arg_eq(argv[i], L"--json"))
            return true;
    return false;
}

static HWND spawn_daemon(int argc, WCHAR **argv, bool is_start)
{
    WCHAR exe[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, exe, MAX_PATH);
    WCHAR *dot = n ? wcsrchr(exe, L'.') : NULL;
    if (!dot || dot - exe + 4 >= MAX_PATH)
        return NULL;
    lstrcpyW(dot, L".exe");
    if (GetFileAttributesW(exe) == INVALID_FILE_ATTRIBUTES) {
        print(L"找不到 sniplite.exe，它必须和 sniplite.com 放在同一个文件夹里\n", true);
        return NULL;
    }
    Str cmd = {0};
    str_add_quoted(&cmd, exe);
    str_add(&cmd, L" --daemon");
    if (is_start) /* so --gdi / hotkeys apply before anything is loaded */
        for (int i = 0; i < argc; i++) {
            str_add(&cmd, L" ");
            str_add_quoted(&cmd, argv[i]);
        }
    STARTUPINFOW si = {sizeof si};
    PROCESS_INFORMATION pi;
    /* Break away from the terminal's job object, if allowed, so closing the terminal keeps it running. */
    BOOL ok = cmd.p && CreateProcessW(exe, cmd.p, NULL, NULL, FALSE, CREATE_BREAKAWAY_FROM_JOB, NULL, NULL, &si, &pi);
    if (!ok && cmd.p)
        ok = CreateProcessW(exe, cmd.p, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi);
    str_free(&cmd);
    if (!ok) {
        print(L"无法启动 sniplite.exe\n", true);
        return NULL;
    }
    HWND d = NULL;
    for (int i = 0; i < 1000 && !(d = ipc_find()); i++)
        if (WaitForSingleObject(pi.hProcess, 5) == WAIT_OBJECT_0) {
            d = ipc_find(); /* lost a start race against another instance */
            break;
        }
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    if (!d)
        print(L"sniplite.exe 没有正常启动\n", true);
    return d;
}

/* `sniplite update [--install] [--json]`: runs here, no background process needed. */
static int cmd_update(int ac, WCHAR **av, bool json)
{
    bool install = false;
    for (int i = 1; i < ac; i++) {
        if (arg_eq(av[i], L"--install")) {
            install = true;
        } else if (!arg_eq(av[i], L"--json")) {
            print(L"用法：sniplite update [--install] [--json]\n", true);
            return EXIT_USAGE;
        }
    }
    static const WCHAR *kState[] = {L"error", L"none", L"latest", L"newer"};
    UpdateResult r;
    update_check(&r);
    bool installed = false;
    int code = r.state == UPD_ERROR ? EXIT_FAIL : EXIT_OK;
    bool portable = r.state == UPD_NEWER && !update_installed_copy(); /* the installer would not touch it */
    if (portable && install) {
        code = EXIT_FAIL;
    } else if (install && r.state == UPD_NEWER) {
        WCHAR setup[MAX_PATH];
        if (!json)
            print(L"正在下载新版本...\n", false);
        code = EXIT_FAIL;
        if (update_download(r.tag, setup, MAX_PATH, NULL, NULL)) {
            Str cmd = {0};
            str_add_quoted(&cmd, setup);
            str_add(&cmd, L" /update");
            STARTUPINFOW si = {sizeof si};
            PROCESS_INFORMATION pi;
            if (cmd.p && CreateProcessW(setup, cmd.p, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
                DWORD rc = 1;
                WaitForSingleObject(pi.hProcess, 120000);
                if (GetExitCodeProcess(pi.hProcess, &rc) && rc == 0) {
                    installed = true;
                    code = EXIT_OK;
                }
                CloseHandle(pi.hThread);
                CloseHandle(pi.hProcess);
            }
            str_free(&cmd);
            DeleteFileW(setup);
        }
    }
    Str out = {0};
    if (json) {
        str_addf(&out, L"{\"state\":\"%s\",\"current\":\"%s\",\"latest\":\"%s\"", kState[r.state],
                 SNIPLITE_VERSION, r.tag);
        if (portable)
            str_add(&out, L",\"portable\":true");
        if (install)
            str_addf(&out, L",\"installed\":%s", installed ? L"true" : L"false");
        str_add(&out, L"}\n");
    } else if (installed) {
        str_addf(&out, L"已更新到 %s\n", r.tag);
    } else if (portable) {
        str_addf(&out, L"有新版本 %s。这份 sniplite 不是用安装包装的，请到 GitHub 下载\n", r.tag);
    } else if (code != EXIT_OK) {
        str_add(&out, r.state == UPD_ERROR ? L"检查失败，请检查网络\n" : L"更新失败，请稍后再试\n");
    } else if (r.state == UPD_NEWER) {
        str_addf(&out, L"有新版本 %s（现在是 %s），运行 sniplite update --install 安装\n", r.tag, SNIPLITE_VERSION);
    } else {
        str_add(&out, r.state == UPD_NONE ? L"还没有发布的版本\n" : L"已是最新版本 " SNIPLITE_VERSION L"\n");
    }
    if (out.p)
        print(out.p, code != EXIT_OK && !json);
    str_free(&out);
    return code;
}

int wmain(int argc, WCHAR **argv)
{
    /* argv[0] is the program; the command starts at argv[1] */
    WCHAR *def[] = {L"start"};
    int ac = argc - 1;
    WCHAR **av = argv + 1;
    if (ac == 0) {
        ac = 1;
        av = def;
    }
    const WCHAR *c = av[0];
    if (arg_eq(c, L"help") || arg_eq(c, L"-h") || arg_eq(c, L"--help") || arg_eq(c, L"/?")) {
        print(kHelp, false);
        return EXIT_OK;
    }
    if (arg_eq(c, L"version") || arg_eq(c, L"--version")) {
        print(L"sniplite " SNIPLITE_VERSION L"\n", false);
        return EXIT_OK;
    }
    bool json = has_json(ac, av);
    if (arg_eq(c, L"update"))
        return cmd_update(ac, av, json);
    bool is_start = arg_eq(c, L"start") || c[0] == L'-';
    HWND d = ipc_find();
    if (!d) {
        if (arg_eq(c, L"status") || arg_eq(c, L"quit") || arg_eq(c, L"exit")) {
            print(json ? L"{\"running\":false}\n" : L"sniplite 没有在运行\n", false);
            return EXIT_NOT_RUNNING;
        }
        d = spawn_daemon(ac, av, is_start);
        if (!d)
            return EXIT_FAIL;
    }
    Str reply = {0};
    int code = ipc_call(d, ac, av, &reply);
    if (code < 0) {
        print(L"无法连接 sniplite 后台进程\n", true);
        str_free(&reply);
        return EXIT_FAIL;
    }
    if (reply.n)
        print(reply.p, code != EXIT_OK && !json);
    str_free(&reply);
    return code;
}
