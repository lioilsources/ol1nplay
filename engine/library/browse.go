package library

import (
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/ol1n/ol1nplay/engine/library/cue"
	"github.com/ol1n/ol1nplay/engine/protocol"
)

// Every method here answers from the cache only. Browsing must stay instant
// on a spun-down NAS or an unplugged drive; the watcher keeps the cache
// honest.

// Tree returns one level of directories. dir == "" returns the roots.
func (l *Library) Tree(dir string) []protocol.DirNode {
	if dir == "" {
		var out []protocol.DirNode
		for _, r := range l.Roots() {
			n := protocol.DirNode{Path: r.Path, Name: r.Path, HasDirs: true}
			if d, ok := l.db.dirRow(r.Path); ok {
				n.HasDirs, n.Tracks, n.Cover = d.HasDirs, d.TrackCount, d.Cover
			}
			out = append(out, n)
		}
		return out
	}
	rows, err := l.db.childDirs(cleanPath(dir))
	if err != nil {
		l.logf("error", "tree %s: %v", dir, err)
		return nil
	}
	out := make([]protocol.DirNode, 0, len(rows))
	for _, r := range rows {
		out = append(out, protocol.DirNode{Path: r.Path, Name: r.Name, HasDirs: r.HasDirs, Tracks: r.TrackCount, Cover: r.Cover})
	}
	sort.Slice(out, func(i, j int) bool { return naturalLess(out[i].Name, out[j].Name) })
	return out
}

// List returns the full content of one directory: subdirectories, tracks
// (disc / track number, then natural filename order) and CUE sheets
// expanded into virtual tracks. A physical file referenced by a CUE is
// hidden – the sheet is the better view of it.
func (l *Library) List(dir string) (protocol.Listing, error) {
	dir = cleanPath(dir)
	out := protocol.Listing{Dir: dir, Dirs: []protocol.DirNode{}, Tracks: []protocol.Track{}}
	drow, ok := l.db.dirRow(dir)
	if !ok {
		return out, ErrNotFound
	}
	out.Cover = drow.Cover
	if root := l.rootOf(dir); root != "" && foldPath(root) != foldPath(dir) {
		out.Parent = filepath.Dir(dir)
	}
	out.Dirs = l.Tree(dir)
	tracks, err := l.db.tracksIn(dir)
	if err != nil {
		return out, err
	}
	byFold := map[string]protocol.Track{}
	for _, t := range tracks {
		byFold[foldPath(t.Path)] = t
	}

	cues, cueTracks, err := l.db.cuesIn(dir)
	if err != nil {
		return out, err
	}
	hidden := map[string]bool{}
	for _, c := range cues {
		sheet := protocol.CueSheet{Path: c.Path, Title: c.Title, Artist: c.Performer}
		for _, ct := range cueTracks[c.Path] {
			phys, ok := byFold[foldPath(ct.File)]
			if !ok {
				continue
			}
			sheet.File = ct.File
			hidden[foldPath(ct.File)] = true
			sheet.Tracks = append(sheet.Tracks, virtualTrack(phys, c, ct))
		}
		if len(sheet.Tracks) > 0 {
			out.Cue = append(out.Cue, sheet)
			out.Tracks = append(out.Tracks, sheet.Tracks...)
		}
	}
	for _, t := range tracks {
		if !hidden[foldPath(t.Path)] {
			out.Tracks = append(out.Tracks, t)
		}
	}
	sortTracks(out.Tracks)
	return out, nil
}

// virtualTrack builds the per-track view of one CUE entry on top of the
// physical file's format.
func virtualTrack(phys protocol.Track, c cueRow, ct cueTrackRow) protocol.Track {
	t := phys
	t.Path = cuePath(phys.Path, ct.No)
	t.CueFile = c.Path
	t.TrackNo = ct.No
	t.Title = ct.Title
	if t.Title == "" {
		t.Title = "Track " + strconv.Itoa(ct.No)
	}
	if ct.Performer != "" {
		t.Artist = ct.Performer
	} else if c.Performer != "" {
		t.Artist = c.Performer
	}
	if c.Title != "" {
		t.Album = c.Title
	}
	if c.Performer != "" && t.AlbumArtist == "" {
		t.AlbumArtist = c.Performer
	}
	if c.Genre != "" {
		t.Genre = c.Genre
	}
	if y, err := strconv.Atoi(strings.TrimSpace(c.Date)); err == nil && t.Year == 0 {
		t.Year = y
	}
	sr := phys.SampleRate
	if sr <= 0 {
		sr = 44100
	}
	t.CueStart = cue.ToSamples(ct.StartCD, sr)
	t.CueEnd = cue.ToSamples(ct.EndCD, sr)
	end := t.CueEnd
	if end == 0 {
		end = phys.Samples
		if end == 0 && phys.DurationMs > 0 {
			end = phys.DurationMs * int64(sr) / 1000
		}
	}
	if end > t.CueStart {
		t.Samples = end - t.CueStart
		t.DurationMs = t.Samples * 1000 / int64(sr)
	}
	return t
}

// cuePath builds the unique virtual path "<file>#<no>".
func cuePath(file string, no int) string { return file + "#" + strconv.Itoa(no) }

// splitCuePath undoes cuePath; no == 0 means a plain path.
func splitCuePath(p string) (string, int) {
	i := strings.LastIndexByte(p, '#')
	if i < 0 {
		return p, 0
	}
	n, err := strconv.Atoi(p[i+1:])
	if err != nil || n <= 0 {
		return p, 0
	}
	return p[:i], n
}

// Track returns one track by path (physical or virtual "<file>#<no>").
func (l *Library) Track(path string) (protocol.Track, error) {
	path = cleanPath(path)
	phys, no := splitCuePath(path)
	if no == 0 {
		return l.db.track(path)
	}
	t, err := l.db.track(phys)
	if err != nil {
		return t, err
	}
	c, ct, ok := l.db.cueTrack(phys, no)
	if !ok {
		return t, ErrNotFound
	}
	return virtualTrack(t, c, ct), nil
}

// Search finds tracks by a folded (case- and diacritic-insensitive) query
// across title, artist, album, filename and directory. Exact-title matches
// rank first, then title prefixes, then title substrings, then the rest.
func (l *Library) Search(query string, limit int) []protocol.Track {
	q := strings.TrimSpace(fold(query))
	if q == "" {
		return nil
	}
	if limit <= 0 {
		limit = 200
	}
	out, err := l.db.search(q, limit)
	if err != nil {
		l.logf("error", "search: %v", err)
		return nil
	}
	return out
}

// sortTracks orders by disc, track number, then natural filename.
func sortTracks(ts []protocol.Track) {
	sort.SliceStable(ts, func(i, j int) bool {
		a, b := ts[i], ts[j]
		if a.DiscNo != b.DiscNo {
			return a.DiscNo < b.DiscNo
		}
		if a.TrackNo != b.TrackNo {
			// Untagged (0) sorts after tagged tracks.
			if a.TrackNo == 0 || b.TrackNo == 0 {
				return b.TrackNo == 0
			}
			return a.TrackNo < b.TrackNo
		}
		return naturalLess(a.FileName, b.FileName)
	})
}

// naturalLess compares strings so embedded numbers sort numerically:
// "Track 2" < "Track 10". Case-insensitive.
func naturalLess(a, b string) bool {
	a, b = strings.ToLower(a), strings.ToLower(b)
	for a != "" && b != "" {
		ad, bd := isDigit(a[0]), isDigit(b[0])
		if ad && bd {
			ai, an := leadingNumber(a)
			bi, bn := leadingNumber(b)
			if ai != bi {
				return ai < bi
			}
			a, b = a[an:], b[bn:]
			continue
		}
		if ad != bd {
			return ad
		}
		if a[0] != b[0] {
			return a[0] < b[0]
		}
		a, b = a[1:], b[1:]
	}
	return len(a) < len(b)
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func leadingNumber(s string) (uint64, int) {
	n := 0
	var v uint64
	for n < len(s) && isDigit(s[n]) {
		if v < 1<<60 {
			v = v*10 + uint64(s[n]-'0')
		}
		n++
	}
	return v, n
}

func sortStable[T any](s []T, less func(a, b T) bool) {
	sort.SliceStable(s, func(i, j int) bool { return less(s[i], s[j]) })
}
