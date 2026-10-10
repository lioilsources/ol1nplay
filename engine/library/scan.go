package library

import (
	"database/sql"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/ol1n/ol1nplay/engine/library/cue"
	"github.com/ol1n/ol1nplay/engine/library/m3u"
	"github.com/ol1n/ol1nplay/engine/meta"
	"github.com/ol1n/ol1nplay/engine/protocol"
)

// Rescan re-indexes dir (recursively) or, when dir is empty, every root.
// It returns when the scan has finished.
func (l *Library) Rescan(dir string) error {
	if dir == "" {
		for _, r := range l.rootPaths() {
			l.scanRoot(r)
		}
		return nil
	}
	dir = cleanPath(dir)
	root := l.rootOf(dir)
	if root == "" {
		return ErrNotFound
	}
	if root == dir {
		l.scanRoot(root)
		return nil
	}
	l.scanTree(root, dir, nil)
	return nil
}

func (l *Library) scanRootAsync(root string) {
	l.wg.Add(1)
	go func() {
		defer l.wg.Done()
		l.scanRoot(root)
	}()
}

// scanRoot is a full incremental scan of one root. Directories that
// disappeared are purged afterwards; everything else is handled per
// directory by indexDir, which only re-probes changed files.
func (l *Library) scanRoot(root string) {
	l.mu.Lock()
	if l.scanning[root] {
		l.mu.Unlock()
		return
	}
	l.scanning[root] = true
	l.mu.Unlock()
	defer func() {
		l.mu.Lock()
		delete(l.scanning, root)
		l.mu.Unlock()
	}()
	if _, err := os.Stat(root); err != nil {
		l.logf("warn", "root missing, keeping cache: %s", root)
		return
	}
	seen := map[string]bool{}
	l.scanTree(root, root, seen)
	if l.ctx.Err() != nil {
		return
	}
	// Purge directories that vanished while we were not watching.
	known, _ := l.db.dirsUnder(root)
	for _, d := range known {
		if !seen[foldPath(d)] {
			if err := l.db.deleteTree(d); err == nil {
				l.opt.OnChange(protocol.LibraryChange{Dir: d, Reason: "scan", Removed: true})
			}
		}
	}
	_ = l.db.touchRoot(root)
}

// scanTree indexes start and everything below it. seen (optional) collects
// folded dir paths for the purge step.
func (l *Library) scanTree(root, start string, seen map[string]bool) {
	var dirs []string
	var total int
	_ = filepath.WalkDir(start, func(p string, d fs.DirEntry, err error) error {
		if l.ctx.Err() != nil {
			return filepath.SkipAll
		}
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if p != start && skipDir(d.Name()) {
				return filepath.SkipDir
			}
			dirs = append(dirs, p)
			if seen != nil {
				seen[foldPath(p)] = true
			}
			return nil
		}
		if meta.IsAudio(p) {
			total++
		}
		return nil
	})
	prog := &progress{l: l, root: root, total: total}
	prog.emit("", false)

	// One worker per CPU; each worker handles whole directories so that
	// cover resolution and the dir row happen once per directory.
	var wg sync.WaitGroup
	ch := make(chan string)
	for i := 0; i < l.opt.Concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for d := range ch {
				if l.ctx.Err() != nil {
					continue
				}
				l.indexDir(root, d, prog)
			}
		}()
	}
	for _, d := range dirs {
		ch <- d
	}
	close(ch)
	wg.Wait()
	prog.emit("", true)
}

// progress throttles ScanProgress events to ~10/s.
type progress struct {
	l     *Library
	root  string
	total int
	done  atomic.Int64
	mu    sync.Mutex
	last  time.Time
}

func (p *progress) step(current string) {
	n := p.done.Add(1)
	p.mu.Lock()
	defer p.mu.Unlock()
	if time.Since(p.last) < 100*time.Millisecond && int(n) < p.total {
		return
	}
	p.last = time.Now()
	p.l.opt.OnScan(protocol.ScanProgress{Root: p.root, Done: int(n), Total: p.total, Current: current})
}

func (p *progress) emit(current string, finished bool) {
	p.l.opt.OnScan(protocol.ScanProgress{Root: p.root, Done: int(p.done.Load()), Total: p.total, Current: current, Finished: finished})
}

// dirEntryInfo is what one ReadDir yields.
type dirEntryInfo struct {
	audio     []fileStamp
	images    []string
	cues      []fileStamp
	playlists []fileStamp
	subdirs   []string
}

type fileStamp struct {
	path  string
	size  int64
	mtime int64
}

func readDirInfo(dir string) (dirEntryInfo, error) {
	var info dirEntryInfo
	ents, err := os.ReadDir(dir)
	if err != nil {
		return info, err
	}
	for _, e := range ents {
		p := filepath.Join(dir, e.Name())
		if e.IsDir() {
			if !skipDir(e.Name()) {
				info.subdirs = append(info.subdirs, p)
			}
			continue
		}
		if strings.HasPrefix(e.Name(), ".") {
			continue
		}
		fi, err := e.Info()
		if err != nil {
			continue
		}
		st := fileStamp{p, fi.Size(), fi.ModTime().UnixMilli()}
		switch {
		case meta.IsAudio(p):
			info.audio = append(info.audio, st)
		case meta.IsImage(p):
			info.images = append(info.images, p)
		case meta.IsCue(p):
			info.cues = append(info.cues, st)
		case meta.IsPlaylist(p):
			info.playlists = append(info.playlists, st)
		}
	}
	sort.Slice(info.images, func(i, j int) bool { return naturalLess(info.images[i], info.images[j]) })
	return info, nil
}

// indexDir brings one directory (non-recursive) in sync with the disk.
// prog may be nil (watcher path).
func (l *Library) indexDir(root, dir string, prog *progress) {
	info, err := readDirInfo(dir)
	if err != nil {
		if os.IsNotExist(err) {
			if err := l.db.deleteTree(dir); err == nil {
				l.opt.OnChange(protocol.LibraryChange{Dir: dir, Reason: "scan", Removed: true})
			}
		}
		return
	}
	stamps, err := l.db.stampsIn(dir)
	if err != nil {
		l.logf("error", "stamps %s: %v", dir, err)
		return
	}

	// Directory cover from files comes first; it wins over embedded art.
	dirCover := l.covers.fromDir(dir, info.images)

	type probed struct {
		st    fileStamp
		m     *meta.Meta
		cover string
	}
	results := make([]probed, len(info.audio))
	var wg sync.WaitGroup
	present := map[string]bool{}
	for i, st := range info.audio {
		present[foldPath(st.path)] = true
		old, ok := stamps[foldPath(st.path)]
		if ok && old.Size == st.size && old.MTime == st.mtime {
			// Unchanged – but the directory cover may have appeared/changed.
			if dirCover != "" && old.Cover != dirCover {
				results[i] = probed{st: st, cover: dirCover}
			}
			if prog != nil {
				prog.step(st.path)
			}
			continue
		}
		wg.Add(1)
		l.sem <- struct{}{}
		go func(i int, st fileStamp) {
			defer wg.Done()
			defer func() { <-l.sem }()
			m, err := l.opt.Prober.Probe(st.path)
			if err != nil {
				l.logf("warn", "probe %s: %v", st.path, err)
				m = &meta.Meta{}
			}
			cover := dirCover
			if cover == "" && len(m.Picture) > 0 {
				cover = l.covers.fromBytes(st.path, st.size, st.mtime, m.Picture)
			}
			m.Picture = nil
			results[i] = probed{st: st, m: m, cover: cover}
			if prog != nil {
				prog.step(st.path)
			}
		}(i, st)
	}
	wg.Wait()
	if l.ctx.Err() != nil {
		return
	}

	// CUE sheets: re-parse when changed. Sample rates are resolved at List
	// time from the referenced track, so the sheet only stores CD frames.
	cueStamps, _ := l.db.cueStamps(dir)
	type cueParsed struct {
		row    cueRow
		tracks []cueTrackRow
	}
	var cues []cueParsed
	cuePresent := map[string]bool{}
	for _, st := range info.cues {
		cuePresent[foldPath(st.path)] = true
		if old, ok := cueStamps[foldPath(st.path)]; ok && old.Size == st.size && old.MTime == st.mtime {
			continue
		}
		sh, err := cue.Parse(st.path)
		if err != nil {
			l.logf("warn", "cue %s: %v", st.path, err)
			continue
		}
		cp := cueParsed{row: cueRow{Path: st.path, Title: sh.Title, Performer: sh.Performer, Genre: sh.Genre, Date: sh.Date, Size: st.size, MTime: st.mtime}}
		for _, t := range sh.Tracks {
			if _, err := os.Stat(t.File); err != nil {
				continue // sheet references a file that is not here
			}
			cp.tracks = append(cp.tracks, cueTrackRow{No: t.Number, Title: t.Title, Performer: t.Performer, File: cleanPath(t.File), StartCD: t.StartCDFrames, EndCD: t.EndCDFrames})
		}
		cues = append(cues, cp)
	}

	// Playlists found next to the music.
	oldPlaylists, _ := l.db.playlistsIn(dir)
	type plParsed struct {
		path  string
		count int
	}
	var pls []plParsed
	plPresent := map[string]bool{}
	for _, st := range info.playlists {
		plPresent[foldPath(st.path)] = true
		n := 0
		if ents, err := m3u.Read(st.path); err == nil {
			n = len(ents)
		}
		pls = append(pls, plParsed{st.path, n})
	}

	// Pick the dir cover: file cover, else the first embedded one we know.
	finalCover := dirCover
	if finalCover == "" {
		for _, r := range results {
			if r.cover != "" {
				finalCover = r.cover
				break
			}
		}
		if finalCover == "" {
			for _, st := range info.audio {
				if s, ok := stamps[foldPath(st.path)]; ok && s.Cover != "" {
					finalCover = s.Cover
					break
				}
			}
		}
	}

	err = l.db.tx(func(tx *sql.Tx) error {
		for _, r := range results {
			if r.st.path == "" {
				continue
			}
			if r.m == nil {
				if err := l.db.setTrackCover(tx, r.st.path, r.cover); err != nil {
					return err
				}
				continue
			}
			if err := l.db.upsertTrack(tx, r.st.path, r.m, r.st.size, r.st.mtime, r.cover); err != nil {
				return err
			}
		}
		for p := range stamps {
			if !present[p] {
				if err := l.db.deleteTrack(tx, p); err != nil {
					return err
				}
			}
		}
		for _, c := range cues {
			if err := l.db.putCue(tx, c.row, c.tracks); err != nil {
				return err
			}
		}
		for p, c := range cueStamps {
			if !cuePresent[p] {
				if err := l.db.deleteCue(tx, c.Path); err != nil {
					return err
				}
			}
		}
		for _, p := range pls {
			if err := l.db.putPlaylist(tx, p.path, p.count); err != nil {
				return err
			}
		}
		for _, p := range oldPlaylists {
			if !plPresent[foldPath(p)] {
				if err := l.db.deletePlaylist(tx, p); err != nil {
					return err
				}
			}
		}
		return l.db.upsertDir(tx, dir, root, len(info.subdirs) > 0, len(info.audio), finalCover)
	})
	if err != nil {
		l.logf("error", "index %s: %v", dir, err)
		return
	}
	l.opt.OnChange(protocol.LibraryChange{Dir: dir, Reason: "scan"})
}
