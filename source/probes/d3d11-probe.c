/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
 */
/* Direct3D 11 check for MacGaming: device, offscreen frame read back, swap chain on a window, Present.
 * One "step hr=0x........" line per stage on stdout; the exit code names the first stage that failed
 * (0 = everything worked, including Present). Build: source/build.sh probe.
 * Usage: d3d11-probe.exe [--show]   (--show maps the window; by default it stays hidden) */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <string.h>

static int failed(const char *stage, HRESULT hr, int code)
{
    printf("%s hr=0x%08lx\n", stage, (unsigned long)hr);
    fflush(stdout);
    return FAILED(hr) ? code : 0;
}

int main(int argc, char **argv)
{
    static const float colour[4] = { 0.0f, 1.0f, 0.0f, 1.0f };
    D3D_FEATURE_LEVEL level = 0;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    IDXGIDevice *dxgi_device = NULL;
    IDXGIAdapter *adapter = NULL;
    IDXGIFactory *factory = NULL;
    IDXGISwapChain *swapchain = NULL;
    ID3D11Texture2D *target = NULL, *staging = NULL, *back = NULL;
    ID3D11RenderTargetView *view = NULL;
    D3D11_TEXTURE2D_DESC texture = { 0 };
    D3D11_MAPPED_SUBRESOURCE mapped;
    DXGI_ADAPTER_DESC adapter_desc;
    DXGI_SWAP_CHAIN_DESC chain = { 0 };
    WNDCLASSA wc = { 0 };
    HWND hwnd;
    HRESULT hr;
    int code;

    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &device, &level, &context);
    if ((code = failed("D3D11CreateDevice", hr, 2))) return code;
    printf("feature_level=0x%x\n", level);
    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi_device))
        && SUCCEEDED(IDXGIDevice_GetAdapter(dxgi_device, &adapter)) && SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &adapter_desc)))
        printf("adapter=%ls\n", adapter_desc.Description);
    if (!adapter) return failed("GetAdapter", E_FAIL, 2);

    /* Offscreen: clear a texture and read one pixel back through a staging copy. */
    texture.Width = texture.Height = 64; texture.MipLevels = texture.ArraySize = 1;
    texture.Format = DXGI_FORMAT_R8G8B8A8_UNORM; texture.SampleDesc.Count = 1;
    texture.Usage = D3D11_USAGE_DEFAULT; texture.BindFlags = D3D11_BIND_RENDER_TARGET;
    hr = ID3D11Device_CreateTexture2D(device, &texture, NULL, &target);
    if ((code = failed("CreateTexture2D", hr, 3))) return code;
    hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)target, NULL, &view);
    if ((code = failed("CreateRenderTargetView", hr, 3))) return code;
    ID3D11DeviceContext_ClearRenderTargetView(context, view, colour);
    texture.Usage = D3D11_USAGE_STAGING; texture.BindFlags = 0; texture.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    hr = ID3D11Device_CreateTexture2D(device, &texture, NULL, &staging);
    if ((code = failed("CreateStagingTexture", hr, 3))) return code;
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging, (ID3D11Resource *)target);
    hr = ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped);
    if ((code = failed("Map", hr, 3))) return code;
    printf("offscreen_pixel=0x%08lx\n", (unsigned long)*(DWORD *)mapped.pData);
    if (*(DWORD *)mapped.pData != 0xff00ff00) return 4;
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);

    /* On screen: a swap chain needs the window's Metal layer (DXMT) or GL surface (wined3d). */
    wc.lpfnWndProc = DefWindowProcA; wc.hInstance = GetModuleHandleA(NULL); wc.lpszClassName = "MacGamingD3D11Probe";
    RegisterClassA(&wc);
    hwnd = CreateWindowA(wc.lpszClassName, "MacGaming D3D11", WS_OVERLAPPEDWINDOW, 40, 40, 320, 240, NULL, NULL, wc.hInstance, NULL);
    if (argc > 1 && !strcmp(argv[1], "--show")) ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    hr = IDXGIAdapter_GetParent(adapter, &IID_IDXGIFactory, (void **)&factory);
    if ((code = failed("GetFactory", hr, 5))) return code;
    chain.BufferDesc.Width = 320; chain.BufferDesc.Height = 240; chain.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    chain.SampleDesc.Count = 1; chain.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; chain.BufferCount = 2;
    chain.OutputWindow = hwnd; chain.Windowed = TRUE; chain.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    hr = IDXGIFactory_CreateSwapChain(factory, (IUnknown *)device, &chain, &swapchain);
    if ((code = failed("CreateSwapChain", hr, 5))) return code;
    hr = IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&back);
    if ((code = failed("GetBuffer", hr, 6))) return code;
    ID3D11RenderTargetView_Release(view);
    hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)back, NULL, &view);
    if ((code = failed("CreateBackBufferView", hr, 6))) return code;
    for (int frame = 0; frame < 30; frame++)
    {
        ID3D11DeviceContext_ClearRenderTargetView(context, view, colour);
        hr = IDXGISwapChain_Present(swapchain, 1, 0);
        if (FAILED(hr)) break;
    }
    if ((code = failed("Present", hr, 7))) return code;
    printf("ok\n");
    return 0;
}
