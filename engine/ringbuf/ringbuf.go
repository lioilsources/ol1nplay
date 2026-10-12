// Package ringbuf is the Go producer side of the C ring buffer in
// native/rb.h. The consumer side lives inside each output backend's C
// callback and never touches Go.
package ringbuf

/*
#cgo CFLAGS: -I${SRCDIR}/../native -std=c11
#include "rb.h"
*/
import "C"

import (
	"errors"
	"unsafe"
)

// SampleType mirrors enum rb_sample_type.
type SampleType int

const (
	S16   SampleType = C.RB_S16
	S24_3 SampleType = C.RB_S24_3
	S32   SampleType = C.RB_S32
	F32   SampleType = C.RB_F32
	F64   SampleType = C.RB_F64
	DSD8  SampleType = C.RB_DSD8
)

// Bytes is the size of one sample of this type.
func (t SampleType) Bytes() int { return int(C.rb_sample_bytes(C.int(t))) }

// Bits is the container width in bits.
func (t SampleType) Bits() int { return t.Bytes() * 8 }

// IsFloat reports whether the type is floating point.
func (t SampleType) IsFloat() bool { return t == F32 || t == F64 }

func (t SampleType) String() string {
	switch t {
	case S16:
		return "s16"
	case S24_3:
		return "s24"
	case S32:
		return "s32"
	case F32:
		return "f32"
	case F64:
		return "f64"
	case DSD8:
		return "dsd"
	}
	return "?"
}

// Ring wraps *rb_t.
type Ring struct {
	p        *C.rb_t
	channels int
	typ      SampleType
}

// New allocates a ring of at least frames frames (rounded up to a power of two).
func New(frames, channels int, typ SampleType) (*Ring, error) {
	if frames <= 0 || channels <= 0 {
		return nil, errors.New("ringbuf: bad size")
	}
	p := C.rb_create(C.uint32_t(frames), C.uint32_t(channels), C.int(typ))
	if p == nil {
		return nil, errors.New("ringbuf: allocation failed")
	}
	return &Ring{p: p, channels: channels, typ: typ}, nil
}

// Ptr is handed to the backend's C side.
func (r *Ring) Ptr() unsafe.Pointer { return unsafe.Pointer(r.p) }

// Close frees the buffer. The consumer must be stopped first.
func (r *Ring) Close() {
	if r.p != nil {
		C.rb_destroy(r.p)
		r.p = nil
	}
}

func (r *Ring) Capacity() int       { return int(C.rb_capacity(r.p)) }
func (r *Ring) Channels() int       { return r.channels }
func (r *Ring) Type() SampleType    { return r.typ }
func (r *Ring) FrameBytes() int     { return int(C.rb_frame_bytes(r.p)) }
func (r *Ring) Fill() int           { return int(C.rb_fill(r.p)) }
func (r *Ring) WriteAvailable() int { return int(C.rb_write_available(r.p)) }

// FillPct is the buffer occupancy for the UI.
func (r *Ring) FillPct() float64 {
	return 100 * float64(r.Fill()) / float64(r.Capacity())
}

// Write copies whole frames from b; returns the number of frames written.
// Never blocks.
func (r *Ring) Write(b []byte) int {
	fb := r.FrameBytes()
	frames := len(b) / fb
	if frames == 0 {
		return 0
	}
	return int(C.rb_write(r.p, unsafe.Pointer(&b[0]), C.uint32_t(frames)))
}

// Reset drops buffered audio (seek / stop).
func (r *Ring) Reset() { C.rb_reset(r.p) }

// ResetStats zeroes the counters (new track or device).
func (r *Ring) ResetStats() { C.rb_reset_stats(r.p) }

// MonoMode is what the consumer does with the channels.
type MonoMode int

const (
	Stereo    MonoMode = iota // untouched
	Mono                      // (L+R)/2 into every channel
	MonoLeft                  // (L+R)/2 into the left channel, silence in the others
	MonoRight                 // (L+R)/2 into the right channel, silence in the others
	OnlyLeft                  // the left channel as it is, silence in the others
	OnlyRight                 // the right channel as it is, silence in the others
)

// SetMonoMode selects the consumer-side downmix.
func (r *Ring) SetMonoMode(m MonoMode) { C.rb_set_mono(r.p, C.int(m)) }

// MonoMode reports the current mode.
func (r *Ring) MonoMode() MonoMode { return MonoMode(C.rb_get_mono(r.p)) }

// SetMuted makes the consumer emit silence while keeping the device running (pause).
func (r *Ring) SetMuted(on bool) { C.rb_set_muted(r.p, cbool(on)) }

func cbool(b bool) C.int {
	if b {
		return 1
	}
	return 0
}

// Stats is a snapshot of the consumer counters.
type Stats struct {
	Underruns      int64
	UnderrunFrames int64
	FramesOut      int64
	Callbacks      int64
	MaxCallbackNs  int64
	LastUnderrunNs int64
}

func (r *Ring) Stats() Stats {
	return Stats{
		Underruns:      int64(C.rb_underruns(r.p)),
		UnderrunFrames: int64(C.rb_underrun_frames(r.p)),
		FramesOut:      int64(C.rb_frames_out(r.p)),
		Callbacks:      int64(C.rb_callbacks(r.p)),
		MaxCallbackNs:  int64(C.rb_max_cb_ns(r.p)),
		LastUnderrunNs: int64(C.rb_last_underrun_ns(r.p)),
	}
}

// FramesOut is how many real frames the device has consumed – the clock
// the UI position is derived from (device clock, not wall clock).
func (r *Ring) FramesOut() int64 { return int64(C.rb_frames_out(r.p)) }

// ReadInterleaved is exposed for tests and the null backend only; real
// backends call rb_read_* from their own C callback.
func (r *Ring) ReadInterleaved(dst []byte) int {
	fb := r.FrameBytes()
	frames := len(dst) / fb
	if frames == 0 {
		return 0
	}
	return int(C.rb_read_interleaved(r.p, unsafe.Pointer(&dst[0]), C.uint32_t(frames)))
}

// ReadPlanar is the consumer path ASIO uses (one buffer per channel),
// exposed for tests. Each dst must hold the same whole number of samples.
func (r *Ring) ReadPlanar(dsts [][]byte) int {
	if len(dsts) != r.channels || len(dsts[0]) == 0 {
		return 0
	}
	frames := len(dsts[0]) / r.typ.Bytes()
	ptrs := (*[64]unsafe.Pointer)(C.malloc(C.size_t(len(dsts)) * C.size_t(unsafe.Sizeof(unsafe.Pointer(nil)))))
	defer C.free(unsafe.Pointer(ptrs))
	tmp := make([]unsafe.Pointer, len(dsts))
	for c := range dsts {
		tmp[c] = C.CBytes(dsts[c])
		ptrs[c] = tmp[c]
	}
	n := int(C.rb_read_deinterleaved(r.p, (*unsafe.Pointer)(unsafe.Pointer(ptrs)), C.uint32_t(frames)))
	for c := range dsts {
		copy(dsts[c], unsafe.Slice((*byte)(tmp[c]), len(dsts[c])))
		C.free(tmp[c])
	}
	return n
}
