// Package library indexes one or more root directories 1:1 with the
// filesystem, keeps a SQLite cache of tags / formats / covers, and watches
// for changes with fsnotify. The filesystem is the source of truth; the
// database only exists so that browsing never touches the disk.
package library

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
	"unicode"

	"golang.org/x/text/runes"
	"golang.org/x/text/transform"
	"golang.org/x/text/unicode/norm"

	"github.com/ol1n/ol1nplay/engine/meta"
	"github.com/ol1n/ol1nplay/engine/protocol"
)

// Options configures Open.
type Options struct {
	DBPath   string // SQLite file; parent dir is created
	CoverDir string // where <hash>.jpg thumbnails go
	DataDir  string // playlists/ etc.; defaults to the DB's directory
	Prober   meta.Prober
	Roots    []string // added on open if not already persisted
	// Concurrency bounds the number of parallel probes (default NumCPU).
	Concurrency int
	// Debounce is the fsnotify quiet period per directory (default 500 ms).
	Debounce time.Duration
	// NoWatch disables fsnotify (tests, read-only media).
	NoWatch bool
	// NoInitialScan skips the scan on Open (the caller calls Rescan).
	NoInitialScan bool

	Log      func(protocol.LogLine)
	OnChange func(protocol.LibraryChange)
	OnScan   func(protocol.ScanProgress)
}

// Library is the indexed music collection.
type Library struct {
	opt    Options
	db     *db
	covers *coverStore
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup
	sem    chan struct{} // probe concurrency

	mu       sync.Mutex
	scanning map[string]bool // root → scanning

	watch *watcher
}

// ErrNotFound is returned for unknown paths.
var ErrNotFound = errors.New("library: not found")

// Open loads (or creates) the cache, registers the roots, starts the
// watcher and kicks off the initial scan in the background.
func Open(ctx context.Context, opt Options) (*Library, error) {
	if opt.Prober == nil {
		return nil, errors.New("library: Prober is required")
	}
	if opt.Concurrency <= 0 {
		opt.Concurrency = runtime.NumCPU()
	}
	if opt.Debounce <= 0 {
		opt.Debounce = 500 * time.Millisecond
	}
	if opt.DataDir == "" {
		opt.DataDir = filepath.Dir(opt.DBPath)
	}
	if opt.CoverDir == "" {
		opt.CoverDir = filepath.Join(opt.DataDir, "covers")
	}
	if opt.Log == nil {
		opt.Log = func(protocol.LogLine) {}
	}
	if opt.OnChange == nil {
		opt.OnChange = func(protocol.LibraryChange) {}
	}
	if opt.OnScan == nil {
		opt.OnScan = func(protocol.ScanProgress) {}
	}
	for _, d := range []string{filepath.Dir(opt.DBPath), opt.CoverDir, filepath.Join(opt.DataDir, "playlists")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return nil, err
		}
	}
	d, err := openDB(opt.DBPath)
	if err != nil {
		return nil, err
	}
	cctx, cancel := context.WithCancel(ctx)
	l := &Library{
		opt:      opt,
		db:       d,
		ctx:      cctx,
		cancel:   cancel,
		sem:      make(chan struct{}, opt.Concurrency),
		scanning: map[string]bool{},
	}
	l.covers = newCoverStore(l)
	for _, r := range opt.Roots {
		if err := l.db.addRoot(cleanPath(r)); err != nil {
			l.Close()
			return nil, err
		}
	}
	if !opt.NoWatch {
		w, err := newWatcher(l)
		if err != nil {
			l.logf("warn", "fsnotify unavailable: %v", err)
		} else {
			l.watch = w
			for _, r := range l.rootPaths() {
				w.addTree(r)
			}
		}
	}
	if !opt.NoInitialScan {
		for _, r := range l.rootPaths() {
			l.scanRootAsync(r)
		}
	}
	return l, nil
}

// Close stops the watcher and waits for scans to finish.
func (l *Library) Close() {
	l.cancel()
	if l.watch != nil {
		l.watch.close()
	}
	l.wg.Wait()
	l.db.close()
}

// Wait blocks until every running scan has finished (tests, CLI).
func (l *Library) Wait() { l.wg.Wait() }

func (l *Library) logf(level, format string, args ...any) {
	l.opt.Log(protocol.LogLine{
		At:    time.Now().UnixMilli(),
		Level: level,
		Scope: "library",
		Msg:   sprintf(format, args...),
	})
}

// ---- roots ---------------------------------------------------------------

// AddRoot registers a directory, watches it and scans it.
func (l *Library) AddRoot(path string) error {
	path = cleanPath(path)
	if fi, err := os.Stat(path); err != nil || !fi.IsDir() {
		return errors.New("library: root is not a directory: " + path)
	}
	if err := l.db.addRoot(path); err != nil {
		return err
	}
	if l.watch != nil {
		l.watch.addTree(path)
	}
	l.scanRootAsync(path)
	l.opt.OnChange(protocol.LibraryChange{Dir: "", Reason: "root"})
	return nil
}

// RemoveRoot forgets a root and everything under it (cache only; files are
// untouched).
func (l *Library) RemoveRoot(path string) error {
	path = cleanPath(path)
	if l.watch != nil {
		l.watch.removeTree(path)
	}
	if err := l.db.removeRoot(path); err != nil {
		return err
	}
	l.opt.OnChange(protocol.LibraryChange{Dir: "", Reason: "root"})
	return nil
}

// Roots lists registered roots with counts. A root whose directory cannot
// be stat'ed (drive unplugged) is reported Missing, never dropped – the
// cache survives until the drive returns.
func (l *Library) Roots() []protocol.Root {
	roots, err := l.db.roots()
	if err != nil {
		l.logf("error", "roots: %v", err)
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	for i := range roots {
		if _, err := os.Stat(roots[i].Path); err != nil {
			roots[i].Missing = true
		}
		roots[i].Scanning = l.scanning[roots[i].Path]
	}
	return roots
}

func (l *Library) rootPaths() []string {
	rs, _ := l.db.roots()
	out := make([]string, 0, len(rs))
	for _, r := range rs {
		out = append(out, r.Path)
	}
	return out
}

// rootOf returns the registered root containing path ("" if none).
func (l *Library) rootOf(path string) string {
	for _, r := range l.rootPaths() {
		if isUnder(r, path) {
			return r
		}
	}
	return ""
}

// ---- path helpers --------------------------------------------------------

// cleanPath normalises separators without touching case: paths are stored
// exactly as the user gave them so they round-trip into playlists.
func cleanPath(p string) string {
	p = filepath.Clean(p)
	if runtime.GOOS == "windows" {
		p = strings.ReplaceAll(p, "/", "\\")
	}
	return p
}

// foldPath is the comparison key. Windows filesystems are case-insensitive,
// so the key is lower-cased there; elsewhere the path itself.
func foldPath(p string) string {
	if runtime.GOOS == "windows" {
		return strings.ToLower(p)
	}
	return p
}

// isUnder reports whether path is root or inside it.
func isUnder(root, path string) bool {
	r, p := foldPath(root), foldPath(path)
	if r == p {
		return true
	}
	if !strings.HasSuffix(r, string(filepath.Separator)) {
		r += string(filepath.Separator)
	}
	return strings.HasPrefix(p, r)
}

// prefixPattern is a LIKE pattern matching everything strictly inside dir.
func prefixPattern(dir string) string {
	p := foldPath(dir)
	if !strings.HasSuffix(p, string(filepath.Separator)) {
		p += string(filepath.Separator)
	}
	return escapeLike(p) + "%"
}

func escapeLike(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return r.Replace(s)
}

var foldT = transform.Chain(norm.NFD, runes.Remove(runes.In(unicode.Mn)), norm.NFC)

// fold lower-cases and strips diacritics so "Dvořák" matches "dvorak".
func fold(s string) string {
	out, _, err := transform.String(foldT, s)
	if err != nil {
		out = s
	}
	return strings.ToLower(out)
}

// skipDir names directories never indexed.
func skipDir(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	switch strings.ToLower(name) {
	case "$recycle.bin", "system volume information", "@eadir", "#recycle", "lost+found":
		return true
	}
	return false
}
