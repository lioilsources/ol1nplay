#include "ffdec.h"
#include "rb.h"

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
#include <libavutil/log.h>

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

struct ff_dec {
    AVFormatContext *fmt;
    AVCodecContext  *ctx;      /* NULL in DSD raw mode */
    AVPacket        *pkt;
    AVFrame         *frame;
    int              stream;
    int              channels;
    int              sample_bytes;
    int              frame_bytes;
    int              rb_type;
    enum AVSampleFormat av_fmt;
    int              planar;
    int              eof_sent;     /* flush packet queued */
    int              finished;     /* decoder drained */

    /* partially consumed decoded frame (PCM) */
    int              pend_off;     /* samples already copied out of ->frame */
    int              have_frame;

    /* DSD raw */
    int              dsd_raw;
    int              dsd_lsbf;
    int              dsd_planar;
    uint8_t         *dsd_buf;      /* interleaved MSB-first bytes of the current packet */
    int              dsd_len;      /* frames in dsd_buf */
    int              dsd_off;

    int64_t          cur_frame;    /* position of the next frame handed out */
    int64_t          skip_to;      /* after seek: discard until this frame (-1 = none) */
};

static void seterr(char *err, const char *what, int averr) {
    if (!err) return;
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    if (averr < 0) av_strerror(averr, buf, sizeof buf);
    snprintf(err, FF_ERR_LEN, "%s%s%s", what, averr < 0 ? ": " : "", buf);
}

static void copy_tag(char *dst, size_t n, AVDictionary *a, AVDictionary *b, const char *key) {
    AVDictionaryEntry *e = av_dict_get(a, key, NULL, AV_DICT_MATCH_CASE);
    if (!e) e = av_dict_get(a, key, NULL, 0);
    if (!e && b) e = av_dict_get(b, key, NULL, 0);
    if (e && e->value) { strncpy(dst, e->value, n - 1); dst[n - 1] = 0; }
}

static int map_sample_fmt(enum AVSampleFormat f, int *planar) {
    *planar = av_sample_fmt_is_planar(f);
    switch (av_get_packed_sample_fmt(f)) {
    case AV_SAMPLE_FMT_S16: return RB_S16;
    case AV_SAMPLE_FMT_S32: return RB_S32;
    case AV_SAMPLE_FMT_FLT: return RB_F32;
    case AV_SAMPLE_FMT_DBL: return RB_F64;
    default: return 0; /* U8 / S64: nothing we want to ship to a DAC */
    }
}

static int is_dsd(enum AVCodecID id) {
    return id == AV_CODEC_ID_DSD_LSBF || id == AV_CODEC_ID_DSD_MSBF ||
           id == AV_CODEC_ID_DSD_LSBF_PLANAR || id == AV_CODEC_ID_DSD_MSBF_PLANAR;
}

/* Fills the format + tag part of info from an opened format context. */
static int fill_info(AVFormatContext *fmt, int si, ff_info *info, char *err) {
    AVStream *st = fmt->streams[si];
    AVCodecParameters *par = st->codecpar;
    const AVCodecDescriptor *desc = avcodec_descriptor_get(par->codec_id);

    memset(info, 0, sizeof *info);
    info->sample_rate = par->sample_rate;
    info->channels    = par->ch_layout.nb_channels;
    info->bitrate_kbps = (int)((par->bit_rate ? par->bit_rate : fmt->bit_rate) / 1000);
    info->lossless = desc && (desc->props & AV_CODEC_PROP_LOSSLESS);
    snprintf(info->codec, sizeof info->codec, "%s", desc ? desc->name : "unknown");
    snprintf(info->container, sizeof info->container, "%s", fmt->iformat ? fmt->iformat->name : "");

    if (is_dsd(par->codec_id)) {
        info->dsd = 1;
        info->lossless = 1;
        info->rb_type = RB_DSD8;
        info->bit_depth = 1;
        /* libavformat reports DSD sample_rate as DSD bit rate / 8 (one byte = 8 bits). */
        info->dsd_rate = par->sample_rate * 8;
    } else {
        int planar;
        info->rb_type = map_sample_fmt((enum AVSampleFormat)par->format, &planar);
        if (info->rb_type == 0 && par->format != AV_SAMPLE_FMT_NONE) {
            seterr(err, "unsupported sample format", 0);
            return -1;
        }
        info->bit_depth = par->bits_per_raw_sample;
        if (info->bit_depth == 0) {
            if (info->rb_type == RB_S16) info->bit_depth = 16;
            else if (info->rb_type == RB_S32) info->bit_depth = 32;
            else info->bit_depth = 0; /* float: depth is meaningless */
        }
    }

    if (st->duration > 0 && st->time_base.den > 0) {
        info->duration_ms = av_rescale_q(st->duration, st->time_base, (AVRational){1, 1000});
        if (par->sample_rate > 0)
            info->nb_frames = av_rescale_q(st->duration, st->time_base, (AVRational){1, par->sample_rate});
    } else if (fmt->duration > 0) {
        info->duration_ms = fmt->duration / (AV_TIME_BASE / 1000);
        if (par->sample_rate > 0)
            info->nb_frames = av_rescale(fmt->duration, par->sample_rate, AV_TIME_BASE);
    }

    AVDictionary *fm = fmt->metadata, *sm = st->metadata;
    copy_tag(info->title,        FF_TAG_LEN, fm, sm, "title");
    copy_tag(info->artist,       FF_TAG_LEN, fm, sm, "artist");
    copy_tag(info->album_artist, FF_TAG_LEN, fm, sm, "album_artist");
    copy_tag(info->album,        FF_TAG_LEN, fm, sm, "album");
    copy_tag(info->genre,        FF_TAG_LEN, fm, sm, "genre");
    copy_tag(info->composer,     FF_TAG_LEN, fm, sm, "composer");
    copy_tag(info->comment,      FF_TAG_LEN, fm, sm, "comment");
    copy_tag(info->date,         sizeof info->date, fm, sm, "date");
    if (!info->date[0]) copy_tag(info->date, sizeof info->date, fm, sm, "year");
    copy_tag(info->track,        sizeof info->track, fm, sm, "track");
    copy_tag(info->disc,         sizeof info->disc, fm, sm, "disc");
    copy_tag(info->replaygain_track, sizeof info->replaygain_track, fm, sm, "REPLAYGAIN_TRACK_GAIN");
    if (!info->replaygain_track[0]) copy_tag(info->replaygain_track, sizeof info->replaygain_track, fm, sm, "replaygain_track_gain");

    /* Lyrics live under several keys: Vorbis "LYRICS"/"UNSYNCEDLYRICS", ID3 USLT
     * becomes "lyrics-eng" (language suffix), MP4 "lyrics". */
    AVDictionaryEntry *e = av_dict_get(fm, "lyrics", NULL, AV_DICT_IGNORE_SUFFIX);
    if (!e) e = av_dict_get(fm, "unsyncedlyrics", NULL, AV_DICT_IGNORE_SUFFIX);
    if (!e) e = av_dict_get(sm, "lyrics", NULL, AV_DICT_IGNORE_SUFFIX);
    if (e && e->value) info->lyrics = strdup(e->value);

    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *ps = fmt->streams[i];
        if ((ps->disposition & AV_DISPOSITION_ATTACHED_PIC) && ps->attached_pic.size > 0) {
            info->picture = (uint8_t *)malloc(ps->attached_pic.size);
            if (info->picture) {
                memcpy(info->picture, ps->attached_pic.data, ps->attached_pic.size);
                info->picture_len = ps->attached_pic.size;
            }
            const char *mime = "image/jpeg";
            if (ps->codecpar->codec_id == AV_CODEC_ID_PNG) mime = "image/png";
            else if (ps->codecpar->codec_id == AV_CODEC_ID_WEBP) mime = "image/webp";
            else if (ps->codecpar->codec_id == AV_CODEC_ID_BMP) mime = "image/bmp";
            else if (ps->codecpar->codec_id == AV_CODEC_ID_GIF) mime = "image/gif";
            snprintf(info->picture_mime, sizeof info->picture_mime, "%s", mime);
            break;
        }
    }
    return 0;
}

static int open_fmt(const char *path, AVFormatContext **fmt, int *si, char *err) {
    *fmt = NULL;
    int r = avformat_open_input(fmt, path, NULL, NULL);
    if (r < 0) { seterr(err, "open", r); return r; }
    r = avformat_find_stream_info(*fmt, NULL);
    if (r < 0) { seterr(err, "stream info", r); avformat_close_input(fmt); return r; }
    r = av_find_best_stream(*fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (r < 0) { seterr(err, "no audio stream", r); avformat_close_input(fmt); return r; }
    *si = r;
    return 0;
}

int ff_probe(const char *path, ff_info *out, char *err) {
    AVFormatContext *fmt; int si;
    if (open_fmt(path, &fmt, &si, err) < 0) return -1;
    int r = fill_info(fmt, si, out, err);
    avformat_close_input(&fmt);
    return r;
}

void ff_info_free(ff_info *info) {
    if (!info) return;
    free(info->lyrics);   info->lyrics = NULL;
    free(info->picture);  info->picture = NULL;
    info->picture_len = 0;
}

ff_dec *ff_open(const char *path, int dsd_mode, ff_info *info, char *err) {
    ff_dec *d = (ff_dec *)calloc(1, sizeof *d);
    if (!d) { seterr(err, "out of memory", 0); return NULL; }
    d->skip_to = -1;

    if (open_fmt(path, &d->fmt, &d->stream, err) < 0) { free(d); return NULL; }
    if (fill_info(d->fmt, d->stream, info, err) < 0) { ff_close(d); return NULL; }

    AVStream *st = d->fmt->streams[d->stream];
    AVCodecParameters *par = st->codecpar;
    d->channels = par->ch_layout.nb_channels;
    d->pkt = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->pkt || !d->frame) { seterr(err, "out of memory", 0); ff_close(d); return NULL; }

    if (info->dsd && dsd_mode == FF_DSD_RAW) {
        d->dsd_raw = 1;
        d->dsd_lsbf = par->codec_id == AV_CODEC_ID_DSD_LSBF || par->codec_id == AV_CODEC_ID_DSD_LSBF_PLANAR;
        d->dsd_planar = par->codec_id == AV_CODEC_ID_DSD_LSBF_PLANAR || par->codec_id == AV_CODEC_ID_DSD_MSBF_PLANAR;
        d->rb_type = RB_DSD8;
        d->sample_bytes = 1;
        d->frame_bytes = d->channels;
        return d;
    }

    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (!codec) { seterr(err, "no decoder", 0); ff_close(d); return NULL; }
    d->ctx = avcodec_alloc_context3(codec);
    if (!d->ctx) { seterr(err, "out of memory", 0); ff_close(d); return NULL; }
    int r = avcodec_parameters_to_context(d->ctx, par);
    if (r < 0) { seterr(err, "codec params", r); ff_close(d); return NULL; }
    d->ctx->pkt_timebase = st->time_base;
    /* Let libavcodec apply encoder delay / padding (gapless MP3/AAC/Opus). */
    d->ctx->flags2 &= ~AV_CODEC_FLAG2_SKIP_MANUAL;
    r = avcodec_open2(d->ctx, codec, NULL);
    if (r < 0) { seterr(err, "codec open", r); ff_close(d); return NULL; }

    d->av_fmt = d->ctx->sample_fmt;
    d->rb_type = map_sample_fmt(d->av_fmt, &d->planar);
    if (d->rb_type == 0) { seterr(err, "unsupported decoder sample format", 0); ff_close(d); return NULL; }
    d->sample_bytes = rb_sample_bytes(d->rb_type);
    d->frame_bytes = d->sample_bytes * d->channels;

    if (info->dsd && dsd_mode == FF_DSD_PCM) {
        /* The DSD→PCM path: FFmpeg's dsd decoder yields float at rate/8. */
        info->lossless = 0;
    }
    /* The probe guessed from codecpar; the opened decoder is authoritative. */
    info->rb_type = d->rb_type;
    if (d->ctx->bits_per_raw_sample > 0) info->bit_depth = d->ctx->bits_per_raw_sample;
    else if (d->rb_type == RB_S16) info->bit_depth = 16;
    else if (d->rb_type == RB_S32) info->bit_depth = 32;
    else info->bit_depth = 0;
    info->sample_rate = d->ctx->sample_rate;
    return d;
}

/* Reverse the bits of a byte (DSD lsbf → msbf). */
static const uint8_t bitrev[256] = {
#define R2(n) n, n + 2*64, n + 1*64, n + 3*64
#define R4(n) R2(n), R2(n + 2*16), R2(n + 1*16), R2(n + 3*16)
#define R6(n) R4(n), R4(n + 2*4 ), R4(n + 1*4 ), R4(n + 3*4 )
    R6(0), R6(2), R6(1), R6(3)
};

static int dsd_fill(ff_dec *d, char *err) {
    for (;;) {
        int r = av_read_frame(d->fmt, d->pkt);
        if (r == AVERROR_EOF) return 0;
        if (r < 0) { seterr(err, "read", r); return r; }
        if (d->pkt->stream_index != d->stream) { av_packet_unref(d->pkt); continue; }
        int frames = d->pkt->size / d->channels;
        if (frames <= 0) { av_packet_unref(d->pkt); continue; }
        uint8_t *nb = (uint8_t *)realloc(d->dsd_buf, (size_t)frames * d->channels);
        if (!nb) { av_packet_unref(d->pkt); seterr(err, "out of memory", 0); return -1; }
        d->dsd_buf = nb;
        const uint8_t *src = d->pkt->data;
        if (d->dsd_planar) {
            for (int c = 0; c < d->channels; c++) {
                const uint8_t *s = src + (size_t)c * frames;
                for (int i = 0; i < frames; i++) {
                    uint8_t v = s[i];
                    d->dsd_buf[(size_t)i * d->channels + c] = d->dsd_lsbf ? bitrev[v] : v;
                }
            }
        } else {
            size_t n = (size_t)frames * d->channels;
            if (d->dsd_lsbf) { for (size_t i = 0; i < n; i++) d->dsd_buf[i] = bitrev[src[i]]; }
            else memcpy(d->dsd_buf, src, n);
        }
        d->dsd_len = frames;
        d->dsd_off = 0;
        av_packet_unref(d->pkt);
        return frames;
    }
}

static int dsd_read(ff_dec *d, uint8_t *dst, int max_frames, char *err) {
    int out = 0;
    while (out < max_frames) {
        if (d->dsd_off >= d->dsd_len) {
            int r = dsd_fill(d, err);
            if (r <= 0) return out > 0 ? out : r;
        }
        int n = d->dsd_len - d->dsd_off;
        if (n > max_frames - out) n = max_frames - out;
        if (d->skip_to >= 0) {
            int64_t skip = d->skip_to - d->cur_frame;
            if (skip >= n) { d->dsd_off += n; d->cur_frame += n; continue; }
            if (skip > 0) { d->dsd_off += (int)skip; d->cur_frame += skip; n -= (int)skip; }
            d->skip_to = -1;
        }
        memcpy(dst + (size_t)out * d->frame_bytes, d->dsd_buf + (size_t)d->dsd_off * d->frame_bytes,
               (size_t)n * d->frame_bytes);
        d->dsd_off += n;
        d->cur_frame += n;
        out += n;
    }
    return out;
}

/* Copies samples [off, off+n) of the pending frame into dst, interleaving planar data. */
static void copy_samples(ff_dec *d, uint8_t *dst, int off, int n) {
    AVFrame *f = d->frame;
    int sb = d->sample_bytes, ch = d->channels;
    if (!d->planar) {
        memcpy(dst, f->data[0] + (size_t)off * d->frame_bytes, (size_t)n * d->frame_bytes);
        return;
    }
    for (int c = 0; c < ch; c++) {
        const uint8_t *s = f->extended_data[c] + (size_t)off * sb;
        uint8_t *o = dst + (size_t)c * sb;
        if (sb == 2) {
            for (int i = 0; i < n; i++) *(uint16_t *)(o + (size_t)i * d->frame_bytes) = ((const uint16_t *)s)[i];
        } else if (sb == 4) {
            for (int i = 0; i < n; i++) *(uint32_t *)(o + (size_t)i * d->frame_bytes) = ((const uint32_t *)s)[i];
        } else if (sb == 8) {
            for (int i = 0; i < n; i++) *(uint64_t *)(o + (size_t)i * d->frame_bytes) = ((const uint64_t *)s)[i];
        } else {
            for (int i = 0; i < n; i++) memcpy(o + (size_t)i * d->frame_bytes, s + (size_t)i * sb, sb);
        }
    }
}

/* Pulls the next decoded frame into d->frame. Returns 1, 0 at EOF, <0 error. */
static int next_frame(ff_dec *d, char *err) {
    for (;;) {
        int r = avcodec_receive_frame(d->ctx, d->frame);
        if (r == 0) {
            if (d->frame->format != (int)d->av_fmt) {
                seterr(err, "decoder changed sample format mid-stream", 0);
                av_frame_unref(d->frame);
                return -1;
            }
            /* Trust the decoder's timestamps when it has them: after a seek the
             * demuxer lands on a packet boundary and we skip to the exact frame. */
            if (d->frame->pts != AV_NOPTS_VALUE && d->ctx->sample_rate > 0) {
                AVStream *st = d->fmt->streams[d->stream];
                d->cur_frame = av_rescale_q(d->frame->pts, st->time_base, (AVRational){1, d->ctx->sample_rate});
            }
            return 1;
        }
        if (r == AVERROR_EOF) { d->finished = 1; return 0; }
        if (r != AVERROR(EAGAIN)) { seterr(err, "decode", r); return r; }
        if (d->eof_sent) { d->finished = 1; return 0; }

        r = av_read_frame(d->fmt, d->pkt);
        if (r == AVERROR_EOF) {
            d->eof_sent = 1;
            avcodec_send_packet(d->ctx, NULL);
            continue;
        }
        if (r < 0) { seterr(err, "read", r); return r; }
        if (d->pkt->stream_index != d->stream) { av_packet_unref(d->pkt); continue; }
        r = avcodec_send_packet(d->ctx, d->pkt);
        av_packet_unref(d->pkt);
        if (r < 0 && r != AVERROR(EAGAIN)) {
            /* A damaged packet should not kill the track; log-free skip. */
            if (r == AVERROR_INVALIDDATA) continue;
            seterr(err, "send packet", r);
            return r;
        }
    }
}

int ff_read(ff_dec *d, uint8_t *dst, int max_frames, char *err) {
    if (!d || max_frames <= 0) return 0;
    if (d->dsd_raw) return dsd_read(d, dst, max_frames, err);

    int out = 0;
    while (out < max_frames) {
        if (!d->have_frame) {
            if (d->finished) break;
            int r = next_frame(d, err);
            if (r < 0) return out > 0 ? out : r;
            if (r == 0) break;
            d->have_frame = 1;
            d->pend_off = 0;
            if (d->skip_to >= 0) {
                int64_t skip = d->skip_to - d->cur_frame;
                if (skip >= d->frame->nb_samples) {
                    d->cur_frame += d->frame->nb_samples;
                    av_frame_unref(d->frame);
                    d->have_frame = 0;
                    continue;
                }
                if (skip > 0) { d->pend_off = (int)skip; d->cur_frame += skip; }
                d->skip_to = -1;
            }
        }
        int avail = d->frame->nb_samples - d->pend_off;
        int n = avail < max_frames - out ? avail : max_frames - out;
        copy_samples(d, dst + (size_t)out * d->frame_bytes, d->pend_off, n);
        d->pend_off += n;
        d->cur_frame += n;
        out += n;
        if (d->pend_off >= d->frame->nb_samples) {
            av_frame_unref(d->frame);
            d->have_frame = 0;
        }
    }
    return out;
}

int ff_seek(ff_dec *d, int64_t frame, char *err) {
    if (!d) return -1;
    AVStream *st = d->fmt->streams[d->stream];
    int rate = d->ctx ? d->ctx->sample_rate : st->codecpar->sample_rate;
    if (frame < 0) frame = 0;
    int64_t ts = av_rescale_q(frame, (AVRational){1, rate}, st->time_base);
    int r = av_seek_frame(d->fmt, d->stream, ts, AVSEEK_FLAG_BACKWARD);
    if (r < 0) { seterr(err, "seek", r); return r; }
    if (d->ctx) avcodec_flush_buffers(d->ctx);
    if (d->have_frame) { av_frame_unref(d->frame); d->have_frame = 0; }
    d->pend_off = 0;
    d->eof_sent = 0;
    d->finished = 0;
    d->dsd_len = d->dsd_off = 0;
    /* Demuxers without timestamps (raw DSD, some WAV) land where they land; we
     * assume the seek hit <= target and skip forward to the exact frame. */
    d->cur_frame = av_rescale_q(ts, st->time_base, (AVRational){1, rate});
    if (d->cur_frame > frame) d->cur_frame = frame;
    d->skip_to = frame;
    return 0;
}

void ff_close(ff_dec *d) {
    if (!d) return;
    if (d->frame) av_frame_free(&d->frame);
    if (d->pkt) av_packet_free(&d->pkt);
    if (d->ctx) avcodec_free_context(&d->ctx);
    if (d->fmt) avformat_close_input(&d->fmt);
    free(d->dsd_buf);
    free(d);
}

const char *ff_version_string(void) {
    static char buf[128];
    snprintf(buf, sizeof buf, "FFmpeg %s (avcodec %u.%u.%u, avformat %u.%u.%u)",
             av_version_info(),
             avcodec_version() >> 16, (avcodec_version() >> 8) & 0xff, avcodec_version() & 0xff,
             avformat_version() >> 16, (avformat_version() >> 8) & 0xff, avformat_version() & 0xff);
    return buf;
}
