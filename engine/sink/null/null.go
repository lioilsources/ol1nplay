// Package null is an output backend with no hardware: a goroutine consumes
// the ring buffer at the nominal sample rate (or as fast as possible) and
// optionally captures everything it reads. It exists for tests, for
// headless verification ("is what reaches the device byte-identical to the
// file?") and as a last resort when no real backend has a device.
package null

import (
	"errors"
	"io"
	"sync"
	"time"

	"github.com/ol1n/ol1nplay/engine/ringbuf"
	"github.com/ol1n/ol1nplay/engine/sink"
)

// Backend implements sink.Backend.
type Backend struct {
	mu      sync.Mutex
	capture io.Writer
	fast    bool
}

// New registers nothing; the caller decides (tests construct it directly).
func New() *Backend { return &Backend{} }

// SetCapture makes every opened stream copy consumed frames into w.
func (b *Backend) SetCapture(w io.Writer) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.capture = w
}

// SetFast disables the real-time clock (tests).
func (b *Backend) SetFast(on bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.fast = on
}

func (b *Backend) Name() string { return "null" }

func (b *Backend) Devices() ([]sink.Device, error) {
	return []sink.Device{{ID: "null", Name: "No output (silent)", Default: true, MaxChannels: 8,
		SampleRates: []int{44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000},
		Note:        "Consumes audio at the right speed, outputs nothing"}}, nil
}

func (b *Backend) Caps(id string) (sink.Caps, error) {
	if id != "null" && id != "" {
		return sink.Caps{}, sink.ErrNoDevice
	}
	return sink.Caps{Exclusive: true, NativeDSD: true,
		SampleRates: []int{44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000},
		Types:       []ringbuf.SampleType{ringbuf.S16, ringbuf.S24_3, ringbuf.S32, ringbuf.F32, ringbuf.F64, ringbuf.DSD8}}, nil
}

func (b *Backend) Open(id string, want sink.Format, ringFrames int) (sink.Stream, error) {
	if id != "null" && id != "" {
		return nil, sink.ErrNoDevice
	}
	if want.SampleRate <= 0 || want.Channels <= 0 {
		return nil, errors.New("null: bad format")
	}
	r, err := ringbuf.New(ringFrames, want.Channels, want.Type)
	if err != nil {
		return nil, err
	}
	b.mu.Lock()
	s := &stream{format: want, ring: r, capture: b.capture, fast: b.fast, period: 512}
	b.mu.Unlock()
	return s, nil
}

type stream struct {
	format  sink.Format
	ring    *ringbuf.Ring
	capture io.Writer
	fast    bool
	period  int

	mu      sync.Mutex
	running bool
	stop    chan struct{}
	done    chan struct{}
}

func (s *stream) Format() sink.Format { return s.format }
func (s *stream) Ring() *ringbuf.Ring { return s.ring }
func (s *stream) BufferFrames() int   { return s.period }
func (s *stream) LatencyMs() float64  { return 1000 * float64(s.period) / float64(s.format.SampleRate) }
func (s *stream) ThreadInfo() sink.ThreadInfo {
	return sink.ThreadInfo{Priority: "normal (null backend)", Core: -1}
}

func (s *stream) Running() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.running
}

func (s *stream) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.running {
		return nil
	}
	s.running = true
	s.stop = make(chan struct{})
	s.done = make(chan struct{})
	go s.loop(s.stop, s.done)
	return nil
}

func (s *stream) loop(stop, done chan struct{}) {
	defer close(done)
	buf := make([]byte, s.period*s.ring.FrameBytes())
	// Period clock: the "device" consumes period frames every period/rate.
	interval := time.Duration(float64(s.period) / float64(s.format.SampleRate) * float64(time.Second))
	var tick *time.Ticker
	if !s.fast {
		tick = time.NewTicker(interval)
		defer tick.Stop()
	}
	for {
		select {
		case <-stop:
			return
		default:
		}
		if tick != nil {
			select {
			case <-stop:
				return
			case <-tick.C:
			}
		}
		rd := buf
		if tick == nil {
			// Fast mode: consume whatever is there (whole frames only), never
			// spin on an empty ring, and never read short so the test backend
			// does not invent underruns.
			fill := s.ring.Fill()
			if fill == 0 {
				time.Sleep(200 * time.Microsecond)
				continue
			}
			if fill < s.period {
				rd = buf[:fill*s.ring.FrameBytes()]
			}
		}
		n := s.ring.ReadInterleaved(rd)
		if s.capture != nil && n > 0 {
			_, _ = s.capture.Write(buf[:n*s.ring.FrameBytes()])
		}
	}
}

func (s *stream) Stop() error {
	s.mu.Lock()
	if !s.running {
		s.mu.Unlock()
		return nil
	}
	s.running = false
	close(s.stop)
	done := s.done
	s.mu.Unlock()
	<-done
	return nil
}

func (s *stream) Close() error {
	_ = s.Stop()
	s.ring.Close()
	return nil
}

func init() { sink.Register(New()) }
