// Package sink defines the output backend contract. A backend owns a device
// and a real-time callback written in C; the only thing it shares with the
// rest of the engine is the ring buffer (ringbuf.Ring) and a few atomics.
//
// Backends: asio (Windows, primary), wasapi (Windows exclusive-mode
// fallback), coreaudio (macOS, development), null (tests, any OS).
package sink

import (
	"errors"
	"sort"
	"sync"

	"github.com/ol1n/ol1nplay/engine/ringbuf"
)

// Format is a device-side PCM format. The engine asks for the track's native
// format; the backend answers with what the device actually accepts. The
// only tolerated difference is a wider integer container with zero LSBs
// (24 → 32), which keeps the stream bit-perfect.
type Format struct {
	SampleRate int
	Channels   int
	Type       ringbuf.SampleType
	// DSD: when Type == DSD8, SampleRate is the DSD bit rate / 8 per channel
	// byte rate is implied; DoP means DSD packed into S32 frames at
	// SampleRate = dsdRate/16 (handled by the engine, not the backend).
	DSDNative bool
	// ValidBits > 0 means the device wants only this many significant bits
	// right-aligned (LSB-justified) inside a wider Type – ASIO's
	// ASIOSTInt32LSB24 is "24 valid bits in the low 24 of an int32". 0 means
	// MSB-justified / full width, which is the normal case. The feeder
	// handles the alignment; the backend only reports it.
	ValidBits int
}

// Equal compares what matters for bit-perfect output.
func (f Format) Equal(o Format) bool {
	return f.SampleRate == o.SampleRate && f.Channels == o.Channels && f.Type == o.Type && f.DSDNative == o.DSDNative
}

// Device is one selectable output.
type Device struct {
	ID          string
	Name        string
	Default     bool
	SampleRates []int // probed, may be empty
	MaxChannels int
	Note        string
}

// Caps describes what a backend can do, for the UI.
type Caps struct {
	Exclusive   bool // owns the device (bit-perfect possible)
	NativeDSD   bool
	SampleRates []int
	Types       []ringbuf.SampleType
}

// Stream is an opened device running one Format.
type Stream interface {
	// Format is what the device is actually running.
	Format() Format
	// Ring is the producer handle. Its sample type equals Format().Type.
	Ring() *ringbuf.Ring
	// BufferFrames is the device period (ASIO buffer size); Latency is the
	// backend's own estimate of output latency.
	BufferFrames() int
	LatencyMs() float64
	// Start/Stop control the device clock. Stop must be synchronous: when it
	// returns, the callback is guaranteed not to run again.
	Start() error
	Stop() error
	// Close releases the device. Stop first.
	Close() error
	// Running reports whether Start succeeded and Stop was not called.
	Running() bool
	// ThreadInfo tells the UI how the callback thread is scheduled.
	ThreadInfo() ThreadInfo
}

// ThreadInfo describes the real-time thread.
type ThreadInfo struct {
	Priority string // "Pro Audio/critical", "time-constraint", "normal", "driver-owned"
	Core     int    // -1 = not pinned
}

// Backend enumerates devices and opens streams.
type Backend interface {
	Name() string // "asio" | "wasapi" | "coreaudio" | "null"
	Devices() ([]Device, error)
	// Caps probes a device without opening it for playback. Backends that
	// cannot probe return a best guess and set Note.
	Caps(deviceID string) (Caps, error)
	// Open prepares the device for want. If the device cannot run the exact
	// Type but can run a wider integer container, the backend returns the
	// wider Format and the engine zero-pads. Anything else is an error:
	// the engine never resamples or dithers.
	Open(deviceID string, want Format, ringFrames int) (Stream, error)
}

// ErrUnsupportedFormat means the device cannot run the format without
// conversion. The engine reports it instead of degrading silently.
var ErrUnsupportedFormat = errors.New("sink: device does not support this format")

// ErrNoDevice means the ID did not resolve.
var ErrNoDevice = errors.New("sink: no such device")

var (
	mu       sync.Mutex
	backends = map[string]Backend{}
	order    []string
)

// Register is called from backend init(); order of registration is the
// preference order (asio before wasapi).
func Register(b Backend) {
	mu.Lock()
	defer mu.Unlock()
	if _, dup := backends[b.Name()]; dup {
		return
	}
	backends[b.Name()] = b
	order = append(order, b.Name())
}

// Get returns a backend by name.
func Get(name string) (Backend, bool) {
	mu.Lock()
	defer mu.Unlock()
	b, ok := backends[name]
	return b, ok
}

// Names lists registered backends in preference order.
func Names() []string {
	mu.Lock()
	defer mu.Unlock()
	return append([]string(nil), order...)
}

// Preferred returns the first registered backend that has at least one
// device (so a Windows box without an ASIO driver falls back to WASAPI).
func Preferred() (Backend, error) {
	for _, n := range Names() {
		b, _ := Get(n)
		if n == "null" {
			continue
		}
		if devs, err := b.Devices(); err == nil && len(devs) > 0 {
			return b, nil
		}
	}
	if b, ok := Get("null"); ok {
		return b, nil
	}
	return nil, errors.New("sink: no backend available")
}

// WidenTo returns the integer container the engine may zero-pad a type into.
// S16 → S32 and S24 → S32 are bit-perfect; floats are never widened.
func WidenTo(have ringbuf.SampleType, offered []ringbuf.SampleType) (ringbuf.SampleType, bool) {
	for _, t := range offered {
		if t == have {
			return t, true
		}
	}
	if have.IsFloat() || have == ringbuf.DSD8 {
		return 0, false
	}
	// Prefer the narrowest container that still holds every bit.
	cands := append([]ringbuf.SampleType(nil), offered...)
	sort.Slice(cands, func(i, j int) bool { return cands[i].Bytes() < cands[j].Bytes() })
	for _, t := range cands {
		if t.IsFloat() || t == ringbuf.DSD8 {
			continue
		}
		if t.Bytes() > have.Bytes() {
			return t, true
		}
	}
	return 0, false
}
