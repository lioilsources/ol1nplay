package library

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"

	"github.com/ol1n/ol1nplay/engine/meta"
	"github.com/ol1n/ol1nplay/engine/protocol"
)

var sprintf = fmt.Sprintf

// db wraps the SQLite cache. modernc's driver is safe for concurrent reads
// in WAL mode, but a single writer avoids SQLITE_BUSY churn during a scan,
// so every write goes through wmu.
type db struct {
	sql *sql.DB
	wmu sync.Mutex
}

const schemaVersion = 1

var migrations = []string{
	// v1
	`
CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS roots (
  path TEXT PRIMARY KEY,
  path_fold TEXT NOT NULL,
  last_scan INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS dirs (
  path TEXT PRIMARY KEY,
  path_fold TEXT NOT NULL UNIQUE,
  parent_fold TEXT NOT NULL,
  name TEXT NOT NULL,
  root_fold TEXT NOT NULL,
  cover TEXT NOT NULL DEFAULT '',
  has_dirs INTEGER NOT NULL DEFAULT 0,
  track_count INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS dirs_parent ON dirs(parent_fold);
CREATE TABLE IF NOT EXISTS tracks (
  path TEXT PRIMARY KEY,
  path_fold TEXT NOT NULL UNIQUE,
  dir_fold TEXT NOT NULL,
  dir TEXT NOT NULL,
  file_name TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  artist TEXT NOT NULL DEFAULT '',
  album_artist TEXT NOT NULL DEFAULT '',
  album TEXT NOT NULL DEFAULT '',
  genre TEXT NOT NULL DEFAULT '',
  composer TEXT NOT NULL DEFAULT '',
  comment TEXT NOT NULL DEFAULT '',
  track_no INTEGER NOT NULL DEFAULT 0,
  disc_no INTEGER NOT NULL DEFAULT 0,
  year INTEGER NOT NULL DEFAULT 0,
  codec TEXT NOT NULL DEFAULT '',
  container TEXT NOT NULL DEFAULT '',
  sample_rate INTEGER NOT NULL DEFAULT 0,
  bit_depth INTEGER NOT NULL DEFAULT 0,
  channels INTEGER NOT NULL DEFAULT 0,
  bitrate INTEGER NOT NULL DEFAULT 0,
  lossless INTEGER NOT NULL DEFAULT 0,
  dsd INTEGER NOT NULL DEFAULT 0,
  dsd_rate INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  samples INTEGER NOT NULL DEFAULT 0,
  size INTEGER NOT NULL DEFAULT 0,
  mtime INTEGER NOT NULL DEFAULT 0,
  replay_gain REAL NOT NULL DEFAULT 0,
  lyrics TEXT NOT NULL DEFAULT '',
  cover TEXT NOT NULL DEFAULT '',
  play_count INTEGER NOT NULL DEFAULT 0,
  last_played INTEGER NOT NULL DEFAULT 0,
  title_fold TEXT NOT NULL DEFAULT '',
  search_fold TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS tracks_dir ON tracks(dir_fold);
CREATE TABLE IF NOT EXISTS covers (
  hash TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  source_size INTEGER NOT NULL,
  source_mtime INTEGER NOT NULL,
  w INTEGER NOT NULL,
  h INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS covers_source ON covers(source);
CREATE TABLE IF NOT EXISTS cues (
  path TEXT PRIMARY KEY,
  dir_fold TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  performer TEXT NOT NULL DEFAULT '',
  genre TEXT NOT NULL DEFAULT '',
  date TEXT NOT NULL DEFAULT '',
  size INTEGER NOT NULL DEFAULT 0,
  mtime INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS cues_dir ON cues(dir_fold);
CREATE TABLE IF NOT EXISTS cue_tracks (
  cue_path TEXT NOT NULL,
  no INTEGER NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  performer TEXT NOT NULL DEFAULT '',
  file TEXT NOT NULL,
  file_fold TEXT NOT NULL,
  start_cd INTEGER NOT NULL,
  end_cd INTEGER NOT NULL,
  PRIMARY KEY (cue_path, no)
);
CREATE TABLE IF NOT EXISTS playlists (
  path TEXT PRIMARY KEY,
  dir_fold TEXT NOT NULL,
  name TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS favorites (
  path TEXT PRIMARY KEY,
  added_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT NOT NULL,
  played_at INTEGER NOT NULL,
  complete INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS history_at ON history(played_at);
`,
}

func openDB(path string) (*db, error) {
	// _pragma via DSN keeps WAL/busy settings per connection.
	dsn := "file:" + filepath.ToSlash(path) + "?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)&_pragma=foreign_keys(ON)"
	s, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	s.SetMaxOpenConns(4)
	d := &db{sql: s}
	if err := d.migrate(); err != nil {
		s.Close()
		return nil, err
	}
	return d, nil
}

func (d *db) close() { d.sql.Close() }

func (d *db) migrate() error {
	var v int
	_ = d.sql.QueryRow(`SELECT version FROM schema_version LIMIT 1`).Scan(&v)
	for i := v; i < len(migrations); i++ {
		if _, err := d.sql.Exec(migrations[i]); err != nil {
			return fmt.Errorf("migration %d: %w", i+1, err)
		}
	}
	if v == 0 {
		if _, err := d.sql.Exec(`INSERT INTO schema_version(version) VALUES (?)`, schemaVersion); err != nil {
			return err
		}
	} else if v != schemaVersion {
		if _, err := d.sql.Exec(`UPDATE schema_version SET version = ?`, schemaVersion); err != nil {
			return err
		}
	}
	return nil
}

// exec serialises writes.
func (d *db) exec(q string, args ...any) error {
	d.wmu.Lock()
	defer d.wmu.Unlock()
	_, err := d.sql.Exec(q, args...)
	return err
}

// tx runs fn inside a write transaction.
func (d *db) tx(fn func(tx *sql.Tx) error) error {
	d.wmu.Lock()
	defer d.wmu.Unlock()
	tx, err := d.sql.Begin()
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}

// ---- roots ---------------------------------------------------------------

func (d *db) addRoot(path string) error {
	return d.exec(`INSERT OR IGNORE INTO roots(path, path_fold) VALUES (?, ?)`, path, foldPath(path))
}

func (d *db) removeRoot(path string) error {
	return d.tx(func(tx *sql.Tx) error {
		pf := foldPath(path)
		for _, q := range []string{
			`DELETE FROM roots WHERE path_fold = ?`,
			`DELETE FROM tracks WHERE dir_fold = ? OR dir_fold LIKE ? ESCAPE '\'`,
			`DELETE FROM dirs WHERE path_fold = ? OR path_fold LIKE ? ESCAPE '\'`,
			`DELETE FROM cues WHERE dir_fold = ? OR dir_fold LIKE ? ESCAPE '\'`,
			`DELETE FROM playlists WHERE dir_fold = ? OR dir_fold LIKE ? ESCAPE '\'`,
		} {
			args := []any{pf, prefixPattern(path)}
			if strings.HasPrefix(q, "DELETE FROM roots") {
				args = []any{pf}
			}
			if _, err := tx.Exec(q, args...); err != nil {
				return err
			}
		}
		_, err := tx.Exec(`DELETE FROM cue_tracks WHERE cue_path NOT IN (SELECT path FROM cues)`)
		return err
	})
}

func (d *db) roots() ([]protocol.Root, error) {
	rows, err := d.sql.Query(`SELECT r.path, r.last_scan,
		(SELECT COUNT(*) FROM tracks t WHERE t.dir_fold = r.path_fold OR t.dir_fold LIKE (r.path_fold || ? || '%')),
		(SELECT COUNT(*) FROM dirs d WHERE d.root_fold = r.path_fold)
		FROM roots r ORDER BY r.path`, string(filepath.Separator))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []protocol.Root
	for rows.Next() {
		var r protocol.Root
		if err := rows.Scan(&r.Path, &r.LastScan, &r.Tracks, &r.Dirs); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (d *db) touchRoot(path string) error {
	return d.exec(`UPDATE roots SET last_scan = ? WHERE path_fold = ?`, time.Now().UnixMilli(), foldPath(path))
}

// ---- dirs ----------------------------------------------------------------

type dirRow struct {
	Path       string
	Name       string
	Cover      string
	HasDirs    bool
	TrackCount int
}

func (d *db) upsertDir(tx *sql.Tx, path, root string, hasDirs bool, trackCount int, cover string) error {
	_, err := tx.Exec(`INSERT INTO dirs(path, path_fold, parent_fold, name, root_fold, cover, has_dirs, track_count)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(path_fold) DO UPDATE SET path = excluded.path, parent_fold = excluded.parent_fold,
		  name = excluded.name, root_fold = excluded.root_fold, cover = excluded.cover,
		  has_dirs = excluded.has_dirs, track_count = excluded.track_count`,
		path, foldPath(path), foldPath(filepath.Dir(path)), filepath.Base(path), foldPath(root), cover, b2i(hasDirs), trackCount)
	return err
}

func (d *db) dirExists(path string) bool {
	var n int
	_ = d.sql.QueryRow(`SELECT COUNT(*) FROM dirs WHERE path_fold = ?`, foldPath(path)).Scan(&n)
	return n > 0
}

func (d *db) dirRow(path string) (dirRow, bool) {
	var r dirRow
	var hd int
	err := d.sql.QueryRow(`SELECT path, name, cover, has_dirs, track_count FROM dirs WHERE path_fold = ?`, foldPath(path)).
		Scan(&r.Path, &r.Name, &r.Cover, &hd, &r.TrackCount)
	r.HasDirs = hd != 0
	return r, err == nil
}

func (d *db) childDirs(parent string) ([]dirRow, error) {
	rows, err := d.sql.Query(`SELECT path, name, cover, has_dirs, track_count FROM dirs WHERE parent_fold = ? AND path_fold != ?`,
		foldPath(parent), foldPath(parent))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dirRow
	for rows.Next() {
		var r dirRow
		var hd int
		if err := rows.Scan(&r.Path, &r.Name, &r.Cover, &hd, &r.TrackCount); err != nil {
			return nil, err
		}
		r.HasDirs = hd != 0
		out = append(out, r)
	}
	return out, rows.Err()
}

// dirsUnder lists every indexed directory inside root (including root).
func (d *db) dirsUnder(root string) ([]string, error) {
	rows, err := d.sql.Query(`SELECT path FROM dirs WHERE path_fold = ? OR path_fold LIKE ? ESCAPE '\'`, foldPath(root), prefixPattern(root))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// deleteTree removes a directory and everything inside it from the cache.
func (d *db) deleteTree(path string) error {
	return d.tx(func(tx *sql.Tx) error {
		pf, pat := foldPath(path), prefixPattern(path)
		for _, q := range []string{
			`DELETE FROM tracks WHERE dir_fold = ? OR dir_fold LIKE ? ESCAPE '\'`,
			`DELETE FROM dirs WHERE path_fold = ? OR path_fold LIKE ? ESCAPE '\'`,
			`DELETE FROM cues WHERE dir_fold = ? OR dir_fold LIKE ? ESCAPE '\'`,
			`DELETE FROM playlists WHERE dir_fold = ? OR dir_fold LIKE ? ESCAPE '\'`,
		} {
			if _, err := tx.Exec(q, pf, pat); err != nil {
				return err
			}
		}
		_, err := tx.Exec(`DELETE FROM cue_tracks WHERE cue_path NOT IN (SELECT path FROM cues)`)
		return err
	})
}

// ---- tracks --------------------------------------------------------------

const trackCols = `t.path, t.dir, t.file_name, t.title, t.artist, t.album_artist, t.album, t.genre, t.composer, t.comment,
 t.track_no, t.disc_no, t.year, t.codec, t.container, t.sample_rate, t.bit_depth, t.channels, t.bitrate, t.lossless, t.dsd, t.dsd_rate,
 t.duration_ms, t.samples, t.size, t.mtime, t.replay_gain, t.cover, t.play_count, t.last_played,
 (t.lyrics != ''), (SELECT COUNT(*) FROM favorites fv WHERE fv.path = t.path)`

func scanTrack(sc interface{ Scan(...any) error }) (protocol.Track, error) {
	var t protocol.Track
	var lossless, dsd, hasLyr, fav int
	var dsdRate int
	err := sc.Scan(&t.Path, &t.Dir, &t.FileName, &t.Title, &t.Artist, &t.AlbumArtist, &t.Album, &t.Genre, &t.Composer, &t.Comment,
		&t.TrackNo, &t.DiscNo, &t.Year, &t.Codec, &t.Container, &t.SampleRate, &t.BitDepth, &t.Channels, &t.Bitrate, &lossless, &dsd, &dsdRate,
		&t.DurationMs, &t.Samples, &t.SizeBytes, &t.ModTime, &t.ReplayGain, &t.Cover, &t.PlayCount, &t.LastPlayed, &hasLyr, &fav)
	t.Lossless = lossless != 0
	t.DSD = dsd != 0
	t.HasLyrics = hasLyr != 0
	t.Favorite = fav != 0
	return t, err
}

func (d *db) track(path string) (protocol.Track, error) {
	row := d.sql.QueryRow(`SELECT `+trackCols+` FROM tracks t WHERE path_fold = ?`, foldPath(path))
	t, err := scanTrack(row)
	if err == sql.ErrNoRows {
		return t, ErrNotFound
	}
	return t, err
}

func (d *db) tracksIn(dir string) ([]protocol.Track, error) {
	rows, err := d.sql.Query(`SELECT `+trackCols+` FROM tracks t WHERE dir_fold = ?`, foldPath(dir))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []protocol.Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// stamp is what decides whether a file is re-probed.
type stamp struct {
	Size  int64
	MTime int64
	Cover string
}

func (d *db) stampsIn(dir string) (map[string]stamp, error) {
	rows, err := d.sql.Query(`SELECT path, size, mtime, cover FROM tracks WHERE dir_fold = ?`, foldPath(dir))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]stamp{}
	for rows.Next() {
		var p string
		var s stamp
		if err := rows.Scan(&p, &s.Size, &s.MTime, &s.Cover); err != nil {
			return nil, err
		}
		out[foldPath(p)] = s
	}
	return out, rows.Err()
}

func (d *db) upsertTrack(tx *sql.Tx, path string, m *meta.Meta, size, mtime int64, cover string) error {
	dir := filepath.Dir(path)
	name := filepath.Base(path)
	title := m.Title
	if title == "" {
		title = strings.TrimSuffix(name, filepath.Ext(name))
	}
	search := fold(strings.Join([]string{title, m.Artist, m.AlbumArtist, m.Album, name, filepath.Base(dir)}, " "))
	_, err := tx.Exec(`INSERT INTO tracks(path, path_fold, dir_fold, dir, file_name, title, artist, album_artist, album, genre, composer, comment,
		track_no, disc_no, year, codec, container, sample_rate, bit_depth, channels, bitrate, lossless, dsd, dsd_rate,
		duration_ms, samples, size, mtime, replay_gain, lyrics, cover, title_fold, search_fold)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(path_fold) DO UPDATE SET path=excluded.path, dir_fold=excluded.dir_fold, dir=excluded.dir, file_name=excluded.file_name,
		 title=excluded.title, artist=excluded.artist, album_artist=excluded.album_artist, album=excluded.album, genre=excluded.genre,
		 composer=excluded.composer, comment=excluded.comment, track_no=excluded.track_no, disc_no=excluded.disc_no, year=excluded.year,
		 codec=excluded.codec, container=excluded.container, sample_rate=excluded.sample_rate, bit_depth=excluded.bit_depth,
		 channels=excluded.channels, bitrate=excluded.bitrate, lossless=excluded.lossless, dsd=excluded.dsd, dsd_rate=excluded.dsd_rate,
		 duration_ms=excluded.duration_ms, samples=excluded.samples, size=excluded.size, mtime=excluded.mtime,
		 replay_gain=excluded.replay_gain, lyrics=excluded.lyrics, cover=excluded.cover, title_fold=excluded.title_fold, search_fold=excluded.search_fold`,
		path, foldPath(path), foldPath(dir), dir, name, title, m.Artist, m.AlbumArtist, m.Album, m.Genre, m.Composer, m.Comment,
		m.TrackNo, m.DiscNo, m.Year, m.Codec, m.Container, m.SampleRate, m.BitDepth, m.Channels, m.Bitrate, b2i(m.Lossless), b2i(m.DSD), m.DSDRate,
		m.DurationMs, m.Samples, size, mtime, m.ReplayGainTrack, m.Lyrics, cover, fold(title), search)
	return err
}

func (d *db) setTrackCover(tx *sql.Tx, path, cover string) error {
	_, err := tx.Exec(`UPDATE tracks SET cover = ? WHERE path_fold = ?`, cover, foldPath(path))
	return err
}

func (d *db) deleteTrack(tx *sql.Tx, path string) error {
	_, err := tx.Exec(`DELETE FROM tracks WHERE path_fold = ?`, foldPath(path))
	return err
}

func (d *db) trackLyrics(path string) (string, error) {
	var s string
	err := d.sql.QueryRow(`SELECT lyrics FROM tracks WHERE path_fold = ?`, foldPath(path)).Scan(&s)
	if err == sql.ErrNoRows {
		return "", ErrNotFound
	}
	return s, err
}

func (d *db) search(q string, limit int) ([]protocol.Track, error) {
	rows, err := d.sql.Query(`SELECT `+trackCols+`, title_fold FROM tracks t WHERE search_fold LIKE ? ESCAPE '\' LIMIT ?`,
		"%"+escapeLike(q)+"%", limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	type hit struct {
		t    protocol.Track
		rank int
	}
	var hits []hit
	for rows.Next() {
		var t protocol.Track
		var lossless, dsd, hasLyr, fav, dsdRate int
		var tf string
		if err := rows.Scan(&t.Path, &t.Dir, &t.FileName, &t.Title, &t.Artist, &t.AlbumArtist, &t.Album, &t.Genre, &t.Composer, &t.Comment,
			&t.TrackNo, &t.DiscNo, &t.Year, &t.Codec, &t.Container, &t.SampleRate, &t.BitDepth, &t.Channels, &t.Bitrate, &lossless, &dsd, &dsdRate,
			&t.DurationMs, &t.Samples, &t.SizeBytes, &t.ModTime, &t.ReplayGain, &t.Cover, &t.PlayCount, &t.LastPlayed, &hasLyr, &fav, &tf); err != nil {
			return nil, err
		}
		t.Lossless, t.DSD, t.HasLyrics, t.Favorite = lossless != 0, dsd != 0, hasLyr != 0, fav != 0
		r := 3
		switch {
		case tf == q:
			r = 0
		case strings.HasPrefix(tf, q):
			r = 1
		case strings.Contains(tf, q):
			r = 2
		}
		hits = append(hits, hit{t, r})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sortStable(hits, func(a, b hit) bool {
		if a.rank != b.rank {
			return a.rank < b.rank
		}
		return naturalLess(a.t.Title, b.t.Title)
	})
	out := make([]protocol.Track, 0, len(hits))
	for _, h := range hits {
		out = append(out, h.t)
	}
	return out, nil
}

// ---- covers --------------------------------------------------------------

func (d *db) coverBySource(source string, size, mtime int64) (string, bool) {
	var h string
	err := d.sql.QueryRow(`SELECT hash FROM covers WHERE source = ? AND source_size = ? AND source_mtime = ?`, source, size, mtime).Scan(&h)
	return h, err == nil
}

func (d *db) coverExists(hash string) bool {
	var n int
	_ = d.sql.QueryRow(`SELECT COUNT(*) FROM covers WHERE hash = ?`, hash).Scan(&n)
	return n > 0
}

func (d *db) putCover(hash, source string, size, mtime int64, w, h int) error {
	return d.exec(`INSERT INTO covers(hash, source, source_size, source_mtime, w, h) VALUES (?,?,?,?,?,?)
		ON CONFLICT(hash) DO UPDATE SET source = excluded.source, source_size = excluded.source_size, source_mtime = excluded.source_mtime`,
		hash, source, size, mtime, w, h)
}

// ---- cues ----------------------------------------------------------------

type cueRow struct {
	Path, Title, Performer, Genre, Date string
	Size, MTime                         int64
}

type cueTrackRow struct {
	No               int
	Title, Performer string
	File             string
	StartCD, EndCD   int64
}

func (d *db) cueStamps(dir string) (map[string]cueRow, error) {
	rows, err := d.sql.Query(`SELECT path, title, performer, genre, date, size, mtime FROM cues WHERE dir_fold = ?`, foldPath(dir))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]cueRow{}
	for rows.Next() {
		var c cueRow
		if err := rows.Scan(&c.Path, &c.Title, &c.Performer, &c.Genre, &c.Date, &c.Size, &c.MTime); err != nil {
			return nil, err
		}
		out[foldPath(c.Path)] = c
	}
	return out, rows.Err()
}

func (d *db) putCue(tx *sql.Tx, c cueRow, tracks []cueTrackRow) error {
	dir := filepath.Dir(c.Path)
	if _, err := tx.Exec(`INSERT INTO cues(path, dir_fold, title, performer, genre, date, size, mtime) VALUES (?,?,?,?,?,?,?,?)
		ON CONFLICT(path) DO UPDATE SET title=excluded.title, performer=excluded.performer, genre=excluded.genre, date=excluded.date, size=excluded.size, mtime=excluded.mtime`,
		c.Path, foldPath(dir), c.Title, c.Performer, c.Genre, c.Date, c.Size, c.MTime); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM cue_tracks WHERE cue_path = ?`, c.Path); err != nil {
		return err
	}
	for _, t := range tracks {
		if _, err := tx.Exec(`INSERT INTO cue_tracks(cue_path, no, title, performer, file, file_fold, start_cd, end_cd) VALUES (?,?,?,?,?,?,?,?)`,
			c.Path, t.No, t.Title, t.Performer, t.File, foldPath(t.File), t.StartCD, t.EndCD); err != nil {
			return err
		}
	}
	return nil
}

func (d *db) deleteCue(tx *sql.Tx, path string) error {
	if _, err := tx.Exec(`DELETE FROM cue_tracks WHERE cue_path = ?`, path); err != nil {
		return err
	}
	_, err := tx.Exec(`DELETE FROM cues WHERE path = ?`, path)
	return err
}

func (d *db) cuesIn(dir string) ([]cueRow, map[string][]cueTrackRow, error) {
	rows, err := d.sql.Query(`SELECT path, title, performer, genre, date, size, mtime FROM cues WHERE dir_fold = ? ORDER BY path`, foldPath(dir))
	if err != nil {
		return nil, nil, err
	}
	var cues []cueRow
	for rows.Next() {
		var c cueRow
		if err := rows.Scan(&c.Path, &c.Title, &c.Performer, &c.Genre, &c.Date, &c.Size, &c.MTime); err != nil {
			rows.Close()
			return nil, nil, err
		}
		cues = append(cues, c)
	}
	rows.Close()
	tracks := map[string][]cueTrackRow{}
	for _, c := range cues {
		tr, err := d.sql.Query(`SELECT no, title, performer, file, start_cd, end_cd FROM cue_tracks WHERE cue_path = ? ORDER BY no`, c.Path)
		if err != nil {
			return nil, nil, err
		}
		for tr.Next() {
			var t cueTrackRow
			if err := tr.Scan(&t.No, &t.Title, &t.Performer, &t.File, &t.StartCD, &t.EndCD); err != nil {
				tr.Close()
				return nil, nil, err
			}
			tracks[c.Path] = append(tracks[c.Path], t)
		}
		tr.Close()
	}
	return cues, tracks, nil
}

// cueTrack finds the virtual track for file#no.
func (d *db) cueTrack(file string, no int) (cueRow, cueTrackRow, bool) {
	var c cueRow
	var t cueTrackRow
	err := d.sql.QueryRow(`SELECT c.path, c.title, c.performer, c.genre, c.date, c.size, c.mtime, ct.no, ct.title, ct.performer, ct.file, ct.start_cd, ct.end_cd
		FROM cue_tracks ct JOIN cues c ON c.path = ct.cue_path WHERE ct.file_fold = ? AND ct.no = ? LIMIT 1`, foldPath(file), no).
		Scan(&c.Path, &c.Title, &c.Performer, &c.Genre, &c.Date, &c.Size, &c.MTime, &t.No, &t.Title, &t.Performer, &t.File, &t.StartCD, &t.EndCD)
	return c, t, err == nil
}

// ---- playlists -----------------------------------------------------------

func (d *db) putPlaylist(tx *sql.Tx, path string, count int) error {
	name := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	_, err := tx.Exec(`INSERT INTO playlists(path, dir_fold, name, count) VALUES (?,?,?,?)
		ON CONFLICT(path) DO UPDATE SET name = excluded.name, count = excluded.count`, path, foldPath(filepath.Dir(path)), name, count)
	return err
}

func (d *db) playlistsIn(dir string) ([]string, error) {
	rows, err := d.sql.Query(`SELECT path FROM playlists WHERE dir_fold = ?`, foldPath(dir))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (d *db) deletePlaylist(tx *sql.Tx, path string) error {
	_, err := tx.Exec(`DELETE FROM playlists WHERE path = ?`, path)
	return err
}

func (d *db) playlists() ([]protocol.Playlist, error) {
	rows, err := d.sql.Query(`SELECT path, name, count FROM playlists ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []protocol.Playlist
	for rows.Next() {
		var p protocol.Playlist
		if err := rows.Scan(&p.Path, &p.Name, &p.Count); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// ---- favorites / history -------------------------------------------------

func (d *db) favorites() ([]protocol.Track, error) {
	rows, err := d.sql.Query(`SELECT ` + trackCols + ` FROM favorites f JOIN tracks t ON t.path = f.path ORDER BY f.added_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []protocol.Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

type historyRow struct {
	Path     string
	PlayedAt int64
	Complete bool
}

// history returns raw rows; the caller resolves paths (which may be CUE
// virtual paths) through Track.
func (d *db) history(limit int) ([]historyRow, error) {
	rows, err := d.sql.Query(`SELECT path, played_at, complete FROM history ORDER BY played_at DESC, id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []historyRow
	for rows.Next() {
		var h historyRow
		var c int
		if err := rows.Scan(&h.Path, &h.PlayedAt, &c); err != nil {
			return nil, err
		}
		h.Complete = c != 0
		out = append(out, h)
	}
	return out, rows.Err()
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}
