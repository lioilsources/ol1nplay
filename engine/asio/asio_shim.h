/*
 * asio_shim.h — C side of the ASIO backend.
 *
 * Everything that talks to the driver object lives here so that the
 * real-time callbacks never see the Go runtime. The Go side calls these
 * functions from one dedicated OS thread (ASIO drivers are apartment
 * threaded COM objects: the thread that created the driver must make every
 * subsequent call and must still be alive while the driver runs).
 *
 * Only one driver can be open at a time: ASIO callbacks carry no user
 * pointer, so the callback has to find its state through a global.
 */
#ifndef OL1N_ASIO_SHIM_H
#define OL1N_ASIO_SHIM_H

#include <stdint.h>
#include "rb.h"
#include "iasio.h"

#ifdef __cplusplus
extern "C" {
#endif

#define ASIO_MAX_CHANNELS 64

/* Error codes returned by every fallible function; details via asio_last_error(). */
enum {
    ASIO_SHIM_OK = 0,
    ASIO_SHIM_ECOM = -1,       /* COM / registry failure                   */
    ASIO_SHIM_EDRIVER = -2,    /* driver returned an ASIOError             */
    ASIO_SHIM_EARG = -3,       /* bad argument                             */
    ASIO_SHIM_ESTATE = -4,     /* called in the wrong state                */
    ASIO_SHIM_EBUSY = -5,      /* another driver is already open           */
};

typedef struct asio_dev asio_dev;

/* Thread-local description of the last failure on this thread. */
const char *asio_last_error(void);

/* COM apartment for the calling thread. Returns 0 on success. */
int  asio_com_init(void);
void asio_com_uninit(void);

/* Open the driver whose CLSID is the given string ("{...}"), call init().
 * sys_handle may be NULL; some drivers want an HWND for their control panel
 * parent, so the Go side passes a hidden message window when it has one. */
int asio_open(const char *clsid, void *sys_handle, asio_dev **out);

/* Release the driver and free the state. Stops and disposes buffers first. */
void asio_close(asio_dev *d);

int  asio_driver_name(asio_dev *d, char *buf, int len);
long asio_driver_version(asio_dev *d);
int  asio_get_channels(asio_dev *d, long *in, long *out);
int  asio_get_buffer_size(asio_dev *d, long *min, long *max, long *preferred, long *granularity);
int  asio_can_sample_rate(asio_dev *d, double sr);          /* 0 = yes, EDRIVER = no */
int  asio_get_sample_rate(asio_dev *d, double *sr);
int  asio_set_sample_rate(asio_dev *d, double sr);
int  asio_get_channel_info(asio_dev *d, long channel, int is_input, ASIOChannelInfo *info);
int  asio_get_latencies(asio_dev *d, long *in, long *out);
int  asio_control_panel(asio_dev *d);

/* DSD: query / switch the driver I/O format. */
int  asio_can_do_dsd(asio_dev *d);                          /* 0 = yes, EDRIVER = no */
int  asio_set_io_format(asio_dev *d, int dsd);
int  asio_get_io_format(asio_dev *d, int *dsd);

/* Create output buffers for channels 0..nch-1, nch <= ASIO_MAX_CHANNELS, with
 * the given buffer size (frames). rb must already have the channel count
 * and sample type the driver uses. affinity_core = -1 means "last core". */
int  asio_create_buffers(asio_dev *d, rb_t *rb, long nch, long frames, int affinity_core);
int  asio_dispose_buffers(asio_dev *d);

int  asio_start(asio_dev *d);
int  asio_stop(asio_dev *d);
int  asio_running(asio_dev *d);
int  asio_output_ready_supported(asio_dev *d);

/* Flags set from asioMessage; read-and-clear from Go. */
int  asio_take_flag(asio_dev *d, int which);
enum {
    ASIO_FLAG_RESET = 0,
    ASIO_FLAG_RESYNC = 1,
    ASIO_FLAG_BUFFER_SIZE = 2,
    ASIO_FLAG_LATENCIES = 3,
    ASIO_FLAG_OVERLOAD = 4,
    ASIO_FLAG_SRATE_CHANGED = 5,
};
double asio_reported_sample_rate(asio_dev *d); /* from sampleRateDidChange, 0 if none */

/* What the one-time thread setup in the callback achieved. */
void asio_thread_info(asio_dev *d, char *prio, int prio_len, int *core);

/* Pump pending window messages on the calling thread (drivers that create
 * windows need the apartment thread to dispatch). */
void asio_pump_messages(void);

/* Last ASIOError value seen (for diagnostics). */
long asio_last_asio_error(asio_dev *d);

#ifdef __cplusplus
}
#endif
#endif /* OL1N_ASIO_SHIM_H */
