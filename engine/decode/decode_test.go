package decode

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"

	"github.com/ol1n/ol1nplay/engine/ringbuf"
)

func td(name string) string { return filepath.Join("..", "testdata", name) }

// Bit-perfect check: our decoder must yield exactly the bytes the ffmpeg CLI
// yields for the same file in the codec's native format.
func TestBitPerfectAgainstFFmpegCLI(t *testing.T) {
	cases := []struct {
		file, ref string
		typ       ringbuf.SampleType
		depth     int
		rate      int
	}{
		{"sine16_44.flac", "ref_sine16_44.s16le.raw", ringbuf.S16, 16, 44100},
		{"sine24_96.flac", "ref_sine24_96.s32le.raw", ringbuf.S32, 24, 96000},
		{"sine24_48.wav", "ref_sine24_48.s32le.raw", ringbuf.S32, 24, 48000},
		{"sine24_44.m4a", "ref_sine24_44_alac.s32le.raw", ringbuf.S32, 24, 44100},
	}
	for _, c := range cases {
		t.Run(c.file, func(t *testing.T) {
			buf, err := DecodeAll(td(c.file), DSDRaw, 0, nil)
			if err != nil {
				t.Fatal(err)
			}
			if buf.Format.Type != c.typ || buf.Format.BitDepth != c.depth || buf.Format.SampleRate != c.rate || buf.Format.Channels != 2 {
				t.Fatalf("format = %+v", buf.Format)
			}
			ref, err := os.ReadFile(td(c.ref))
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(buf.PCM, ref) {
				t.Fatalf("PCM differs: got %d bytes, ref %d bytes (first diff at %d)", len(buf.PCM), len(ref), firstDiff(buf.PCM, ref))
			}
			if c.depth == 24 {
				// 24 valid bits MSB-justified: every low byte must be zero.
				for i := 0; i < len(buf.PCM); i += 4 {
					if buf.PCM[i] != 0 {
						t.Fatalf("24-bit sample has non-zero LSB byte at %d", i)
					}
				}
			}
		})
	}
}

func firstDiff(a, b []byte) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		if a[i] != b[i] {
			return i
		}
	}
	return n
}

func TestProbeTags(t *testing.T) {
	m, err := Probe(td("sine16_44.flac"))
	if err != nil {
		t.Fatal(err)
	}
	if m.Title != "Sine Sixteen" || m.Artist != "Ol1n" || m.Album != "Test" || m.TrackNo != 3 || m.Year != 2026 {
		t.Fatalf("tags = %+v", m)
	}
	if !m.Lossless || m.Codec != "flac" || m.BitDepth != 16 || m.SampleRate != 44100 || m.DurationMs < 1400 || m.DurationMs > 1600 {
		t.Fatalf("format = %+v", m)
	}
	if m.Samples != 66150 {
		t.Fatalf("samples = %d", m.Samples)
	}
}

func TestProbeEmbeddedCover(t *testing.T) {
	m, err := Probe(td("sine_cover.flac"))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Picture) == 0 || m.PictureMime != "image/png" {
		t.Fatalf("picture len=%d mime=%q", len(m.Picture), m.PictureMime)
	}
	if !bytes.HasPrefix(m.Picture, []byte("\x89PNG")) {
		t.Fatal("not a PNG")
	}
}

func TestLossyFormats(t *testing.T) {
	for _, f := range []string{"sine.mp3", "sine_aac.m4a", "sine.opus", "sine.ogg", "sine16_44.aiff", "sine24_44.wv"} {
		t.Run(f, func(t *testing.T) {
			if _, err := os.Stat(td(f)); err != nil {
				t.Skip("fixture missing")
			}
			buf, err := DecodeAll(td(f), DSDRaw, 0, nil)
			if err != nil {
				t.Fatal(err)
			}
			if buf.Frames < 60000 || buf.Frames > 160000 {
				t.Fatalf("frames = %d (format %v)", buf.Frames, buf.Format)
			}
			if buf.Format.Channels != 2 {
				t.Fatalf("channels = %d", buf.Format.Channels)
			}
		})
	}
}

// Seeking must be sample exact: decoding from frame N must give the same
// bytes as the full decode from offset N.
func TestSeekExact(t *testing.T) {
	for _, f := range []string{"sine24_96.flac", "sine16_44.wav", "sine24_44.m4a"} {
		t.Run(f, func(t *testing.T) {
			full, err := DecodeAll(td(f), DSDRaw, 0, nil)
			if err != nil {
				t.Fatal(err)
			}
			dec, err := Open(td(f), DSDRaw)
			if err != nil {
				t.Fatal(err)
			}
			defer dec.Close()
			fb := dec.Format().FrameBytes()
			for _, target := range []int64{12345, 1, 50000, 0} {
				if err := dec.SeekFrame(target); err != nil {
					t.Fatal(err)
				}
				got := make([]byte, 1000*fb)
				n, err := dec.Read(got)
				if err != nil {
					t.Fatal(err)
				}
				want := full.PCM[target*int64(fb) : target*int64(fb)+int64(n*fb)]
				if !bytes.Equal(got[:n*fb], want) {
					t.Fatalf("seek %d: mismatch at byte %d", target, firstDiff(got[:n*fb], want))
				}
			}
		})
	}
}

func TestRAMLimit(t *testing.T) {
	_, err := DecodeAll(td("sine24_96.flac"), DSDRaw, 1000, nil)
	if err != ErrTooLarge {
		t.Fatalf("err = %v", err)
	}
}

// writeDSF builds a minimal DSF (DSD64 stereo, LSB-first, 4096-byte blocks)
// from per-channel DSD byte streams, like a real .dsf from a SACD rip.
func writeDSF(t *testing.T, path string, ch [][]byte) {
	t.Helper()
	const block = 4096
	n := len(ch[0])
	blocks := (n + block - 1) / block
	data := make([]byte, 0, blocks*block*len(ch))
	for b := 0; b < blocks; b++ {
		for c := range ch {
			chunk := make([]byte, block)
			lo := b * block
			hi := lo + block
			if hi > n {
				hi = n
			}
			copy(chunk, ch[c][lo:hi])
			data = append(data, chunk...)
		}
	}
	var w bytes.Buffer
	le := binary.LittleEndian
	put32 := func(v uint32) { b := make([]byte, 4); le.PutUint32(b, v); w.Write(b) }
	put64 := func(v uint64) { b := make([]byte, 8); le.PutUint64(b, v); w.Write(b) }
	total := uint64(28 + 52 + 12 + len(data))
	w.WriteString("DSD ")
	put64(28)
	put64(total)
	put64(0) // no metadata
	w.WriteString("fmt ")
	put64(52)
	put32(1) // version
	put32(0) // DSD raw
	put32(2) // stereo
	put32(uint32(len(ch)))
	put32(2822400)
	put32(1) // bits per sample: 1 = LSB first
	put64(uint64(n) * 8)
	put32(block)
	put32(0)
	w.WriteString("data")
	put64(uint64(12 + len(data)))
	w.Write(data)
	if err := os.WriteFile(path, w.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

func rev8(b byte) byte {
	var r byte
	for i := 0; i < 8; i++ {
		r = r<<1 | (b>>i)&1
	}
	return r
}

func TestDSDRaw(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "t.dsf")
	n := 10000
	l := make([]byte, n)
	r := make([]byte, n)
	for i := range l {
		l[i] = byte(i * 7)
		r[i] = byte(i*13 + 1)
	}
	writeDSF(t, path, [][]byte{l, r})

	m, err := Probe(path)
	if err != nil {
		t.Fatal(err)
	}
	if !m.DSD || m.DSDRate != 2822400 || m.Channels != 2 || !m.Lossless {
		t.Fatalf("meta = %+v", m)
	}
	buf, err := DecodeAll(path, DSDRaw, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	if buf.Format.Type != ringbuf.DSD8 || !buf.Format.DSD || buf.Format.SampleRate != 2822400/8 {
		t.Fatalf("format = %+v", buf.Format)
	}
	if buf.Frames < int64(n) {
		t.Fatalf("frames = %d", buf.Frames)
	}
	// Interleaved, MSB-first: frame i = [rev(l[i]), rev(r[i])].
	for i := 0; i < n; i++ {
		if buf.PCM[2*i] != rev8(l[i]) || buf.PCM[2*i+1] != rev8(r[i]) {
			t.Fatalf("frame %d = %x %x, want %x %x", i, buf.PCM[2*i], buf.PCM[2*i+1], rev8(l[i]), rev8(r[i]))
		}
	}
	// PCM mode must at least decode something at rate/8 in float.
	pcm, err := DecodeAll(path, DSDPCM, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	if pcm.Format.Type != ringbuf.F32 || pcm.Format.DSD {
		t.Fatalf("pcm format = %+v", pcm.Format)
	}
}
