// Package playback is the engine's transport: queue, gapless track
// switching, sample-rate changes, sample-accurate A-B loop, mono flag,
// position from the device clock. One goroutine (the feeder) owns all of
// it and pushes converted frames into the backend's ring buffer; the
// backend's C callback is the only thing downstream.
package playback

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/ol1n/ol1nplay/engine/decode"
	"github.com/ol1n/ol1nplay/engine/protocol"
	"github.com/ol1n/ol1nplay/engine/ringbuf"
	"github.com/ol1n/ol1nplay/engine/sink"
)

// Options configure a Player.
type Options struct {
	Backend string // "" = preferred
	Device  string // "" = default
	// RingSeconds is the ring buffer length; the only read-ahead for
	// streamed tracks and the headroom for everything else. 1–2 s.
	RingSeconds float64
	// RAMLimit caps the decoded size of a resident track; above it the
	// track streams from disk through the ring. 0 = 512 MB.
	RAMLimit int64
	// PreloadNext decodes the following track while this one plays (gapless).
	PreloadNext bool
	// DSDMode: "native" (try native, then DoP), "dop", "pcm" (lossy, flagged).
	DSDMode string
	// WidthExtension allows 16/24 → 32-bit zero-padding when the device
	// demands it. Default true; it is bit-perfect.
	WidthExtension bool
	ABCrossfadeMs  int // 0 = off (it would be DSP)

	// Resolve turns a path into a Track (library lookup). nil = probe.
	Resolve func(path string) (protocol.Track, error)
	Log     func(protocol.LogLine)
	OnState func(protocol.State)
	OnQueue func(protocol.Queue)
	// OnPlayed records history: complete = reached the end naturally.
	OnPlayed func(track protocol.Track, complete bool)
}

// Player is the transport. All methods are safe from any goroutine; they
// execute on the feeder goroutine and return when done.
type Player struct {
	opts Options
	cmds chan func()
	quit chan struct{}
	done chan struct{}
	once sync.Once

	// Everything below is owned by the feeder goroutine.
	backend     sink.Backend
	backendName string
	deviceID    string
	stream      sink.Stream
	ring        *ringbuf.Ring
	devFormat   sink.Format
	conv        *converter
	convSt      *convState
	chunk       []byte // source frames
	devChunk    []byte // device frames
	chunkDev    int    // device frames per chunk
	outErr      string
	thread      sink.ThreadInfo
	lastUnderun int64

	q       *queue
	cur     *loaded // the track being fed (may be ahead of the device)
	pos     int64   // next source frame to feed
	state   string
	paused  bool
	mono    string // protocol.Mono*
	ab      protocol.ABLoop
	loadGen int

	preload     *loaded
	preloadPath string
	preloading  bool
	loading     bool

	// device-clock bookkeeping
	written  int64 // device frames written to the ring, ever
	dropped  int64 // device frames written but discarded by a ring reset
	timeline []tlEntry
	devCur   *loaded // what the device is playing (from the timeline)

	drain *drainState

	sleepTimer *time.Timer
	sleep      *protocol.SleepTimer
	lastEmit   time.Time
	lastHealth time.Time
	dirty      bool
	ramBytes   int64
	dsdPCM     bool // current track was converted DSD→PCM (not bit-perfect)
	failures   int
}

type tlEntry struct {
	written int64 // device frame counter when this entry started
	srcPos  int64 // source frame at that point
	l       *loaded
}

type drainState struct {
	then func()
}

// New creates the player but opens no device until the first play.
func New(opts Options) *Player {
	if opts.RingSeconds <= 0 {
		opts.RingSeconds = 1.5
	}
	if opts.RAMLimit <= 0 {
		opts.RAMLimit = 512 << 20
	}
	if opts.DSDMode == "" {
		opts.DSDMode = "native"
	}
	if opts.Log == nil {
		opts.Log = func(protocol.LogLine) {}
	}
	p := &Player{
		opts:  opts,
		cmds:  make(chan func(), 64),
		quit:  make(chan struct{}),
		done:  make(chan struct{}),
		q:     newQueue(),
		state: "stopped",
		ab:    protocol.ABLoop{A: -1, B: -1},
	}
	p.backendName = opts.Backend
	p.deviceID = opts.Device
	go p.run()
	return p
}

// Close stops playback and releases the device.
func (p *Player) Close() {
	p.once.Do(func() {
		p.do(func() { p.stopInternal(false) })
		close(p.quit)
		<-p.done
	})
}

func (p *Player) log(level, msg string, args ...any) {
	p.opts.Log(protocol.LogLine{At: time.Now().UnixMilli(), Level: level, Scope: "playback", Msg: fmt.Sprintf(msg, args...)})
}

// do runs f on the feeder goroutine and waits.
func (p *Player) do(f func()) {
	doneCh := make(chan struct{})
	select {
	case p.cmds <- func() { f(); close(doneCh) }:
		<-doneCh
	case <-p.done:
	}
}

func (p *Player) run() {
	defer close(p.done)
	tick := time.NewTicker(5 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case f := <-p.cmds:
			f()
			p.maybeEmit(true)
		case <-tick.C:
			p.feed()
			p.checkDeviceTrack()
			if time.Since(p.lastHealth) >= 250*time.Millisecond {
				p.lastHealth = time.Now()
				p.checkDeviceHealth()
			}
			p.maybeEmit(false)
		case <-p.quit:
			p.closeStream()
			return
		}
	}
}

// ---------------------------------------------------------------- device

func (p *Player) ensureBackend() error {
	if p.backend != nil && p.backend.Name() == p.backendName {
		return nil
	}
	var b sink.Backend
	if p.backendName != "" {
		var ok bool
		b, ok = sink.Get(p.backendName)
		if !ok {
			return fmt.Errorf("playback: backend %q not available", p.backendName)
		}
	} else {
		var err error
		b, err = sink.Preferred()
		if err != nil {
			return err
		}
	}
	p.closeStream()
	p.backend = b
	p.backendName = b.Name()
	return nil
}

// wantFormat picks the device format for a source format according to
// the DSD policy. The first candidate that the device accepts wins.
func (p *Player) wantFormats(f decode.Format) []sink.Format {
	if f.DSD {
		dop := sink.Format{SampleRate: f.DSDRate / 16, Channels: f.Channels, Type: ringbuf.S32}
		dop24 := dop
		dop24.Type = ringbuf.S24_3
		native := sink.Format{SampleRate: f.DSDRate / 8, Channels: f.Channels, Type: ringbuf.DSD8, DSDNative: true}
		switch p.opts.DSDMode {
		case "dop":
			return []sink.Format{dop, dop24}
		default:
			return []sink.Format{native, dop, dop24}
		}
	}
	want := sink.Format{SampleRate: f.SampleRate, Channels: f.Channels, Type: f.Type}
	out := []sink.Format{want}
	if p.opts.WidthExtension {
		switch f.Type {
		case ringbuf.S16:
			out = append(out, sink.Format{SampleRate: f.SampleRate, Channels: f.Channels, Type: ringbuf.S24_3},
				sink.Format{SampleRate: f.SampleRate, Channels: f.Channels, Type: ringbuf.S32})
		case ringbuf.S32:
			if f.BitDepth <= 24 {
				out = append(out, sink.Format{SampleRate: f.SampleRate, Channels: f.Channels, Type: ringbuf.S24_3})
			}
			if f.BitDepth <= 16 {
				out = append(out, sink.Format{SampleRate: f.SampleRate, Channels: f.Channels, Type: ringbuf.S16})
			}
		case ringbuf.F32:
			out = append(out, sink.Format{SampleRate: f.SampleRate, Channels: f.Channels, Type: ringbuf.F64})
		}
	}
	return out
}

// ensureStream opens the device for f, reusing the open stream when the
// device format already matches (gapless, same rate).
func (p *Player) ensureStream(f decode.Format) error {
	if err := p.ensureBackend(); err != nil {
		return err
	}
	cands := p.wantFormats(f)
	if p.stream != nil {
		for _, w := range cands {
			if p.devFormat.SampleRate == w.SampleRate && p.devFormat.Channels == w.Channels && p.devFormat.Type == w.Type && p.devFormat.DSDNative == w.DSDNative {
				return p.setConverter(f)
			}
		}
		p.closeStream()
	}
	var lastErr error
	for _, w := range cands {
		ringFrames := int(float64(w.SampleRate) * p.opts.RingSeconds)
		if ringFrames < 16384 {
			ringFrames = 16384
		}
		st, err := p.backend.Open(p.deviceID, w, ringFrames)
		if err != nil {
			lastErr = err
			if errors.Is(err, sink.ErrUnsupportedFormat) {
				continue
			}
			p.outErr = err.Error()
			return err
		}
		p.stream = st
		p.ring = st.Ring()
		p.devFormat = st.Format()
		p.ring.SetMonoMode(ringMono(p.mono))
		p.ring.SetMuted(p.paused)
		p.outErr = ""
		p.thread = st.ThreadInfo()
		p.written = 0
		p.dropped = 0
		p.timeline = nil
		p.lastUnderun = 0
		if err := p.setConverter(f); err != nil {
			p.closeStream()
			return err
		}
		p.log("info", "output %s/%s: %d Hz %s %dch, buffer %d frames, %s", p.backend.Name(), p.deviceID, p.devFormat.SampleRate, p.devFormat.Type, p.devFormat.Channels, st.BufferFrames(), p.conv.description)
		return nil
	}
	if lastErr == nil {
		lastErr = sink.ErrUnsupportedFormat
	}
	p.outErr = lastErr.Error()
	return lastErr
}

func (p *Player) setConverter(f decode.Format) error {
	c, err := makeConverter(f.Type, f.DSD, f.Channels, p.devFormat, f.BitDepth)
	if err != nil {
		return err
	}
	p.conv = c
	p.convSt = newConvState()
	// Chunk = a quarter of the ring: big enough to amortise the cgo write,
	// small enough that a seek or A-B change lands within ~1/4 ring.
	p.chunkDev = p.ring.Capacity() / 4
	if bf := p.stream.BufferFrames(); bf > 0 && p.chunkDev < bf {
		p.chunkDev = bf
	}
	p.devChunk = make([]byte, p.chunkDev*c.dstFB)
	p.chunk = make([]byte, p.chunkDev*c.srcPerDst*c.srcFB)
	return nil
}

func (p *Player) closeStream() {
	if p.stream == nil {
		return
	}
	_ = p.stream.Stop()
	_ = p.stream.Close()
	p.stream = nil
	p.ring = nil
	p.conv = nil
}

// ---------------------------------------------------------------- feeding

// consumed is the device's position in the written-frames counter.
func (p *Player) consumed() int64 {
	if p.ring == nil {
		return p.written
	}
	return p.ring.FramesOut() + p.dropped
}

func (p *Player) resetRing() {
	if p.ring == nil {
		return
	}
	// Everything written but not yet played is discarded, so the device's
	// counter jumps to "now" in our frame space.
	p.dropped = p.written - p.ring.FramesOut()
	p.ring.Reset()
	p.timeline = nil
}

func (p *Player) mark(l *loaded, srcPos int64) {
	p.timeline = append(p.timeline, tlEntry{written: p.written, srcPos: srcPos, l: l})
	// Drop entries older than one ring length behind the device.
	if len(p.timeline) > 64 {
		c := p.consumed() - int64(p.ring.Capacity())
		k := 0
		for k < len(p.timeline)-1 && p.timeline[k+1].written <= c {
			k++
		}
		p.timeline = p.timeline[k:]
	}
}

// devicePos returns the track the device is on and its source position.
func (p *Player) devicePos() (*loaded, int64) {
	if len(p.timeline) == 0 {
		return p.cur, p.pos
	}
	c := p.consumed()
	e := p.timeline[0]
	for _, x := range p.timeline {
		if x.written <= c {
			e = x
		} else {
			break
		}
	}
	spd := int64(1)
	if p.conv != nil {
		spd = int64(p.conv.srcPerDst)
	}
	pos := e.srcPos + (c-e.written)*spd
	if e.l != nil && e.l.src.Frames() > 0 && pos > e.l.src.Frames() {
		pos = e.l.src.Frames()
	}
	return e.l, pos
}

func (p *Player) feed() {
	if p.stream == nil || p.cur == nil || p.state == "stopped" {
		return
	}
	if p.drain != nil {
		if p.ring.Fill() == 0 {
			then := p.drain.then
			p.drain = nil
			then()
		}
		return
	}
	if p.state != "playing" && p.state != "paused" {
		return // loading: the old source is finished, the new one is not here yet
	}
	for p.ring.WriteAvailable() >= p.chunkDev {
		n, err := p.readChunk()
		if err != nil {
			p.log("error", "%s: %v", p.cur.track.Path, err)
			p.endOfTrack(false)
			return
		}
		if n == 0 {
			p.endOfTrack(true)
			return
		}
		dev := p.conv.convert(p.devChunk, p.chunk, n, p.convSt)
		if dev == 0 {
			return
		}
		p.mark(p.cur, p.pos)
		w := p.ring.Write(p.devChunk[:dev*p.conv.dstFB])
		p.written += int64(w)
		p.pos += int64(w) * int64(p.conv.srcPerDst)
		if p.cur.src.Frames() > 0 && p.pos >= p.cur.src.Frames() {
			p.endOfTrack(true)
			return
		}
	}
}

// readChunk reads the next source frames, honouring the A-B loop with
// sample accuracy: the chunk is cut exactly at B and the next read starts
// at A.
func (p *Player) readChunk() (int, error) {
	src := p.cur.src
	frames := p.chunkDev * p.conv.srcPerDst
	ab := p.ab.Active && p.devCur == p.cur
	if ab {
		if p.pos >= p.ab.B || p.pos < p.ab.A {
			p.pos = p.ab.A
		}
		if remain := p.ab.B - p.pos; int64(frames) > remain {
			frames = int(remain)
			if p.conv.srcPerDst == 2 {
				frames &^= 1
				if frames == 0 {
					frames = 2
				}
			}
		}
	}
	n, err := src.ReadAt(p.pos, p.chunk[:frames*p.conv.srcFB])
	if n == 0 && err == nil && ab {
		p.pos = p.ab.A
		n, err = src.ReadAt(p.pos, p.chunk[:frames*p.conv.srcFB])
	}
	return n, err
}

func (p *Player) endOfTrack(natural bool) {
	ended := p.cur
	nextPos, ok := p.q.peekNext()
	if !ok || !natural {
		if !natural {
			// Decode error: skip forward like a user "next" but stop after too many.
			p.failures++
			if p.failures > p.q.len() {
				p.failures = 0
				p.drainThen(func() { p.stopInternal(false) })
				return
			}
			p.drainThen(func() {
				if p.q.next(false) {
					p.startCurrent()
				} else {
					p.stopInternal(false)
				}
			})
			return
		}
		p.drainThen(func() { p.stopInternal(true) })
		return
	}
	nextTrack := p.q.tracks[p.q.idxAt(nextPos)]
	var next *loaded
	if p.preload != nil && p.preload.track.Path == nextTrack.Path {
		next = p.preload
		p.preload = nil
		p.preloadPath = ""
	} else if p.q.repeat == "one" || nextTrack.Path == ended.track.Path {
		next = ended
	}
	if next == nil {
		// Not preloaded: let the device drain, then load and start (a gap).
		p.drainThen(func() {
			p.q.next(true)
			p.startCurrent()
		})
		return
	}
	p.q.next(true)
	f := next.src.Format()
	if p.formatMatches(f) {
		// Gapless: keep feeding the same stream without a break.
		p.cur = next
		p.pos = 0
		p.kickPreload()
		return
	}
	// Sample-rate / width change: play out what is buffered, then reopen.
	p.drainThen(func() {
		p.cur = next
		p.pos = 0
		if err := p.openAndStart(); err != nil {
			p.log("error", "%v", err)
			p.stopInternal(false)
		}
	})
}

func (p *Player) formatMatches(f decode.Format) bool {
	if p.stream == nil {
		return false
	}
	for _, w := range p.wantFormats(f) {
		if p.devFormat.SampleRate == w.SampleRate && p.devFormat.Channels == w.Channels && p.devFormat.Type == w.Type && p.devFormat.DSDNative == w.DSDNative {
			return true
		}
	}
	return false
}

// drainThen lets the device play out the ring and then runs then. One
// device period of silence is appended first so the last callback reads a
// full buffer: without it the tail of every album would register as an
// underrun. Silence after the music is not DSP on the music.
func (p *Player) drainThen(then func()) {
	if p.ring != nil && p.stream != nil {
		pad := p.stream.BufferFrames()
		if pad <= 0 {
			pad = 512
		}
		zeros := make([]byte, pad*p.ring.FrameBytes())
		w := p.ring.Write(zeros)
		p.written += int64(w)
	}
	p.drain = &drainState{then: then}
}

// checkDeviceTrack notices when the device clock crosses into another
// track (gapless) and updates the user-visible current track + history.
func (p *Player) checkDeviceTrack() {
	if p.state == "stopped" || p.ring == nil {
		return
	}
	l, _ := p.devicePos()
	if l != p.devCur {
		prev := p.devCur
		p.devCur = l
		if prev != nil && p.opts.OnPlayed != nil {
			p.opts.OnPlayed(prev.track, true)
		}
		if prev != nil && prev != l && prev != p.preload && prev != p.cur {
			if _, isStream := prev.src.(*streamSource); isStream {
				prev.src.Close()
			}
		}
		p.ab = protocol.ABLoop{A: -1, B: -1}
		p.dirty = true
		if p.opts.OnQueue != nil {
			p.opts.OnQueue(p.q.snapshot())
		}
		p.failures = 0
	}
}

// ---------------------------------------------------------------- transport

// startCurrent loads the queue's current track (async) and plays it.
func (p *Player) startCurrent() {
	t, ok := p.q.current()
	if !ok {
		p.stopInternal(false)
		return
	}
	if p.preload != nil && p.preload.track.Path == t.Path {
		p.cur = p.preload
		p.preload = nil
		p.preloadPath = ""
		p.pos = 0
		if err := p.openAndStart(); err != nil {
			p.log("error", "%v", err)
			p.stopInternal(false)
		}
		return
	}
	p.loadGen++
	gen := p.loadGen
	p.state = "loading"
	p.loading = true
	p.dirty = true
	mode := p.dsdMode()
	limit := p.opts.RAMLimit
	go func() {
		l, err := loadTrack(t, mode, limit, nil)
		p.do(func() {
			if gen != p.loadGen {
				if l != nil {
					l.src.Close()
				}
				return
			}
			p.loading = false
			if err != nil {
				p.log("error", "%s: %v", t.Path, err)
				p.failures++
				if p.failures <= p.q.len() && p.q.next(false) {
					p.startCurrent()
				} else {
					p.failures = 0
					p.stopInternal(false)
				}
				return
			}
			p.cur = l
			p.pos = 0
			if err := p.openAndStart(); err != nil {
				p.log("error", "%v", err)
				p.stopInternal(false)
			}
		})
	}()
}

func (p *Player) dsdMode() decode.DSDMode {
	if p.opts.DSDMode == "pcm" {
		return decode.DSDPCM
	}
	return decode.DSDRaw
}

// openAndStart (re)opens the device for p.cur and starts feeding.
func (p *Player) openAndStart() error {
	f := p.cur.src.Format()
	err := p.ensureStream(f)
	if err != nil && f.DSD && p.opts.DSDMode != "pcm" && errors.Is(err, sink.ErrUnsupportedFormat) {
		// Device cannot take DSD in any form; the user has to opt into PCM.
		return fmt.Errorf("DSD not supported by %s/%s (set dsdMode=pcm to convert, not bit-perfect)", p.backendName, p.deviceID)
	}
	if err != nil {
		return err
	}
	p.dsdPCM = p.cur.track.DSD && !f.DSD
	p.resetRing()
	p.convSt = newConvState()
	p.ring.ResetStats()
	p.timeline = nil
	p.devCur = p.cur
	p.state = "playing"
	p.paused = false
	p.ring.SetMuted(false)
	p.drain = nil
	p.feed()
	if !p.stream.Running() {
		if err := p.stream.Start(); err != nil {
			p.outErr = err.Error()
			return err
		}
	}
	p.dirty = true
	p.kickPreload()
	if p.opts.OnQueue != nil {
		p.opts.OnQueue(p.q.snapshot())
	}
	return nil
}

// kickPreload decodes the next track in the background.
func (p *Player) kickPreload() {
	if !p.opts.PreloadNext || p.preloading {
		return
	}
	np, ok := p.q.peekNext()
	if !ok {
		return
	}
	t := p.q.tracks[p.q.idxAt(np)]
	if p.preload != nil && p.preload.track.Path == t.Path {
		return
	}
	if p.cur != nil && p.cur.track.Path == t.Path {
		return // repeat-one reuses the current source
	}
	p.preloading = true
	p.preloadPath = t.Path
	mode := p.dsdMode()
	limit := p.opts.RAMLimit
	go func() {
		l, err := loadTrack(t, mode, limit, nil)
		p.do(func() {
			p.preloading = false
			if err != nil {
				p.log("warn", "preload %s: %v", t.Path, err)
				return
			}
			if p.preloadPath != t.Path {
				l.src.Close()
				return
			}
			if p.preload != nil {
				p.preload.src.Close()
			}
			p.preload = l
			p.dirty = true
		})
	}()
}

func (p *Player) stopInternal(natural bool) {
	if p.stream != nil {
		_ = p.stream.Stop()
	}
	if p.devCur != nil && p.opts.OnPlayed != nil && p.state != "stopped" {
		p.opts.OnPlayed(p.devCur.track, natural)
	}
	p.loadGen++
	p.loading = false
	p.drain = nil
	p.resetRing()
	p.state = "stopped"
	p.paused = false
	p.pos = 0
	p.ab = protocol.ABLoop{A: -1, B: -1}
	if p.cur != nil {
		if _, isStream := p.cur.src.(*streamSource); isStream {
			p.cur.src.Close()
		}
	}
	p.cur = nil
	p.devCur = nil
	p.dirty = true
}

// ---------------------------------------------------------------- public API

// Play replaces the queue with tracks and starts at index.
func (p *Player) Play(tracks []protocol.Track, index int) error {
	if len(tracks) == 0 {
		return errors.New("playback: nothing to play")
	}
	p.do(func() {
		p.q.set(tracks, index)
		p.loadGen++
		p.drain = nil
		p.preloadPath = ""
		if p.preload != nil {
			p.preload.src.Close()
			p.preload = nil
		}
		p.state = "loading"
		p.resetRing()
		p.startCurrent()
	})
	return nil
}

// PlayPaths resolves paths and plays them.
func (p *Player) PlayPaths(paths []string, index int) error {
	tracks, err := p.resolveAll(paths)
	if err != nil {
		return err
	}
	return p.Play(tracks, index)
}

func (p *Player) resolveAll(paths []string) ([]protocol.Track, error) {
	out := make([]protocol.Track, 0, len(paths))
	for _, path := range paths {
		t, err := p.resolve(path)
		if err != nil {
			p.log("warn", "%s: %v", path, err)
			continue
		}
		out = append(out, t)
	}
	if len(out) == 0 {
		return nil, errors.New("playback: no playable tracks")
	}
	return out, nil
}

func (p *Player) resolve(path string) (protocol.Track, error) {
	if p.opts.Resolve != nil {
		if t, err := p.opts.Resolve(path); err == nil {
			return t, nil
		}
	}
	return ProbeTrack(path)
}

// ProbeTrack builds a Track from the file alone (no library).
func ProbeTrack(path string) (protocol.Track, error) {
	m, err := decode.Probe(path)
	if err != nil {
		return protocol.Track{}, err
	}
	st, _ := os.Stat(path)
	t := protocol.Track{
		Path: path, Dir: filepath.Dir(path), FileName: filepath.Base(path),
		Title: m.Title, Artist: m.Artist, AlbumArtist: m.AlbumArtist, Album: m.Album,
		TrackNo: m.TrackNo, DiscNo: m.DiscNo, Year: m.Year, Genre: m.Genre, Composer: m.Composer,
		Codec: m.Codec, Container: m.Container, SampleRate: m.SampleRate, BitDepth: m.BitDepth,
		Channels: m.Channels, Lossless: m.Lossless, DSD: m.DSD, Bitrate: m.Bitrate,
		DurationMs: m.DurationMs, Samples: m.Samples, ReplayGain: m.ReplayGainTrack,
		HasLyrics: m.Lyrics != "",
	}
	if t.Title == "" {
		t.Title = strings.TrimSuffix(t.FileName, filepath.Ext(t.FileName))
	}
	if st != nil {
		t.SizeBytes = st.Size()
		t.ModTime = st.ModTime().UnixMilli()
	}
	return t, nil
}

func (p *Player) Pause() {
	p.do(func() {
		if p.state != "playing" {
			return
		}
		p.paused = true
		p.state = "paused"
		if p.ring != nil {
			p.ring.SetMuted(true)
		}
		p.dirty = true
	})
}

func (p *Player) Resume() {
	p.do(func() {
		switch p.state {
		case "paused":
			p.paused = false
			p.state = "playing"
			if p.ring != nil {
				p.ring.SetMuted(false)
			}
			p.dirty = true
		case "stopped":
			if p.q.len() > 0 {
				if p.q.pos < 0 {
					p.q.pos = 0
				}
				p.startCurrent()
			}
		}
	})
}

func (p *Player) Toggle() {
	p.do(func() {
		switch p.state {
		case "playing":
			p.paused = true
			p.state = "paused"
			p.ring.SetMuted(true)
		case "paused":
			p.paused = false
			p.state = "playing"
			p.ring.SetMuted(false)
		case "stopped":
			if p.q.len() > 0 {
				if p.q.pos < 0 {
					p.q.pos = 0
				}
				p.startCurrent()
			}
		}
		p.dirty = true
	})
}

func (p *Player) Stop() { p.do(func() { p.stopInternal(false) }) }

func (p *Player) Next() {
	p.do(func() {
		if !p.q.next(false) {
			p.stopInternal(false)
			return
		}
		p.skipTo()
	})
}

func (p *Player) Prev() {
	p.do(func() {
		// Like every player: early in a track, previous means previous;
		// later it means restart.
		if _, pos := p.devicePos(); p.devCur != nil && pos > int64(p.srcRate())*3 {
			p.seekInternal(0)
			return
		}
		if !p.q.prev() {
			return
		}
		p.skipTo()
	})
}

func (p *Player) srcRate() int {
	if p.devCur == nil {
		return 44100
	}
	return p.devCur.src.Format().SampleRate
}

// skipTo abandons what is buffered and starts the queue's current track.
func (p *Player) skipTo() {
	if p.devCur != nil && p.opts.OnPlayed != nil {
		p.opts.OnPlayed(p.devCur.track, false)
	}
	p.loadGen++
	p.drain = nil
	wasPaused := p.state == "paused"
	if p.stream != nil {
		_ = p.stream.Stop()
	}
	p.resetRing()
	p.ab = protocol.ABLoop{A: -1, B: -1}
	if p.cur != nil && p.cur != p.preload {
		if _, isStream := p.cur.src.(*streamSource); isStream {
			p.cur.src.Close()
		}
	}
	p.cur = nil
	p.devCur = nil
	p.startCurrent()
	if wasPaused {
		p.paused = false
	}
}

// Jump plays queue entry idx.
func (p *Player) Jump(idx int) {
	p.do(func() {
		if p.q.jump(idx) {
			p.skipTo()
		}
	})
}

// SeekFrame moves the current track to frame (source frames).
func (p *Player) SeekFrame(frame int64) { p.do(func() { p.seekInternal(frame) }) }

// SeekMs moves by milliseconds.
func (p *Player) SeekMs(ms int64) {
	p.do(func() {
		if p.devCur == nil {
			return
		}
		p.seekInternal(ms * int64(p.devCur.src.Format().SampleRate) / 1000)
	})
}

func (p *Player) seekInternal(frame int64) {
	if p.devCur == nil || p.ring == nil {
		return
	}
	if p.cur != p.devCur {
		// The feeder already ran ahead into the next track; pull it back.
		if p.cur != nil && p.cur != p.preload {
			p.preload = p.cur
			p.preloadPath = p.cur.track.Path
			// The queue advanced with the feeder; step back to the device's track.
			if i := p.indexOf(p.devCur.track); i >= 0 {
				p.q.jump(i)
			}
		}
		p.cur = p.devCur
	}
	if frame < 0 {
		frame = 0
	}
	if n := p.cur.src.Frames(); n > 0 && frame >= n {
		frame = n - 1
	}
	p.drain = nil
	p.resetRing()
	p.pos = frame
	p.mark(p.cur, p.pos)
	p.feed()
	p.dirty = true
}

func (p *Player) indexOf(t protocol.Track) int {
	for i, x := range p.q.tracks {
		if x.Path == t.Path {
			return i
		}
	}
	return -1
}

// SetMono switches between stereo and the plain downmix.
func (p *Player) SetMono(on bool) {
	if on {
		p.SetMonoMode(protocol.MonoBoth)
	} else {
		p.SetMonoMode(protocol.MonoStereo)
	}
}

// SetMonoMode sets the downmix mode read by the callback.
func (p *Player) SetMonoMode(mode string) {
	mode = protocol.NormalizeMonoMode(mode)
	p.do(func() {
		p.mono = mode
		if p.ring != nil {
			p.ring.SetMonoMode(ringMono(mode))
		}
		p.dirty = true
	})
}

func ringMono(mode string) ringbuf.MonoMode {
	switch mode {
	case protocol.MonoBoth:
		return ringbuf.Mono
	case protocol.MonoLeft:
		return ringbuf.MonoLeft
	case protocol.MonoRight:
		return ringbuf.MonoRight
	}
	return ringbuf.Stereo
}

// monoNote is the conversion-path text for a mono mode ("" for stereo).
func monoNote(mode string) string {
	switch mode {
	case protocol.MonoBoth:
		return "mono downmix"
	case protocol.MonoLeft:
		return "mono downmix → left speaker only"
	case protocol.MonoRight:
		return "mono downmix → right speaker only"
	}
	return ""
}

func (p *Player) SetRepeat(mode string) {
	p.do(func() {
		switch mode {
		case "off", "one", "all":
			p.q.repeat = mode
			p.dirty = true
			p.kickPreload()
		}
	})
}

func (p *Player) SetShuffle(on bool) {
	p.do(func() {
		p.q.setShuffle(on)
		p.preloadPath = ""
		p.dirty = true
		p.kickPreload()
		if p.opts.OnQueue != nil {
			p.opts.OnQueue(p.q.snapshot())
		}
	})
}

// ---- A-B loop

// ABSetA marks A at frame (<0 = current device position).
func (p *Player) ABSetA(frame int64) {
	p.do(func() {
		if p.devCur == nil {
			return
		}
		if frame < 0 {
			_, frame = p.devicePos()
		}
		p.ab.A = frame
		p.ab.Enabled = true
		p.updateAB()
	})
}

func (p *Player) ABSetB(frame int64) {
	p.do(func() {
		if p.devCur == nil {
			return
		}
		if frame < 0 {
			_, frame = p.devicePos()
		}
		p.ab.B = frame
		p.ab.Enabled = true
		p.updateAB()
	})
}

func (p *Player) ABClear() {
	p.do(func() {
		p.ab = protocol.ABLoop{A: -1, B: -1}
		p.dirty = true
	})
}

func (p *Player) ABToggle(enabled bool) {
	p.do(func() {
		p.ab.Enabled = enabled
		p.updateAB()
	})
}

// ABNudge shifts A or B by ms (negative = earlier).
func (p *Player) ABNudge(which string, ms int64) {
	p.do(func() {
		if p.devCur == nil {
			return
		}
		d := ms * int64(p.devCur.src.Format().SampleRate) / 1000
		if which == "a" && p.ab.A >= 0 {
			p.ab.A += d
			if p.ab.A < 0 {
				p.ab.A = 0
			}
		}
		if which == "b" && p.ab.B >= 0 {
			p.ab.B += d
			if n := p.devCur.src.Frames(); n > 0 && p.ab.B > n {
				p.ab.B = n
			}
		}
		p.updateAB()
	})
}

// updateAB recomputes Active and re-feeds from the device position so the
// loop takes effect within one chunk instead of after the whole ring.
func (p *Player) updateAB() {
	wasActive := p.ab.Active
	p.ab.Active = p.ab.Enabled && p.ab.A >= 0 && p.ab.B > p.ab.A
	p.dirty = true
	if p.ab.Active == wasActive && !p.ab.Active {
		return
	}
	if p.devCur != nil && p.ring != nil && p.state != "stopped" {
		_, pos := p.devicePos()
		if p.ab.Active && (pos >= p.ab.B || pos < p.ab.A) {
			pos = p.ab.A
		}
		p.seekInternal(pos)
	}
}

// ---- queue

func (p *Player) Queue() protocol.Queue {
	var q protocol.Queue
	p.do(func() { q = p.q.snapshot() })
	return q
}

func (p *Player) QueueSet(tracks []protocol.Track, idx int) {
	p.do(func() {
		p.q.set(tracks, idx)
		p.preloadPath = ""
		p.kickPreload()
		p.notifyQueue()
	})
}

func (p *Player) QueueAdd(tracks []protocol.Track) {
	p.do(func() { p.q.add(tracks); p.kickPreload(); p.notifyQueue() })
}

func (p *Player) QueueInsert(tracks []protocol.Track) {
	p.do(func() { p.q.insert(tracks); p.preloadPath = ""; p.kickPreload(); p.notifyQueue() })
}

func (p *Player) QueueRemove(idx int) {
	p.do(func() {
		cur := p.q.currentIdx()
		p.q.remove(idx)
		if idx == cur && p.state != "stopped" {
			if p.q.len() == 0 {
				p.stopInternal(false)
			} else {
				p.skipTo()
			}
		}
		p.preloadPath = ""
		p.kickPreload()
		p.notifyQueue()
	})
}

func (p *Player) QueueMove(from, to int) {
	p.do(func() { p.q.move(from, to); p.preloadPath = ""; p.kickPreload(); p.notifyQueue() })
}

func (p *Player) QueueClear() {
	p.do(func() {
		p.stopInternal(false)
		p.q.clear()
		if p.preload != nil {
			p.preload.src.Close()
			p.preload = nil
		}
		p.preloadPath = ""
		p.notifyQueue()
	})
}

func (p *Player) notifyQueue() {
	p.dirty = true
	if p.opts.OnQueue != nil {
		p.opts.OnQueue(p.q.snapshot())
	}
}

// ---- output

// SetOutput switches backend/device; playback continues from the same
// position after the reopen.
func (p *Player) SetOutput(backend, device string) error {
	var err error
	p.do(func() {
		if backend == p.backendName && device == p.deviceID && p.stream != nil {
			return
		}
		var pos int64
		l := p.devCur
		if l != nil {
			_, pos = p.devicePos()
		}
		playing := p.state == "playing" || p.state == "paused"
		wasPaused := p.state == "paused"
		p.closeStream()
		p.backend = nil
		p.backendName = backend
		p.deviceID = device
		if err = p.ensureBackend(); err != nil {
			return
		}
		if playing && l != nil {
			p.cur = l
			p.pos = pos
			if err = p.openAndStart(); err != nil {
				p.stopInternal(false)
				return
			}
			if wasPaused {
				p.paused = true
				p.state = "paused"
				p.ring.SetMuted(true)
			}
		}
		p.dirty = true
	})
	return err
}

// Optional stream capabilities: ASIO drivers ask for a reset (control
// panel change, buffer size change), WASAPI invalidates the endpoint when
// it is unplugged or reconfigured in Sound settings.
type resetRequester interface{ ResetRequested() bool }
type invalidator interface{ DeviceInvalidated() bool }

// checkDeviceHealth answers those requests the only way the drivers
// accept: close the device and open it again, resuming where the device
// clock was.
func (p *Player) checkDeviceHealth() {
	if p.stream == nil {
		return
	}
	reason := ""
	if r, ok := p.stream.(resetRequester); ok && r.ResetRequested() {
		reason = "driver requested a reset"
	} else if i, ok := p.stream.(invalidator); ok && i.DeviceInvalidated() {
		reason = "device was invalidated"
	}
	if reason == "" {
		return
	}
	p.log("warn", "%s — reopening output", reason)
	if err := p.reopen(); err != nil {
		p.log("error", "reopen failed: %v", err)
		p.outErr = err.Error()
		p.stopInternal(false)
		p.closeStream()
	}
}

// reopen closes and reopens the current device, keeping track, position
// and pause state. Feeder goroutine only.
func (p *Player) reopen() error {
	var pos int64
	l := p.devCur
	if l != nil {
		_, pos = p.devicePos()
	}
	active := (p.state == "playing" || p.state == "paused") && l != nil
	wasPaused := p.state == "paused"
	p.closeStream()
	p.dirty = true
	if !active {
		return nil
	}
	p.cur = l
	p.pos = pos
	if err := p.openAndStart(); err != nil {
		return err
	}
	if wasPaused {
		p.paused = true
		p.state = "paused"
		p.ring.SetMuted(true)
	}
	return nil
}

// ResetOutput closes and reopens the device (after a driver reset request).
func (p *Player) ResetOutput() error {
	var err error
	p.do(func() { err = p.reopen() })
	return err
}

// Devices lists every device of every backend.
func (p *Player) Devices() []protocol.Device {
	var out []protocol.Device
	cur := p.Output()
	for _, name := range sink.Names() {
		b, _ := sink.Get(name)
		devs, err := b.Devices()
		if err != nil {
			p.log("warn", "%s: %v", name, err)
			continue
		}
		for _, d := range devs {
			out = append(out, protocol.Device{
				Backend: name, ID: d.ID, Name: d.Name, Default: d.Default,
				Selected:    name == cur.Backend && (d.ID == cur.DeviceID || (cur.DeviceID == "" && d.Default)),
				SampleRates: d.SampleRates, MaxChannels: d.MaxChannels, Note: d.Note,
			})
		}
	}
	return out
}

// Output is the output part of the state.
func (p *Player) Output() protocol.Output {
	var o protocol.Output
	p.do(func() { o = p.outputSnapshot() })
	return o
}

func (p *Player) outputSnapshot() protocol.Output {
	o := protocol.Output{Backend: p.backendName, DeviceID: p.deviceID, Status: "closed", Error: p.outErr}
	if p.backend != nil {
		o.Backend = p.backend.Name()
		if devs, err := p.backend.Devices(); err == nil {
			for _, d := range devs {
				if d.ID == p.deviceID || (p.deviceID == "" && d.Default) {
					o.Device = d.Name
					if p.deviceID == "" {
						o.DeviceID = d.ID
					}
				}
			}
		}
	}
	if p.outErr != "" {
		o.Status = "error"
	}
	if p.stream != nil {
		o.Status = "open"
		if p.stream.Running() {
			o.Status = "running"
		}
		f := p.devFormat
		o.Format = protocol.Format{SampleRate: f.SampleRate, Channels: f.Channels, SampleFormat: f.Type.String(), BitDepth: f.Type.Bits()}
		if f.ValidBits > 0 {
			o.Format.BitDepth = f.ValidBits
		}
		if f.Type == ringbuf.DSD8 {
			o.Format.SampleFormat = "dsd"
			o.Format.DSDRate = f.SampleRate * 8
			o.Format.BitDepth = 1
			o.NativeDSD = true
		}
		if p.conv != nil && p.conv.srcPerDst == 2 {
			o.DoP = true
			o.Format.SampleFormat = "dop"
		}
		o.BufferFrames = p.stream.BufferFrames()
		o.LatencyMs = p.stream.LatencyMs()
		o.Underruns = p.ring.Stats().Underruns
		o.Exclusive = true
		if p.conv != nil {
			note := monoNote(p.mono)
			o.BitPerfect = p.conv.bitPerfect && note == "" && !p.dsdPCM
			o.Conversion = p.conv.description
			if note != "" {
				o.Conversion += "; " + note
			}
			if p.dsdPCM {
				o.Conversion = "DSD → PCM (FFmpeg), not bit-perfect"
			}
		}
	}
	return o
}

// Stats are the hot counters.
func (p *Player) Stats() protocol.OutputStats {
	var s protocol.OutputStats
	p.do(func() {
		s.ThreadPriority = p.thread.Priority
		s.CPUCore = p.thread.Core
		if p.ring == nil {
			return
		}
		st := p.ring.Stats()
		s.Underruns = st.Underruns
		s.CallbackCount = st.Callbacks
		s.RingFillPct = p.ring.FillPct()
		s.MaxCallbackUs = st.MaxCallbackNs / 1000
		s.LastUnderrunAt = st.LastUnderrunNs / 1e6
	})
	return s
}

// Waveform is the loudness overview of a track that is loaded right now
// (playing, being fed, or preloaded); nil for anything else.
func (p *Player) Waveform(path string) *protocol.Waveform {
	var w *protocol.Waveform
	p.do(func() {
		for _, l := range []*loaded{p.devCur, p.cur, p.preload} {
			if l != nil && l.wave != nil && l.wave.Path == path {
				w = l.wave
				return
			}
		}
	})
	return w
}

// ---- sleep timer

func (p *Player) SleepSet(minutes int) {
	p.do(func() {
		if p.sleepTimer != nil {
			p.sleepTimer.Stop()
		}
		if minutes <= 0 {
			p.sleep = nil
			p.sleepTimer = nil
			p.dirty = true
			return
		}
		end := time.Now().Add(time.Duration(minutes) * time.Minute)
		p.sleep = &protocol.SleepTimer{EndsAt: end.UnixMilli(), Minutes: minutes}
		p.sleepTimer = time.AfterFunc(time.Until(end), func() {
			p.do(func() {
				p.sleep = nil
				p.sleepTimer = nil
				p.stopInternal(false)
			})
		})
		p.dirty = true
	})
}

func (p *Player) SleepClear() { p.SleepSet(0) }

// ---- state

// State is the full snapshot.
func (p *Player) State() protocol.State {
	var s protocol.State
	p.do(func() { s = p.stateSnapshot() })
	return s
}

func (p *Player) stateSnapshot() protocol.State {
	s := protocol.State{
		Playback: p.state, Mono: monoNote(p.mono) != "", MonoMode: protocol.NormalizeMonoMode(p.mono), AB: p.ab, Repeat: p.q.repeat, Shuffle: p.q.shuffle,
		QueueIndex: p.q.currentIdx(), QueueLen: p.q.len(), Gain: "0 dB", Sleep: p.sleep,
		Output: p.outputSnapshot(),
	}
	if p.state == "loading" {
		if t, ok := p.q.current(); ok {
			tt := t
			s.Track = &tt
			s.Duration = t.Samples
			s.DurationMs = t.DurationMs
		}
	}
	l, pos := p.devicePos()
	if l != nil && p.state != "stopped" {
		t := l.track
		s.Track = &t
		f := l.src.Format()
		s.Source = protocol.Format{SampleRate: f.SampleRate, Channels: f.Channels, BitDepth: f.BitDepth, SampleFormat: f.SampleFormatName(), DSDRate: f.DSDRate}
		if f.DSD {
			s.Source.SampleRate = f.DSDRate
		}
		s.Position = pos
		s.Duration = l.src.Frames()
		if s.Duration == 0 {
			s.Duration = t.Samples
		}
		rate := int64(f.SampleRate)
		if rate > 0 {
			s.PositionMs = pos * 1000 / rate
			s.DurationMs = s.Duration * 1000 / rate
		}
		if s.DurationMs == 0 {
			s.DurationMs = t.DurationMs
		}
		if rate > 0 {
			s.AB.AMs = s.AB.A * 1000 / rate
			s.AB.BMs = s.AB.B * 1000 / rate
		}
		s.RAMBytes = l.src.Bytes()
		if l.wave != nil {
			s.Waveform = l.wave.Path
		}
	}
	if p.preload != nil {
		t := p.preload.track
		s.NextTrack = &t
		s.Preloaded = p.preload.inRAM
		s.RAMBytes += p.preload.src.Bytes()
	}
	if p.cur != nil && p.cur != l && p.cur != p.preload {
		s.RAMBytes += p.cur.src.Bytes()
	}
	return s
}

// maybeEmit pushes a state event: at once when something changed, every
// 250 ms while the clock runs, and whenever the underrun counter moves.
func (p *Player) maybeEmit(force bool) {
	if p.opts.OnState == nil {
		return
	}
	now := time.Now()
	if p.ring != nil {
		if u := p.ring.Stats().Underruns; u != p.lastUnderun {
			p.lastUnderun = u
			p.dirty = true
		}
	}
	if !p.dirty && !(p.state == "playing" && now.Sub(p.lastEmit) >= 250*time.Millisecond) {
		return
	}
	if !force && p.dirty && now.Sub(p.lastEmit) < 30*time.Millisecond {
		return
	}
	p.dirty = false
	p.lastEmit = now
	p.opts.OnState(p.stateSnapshot())
}

// NumCPU is exported for the sysmode default core choice.
func NumCPU() int { return runtime.NumCPU() }
