/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
 */
/* Synthetic offscreen GPU test for the game-local mtld3d compatibility ASI.
 * Run from a directory named gta-sa.exe so the game's per-executable D3D9 override applies.
 * This reads its own 16x16 render target, never the desktop or another application's window.
 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(call) do { HRESULT result=(call); if(FAILED(result)) { printf("FAIL line %d: %s = %08lx\n",__LINE__,#call,result); return 1; } } while(0)
#define EXPECT(condition) do { if(!(condition)) { printf("FAIL line %d: %s\n",__LINE__,#condition); return 1; } } while(0)
typedef struct { float x,y,z,rhw; DWORD diffuse; float u,v; } Vertex;
static DWORD pixel(IDirect3DDevice9 *dev)
{
    IDirect3DSurface9 *target=NULL,*copy=NULL; D3DLOCKED_RECT lock;
    if(FAILED(IDirect3DDevice9_GetRenderTarget(dev,0,&target))) return 0;
    HRESULT hr=IDirect3DDevice9_CreateOffscreenPlainSurface(dev,16,16,D3DFMT_A8R8G8B8,D3DPOOL_SYSTEMMEM,&copy,NULL);
    if(SUCCEEDED(hr)) hr=IDirect3DDevice9_GetRenderTargetData(dev,target,copy);
    DWORD color=0;
    if(SUCCEEDED(hr) && SUCCEEDED(IDirect3DSurface9_LockRect(copy,&lock,NULL,D3DLOCK_READONLY))) {
        color=*(DWORD*)((BYTE*)lock.pBits+8*lock.Pitch+8*sizeof(DWORD));
        IDirect3DSurface9_UnlockRect(copy);
    }
    if(copy) IDirect3DSurface9_Release(copy);
    IDirect3DSurface9_Release(target);
    return color;
}
int main(void)
{
    IDirect3D9 *baseline=Direct3DCreate9(D3D_SDK_VERSION); EXPECT(baseline);
    D3DCAPS9 before={0},after={0}; CHECK(IDirect3D9_GetDeviceCaps(baseline,0,D3DDEVTYPE_HAL,&before));
    EXPECT(LoadLibraryA("MacGamingSA.asi"));
    IDirect3D9 *d=Direct3DCreate9(D3D_SDK_VERSION); EXPECT(d);
    CHECK(IDirect3D9_GetDeviceCaps(d,0,D3DDEVTYPE_HAL,&after));
    printf("TextureOpCaps: baseline=%08lx patched=%08lx\n",before.TextureOpCaps,after.TextureOpCaps);
    before.TextureOpCaps |= D3DTEXOPCAPS_MULTIPLYADD;
    EXPECT(!memcmp(&before,&after,sizeof(before)));
    WNDCLASSA cls={0}; cls.lpfnWndProc=DefWindowProcA; cls.hInstance=GetModuleHandleA(NULL); cls.lpszClassName="MacGamingGPUProbe";
    EXPECT(RegisterClassA(&cls));
    HWND window=CreateWindowA(cls.lpszClassName,"Offscreen test",WS_OVERLAPPED,0,0,16,16,NULL,NULL,cls.hInstance,NULL); EXPECT(window);
    D3DPRESENT_PARAMETERS pp={0}; pp.BackBufferWidth=16; pp.BackBufferHeight=16;
    pp.BackBufferFormat=D3DFMT_A8R8G8B8; pp.BackBufferCount=1; pp.SwapEffect=D3DSWAPEFFECT_DISCARD;
    pp.hDeviceWindow=window; pp.Windowed=TRUE; pp.PresentationInterval=D3DPRESENT_INTERVAL_IMMEDIATE;
    IDirect3DDevice9 *dev=NULL;
    CHECK(IDirect3D9_CreateDevice(d,0,D3DDEVTYPE_HAL,window,D3DCREATE_SOFTWARE_VERTEXPROCESSING,&pp,&dev));
    CHECK(IDirect3DDevice9_GetDeviceCaps(dev,&after)); EXPECT(after.TextureOpCaps & D3DTEXOPCAPS_MULTIPLYADD);
    IDirect3DTexture9 *texture=NULL;
    CHECK(IDirect3DDevice9_CreateTexture(dev,1,1,1,0,D3DFMT_A8R8G8B8,D3DPOOL_MANAGED,&texture,NULL));
    D3DLOCKED_RECT lock; CHECK(IDirect3DTexture9_LockRect(texture,0,&lock,NULL,0));
    *(DWORD*)lock.pBits=0xff668099; CHECK(IDirect3DTexture9_UnlockRect(texture,0));
    CHECK(IDirect3DDevice9_SetTexture(dev,1,(IDirect3DBaseTexture9*)texture));
    CHECK(IDirect3DDevice9_SetRenderState(dev,D3DRS_LIGHTING,FALSE));
    CHECK(IDirect3DDevice9_SetRenderState(dev,D3DRS_ZENABLE,FALSE));
    CHECK(IDirect3DDevice9_SetRenderState(dev,D3DRS_CULLMODE,D3DCULL_NONE));
    CHECK(IDirect3DDevice9_SetRenderState(dev,D3DRS_TEXTUREFACTOR,0xff404040));
    CHECK(IDirect3DDevice9_SetFVF(dev,D3DFVF_XYZRHW|D3DFVF_DIFFUSE|D3DFVF_TEX1));
    CHECK(IDirect3DDevice9_SetTextureStageState(dev,0,D3DTSS_COLOROP,D3DTOP_SELECTARG1));
    CHECK(IDirect3DDevice9_SetTextureStageState(dev,0,D3DTSS_COLORARG1,D3DTA_DIFFUSE));
    CHECK(IDirect3DDevice9_SetTextureStageState(dev,0,D3DTSS_ALPHAOP,D3DTOP_SELECTARG1));
    CHECK(IDirect3DDevice9_SetTextureStageState(dev,0,D3DTSS_ALPHAARG1,D3DTA_DIFFUSE));
    CHECK(IDirect3DDevice9_SetTextureStageState(dev,1,D3DTSS_COLOROP,D3DTOP_MULTIPLYADD));
    CHECK(IDirect3DDevice9_SetTextureStageState(dev,1,D3DTSS_COLORARG0,D3DTA_CURRENT));
    CHECK(IDirect3DDevice9_SetTextureStageState(dev,1,D3DTSS_COLORARG1,D3DTA_TEXTURE));
    CHECK(IDirect3DDevice9_SetTextureStageState(dev,1,D3DTSS_COLORARG2,D3DTA_TFACTOR));
    CHECK(IDirect3DDevice9_SetTextureStageState(dev,1,D3DTSS_ALPHAOP,D3DTOP_SELECTARG2));
    CHECK(IDirect3DDevice9_SetTextureStageState(dev,1,D3DTSS_ALPHAARG2,D3DTA_CURRENT));
    CHECK(IDirect3DDevice9_SetTextureStageState(dev,1,D3DTSS_TEXCOORDINDEX,0));
    CHECK(IDirect3DDevice9_SetTextureStageState(dev,2,D3DTSS_COLOROP,D3DTOP_DISABLE));
    Vertex vertices[4]={{-.5f,-.5f,0,1,0x80334d66,0,0},{15.5f,-.5f,0,1,0x80334d66,0,0},
                        {-.5f,15.5f,0,1,0x80334d66,0,0},{15.5f,15.5f,0,1,0x80334d66,0,0}};
    CHECK(IDirect3DDevice9_Clear(dev,0,NULL,D3DCLEAR_TARGET,0,1,0));
    CHECK(IDirect3DDevice9_BeginScene(dev));
    CHECK(IDirect3DDevice9_DrawPrimitiveUP(dev,D3DPT_TRIANGLESTRIP,2,vertices,sizeof(Vertex)));
    CHECK(IDirect3DDevice9_EndScene(dev));
    DWORD actual=pixel(dev),expected=0x804d6d8c;
    printf("MULTIPLYADD pixel=%08lx expected=%08lx (tolerance 2)\n",actual,expected);
    for(int shift=0;shift<32;shift+=8) EXPECT(abs((int)((actual>>shift)&255)-(int)((expected>>shift)&255))<=2);
    DWORD state;
    CHECK(IDirect3DDevice9_GetTextureStageState(dev,1,D3DTSS_COLOROP,&state)); EXPECT(state==D3DTOP_MULTIPLYADD);
    CHECK(IDirect3DDevice9_GetTextureStageState(dev,1,D3DTSS_RESULTARG,&state)); EXPECT(state==D3DTA_CURRENT);
    CHECK(IDirect3DDevice9_GetTextureStageState(dev,2,D3DTSS_COLOROP,&state)); EXPECT(state==D3DTOP_DISABLE);
    /* Render through the indexed vertex/index-buffer path used by RenderWare as well. */
    IDirect3DVertexBuffer9 *vb=NULL; IDirect3DIndexBuffer9 *ib=NULL; void *data=NULL;
    WORD indices[4]={0,1,2,3};
    CHECK(IDirect3DDevice9_CreateVertexBuffer(dev,sizeof(vertices),0,D3DFVF_XYZRHW|D3DFVF_DIFFUSE|D3DFVF_TEX1,D3DPOOL_MANAGED,&vb,NULL));
    CHECK(IDirect3DVertexBuffer9_Lock(vb,0,sizeof(vertices),&data,0)); memcpy(data,vertices,sizeof(vertices));
    CHECK(IDirect3DVertexBuffer9_Unlock(vb));
    CHECK(IDirect3DDevice9_CreateIndexBuffer(dev,sizeof(indices),0,D3DFMT_INDEX16,D3DPOOL_MANAGED,&ib,NULL));
    CHECK(IDirect3DIndexBuffer9_Lock(ib,0,sizeof(indices),&data,0)); memcpy(data,indices,sizeof(indices));
    CHECK(IDirect3DIndexBuffer9_Unlock(ib));
    CHECK(IDirect3DDevice9_SetStreamSource(dev,0,vb,0,sizeof(Vertex)));
    CHECK(IDirect3DDevice9_SetIndices(dev,ib));
    for(int variant=0;variant<3;variant++) {
        CHECK(IDirect3DDevice9_Clear(dev,0,NULL,D3DCLEAR_TARGET,0,1,0));
        CHECK(IDirect3DDevice9_BeginScene(dev));
        if(variant==0) CHECK(IDirect3DDevice9_DrawIndexedPrimitive(dev,D3DPT_TRIANGLESTRIP,0,0,4,0,2));
        if(variant==1) CHECK(IDirect3DDevice9_DrawPrimitive(dev,D3DPT_TRIANGLESTRIP,0,2));
        if(variant==2) CHECK(IDirect3DDevice9_DrawIndexedPrimitiveUP(dev,D3DPT_TRIANGLESTRIP,0,4,2,indices,D3DFMT_INDEX16,vertices,sizeof(Vertex)));
        CHECK(IDirect3DDevice9_EndScene(dev));
        actual=pixel(dev); printf("Draw variant %d: pixel=%08lx expected=%08lx\n",variant,actual,expected);
        for(int shift=0;shift<32;shift+=8) EXPECT(abs((int)((actual>>shift)&255)-(int)((expected>>shift)&255))<=2);
    }
    IDirect3DIndexBuffer9_Release(ib); IDirect3DVertexBuffer9_Release(vb);
    CHECK(IDirect3DDevice9_SetTextureStageState(dev,1,D3DTSS_COLOROP,D3DTOP_DISABLE));
    CHECK(IDirect3DDevice9_BeginScene(dev));
    CHECK(IDirect3DDevice9_DrawPrimitiveUP(dev,D3DPT_TRIANGLESTRIP,2,vertices,sizeof(Vertex)));
    CHECK(IDirect3DDevice9_EndScene(dev));
    actual=pixel(dev); printf("After disabling reflection stage: pixel=%08lx expected=80334d66\n",actual);
    for(int shift=0;shift<32;shift+=8) EXPECT(abs((int)((actual>>shift)&255)-(int)((0x80334d66ul>>shift)&255))<=2);
    IDirect3DTexture9_Release(texture); IDirect3DDevice9_Release(dev); IDirect3D9_Release(d); IDirect3D9_Release(baseline);
    DestroyWindow(window);
    puts("PASS: exact capability change, GPU multiply-add, alpha and stage restoration");
    return 0;
}
