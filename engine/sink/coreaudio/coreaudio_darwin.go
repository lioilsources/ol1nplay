//go:build darwin

// Package coreaudio is the macOS development backend: exclusive (hog mode)
// AUHAL output at the track's native rate and integer width. It is not the
// product – Windows/ASIO is – but it lets the whole pipeline be exercised
// end to end on a Mac.
package coreaudio

/*
#cgo CFLAGS: -I${SRCDIR}/../../native -std=c11
#cgo LDFLAGS: -framework CoreAudio -framework AudioUnit -framework AudioToolbox -framework CoreFoundation
#include <stdlib.h>
#include "ca_shim.h"
*/
import "C"

import (
	"fmt"
	"sync"
	"unsafe"

	"github.com/ol1n/ol1nplay/engine/ringbuf"
	"github.com/ol1n/ol1nplay/engine/sink"
)

// Backend implements sink.Backend.
type Backend struct {
	// Hog requests exclusive access (other apps lose the device while we
	// play). Default on – that is what "exclusive" means.
	Hog bool
}

func (b *Backend) Name() string { return "coreaudio" }

func (b *Backend) Devices() ([]sink.Device, error) {
	var devs [64]C.ca_device
	var cerr [C.CA_ERR_LEN]C.char
	n := C.ca_list_devices(&devs[0], 64, &cerr[0])
	if n < 0 {
		return nil, fmt.Errorf("coreaudio: %s", C.GoString(&cerr[0]))
	}
	out := make([]sink.Device, 0, int(n))
	for i := 0; i < int(n); i++ {
		d := devs[i]
		rates := make([]int, 0, int(d.n_rates))
		for k := 0; k < int(d.n_rates); k++ {
			rates = append(rates, int(d.rates[k]))
		}
		out = append(out, sink.Device{
			ID:          C.GoString(&d.uid[0]),
			Name:        C.GoString(&d.name[0]),
			Default:     d.is_default != 0,
			MaxChannels: int(d.max_channels),
			SampleRates: rates,
		})
	}
	return out, nil
}

func (b *Backend) Caps(id string) (sink.Caps, error) {
	devs, err := b.Devices()
	if err != nil {
		return sink.Caps{}, err
	}
	for _, d := range devs {
		if d.ID == id || (id == "" && d.Default) {
			return sink.Caps{Exclusive: b.Hog, SampleRates: d.SampleRates,
				Types: []ringbuf.SampleType{ringbuf.S16, ringbuf.S24_3, ringbuf.S32, ringbuf.F32}}, nil
		}
	}
	return sink.Caps{}, sink.ErrNoDevice
}

func (b *Backend) Open(id string, want sink.Format, ringFrames int) (sink.Stream, error) {
	if want.Type == ringbuf.DSD8 {
		return nil, fmt.Errorf("%w: CoreAudio has no native DSD; use DoP", sink.ErrUnsupportedFormat)
	}
	if want.Type == ringbuf.F64 {
		return nil, fmt.Errorf("%w: float64", sink.ErrUnsupportedFormat)
	}
	r, err := ringbuf.New(ringFrames, want.Channels, want.Type)
	if err != nil {
		return nil, err
	}
	cuid := C.CString(id)
	defer C.free(unsafe.Pointer(cuid))
	var cerr [C.CA_ERR_LEN]C.char
	hog := C.int(0)
	if b.Hog {
		hog = 1
	}
	s := C.ca_open(cuid, C.double(want.SampleRate), C.int(want.Channels), C.int(want.Type), hog, r.Ptr(), &cerr[0])
	if s == nil {
		r.Close()
		msg := C.GoString(&cerr[0])
		if msg == "device does not accept this sample rate" || msg == "device rejected the stream format" {
			return nil, fmt.Errorf("%w: %s", sink.ErrUnsupportedFormat, msg)
		}
		return nil, fmt.Errorf("coreaudio: %s", msg)
	}
	st := &stream{s: s, ring: r, format: want}
	st.format.SampleRate = int(C.ca_actual_rate(s))
	return st, nil
}

type stream struct {
	s      *C.ca_stream
	ring   *ringbuf.Ring
	format sink.Format
	mu     sync.Mutex
	run    bool
}

func (s *stream) Format() sink.Format { return s.format }
func (s *stream) Ring() *ringbuf.Ring { return s.ring }
func (s *stream) BufferFrames() int   { return int(C.ca_buffer_frames(s.s)) }
func (s *stream) LatencyMs() float64  { return float64(C.ca_latency_ms(s.s)) }
func (s *stream) ThreadInfo() sink.ThreadInfo {
	return sink.ThreadInfo{Priority: "time-constraint (CoreAudio IO thread)", Core: -1}
}

func (s *stream) Running() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.s != nil && s.run
}

// Hogged reports whether exclusive access was granted.
func (s *stream) Hogged() bool { return s.s != nil && C.ca_hogged(s.s) != 0 }

func (s *stream) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var cerr [C.CA_ERR_LEN]C.char
	if C.ca_start(s.s, &cerr[0]) != 0 {
		return fmt.Errorf("coreaudio: %s", C.GoString(&cerr[0]))
	}
	s.run = true
	return nil
}

func (s *stream) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var cerr [C.CA_ERR_LEN]C.char
	if C.ca_stop(s.s, &cerr[0]) != 0 {
		return fmt.Errorf("coreaudio: %s", C.GoString(&cerr[0]))
	}
	s.run = false
	return nil
}

func (s *stream) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.s != nil {
		C.ca_close(s.s)
		s.s = nil
	}
	s.ring.Close()
	return nil
}

func init() { sink.Register(&Backend{Hog: true}) }
