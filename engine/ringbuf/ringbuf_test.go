package ringbuf

import (
	"encoding/binary"
	"testing"
)

// One stereo frame L=1000, R=-200 → downmix 400.
func frameS16() []byte {
	b := make([]byte, 4)
	binary.LittleEndian.PutUint16(b, uint16(int16(1000)))
	binary.LittleEndian.PutUint16(b[2:], uint16(0xFF38)) // -200
	return b
}

func frameS32() []byte {
	b := make([]byte, 8)
	binary.LittleEndian.PutUint32(b, uint32(int32(1000)))
	binary.LittleEndian.PutUint32(b[4:], 0xFFFFFF38) // -200
	return b
}

func TestMonoModes(t *testing.T) {
	cases := []struct {
		mode MonoMode
		l, r int32
	}{
		{Stereo, 1000, -200},
		{Mono, 400, 400},
		{MonoLeft, 400, 0},
		{MonoRight, 0, 400},
		{OnlyLeft, 1000, 0},
		{OnlyRight, 0, -200},
	}
	types := []struct {
		typ   SampleType
		frame func() []byte
		get   func([]byte) int32
	}{
		{S16, frameS16, func(b []byte) int32 { return int32(int16(binary.LittleEndian.Uint16(b))) }},
		{S32, frameS32, func(b []byte) int32 { return int32(binary.LittleEndian.Uint32(b)) }},
	}
	for _, ty := range types {
		sb := ty.typ.Bytes()
		for _, c := range cases {
			// Interleaved (WASAPI / CoreAudio path).
			r, err := New(16, 2, ty.typ)
			if err != nil {
				t.Fatal(err)
			}
			r.SetMonoMode(c.mode)
			r.Write(ty.frame())
			out := make([]byte, 2*sb)
			if n := r.ReadInterleaved(out); n != 1 {
				t.Fatalf("%v mode %d: read %d frames", ty.typ, c.mode, n)
			}
			if l, rr := ty.get(out), ty.get(out[sb:]); l != c.l || rr != c.r {
				t.Errorf("%v mode %d interleaved: got L=%d R=%d, want L=%d R=%d", ty.typ, c.mode, l, rr, c.l, c.r)
			}
			r.Close()

			// Planar (ASIO path).
			r, _ = New(16, 2, ty.typ)
			r.SetMonoMode(c.mode)
			r.Write(ty.frame())
			pl := [][]byte{make([]byte, sb), make([]byte, sb)}
			if n := r.ReadPlanar(pl); n != 1 {
				t.Fatalf("%v mode %d: planar read %d frames", ty.typ, c.mode, n)
			}
			if l, rr := ty.get(pl[0]), ty.get(pl[1]); l != c.l || rr != c.r {
				t.Errorf("%v mode %d planar: got L=%d R=%d, want L=%d R=%d", ty.typ, c.mode, l, rr, c.l, c.r)
			}
			r.Close()
		}
	}
}

// DSD has no mono: zero bytes are not DSD silence, so every mode leaves it alone.
func TestMonoLeavesDSDAlone(t *testing.T) {
	r, err := New(16, 2, DSD8)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	r.SetMonoMode(MonoLeft)
	r.Write([]byte{0x69, 0x96})
	out := make([]byte, 2)
	r.ReadInterleaved(out)
	if out[0] != 0x69 || out[1] != 0x96 {
		t.Fatalf("DSD frame was altered: % x", out)
	}
}
