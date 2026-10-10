/*
 * ca_shim.h — CoreAudio output for macOS development builds.
 *
 * AUHAL (kAudioUnitSubType_HALOutput) with the device's nominal sample rate
 * set to the track's rate, hog mode (exclusive) when available, and an
 * integer stream format matching the ring buffer. The render callback is
 * pure C: rb_read_interleaved into the AudioUnit buffer, nothing else.
 */
#ifndef OL1N_CA_SHIM_H
#define OL1N_CA_SHIM_H

#include <stdint.h>

#define CA_ERR_LEN 256
#define CA_NAME_LEN 256

typedef struct ca_device {
    uint32_t id;              /* AudioDeviceID */
    char     uid[CA_NAME_LEN];
    char     name[CA_NAME_LEN];
    int      is_default;
    int      max_channels;
    int      n_rates;
    double   rates[32];
} ca_device;

typedef struct ca_stream ca_stream;

/* Enumerates output devices into out[0..max). Returns count or <0. */
int ca_list_devices(ca_device *out, int max, char *err);

/* Opens the device (by UID, "" = default) at rate/channels/rb_type (enum
 * rb_sample_type from rb.h), creates the AUHAL, sets nominal sample rate,
 * tries hog mode. rb is the ring buffer pointer. */
ca_stream *ca_open(const char *uid, double rate, int channels, int rb_type,
                   int hog, void *rb, char *err);
int  ca_start(ca_stream *s, char *err);
int  ca_stop(ca_stream *s, char *err);
void ca_close(ca_stream *s);
int  ca_buffer_frames(ca_stream *s);
double ca_latency_ms(ca_stream *s);
double ca_actual_rate(ca_stream *s);
int  ca_hogged(ca_stream *s);

#endif
