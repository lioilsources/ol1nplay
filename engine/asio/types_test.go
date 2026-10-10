package asio

import (
	"errors"
	"testing"

	"github.com/ol1n/ol1nplay/engine/ringbuf"
	"github.com/ol1n/ol1nplay/engine/sink"
)

func TestToRing(t *testing.T) {
	cases := []struct {
		in    SampleType
		want  DeviceType
		fails bool
	}{
		{STInt16LSB, DeviceType{Type: ringbuf.S16}, false},
		{STInt24LSB, DeviceType{Type: ringbuf.S24_3}, false},
		{STInt32LSB, DeviceType{Type: ringbuf.S32}, false},
		{STFloat32LSB, DeviceType{Type: ringbuf.F32}, false},
		{STFloat64LSB, DeviceType{Type: ringbuf.F64}, false},
		{STInt32LSB16, DeviceType{Type: ringbuf.S32, ValidBits: 16}, false},
		{STInt32LSB24, DeviceType{Type: ringbuf.S32, ValidBits: 24}, false},
		{STDSDInt8MSB1, DeviceType{Type: ringbuf.DSD8}, false},
		{STInt16MSB, DeviceType{}, true},
		{STInt32MSB24, DeviceType{}, true},
		{STDSDInt8LSB1, DeviceType{}, true},
		{SampleType(99), DeviceType{}, true},
	}
	for _, c := range cases {
		got, err := c.in.ToRing()
		if c.fails {
			if err == nil {
				t.Errorf("%s: expected error", c.in)
			}
			continue
		}
		if err != nil || got != c.want {
			t.Errorf("%s: got %+v, %v; want %+v", c.in, got, err, c.want)
		}
	}
}

func TestNegotiate(t *testing.T) {
	f := func(typ ringbuf.SampleType) sink.Format {
		return sink.Format{SampleRate: 96000, Channels: 2, Type: typ}
	}
	cases := []struct {
		name  string
		want  sink.Format
		dev   DeviceType
		out   sink.Format
		fails bool
	}{
		{"exact s24", f(ringbuf.S24_3), DeviceType{Type: ringbuf.S24_3}, f(ringbuf.S24_3), false},
		{"s24 into s32", f(ringbuf.S24_3), DeviceType{Type: ringbuf.S32}, f(ringbuf.S32), false},
		{"s16 into s32 LSB24", f(ringbuf.S16), DeviceType{Type: ringbuf.S32, ValidBits: 24},
			sink.Format{SampleRate: 96000, Channels: 2, Type: ringbuf.S32, ValidBits: 24}, false},
		{"s24 into s32 LSB16 refused", f(ringbuf.S24_3), DeviceType{Type: ringbuf.S32, ValidBits: 16}, sink.Format{}, true},
		{"s32 into s24 refused", f(ringbuf.S32), DeviceType{Type: ringbuf.S24_3}, sink.Format{}, true},
		{"float to int refused", f(ringbuf.F32), DeviceType{Type: ringbuf.S32}, sink.Format{}, true},
		{"int to float refused", f(ringbuf.S24_3), DeviceType{Type: ringbuf.F32}, sink.Format{}, true},
		{"float exact", f(ringbuf.F32), DeviceType{Type: ringbuf.F32}, f(ringbuf.F32), false},
		{"dsd native", f(ringbuf.DSD8), DeviceType{Type: ringbuf.DSD8},
			sink.Format{SampleRate: 96000, Channels: 2, Type: ringbuf.DSD8, DSDNative: true}, false},
		{"dsd on pcm refused", f(ringbuf.DSD8), DeviceType{Type: ringbuf.S32}, sink.Format{}, true},
	}
	for _, c := range cases {
		got, err := Negotiate(c.want, c.dev)
		if c.fails {
			if err == nil {
				t.Errorf("%s: expected error, got %+v", c.name, got)
			} else if !errors.Is(err, sink.ErrUnsupportedFormat) {
				t.Errorf("%s: error should wrap ErrUnsupportedFormat: %v", c.name, err)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: unexpected error %v", c.name, err)
			continue
		}
		if got != c.out {
			t.Errorf("%s: got %+v want %+v", c.name, got, c.out)
		}
	}
}

func TestPickBufferSize(t *testing.T) {
	if n := PickBufferSize(BufferPreferred, 64, 2048, 512, -1); n != 512 {
		t.Errorf("preferred: %d", n)
	}
	if n := PickBufferSize(BufferMax, 64, 2048, 512, -1); n != 2048 {
		t.Errorf("max: %d", n)
	}
	if n := PickBufferSize(BufferMin, 64, 2048, 512, -1); n != 64 {
		t.Errorf("min: %d", n)
	}
	if n := PickBufferSize(BufferPreferred, 0, 0, 0, 0); n != 512 {
		t.Errorf("fallback: %d", n)
	}
}

func TestSampleTypeString(t *testing.T) {
	if STInt32LSB24.String() != "Int32LSB24" {
		t.Errorf("got %s", STInt32LSB24)
	}
	if STInt32MSB18.String() != "Int32MSB18" {
		t.Errorf("got %s", STInt32MSB18)
	}
}
