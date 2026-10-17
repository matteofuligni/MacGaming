/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
 */
/*
 * steamwebhelper wrapper for MacGaming.
 *
 * Steam's browser (CEF) paints a black window under Wine on macOS when its renderer and display
 * compositor run in separate processes. Steam no longer accepts -cef-single-process, so MacGaming
 * installs this program as steamwebhelper.exe: it starts Valve's original helper, renamed
 * steamwebhelper_real.exe, with Steam's own arguments plus --disable-gpu --single-process,
 * passes the inherited handles on, waits for it and returns its exit code.
 * MACGAMING_WEBHELPER_FLAGS, from the runtime manifest's environment, replaces those flags for
 * runtimes that need others.
 *
 * Adapted from the MIT-licensed wrapper of github.com/notpop/steam-on-m1-wine.
 * Copyright (c) 2026 notpop. Original MIT terms: LICENSES/steam-on-m1-wine-MIT.txt.
 * MacGaming modifications are licensed under GPL-3.0-or-later; see LICENSE.
 *
 * Build: source/build.sh wrapper
 */
#ifndef UNICODE
#define UNICODE
#endif
#include <windows.h>
#include <wchar.h>
#include <stdlib.h>

#define DEFAULT_FLAGS L"--disable-gpu --single-process"
#define REAL_BINARY L"steamwebhelper_real.exe"

/* MacGaming recognises any version of this wrapper by this marker, kept in the binary. */
__attribute__((used)) static const char marker[] = "MACGAMING-STEAMWEBHELPER-WRAPPER";

/* The command line without its first token, the path this wrapper was started as. */
static const wchar_t *arguments_after_program(void)
{
    const wchar_t *cursor = GetCommandLineW();
    int quoted = 0;
    if (!cursor) return L"";
    while (*cursor) {
        if (*cursor == L'"') quoted = !quoted;
        else if ((*cursor == L' ' || *cursor == L'\t') && !quoted) break;
        cursor++;
    }
    while (*cursor == L' ' || *cursor == L'\t') cursor++;
    return cursor;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR unused, int show)
{
    wchar_t real[MAX_PATH + 32];
    DWORD length = GetModuleFileNameW(NULL, real, MAX_PATH);
    wchar_t *slash;
    const wchar_t *arguments;
    wchar_t *command;
    const wchar_t *flags = _wgetenv(L"MACGAMING_WEBHELPER_FLAGS");
    size_t capacity;
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    DWORD code = 1;
    (void)instance; (void)previous; (void)unused; (void)show;

    if (length == 0 || length >= MAX_PATH) return 1;
    slash = wcsrchr(real, L'\\');
    if (!slash) return 1;
    wcscpy(slash + 1, REAL_BINARY);

    if (!flags || !*flags) flags = DEFAULT_FLAGS;
    arguments = arguments_after_program();
    capacity = wcslen(real) + wcslen(flags) + wcslen(arguments) + 8;
    command = (wchar_t *)calloc(capacity, sizeof(wchar_t));
    if (!command) return 1;
    _snwprintf(command, capacity, L"\"%ls\" %ls %ls", real, flags, arguments);

    ZeroMemory(&startup, sizeof(startup));
    startup.cb = sizeof(startup);
    ZeroMemory(&process, sizeof(process));
    if (!CreateProcessW(real, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process)) {
        free(command);
        return 1;
    }
    WaitForSingleObject(process.hProcess, INFINITE);
    GetExitCodeProcess(process.hProcess, &code);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    free(command);
    return (int)code;
}
