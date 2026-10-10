/*
 * ffdec.h — thin C layer over libavformat/libavcodec.
 *
 * The rule of this file: samples are never converted. Whatever sample
 * format the codec produces (S16, S32 with 24 valid bits, float) is handed
 * to Go as interleaved native frames. Planar → interleaved is a memcpy of
 * bytes, not a conversion. No swresample anywhere.
 *
 * DSD files (.dsf/.dff) are special: FFmpeg's DSD "decoders" convert to
 * float PCM, which is exactly what we must not do. In DSD_RAW mode we read
 * the demuxer packets directly and only normalise bit order / planarity to
 * one byte (8 DSD bits, MSB first) per channel per frame.
 */
#ifndef OL1N_FFDEC_H
#define OL1N_FFDEC_H

#include <stdint.h>

#define FF_ERR_LEN 256
#define FF_TAG_LEN 512

enum ff_dsd_mode {
    FF_DSD_RAW = 0, /* raw DSD8 frames (for native DSD or DoP)         */
    FF_DSD_PCM = 1, /* let FFmpeg convert to float – NOT bit-perfect   */
};

typedef struct ff_info {
    /* stream */
    int     sample_rate;     /* PCM: Hz. DSD raw: DSD bit rate / 8 (byte frames per second) */
    int     channels;
    int     rb_type;         /* enum rb_sample_type (see native/rb.h) */
    int     bit_depth;       /* meaningful bits (bits_per_raw_sample), 0 if unknown/float */
    int     bitrate_kbps;
    int     lossless;
    int     dsd;
    int     dsd_rate;        /* DSD bit rate, e.g. 2822400 */
    int64_t duration_ms;
    int64_t nb_frames;       /* estimated total frames (0 = unknown) */
    char    codec[64];
    char    container[64];

    /* tags */
    char title[FF_TAG_LEN], artist[FF_TAG_LEN], album_artist[FF_TAG_LEN],
         album[FF_TAG_LEN], genre[FF_TAG_LEN], composer[FF_TAG_LEN],
         comment[FF_TAG_LEN], date[64], track[32], disc[32],
         replaygain_track[32];
    char   *lyrics;          /* malloc'd, may be NULL */

    /* embedded picture */
    uint8_t *picture;        /* malloc'd, may be NULL */
    int      picture_len;
    char     picture_mime[64];
} ff_info;

typedef struct ff_dec ff_dec;

/* Probe only: tags + format + picture. No audio decoded. 0 on success. */
int  ff_probe(const char *path, ff_info *out, char *err);
void ff_info_free(ff_info *info);

/* Open for decoding. Fills *info. NULL on error (err set). */
ff_dec *ff_open(const char *path, int dsd_mode, ff_info *info, char *err);

/* Decode up to max_frames interleaved frames into dst (frame size =
 * channels * rb_sample_bytes(rb_type)). Returns frames written, 0 at EOF,
 * negative on error (err set). */
int  ff_read(ff_dec *d, uint8_t *dst, int max_frames, char *err);

/* Seek to a frame position (best effort; decoders then skip to exact). */
int  ff_seek(ff_dec *d, int64_t frame, char *err);

void ff_close(ff_dec *d);

/* Library version strings for the about box. */
const char *ff_version_string(void);

#endif
