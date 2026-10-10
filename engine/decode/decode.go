// Package decode turns an audio file into PCM (or raw DSD) frames in the
// codec's native sample format, via FFmpeg. It never resamples, dithers or
// changes bit depth: a 24-bit FLAC comes out as int32 with the 24 bits
// MSB-justified and eight zero LSBs, exactly as libavcodec produces it.
package decode

/*
#cgo CFLAGS: -I${SRCDIR}/../native -std=c11
#cgo !windows pkg-config: libavformat libavcodec libavutil
#cgo windows CFLAGS: -I${SRCDIR}/../ffmpeg-win/include
#cgo windows LDFLAGS: -L${SRCDIR}/../ffmpeg-win/lib -lavformat -lavcodec -lavutil
#include <stdlib.h>
#include <libavutil/log.h>
#include "ffdec.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"unsafe"

	"github.com/ol1n/ol1nplay/engine/meta"
	"github.com/ol1n/ol1nplay/engine/ringbuf"
)

func init() {
	// libav is chatty on stderr; the engine has its own log channel.
	C.av_log_set_level(C.AV_LOG_ERROR)
}

// Version is the linked FFmpeg's version string.
func Version() string { return C.GoString(C.ff_version_string()) }

// DSDMode selects how .dsf/.dff files are read.
type DSDMode int

const (
	// DSDRaw hands out DSD8 frames (one byte = 8 DSD bits, MSB first, per
	// channel) for native DSD or DoP output. Bit-perfect.
	DSDRaw DSDMode = C.FF_DSD_RAW
	// DSDPCM lets FFmpeg convert to float PCM. Not bit-perfect; only for
	// devices that cannot take DSD at all.
	DSDPCM DSDMode = C.FF_DSD_PCM
)

// Format is the decoded stream's native format.
type Format struct {
	SampleRate int // PCM Hz; for DSD8: DSD rate / 8
	Channels   int
	Type       ringbuf.SampleType
	BitDepth   int // meaningful bits (24 inside S32 etc.), 0 for float, 1 for DSD
	DSD        bool
	DSDRate    int
}

// FrameBytes is bytes per interleaved frame.
func (f Format) FrameBytes() int { return f.Type.Bytes() * f.Channels }

// String renders "FLAC 24/96000 2ch"-style text.
func (f Format) String() string {
	if f.DSD {
		return fmt.Sprintf("DSD%d %dch", f.DSDRate/44100, f.Channels)
	}
	if f.Type.IsFloat() {
		return fmt.Sprintf("%s/%d %dch", f.Type, f.SampleRate, f.Channels)
	}
	return fmt.Sprintf("%d/%d %dch (%s)", f.BitDepth, f.SampleRate, f.Channels, f.Type)
}

// SampleFormatName is the protocol's sampleFormat string.
func (f Format) SampleFormatName() string {
	if f.DSD {
		return "dsd"
	}
	switch {
	case f.Type == ringbuf.S32 && f.BitDepth == 24:
		return "s24"
	default:
		return f.Type.String()
	}
}

func infoToMeta(ci *C.ff_info) *meta.Meta {
	m := &meta.Meta{
		Title:       C.GoString(&ci.title[0]),
		Artist:      C.GoString(&ci.artist[0]),
		AlbumArtist: C.GoString(&ci.album_artist[0]),
		Album:       C.GoString(&ci.album[0]),
		Genre:       C.GoString(&ci.genre[0]),
		Composer:    C.GoString(&ci.composer[0]),
		Comment:     C.GoString(&ci.comment[0]),
		Codec:       C.GoString(&ci.codec[0]),
		Container:   C.GoString(&ci.container[0]),
		SampleRate:  int(ci.sample_rate),
		BitDepth:    int(ci.bit_depth),
		Channels:    int(ci.channels),
		Bitrate:     int(ci.bitrate_kbps),
		Lossless:    ci.lossless != 0,
		DSD:         ci.dsd != 0,
		DSDRate:     int(ci.dsd_rate),
		DurationMs:  int64(ci.duration_ms),
		Samples:     int64(ci.nb_frames),
	}
	m.TrackNo, _ = firstInt(C.GoString(&ci.track[0]))
	m.DiscNo, _ = firstInt(C.GoString(&ci.disc[0]))
	m.Year, _ = firstInt(C.GoString(&ci.date[0]))
	if rg := strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(C.GoString(&ci.replaygain_track[0])), "dB")); rg != "" {
		m.ReplayGainTrack, _ = strconv.ParseFloat(strings.TrimSpace(rg), 64)
	}
	if ci.lyrics != nil {
		m.Lyrics = C.GoString(ci.lyrics)
	}
	if ci.picture != nil && ci.picture_len > 0 {
		m.Picture = C.GoBytes(unsafe.Pointer(ci.picture), ci.picture_len)
		m.PictureMime = C.GoString(&ci.picture_mime[0])
	}
	if m.Lossless && m.Bitrate > 0 && !m.DSD {
		// Lossless bitrate is a file-size artefact; the UI shows depth/rate instead.
		m.Bitrate = 0
	}
	if m.DSD {
		// For DSD the probe's "sample rate" is bytes per second; the protocol
		// carries the DSD rate separately and SampleRate as the DoP PCM rate
		// would mislead, so report the DSD byte rate ×8 / 16 (= DoP rate).
		m.SampleRate = m.DSDRate / 16
		m.BitDepth = 1
	}
	return m
}

// firstInt parses "3/12" or "03" → 3.
func firstInt(s string) (int, bool) {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "/-"); i > 0 {
		s = s[:i]
	}
	if len(s) > 4 && s[4] == '-' { // "2019-05-01"
		s = s[:4]
	}
	n, err := strconv.Atoi(strings.TrimSpace(s))
	return n, err == nil
}

func infoFormat(ci *C.ff_info) Format {
	return Format{
		SampleRate: int(ci.sample_rate),
		Channels:   int(ci.channels),
		Type:       ringbuf.SampleType(ci.rb_type),
		BitDepth:   int(ci.bit_depth),
		DSD:        ci.dsd != 0,
		DSDRate:    int(ci.dsd_rate),
	}
}

// Prober implements meta.Prober.
type Prober struct{}

// Probe reads tags and format without decoding audio.
func (Prober) Probe(path string) (*meta.Meta, error) { return Probe(path) }

// Probe reads tags and format without decoding audio.
func Probe(path string) (*meta.Meta, error) {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	var ci C.ff_info
	var cerr [C.FF_ERR_LEN]C.char
	if C.ff_probe(cpath, &ci, &cerr[0]) != 0 {
		return nil, fmt.Errorf("decode: %s: %s", path, C.GoString(&cerr[0]))
	}
	defer C.ff_info_free(&ci)
	return infoToMeta(&ci), nil
}

// Decoder is an open file.
type Decoder struct {
	d      *C.ff_dec
	format Format
	meta   *meta.Meta
	path   string
}

// Open prepares path for decoding.
func Open(path string, mode DSDMode) (*Decoder, error) {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	var ci C.ff_info
	var cerr [C.FF_ERR_LEN]C.char
	d := C.ff_open(cpath, C.int(mode), &ci, &cerr[0])
	if d == nil {
		return nil, fmt.Errorf("decode: %s: %s", path, C.GoString(&cerr[0]))
	}
	defer C.ff_info_free(&ci)
	dec := &Decoder{d: d, format: infoFormat(&ci), meta: infoToMeta(&ci), path: path}
	if ci.dsd != 0 && mode == DSDPCM {
		dec.format.DSD = false
		dec.format.DSDRate = 0
	}
	return dec, nil
}

// Format is the native output format.
func (d *Decoder) Format() Format { return d.format }

// Meta is what the probe saw.
func (d *Decoder) Meta() *meta.Meta { return d.meta }

// Read fills dst with whole frames; returns frames read, 0 at EOF.
func (d *Decoder) Read(dst []byte) (int, error) {
	fb := d.format.FrameBytes()
	max := len(dst) / fb
	if max == 0 {
		return 0, errors.New("decode: buffer smaller than one frame")
	}
	var cerr [C.FF_ERR_LEN]C.char
	n := C.ff_read(d.d, (*C.uint8_t)(unsafe.Pointer(&dst[0])), C.int(max), &cerr[0])
	if n < 0 {
		return 0, fmt.Errorf("decode: %s: %s", d.path, C.GoString(&cerr[0]))
	}
	return int(n), nil
}

// SeekFrame positions the decoder at frame (exact; the C side skips to it).
func (d *Decoder) SeekFrame(frame int64) error {
	var cerr [C.FF_ERR_LEN]C.char
	if C.ff_seek(d.d, C.int64_t(frame), &cerr[0]) < 0 {
		return fmt.Errorf("decode: %s: %s", d.path, C.GoString(&cerr[0]))
	}
	return nil
}

// Close releases the decoder.
func (d *Decoder) Close() {
	if d.d != nil {
		C.ff_close(d.d)
		d.d = nil
	}
}

// Buffer is a whole track in RAM.
type Buffer struct {
	Format Format
	PCM    []byte
	Frames int64
	Meta   *meta.Meta
}

// Bytes is the resident size.
func (b *Buffer) Bytes() int64 { return int64(len(b.PCM)) }

// DecodeAll reads the entire file into RAM. onProgress (optional) receives
// frames decoded so far. maxBytes > 0 aborts with ErrTooLarge once the PCM
// would exceed it, so the caller can fall back to streaming.
func DecodeAll(path string, mode DSDMode, maxBytes int64, onProgress func(frames int64)) (*Buffer, error) {
	dec, err := Open(path, mode)
	if err != nil {
		return nil, err
	}
	defer dec.Close()
	f := dec.Format()
	fb := f.FrameBytes()
	est := dec.meta.Samples
	if f.DSD {
		est = dec.meta.Samples // bytes per channel; probe reports frames in byte units already
	}
	if maxBytes > 0 && est*int64(fb) > maxBytes {
		return nil, ErrTooLarge
	}
	cap0 := est*int64(fb) + int64(fb)*4096
	if cap0 < 1<<20 {
		cap0 = 1 << 20
	}
	pcm := make([]byte, 0, cap0)
	chunk := make([]byte, 65536*fb)
	var frames int64
	for {
		n, err := dec.Read(chunk)
		if err != nil {
			return nil, err
		}
		if n == 0 {
			break
		}
		pcm = append(pcm, chunk[:n*fb]...)
		frames += int64(n)
		if maxBytes > 0 && int64(len(pcm)) > maxBytes {
			return nil, ErrTooLarge
		}
		if onProgress != nil {
			onProgress(frames)
		}
	}
	return &Buffer{Format: f, PCM: pcm, Frames: frames, Meta: dec.meta}, nil
}

// ErrTooLarge is returned by DecodeAll when the RAM limit would be exceeded.
var ErrTooLarge = errors.New("decode: track exceeds RAM limit")
