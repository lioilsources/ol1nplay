//go:build darwin

#include "ca_shim.h"
#include "rb.h"

#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

struct ca_stream {
    AudioDeviceID dev;
    AudioUnit     unit;
    rb_t         *rb;
    int           channels;
    int           rb_type;
    double        rate;
    int           running;
    int           hogged;
    pid_t         prev_hog;
    double        prev_rate;
    UInt32        buffer_frames;
};

static void seterr(char *err, const char *what, OSStatus st) {
    if (!err) return;
    if (st) snprintf(err, CA_ERR_LEN, "%s (OSStatus %d)", what, (int)st);
    else snprintf(err, CA_ERR_LEN, "%s", what);
}

static int cfstr_to_c(CFStringRef s, char *out, size_t n) {
    if (!s) { out[0] = 0; return 0; }
    if (!CFStringGetCString(s, out, (CFIndex)n, kCFStringEncodingUTF8)) out[0] = 0;
    return 1;
}

static int device_output_channels(AudioDeviceID dev) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != noErr || size == 0) return 0;
    AudioBufferList *bl = (AudioBufferList *)malloc(size);
    if (!bl) return 0;
    int ch = 0;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, bl) == noErr) {
        for (UInt32 i = 0; i < bl->mNumberBuffers; i++) ch += bl->mBuffers[i].mNumberChannels;
    }
    free(bl);
    return ch;
}

int ca_list_devices(ca_device *out, int max, char *err) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    OSStatus st = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size);
    if (st != noErr) { seterr(err, "device list size", st); return -1; }
    int n = (int)(size / sizeof(AudioDeviceID));
    AudioDeviceID *ids = (AudioDeviceID *)malloc(size);
    if (!ids) { seterr(err, "out of memory", 0); return -1; }
    st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids);
    if (st != noErr) { free(ids); seterr(err, "device list", st); return -1; }

    AudioDeviceID def = 0;
    AudioObjectPropertyAddress da = { kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 ds = sizeof def;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &da, 0, NULL, &ds, &def);

    int count = 0;
    for (int i = 0; i < n && count < max; i++) {
        int ch = device_output_channels(ids[i]);
        if (ch == 0) continue;
        ca_device *d = &out[count];
        memset(d, 0, sizeof *d);
        d->id = ids[i];
        d->max_channels = ch;
        d->is_default = ids[i] == def;

        CFStringRef s = NULL; UInt32 ss = sizeof s;
        AudioObjectPropertyAddress na = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &ss, &s) == noErr && s) { cfstr_to_c(s, d->name, sizeof d->name); CFRelease(s); }
        s = NULL; ss = sizeof s;
        AudioObjectPropertyAddress ua = { kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        if (AudioObjectGetPropertyData(ids[i], &ua, 0, NULL, &ss, &s) == noErr && s) { cfstr_to_c(s, d->uid, sizeof d->uid); CFRelease(s); }

        AudioObjectPropertyAddress ra = { kAudioDevicePropertyAvailableNominalSampleRates,
            kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        UInt32 rs = 0;
        if (AudioObjectGetPropertyDataSize(ids[i], &ra, 0, NULL, &rs) == noErr && rs > 0) {
            int nr = (int)(rs / sizeof(AudioValueRange));
            AudioValueRange *vr = (AudioValueRange *)malloc(rs);
            if (vr && AudioObjectGetPropertyData(ids[i], &ra, 0, NULL, &rs, vr) == noErr) {
                for (int k = 0; k < nr && d->n_rates < 32; k++) {
                    /* Ranges with min==max are discrete rates; a true range is
                     * reported by its endpoints so the UI can show it. */
                    d->rates[d->n_rates++] = vr[k].mMinimum;
                    if (vr[k].mMaximum != vr[k].mMinimum && d->n_rates < 32) d->rates[d->n_rates++] = vr[k].mMaximum;
                }
            }
            free(vr);
        }
        count++;
    }
    free(ids);
    return count;
}

static int find_device(const char *uid, AudioDeviceID *out) {
    ca_device devs[64];
    int n = ca_list_devices(devs, 64, NULL);
    if (n <= 0) return -1;
    for (int i = 0; i < n; i++) {
        if ((uid == NULL || uid[0] == 0) ? devs[i].is_default : strcmp(devs[i].uid, uid) == 0) {
            *out = devs[i].id;
            return 0;
        }
    }
    if (uid == NULL || uid[0] == 0) { *out = devs[0].id; return 0; }
    return -1;
}

static OSStatus render_cb(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                          UInt32 bus, UInt32 frames, AudioBufferList *io) {
    (void)flags; (void)ts; (void)bus;
    ca_stream *s = (ca_stream *)ref;
    uint64_t t0 = mach_absolute_time();
    /* Interleaved format: exactly one buffer. */
    rb_read_interleaved(s->rb, io->mBuffers[0].mData, frames);
    uint64_t t1 = mach_absolute_time();
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    rb_note_cb_ns(s->rb, (int64_t)((t1 - t0) * tb.numer / tb.denom));
    return noErr;
}

static int set_nominal_rate(AudioDeviceID dev, double rate, double *prev, char *err) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = sizeof(double);
    double cur = 0;
    AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &cur);
    if (prev) *prev = cur;
    if (cur == rate) return 0;
    OSStatus st = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof rate, &rate);
    if (st != noErr) { seterr(err, "device does not accept this sample rate", st); return -1; }
    /* The rate change is asynchronous on most devices; wait up to ~2 s. */
    for (int i = 0; i < 200; i++) {
        sz = sizeof cur;
        if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &cur) == noErr && cur == rate) return 0;
        usleep(10000);
    }
    seterr(err, "sample rate change did not take effect", 0);
    return -1;
}

ca_stream *ca_open(const char *uid, double rate, int channels, int rb_type, int hog, void *rbp, char *err) {
    ca_stream *s = (ca_stream *)calloc(1, sizeof *s);
    if (!s) { seterr(err, "out of memory", 0); return NULL; }
    s->rb = (rb_t *)rbp;
    s->channels = channels;
    s->rb_type = rb_type;
    s->rate = rate;
    s->prev_hog = -1;

    if (find_device(uid, &s->dev) != 0) { seterr(err, "no such device", 0); free(s); return NULL; }

    if (hog) {
        AudioObjectPropertyAddress ha = { kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        pid_t owner = -1; UInt32 hs = sizeof owner;
        AudioObjectGetPropertyData(s->dev, &ha, 0, NULL, &hs, &owner);
        if (owner == -1) {
            pid_t me = getpid();
            if (AudioObjectSetPropertyData(s->dev, &ha, 0, NULL, sizeof me, &me) == noErr) s->hogged = 1;
        } else if (owner == getpid()) {
            s->hogged = 1;
        }
    }

    if (set_nominal_rate(s->dev, rate, &s->prev_rate, err) != 0) { ca_close(s); return NULL; }

    AudioComponentDescription desc = { kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
        kAudioUnitManufacturer_Apple, 0, 0 };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) { seterr(err, "AUHAL not found", 0); ca_close(s); return NULL; }
    OSStatus st = AudioComponentInstanceNew(comp, &s->unit);
    if (st != noErr) { seterr(err, "AudioComponentInstanceNew", st); ca_close(s); return NULL; }

    UInt32 on = 1, off = 0;
    AudioUnitSetProperty(s->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, sizeof on);
    AudioUnitSetProperty(s->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, sizeof off);
    st = AudioUnitSetProperty(s->unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &s->dev, sizeof s->dev);
    if (st != noErr) { seterr(err, "set current device", st); ca_close(s); return NULL; }

    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mChannelsPerFrame = channels;
    f.mFramesPerPacket = 1;
    switch (rb_type) {
    case RB_S16:   f.mBitsPerChannel = 16; f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked; break;
    case RB_S24_3: f.mBitsPerChannel = 24; f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked; break;
    case RB_S32:   f.mBitsPerChannel = 32; f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked; break;
    case RB_F32:   f.mBitsPerChannel = 32; f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked; break;
    default: seterr(err, "unsupported sample type for CoreAudio", 0); ca_close(s); return NULL;
    }
    f.mBytesPerFrame = (f.mBitsPerChannel / 8) * channels;
    f.mBytesPerPacket = f.mBytesPerFrame;
    st = AudioUnitSetProperty(s->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
    if (st != noErr) { seterr(err, "device rejected the stream format", st); ca_close(s); return NULL; }

    AURenderCallbackStruct cb = { render_cb, s };
    st = AudioUnitSetProperty(s->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    if (st != noErr) { seterr(err, "set render callback", st); ca_close(s); return NULL; }

    st = AudioUnitInitialize(s->unit);
    if (st != noErr) { seterr(err, "AudioUnitInitialize", st); ca_close(s); return NULL; }

    UInt32 bf = 0, bs = sizeof bf;
    AudioObjectPropertyAddress ba = { kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(s->dev, &ba, 0, NULL, &bs, &bf) == noErr) s->buffer_frames = bf;
    return s;
}

int ca_start(ca_stream *s, char *err) {
    if (s->running) return 0;
    OSStatus st = AudioOutputUnitStart(s->unit);
    if (st != noErr) { seterr(err, "AudioOutputUnitStart", st); return -1; }
    s->running = 1;
    return 0;
}

int ca_stop(ca_stream *s, char *err) {
    if (!s->running) return 0;
    OSStatus st = AudioOutputUnitStop(s->unit);
    s->running = 0;
    if (st != noErr) { seterr(err, "AudioOutputUnitStop", st); return -1; }
    return 0;
}

void ca_close(ca_stream *s) {
    if (!s) return;
    if (s->unit) {
        if (s->running) AudioOutputUnitStop(s->unit);
        AudioUnitUninitialize(s->unit);
        AudioComponentInstanceDispose(s->unit);
    }
    if (s->hogged) {
        pid_t none = -1;
        AudioObjectPropertyAddress ha = { kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectSetPropertyData(s->dev, &ha, 0, NULL, sizeof none, &none);
    }
    free(s);
}

int ca_buffer_frames(ca_stream *s) { return (int)s->buffer_frames; }

double ca_latency_ms(ca_stream *s) {
    UInt32 lat = 0, sz = sizeof lat;
    AudioObjectPropertyAddress a = { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioObjectGetPropertyData(s->dev, &a, 0, NULL, &sz, &lat);
    return 1000.0 * (lat + s->buffer_frames) / s->rate;
}

double ca_actual_rate(ca_stream *s) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    double r = 0; UInt32 sz = sizeof r;
    AudioObjectGetPropertyData(s->dev, &a, 0, NULL, &sz, &r);
    return r;
}

int ca_hogged(ca_stream *s) { return s->hogged; }
