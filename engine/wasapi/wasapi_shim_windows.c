/*
 * wasapi_shim_windows.c — exclusive-mode WASAPI rendering in pure C.
 *
 * Written against the C (CINTERFACE / COBJMACROS) view of the COM
 * interfaces so no C++ is involved. All interface GUIDs are defined locally
 * rather than pulled from libuuid, because the MinGW import library does not
 * reliably carry the Core Audio IIDs.
 */
#define WIN32_LEAN_AND_MEAN
#define CINTERFACE
#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <propidl.h>
#include <avrt.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "wasapi_shim.h"

/* ---- GUIDs ------------------------------------------------------------------- */

static const CLSID my_CLSID_MMDeviceEnumerator =
    {0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}};
static const IID my_IID_IMMDeviceEnumerator =
    {0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}};
static const IID my_IID_IAudioClient =
    {0x1CB9AD4C, 0xDBFA, 0x4C32, {0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2}};
static const IID my_IID_IAudioRenderClient =
    {0xF294ACFC, 0x3146, 0x4483, {0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2}};
static const GUID my_KSDATAFORMAT_SUBTYPE_PCM =
    {0x00000001, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};
static const GUID my_KSDATAFORMAT_SUBTYPE_IEEE_FLOAT =
    {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};
static const PROPERTYKEY my_PKEY_Device_FriendlyName =
    {{0xA45C254E, 0xDF1C, 0x4EFD, {0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0}}, 14};

#ifndef AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED
#define AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED ((HRESULT)0x88890019)
#endif
#ifndef AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED
#define AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED ((HRESULT)0x8889000F)
#endif
#ifndef AUDCLNT_E_DEVICE_IN_USE
#define AUDCLNT_E_DEVICE_IN_USE ((HRESULT)0x8889000A)
#endif
#ifndef AUDCLNT_E_UNSUPPORTED_FORMAT
#define AUDCLNT_E_UNSUPPORTED_FORMAT ((HRESULT)0x88890008)
#endif
#ifndef AUDCLNT_E_DEVICE_INVALIDATED
#define AUDCLNT_E_DEVICE_INVALIDATED ((HRESULT)0x88890004)
#endif

/* ---- errors ------------------------------------------------------------------ */

static _Thread_local char t_err[512];

const char *wasapi_last_error(void) { return t_err; }

static void set_err(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(t_err, sizeof t_err, fmt, ap);
    va_end(ap);
}

static int hr_err(const char *what, HRESULT hr) {
    set_err("%s: HRESULT 0x%08lx", what, (unsigned long)hr);
    switch (hr) {
    case AUDCLNT_E_UNSUPPORTED_FORMAT: return WASAPI_EFORMAT;
    case AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED:
        set_err("%s: exclusive mode is disabled for this device in Windows Sound settings", what);
        return WASAPI_EEXCLUSIVE;
    case AUDCLNT_E_DEVICE_IN_USE:
        set_err("%s: another application holds the device in exclusive mode", what);
        return WASAPI_EINUSE;
    default: return WASAPI_ECOM;
    }
}

/* ---- state ------------------------------------------------------------------- */

struct wasapi_dev {
    IAudioClient       *client;
    IAudioRenderClient *render;
    HANDLE              event;
    HANDLE              thread;
    UINT32              frames;        /* one period = whole exclusive buffer */
    int                 sr;
    rb_t               *rb;
    REFERENCE_TIME      latency;       /* from GetStreamLatency, 100 ns units */

    volatile LONG running;
    volatile LONG invalidated;
    volatile LONG timeouts;
    volatile LONG error_hr;

    int    affinity_core;
    int    thread_core;
    char   thread_prio[64];
    LARGE_INTEGER qpf;
};

/* ---- helpers ------------------------------------------------------------------- */

int wasapi_com_init(void) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (hr == S_OK || hr == S_FALSE || hr == RPC_E_CHANGED_MODE) return WASAPI_OK;
    return hr_err("CoInitializeEx", hr);
}

void wasapi_com_uninit(void) { CoUninitialize(); }

static void wide_to_utf8(const WCHAR *w, char *out, int len) {
    if (!w) { out[0] = 0; return; }
    if (WideCharToMultiByte(CP_UTF8, 0, w, -1, out, len, NULL, NULL) == 0) out[0] = 0;
    out[len - 1] = 0;
}

static WCHAR *utf8_to_wide(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    WCHAR *w = (WCHAR *)CoTaskMemAlloc((size_t)n * sizeof(WCHAR));
    if (!w) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

static int get_enumerator(IMMDeviceEnumerator **out) {
    HRESULT hr = CoCreateInstance(&my_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                                  &my_IID_IMMDeviceEnumerator, (void **)out);
    if (FAILED(hr)) return hr_err("CoCreateInstance(MMDeviceEnumerator)", hr);
    return WASAPI_OK;
}

static int get_device(const char *id, IMMDevice **out) {
    IMMDeviceEnumerator *en = NULL;
    int rc = get_enumerator(&en);
    if (rc) return rc;
    HRESULT hr;
    if (!id || !id[0]) {
        hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(en, eRender, eConsole, out);
    } else {
        WCHAR *w = utf8_to_wide(id);
        if (!w) { IMMDeviceEnumerator_Release(en); set_err("bad device id"); return WASAPI_EARG; }
        hr = IMMDeviceEnumerator_GetDevice(en, w, out);
        CoTaskMemFree(w);
    }
    IMMDeviceEnumerator_Release(en);
    if (FAILED(hr)) {
        hr_err("GetDevice", hr);
        return WASAPI_ENODEVICE;
    }
    return WASAPI_OK;
}

static void build_wfx(WAVEFORMATEXTENSIBLE *wfx, int sr, int ch, int container_bits,
                      int valid_bits, int is_float, uint32_t channel_mask) {
    memset(wfx, 0, sizeof *wfx);
    wfx->Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    wfx->Format.nChannels = (WORD)ch;
    wfx->Format.nSamplesPerSec = (DWORD)sr;
    wfx->Format.wBitsPerSample = (WORD)container_bits;
    wfx->Format.nBlockAlign = (WORD)(ch * container_bits / 8);
    wfx->Format.nAvgBytesPerSec = (DWORD)sr * wfx->Format.nBlockAlign;
    wfx->Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    wfx->Samples.wValidBitsPerSample = (WORD)(valid_bits ? valid_bits : container_bits);
    wfx->dwChannelMask = channel_mask;
    wfx->SubFormat = is_float ? my_KSDATAFORMAT_SUBTYPE_IEEE_FLOAT : my_KSDATAFORMAT_SUBTYPE_PCM;
}

/* ---- enumeration ---------------------------------------------------------- */

int wasapi_enumerate(wasapi_device_info *out, int max, int *count) {
    *count = 0;
    IMMDeviceEnumerator *en = NULL;
    int rc = get_enumerator(&en);
    if (rc) return rc;

    char def_id[512] = {0};
    IMMDevice *def = NULL;
    if (SUCCEEDED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(en, eRender, eConsole, &def)) && def) {
        LPWSTR w = NULL;
        if (SUCCEEDED(IMMDevice_GetId(def, &w))) { wide_to_utf8(w, def_id, sizeof def_id); CoTaskMemFree(w); }
        IMMDevice_Release(def);
    }

    IMMDeviceCollection *coll = NULL;
    HRESULT hr = IMMDeviceEnumerator_EnumAudioEndpoints(en, eRender, DEVICE_STATE_ACTIVE, &coll);
    IMMDeviceEnumerator_Release(en);
    if (FAILED(hr)) return hr_err("EnumAudioEndpoints", hr);

    UINT n = 0;
    IMMDeviceCollection_GetCount(coll, &n);
    UINT i;
    for (i = 0; i < n; i++) {
        IMMDevice *dev = NULL;
        if (FAILED(IMMDeviceCollection_Item(coll, i, &dev)) || !dev) continue;
        if (*count < max) {
            wasapi_device_info *info = &out[*count];
            memset(info, 0, sizeof *info);
            LPWSTR w = NULL;
            if (SUCCEEDED(IMMDevice_GetId(dev, &w))) { wide_to_utf8(w, info->id, sizeof info->id); CoTaskMemFree(w); }
            IPropertyStore *ps = NULL;
            if (SUCCEEDED(IMMDevice_OpenPropertyStore(dev, STGM_READ, &ps)) && ps) {
                PROPVARIANT pv;
                PropVariantInit(&pv);
                if (SUCCEEDED(IPropertyStore_GetValue(ps, &my_PKEY_Device_FriendlyName, &pv)) && pv.vt == VT_LPWSTR) {
                    wide_to_utf8(pv.pwszVal, info->name, sizeof info->name);
                }
                PropVariantClear(&pv);
                IPropertyStore_Release(ps);
            }
            if (!info->name[0]) strncpy(info->name, info->id, sizeof info->name - 1);
            info->is_default = def_id[0] && strcmp(def_id, info->id) == 0;
        }
        (*count)++;
        IMMDevice_Release(dev);
    }
    IMMDeviceCollection_Release(coll);
    if (*count > max) *count = max;
    return WASAPI_OK;
}

/* ---- format probing ------------------------------------------------------ */

int wasapi_format_supported(const char *id, int sr, int ch, int container_bits,
                            int valid_bits, int is_float, uint32_t channel_mask) {
    IMMDevice *dev = NULL;
    int rc = get_device(id, &dev);
    if (rc) return rc;
    IAudioClient *client = NULL;
    HRESULT hr = IMMDevice_Activate(dev, &my_IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client);
    IMMDevice_Release(dev);
    if (FAILED(hr)) return hr_err("Activate(IAudioClient)", hr);

    WAVEFORMATEXTENSIBLE wfx;
    build_wfx(&wfx, sr, ch, container_bits, valid_bits, is_float, channel_mask);
    /* In exclusive mode the "closest match" out-parameter must be NULL and
     * the answer is simply S_OK or AUDCLNT_E_UNSUPPORTED_FORMAT. */
    hr = IAudioClient_IsFormatSupported(client, AUDCLNT_SHAREMODE_EXCLUSIVE, (WAVEFORMATEX *)&wfx, NULL);
    IAudioClient_Release(client);
    if (hr == S_OK) return WASAPI_OK;
    return hr_err("IsFormatSupported(exclusive)", hr);
}

/* ---- render thread ----------------------------------------------------------- */

static LONGLONG qpc_ns(wasapi_dev *d) {
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    if (d->qpf.QuadPart == 0) return 0;
    return (LONGLONG)((double)t.QuadPart * 1e9 / (double)d->qpf.QuadPart);
}

static void setup_rt_thread(wasapi_dev *d, HANDLE *avrt) {
    DWORD idx = 0;
    *avrt = AvSetMmThreadCharacteristicsA("Pro Audio", &idx);
    if (*avrt) {
        if (AvSetMmThreadPriority(*avrt, AVRT_PRIORITY_CRITICAL))
            strncpy(d->thread_prio, "Pro Audio/critical", sizeof d->thread_prio - 1);
        else
            strncpy(d->thread_prio, "Pro Audio", sizeof d->thread_prio - 1);
    } else if (SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL)) {
        strncpy(d->thread_prio, "time-critical", sizeof d->thread_prio - 1);
    } else {
        strncpy(d->thread_prio, "normal", sizeof d->thread_prio - 1);
    }
    d->thread_core = -1;
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    int ncpu = (int)si.dwNumberOfProcessors;
    int core = d->affinity_core < 0 ? ncpu - 1 : d->affinity_core;
    if (ncpu > 1 && core >= 0 && core < ncpu && core < 64) {
        if (SetThreadAffinityMask(GetCurrentThread(), (DWORD_PTR)1 << core)) d->thread_core = core;
    }
}

static DWORD WINAPI render_thread(LPVOID arg) {
    wasapi_dev *d = (wasapi_dev *)arg;
    HANDLE avrt = NULL;
    /* IAudioRenderClient is free-threaded, but initialising COM on the
     * thread keeps the runtime happy on every Windows version. */
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    setup_rt_thread(d, &avrt);

    while (InterlockedCompareExchange(&d->running, 0, 0)) {
        DWORD w = WaitForSingleObject(d->event, 2000);
        if (!InterlockedCompareExchange(&d->running, 0, 0)) break;
        if (w != WAIT_OBJECT_0) {
            /* The engine stopped signalling: device yanked or driver hung.
             * Count it and keep waiting; the Go side decides what to do. */
            InterlockedIncrement(&d->timeouts);
            continue;
        }
        LONGLONG t0 = qpc_ns(d);
        BYTE *data = NULL;
        HRESULT hr = IAudioRenderClient_GetBuffer(d->render, d->frames, &data);
        if (FAILED(hr) || !data) {
            InterlockedExchange(&d->error_hr, (LONG)hr);
            if (hr == AUDCLNT_E_DEVICE_INVALIDATED) {
                InterlockedExchange(&d->invalidated, 1);
                break;
            }
            continue;
        }
        uint32_t got = rb_read_interleaved(d->rb, data, d->frames);
        if (got < d->frames) rb_note_underrun_ns(d->rb, t0);
        IAudioRenderClient_ReleaseBuffer(d->render, d->frames, 0);
        rb_note_cb_ns(d->rb, qpc_ns(d) - t0);
    }

    if (avrt) AvRevertMmThreadCharacteristics(avrt);
    CoUninitialize();
    return 0;
}

/* ---- open / close -------------------------------------------------------------- */

static int initialize_client(IMMDevice *dev, WAVEFORMATEXTENSIBLE *wfx, int sr,
                             IAudioClient **out, UINT32 *frames) {
    IAudioClient *client = NULL;
    HRESULT hr = IMMDevice_Activate(dev, &my_IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client);
    if (FAILED(hr)) return hr_err("Activate(IAudioClient)", hr);

    REFERENCE_TIME def_period = 0, min_period = 0;
    hr = IAudioClient_GetDevicePeriod(client, &def_period, &min_period);
    if (FAILED(hr)) { IAudioClient_Release(client); return hr_err("GetDevicePeriod", hr); }
    /* Default period, not minimum: we do not care about latency and the
     * default is what the driver was validated with. */
    REFERENCE_TIME period = def_period;

    hr = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_EXCLUSIVE,
                                 AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                 period, period, (WAVEFORMATEX *)wfx, NULL);
    if (hr == AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED) {
        /* The period must map to a whole number of frames the hardware can
         * DMA; Windows tells us the aligned frame count and we must throw
         * the client away and start over with the matching period. */
        UINT32 aligned = 0;
        IAudioClient_GetBufferSize(client, &aligned);
        IAudioClient_Release(client);
        client = NULL;
        period = (REFERENCE_TIME)((10000.0 * 1000.0 / (double)sr) * (double)aligned + 0.5);
        hr = IMMDevice_Activate(dev, &my_IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client);
        if (FAILED(hr)) return hr_err("Activate(IAudioClient) #2", hr);
        hr = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_EXCLUSIVE,
                                     AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                     period, period, (WAVEFORMATEX *)wfx, NULL);
    }
    if (FAILED(hr)) {
        IAudioClient_Release(client);
        return hr_err("IAudioClient::Initialize(exclusive)", hr);
    }
    hr = IAudioClient_GetBufferSize(client, frames);
    if (FAILED(hr)) { IAudioClient_Release(client); return hr_err("GetBufferSize", hr); }
    *out = client;
    return WASAPI_OK;
}

int wasapi_open(const char *id, int sr, int ch, int container_bits, int valid_bits,
                int is_float, uint32_t channel_mask, rb_t *rb, int affinity_core,
                wasapi_dev **out) {
    if (!rb || !out || ch <= 0 || sr <= 0) { set_err("wasapi_open: bad arguments"); return WASAPI_EARG; }
    if ((int)rb_channels(rb) != ch || (int)rb_frame_bytes(rb) != ch * container_bits / 8) {
        set_err("wasapi_open: ring buffer layout does not match the format");
        return WASAPI_EARG;
    }

    IMMDevice *dev = NULL;
    int rc = get_device(id, &dev);
    if (rc) return rc;

    wasapi_dev *d = (wasapi_dev *)calloc(1, sizeof *d);
    if (!d) { IMMDevice_Release(dev); set_err("out of memory"); return WASAPI_ECOM; }
    QueryPerformanceFrequency(&d->qpf);
    d->affinity_core = affinity_core;
    d->thread_core = -1;
    d->sr = sr;
    d->rb = rb;

    WAVEFORMATEXTENSIBLE wfx;
    build_wfx(&wfx, sr, ch, container_bits, valid_bits, is_float, channel_mask);

    rc = initialize_client(dev, &wfx, sr, &d->client, &d->frames);
    IMMDevice_Release(dev);
    if (rc) { free(d); return rc; }

    d->event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!d->event) { set_err("CreateEvent failed"); wasapi_close(d); return WASAPI_ECOM; }
    HRESULT hr = IAudioClient_SetEventHandle(d->client, d->event);
    if (FAILED(hr)) { rc = hr_err("SetEventHandle", hr); wasapi_close(d); return rc; }

    hr = IAudioClient_GetService(d->client, &my_IID_IAudioRenderClient, (void **)&d->render);
    if (FAILED(hr)) { rc = hr_err("GetService(IAudioRenderClient)", hr); wasapi_close(d); return rc; }

    IAudioClient_GetStreamLatency(d->client, &d->latency);

    /* Pre-fill the first period with silence so Start() never plays stale
     * buffer memory. */
    BYTE *data = NULL;
    if (SUCCEEDED(IAudioRenderClient_GetBuffer(d->render, d->frames, &data)) && data) {
        IAudioRenderClient_ReleaseBuffer(d->render, d->frames, AUDCLNT_BUFFERFLAGS_SILENT);
    }

    *out = d;
    return WASAPI_OK;
}

int wasapi_buffer_frames(wasapi_dev *d) { return d ? (int)d->frames : 0; }

double wasapi_latency_ms(wasapi_dev *d) {
    if (!d) return 0;
    /* GetStreamLatency is often 0 in exclusive mode; the period is the
     * honest lower bound. */
    double lat = (double)d->latency / 10000.0;
    double per = 1000.0 * (double)d->frames / (double)d->sr;
    return lat > per ? lat : per;
}

int wasapi_start(wasapi_dev *d) {
    if (!d || !d->client) { set_err("start: not open"); return WASAPI_ESTATE; }
    if (d->running) return WASAPI_OK;
    InterlockedExchange(&d->running, 1);
    InterlockedExchange(&d->invalidated, 0);
    d->thread = CreateThread(NULL, 0, render_thread, d, 0, NULL);
    if (!d->thread) {
        InterlockedExchange(&d->running, 0);
        set_err("CreateThread failed");
        return WASAPI_ECOM;
    }
    HRESULT hr = IAudioClient_Start(d->client);
    if (FAILED(hr)) {
        InterlockedExchange(&d->running, 0);
        SetEvent(d->event);
        WaitForSingleObject(d->thread, 5000);
        CloseHandle(d->thread);
        d->thread = NULL;
        return hr_err("IAudioClient::Start", hr);
    }
    return WASAPI_OK;
}

int wasapi_stop(wasapi_dev *d) {
    if (!d || !d->client) { set_err("stop: not open"); return WASAPI_ESTATE; }
    if (!d->running) return WASAPI_OK;
    InterlockedExchange(&d->running, 0);
    if (d->thread) {
        SetEvent(d->event);
        WaitForSingleObject(d->thread, 5000);
        CloseHandle(d->thread);
        d->thread = NULL;
    }
    HRESULT hr = IAudioClient_Stop(d->client);
    IAudioClient_Reset(d->client);
    if (FAILED(hr)) return hr_err("IAudioClient::Stop", hr);
    return WASAPI_OK;
}

void wasapi_close(wasapi_dev *d) {
    if (!d) return;
    if (d->running) wasapi_stop(d);
    if (d->render) IAudioRenderClient_Release(d->render);
    if (d->client) IAudioClient_Release(d->client);
    if (d->event) CloseHandle(d->event);
    free(d);
}

int  wasapi_running(wasapi_dev *d) { return d && d->running; }
int  wasapi_device_invalidated(wasapi_dev *d) { return d && InterlockedCompareExchange(&d->invalidated, 0, 0); }
long wasapi_event_timeouts(wasapi_dev *d) { return d ? InterlockedCompareExchange(&d->timeouts, 0, 0) : 0; }

void wasapi_thread_info(wasapi_dev *d, char *prio, int prio_len, int *core) {
    if (!d || !d->thread_prio[0]) {
        strncpy(prio, "normal", prio_len - 1);
        prio[prio_len - 1] = 0;
        *core = -1;
        return;
    }
    strncpy(prio, d->thread_prio, prio_len - 1);
    prio[prio_len - 1] = 0;
    *core = d->thread_core;
}
