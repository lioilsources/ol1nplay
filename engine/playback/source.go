package playback

import (
	"errors"
	"sync"

	"github.com/ol1n/ol1nplay/engine/decode"
	"github.com/ol1n/ol1nplay/engine/protocol"
)

// source is one track's audio, addressable by frame. The feeder reads it in
// chunks; nothing else touches it.
type source interface {
	Format() decode.Format
	// Frames is the total length, 0 if unknown (streaming without duration).
	Frames() int64
	// ReadAt fills dst (whole frames) starting at frame pos. Returns frames
	// delivered; 0 means end of track.
	ReadAt(pos int64, dst []byte) (int, error)
	// Bytes is the resident RAM.
	Bytes() int64
	Close()
}

// ramSource is the normal case: the whole track decoded before it starts,
// so playback does zero IO.
type ramSource struct {
	buf *decode.Buffer
}

func (r *ramSource) Format() decode.Format { return r.buf.Format }
func (r *ramSource) Frames() int64         { return r.buf.Frames }
func (r *ramSource) Bytes() int64          { return r.buf.Bytes() }
func (r *ramSource) Close()                { r.buf.PCM = nil }

func (r *ramSource) ReadAt(pos int64, dst []byte) (int, error) {
	fb := int64(r.buf.Format.FrameBytes())
	if pos >= r.buf.Frames || pos < 0 {
		return 0, nil
	}
	want := int64(len(dst)) / fb
	if want > r.buf.Frames-pos {
		want = r.buf.Frames - pos
	}
	copy(dst, r.buf.PCM[pos*fb:(pos+want)*fb])
	return int(want), nil
}

// streamSource decodes on demand for tracks above the RAM limit. The ring
// buffer (a second or two) is the only read-ahead; the decoder runs on the
// feeder goroutine, never on the audio thread.
type streamSource struct {
	mu     sync.Mutex
	dec    *decode.Decoder
	pos    int64 // decoder's next frame
	frames int64
}

func newStreamSource(path string, mode decode.DSDMode) (*streamSource, error) {
	dec, err := decode.Open(path, mode)
	if err != nil {
		return nil, err
	}
	return &streamSource{dec: dec, frames: dec.Meta().Samples}, nil
}

func (s *streamSource) Format() decode.Format { return s.dec.Format() }
func (s *streamSource) Frames() int64         { return s.frames }
func (s *streamSource) Bytes() int64          { return 0 }

func (s *streamSource) ReadAt(pos int64, dst []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.dec == nil {
		return 0, errors.New("playback: source closed")
	}
	if pos != s.pos {
		if err := s.dec.SeekFrame(pos); err != nil {
			return 0, err
		}
		s.pos = pos
	}
	n, err := s.dec.Read(dst)
	s.pos += int64(n)
	return n, err
}

func (s *streamSource) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.dec != nil {
		s.dec.Close()
		s.dec = nil
	}
}

// windowSource exposes [start, end) of another source as a track of its
// own – a CUE sheet entry.
type windowSource struct {
	inner      source
	start, end int64
}

func newWindow(inner source, start, end int64) source {
	if end <= 0 || (inner.Frames() > 0 && end > inner.Frames()) {
		end = inner.Frames()
	}
	if start <= 0 && (end == 0 || end == inner.Frames()) {
		return inner
	}
	return &windowSource{inner: inner, start: start, end: end}
}

func (w *windowSource) Format() decode.Format { return w.inner.Format() }
func (w *windowSource) Frames() int64 {
	if w.end == 0 {
		return 0
	}
	return w.end - w.start
}
func (w *windowSource) Bytes() int64 { return w.inner.Bytes() }
func (w *windowSource) Close()       { w.inner.Close() }

func (w *windowSource) ReadAt(pos int64, dst []byte) (int, error) {
	fb := w.inner.Format().FrameBytes()
	if w.end > 0 {
		remain := w.end - w.start - pos
		if remain <= 0 {
			return 0, nil
		}
		if int64(len(dst)/fb) > remain {
			dst = dst[:remain*int64(fb)]
		}
	}
	return w.inner.ReadAt(w.start+pos, dst)
}

// loaded is a source paired with the track it belongs to.
type loaded struct {
	track protocol.Track
	src   source
	// inRAM reports whether the source is fully resident (for the UI's
	// "preloaded" flag and RAM accounting).
	inRAM bool
}

// loadTrack decodes a track into RAM (or opens it for streaming when it is
// larger than ramLimit). CUE windows are applied here.
func loadTrack(t protocol.Track, mode decode.DSDMode, ramLimit int64, onProgress func(int64)) (*loaded, error) {
	path := t.Path
	if t.CueFile != "" {
		path = t.CueFile
	}
	var src source
	inRAM := true
	buf, err := decode.DecodeAll(path, mode, ramLimit, onProgress)
	if err == nil {
		src = &ramSource{buf: buf}
	} else if errors.Is(err, decode.ErrTooLarge) {
		ss, err2 := newStreamSource(path, mode)
		if err2 != nil {
			return nil, err2
		}
		src = ss
		inRAM = false
	} else {
		return nil, err
	}
	if t.CueFile != "" {
		src = newWindow(src, t.CueStart, t.CueEnd)
	}
	return &loaded{track: t, src: src, inRAM: inRAM}, nil
}
