//go:build windows

package asio

/*
#cgo CFLAGS: -I${SRCDIR}/../native -std=c11 -D_WIN32_WINNT=0x0A00
#cgo LDFLAGS: -lole32 -loleaut32 -luuid -lavrt
#include <stdlib.h>
#include "asio_shim.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"math"
	"runtime"
	"sort"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows/registry"

	"github.com/ol1n/ol1nplay/engine/ringbuf"
	"github.com/ol1n/ol1nplay/engine/sink"
)

func init() {
	// Registered first so sink.Preferred() picks ASIO over WASAPI whenever a
	// driver is installed.
	sink.Register(newBackend())
}

// driverThread is the one OS thread every driver call is made from. ASIO
// drivers are apartment-threaded COM objects; calling them from whichever
// goroutine happens to run is undefined behaviour in practice (the Go
// scheduler migrates goroutines between threads).
type driverThread struct {
	cmds chan func()
}

func startDriverThread() *driverThread {
	t := &driverThread{cmds: make(chan func())}
	ready := make(chan struct{})
	go func() {
		runtime.LockOSThread()
		C.asio_com_init()
		close(ready)
		// Drivers that own windows (control panels, tray helpers) need the
		// apartment thread to dispatch their messages, so pump while idle.
		tick := time.NewTicker(20 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case f := <-t.cmds:
				f()
			case <-tick.C:
				C.asio_pump_messages()
			}
		}
	}()
	<-ready
	return t
}

// do runs f on the driver thread and waits for it. Never call from f itself.
func (t *driverThread) do(f func() error) error {
	done := make(chan error, 1)
	t.cmds <- func() { done <- f() }
	return <-done
}

func lastErr() string { return C.GoString(C.asio_last_error()) }

func shimErr(what string, rc C.int) error {
	if rc == 0 {
		return nil
	}
	return fmt.Errorf("asio: %s: %s", what, lastErr())
}

// Backend implements sink.Backend.
type Backend struct {
	th   *driverThread
	mu   sync.Mutex
	open *Stream

	pref BufferPreference
	core int
}

func newBackend() *Backend {
	return &Backend{th: startDriverThread(), pref: BufferPreferred, core: -1}
}

// New returns the registered backend (there is only one driver thread per
// process).
func New() (*Backend, error) {
	b, ok := sink.Get("asio")
	if !ok {
		return nil, ErrWindowsOnly
	}
	return b.(*Backend), nil
}

// Name implements sink.Backend.
func (b *Backend) Name() string { return "asio" }

// SetBufferPreference chooses min/preferred/max for the next Open.
func (b *Backend) SetBufferPreference(p BufferPreference) {
	b.mu.Lock()
	b.pref = p
	b.mu.Unlock()
}

// SetAffinityCore pins the callback thread for the next Open (-1 = last core).
func (b *Backend) SetAffinityCore(core int) {
	b.mu.Lock()
	b.core = core
	b.mu.Unlock()
}

// Devices implements sink.Backend by reading HKLM\SOFTWARE\ASIO. Only the
// 64-bit registry view matters: a 32-bit driver under WOW6432Node cannot be
// loaded into this process anyway.
func (b *Backend) Devices() ([]sink.Device, error) {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\ASIO`, registry.READ)
	if err != nil {
		if errors.Is(err, registry.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("asio: registry: %w", err)
	}
	defer k.Close()
	names, err := k.ReadSubKeyNames(-1)
	if err != nil {
		return nil, fmt.Errorf("asio: registry: %w", err)
	}
	sort.Strings(names)
	var out []sink.Device
	for _, n := range names {
		sub, err := registry.OpenKey(k, n, registry.READ)
		if err != nil {
			continue
		}
		clsid, _, err := sub.GetStringValue("CLSID")
		desc, _, _ := sub.GetStringValue("Description")
		sub.Close()
		if err != nil || clsid == "" {
			continue
		}
		if desc == "" {
			desc = n
		}
		out = append(out, sink.Device{ID: clsid, Name: desc})
	}
	if len(out) > 0 {
		out[0].Default = true
	}
	return out, nil
}

// withDriver opens the driver on the driver thread, runs f, and closes it.
func (b *Backend) withDriver(id string, f func(d *C.asio_dev) error) error {
	return b.th.do(func() error {
		var d *C.asio_dev
		cid := C.CString(id)
		defer C.free(unsafe.Pointer(cid))
		if rc := C.asio_open(cid, nil, &d); rc != 0 {
			return shimErr("open", rc)
		}
		defer C.asio_close(d)
		return f(d)
	})
}

// Caps implements sink.Backend by opening the driver briefly.
func (b *Backend) Caps(id string) (sink.Caps, error) {
	b.mu.Lock()
	if b.open != nil {
		b.mu.Unlock()
		return sink.Caps{}, errors.New("asio: cannot probe while a stream is open")
	}
	b.mu.Unlock()

	caps := sink.Caps{Exclusive: true}
	err := b.withDriver(id, func(d *C.asio_dev) error {
		for _, sr := range ProbeRates {
			if C.asio_can_sample_rate(d, C.double(sr)) == 0 {
				caps.SampleRates = append(caps.SampleRates, sr)
			}
		}
		var info C.ASIOChannelInfo
		if rc := C.asio_get_channel_info(d, 0, 0, &info); rc != 0 {
			return shimErr("getChannelInfo", rc)
		}
		dt, err := SampleType(info._type).ToRing()
		if err != nil {
			return err
		}
		caps.Types = []ringbuf.SampleType{dt.Type}
		caps.NativeDSD = C.asio_can_do_dsd(d) == 0
		return nil
	})
	return caps, err
}

// Open implements sink.Backend.
func (b *Backend) Open(id string, want sink.Format, ringFrames int) (sink.Stream, error) {
	b.mu.Lock()
	if b.open != nil {
		b.mu.Unlock()
		return nil, errors.New("asio: a stream is already open; close it first")
	}
	pref, core := b.pref, b.core
	b.mu.Unlock()

	if want.Channels <= 0 || want.Channels > C.ASIO_MAX_CHANNELS {
		return nil, fmt.Errorf("asio: bad channel count %d", want.Channels)
	}

	s := &Stream{b: b, want: want}
	err := b.th.do(func() error {
		cid := C.CString(id)
		defer C.free(unsafe.Pointer(cid))
		if rc := C.asio_open(cid, nil, &s.d); rc != 0 {
			return shimErr("open", rc)
		}
		ok := false
		defer func() {
			if !ok {
				C.asio_close(s.d)
				s.d = nil
			}
		}()

		var name [64]C.char
		C.asio_driver_name(s.d, &name[0], 64)
		s.driverName = C.GoString(&name[0])
		s.driverVersion = int(C.asio_driver_version(s.d))

		var nin, nout C.long
		if rc := C.asio_get_channels(s.d, &nin, &nout); rc != 0 {
			return shimErr("getChannels", rc)
		}
		if int(nout) < want.Channels {
			return fmt.Errorf("%w: driver has %d output channels, track needs %d", sink.ErrUnsupportedFormat, nout, want.Channels)
		}

		// DSD: switch the driver's I/O format before asking for channel
		// types; drivers report DSD sample types only in DSD mode.
		wantDSD := want.Type == ringbuf.DSD8
		if wantDSD {
			if rc := C.asio_can_do_dsd(s.d); rc != 0 {
				return fmt.Errorf("%w: %s", sink.ErrUnsupportedFormat, lastErr())
			}
			if rc := C.asio_set_io_format(s.d, 1); rc != 0 {
				return shimErr("set DSD format", rc)
			}
		} else {
			// Back to PCM in case the previous track left the driver in DSD.
			var dsd C.int
			if C.asio_get_io_format(s.d, &dsd) == 0 && dsd != 0 {
				if rc := C.asio_set_io_format(s.d, 0); rc != 0 {
					return shimErr("set PCM format", rc)
				}
			}
		}

		if rc := C.asio_can_sample_rate(s.d, C.double(want.SampleRate)); rc != 0 {
			return fmt.Errorf("%w: driver refuses %d Hz (%s)", sink.ErrUnsupportedFormat, want.SampleRate, lastErr())
		}
		var cur C.double
		C.asio_get_sample_rate(s.d, &cur)
		if math.Abs(float64(cur)-float64(want.SampleRate)) > 0.5 {
			if rc := C.asio_set_sample_rate(s.d, C.double(want.SampleRate)); rc != 0 {
				return shimErr("setSampleRate", rc)
			}
			// Some drivers accept setSampleRate but switch asynchronously;
			// verify, because playing 96 kHz material at 48 kHz is exactly
			// the failure this program exists to avoid.
			C.asio_get_sample_rate(s.d, &cur)
			if math.Abs(float64(cur)-float64(want.SampleRate)) > 0.5 {
				return fmt.Errorf("asio: driver reports %.0f Hz after setSampleRate(%d)", float64(cur), want.SampleRate)
			}
		}

		var dt DeviceType
		for c := 0; c < want.Channels; c++ {
			var info C.ASIOChannelInfo
			if rc := C.asio_get_channel_info(s.d, C.long(c), 0, &info); rc != 0 {
				return shimErr("getChannelInfo", rc)
			}
			t, err := SampleType(info._type).ToRing()
			if err != nil {
				return err
			}
			if c == 0 {
				dt = t
				s.asioType = SampleType(info._type)
			} else if t != dt {
				return fmt.Errorf("asio: channel %d runs %s but channel 0 runs %s; mixed channel types are not supported", c, SampleType(info._type), s.asioType)
			}
		}

		got, err := Negotiate(want, dt)
		if err != nil {
			return err
		}
		s.format = got

		var mn, mx, pf, gr C.long
		if rc := C.asio_get_buffer_size(s.d, &mn, &mx, &pf, &gr); rc != 0 {
			return shimErr("getBufferSize", rc)
		}
		s.bufferFrames = PickBufferSize(pref, int(mn), int(mx), int(pf), int(gr))

		if ringFrames < 4*s.bufferFrames {
			ringFrames = 4 * s.bufferFrames
		}
		ring, err := ringbuf.New(ringFrames, want.Channels, got.Type)
		if err != nil {
			return err
		}
		if rc := C.asio_create_buffers(s.d, (*C.rb_t)(ring.Ptr()), C.long(want.Channels), C.long(s.bufferFrames), C.int(core)); rc != 0 {
			ring.Close()
			return shimErr("createBuffers", rc)
		}
		s.ring = ring

		var lin, lout C.long
		if C.asio_get_latencies(s.d, &lin, &lout) == 0 {
			s.latencyFrames = int(lout)
		}
		ok = true
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

// Stream is one open ASIO driver with buffers created.
type Stream struct {
	b    *Backend
	d    *C.asio_dev
	want sink.Format

	driverName    string
	driverVersion int
	asioType      SampleType
	format        sink.Format
	ring          *ringbuf.Ring
	bufferFrames  int
	latencyFrames int

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
func (s *Stream) LatencyMs() float64 {
	if s.format.SampleRate == 0 {
		return 0
	}
	return 1000 * float64(s.latencyFrames) / float64(s.format.SampleRate)
}

// Start implements sink.Stream.
func (s *Stream) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errors.New("asio: stream closed")
	}
	if s.running {
		return nil
	}
	s.ring.ResetStats()
	if err := s.b.th.do(func() error { return shimErr("start", C.asio_start(s.d)) }); err != nil {
		return err
	}
	s.running = true
	return nil
}

// Stop implements sink.Stream. Synchronous: ASIOStop returns only after the
// driver's thread has left the callback.
func (s *Stream) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.running || s.closed {
		return nil
	}
	s.running = false
	return s.b.th.do(func() error { return shimErr("stop", C.asio_stop(s.d)) })
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
		C.asio_close(s.d) // stops + disposes
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
	C.asio_thread_info(s.d, &prio[0], 64, &core)
	return sink.ThreadInfo{Priority: C.GoString(&prio[0]), Core: int(core)}
}

// Flags are the driver's asynchronous requests, read-and-clear.
type Flags struct {
	Reset             bool // driver asks for stop/dispose/create/start → Close + Open
	Resync            bool
	BufferSizeChanged bool
	LatenciesChanged  bool
	Overloads         int
	SampleRateChanged bool
	ReportedRate      float64
}

// TakeFlags returns and clears the pending driver requests.
func (s *Stream) TakeFlags() Flags {
	if s.d == nil {
		return Flags{}
	}
	f := Flags{
		Reset:             C.asio_take_flag(s.d, C.ASIO_FLAG_RESET) != 0,
		Resync:            C.asio_take_flag(s.d, C.ASIO_FLAG_RESYNC) != 0,
		BufferSizeChanged: C.asio_take_flag(s.d, C.ASIO_FLAG_BUFFER_SIZE) != 0,
		LatenciesChanged:  C.asio_take_flag(s.d, C.ASIO_FLAG_LATENCIES) != 0,
		Overloads:         int(C.asio_take_flag(s.d, C.ASIO_FLAG_OVERLOAD)),
		SampleRateChanged: C.asio_take_flag(s.d, C.ASIO_FLAG_SRATE_CHANGED) != 0,
	}
	if f.SampleRateChanged {
		f.ReportedRate = float64(C.asio_reported_sample_rate(s.d))
	}
	return f
}

// ResetRequested reports (and clears) a driver reset request. The engine
// answers by Close() + Open().
func (s *Stream) ResetRequested() bool {
	f := s.TakeFlags()
	return f.Reset || f.BufferSizeChanged
}

// ControlPanel opens the driver's settings dialog.
func (s *Stream) ControlPanel() error {
	return s.b.th.do(func() error { return shimErr("controlPanel", C.asio_control_panel(s.d)) })
}

// DriverName is what the driver calls itself.
func (s *Stream) DriverName() string { return s.driverName }

// DriverVersion is the driver's own version number.
func (s *Stream) DriverVersion() int { return s.driverVersion }

// ASIOType is the driver channel sample type (for the tech-info panel).
func (s *Stream) ASIOType() SampleType { return s.asioType }

// OutputReady reports whether the driver supports ASIOOutputReady.
func (s *Stream) OutputReady() bool { return C.asio_output_ready_supported(s.d) != 0 }

// ControlPanel opens the control panel of a driver that is not open.
func (b *Backend) ControlPanel(id string) error {
	return b.withDriver(id, func(d *C.asio_dev) error {
		return shimErr("controlPanel", C.asio_control_panel(d))
	})
}
