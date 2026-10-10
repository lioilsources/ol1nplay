/*
 * wasapi_shim.h — C side of the WASAPI exclusive-mode backend.
 *
 * WASAPI is the fallback for machines without an ASIO driver. Exclusive
 * mode gives us the device untouched by the Windows mixer (no resampling,
 * no volume, no APOs), which is as bit-perfect as the shared engine allows.
 * Event-driven: the engine signals an event each period, our own C thread
 * fills exactly one period from the ring buffer.
 */
#ifndef OL1N_WASAPI_SHIM_H
#define OL1N_WASAPI_SHIM_H

#include <stdint.h>
#include "rb.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    WASAPI_OK = 0,
    WASAPI_ECOM = -1,          /* COM failure (details in wasapi_last_error)        */
    WASAPI_EFORMAT = -2,       /* device refuses the format in exclusive mode       */
    WASAPI_EEXCLUSIVE = -3,    /* exclusive mode disallowed in Sound settings       */
    WASAPI_EARG = -4,
    WASAPI_ESTATE = -5,
    WASAPI_ENODEVICE = -6,
    WASAPI_EINUSE = -7,        /* another exclusive stream holds the device         */
};

typedef struct wasapi_device_info {
    char id[512];     /* endpoint ID string, UTF-8                                */
    char name[256];   /* PKEY_Device_FriendlyName, UTF-8                          */
    int  is_default;  /* default render endpoint for the console role              */
} wasapi_device_info;

typedef struct wasapi_dev wasapi_dev;

const char *wasapi_last_error(void);

int  wasapi_com_init(void);
void wasapi_com_uninit(void);

/* Fills out[0..max) with active render endpoints; *count is the total found. */
int wasapi_enumerate(wasapi_device_info *out, int max, int *count);

/* Asks IsFormatSupported(EXCLUSIVE) without opening a stream. 0 = yes. */
int wasapi_format_supported(const char *id, int sr, int ch, int container_bits,
                            int valid_bits, int is_float, uint32_t channel_mask);

/* Opens the endpoint in exclusive event-driven mode with the given format.
 * rb must be sized for ch channels and the matching sample type. The
 * stream is created stopped. affinity_core -1 = last logical core. */
int wasapi_open(const char *id, int sr, int ch, int container_bits, int valid_bits,
                int is_float, uint32_t channel_mask, rb_t *rb, int affinity_core,
                wasapi_dev **out);

int    wasapi_buffer_frames(wasapi_dev *d);
double wasapi_latency_ms(wasapi_dev *d);
int    wasapi_start(wasapi_dev *d);
int    wasapi_stop(wasapi_dev *d);          /* synchronous: joins the render thread */
void   wasapi_close(wasapi_dev *d);
int    wasapi_running(wasapi_dev *d);
int    wasapi_device_invalidated(wasapi_dev *d); /* device unplugged / format changed */
long   wasapi_event_timeouts(wasapi_dev *d);
void   wasapi_thread_info(wasapi_dev *d, char *prio, int prio_len, int *core);

#ifdef __cplusplus
}
#endif
#endif /* OL1N_WASAPI_SHIM_H */
