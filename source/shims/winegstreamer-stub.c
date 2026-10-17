/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
 */
/*
 * Minimal IWMSyncReader for a Wine built without winegstreamer.
 * GTA SA probes WMCreateSyncReader during audio initialisation and immediately releases it.
 * This reader passes that availability probe, but rejects actual WMA files: it is not a
 * media decoder. Its use is restricted to this game while diagnosing the missing codec.
 * Install only next to the game that needs it; never replace a runtime DLL globally.
 */
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include <wmsdk.h>
#include <nserror.h>

typedef struct {
    IWMSyncReader iface;
    LONG refs;
} EmptyReader;

static ULONG WINAPI add_ref(IWMSyncReader *iface)
{
    return InterlockedIncrement(&((EmptyReader *)iface)->refs);
}
static ULONG WINAPI release(IWMSyncReader *iface)
{
    EmptyReader *reader = (EmptyReader *)iface;
    ULONG refs = InterlockedDecrement(&reader->refs);
    if (!refs) HeapFree(GetProcessHeap(), 0, reader);
    return refs;
}
static HRESULT WINAPI query(IWMSyncReader *iface, REFIID iid, void **out)
{
    if (!out) return E_POINTER;
    *out = NULL;
    if (!IsEqualGUID(iid, &IID_IUnknown) && !IsEqualGUID(iid, &IID_IWMSyncReader))
        return E_NOINTERFACE;
    *out = iface;
    add_ref(iface);
    return S_OK;
}
static HRESULT WINAPI open_file(IWMSyncReader *iface, const WCHAR *path)
{
    (void)iface; (void)path;
    OutputDebugStringA("MacGaming media: WMA files are unsupported by this reader\n");
    return E_NOTIMPL;
}
static HRESULT WINAPI close_reader(IWMSyncReader *iface) { (void)iface; return S_OK; }
static HRESULT WINAPI set_range(IWMSyncReader *iface, QWORD start, LONGLONG duration)
{ (void)iface; (void)start; (void)duration; return E_NOTIMPL; }
static HRESULT WINAPI set_range_frame(IWMSyncReader *iface, WORD stream, QWORD start, LONGLONG count)
{ (void)iface; (void)stream; (void)start; (void)count; return E_NOTIMPL; }
static HRESULT WINAPI next_sample(IWMSyncReader *iface, WORD stream, INSSBuffer **sample,
                                  QWORD *time, QWORD *duration, DWORD *flags, DWORD *output, WORD *number)
{
    (void)iface; (void)stream;
    if (sample) *sample = NULL;
    if (time) *time = 0;
    if (duration) *duration = 0;
    if (flags) *flags = 0;
    if (output) *output = 0;
    if (number) *number = 0;
    return NS_E_NO_MORE_SAMPLES;
}
static HRESULT WINAPI set_streams(IWMSyncReader *iface, WORD count, WORD *numbers, WMT_STREAM_SELECTION *selections)
{ (void)iface; (void)count; (void)numbers; (void)selections; return E_NOTIMPL; }
static HRESULT WINAPI get_stream(IWMSyncReader *iface, WORD stream, WMT_STREAM_SELECTION *selection)
{ (void)iface; (void)stream; if (selection) *selection = WMT_OFF; return E_NOTIMPL; }
static HRESULT WINAPI set_compressed(IWMSyncReader *iface, WORD stream, BOOL compressed)
{ (void)iface; (void)stream; (void)compressed; return E_NOTIMPL; }
static HRESULT WINAPI get_compressed(IWMSyncReader *iface, WORD stream, BOOL *compressed)
{ (void)iface; (void)stream; if (compressed) *compressed = FALSE; return E_NOTIMPL; }
static HRESULT WINAPI get_setting(IWMSyncReader *iface, DWORD output, LPCWSTR name,
                                  WMT_ATTR_DATATYPE *type, BYTE *value, WORD *length)
{ (void)iface; (void)output; (void)name; (void)type; (void)value; if (length) *length = 0; return E_NOTIMPL; }
static HRESULT WINAPI set_setting(IWMSyncReader *iface, DWORD output, LPCWSTR name,
                                  WMT_ATTR_DATATYPE type, const BYTE *value, WORD length)
{ (void)iface; (void)output; (void)name; (void)type; (void)value; (void)length; return E_NOTIMPL; }
static HRESULT WINAPI output_count(IWMSyncReader *iface, DWORD *count)
{ (void)iface; if (!count) return E_POINTER; *count = 0; return S_OK; }
static HRESULT WINAPI get_props(IWMSyncReader *iface, DWORD output, IWMOutputMediaProps **props)
{ (void)iface; (void)output; if (props) *props = NULL; return E_INVALIDARG; }
static HRESULT WINAPI set_props(IWMSyncReader *iface, DWORD output, IWMOutputMediaProps *props)
{ (void)iface; (void)output; (void)props; return E_INVALIDARG; }
static HRESULT WINAPI format_count(IWMSyncReader *iface, DWORD output, DWORD *count)
{ (void)iface; (void)output; if (count) *count = 0; return E_INVALIDARG; }
static HRESULT WINAPI get_format(IWMSyncReader *iface, DWORD output, DWORD format, IWMOutputMediaProps **props)
{ (void)iface; (void)output; (void)format; if (props) *props = NULL; return E_INVALIDARG; }
static HRESULT WINAPI output_for_stream(IWMSyncReader *iface, WORD stream, DWORD *output)
{ (void)iface; (void)stream; if (output) *output = 0; return E_INVALIDARG; }
static HRESULT WINAPI stream_for_output(IWMSyncReader *iface, DWORD output, WORD *stream)
{ (void)iface; (void)output; if (stream) *stream = 0; return E_INVALIDARG; }
static HRESULT WINAPI max_output_sample(IWMSyncReader *iface, DWORD output, DWORD *size)
{ (void)iface; (void)output; if (size) *size = 0; return E_INVALIDARG; }
static HRESULT WINAPI max_stream_sample(IWMSyncReader *iface, WORD stream, DWORD *size)
{ (void)iface; (void)stream; if (size) *size = 0; return E_INVALIDARG; }
static HRESULT WINAPI open_stream(IWMSyncReader *iface, IStream *stream)
{ (void)iface; (void)stream; return E_NOTIMPL; }

static IWMSyncReaderVtbl vtable = {
    query, add_ref, release, open_file, close_reader, set_range, set_range_frame, next_sample,
    set_streams, get_stream, set_compressed, get_compressed, get_setting, set_setting,
    output_count, get_props, set_props, format_count, get_format, output_for_stream,
    stream_for_output, max_output_sample, max_stream_sample, open_stream
};

__declspec(dllexport) HRESULT WINAPI winegstreamer_create_wm_sync_reader(IUnknown *outer, void **out)
{
    if (!out) return E_POINTER;
    *out = NULL;
    if (outer) return CLASS_E_NOAGGREGATION;
    EmptyReader *reader = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*reader));
    if (!reader) return E_OUTOFMEMORY;
    reader->iface.lpVtbl = &vtable;
    reader->refs = 1;
    *out = &reader->iface;
    OutputDebugStringA("MacGaming media: created empty IWMSyncReader for codec availability probe\n");
    return S_OK;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(instance);
    return TRUE;
}
