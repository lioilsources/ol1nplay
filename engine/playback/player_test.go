package playback

import (
	"bytes"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/ol1n/ol1nplay/engine/decode"
	"github.com/ol1n/ol1nplay/engine/protocol"
	"github.com/ol1n/ol1nplay/engine/ringbuf"
	"github.com/ol1n/ol1nplay/engine/sink"
	"github.com/ol1n/ol1nplay/engine/sink/null"
)

func td(name string) string { return filepath.Join("..", "testdata", name) }

type capture struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (c *capture) Write(b []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.Write(b)
}

func (c *capture) Bytes() []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]byte(nil), c.buf.Bytes()...)
}

func newTestPlayer(t *testing.T, cap *capture) *Player {
	t.Helper()
	b, _ := sink.Get("null")
	nb := b.(*null.Backend)
	nb.SetFast(true)
	nb.SetCapture(cap)
	p := New(Options{Backend: "null", RingSeconds: 0.5, PreloadNext: true, WidthExtension: true,
		Log:     func(l protocol.LogLine) { t.Logf("[%s] %s", l.Level, l.Msg) },
		OnState: func(protocol.State) {}})
	t.Cleanup(p.Close)
	return p
}

func waitStopped(t *testing.T, p *Player, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if p.State().Playback == "stopped" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("player did not stop: %+v", p.State().Playback)
}

func mustTrack(t *testing.T, name string) protocol.Track {
	t.Helper()
	tr, err := ProbeTrack(td(name))
	if err != nil {
		t.Fatal(err)
	}
	return tr
}

func TestEndToEndBitPerfect(t *testing.T) {
	cap := &capture{}
	p := newTestPlayer(t, cap)
	ref, err := decode.DecodeAll(td("sine24_96.flac"), decode.DSDRaw, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := p.Play([]protocol.Track{mustTrack(t, "sine24_96.flac")}, 0); err != nil {
		t.Fatal(err)
	}
	waitStopped(t, p, 10*time.Second)
	got := cap.Bytes()
	if !equalWithPad(got, ref.PCM) {
		t.Fatalf("device received %d bytes, file has %d; first diff %d", len(got), len(ref.PCM), firstDiff(got, ref.PCM))
	}
	o := p.Output()
	if o.Underruns != 0 {
		t.Fatalf("underruns = %d", o.Underruns)
	}
}

func TestGaplessSameFormat(t *testing.T) {
	cap := &capture{}
	p := newTestPlayer(t, cap)
	a, _ := decode.DecodeAll(td("sine16_44.flac"), decode.DSDRaw, 0, nil)
	b, _ := decode.DecodeAll(td("sine16_44.wav"), decode.DSDRaw, 0, nil)
	want := append(append([]byte(nil), a.PCM...), b.PCM...)
	// Real-time clock: gapless relies on the next track being preloaded
	// while this one plays, which a 1.5 s track in fast mode never allows.
	nb, _ := sink.Get("null")
	nb.(*null.Backend).SetFast(false)
	if err := p.Play([]protocol.Track{mustTrack(t, "sine16_44.flac"), mustTrack(t, "sine16_44.wav")}, 0); err != nil {
		t.Fatal(err)
	}
	waitStopped(t, p, 15*time.Second)
	got := cap.Bytes()
	if !equalWithPad(got, want) {
		t.Fatalf("gapless stream differs: got %d want %d, first diff %d", len(got), len(want), firstDiff(got, want))
	}
}

func TestSampleRateChangeBetweenTracks(t *testing.T) {
	cap := &capture{}
	p := newTestPlayer(t, cap)
	a, _ := decode.DecodeAll(td("sine16_44.flac"), decode.DSDRaw, 0, nil)
	b, _ := decode.DecodeAll(td("sine24_96.flac"), decode.DSDRaw, 0, nil)
	want := append(append([]byte(nil), a.PCM...), b.PCM...)
	if err := p.Play([]protocol.Track{mustTrack(t, "sine16_44.flac"), mustTrack(t, "sine24_96.flac")}, 0); err != nil {
		t.Fatal(err)
	}
	// While the first plays, the device must run at 44.1k/16; afterwards 96k/32.
	deadline := time.Now().Add(5 * time.Second)
	saw44 := false
	for time.Now().Before(deadline) {
		s := p.State()
		if s.Playback == "playing" && s.Output.Format.SampleRate == 44100 && s.Output.Format.SampleFormat == "s16" {
			saw44 = true
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !saw44 {
		t.Fatalf("never saw 44.1k/16 output: %+v", p.State().Output)
	}
	waitStopped(t, p, 15*time.Second)
	// Across a rate change the device drains with a silence pad between the
	// two formats; both tracks must still arrive intact and in order.
	got := cap.Bytes()
	if !bytes.HasPrefix(got, a.PCM) {
		t.Fatalf("first track corrupted at %d", firstDiff(got, a.PCM))
	}
	rest := got[len(a.PCM):]
	i := bytes.Index(rest, b.PCM[:4096])
	if i < 0 || !equalWithPad(rest[i:], b.PCM) {
		t.Fatalf("second track not found intact after rate change (got %d want %d)", len(got), len(want))
	}
	for _, z := range rest[:i] {
		if z != 0 {
			t.Fatal("non-silence between tracks of different rate")
		}
	}
}

func TestABLoopSampleExact(t *testing.T) {
	cap := &capture{}
	p := newTestPlayer(t, cap)
	ref, _ := decode.DecodeAll(td("sine24_96.flac"), decode.DSDRaw, 0, nil)
	fb := ref.Format.FrameBytes()
	// Loop [3000, 5000) set before anything plays: the feeder must cut at B
	// exactly and resume at A exactly.
	tr := mustTrack(t, "sine24_96.flac")
	b, _ := sink.Get("null")
	b.(*null.Backend).SetFast(false) // real-time so we can observe mid-track
	if err := p.Play([]protocol.Track{tr}, 0); err != nil {
		t.Fatal(err)
	}
	// Wait for playback to start, then set A/B.
	for i := 0; i < 500 && p.State().Playback != "playing"; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	p.ABSetA(3000)
	p.ABSetB(5000)
	time.Sleep(600 * time.Millisecond)
	s := p.State()
	if !s.AB.Active || s.AB.A != 3000 || s.AB.B != 5000 {
		t.Fatalf("ab = %+v", s.AB)
	}
	if s.Position < 3000 || s.Position >= 5000 {
		t.Fatalf("position %d outside loop", s.Position)
	}
	p.Stop()
	got := cap.Bytes()
	// After the loop engaged the stream is a repetition of ref[3000:5000).
	// Find the first occurrence of frame 3000 followed by 2000 frames then
	// frame 3000 again.
	seg := ref.PCM[3000*fb : 5000*fb]
	idx := bytes.Index(got, seg)
	if idx < 0 {
		t.Fatal("loop segment not found in output")
	}
	if idx%fb != 0 {
		t.Fatalf("segment not frame aligned: %d", idx)
	}
	// The bytes right after the segment must be the segment again (loop),
	// unless the capture ended.
	next := got[idx+len(seg):]
	if len(next) >= len(seg) && !bytes.Equal(next[:len(seg)], seg) {
		t.Fatalf("after B the stream did not restart at A (first diff %d frames)", firstDiff(next[:len(seg)], seg)/fb)
	}
	if len(next) < len(seg) {
		t.Skip("capture ended before a second pass; loop boundary not observable")
	}
}

func TestPauseIsSilentAndHoldsPosition(t *testing.T) {
	cap := &capture{}
	p := newTestPlayer(t, cap)
	b, _ := sink.Get("null")
	b.(*null.Backend).SetFast(false)
	if err := p.Play([]protocol.Track{mustTrack(t, "sine24_96.flac")}, 0); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 500 && p.State().Playback != "playing"; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(200 * time.Millisecond)
	p.Pause()
	s1 := p.State()
	time.Sleep(200 * time.Millisecond)
	s2 := p.State()
	if s1.Playback != "paused" || s2.Position != s1.Position {
		t.Fatalf("paused position moved: %d → %d (%s)", s1.Position, s2.Position, s2.Playback)
	}
	if s2.Output.Underruns != 0 {
		t.Fatalf("pause counted as underruns: %d", s2.Output.Underruns)
	}
	p.Resume()
	time.Sleep(200 * time.Millisecond)
	s3 := p.State()
	if s3.Playback != "playing" || s3.Position <= s2.Position {
		t.Fatalf("did not resume: %+v", s3.Playback)
	}
	p.Stop()
}

func TestSeekAndMono(t *testing.T) {
	cap := &capture{}
	p := newTestPlayer(t, cap)
	b, _ := sink.Get("null")
	b.(*null.Backend).SetFast(false)
	if err := p.Play([]protocol.Track{mustTrack(t, "sine24_96.flac")}, 0); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 500 && p.State().Playback != "playing"; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	p.SeekMs(1000)
	time.Sleep(100 * time.Millisecond)
	s := p.State()
	if s.PositionMs < 1000 || s.PositionMs > 1400 {
		t.Fatalf("after seek position = %d ms", s.PositionMs)
	}
	p.SetMono(true)
	s = p.State()
	if !s.Mono || s.Output.BitPerfect {
		t.Fatalf("mono state: mono=%v bitPerfect=%v", s.Mono, s.Output.BitPerfect)
	}
	for _, mode := range []string{protocol.MonoLeft, protocol.MonoRight} {
		p.SetMonoMode(mode)
		if s = p.State(); !s.Mono || s.MonoMode != mode || s.Output.BitPerfect {
			t.Fatalf("mode %s: mono=%v monoMode=%q bitPerfect=%v", mode, s.Mono, s.MonoMode, s.Output.BitPerfect)
		}
	}
	p.SetMono(false)
	if s = p.State(); !s.Output.BitPerfect || s.MonoMode != protocol.MonoStereo {
		t.Fatalf("bit-perfect should be back: %+v", s.Output)
	}
	p.Stop()
}

func TestQueueOps(t *testing.T) {
	q := newQueue()
	tr := func(n string) protocol.Track { return protocol.Track{Path: n} }
	q.set([]protocol.Track{tr("a"), tr("b"), tr("c"), tr("d")}, 1)
	if c, _ := q.current(); c.Path != "b" {
		t.Fatal("current")
	}
	q.move(3, 0)
	if c, _ := q.current(); c.Path != "b" || q.tracks[0].Path != "d" {
		t.Fatalf("move: %+v", q.snapshot())
	}
	q.remove(0)
	if c, _ := q.current(); c.Path != "b" || q.currentIdx() != 1 {
		t.Fatalf("remove: %+v", q.snapshot())
	}
	q.repeat = "all"
	q.next(true)
	q.next(true)
	if c, _ := q.current(); c.Path != "a" {
		t.Fatalf("wrap: %+v", q.snapshot())
	}
	q.setShuffle(true)
	if c, _ := q.current(); c.Path != "a" || q.order[0] != 0 {
		t.Fatalf("shuffle keeps current first: %+v order=%v", q.snapshot(), q.order)
	}
	q.setShuffle(false)
	if q.order != nil || q.currentIdx() != 0 {
		t.Fatal("unshuffle")
	}
}

func TestStreamingSourceAboveRAMLimit(t *testing.T) {
	cap := &capture{}
	b, _ := sink.Get("null")
	nb := b.(*null.Backend)
	nb.SetFast(true)
	nb.SetCapture(cap)
	p := New(Options{Backend: "null", RingSeconds: 0.5, RAMLimit: 1000, Log: func(l protocol.LogLine) { t.Logf("%s", l.Msg) }})
	defer p.Close()
	ref, _ := decode.DecodeAll(td("sine24_96.flac"), decode.DSDRaw, 0, nil)
	if err := p.Play([]protocol.Track{mustTrack(t, "sine24_96.flac")}, 0); err != nil {
		t.Fatal(err)
	}
	waitStopped(t, p, 15*time.Second)
	if got := cap.Bytes(); !equalWithPad(got, ref.PCM) {
		t.Fatalf("streamed output differs: got %d want %d, first diff %d", len(got), len(ref.PCM), firstDiff(got, ref.PCM))
	}
}

func TestDoPConversion(t *testing.T) {
	// Two DSD8 frames per channel become one 32-bit DoP word with alternating markers.
	c, err := makeConverter(ringbuf.DSD8, true, 2, sink.Format{SampleRate: 176400, Channels: 2, Type: ringbuf.S32}, 1)
	if err != nil {
		t.Fatal(err)
	}
	src := []byte{0x11, 0xAA, 0x22, 0xBB, 0x33, 0xCC, 0x44, 0xDD} // 4 frames × 2 ch
	dst := make([]byte, 2*2*4)
	st := newConvState()
	n := c.convert(dst, src, 4, st)
	if n != 2 {
		t.Fatalf("n = %d", n)
	}
	want := []byte{
		0x00, 0x22, 0x11, 0x05, 0x00, 0xBB, 0xAA, 0x05, // frame 0: marker 05
		0x00, 0x44, 0x33, 0xFA, 0x00, 0xDD, 0xCC, 0xFA, // frame 1: marker FA
	}
	if !bytes.Equal(dst, want) {
		t.Fatalf("dop = % x\nwant  % x", dst, want)
	}
	if !c.bitPerfect {
		t.Fatal("DoP is bit-perfect by definition")
	}
}

func TestWidening(t *testing.T) {
	c, err := makeConverter(ringbuf.S16, false, 2, sink.Format{SampleRate: 44100, Channels: 2, Type: ringbuf.S32}, 16)
	if err != nil {
		t.Fatal(err)
	}
	src := []byte{0x34, 0x12, 0xCD, 0xAB}
	dst := make([]byte, 8)
	c.convert(dst, src, 1, nil)
	if !bytes.Equal(dst, []byte{0, 0, 0x34, 0x12, 0, 0, 0xCD, 0xAB}) {
		t.Fatalf("% x", dst)
	}
	c, err = makeConverter(ringbuf.S32, false, 1, sink.Format{SampleRate: 44100, Channels: 1, Type: ringbuf.S24_3}, 24)
	if err != nil {
		t.Fatal(err)
	}
	dst = make([]byte, 3)
	c.convert(dst, []byte{0x00, 0x56, 0x34, 0x12}, 1, nil)
	if !bytes.Equal(dst, []byte{0x56, 0x34, 0x12}) {
		t.Fatalf("% x", dst)
	}
	if _, err := makeConverter(ringbuf.S32, false, 1, sink.Format{Type: ringbuf.S24_3}, 32); err == nil {
		t.Fatal("32-bit into 24-bit must be refused")
	}
	if _, err := makeConverter(ringbuf.F32, false, 2, sink.Format{Type: ringbuf.S32}, 0); err == nil {
		t.Fatal("float → int must be refused (it would dither or clip)")
	}
}

// equalWithPad accepts got == want followed only by zero frames (the drain
// padding the player appends so the last device callback is full).
func equalWithPad(got, want []byte) bool {
	if len(got) < len(want) || !bytes.Equal(got[:len(want)], want) {
		return false
	}
	for _, b := range got[len(want):] {
		if b != 0 {
			return false
		}
	}
	return true
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

func TestMain(m *testing.M) {
	if _, err := os.Stat(td("sine24_96.flac")); err != nil {
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func TestWaveform(t *testing.T) {
	cap := &capture{}
	p := newTestPlayer(t, cap)
	b, _ := sink.Get("null")
	b.(*null.Backend).SetFast(false)
	tr := mustTrack(t, "sine24_96.flac")
	if err := p.Play([]protocol.Track{tr}, 0); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 500 && p.State().Playback != "playing"; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	if got := p.State().Waveform; got != tr.Path {
		t.Fatalf("state.waveform = %q, want the playing track", got)
	}
	w := p.Waveform(tr.Path)
	if w == nil || w.Bins != len(w.Peak) || w.Bins != len(w.RMS) || w.Bins == 0 {
		t.Fatalf("waveform = %+v", w)
	}
	// A steady sine: every bin has signal, and RMS sits below the peak.
	mid := w.Bins / 2
	if w.Peak[mid] == 0 || w.RMS[mid] == 0 || w.RMS[mid] > w.Peak[mid] {
		t.Fatalf("bin %d: peak=%d rms=%d", mid, w.Peak[mid], w.RMS[mid])
	}
	if p.Waveform("nope.flac") != nil {
		t.Fatal("waveform for a track that is not loaded")
	}
	p.Stop()
}
