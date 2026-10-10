//go:build windows

package wasapi

/*
#cgo CFLAGS: -I${SRCDIR}/../native -std=c11 -D_WIN32_WINNT=0x0A00
#cgo LDFLAGS: -lole32 -lavrt -lksuser
#include <stdlib.h>
#include "wasapi_shim.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"unsafe"

	"github.com/ol1n/ol1nplay/engine/ringbuf"
	"github.com/ol1n/ol1nplay/engine/sink"
)

func init() {
	// Registered after asio (package init order follows import order in
	// cmd/engine; asio is imported first there).
	sink.Register(newBackend())
}

// comThread serialises every Core Audio call onto one MTA-initialised OS
// thread. The interfaces are free-threaded, but the Go scheduler would
// otherwise call CoInitialize-less threads and some Windows builds log
// RPC_E_* noise for that.
type comThread struct{ cmds chan func() }

func startComThread() *comThread {
	t := &comThread{cmds: make(chan func())}
	ready := make(chan struct{})
	go func() {
		runtime.LockOSThread()
		C.wasapi_com_init()
		close(ready)
		for f := range t.cmds {
			f()
		}
	}()
	<-ready
	return t
}

func (t *comThread) do(f func() error) error {
	done := make(chan error, 1)
	t.cmds <- func() { done <- f() }
	return <-done
}

func lastErr() string { return C.GoString(C.wasapi_last_error()) }

func shimErr(what string, rc C.int) error {
	switch rc {
	case 0:
		return nil
	case C.WASAPI_EFORMAT:
		return fmt.Errorf("%w: %s", sink.ErrUnsupportedFormat, lastErr())
	case C.WASAPI_ENODEVICE:
		return fmt.Errorf("%w: %s", sink.ErrNoDevice, lastErr())
	}
	return fmt.Errorf("wasapi: %s: %s", what, lastErr())
}

// Backend implements sink.Backend.
type Backend struct {
	th   *comThread
	mu   sync.Mutex
	open *Stream
	core int
}

func newBackend() *Backend { return &Backend{th: startComThread(), core: -1} }

// New returns the registered backend.
func New() (*Backend, error) {
	b, ok := sink.Get("wasapi")
	if !ok {
		return nil, ErrWindowsOnly
	}
	return b.(*Backend), nil
}

// Name implements sink.Backend.
func (b *Backend) Name() string { return "wasapi" }

// SetAffinityCore pins the render thread for the next Open (-1 = last core).
func (b *Backend) SetAffinityCore(core int) {
	b.mu.Lock()
	b.core = core
	b.mu.Unlock()
}

// Devices implements sink.Backend.
func (b *Backend) Devices() ([]sink.Device, error) {
	const max = 64
	var infos [max]C.wasapi_device_info
	var count C.int
	err := b.th.do(func() error { return shimErr("enumerate", C.wasapi_enumerate(&infos[0], max, &count)) })
	if err != nil {
		return nil, err
	}
	out := make([]sink.Device, 0, int(count))
	for i := 0; i < int(count); i++ {
		out = append(out, sink.Device{
			ID:      C.GoString(&infos[i].id[0]),
			Name:    C.GoString(&infos[i].name[0]),
			Default: infos[i].is_default != 0,
		})
	}
	return out, nil
}

func (b *Backend) supported(id string, w WFX) bool {
	cid := C.CString(id)
	defer C.free(unsafe.Pointer(cid))
	return C.wasapi_format_supported(cid, C.int(w.SampleRate), C.int(w.Channels), C.int(w.ContainerBits),
		C.int(w.ValidBits), cbool(w.Float), C.uint32_t(w.ChannelMask)) == 0
}

func cbool(b bool) C.int {
	if b {
		return 1
	}
	return 0
}

// Caps implements sink.Backend by probing IsFormatSupported for the usual
// rates and containers at 2 channels.
func (b *Backend) Caps(id string) (sink.Caps, error) {
	caps := sink.Caps{Exclusive: true}
	err := b.th.do(func() error {
		types := map[ringbuf.SampleType]bool{}
		for _, sr := range ProbeRates {
			hit := false
			for _, t := range []ringbuf.SampleType{ringbuf.S16, ringbuf.S24_3, ringbuf.S32, ringbuf.F32} {
				cands, _ := Candidates(sink.Format{SampleRate: sr, Channels: 2, Type: t})
				if len(cands) == 0 {
					continue
				}
				if b.supported(id, cands[0]) {
					hit = true
					types[t] = true
				}
			}
			if hit {
				caps.SampleRates = append(caps.SampleRates, sr)
			}
		}
		for _, t := range []ringbuf.SampleType{ringbuf.S16, ringbuf.S24_3, ringbuf.S32, ringbuf.F32} {
			if types[t] {
				caps.Types = append(caps.Types, t)
			}
		}
		return nil
	})
	return caps, err
}

// Open implements sink.Backend.
func (b *Backend) Open(id string, want sink.Format, ringFrames int) (sink.Stream, error) {
	b.mu.Lock()
	if b.open != nil {
		b.mu.Unlock()
		return nil, errors.New("wasapi: a stream is already open; close it first")
	}
	core := b.core
	b.mu.Unlock()

	cands, err := Candidates(want)
	if err != nil {
		return nil, err
	}

	s := &Stream{b: b}
	err = b.th.do(func() error {
		var chosen *WFX
		for i := range cands {
			if b.supported(id, cands[i]) {
				chosen = &cands[i]
				break
			}
		}
		if chosen == nil {
			return fmt.Errorf("%w: endpoint accepts none of the bit-perfect containers for %s @ %d Hz (last: %s)",
				sink.ErrUnsupportedFormat, want.Type, want.SampleRate, lastErr())
		}
		s.format = chosen.Format()

		if ringFrames < 8192 {
			ringFrames = 8192
		}
		ring, err := ringbuf.New(ringFrames, want.Channels, chosen.Type)
		if err != nil {
			return err
		}
		cid := C.CString(id)
		defer C.free(unsafe.Pointer(cid))
		rc := C.wasapi_open(cid, C.int(chosen.SampleRate), C.int(chosen.Channels), C.int(chosen.ContainerBits),
			C.int(chosen.ValidBits), cbool(chosen.Float), C.uint32_t(chosen.ChannelMask),
			(*C.rb_t)(ring.Ptr()), C.int(core), &s.d)
		if rc != 0 {
			ring.Close()
			return shimErr("open", rc)
		}
		s.ring = ring
		s.bufferFrames = int(C.wasapi_buffer_frames(s.d))
		s.latencyMs = float64(C.wasapi_latency_ms(s.d))
		if s.ring.Capacity() < 4*s.bufferFrames {
			// The period turned out larger than expected; grow the ring so
			// the feeder has headroom.
			C.wasapi_close(s.d)
			s.d = nil
			ring.Close()
			ring, err = ringbuf.New(8*s.bufferFrames, want.Channels, chosen.Type)
			if err != nil {
				return err
			}
			rc = C.wasapi_open(cid, C.int(chosen.SampleRate), C.int(chosen.Channels), C.int(chosen.ContainerBits),
				C.int(chosen.ValidBits), cbool(chosen.Float), C.uint32_t(chosen.ChannelMask),
				(*C.rb_t)(ring.Ptr()), C.int(core), &s.d)
			if rc != 0 {
				ring.Close()
				return shimErr("open", rc)
			}
			s.ring = ring
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	b.mu.Lock()
	b.open = s
	b.mu.Unlock()
	return s, nil
}

// Stream is one exclusive-mode endpoint.
type Stream struct {
	b            *Backend
	d            *C.wasapi_dev
	format       sink.Format
	ring         *ringbuf.Ring
	bufferFrames int
	latencyMs    float64

	mu      sync.Mutex
	running bool
	closed  bool
}

// Format implements sink.Stream.
func (s *Stream) Format() sink.Format { return s.format }

// Ring implements sink.Stream.
func (s *Stream) Ring() *ringbuf.Ring { return s.ring }

// BufferFrames implements sink.Stream.
func (s *Stream) BufferFrames() int { return s.bufferFrames }

// LatencyMs implements sink.Stream.
func (s *Stream) LatencyMs() float64 { return s.latencyMs }

// Start implements sink.Stream.
func (s *Stream) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errors.New("wasapi: stream closed")
	}
	if s.running {
		return nil
	}
	s.ring.ResetStats()
	if err := s.b.th.do(func() error { return shimErr("start", C.wasapi_start(s.d)) }); err != nil {
		return err
	}
	s.running = true
	return nil
}

// Stop implements sink.Stream; joins the render thread before returning.
func (s *Stream) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.running || s.closed {
		return nil
	}
	s.running = false
	return s.b.th.do(func() error { return shimErr("stop", C.wasapi_stop(s.d)) })
}

// Close implements sink.Stream.
func (s *Stream) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	s.closed = true
	s.running = false
	err := s.b.th.do(func() error {
		C.wasapi_close(s.d)
		s.d = nil
		return nil
	})
	s.ring.Close()
	s.b.mu.Lock()
	if s.b.open == s {
		s.b.open = nil
	}
	s.b.mu.Unlock()
	return err
}

// Running implements sink.Stream.
func (s *Stream) Running() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.running && !s.closed
}

// ThreadInfo implements sink.Stream.
func (s *Stream) ThreadInfo() sink.ThreadInfo {
	var prio [64]C.char
	var core C.int
	C.wasapi_thread_info(s.d, &prio[0], 64, &core)
	return sink.ThreadInfo{Priority: C.GoString(&prio[0]), Core: int(core)}
}

// DeviceInvalidated reports that Windows pulled the endpoint (unplugged,
// format changed in Sound settings). The engine should Close and re-Open.
func (s *Stream) DeviceInvalidated() bool { return s.d != nil && C.wasapi_device_invalidated(s.d) != 0 }

// EventTimeouts counts periods where the engine failed to signal within 2 s.
func (s *Stream) EventTimeouts() int64 {
	if s.d == nil {
		return 0
	}
	return int64(C.wasapi_event_timeouts(s.d))
}
