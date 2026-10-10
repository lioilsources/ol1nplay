package library

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/ol1n/ol1nplay/engine/library/lrc"
	"github.com/ol1n/ol1nplay/engine/library/m3u"
	"github.com/ol1n/ol1nplay/engine/protocol"
)

// ---- playlists -----------------------------------------------------------

// PlaylistDir is where SavePlaylist writes.
func (l *Library) PlaylistDir() string { return filepath.Join(l.opt.DataDir, "playlists") }

// Playlists lists M3U files found inside the roots plus those saved by the
// app. The app's own folder is read live: it is tiny and not watched.
func (l *Library) Playlists() []protocol.Playlist {
	out, err := l.db.playlists()
	if err != nil {
		l.logf("error", "playlists: %v", err)
	}
	seen := map[string]bool{}
	for _, p := range out {
		seen[foldPath(p.Path)] = true
	}
	ents, _ := os.ReadDir(l.PlaylistDir())
	for _, e := range ents {
		p := filepath.Join(l.PlaylistDir(), e.Name())
		if e.IsDir() || seen[foldPath(p)] || !(strings.HasSuffix(strings.ToLower(p), ".m3u") || strings.HasSuffix(strings.ToLower(p), ".m3u8")) {
			continue
		}
		n := 0
		if es, err := m3u.Read(p); err == nil {
			n = len(es)
		}
		out = append(out, protocol.Playlist{Path: p, Name: strings.TrimSuffix(e.Name(), filepath.Ext(e.Name())), Count: n})
	}
	sort.Slice(out, func(i, j int) bool { return naturalLess(out[i].Name, out[j].Name) })
	return out
}

// LoadPlaylist resolves an M3U into tracks. Entries unknown to the cache
// (outside the roots, or not yet scanned) are returned as bare tracks so the
// playback engine can still try them.
func (l *Library) LoadPlaylist(path string) ([]protocol.Track, error) {
	ents, err := m3u.Read(path)
	if err != nil {
		return nil, err
	}
	out := make([]protocol.Track, 0, len(ents))
	for _, e := range ents {
		t, err := l.Track(e.Path)
		if err != nil {
			t = protocol.Track{Path: e.Path, Dir: filepath.Dir(e.Path), FileName: filepath.Base(e.Path), Title: e.Title}
			if t.Title == "" {
				t.Title = strings.TrimSuffix(t.FileName, filepath.Ext(t.FileName))
			}
			if e.Duration > 0 {
				t.DurationMs = int64(e.Duration) * 1000
			}
		}
		out = append(out, t)
	}
	return out, nil
}

var unsafeName = regexp.MustCompile(`[<>:"/\\|?*\x00-\x1f]`)

// SavePlaylist writes paths as <DataDir>/playlists/<name>.m3u8 and returns
// the file path.
func (l *Library) SavePlaylist(name string, paths []string) (string, error) {
	name = strings.TrimSpace(unsafeName.ReplaceAllString(name, "_"))
	if name == "" {
		name = "playlist"
	}
	ents := make([]m3u.Entry, 0, len(paths))
	for _, p := range paths {
		e := m3u.Entry{Path: p, Duration: -1}
		if t, err := l.Track(p); err == nil {
			e.Title = t.Title
			if t.Artist != "" {
				e.Title = t.Artist + " - " + t.Title
			}
			e.Duration = int(t.DurationMs / 1000)
		}
		ents = append(ents, e)
	}
	path := filepath.Join(l.PlaylistDir(), name+".m3u8")
	return path, m3u.Write(path, ents)
}

// ---- lyrics --------------------------------------------------------------

// Lyrics looks for a sidecar .lrc, then .txt, then the tag lyrics cached
// at scan time. Sidecars are read from disk on demand – they are small
// and only requested for the playing track.
func (l *Library) Lyrics(trackPath string) *protocol.Lyrics {
	phys, _ := splitCuePath(cleanPath(trackPath))
	base := strings.TrimSuffix(phys, filepath.Ext(phys))
	if data, err := os.ReadFile(base + ".lrc"); err == nil {
		return lrc.Parse(string(data))
	}
	if data, err := os.ReadFile(base + ".txt"); err == nil {
		return &protocol.Lyrics{Text: strings.TrimSpace(string(data)), Source: "txt"}
	}
	if s, err := l.db.trackLyrics(phys); err == nil && s != "" {
		// Some taggers embed LRC-formatted text; honour the timestamps.
		p := lrc.Parse(s)
		if p.Source == "lrc" {
			return p
		}
		return &protocol.Lyrics{Text: strings.TrimSpace(s), Source: "tag"}
	}
	return nil
}

// ---- favorites / history -------------------------------------------------

// Favorites lists starred tracks, newest first.
func (l *Library) Favorites() []protocol.Track {
	out, err := l.db.favorites()
	if err != nil {
		l.logf("error", "favorites: %v", err)
	}
	return out
}

// AddFavorite stars a track.
func (l *Library) AddFavorite(path string) error {
	return l.db.exec(`INSERT OR IGNORE INTO favorites(path, added_at) VALUES (?, ?)`, cleanPath(path), time.Now().UnixMilli())
}

// RemoveFavorite un-stars a track.
func (l *Library) RemoveFavorite(path string) error {
	return l.db.exec(`DELETE FROM favorites WHERE path = ?`, cleanPath(path))
}

// IsFavorite reports whether a track is starred.
func (l *Library) IsFavorite(path string) bool {
	var n int
	_ = l.db.sql.QueryRow(`SELECT COUNT(*) FROM favorites WHERE path = ?`, cleanPath(path)).Scan(&n)
	return n > 0
}

// RecordPlay appends to the history and bumps the play counter.
func (l *Library) RecordPlay(path string, complete bool) error {
	path = cleanPath(path)
	now := time.Now().UnixMilli()
	if err := l.db.exec(`INSERT INTO history(path, played_at, complete) VALUES (?, ?, ?)`, path, now, b2i(complete)); err != nil {
		return err
	}
	phys, _ := splitCuePath(path)
	return l.db.exec(`UPDATE tracks SET play_count = play_count + 1, last_played = ? WHERE path_fold = ?`, now, foldPath(phys))
}

// History returns the most recent plays.
func (l *Library) History(limit int) []protocol.HistoryEntry {
	if limit <= 0 {
		limit = 100
	}
	rows, err := l.db.history(limit)
	if err != nil {
		l.logf("error", "history: %v", err)
	}
	out := make([]protocol.HistoryEntry, 0, len(rows))
	for _, h := range rows {
		t, err := l.Track(h.Path)
		if err != nil {
			continue // file is gone; history keeps the row in case it returns
		}
		out = append(out, protocol.HistoryEntry{Track: t, PlayedAt: h.PlayedAt, Complete: h.Complete})
	}
	return out
}
