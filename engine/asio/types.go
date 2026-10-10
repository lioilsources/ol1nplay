// Package asio is the primary output backend on Windows: a sink.Backend that
// drives an ASIO driver through an SDK-free C shim (see iasio.h). Every
// driver call runs on one dedicated OS thread; the real-time callback is C
// only.
//
// This file is platform independent so the format negotiation can be unit
// tested on any OS.
package asio

import (
	"fmt"

	"github.com/ol1n/ol1nplay/engine/ringbuf"
	"github.com/ol1n/ol1nplay/engine/sink"
)

// SampleType mirrors ASIOSampleType (see iasio.h).
type SampleType int32

// ASIOSampleType values. Kept in Go too so tests and the UI can name them
// without cgo.
const (
	STInt16MSB    SampleType = 0
	STInt24MSB    SampleType = 1
	STInt32MSB    SampleType = 2
	STFloat32MSB  SampleType = 3
	STFloat64MSB  SampleType = 4
	STInt32MSB16  SampleType = 8
	STInt32MSB18  SampleType = 9
	STInt32MSB20  SampleType = 10
	STInt32MSB24  SampleType = 11
	STInt16LSB    SampleType = 16
	STInt24LSB    SampleType = 17
	STInt32LSB    SampleType = 18
	STFloat32LSB  SampleType = 19
	STFloat64LSB  SampleType = 20
	STInt32LSB16  SampleType = 24
	STInt32LSB18  SampleType = 25
	STInt32LSB20  SampleType = 26
	STInt32LSB24  SampleType = 27
	STDSDInt8LSB1 SampleType = 32
	STDSDInt8MSB1 SampleType = 33
	STDSDInt8NER8 SampleType = 40
)

// alignBits are the valid-bit counts of the Int32xxx16/18/20/24 families.
var alignBits = [4]int{16, 18, 20, 24}

func (t SampleType) String() string {
	switch t {
	case STInt16MSB:
		return "Int16MSB"
	case STInt24MSB:
		return "Int24MSB"
	case STInt32MSB:
		return "Int32MSB"
	case STFloat32MSB:
		return "Float32MSB"
	case STFloat64MSB:
		return "Float64MSB"
	case STInt32MSB16, STInt32MSB18, STInt32MSB20, STInt32MSB24:
		return fmt.Sprintf("Int32MSB%d", alignBits[int(t)-int(STInt32MSB16)])
	case STInt16LSB:
		return "Int16LSB"
	case STInt24LSB:
		return "Int24LSB"
	case STInt32LSB:
		return "Int32LSB"
	case STFloat32LSB:
		return "Float32LSB"
	case STFloat64LSB:
		return "Float64LSB"
	case STInt32LSB16, STInt32LSB18, STInt32LSB20, STInt32LSB24:
		return fmt.Sprintf("Int32LSB%d", alignBits[int(t)-int(STInt32LSB16)])
	case STDSDInt8LSB1:
		return "DSDInt8LSB1"
	case STDSDInt8MSB1:
		return "DSDInt8MSB1"
	case STDSDInt8NER8:
		return "DSDInt8NER8"
	}
	return fmt.Sprintf("ASIOSampleType(%d)", int32(t))
}

// DeviceType is what a driver's output channels run: a ring buffer sample
// type plus the number of valid (LSB-justified) bits for the Int32LSBxx
// family, which the feeder must right-align into.
type DeviceType struct {
	Type      ringbuf.SampleType
	ValidBits int // 0 = full container width
}

// ToRing maps an ASIO sample type to the ring buffer representation. Big
// endian types are refused: x86 hardware never asks for them and supporting
// them would mean byte-swapping in the callback.
func (t SampleType) ToRing() (DeviceType, error) {
	switch t {
	case STInt16LSB:
		return DeviceType{Type: ringbuf.S16}, nil
	case STInt24LSB:
		return DeviceType{Type: ringbuf.S24_3}, nil
	case STInt32LSB:
		return DeviceType{Type: ringbuf.S32}, nil
	case STFloat32LSB:
		return DeviceType{Type: ringbuf.F32}, nil
	case STFloat64LSB:
		return DeviceType{Type: ringbuf.F64}, nil
	case STInt32LSB16:
		return DeviceType{Type: ringbuf.S32, ValidBits: 16}, nil
	case STInt32LSB18:
		return DeviceType{Type: ringbuf.S32, ValidBits: 18}, nil
	case STInt32LSB20:
		return DeviceType{Type: ringbuf.S32, ValidBits: 20}, nil
	case STInt32LSB24:
		return DeviceType{Type: ringbuf.S32, ValidBits: 24}, nil
	case STDSDInt8MSB1:
		return DeviceType{Type: ringbuf.DSD8}, nil
	case STDSDInt8LSB1, STDSDInt8NER8:
		return DeviceType{}, fmt.Errorf("asio: DSD layout %s is not supported (only MSB-first 8-bit packing)", t)
	case STInt16MSB, STInt24MSB, STInt32MSB, STFloat32MSB, STFloat64MSB,
		STInt32MSB16, STInt32MSB18, STInt32MSB20, STInt32MSB24:
		return DeviceType{}, fmt.Errorf("asio: big-endian sample type %s is not supported", t)
	}
	return DeviceType{}, fmt.Errorf("asio: unknown sample type %d", int32(t))
}

// wantBits is the number of significant bits a ring type carries.
func wantBits(t ringbuf.SampleType) int {
	switch t {
	case ringbuf.S16:
		return 16
	case ringbuf.S24_3:
		return 24
	case ringbuf.S32:
		return 32
	}
	return 0
}

// Negotiate decides whether a track format can be played bit-perfectly on a
// device running dev, and returns the Format the stream will run. The only
// transformation it allows is widening an integer sample into a larger
// integer container (zero LSBs or LSB-justified into ValidBits): no
// resampling, no float<->int, no truncation.
func Negotiate(want sink.Format, dev DeviceType) (sink.Format, error) {
	out := want
	out.Type = dev.Type
	out.ValidBits = 0

	if want.Type == ringbuf.DSD8 || dev.Type == ringbuf.DSD8 {
		if want.Type == dev.Type {
			out.DSDNative = true
			return out, nil
		}
		return sink.Format{}, fmt.Errorf("%w: DSD/PCM mismatch (track %s, device %s)", sink.ErrUnsupportedFormat, want.Type, dev.Type)
	}

	if want.Type == dev.Type && dev.ValidBits == 0 {
		return out, nil
	}

	if want.Type.IsFloat() || dev.Type.IsFloat() {
		if want.Type == dev.Type {
			return out, nil
		}
		return sink.Format{}, fmt.Errorf("%w: track is %s, device runs %s (float conversion is not bit-perfect)", sink.ErrUnsupportedFormat, want.Type, dev.Type)
	}

	wider, ok := sink.WidenTo(want.Type, []ringbuf.SampleType{dev.Type})
	if !ok || wider != dev.Type {
		return sink.Format{}, fmt.Errorf("%w: cannot fit %s samples into a %s device container", sink.ErrUnsupportedFormat, want.Type, dev.Type)
	}
	if dev.ValidBits != 0 && dev.ValidBits < wantBits(want.Type) {
		return sink.Format{}, fmt.Errorf("%w: device accepts only %d valid bits, track has %d", sink.ErrUnsupportedFormat, dev.ValidBits, wantBits(want.Type))
	}
	out.ValidBits = dev.ValidBits
	return out, nil
}

// BufferPreference selects which of the driver's sizes to use.
type BufferPreference string

const (
	BufferPreferred BufferPreference = "preferred" // what the driver recommends (default)
	BufferMax       BufferPreference = "max"       // largest: most headroom, latency is irrelevant here
	BufferMin       BufferPreference = "min"       // smallest: only for experiments
)

// PickBufferSize applies the preference to the driver's reported sizes.
func PickBufferSize(pref BufferPreference, min, max, preferred, granularity int) int {
	var n int
	switch pref {
	case BufferMax:
		n = max
	case BufferMin:
		n = min
	default:
		n = preferred
	}
	if n <= 0 {
		n = preferred
	}
	if n <= 0 {
		n = max
	}
	if n <= 0 {
		n = 512
	}
	// granularity == -1 means powers of two; otherwise sizes must be
	// min + k*granularity. Preferred always satisfies this, so only clamp.
	if min > 0 && n < min {
		n = min
	}
	if max > 0 && n > max {
		n = max
	}
	_ = granularity
	return n
}

// ProbeRates is the list of sample rates Caps() asks the driver about.
var ProbeRates = []int{44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000}

// ErrWindowsOnly is returned by the constructor on other platforms.
var ErrWindowsOnly = fmt.Errorf("asio: ASIO is available on Windows only")
