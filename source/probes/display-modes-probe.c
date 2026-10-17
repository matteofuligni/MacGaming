/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
 */
/*
 * Lists the display modes a game sees: Wine's EnumDisplaySettings and Direct3D 9's EnumAdapterModes.
 * Built 32-bit and named after a game's executable, it gets that game's Wine per-executable settings
 * (DLL overrides, EmulateModeset). Build: source/build.sh probe; run: macgaming run build/probes/...
 * The report also goes to a .txt next to the executable, for runs whose console is not ours
 * (e.g. started inside a virtual desktop by explorer.exe /desktop=...).
 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdarg.h>

static FILE *report;

static void say(const char *format, ...)
{
    va_list args;
    va_start(args, format); vprintf(format, args); va_end(args);
    if (report) { va_start(args, format); vfprintf(report, format, args); va_end(args); }
}

int main(void)
{
    DEVMODEW mode;
    IDirect3D9 *d3d;
    D3DADAPTER_IDENTIFIER9 identifier;
    D3DDISPLAYMODE current;
    const D3DFORMAT formats[] = { D3DFMT_X8R8G8B8, D3DFMT_R5G6B5 };
    const char *names[] = { "X8R8G8B8", "R5G6B5" };
    DWORD i;
    UINT f;
    char path[MAX_PATH];
    DWORD length = GetModuleFileNameA(NULL, path, MAX_PATH);

    if (length > 4 && length < MAX_PATH) { strcpy(path + length - 4, ".txt"); report = fopen(path, "w"); }

    ZeroMemory(&mode, sizeof(mode));
    mode.dmSize = sizeof(mode);
    say("EnumDisplaySettings:\n");
    for (i = 0; EnumDisplaySettingsW(NULL, i, &mode); i++)
        say("  %lux%lux%lu @%lu\n", mode.dmPelsWidth, mode.dmPelsHeight, mode.dmBitsPerPel, mode.dmDisplayFrequency);
    if (EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &mode))
        say("current: %lux%lux%lu @%lu\n", mode.dmPelsWidth, mode.dmPelsHeight, mode.dmBitsPerPel, mode.dmDisplayFrequency);
    fflush(stdout);

    d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { say("Direct3DCreate9 failed\n"); return 1; }
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &identifier)))
        say("adapter: %s (%s)\n", identifier.Description, identifier.Driver);
    if (SUCCEEDED(IDirect3D9_GetAdapterDisplayMode(d3d, D3DADAPTER_DEFAULT, &current)))
        say("adapter display mode: %ux%u format %d @%u\n", current.Width, current.Height, current.Format, current.RefreshRate);
    D3DCAPS9 caps;
    if (SUCCEEDED(IDirect3D9_GetDeviceCaps(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, &caps))) {
        say("GTA car pipeline: MaxTextureBlendStages=%lu MaxSimultaneousTextures=%lu\n",
            caps.MaxTextureBlendStages, caps.MaxSimultaneousTextures);
        say("TextureOpCaps=%08lx: BLENDFACTORALPHA=%d MULTIPLYADD=%d\n", caps.TextureOpCaps,
            !!(caps.TextureOpCaps & D3DTEXOPCAPS_BLENDFACTORALPHA), !!(caps.TextureOpCaps & D3DTEXOPCAPS_MULTIPLYADD));
        say("ShadeCaps=%08lx: SPECULARGOURAUDRGB=%d\n", caps.ShadeCaps,
            !!(caps.ShadeCaps & D3DPSHADECAPS_SPECULARGOURAUDRGB));
    }
    for (f = 0; f < 2; f++) {
        UINT count = IDirect3D9_GetAdapterModeCount(d3d, D3DADAPTER_DEFAULT, formats[f]), m;
        say("EnumAdapterModes %s: %u\n", names[f], count);
        for (m = 0; m < count; m++) {
            D3DDISPLAYMODE dm;
            if (SUCCEEDED(IDirect3D9_EnumAdapterModes(d3d, D3DADAPTER_DEFAULT, formats[f], m, &dm)))
                say("  %ux%u @%u\n", dm.Width, dm.Height, dm.RefreshRate);
        }
    }
    IDirect3D9_Release(d3d);
    fflush(stdout);
    if (report) fclose(report);
    return 0;
}
