/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
 */
/* Game-local D3D9 compatibility for GTA San Andreas + Hadron 0.3.0's mtld3d.
 * Implements CURRENT + TEXTURE * TFACTOR (D3DTOP_MULTIPLYADD) as two supported
 * texture stages, using TEMP. Only that capability bit is added. The original
 * stage state is restored after every draw. No game code or runtime DLL is replaced.
 * Loaded by Ultimate ASI Loader; this is inactive on any renderer other than mtld3d.
 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <string.h>

static IDirect3D9 *(WINAPI *create9)(UINT);
static HRESULT (WINAPI *caps9)(IDirect3D9*,UINT,D3DDEVTYPE,D3DCAPS9*);
static HRESULT (WINAPI *create_device)(IDirect3D9*,UINT,D3DDEVTYPE,HWND,DWORD,D3DPRESENT_PARAMETERS*,IDirect3DDevice9**);
static HRESULT (WINAPI *device_caps)(IDirect3DDevice9*,D3DCAPS9*);
static HRESULT (WINAPI *draw_primitive)(IDirect3DDevice9*,D3DPRIMITIVETYPE,UINT,UINT);
static HRESULT (WINAPI *draw_indexed)(IDirect3DDevice9*,D3DPRIMITIVETYPE,INT,UINT,UINT,UINT,UINT);
static HRESULT (WINAPI *draw_up)(IDirect3DDevice9*,D3DPRIMITIVETYPE,UINT,const void*,UINT);
static HRESULT (WINAPI *draw_indexed_up)(IDirect3DDevice9*,D3DPRIMITIVETYPE,UINT,UINT,UINT,const void*,D3DFORMAT,const void*,UINT);

static void patch_slot(void *slot, void *replacement, void *saved)
{
    DWORD old;
    if (*(void**)slot == replacement) return;
    if (!VirtualProtect(slot,sizeof(void*),PAGE_READWRITE,&old)) return;
    *(void**)saved=*(void**)slot;
    *(void**)slot=replacement;
    VirtualProtect(slot,sizeof(void*),old,&old);
}

static HRESULT WINAPI get_caps(IDirect3D9 *self,UINT adapter,D3DDEVTYPE type,D3DCAPS9 *caps)
{
    HRESULT hr=caps9(self,adapter,type,caps);
    if (SUCCEEDED(hr) && caps) caps->TextureOpCaps |= D3DTEXOPCAPS_MULTIPLYADD;
    return hr;
}
static HRESULT WINAPI get_device_caps(IDirect3DDevice9 *self,D3DCAPS9 *caps)
{
    HRESULT hr=device_caps(self,caps);
    if (SUCCEEDED(hr) && caps) caps->TextureOpCaps |= D3DTEXOPCAPS_MULTIPLYADD;
    return hr;
}

typedef struct { DWORD stage; D3DTEXTURESTAGESTATETYPE key; DWORD value; } SavedState;
typedef struct { SavedState states[8]; UINT count; } Remap;
static void replace_state(IDirect3DDevice9 *dev,Remap *r,DWORD stage,D3DTEXTURESTAGESTATETYPE key,DWORD value)
{
    SavedState *s=&r->states[r->count];
    s->stage=stage; s->key=key;
    if (SUCCEEDED(IDirect3DDevice9_GetTextureStageState(dev,stage,key,&s->value))) {
        r->count++;
        IDirect3DDevice9_SetTextureStageState(dev,stage,key,value);
    }
}
static Remap begin_remap(IDirect3DDevice9 *dev)
{
    Remap r={0}; DWORD op, next_op, arg0, result;
    IDirect3DPixelShader9 *ps=NULL;
    if (FAILED(IDirect3DDevice9_GetPixelShader(dev,&ps))) return r;
    if (ps) { IDirect3DPixelShader9_Release(ps); return r; }
    if (FAILED(IDirect3DDevice9_GetTextureStageState(dev,1,D3DTSS_COLOROP,&op)) || op!=D3DTOP_MULTIPLYADD) return r;
    if (FAILED(IDirect3DDevice9_GetTextureStageState(dev,2,D3DTSS_COLOROP,&next_op)) || next_op!=D3DTOP_DISABLE) return r;
    if (FAILED(IDirect3DDevice9_GetTextureStageState(dev,1,D3DTSS_COLORARG0,&arg0)) || arg0!=D3DTA_CURRENT) return r;
    if (FAILED(IDirect3DDevice9_GetTextureStageState(dev,1,D3DTSS_RESULTARG,&result)) || result!=D3DTA_CURRENT) return r;
    // Stage 1: TEMP.rgb = arg1 * arg2; TEMP.a = original alpha expression.
    // Stage 2: CURRENT.rgb += TEMP.rgb; CURRENT.a = TEMP.a.
    replace_state(dev,&r,1,D3DTSS_COLOROP,D3DTOP_MODULATE);
    replace_state(dev,&r,1,D3DTSS_RESULTARG,D3DTA_TEMP);
    replace_state(dev,&r,2,D3DTSS_COLOROP,D3DTOP_ADD);
    replace_state(dev,&r,2,D3DTSS_COLORARG1,D3DTA_TEMP);
    replace_state(dev,&r,2,D3DTSS_COLORARG2,D3DTA_CURRENT);
    replace_state(dev,&r,2,D3DTSS_ALPHAOP,D3DTOP_SELECTARG1);
    replace_state(dev,&r,2,D3DTSS_ALPHAARG1,D3DTA_TEMP);
    replace_state(dev,&r,2,D3DTSS_RESULTARG,D3DTA_CURRENT);
    return r;
}
static void end_remap(IDirect3DDevice9 *dev,Remap *r)
{
    while(r->count) { SavedState *s=&r->states[--r->count]; IDirect3DDevice9_SetTextureStageState(dev,s->stage,s->key,s->value); }
}
static HRESULT WINAPI primitive(IDirect3DDevice9 *d,D3DPRIMITIVETYPE t,UINT start,UINT count)
{ Remap r=begin_remap(d); HRESULT hr=draw_primitive(d,t,start,count); end_remap(d,&r); return hr; }
static HRESULT WINAPI indexed(IDirect3DDevice9 *d,D3DPRIMITIVETYPE t,INT base,UINT min,UINT vertices,UINT start,UINT count)
{ Remap r=begin_remap(d); HRESULT hr=draw_indexed(d,t,base,min,vertices,start,count); end_remap(d,&r); return hr; }
static HRESULT WINAPI up(IDirect3DDevice9 *d,D3DPRIMITIVETYPE t,UINT count,const void *data,UINT stride)
{ Remap r=begin_remap(d); HRESULT hr=draw_up(d,t,count,data,stride); end_remap(d,&r); return hr; }
static HRESULT WINAPI indexed_up(IDirect3DDevice9 *d,D3DPRIMITIVETYPE t,UINT min,UINT vertices,UINT count,const void *indices,D3DFORMAT format,const void *data,UINT stride)
{ Remap r=begin_remap(d); HRESULT hr=draw_indexed_up(d,t,min,vertices,count,indices,format,data,stride); end_remap(d,&r); return hr; }
static HRESULT WINAPI new_device(IDirect3D9 *self,UINT adapter,D3DDEVTYPE type,HWND window,DWORD flags,D3DPRESENT_PARAMETERS *pp,IDirect3DDevice9 **out)
{
    HRESULT hr=create_device(self,adapter,type,window,flags,pp,out);
    if (SUCCEEDED(hr) && out && *out) {
        IDirect3DDevice9Vtbl *v=(*out)->lpVtbl;
        patch_slot(&v->GetDeviceCaps,get_device_caps,&device_caps);
        patch_slot(&v->DrawPrimitive,primitive,&draw_primitive);
        patch_slot(&v->DrawIndexedPrimitive,indexed,&draw_indexed);
        patch_slot(&v->DrawPrimitiveUP,up,&draw_up);
        patch_slot(&v->DrawIndexedPrimitiveUP,indexed_up,&draw_indexed_up);
    }
    return hr;
}
static IDirect3D9 *WINAPI new_d3d9(UINT version)
{
    IDirect3D9 *d=create9(version);
    D3DADAPTER_IDENTIFIER9 id;
    if(d && SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d,0,0,&id)) && strstr(id.Driver,"mtld3d")) {
        patch_slot(&d->lpVtbl->GetDeviceCaps,get_caps,&caps9);
        patch_slot(&d->lpVtbl->CreateDevice,new_device,&create_device);
        OutputDebugStringA("MacGamingSA: mtld3d MULTIPLYADD compatibility active\n");
    }
    return d;
}
BOOL WINAPI DllMain(HINSTANCE dll,DWORD reason,LPVOID reserved)
{
    (void)reserved;
    if(reason==DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(dll);
        BYTE *base=(BYTE*)GetModuleHandleA(NULL);
        IMAGE_NT_HEADERS *nt=(void*)(base+((IMAGE_DOS_HEADER*)base)->e_lfanew);
        DWORD rva=nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
        if(!rva) return TRUE;
        IMAGE_IMPORT_DESCRIPTOR *desc=(void*)(base+rva);
        for(;desc->Name;desc++) {
            if(!desc->OriginalFirstThunk || _stricmp((char*)(base+desc->Name),"d3d9.dll")) continue;
            IMAGE_THUNK_DATA *names=(void*)(base+desc->OriginalFirstThunk),*slots=(void*)(base+desc->FirstThunk);
            for(;names->u1.AddressOfData;names++,slots++) {
                if(IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
                IMAGE_IMPORT_BY_NAME *item=(void*)(base+names->u1.AddressOfData);
                if(!strcmp((char*)item->Name,"Direct3DCreate9"))
                    patch_slot(&slots->u1.Function,new_d3d9,&create9);
            }
        }
    }
    return TRUE;
}
