package wasapi

import (
	"errors"
	"testing"

	"github.com/ol1n/ol1nplay/engine/ringbuf"
	"github.com/ol1n/ol1nplay/engine/sink"
)

func TestWFXArithmetic(t *testing.T) {
	w := WFX{SampleRate: 96000, Channels: 2, ContainerBits: 24, ValidBits: 24, Type: ringbuf.S24_3}
	if w.BlockAlign() != 6 {
		t.Errorf("blockAlign %d", w.BlockAlign())
	}
	if w.AvgBytesPerSec() != 576000 {
		t.Errorf("avg %d", w.AvgBytesPerSec())
	}
	f := w.Format()
	if f.ValidBits != 0 || f.Type != ringbuf.S24_3 {
		t.Errorf("format %+v", f)
	}
	w2 := WFX{SampleRate: 44100, Channels: 2, ContainerBits: 32, ValidBits: 24, Type: ringbuf.S32}
	if f := w2.Format(); f.ValidBits != 24 || f.Type != ringbuf.S32 {
		t.Errorf("24-in-32 format %+v", f)
	}
}

func TestChannelMask(t *testing.T) {
	if ChannelMask(2) != 0x3 {
		t.Errorf("stereo mask %#x", ChannelMask(2))
	}
	if ChannelMask(6) != 0x3F {
		t.Errorf("5.1 mask %#x", ChannelMask(6))
	}
	if ChannelMask(8) != 0x63F {
		t.Errorf("7.1 mask %#x", ChannelMask(8))
	}
	if ChannelMask(11) != 0 {
		t.Errorf("odd layout should be unspecified")
	}
}

func TestCandidates(t *testing.T) {
	c, err := Candidates(sink.Format{SampleRate: 44100, Channels: 2, Type: ringbuf.S16})
	if err != nil || len(c) != 5 || c[0].ContainerBits != 16 || c[len(c)-1].ValidBits != 16 {
		t.Errorf("s16 candidates %+v %v", c, err)
	}
	c, err = Candidates(sink.Format{SampleRate: 96000, Channels: 2, Type: ringbuf.S24_3})
	if err != nil || len(c) != 3 || c[0].Type != ringbuf.S24_3 || c[2].ValidBits != 24 || c[2].ContainerBits != 32 {
		t.Errorf("s24 candidates %+v %v", c, err)
	}
	c, err = Candidates(sink.Format{SampleRate: 96000, Channels: 2, Type: ringbuf.F32})
	if err != nil || len(c) != 1 || !c[0].Float {
		t.Errorf("f32 candidates %+v %v", c, err)
	}
	_, err = Candidates(sink.Format{SampleRate: 352800, Channels: 2, Type: ringbuf.DSD8})
	if !errors.Is(err, sink.ErrUnsupportedFormat) {
		t.Errorf("dsd should be unsupported: %v", err)
	}
	for _, w := range c {
		if w.ChannelMask != 0x3 {
			t.Errorf("mask not filled: %+v", w)
		}
	}
}
