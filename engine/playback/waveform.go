package playback

import (
	"encoding/binary"
	"math"

	"github.com/ol1n/ol1nplay/engine/protocol"
	"github.com/ol1n/ol1nplay/engine/ringbuf"
)

const (
	waveBins = 1024
	// Frames looked at per bin, spread evenly across it. Enough for a
	// picture of the track's loudness; keeps a ten-minute hi-res file to a
	// few milliseconds instead of a pass over every sample.
	waveFramesPerBin = 1024
)

// computeWaveform builds the seek bar's loudness overview from a fully
// loaded source. It only reads; the PCM is never altered. Returns nil for
// DSD (no amplitude to read from a 1-bit stream) and for empty sources.
func computeWaveform(path string, src source) *protocol.Waveform {
	f := src.Format()
	total := src.Frames()
	if f.DSD || total <= 0 || f.Channels <= 0 {
		return nil
	}
	sb := f.Type.Bytes()
	var read func([]byte) float64
	switch f.Type {
	case ringbuf.S16:
		read = func(b []byte) float64 { return float64(int16(binary.LittleEndian.Uint16(b))) / (1 << 15) }
	case ringbuf.S24_3:
		read = func(b []byte) float64 {
			v := int32(uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16)
			if v&0x800000 != 0 {
				v |= ^0xFFFFFF
			}
			return float64(v) / (1 << 23)
		}
	case ringbuf.S32:
		// 24-in-32 is LSB-justified, so full scale follows the bit depth.
		bits := f.BitDepth
		if bits <= 0 || bits > 32 {
			bits = 32
		}
		scale := math.Ldexp(1, bits-1)
		read = func(b []byte) float64 { return float64(int32(binary.LittleEndian.Uint32(b))) / scale }
	case ringbuf.F32:
		read = func(b []byte) float64 { return float64(math.Float32frombits(binary.LittleEndian.Uint32(b))) }
	case ringbuf.F64:
		read = func(b []byte) float64 { return math.Float64frombits(binary.LittleEndian.Uint64(b)) }
	default:
		return nil
	}

	bins := waveBins
	if total < int64(bins) {
		bins = int(total)
	}
	w := &protocol.Waveform{Path: path, Bins: bins, Peak: make([]byte, bins), RMS: make([]byte, bins)}
	fb := f.FrameBytes()
	frame := make([]byte, fb)
	for i := 0; i < bins; i++ {
		start := total * int64(i) / int64(bins)
		end := total * int64(i+1) / int64(bins)
		step := (end - start) / waveFramesPerBin
		if step < 1 {
			step = 1
		}
		var peak, sum float64
		var n int
		for pos := start; pos < end; pos += step {
			if got, err := src.ReadAt(pos, frame); err != nil || got == 0 {
				break
			}
			for c := 0; c < f.Channels; c++ {
				v := math.Abs(read(frame[c*sb:]))
				if v > peak {
					peak = v
				}
				sum += v * v
				n++
			}
		}
		if n > 0 {
			w.Peak[i] = waveByte(peak)
			w.RMS[i] = waveByte(math.Sqrt(sum / float64(n)))
		}
	}
	return w
}

// waveByte maps linear amplitude 0..1 to 0..255 on a square-root scale, so
// a passage at −40 dBFS is still a tenth of the height instead of a hairline.
func waveByte(a float64) byte {
	if a >= 1 {
		return 255
	}
	if a <= 0 || math.IsNaN(a) {
		return 0
	}
	return byte(math.Round(math.Sqrt(a) * 255))
}
