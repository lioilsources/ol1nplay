// Package cue parses CUE sheets into per-track sample offsets.
//
// A CUE sheet addresses audio in CD frames (75 per second). We convert to
// sample frames using the referenced file's real sample rate, so a 96 kHz
// image with a CUE still seeks to exact positions – the 75 fps grid is only
// the authoring resolution, not a playback constraint.
package cue

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding/charmap"
)

// FramesPerSecond is the CD frame rate.
const FramesPerSecond = 75

// Sheet is one parsed CUE file. A sheet may reference several FILEs; each
// Track knows which one it belongs to.
type Sheet struct {
	Path      string // the .cue itself
	Title     string
	Performer string
	Genre     string
	Date      string
	Files     []string // referenced audio files, in order, resolved relative to the .cue dir
	Tracks    []Track
}

// Track is one TRACK entry.
type Track struct {
	Number    int
	Title     string
	Performer string
	File      string // resolved audio file path
	// Start is INDEX 01 in CD frames; Pregap (INDEX 00) is ignored for
	// playback start because players conventionally start at INDEX 01.
	StartCDFrames int64
	// EndCDFrames is the next track's INDEX 01 (or INDEX 00 when the next
	// track has a pregap that belongs to it), 0 = until end of file.
	EndCDFrames int64
	ISRC        string
}

// Parse reads a CUE sheet from path. Non-UTF-8 files are assumed to be
// Windows-1252 (the common case for sheets written by EAC on Western
// systems); 1250 cannot be told apart heuristically, so callers wanting
// Czech tags can re-parse with ParseBytes after their own detection.
func Parse(path string) (*Sheet, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ParseBytes(path, data)
}

// ParseBytes parses raw sheet bytes; path is used to resolve FILE entries.
func ParseBytes(path string, data []byte) (*Sheet, error) {
	data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})
	if !utf8.Valid(data) {
		dec := charmap.Windows1252.NewDecoder()
		if d, err := dec.Bytes(data); err == nil {
			data = d
		}
	}
	sh := &Sheet{Path: path}
	dir := filepath.Dir(path)
	var (
		curFile string
		cur     *Track
		// pendingPregapOf remembers an INDEX 00 seen before INDEX 01 for
		// the current track, so the previous track can end there.
		pendingIndex00 int64 = -1
	)
	sc := bufio.NewScanner(bytes.NewReader(data))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		fields := splitFields(line)
		if len(fields) == 0 {
			continue
		}
		cmd := strings.ToUpper(fields[0])
		args := fields[1:]
		switch cmd {
		case "REM":
			if len(args) >= 2 {
				switch strings.ToUpper(args[0]) {
				case "GENRE":
					sh.Genre = strings.Join(args[1:], " ")
				case "DATE":
					sh.Date = args[1]
				}
			}
		case "TITLE":
			if cur != nil {
				cur.Title = strings.Join(args, " ")
			} else {
				sh.Title = strings.Join(args, " ")
			}
		case "PERFORMER":
			if cur != nil {
				cur.Performer = strings.Join(args, " ")
			} else {
				sh.Performer = strings.Join(args, " ")
			}
		case "FILE":
			if len(args) == 0 {
				continue
			}
			// last arg is the type (WAVE/MP3/...), everything before is the name
			name := args[0]
			if len(args) > 1 {
				name = strings.Join(args[:len(args)-1], " ")
			}
			if !filepath.IsAbs(name) {
				name = filepath.Join(dir, name)
			}
			curFile = name
			sh.Files = append(sh.Files, name)
		case "TRACK":
			if len(args) < 1 {
				continue
			}
			n, err := strconv.Atoi(args[0])
			if err != nil {
				return nil, fmt.Errorf("cue: bad TRACK %q", args[0])
			}
			if len(args) >= 2 && !strings.EqualFold(args[1], "AUDIO") {
				cur = nil // data tracks are skipped
				continue
			}
			sh.Tracks = append(sh.Tracks, Track{Number: n, File: curFile, StartCDFrames: -1})
			cur = &sh.Tracks[len(sh.Tracks)-1]
			pendingIndex00 = -1
		case "INDEX":
			if cur == nil || len(args) < 2 {
				continue
			}
			idx, _ := strconv.Atoi(args[0])
			fr, err := parseMSF(args[1])
			if err != nil {
				return nil, err
			}
			switch idx {
			case 0:
				pendingIndex00 = fr
			case 1:
				cur.StartCDFrames = fr
				// The previous track in the same file ends where this one's
				// pregap (INDEX 00) starts, otherwise at this INDEX 01.
				if len(sh.Tracks) >= 2 {
					prev := &sh.Tracks[len(sh.Tracks)-2]
					if prev.File == cur.File && prev.EndCDFrames == 0 {
						if pendingIndex00 >= 0 {
							prev.EndCDFrames = pendingIndex00
						} else {
							prev.EndCDFrames = fr
						}
					}
				}
			}
		case "ISRC":
			if cur != nil && len(args) > 0 {
				cur.ISRC = args[0]
			}
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	// Tracks without INDEX 01 are unplayable; drop them.
	out := sh.Tracks[:0]
	for _, t := range sh.Tracks {
		if t.StartCDFrames >= 0 && t.File != "" {
			out = append(out, t)
		}
	}
	sh.Tracks = out
	return sh, nil
}

// parseMSF converts MM:SS:FF to CD frames.
func parseMSF(s string) (int64, error) {
	parts := strings.Split(s, ":")
	if len(parts) != 3 {
		return 0, fmt.Errorf("cue: bad index time %q", s)
	}
	m, e1 := strconv.Atoi(parts[0])
	sec, e2 := strconv.Atoi(parts[1])
	f, e3 := strconv.Atoi(parts[2])
	if e1 != nil || e2 != nil || e3 != nil {
		return 0, fmt.Errorf("cue: bad index time %q", s)
	}
	return int64(m)*60*FramesPerSecond + int64(sec)*FramesPerSecond + int64(f), nil
}

// ToSamples converts CD frames to sample frames at the given rate. CD
// frames are exact at 44.1 kHz (588 samples each); other rates round.
func ToSamples(cdFrames int64, sampleRate int) int64 {
	if cdFrames <= 0 {
		return 0
	}
	return cdFrames * int64(sampleRate) / FramesPerSecond
}

// splitFields splits a CUE line honouring double quotes.
func splitFields(line string) []string {
	var out []string
	var b strings.Builder
	inQ := false
	flush := func() {
		if b.Len() > 0 || inQ {
			out = append(out, b.String())
			b.Reset()
		}
	}
	for _, r := range line {
		switch {
		case r == '"':
			if inQ {
				out = append(out, b.String())
				b.Reset()
				inQ = false
			} else {
				inQ = true
			}
		case r == ' ' || r == '\t':
			if inQ {
				b.WriteRune(r)
			} else {
				flush()
			}
		default:
			b.WriteRune(r)
		}
	}
	if !inQ {
		flush()
	} else {
		out = append(out, b.String())
	}
	return out
}
