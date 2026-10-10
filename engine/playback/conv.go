package playback

import (
	"encoding/binary"
	"fmt"
	"math"

	"github.com/ol1n/ol1nplay/engine/ringbuf"
	"github.com/ol1n/ol1nplay/engine/sink"
)

// converter rewrites source frames into device frames. Every converter here
// is lossless: it only moves bits into a wider container, drops zero LSB
// bytes that libavcodec padded, or packs DSD into DoP. Nothing rounds,
// nothing dithers, nothing resamples. If a converter cannot be lossless it
// does not exist and the engine reports the format as unplayable.
type converter struct {
	srcType ringbuf.SampleType
	dstType ringbuf.SampleType
	srcFB   int // source frame bytes
	dstFB   int // device frame bytes
	// srcPerDst is source frames consumed per device frame: 1 for PCM,
	// 2 for DoP (16 DSD bits per channel per PCM frame).
	srcPerDst int
	channels  int
	validBits int
	// bitPerfect is false only for conversions the user explicitly allowed
	// that lose information (none exist today; DSD→PCM happens in the
	// decoder, before the converter, and is flagged there).
	bitPerfect  bool
	description string
	fn          func(dst, src []byte, frames int, state *convState)
}

// convState carries the DoP marker phase across calls.
type convState struct {
	dopMarker byte
}

func newConvState() *convState { return &convState{dopMarker: 0x05} }

// makeConverter picks the lossless path from src to the device format.
func makeConverter(src ringbuf.SampleType, srcDSD bool, channels int, dev sink.Format, srcBits int) (*converter, error) {
	c := &converter{srcType: src, dstType: dev.Type, channels: channels, srcPerDst: 1,
		srcFB: src.Bytes() * channels, dstFB: dev.Type.Bytes() * channels, validBits: dev.ValidBits, bitPerfect: true}

	if srcDSD || src == ringbuf.DSD8 {
		if dev.Type == ringbuf.DSD8 {
			c.description = "native DSD"
			c.fn = convCopy
			return c, nil
		}
		// DoP: two DSD bytes per channel per PCM frame, marker 0x05/0xFA in the top byte.
		c.srcPerDst = 2
		switch dev.Type {
		case ringbuf.S32:
			c.description = "DoP (DSD over PCM, 32-bit container)"
			c.fn = convDoPS32
		case ringbuf.S24_3:
			c.description = "DoP (DSD over PCM, 24-bit)"
			c.fn = convDoPS24
		default:
			return nil, fmt.Errorf("%w: DSD needs a 24/32-bit integer path for DoP, device offers %s", sink.ErrUnsupportedFormat, dev.Type)
		}
		if dev.ValidBits != 0 && dev.ValidBits != 24 {
			return nil, fmt.Errorf("%w: DoP needs 24 valid bits, device offers %d", sink.ErrUnsupportedFormat, dev.ValidBits)
		}
		if dev.ValidBits == 24 && dev.Type == ringbuf.S32 {
			// LSB-justified 24-in-32: DoP word sits in the low 24 bits.
			c.fn = convDoPS32LSB24
			c.description = "DoP (DSD over PCM, 24-in-32 LSB)"
		}
		return c, nil
	}

	if src == dev.Type && dev.ValidBits == 0 {
		c.description = "bit-perfect (no conversion)"
		c.fn = convCopy
		return c, nil
	}

	switch {
	case src == ringbuf.S16 && dev.Type == ringbuf.S32 && dev.ValidBits == 0:
		c.description = "16 → 32-bit container, zero-padded"
		c.fn = convS16toS32
	case src == ringbuf.S16 && dev.Type == ringbuf.S32 && dev.ValidBits == 16:
		c.description = "16 → 32-bit container, LSB-justified"
		c.fn = convS16toS32LSB
	case src == ringbuf.S16 && dev.Type == ringbuf.S24_3:
		c.description = "16 → 24-bit, zero-padded"
		c.fn = convS16toS24
	case src == ringbuf.S32 && dev.Type == ringbuf.S24_3:
		if srcBits > 24 {
			return nil, fmt.Errorf("%w: %d-bit source into a 24-bit device would truncate", sink.ErrUnsupportedFormat, srcBits)
		}
		c.description = "24-in-32 → packed 24-bit (zero LSB byte dropped)"
		c.fn = convS32toS24
	case src == ringbuf.S32 && dev.Type == ringbuf.S32 && dev.ValidBits == 24:
		if srcBits > 24 {
			return nil, fmt.Errorf("%w: %d-bit source into a 24-valid-bit device would truncate", sink.ErrUnsupportedFormat, srcBits)
		}
		c.description = "24-in-32 MSB → 24-in-32 LSB-justified"
		c.fn = convS32MSBtoLSB24
	case src == ringbuf.S32 && dev.Type == ringbuf.S32 && dev.ValidBits == 16:
		if srcBits > 16 {
			return nil, fmt.Errorf("%w: %d-bit source into a 16-valid-bit device would truncate", sink.ErrUnsupportedFormat, srcBits)
		}
		c.description = "16-in-32 MSB → LSB-justified"
		c.fn = convS32MSBtoLSB16
	case src == ringbuf.S32 && dev.Type == ringbuf.S16:
		if srcBits > 16 {
			return nil, fmt.Errorf("%w: %d-bit source into a 16-bit device would truncate", sink.ErrUnsupportedFormat, srcBits)
		}
		c.description = "16-in-32 → 16-bit (zero bytes dropped)"
		c.fn = convS32toS16
	case src == ringbuf.F32 && dev.Type == ringbuf.F64:
		c.description = "float32 → float64 (exact)"
		c.fn = convF32toF64
	default:
		return nil, fmt.Errorf("%w: no lossless path from %s to %s", sink.ErrUnsupportedFormat, src, dev.Type)
	}
	return c, nil
}

// convert runs the converter over srcFrames source frames. dst must hold
// srcFrames/srcPerDst device frames. Returns device frames produced.
func (c *converter) convert(dst, src []byte, srcFrames int, st *convState) int {
	if c.srcPerDst == 2 {
		srcFrames &^= 1
	}
	panicIfShort(dst, src, srcFrames, c)
	c.fn(dst, src, srcFrames, st)
	return srcFrames / c.srcPerDst
}

func panicIfShort(dst, src []byte, srcFrames int, c *converter) {
	if len(src) < srcFrames*c.srcFB || len(dst) < srcFrames/c.srcPerDst*c.dstFB {
		panic("playback: converter buffers too small")
	}
}

func convCopy(dst, src []byte, frames int, _ *convState) {
	copy(dst, src[:len(dst)])
}

func convS16toS32(dst, src []byte, frames int, _ *convState) {
	n := len(src) / 2
	for i := 0; i < n; i++ {
		v := binary.LittleEndian.Uint16(src[2*i:])
		binary.LittleEndian.PutUint32(dst[4*i:], uint32(v)<<16)
	}
}

func convS16toS32LSB(dst, src []byte, frames int, _ *convState) {
	n := len(src) / 2
	for i := 0; i < n; i++ {
		v := int16(binary.LittleEndian.Uint16(src[2*i:]))
		binary.LittleEndian.PutUint32(dst[4*i:], uint32(int32(v)))
	}
}

func convS16toS24(dst, src []byte, frames int, _ *convState) {
	n := len(src) / 2
	for i := 0; i < n; i++ {
		dst[3*i] = 0
		dst[3*i+1] = src[2*i]
		dst[3*i+2] = src[2*i+1]
	}
}

func convS32toS24(dst, src []byte, frames int, _ *convState) {
	n := len(src) / 4
	for i := 0; i < n; i++ {
		dst[3*i] = src[4*i+1]
		dst[3*i+1] = src[4*i+2]
		dst[3*i+2] = src[4*i+3]
	}
}

func convS32MSBtoLSB24(dst, src []byte, frames int, _ *convState) {
	n := len(src) / 4
	for i := 0; i < n; i++ {
		v := int32(binary.LittleEndian.Uint32(src[4*i:]))
		binary.LittleEndian.PutUint32(dst[4*i:], uint32(v>>8))
	}
}

func convS32MSBtoLSB16(dst, src []byte, frames int, _ *convState) {
	n := len(src) / 4
	for i := 0; i < n; i++ {
		v := int32(binary.LittleEndian.Uint32(src[4*i:]))
		binary.LittleEndian.PutUint32(dst[4*i:], uint32(v>>16))
	}
}

func convS32toS16(dst, src []byte, frames int, _ *convState) {
	n := len(src) / 4
	for i := 0; i < n; i++ {
		dst[2*i] = src[4*i+2]
		dst[2*i+1] = src[4*i+3]
	}
}

func convF32toF64(dst, src []byte, frames int, _ *convState) {
	n := len(src) / 4
	for i := 0; i < n; i++ {
		f := float64(math.Float32frombits(binary.LittleEndian.Uint32(src[4*i:])))
		binary.LittleEndian.PutUint64(dst[8*i:], math.Float64bits(f))
	}
}

// DoP: PCM frame k carries DSD bytes 2k and 2k+1 of each channel, newest in
// the low byte, with the marker alternating 0x05 / 0xFA per PCM frame so the
// DAC can detect the stream. We keep the phase across calls (state) so a
// chunk boundary never breaks the alternation.
func dopMarkerNext(st *convState) byte {
	if st == nil {
		return 0x05
	}
	m := st.dopMarker
	if m == 0x05 {
		st.dopMarker = 0xFA
	} else {
		st.dopMarker = 0x05
	}
	return m
}

func convDoPS32(dst, src []byte, srcFrames int, st *convState) {
	ch := len(src) / srcFrames
	if srcFrames == 0 {
		return
	}
	frames := srcFrames / 2
	for k := 0; k < frames; k++ {
		m := dopMarkerNext(st)
		for c := 0; c < ch; c++ {
			b0 := src[(2*k)*ch+c]
			b1 := src[(2*k+1)*ch+c]
			binary.LittleEndian.PutUint32(dst[(k*ch+c)*4:], uint32(m)<<24|uint32(b0)<<16|uint32(b1)<<8)
		}
	}
}

func convDoPS32LSB24(dst, src []byte, srcFrames int, st *convState) {
	ch := len(src) / srcFrames
	if srcFrames == 0 {
		return
	}
	frames := srcFrames / 2
	for k := 0; k < frames; k++ {
		m := dopMarkerNext(st)
		for c := 0; c < ch; c++ {
			b0 := src[(2*k)*ch+c]
			b1 := src[(2*k+1)*ch+c]
			w := int32(uint32(m)<<24|uint32(b0)<<16|uint32(b1)<<8) >> 8
			binary.LittleEndian.PutUint32(dst[(k*ch+c)*4:], uint32(w))
		}
	}
}

func convDoPS24(dst, src []byte, srcFrames int, st *convState) {
	ch := len(src) / srcFrames
	if srcFrames == 0 {
		return
	}
	frames := srcFrames / 2
	for k := 0; k < frames; k++ {
		m := dopMarkerNext(st)
		for c := 0; c < ch; c++ {
			o := (k*ch + c) * 3
			dst[o] = src[(2*k+1)*ch+c]
			dst[o+1] = src[(2*k)*ch+c]
			dst[o+2] = m
		}
	}
}
