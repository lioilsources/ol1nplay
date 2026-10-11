/*
 * rb.h — lock-free single-producer / single-consumer ring buffer of
 * interleaved PCM frames, shared by every output backend.
 *
 * Header-only (static inline) on purpose: the ASIO / WASAPI / CoreAudio
 * callbacks are pure C and must never call into Go. Each cgo package that
 * includes this header gets its own copy of the functions; the struct is
 * shared by pointer.
 *
 * Real-time rules for the consumer side (rb_read_*):
 *   - no allocation, no locks, no syscalls, no logging
 *   - underrun → zero-fill and count; never block
 *   - mono downmix is the only arithmetic allowed, and only when asked;
 *     routing that mix to a single speaker only writes zeros to the other
 *
 * The producer (Go feeder goroutine) owns write_pos, the consumer (audio
 * callback) owns read_pos. Both are 64-bit monotonic frame counters; the
 * buffer index is counter & mask (capacity is a power of two).
 */
#ifndef OL1N_RB_H
#define OL1N_RB_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

#ifdef __cplusplus
extern "C" {
#endif

enum rb_sample_type {
    RB_S16   = 1,  /* int16 little-endian                       */
    RB_S24_3 = 2,  /* int24 packed in 3 bytes, little-endian     */
    RB_S32   = 3,  /* int32 (also 24-in-32, LSB-justified)       */
    RB_F32   = 4,  /* IEEE float32                               */
    RB_F64   = 5,  /* IEEE float64                               */
    RB_DSD8  = 6,  /* 8 DSD bits per byte, MSB first, per channel */
};

enum rb_mono_mode {
    RB_STEREO     = 0,  /* untouched                                   */
    RB_MONO       = 1,  /* (L+R)/2 into every channel                  */
    RB_MONO_LEFT  = 2,  /* (L+R)/2 into channel 0, silence elsewhere   */
    RB_MONO_RIGHT = 3,  /* (L+R)/2 into channel 1, silence elsewhere   */
};

typedef struct rb {
    _Atomic uint64_t write_pos;      /* frames produced so far           */
    _Atomic uint64_t read_pos;       /* frames consumed so far           */
    uint32_t capacity;               /* frames, power of two             */
    uint32_t mask;
    uint32_t channels;
    uint32_t sample_bytes;
    uint32_t frame_bytes;
    int      sample_type;            /* enum rb_sample_type              */

    /* control flags written by Go, read by the callback (atomic)        */
    _Atomic int mono;                /* enum rb_mono_mode                */
    _Atomic int muted;               /* 1 = output silence (pause)       */

    /* statistics written by the callback, read by Go                    */
    _Atomic uint64_t underruns;      /* number of callbacks short of data */
    _Atomic uint64_t underrun_frames;
    _Atomic uint64_t frames_out;     /* frames handed to the device       */
    _Atomic uint64_t callbacks;
    _Atomic int64_t  max_cb_ns;      /* longest callback, if measured     */
    _Atomic int64_t  last_underrun_ns;

    uint8_t *data;
} rb_t;

static inline uint32_t rb__pow2(uint32_t v) {
    uint32_t p = 1;
    while (p < v) p <<= 1;
    return p;
}

static inline uint32_t rb_sample_bytes(int t) {
    switch (t) {
    case RB_S16:   return 2;
    case RB_S24_3: return 3;
    case RB_S32:   return 4;
    case RB_F32:   return 4;
    case RB_F64:   return 8;
    case RB_DSD8:  return 1;
    default:       return 0;
    }
}

static inline rb_t *rb_create(uint32_t frames, uint32_t channels, int sample_type) {
    uint32_t sb = rb_sample_bytes(sample_type);
    if (sb == 0 || channels == 0 || frames == 0) return NULL;
    rb_t *rb = (rb_t *)calloc(1, sizeof(rb_t));
    if (!rb) return NULL;
    rb->capacity     = rb__pow2(frames);
    rb->mask         = rb->capacity - 1;
    rb->channels     = channels;
    rb->sample_bytes = sb;
    rb->frame_bytes  = sb * channels;
    rb->sample_type  = sample_type;
    rb->data = (uint8_t *)calloc((size_t)rb->capacity, rb->frame_bytes);
    if (!rb->data) { free(rb); return NULL; }
    atomic_init(&rb->write_pos, 0);
    atomic_init(&rb->read_pos, 0);
    atomic_init(&rb->mono, 0);
    atomic_init(&rb->muted, 0);
    atomic_init(&rb->underruns, 0);
    atomic_init(&rb->underrun_frames, 0);
    atomic_init(&rb->frames_out, 0);
    atomic_init(&rb->callbacks, 0);
    atomic_init(&rb->max_cb_ns, 0);
    atomic_init(&rb->last_underrun_ns, 0);
    return rb;
}

static inline void rb_destroy(rb_t *rb) {
    if (!rb) return;
    free(rb->data);
    free(rb);
}

/* ---- producer side ---------------------------------------------------- */

static inline uint32_t rb_fill(const rb_t *rb) {
    uint64_t w = atomic_load_explicit(&rb->write_pos, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&rb->read_pos, memory_order_acquire);
    return (uint32_t)(w - r);
}

static inline uint32_t rb_write_available(const rb_t *rb) {
    return rb->capacity - rb_fill(rb);
}

/* Copies up to `frames` interleaved frames from src; returns frames written. */
static inline uint32_t rb_write(rb_t *rb, const void *src, uint32_t frames) {
    uint32_t avail = rb_write_available(rb);
    if (frames > avail) frames = avail;
    if (frames == 0) return 0;
    uint64_t w = atomic_load_explicit(&rb->write_pos, memory_order_relaxed);
    uint32_t idx = (uint32_t)(w & rb->mask);
    uint32_t first = rb->capacity - idx;
    if (first > frames) first = frames;
    const uint8_t *s = (const uint8_t *)src;
    memcpy(rb->data + (size_t)idx * rb->frame_bytes, s, (size_t)first * rb->frame_bytes);
    if (frames > first) {
        memcpy(rb->data, s + (size_t)first * rb->frame_bytes,
               (size_t)(frames - first) * rb->frame_bytes);
    }
    atomic_store_explicit(&rb->write_pos, w + frames, memory_order_release);
    return frames;
}

/* Drop everything buffered. Only safe when the consumer is stopped or when
 * a brief glitch is acceptable (seek / flush): the consumer may be mid-read,
 * which at worst yields one zero-filled callback. */
static inline void rb_reset(rb_t *rb) {
    uint64_t w = atomic_load_explicit(&rb->write_pos, memory_order_acquire);
    atomic_store_explicit(&rb->read_pos, w, memory_order_release);
}

/* ---- consumer side (real-time) ---------------------------------------- */

/* Mono downmix of one interleaved frame in place, in the native type.
 * Arithmetic is done in double, result truncated toward zero: the error is
 * below 1 LSB and documented as such. Channels > 2 average all channels. */
static inline void rb__mono_frame(uint8_t *f, int type, uint32_t ch) {
    uint32_t c;
    switch (type) {
    case RB_S16: {
        int16_t *p = (int16_t *)f; double acc = 0;
        for (c = 0; c < ch; c++) acc += p[c];
        int32_t v = (int32_t)(acc / ch);
        for (c = 0; c < ch; c++) p[c] = (int16_t)v;
        break;
    }
    case RB_S24_3: {
        double acc = 0;
        for (c = 0; c < ch; c++) {
            uint8_t *b = f + c * 3;
            int32_t v = (int32_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16));
            if (v & 0x800000) v |= (int32_t)0xFF000000;
            acc += v;
        }
        int32_t m = (int32_t)(acc / ch);
        for (c = 0; c < ch; c++) {
            uint8_t *b = f + c * 3;
            b[0] = (uint8_t)(m); b[1] = (uint8_t)(m >> 8); b[2] = (uint8_t)(m >> 16);
        }
        break;
    }
    case RB_S32: {
        int32_t *p = (int32_t *)f; double acc = 0;
        for (c = 0; c < ch; c++) acc += p[c];
        int32_t v = (int32_t)(acc / ch);
        for (c = 0; c < ch; c++) p[c] = v;
        break;
    }
    case RB_F32: {
        float *p = (float *)f; double acc = 0;
        for (c = 0; c < ch; c++) acc += p[c];
        float v = (float)(acc / ch);
        for (c = 0; c < ch; c++) p[c] = v;
        break;
    }
    case RB_F64: {
        double *p = (double *)f; double acc = 0;
        for (c = 0; c < ch; c++) acc += p[c];
        double v = acc / ch;
        for (c = 0; c < ch; c++) p[c] = v;
        break;
    }
    default: break; /* DSD: mono is not defined, leave untouched */
    }
}

/* One frame through a mono mode: the downmix, then silence in every
 * channel but the chosen one for the single-speaker modes. DSD is left
 * alone throughout — zero bytes are not DSD silence. */
static inline void rb__mono_apply(uint8_t *f, int type, uint32_t ch, uint32_t sb, int mode) {
    if (type == RB_DSD8) return;
    rb__mono_frame(f, type, ch);
    if (mode == RB_MONO_LEFT || mode == RB_MONO_RIGHT) {
        uint32_t keep = mode == RB_MONO_LEFT ? 0 : 1, c;
        for (c = 0; c < ch; c++) if (c != keep) memset(f + c * sb, 0, sb);
    }
}

/* Reads `frames` interleaved frames into dst. Short reads are zero-filled
 * and counted as an underrun. Applies mono when requested. Returns the
 * number of real (non-silence) frames delivered. */
static inline uint32_t rb_read_interleaved(rb_t *rb, void *dst, uint32_t frames) {
    atomic_fetch_add_explicit(&rb->callbacks, 1, memory_order_relaxed);
    uint8_t *d = (uint8_t *)dst;
    if (atomic_load_explicit(&rb->muted, memory_order_relaxed)) {
        memset(d, 0, (size_t)frames * rb->frame_bytes);
        return 0;
    }
    uint32_t avail = rb_fill(rb);
    uint32_t n = frames < avail ? frames : avail;
    if (n > 0) {
        uint64_t r = atomic_load_explicit(&rb->read_pos, memory_order_relaxed);
        uint32_t idx = (uint32_t)(r & rb->mask);
        uint32_t first = rb->capacity - idx;
        if (first > n) first = n;
        memcpy(d, rb->data + (size_t)idx * rb->frame_bytes, (size_t)first * rb->frame_bytes);
        if (n > first) {
            memcpy(d + (size_t)first * rb->frame_bytes, rb->data,
                   (size_t)(n - first) * rb->frame_bytes);
        }
        atomic_store_explicit(&rb->read_pos, r + n, memory_order_release);
        int mono = atomic_load_explicit(&rb->mono, memory_order_relaxed);
        if (mono != RB_STEREO && rb->channels > 1) {
            uint32_t i;
            for (i = 0; i < n; i++) rb__mono_apply(d + (size_t)i * rb->frame_bytes, rb->sample_type, rb->channels, rb->sample_bytes, mono);
        }
    }
    if (n < frames) {
        memset(d + (size_t)n * rb->frame_bytes, 0, (size_t)(frames - n) * rb->frame_bytes);
        if (avail == 0 || n < frames) {
            atomic_fetch_add_explicit(&rb->underruns, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&rb->underrun_frames, frames - n, memory_order_relaxed);
        }
    }
    atomic_fetch_add_explicit(&rb->frames_out, n, memory_order_relaxed);
    return n;
}

/* Reads `frames` frames and scatters them into one buffer per channel
 * (ASIO hands us separate channel buffers). dsts[c] must hold frames *
 * sample_bytes bytes. Same underrun / mono semantics as above. */
static inline uint32_t rb_read_deinterleaved(rb_t *rb, void **dsts, uint32_t frames) {
    atomic_fetch_add_explicit(&rb->callbacks, 1, memory_order_relaxed);
    uint32_t ch = rb->channels, sb = rb->sample_bytes, c, i;
    if (atomic_load_explicit(&rb->muted, memory_order_relaxed)) {
        for (c = 0; c < ch; c++) memset(dsts[c], 0, (size_t)frames * sb);
        return 0;
    }
    uint32_t avail = rb_fill(rb);
    uint32_t n = frames < avail ? frames : avail;
    int mono = ch > 1 ? atomic_load_explicit(&rb->mono, memory_order_relaxed) : RB_STEREO;
    if (n > 0) {
        uint64_t r = atomic_load_explicit(&rb->read_pos, memory_order_relaxed);
        for (i = 0; i < n; i++) {
            uint8_t *f = rb->data + (size_t)((r + i) & rb->mask) * rb->frame_bytes;
            if (mono != RB_STEREO) rb__mono_apply(f, rb->sample_type, ch, sb, mono);
            for (c = 0; c < ch; c++) {
                memcpy((uint8_t *)dsts[c] + (size_t)i * sb, f + c * sb, sb);
            }
        }
        atomic_store_explicit(&rb->read_pos, r + n, memory_order_release);
    }
    if (n < frames) {
        for (c = 0; c < ch; c++) memset((uint8_t *)dsts[c] + (size_t)n * sb, 0, (size_t)(frames - n) * sb);
        atomic_fetch_add_explicit(&rb->underruns, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&rb->underrun_frames, frames - n, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&rb->frames_out, n, memory_order_relaxed);
    return n;
}

/* ---- accessors (cgo cannot read _Atomic fields directly) -------------- */

static inline uint32_t rb_capacity(const rb_t *rb)    { return rb->capacity; }
static inline uint32_t rb_frame_bytes(const rb_t *rb) { return rb->frame_bytes; }
static inline uint32_t rb_channels(const rb_t *rb)    { return rb->channels; }
static inline int      rb_type(const rb_t *rb)        { return rb->sample_type; }
static inline void rb_set_mono(rb_t *rb, int v)  { atomic_store_explicit(&rb->mono, v, memory_order_relaxed); }
static inline void rb_set_muted(rb_t *rb, int v) { atomic_store_explicit(&rb->muted, v, memory_order_relaxed); }
static inline int  rb_get_mono(const rb_t *rb)   { return atomic_load_explicit(&rb->mono, memory_order_relaxed); }
static inline uint64_t rb_underruns(const rb_t *rb)       { return atomic_load_explicit(&rb->underruns, memory_order_relaxed); }
static inline uint64_t rb_underrun_frames(const rb_t *rb) { return atomic_load_explicit(&rb->underrun_frames, memory_order_relaxed); }
static inline uint64_t rb_frames_out(const rb_t *rb)      { return atomic_load_explicit(&rb->frames_out, memory_order_relaxed); }
static inline uint64_t rb_callbacks(const rb_t *rb)       { return atomic_load_explicit(&rb->callbacks, memory_order_relaxed); }
static inline int64_t  rb_max_cb_ns(const rb_t *rb)       { return atomic_load_explicit(&rb->max_cb_ns, memory_order_relaxed); }
static inline int64_t  rb_last_underrun_ns(const rb_t *rb){ return atomic_load_explicit(&rb->last_underrun_ns, memory_order_relaxed); }
/* Backends call this from the callback with their own monotonic clock. */
static inline void rb_note_cb_ns(rb_t *rb, int64_t ns) {
    int64_t m = atomic_load_explicit(&rb->max_cb_ns, memory_order_relaxed);
    if (ns > m) atomic_store_explicit(&rb->max_cb_ns, ns, memory_order_relaxed);
}
static inline void rb_note_underrun_ns(rb_t *rb, int64_t ns) {
    atomic_store_explicit(&rb->last_underrun_ns, ns, memory_order_relaxed);
}
/* Reset the counters (new track / new device). */
static inline void rb_reset_stats(rb_t *rb) {
    atomic_store_explicit(&rb->underruns, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->underrun_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->frames_out, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->callbacks, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->max_cb_ns, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->last_underrun_ns, 0, memory_order_relaxed);
}

#ifdef __cplusplus
}
#endif
#endif /* OL1N_RB_H */
