package library

import (
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

// watcher turns fsnotify events into per-directory re-index jobs.
//
// Events arrive in bursts (a tagger rewriting an album touches every file
// several times; a copy emits create + many writes), so each directory has
// a 500 ms quiet-period timer: the directory is re-indexed once, after the
// burst. Only the touched directory is re-read – never the whole tree –
// except when a new directory appears, which is walked once to add watches.
//
// Windows: fsnotify uses ReadDirectoryChangesW with a per-watch buffer. When
// a burst overflows it, fsnotify delivers an error ("short read" /
// ERROR_NOTIFY_ENUM_DIR) and we cannot know what changed, so the whole root
// is rescanned – the incremental scan makes that cheap.
type watcher struct {
	l  *Library
	fw *fsnotify.Watcher

	mu      sync.Mutex
	timers  map[string]*time.Timer
	watched map[string]bool
	closed  bool
	jobs    sync.WaitGroup // running fire() calls
	done    chan struct{}
}

func newWatcher(l *Library) (*watcher, error) {
	fw, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	w := &watcher{l: l, fw: fw, timers: map[string]*time.Timer{}, watched: map[string]bool{}, done: make(chan struct{})}
	go w.loop()
	return w, nil
}

func (w *watcher) close() {
	w.fw.Close()
	<-w.done
	w.mu.Lock()
	w.closed = true
	for _, t := range w.timers {
		t.Stop()
	}
	w.mu.Unlock()
	w.jobs.Wait()
}

// addTree watches dir and every subdirectory.
func (w *watcher) addTree(dir string) {
	_ = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() {
			return nil
		}
		if p != dir && skipDir(d.Name()) {
			return filepath.SkipDir
		}
		w.add(p)
		return nil
	})
}

func (w *watcher) add(dir string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.watched[foldPath(dir)] {
		return
	}
	if err := w.fw.Add(dir); err != nil {
		w.l.logf("warn", "watch %s: %v", dir, err)
		return
	}
	w.watched[foldPath(dir)] = true
}

func (w *watcher) removeTree(dir string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	for p := range w.watched {
		if isUnder(dir, p) {
			_ = w.fw.Remove(p)
			delete(w.watched, p)
		}
	}
}

func (w *watcher) loop() {
	defer close(w.done)
	for {
		select {
		case ev, ok := <-w.fw.Events:
			if !ok {
				return
			}
			w.handle(ev)
		case err, ok := <-w.fw.Errors:
			if !ok {
				return
			}
			w.l.logf("warn", "fsnotify: %v (rescanning roots)", err)
			for _, r := range w.l.rootPaths() {
				w.l.scanRootAsync(r)
			}
		}
	}
}

func (w *watcher) handle(ev fsnotify.Event) {
	name := cleanPath(ev.Name)
	parent := filepath.Dir(name)
	if ev.Has(fsnotify.Create) {
		if fi, err := os.Stat(name); err == nil && fi.IsDir() {
			if !skipDir(filepath.Base(name)) {
				// A moved-in tree needs watches and a walk of its own.
				w.addTree(name)
				w.scheduleTree(name)
			}
		}
	}
	if ev.Has(fsnotify.Remove) || ev.Has(fsnotify.Rename) {
		// A removed directory: fsnotify cannot tell us; the cache can.
		if w.l.db.dirExists(name) {
			w.mu.Lock()
			for p := range w.watched {
				if isUnder(name, p) {
					_ = w.fw.Remove(p)
					delete(w.watched, p)
				}
			}
			w.mu.Unlock()
			w.schedule(name, false)
		}
	}
	w.schedule(parent, false)
}

// schedule (re)arms the debounce timer for dir.
func (w *watcher) schedule(dir string, tree bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	key := foldPath(dir)
	if tree {
		key += "\x00tree"
	}
	if t, ok := w.timers[key]; ok {
		t.Reset(w.l.opt.Debounce)
		return
	}
	w.timers[key] = time.AfterFunc(w.l.opt.Debounce, func() {
		w.mu.Lock()
		delete(w.timers, key)
		w.mu.Unlock()
		w.fire(dir, tree)
	})
}

func (w *watcher) scheduleTree(dir string) { w.schedule(dir, true) }

func (w *watcher) fire(dir string, tree bool) {
	w.mu.Lock()
	if w.closed || w.l.ctx.Err() != nil {
		w.mu.Unlock()
		return
	}
	w.jobs.Add(1)
	w.mu.Unlock()
	defer w.jobs.Done()
	root := w.l.rootOf(dir)
	if root == "" {
		return
	}
	if tree {
		w.l.scanTree(root, dir, nil)
		return
	}
	// indexDir handles a vanished directory by purging it.
	w.l.indexDir(root, dir, nil)
	// New subdirectories created inside dir that we have not seen yet.
	if info, err := readDirInfo(dir); err == nil {
		for _, sd := range info.subdirs {
			if !w.l.db.dirExists(sd) {
				w.addTree(sd)
				w.l.scanTree(root, sd, nil)
			}
		}
	}
}
