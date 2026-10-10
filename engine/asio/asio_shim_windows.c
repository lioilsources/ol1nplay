/*
 * asio_shim_windows.c — driver loading, buffer management and the
 * real-time callbacks for the ASIO backend. Pure C; never calls into Go.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <avrt.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "asio_shim.h"

/* ---- error reporting ---------------------------------------------------- */

static _Thread_local char t_err[512];

const char *asio_last_error(void) { return t_err; }

static void set_err(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(t_err, sizeof t_err, fmt, ap);
    va_end(ap);
}

static void set_hr_err(const char *what, HRESULT hr) {
    set_err("%s: HRESULT 0x%08lx", what, (unsigned long)hr);
}

/* ---- state ---------------------------------------------------------------- */

struct asio_dev {
    IASIO *drv;
    int    initialized;      /* init() returned true                       */
    int    buffers_created;
    int    running;
    int    output_ready;     /* driver supports outputReady()              */

    rb_t          *rb;
    long           nch;
    long           frames;   /* buffer size in frames                      */
    ASIOBufferInfo bufs[ASIO_MAX_CHANNELS];
    ASIOCallbacks  cb;

    /* real-time thread setup, done once inside the first callback         */
    volatile LONG thread_setup_done;
    int   affinity_core;     /* requested; -1 = last logical core          */
    int   thread_core;       /* achieved; -1 = not pinned                  */
    char  thread_prio[64];
    HANDLE avrt_handle;

    /* asioMessage flags, read-and-clear from Go                            */
    volatile LONG flags[8];
    volatile LONGLONG reported_sr_bits; /* double bits from sampleRateDidChange */

    LARGE_INTEGER qpf;
    long last_asio_err;
};

/* The callbacks carry no context pointer, hence the global. Only one
 * driver may be open at a time; asio_open enforces it. */
static asio_dev *g_dev;

/* ---- helpers ---------------------------------------------------------------- */

static int asio_err(asio_dev *d, const char *what, ASIOError e) {
    char msg[128] = {0};
    d->last_asio_err = e;
    if (d->drv) d->drv->lpVtbl->getErrorMessage(d->drv, msg);
    set_err("%s: ASIOError %ld (%s)", what, e, msg);
    return ASIO_SHIM_EDRIVER;
}

static LONGLONG qpc_ns(asio_dev *d) {
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    if (d->qpf.QuadPart == 0) return 0;
    return (LONGLONG)((double)t.QuadPart * 1e9 / (double)d->qpf.QuadPart);
}

/* ---- real-time thread setup --------------------------------------------- */

/* Runs once, in the driver's audio thread, on the first buffer switch. These
 * are syscalls, which the callback rules forbid — but they happen exactly
 * once, before any audio has been handed over, and the driver thread is the
 * only place where its own characteristics can be changed. */
static void setup_rt_thread(asio_dev *d) {
    DWORD task_index = 0;
    HANDLE h = AvSetMmThreadCharacteristicsA("Pro Audio", &task_index);
    if (h) {
        d->avrt_handle = h;
        if (AvSetMmThreadPriority(h, AVRT_PRIORITY_CRITICAL)) {
            strncpy(d->thread_prio, "Pro Audio/critical", sizeof d->thread_prio - 1);
        } else {
            strncpy(d->thread_prio, "Pro Audio", sizeof d->thread_prio - 1);
        }
    } else {
        /* MMCSS refused (service stopped?) — fall back to the plain scheduler. */
        if (SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL)) {
            strncpy(d->thread_prio, "time-critical", sizeof d->thread_prio - 1);
        } else {
            strncpy(d->thread_prio, "driver-owned", sizeof d->thread_prio - 1);
        }
    }

    d->thread_core = -1;
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    int ncpu = (int)si.dwNumberOfProcessors;
    int core = d->affinity_core;
    if (core < 0) core = ncpu - 1;
    if (core >= 0 && core < ncpu && core < 64 && ncpu > 1) {
        DWORD_PTR mask = (DWORD_PTR)1 << core;
        if (SetThreadAffinityMask(GetCurrentThread(), mask)) d->thread_core = core;
    }
    InterlockedExchange(&d->thread_setup_done, 1);
}

/* ---- callbacks ------------------------------------------------------------- */

static ASIOTime *cb_buffer_switch_time_info(ASIOTime *params, long index, ASIOBool direct) {
    (void)direct;
    asio_dev *d = g_dev;
    if (!d || !d->rb || !d->buffers_created) return params;
    if (!d->thread_setup_done) setup_rt_thread(d);

    LONGLONG t0 = qpc_ns(d);

    void *ptrs[ASIO_MAX_CHANNELS];
    long c;
    for (c = 0; c < d->nch; c++) ptrs[c] = d->bufs[c].buffers[index & 1];
    uint32_t got = rb_read_deinterleaved(d->rb, ptrs, (uint32_t)d->frames);
    if (got < (uint32_t)d->frames) rb_note_underrun_ns(d->rb, t0);

    /* Tell the driver the buffer is complete so it can start its DMA early
     * instead of waiting for the next switch (lower latency, same data). */
    if (d->output_ready) d->drv->lpVtbl->outputReady(d->drv);

    rb_note_cb_ns(d->rb, qpc_ns(d) - t0);
    return params;
}

static void cb_buffer_switch(long index, ASIOBool direct) {
    /* Drivers that do not support time info call this one; route it to the
     * same code path with an empty ASIOTime. */
    ASIOTime t;
    memset(&t, 0, sizeof t);
    cb_buffer_switch_time_info(&t, index, direct);
}

static void cb_sample_rate_did_change(ASIOSampleRate sr) {
    asio_dev *d = g_dev;
    if (!d) return;
    LONGLONG bits;
    memcpy(&bits, &sr, sizeof bits);
    InterlockedExchange64(&d->reported_sr_bits, bits);
    InterlockedExchange(&d->flags[ASIO_FLAG_SRATE_CHANGED], 1);
}

static long cb_asio_message(long selector, long value, void *message, double *opt) {
    (void)message; (void)opt;
    asio_dev *d = g_dev;
    switch (selector) {
    case kAsioSelectorSupported:
        switch (value) {
        case kAsioEngineVersion:
        case kAsioResetRequest:
        case kAsioBufferSizeChange:
        case kAsioResyncRequest:
        case kAsioLatenciesChanged:
        case kAsioSupportsTimeInfo:
        case kAsioOverload:
            return 1;
        default:
            return 0;
        }
    case kAsioEngineVersion:
        return 2;
    case kAsioResetRequest:
        /* The driver wants stop → dispose → create → start. We must not do
         * that from inside its own callback; flag it and let Go re-open. */
        if (d) InterlockedExchange(&d->flags[ASIO_FLAG_RESET], 1);
        return 1;
    case kAsioBufferSizeChange:
        if (d) InterlockedExchange(&d->flags[ASIO_FLAG_BUFFER_SIZE], 1);
        return 1; /* accepted: a re-open picks up the new preferred size */
    case kAsioResyncRequest:
        if (d) InterlockedExchange(&d->flags[ASIO_FLAG_RESYNC], 1);
        return 1;
    case kAsioLatenciesChanged:
        if (d) InterlockedExchange(&d->flags[ASIO_FLAG_LATENCIES], 1);
        return 1;
    case kAsioSupportsTimeInfo:
        return 1;
    case kAsioSupportsTimeCode:
        return 0;
    case kAsioOverload:
        if (d) InterlockedIncrement(&d->flags[ASIO_FLAG_OVERLOAD]);
        return 1;
    default:
        return 0;
    }
}

/* ---- COM ------------------------------------------------------------------ */

int asio_com_init(void) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (hr == S_OK || hr == S_FALSE) return ASIO_SHIM_OK;
    if (hr == RPC_E_CHANGED_MODE) {
        /* Already initialized as MTA on this thread; drivers generally cope. */
        return ASIO_SHIM_OK;
    }
    set_hr_err("CoInitializeEx", hr);
    return ASIO_SHIM_ECOM;
}

void asio_com_uninit(void) { CoUninitialize(); }

void asio_pump_messages(void) {
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

int asio_open(const char *clsid_str, void *sys_handle, asio_dev **out) {
    if (!clsid_str || !out) { set_err("asio_open: null argument"); return ASIO_SHIM_EARG; }
    if (g_dev) { set_err("asio_open: a driver is already open"); return ASIO_SHIM_EBUSY; }

    WCHAR wcls[64];
    if (MultiByteToWideChar(CP_UTF8, 0, clsid_str, -1, wcls, 64) == 0) {
        set_err("asio_open: CLSID string too long");
        return ASIO_SHIM_EARG;
    }
    CLSID clsid;
    HRESULT hr = CLSIDFromString(wcls, &clsid);
    if (FAILED(hr)) { set_hr_err("CLSIDFromString", hr); return ASIO_SHIM_ECOM; }

    asio_dev *d = (asio_dev *)calloc(1, sizeof *d);
    if (!d) { set_err("asio_open: out of memory"); return ASIO_SHIM_ECOM; }
    QueryPerformanceFrequency(&d->qpf);
    d->affinity_core = -1;
    d->thread_core = -1;

    /* The ASIO quirk: the interface ID handed to CoCreateInstance is the
     * driver's own CLSID, not a shared IID — every driver is its own
     * interface as far as COM is concerned. */
    IASIO *drv = NULL;
    hr = CoCreateInstance(&clsid, NULL, CLSCTX_INPROC_SERVER, &clsid, (void **)&drv);
    if (FAILED(hr) || !drv) {
        free(d);
        set_hr_err("CoCreateInstance(ASIO driver)", hr);
        return ASIO_SHIM_ECOM;
    }
    d->drv = drv;

    if (!drv->lpVtbl->init(drv, sys_handle)) {
        char msg[128] = {0};
        drv->lpVtbl->getErrorMessage(drv, msg);
        drv->lpVtbl->Release(drv);
        free(d);
        set_err("ASIO init failed: %s", msg[0] ? msg : "(driver gave no reason)");
        return ASIO_SHIM_EDRIVER;
    }
    d->initialized = 1;

    d->cb.bufferSwitch = cb_buffer_switch;
    d->cb.sampleRateDidChange = cb_sample_rate_did_change;
    d->cb.asioMessage = cb_asio_message;
    d->cb.bufferSwitchTimeInfo = cb_buffer_switch_time_info;

    g_dev = d;
    *out = d;
    return ASIO_SHIM_OK;
}

void asio_close(asio_dev *d) {
    if (!d) return;
    if (d->running) asio_stop(d);
    if (d->buffers_created) asio_dispose_buffers(d);
    if (d->drv) d->drv->lpVtbl->Release(d->drv);
    if (g_dev == d) g_dev = NULL;
    free(d);
}

/* ---- queries ----------------------------------------------------------------- */

#define CHECK_DEV(d) \
    if (!(d) || !(d)->drv) { set_err("%s: driver not open", __func__); return ASIO_SHIM_ESTATE; }

int asio_driver_name(asio_dev *d, char *buf, int len) {
    CHECK_DEV(d);
    char name[64] = {0};
    d->drv->lpVtbl->getDriverName(d->drv, name);
    strncpy(buf, name, len - 1);
    buf[len - 1] = 0;
    return ASIO_SHIM_OK;
}

long asio_driver_version(asio_dev *d) {
    if (!d || !d->drv) return 0;
    return d->drv->lpVtbl->getDriverVersion(d->drv);
}

int asio_get_channels(asio_dev *d, long *in, long *out) {
    CHECK_DEV(d);
    ASIOError e = d->drv->lpVtbl->getChannels(d->drv, in, out);
    return e == ASE_OK ? ASIO_SHIM_OK : asio_err(d, "getChannels", e);
}

int asio_get_buffer_size(asio_dev *d, long *min, long *max, long *preferred, long *granularity) {
    CHECK_DEV(d);
    ASIOError e = d->drv->lpVtbl->getBufferSize(d->drv, min, max, preferred, granularity);
    return e == ASE_OK ? ASIO_SHIM_OK : asio_err(d, "getBufferSize", e);
}

int asio_can_sample_rate(asio_dev *d, double sr) {
    CHECK_DEV(d);
    ASIOError e = d->drv->lpVtbl->canSampleRate(d->drv, sr);
    return e == ASE_OK ? ASIO_SHIM_OK : asio_err(d, "canSampleRate", e);
}

int asio_get_sample_rate(asio_dev *d, double *sr) {
    CHECK_DEV(d);
    ASIOError e = d->drv->lpVtbl->getSampleRate(d->drv, sr);
    return e == ASE_OK ? ASIO_SHIM_OK : asio_err(d, "getSampleRate", e);
}

int asio_set_sample_rate(asio_dev *d, double sr) {
    CHECK_DEV(d);
    ASIOError e = d->drv->lpVtbl->setSampleRate(d->drv, sr);
    return e == ASE_OK ? ASIO_SHIM_OK : asio_err(d, "setSampleRate", e);
}

int asio_get_channel_info(asio_dev *d, long channel, int is_input, ASIOChannelInfo *info) {
    CHECK_DEV(d);
    memset(info, 0, sizeof *info);
    info->channel = channel;
    info->isInput = is_input ? ASIOTrue : ASIOFalse;
    ASIOError e = d->drv->lpVtbl->getChannelInfo(d->drv, info);
    return e == ASE_OK ? ASIO_SHIM_OK : asio_err(d, "getChannelInfo", e);
}

int asio_get_latencies(asio_dev *d, long *in, long *out) {
    CHECK_DEV(d);
    ASIOError e = d->drv->lpVtbl->getLatencies(d->drv, in, out);
    return e == ASE_OK ? ASIO_SHIM_OK : asio_err(d, "getLatencies", e);
}

int asio_control_panel(asio_dev *d) {
    CHECK_DEV(d);
    ASIOError e = d->drv->lpVtbl->controlPanel(d->drv);
    return e == ASE_OK ? ASIO_SHIM_OK : asio_err(d, "controlPanel", e);
}

int asio_can_do_dsd(asio_dev *d) {
    CHECK_DEV(d);
    ASIOIoFormat f;
    memset(&f, 0, sizeof f);
    f.FormatType = kASIODSDFormat;
    ASIOError e = d->drv->lpVtbl->future(d->drv, kAsioCanDoIoFormat, &f);
    /* ASIOFuture answers ASE_SUCCESS (not ASE_OK) when it understood. */
    if (e == ASE_SUCCESS || e == ASE_OK) return ASIO_SHIM_OK;
    set_err("driver cannot do DSD (future returned %ld)", e);
    return ASIO_SHIM_EDRIVER;
}

int asio_set_io_format(asio_dev *d, int dsd) {
    CHECK_DEV(d);
    ASIOIoFormat f;
    memset(&f, 0, sizeof f);
    f.FormatType = dsd ? kASIODSDFormat : kASIOPCMFormat;
    ASIOError e = d->drv->lpVtbl->future(d->drv, kAsioSetIoFormat, &f);
    if (e == ASE_SUCCESS || e == ASE_OK) return ASIO_SHIM_OK;
    return asio_err(d, "future(kAsioSetIoFormat)", e);
}

int asio_get_io_format(asio_dev *d, int *dsd) {
    CHECK_DEV(d);
    ASIOIoFormat f;
    memset(&f, 0, sizeof f);
    f.FormatType = kASIOFormatInvalid;
    ASIOError e = d->drv->lpVtbl->future(d->drv, kAsioGetIoFormat, &f);
    if (e == ASE_SUCCESS || e == ASE_OK) {
        *dsd = f.FormatType == kASIODSDFormat;
        return ASIO_SHIM_OK;
    }
    *dsd = 0;
    return asio_err(d, "future(kAsioGetIoFormat)", e);
}

/* ---- buffers / transport ---------------------------------------------------- */

int asio_create_buffers(asio_dev *d, rb_t *rb, long nch, long frames, int affinity_core) {
    CHECK_DEV(d);
    if (d->buffers_created) { set_err("createBuffers: already created"); return ASIO_SHIM_ESTATE; }
    if (!rb || nch <= 0 || nch > ASIO_MAX_CHANNELS || frames <= 0) {
        set_err("createBuffers: bad arguments");
        return ASIO_SHIM_EARG;
    }
    if ((long)rb_channels(rb) != nch) {
        set_err("createBuffers: ring has %u channels, driver wants %ld", rb_channels(rb), nch);
        return ASIO_SHIM_EARG;
    }
    long c;
    for (c = 0; c < nch; c++) {
        d->bufs[c].isInput = ASIOFalse;
        d->bufs[c].channelNum = c;
        d->bufs[c].buffers[0] = d->bufs[c].buffers[1] = NULL;
    }
    d->rb = NULL;
    d->nch = nch;
    d->frames = frames;
    d->affinity_core = affinity_core;
    d->thread_core = -1;
    d->thread_prio[0] = 0;
    InterlockedExchange(&d->thread_setup_done, 0);

    ASIOError e = d->drv->lpVtbl->createBuffers(d->drv, d->bufs, nch, frames, &d->cb);
    if (e != ASE_OK) return asio_err(d, "createBuffers", e);
    d->buffers_created = 1;

    /* Publish the ring only after the buffers exist; the callback checks it. */
    MemoryBarrier();
    d->rb = rb;

    /* outputReady() is optional; probing it once tells us whether to call it
     * in the callback. */
    d->output_ready = d->drv->lpVtbl->outputReady(d->drv) == ASE_OK;
    return ASIO_SHIM_OK;
}

int asio_dispose_buffers(asio_dev *d) {
    CHECK_DEV(d);
    if (!d->buffers_created) return ASIO_SHIM_OK;
    if (d->running) asio_stop(d);
    d->rb = NULL;
    MemoryBarrier();
    ASIOError e = d->drv->lpVtbl->disposeBuffers(d->drv);
    d->buffers_created = 0;
    if (d->avrt_handle) {
        /* The MMCSS handle belongs to the driver's thread, which is gone
         * now; reverting here is best-effort and harmless if it fails. */
        AvRevertMmThreadCharacteristics(d->avrt_handle);
        d->avrt_handle = NULL;
    }
    return e == ASE_OK ? ASIO_SHIM_OK : asio_err(d, "disposeBuffers", e);
}

int asio_start(asio_dev *d) {
    CHECK_DEV(d);
    if (!d->buffers_created) { set_err("start: no buffers"); return ASIO_SHIM_ESTATE; }
    if (d->running) return ASIO_SHIM_OK;
    ASIOError e = d->drv->lpVtbl->start(d->drv);
    if (e != ASE_OK) return asio_err(d, "start", e);
    d->running = 1;
    return ASIO_SHIM_OK;
}

int asio_stop(asio_dev *d) {
    CHECK_DEV(d);
    if (!d->running) return ASIO_SHIM_OK;
    /* ASIOStop is synchronous in every driver we know of: when it returns
     * the hardware thread has left bufferSwitch. */
    ASIOError e = d->drv->lpVtbl->stop(d->drv);
    d->running = 0;
    return e == ASE_OK ? ASIO_SHIM_OK : asio_err(d, "stop", e);
}

int asio_running(asio_dev *d) { return d && d->running; }
int asio_output_ready_supported(asio_dev *d) { return d && d->output_ready; }

int asio_take_flag(asio_dev *d, int which) {
    if (!d || which < 0 || which >= 8) return 0;
    return (int)InterlockedExchange(&d->flags[which], 0);
}

double asio_reported_sample_rate(asio_dev *d) {
    if (!d) return 0;
    LONGLONG bits = InterlockedCompareExchange64(&d->reported_sr_bits, 0, 0);
    double sr;
    memcpy(&sr, &bits, sizeof sr);
    return sr;
}

void asio_thread_info(asio_dev *d, char *prio, int prio_len, int *core) {
    if (!d || !d->thread_setup_done) {
        strncpy(prio, "driver-owned", prio_len - 1);
        prio[prio_len - 1] = 0;
        *core = -1;
        return;
    }
    strncpy(prio, d->thread_prio, prio_len - 1);
    prio[prio_len - 1] = 0;
    *core = d->thread_core;
}

long asio_last_asio_error(asio_dev *d) { return d ? d->last_asio_err : 0; }
