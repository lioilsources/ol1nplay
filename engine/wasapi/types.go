// Package wasapi is the Windows fallback output backend: WASAPI exclusive
// mode, event driven, with a C render thread. It is used when no ASIO
// driver is installed. Platform-independent pieces (format candidates,
// WAVEFORMATEXTENSIBLE parameters) live in this file so they can be unit
// tested anywhere.
package wasapi

import (
	"errors"
	"fmt"

	"github.com/ol1n/ol1nplay/engine/ringbuf"
	"github.com/ol1n/ol1nplay/engine/sink"
)

// ErrWindowsOnly is returned by the constructor on other platforms.
var ErrWindowsOnly = errors.New("wasapi: WASAPI is available on Windows only")

// WFX are the numbers that go into a WAVEFORMATEXTENSIBLE.
type WFX struct {
	SampleRate    int
	Channels      int
	ContainerBits int    // wBitsPerSample
	ValidBits     int    // Samples.wValidBitsPerSample
	Float         bool   // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT vs PCM
	ChannelMask   uint32 // dwChannelMask
	Type          ringbuf.SampleType
}

// BlockAlign is nBlockAlign.
func (w WFX) BlockAlign() int { return w.Channels * w.ContainerBits / 8 }

// AvgBytesPerSec is nAvgBytesPerSec.
func (w WFX) AvgBytesPerSec() int { return w.SampleRate * w.BlockAlign() }

// Format is the sink.Format a stream with this WFX runs.
func (w WFX) Format() sink.Format {
	f := sink.Format{SampleRate: w.SampleRate, Channels: w.Channels, Type: w.Type}
	if !w.Float && w.ValidBits != w.ContainerBits {
		f.ValidBits = w.ValidBits
	}
	return f
}

// Speaker position bits from ksmedia.h.
const (
	speakerFrontLeft          = 0x1
	speakerFrontRight         = 0x2
	speakerFrontCenter        = 0x4
	speakerLowFrequency       = 0x8
	speakerBackLeft           = 0x10
	speakerBackRight          = 0x20
	speakerFrontLeftOfCenter  = 0x40
	speakerFrontRightOfCenter = 0x80
	speakerBackCenter         = 0x100
	speakerSideLeft           = 0x200
	speakerSideRight          = 0x400
)

// ChannelMask returns the standard dwChannelMask for a channel count. Zero
// means "unspecified", which exclusive mode accepts for odd layouts.
func ChannelMask(channels int) uint32 {
	switch channels {
	case 1:
		return speakerFrontCenter
	case 2:
		return speakerFrontLeft | speakerFrontRight
	case 3:
		return speakerFrontLeft | speakerFrontRight | speakerLowFrequency
	case 4:
		return speakerFrontLeft | speakerFrontRight | speakerBackLeft | speakerBackRight
	case 5:
		return speakerFrontLeft | speakerFrontRight | speakerFrontCenter | speakerBackLeft | speakerBackRight
	case 6:
		return speakerFrontLeft | speakerFrontRight | speakerFrontCenter | speakerLowFrequency | speakerBackLeft | speakerBackRight
	case 7:
		return speakerFrontLeft | speakerFrontRight | speakerFrontCenter | speakerLowFrequency | speakerBackCenter | speakerSideLeft | speakerSideRight
	case 8:
		return speakerFrontLeft | speakerFrontRight | speakerFrontCenter | speakerLowFrequency | speakerBackLeft | speakerBackRight | speakerSideLeft | speakerSideRight
	}
	return 0
}

// Candidates lists the WAVEFORMATEXTENSIBLE variants to try for a track
// format, best first. Only bit-perfect options appear: the exact container,
// then wider integer containers (zero LSBs, or the "24 valid bits in 32"
// layout many USB drivers insist on). Floats and DSD get no alternatives.
func Candidates(want sink.Format) ([]WFX, error) {
	base := WFX{SampleRate: want.SampleRate, Channels: want.Channels, ChannelMask: ChannelMask(want.Channels)}
	mk := func(container, valid int, float bool, t ringbuf.SampleType) WFX {
		w := base
		w.ContainerBits, w.ValidBits, w.Float, w.Type = container, valid, float, t
		return w
	}
	switch want.Type {
	case ringbuf.S16:
		return []WFX{
			mk(16, 16, false, ringbuf.S16),
			mk(24, 24, false, ringbuf.S24_3),
			mk(32, 32, false, ringbuf.S32),
			mk(32, 24, false, ringbuf.S32),
			mk(32, 16, false, ringbuf.S32),
		}, nil
	case ringbuf.S24_3:
		return []WFX{
			mk(24, 24, false, ringbuf.S24_3),
			mk(32, 32, false, ringbuf.S32),
			mk(32, 24, false, ringbuf.S32),
		}, nil
	case ringbuf.S32:
		return []WFX{mk(32, 32, false, ringbuf.S32)}, nil
	case ringbuf.F32:
		return []WFX{mk(32, 32, true, ringbuf.F32)}, nil
	case ringbuf.F64:
		return []WFX{mk(64, 64, true, ringbuf.F64)}, nil
	case ringbuf.DSD8:
		return nil, fmt.Errorf("%w: WASAPI has no native DSD path; use DoP or ASIO", sink.ErrUnsupportedFormat)
	}
	return nil, fmt.Errorf("%w: unknown sample type %v", sink.ErrUnsupportedFormat, want.Type)
}

// ProbeRates is what Caps() asks the endpoint about.
var ProbeRates = []int{44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000}
