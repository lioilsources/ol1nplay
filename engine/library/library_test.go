package library

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ol1n/ol1nplay/engine/meta"
	"github.com/ol1n/ol1nplay/engine/protocol"
)

// fakeProber answers from the filename so tests need no real audio.
type fakeProber struct {
	mu     sync.Mutex
	probed []string
	pic    map[string][]byte // basename → embedded picture
}

func (f *fakeProber) Probe(path string) (*meta.Meta, error) {
	f.mu.Lock()
	f.probed = append(f.probed, path)
	f.mu.Unlock()
	base := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	m := &meta.Meta{
		Title: base, Artist: "Artist", Album: filepath.Base(filepath.Dir(path)),
		Codec: "flac", Container: "flac", SampleRate: 44100, BitDepth: 16, Channels: 2, Lossless: true,
		DurationMs: 30 * 60 * 1000, Samples: 30 * 60 * 44100,
	}
	if strings.HasPrefix(base, "Track ") {
		var n int
		if _, err := sscan(strings.TrimPrefix(base, "Track "), &n); err == nil {
			m.TrackNo = n
		}
	}
	if base == "Dvořák" {
		m.Title = "Symfonie č. 9 „Z Nového světa“"
		m.Lyrics = "[00:01.00]hello\n[00:02.00]world"
	}
	if p, ok := f.pic[filepath.Base(path)]; ok {
		m.Picture = p
		m.PictureMime = "image/png"
	}
	return m, nil
}

func (f *fakeProber) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.probed)
}

func sscan(s string, n *int) (int, error) {
	v := 0
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0, os.ErrInvalid
		}
		v = v*10 + int(r-'0')
	}
	*n = v
	return 1, nil
}

func pngBytes(c color.Color, size int) []byte {
	img := image.NewRGBA(image.Rect(0, 0, size, size))
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			img.Set(x, y, c)
		}
	}
	var b bytes.Buffer
	_ = png.Encode(&b, img)
	return b.Bytes()
}

func touch(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

type harness struct {
	root    string
	data    string
	prober  *fakeProber
	lib     *Library
	changes chan protocol.LibraryChange
}

func newHarness(t *testing.T, watch bool) *harness {
	t.Helper()
	base := t.TempDir()
	h := &harness{root: filepath.Join(base, "Music"), data: filepath.Join(base, "data"), changes: make(chan protocol.LibraryChange, 256)}
	h.prober = &fakeProber{pic: map[string][]byte{"Track 1.flac": pngBytes(color.RGBA{255, 0, 0, 255}, 800)}}

	// Album A: cover.jpg wins over folder.png and embedded art.
	touch(t, filepath.Join(h.root, "A", "Track 1.flac"), []byte("x"))
	touch(t, filepath.Join(h.root, "A", "Track 2.flac"), []byte("xx"))
	touch(t, filepath.Join(h.root, "A", "Track 10.flac"), []byte("xxx"))
	touch(t, filepath.Join(h.root, "A", "folder.png"), pngBytes(color.RGBA{0, 255, 0, 255}, 10))
	touch(t, filepath.Join(h.root, "A", "cover.png"), pngBytes(color.RGBA{0, 0, 255, 255}, 1024))
	// Album B: only a random image.
	touch(t, filepath.Join(h.root, "B", "Dvořák.flac"), []byte("y"))
	touch(t, filepath.Join(h.root, "B", "scan001.png"), pngBytes(color.RGBA{9, 9, 9, 255}, 20))
	touch(t, filepath.Join(h.root, "B", "Dvořák.lrc"), []byte("[00:05.00]sidecar"))
	// Album C: CUE sheet over one big file.
	cueSrc, err := os.ReadFile(filepath.Join("testdata", "album.cue"))
	if err != nil {
		t.Fatal(err)
	}
	touch(t, filepath.Join(h.root, "C", "album.cue"), cueSrc)
	touch(t, filepath.Join(h.root, "C", "Kind of Blue.flac"), []byte("z"))
	touch(t, filepath.Join(h.root, "C", "list.m3u8"), []byte("#EXTM3U\nKind of Blue.flac\n../A/Track 1.flac\n"))
	// Hidden / skipped.
	touch(t, filepath.Join(h.root, ".hidden", "no.flac"), []byte("n"))

	lib, err := Open(context.Background(), Options{
		DBPath:   filepath.Join(h.data, "library.db"),
		CoverDir: filepath.Join(h.data, "covers"),
		DataDir:  h.data,
		Prober:   h.prober,
		Roots:    []string{h.root},
		NoWatch:  !watch,
		Debounce: 150 * time.Millisecond,
		OnChange: func(c protocol.LibraryChange) {
			select {
			case h.changes <- c:
			default:
			}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	lib.Wait()
	h.lib = lib
	t.Cleanup(lib.Close)
	return h
}

func TestScanListSearch(t *testing.T) {
	h := newHarness(t, false)
	lib := h.lib

	roots := lib.Roots()
	if len(roots) != 1 || roots[0].Tracks != 5 || roots[0].Missing {
		t.Fatalf("roots: %+v", roots)
	}
	if h.prober.count() != 5 {
		t.Fatalf("probed %d files, want 5 (hidden dir must be skipped)", h.prober.count())
	}

	top := lib.Tree("")
	if len(top) != 1 || !top[0].HasDirs {
		t.Fatalf("tree root: %+v", top)
	}
	kids := lib.Tree(h.root)
	if len(kids) != 3 || kids[0].Name != "A" || kids[2].Name != "C" || kids[0].Tracks != 3 {
		t.Fatalf("tree: %+v", kids)
	}

	a, err := lib.List(filepath.Join(h.root, "A"))
	if err != nil {
		t.Fatal(err)
	}
	if a.Parent != h.root {
		t.Fatalf("parent %q", a.Parent)
	}
	names := []string{}
	for _, tr := range a.Tracks {
		names = append(names, tr.FileName)
	}
	if strings.Join(names, ",") != "Track 1.flac,Track 2.flac,Track 10.flac" {
		t.Fatalf("order: %v", names)
	}
	if a.Tracks[0].Title != "Track 1" || !a.Tracks[0].Lossless || a.Tracks[0].SampleRate != 44100 {
		t.Fatalf("meta: %+v", a.Tracks[0])
	}

	// Natural sort without tags.
	if !naturalLess("Track 2", "Track 10") || naturalLess("b", "a") || !naturalLess("01 x", "2 y") {
		t.Fatal("naturalLess")
	}

	// Search: folded, ranked.
	hits := lib.Search("dvorak", 10)
	if len(hits) != 1 || hits[0].FileName != "Dvořák.flac" {
		t.Fatalf("search dvorak: %+v", hits)
	}
	hits = lib.Search("SYMFONIE", 10)
	if len(hits) != 1 {
		t.Fatalf("search title: %+v", hits)
	}
	hits = lib.Search("track", 10)
	if len(hits) != 3 || hits[0].Title != "Track 1" {
		t.Fatalf("search prefix rank: %+v", hits)
	}
	if lib.Search("   ", 10) != nil {
		t.Fatal("empty search")
	}

	tr, err := lib.Track(filepath.Join(h.root, "B", "Dvořák.flac"))
	if err != nil || !tr.HasLyrics {
		t.Fatalf("track: %+v %v", tr, err)
	}
	if _, err := lib.Track(filepath.Join(h.root, "nope.flac")); err != ErrNotFound {
		t.Fatalf("missing track err %v", err)
	}
}

func TestCoverPriority(t *testing.T) {
	h := newHarness(t, false)
	lib := h.lib

	a, _ := lib.List(filepath.Join(h.root, "A"))
	if a.Cover == "" {
		t.Fatal("A has no cover")
	}
	// cover.png (blue, 1024px) must win: thumbnail is 512 px and blue.
	p, ok := lib.CoverPath(a.Cover)
	if !ok {
		t.Fatal("cover file missing")
	}
	f, _ := os.Open(p)
	img, _, err := image.Decode(f)
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	if img.Bounds().Dx() != 512 {
		t.Fatalf("thumb width %d", img.Bounds().Dx())
	}
	r, g, b, _ := img.At(100, 100).RGBA()
	if !(b > r && b > g) {
		t.Fatalf("cover.png should win (blue), got rgb %d %d %d", r>>8, g>>8, b>>8)
	}
	if _, ok := lib.ThumbPath(a.Cover); !ok {
		t.Fatal("96px thumb missing")
	}
	for _, tr := range a.Tracks {
		if tr.Cover != a.Cover {
			t.Fatalf("track cover %q != dir cover %q", tr.Cover, a.Cover)
		}
	}

	// B: first image file (scan001.png).
	b2, _ := lib.List(filepath.Join(h.root, "B"))
	if b2.Cover == "" || b2.Cover == a.Cover {
		t.Fatalf("B cover %q", b2.Cover)
	}

	// C: no image file, no embedded → none.
	c, _ := lib.List(filepath.Join(h.root, "C"))
	if c.Cover != "" {
		t.Fatalf("C cover %q", c.Cover)
	}

	// Embedded: remove A's image files, re-probe → Track 1's embedded red art.
	os.Remove(filepath.Join(h.root, "A", "cover.png"))
	os.Remove(filepath.Join(h.root, "A", "folder.png"))
	// force re-probe by touching the file
	touch(t, filepath.Join(h.root, "A", "Track 1.flac"), []byte("changed!"))
	if err := lib.Rescan(filepath.Join(h.root, "A")); err != nil {
		t.Fatal(err)
	}
	a, _ = lib.List(filepath.Join(h.root, "A"))
	if a.Cover == "" || a.Cover == b2.Cover {
		t.Fatalf("embedded cover not used: %q", a.Cover)
	}
	p, _ = lib.CoverPath(a.Cover)
	f, _ = os.Open(p)
	img, _, _ = image.Decode(f)
	f.Close()
	r, g, b, _ = img.At(10, 10).RGBA()
	if !(r > g && r > b) {
		t.Fatalf("embedded should be red, got %d %d %d", r>>8, g>>8, b>>8)
	}
	if lib.CoverFor(filepath.Join(h.root, "A", "Track 1.flac")) != a.Cover {
		t.Fatal("CoverFor")
	}

	// Same bytes → same hash, not re-encoded (one file in covers dir per hash).
	ents, _ := os.ReadDir(filepath.Join(h.data, "covers"))
	seen := map[string]int{}
	for _, e := range ents {
		seen[e.Name()]++
	}
	for n, c := range seen {
		if c != 1 {
			t.Fatalf("dup %s", n)
		}
	}
}

func TestIncrementalProbe(t *testing.T) {
	h := newHarness(t, false)
	before := h.prober.count()
	if err := h.lib.Rescan(""); err != nil {
		t.Fatal(err)
	}
	if h.prober.count() != before {
		t.Fatalf("unchanged files were re-probed: %d → %d", before, h.prober.count())
	}
	touch(t, filepath.Join(h.root, "A", "Track 2.flac"), []byte("different size"))
	_ = h.lib.Rescan("")
	if h.prober.count() != before+1 {
		t.Fatalf("changed file not re-probed: %d → %d", before, h.prober.count())
	}
	// Vanished file and directory.
	os.RemoveAll(filepath.Join(h.root, "B"))
	os.Remove(filepath.Join(h.root, "A", "Track 10.flac"))
	_ = h.lib.Rescan("")
	if _, err := h.lib.List(filepath.Join(h.root, "B")); err != ErrNotFound {
		t.Fatalf("B should be gone: %v", err)
	}
	a, _ := h.lib.List(filepath.Join(h.root, "A"))
	if len(a.Tracks) != 2 {
		t.Fatalf("A tracks %d", len(a.Tracks))
	}
	if r := h.lib.Roots(); r[0].Tracks != 3 {
		t.Fatalf("root tracks %d", r[0].Tracks)
	}
}

func TestCueExpansion(t *testing.T) {
	h := newHarness(t, false)
	c, err := h.lib.List(filepath.Join(h.root, "C"))
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Cue) != 1 || len(c.Tracks) != 3 {
		t.Fatalf("cue: %d sheets, %d tracks", len(c.Cue), len(c.Tracks))
	}
	phys := filepath.Join(h.root, "C", "Kind of Blue.flac")
	for _, tr := range c.Tracks {
		if tr.Path == phys {
			t.Fatal("physical file must be hidden behind the CUE")
		}
	}
	t2 := c.Tracks[1]
	if t2.Path != phys+"#2" || t2.Title != "Freddie Freeloader" || t2.Album != "Kind of Blue" || t2.Artist != "Miles Davis" || t2.Year != 1959 || t2.Genre != "Jazz" {
		t.Fatalf("t2: %+v", t2)
	}
	if t2.CueStart != (9*60+22)*44100 || t2.CueEnd != (19*60+8)*44100 || t2.Samples != t2.CueEnd-t2.CueStart {
		t.Fatalf("t2 offsets: start %d end %d samples %d", t2.CueStart, t2.CueEnd, t2.Samples)
	}
	t3 := c.Tracks[2]
	if t3.CueEnd != 0 || t3.Samples != 30*60*44100-t3.CueStart {
		t.Fatalf("t3: %+v", t3)
	}
	got, err := h.lib.Track(phys + "#3")
	if err != nil || got.Title != "Blue in Green" || got.CueFile == "" {
		t.Fatalf("Track(virtual): %+v %v", got, err)
	}
}

func TestPlaylistsLyricsFavoritesHistory(t *testing.T) {
	h := newHarness(t, false)
	lib := h.lib

	pls := lib.Playlists()
	if len(pls) != 1 || pls[0].Name != "list" || pls[0].Count != 2 {
		t.Fatalf("playlists: %+v", pls)
	}
	tracks, err := lib.LoadPlaylist(pls[0].Path)
	if err != nil || len(tracks) != 2 || tracks[1].Title != "Track 1" {
		t.Fatalf("load: %+v %v", tracks, err)
	}
	saved, err := lib.SavePlaylist("My: Mix", []string{tracks[1].Path, filepath.Join(h.root, "unknown.flac")})
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(saved) != "My_ Mix.m3u8" {
		t.Fatalf("saved name %q", saved)
	}
	back, _ := lib.LoadPlaylist(saved)
	if len(back) != 2 || back[0].Path != tracks[1].Path || back[1].Title != "unknown" {
		t.Fatalf("round trip: %+v", back)
	}
	if n := len(lib.Playlists()); n != 2 {
		t.Fatalf("playlists after save: %d", n)
	}

	// Lyrics: sidecar beats tag.
	dv := filepath.Join(h.root, "B", "Dvořák.flac")
	ly := lib.Lyrics(dv)
	if ly == nil || ly.Source != "lrc" || len(ly.Lines) != 1 || ly.Lines[0].Text != "sidecar" {
		t.Fatalf("lyrics: %+v", ly)
	}
	os.Remove(filepath.Join(h.root, "B", "Dvořák.lrc"))
	ly = lib.Lyrics(dv)
	if ly == nil || ly.Source != "lrc" || len(ly.Lines) != 2 || ly.Lines[1].Text != "world" {
		t.Fatalf("tag lyrics: %+v", ly)
	}
	if lib.Lyrics(filepath.Join(h.root, "A", "Track 2.flac")) != nil {
		t.Fatal("no lyrics expected")
	}

	// Favorites and history.
	if err := lib.AddFavorite(dv); err != nil {
		t.Fatal(err)
	}
	if fav := lib.Favorites(); len(fav) != 1 || fav[0].Path != dv || !fav[0].Favorite {
		t.Fatalf("favorites: %+v", fav)
	}
	if tr, _ := lib.Track(dv); !tr.Favorite {
		t.Fatal("Track should carry Favorite")
	}
	_ = lib.RemoveFavorite(dv)
	if len(lib.Favorites()) != 0 {
		t.Fatal("remove favorite")
	}
	cueT := filepath.Join(h.root, "C", "Kind of Blue.flac") + "#2"
	_ = lib.RecordPlay(dv, true)
	_ = lib.RecordPlay(cueT, false)
	hist := lib.History(10)
	if len(hist) != 2 || hist[0].Track.Path != cueT || hist[0].Complete || hist[1].Track.Path != dv || !hist[1].Complete {
		t.Fatalf("history: %+v", hist)
	}
	if tr, _ := lib.Track(dv); tr.PlayCount != 1 || tr.LastPlayed == 0 {
		t.Fatalf("play count: %+v", tr)
	}
}

func TestRootsAddRemoveMissing(t *testing.T) {
	h := newHarness(t, false)
	other := filepath.Join(filepath.Dir(h.root), "Other")
	touch(t, filepath.Join(other, "x.flac"), []byte("o"))
	if err := h.lib.AddRoot(other); err != nil {
		t.Fatal(err)
	}
	h.lib.Wait()
	if r := h.lib.Roots(); len(r) != 2 {
		t.Fatalf("roots %+v", r)
	}
	if l, err := h.lib.List(other); err != nil || len(l.Tracks) != 1 {
		t.Fatalf("other list: %+v %v", l, err)
	}
	// Unplugged drive: still listed, flagged, cache intact.
	os.RemoveAll(other)
	r := h.lib.Roots()
	var o protocol.Root
	for _, x := range r {
		if x.Path == other {
			o = x
		}
	}
	if !o.Missing || o.Tracks != 1 {
		t.Fatalf("missing root: %+v", o)
	}
	_ = h.lib.Rescan("")
	if l, err := h.lib.List(other); err != nil || len(l.Tracks) != 1 {
		t.Fatalf("missing root must keep its cache: %v", err)
	}
	if err := h.lib.RemoveRoot(other); err != nil {
		t.Fatal(err)
	}
	if _, err := h.lib.List(other); err != ErrNotFound {
		t.Fatal("removed root still listed")
	}
	if err := h.lib.AddRoot(filepath.Join(h.root, "nonexistent")); err == nil {
		t.Fatal("adding a missing dir must fail")
	}
}

func waitChange(t *testing.T, h *harness, dir string, timeout time.Duration) protocol.LibraryChange {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case c := <-h.changes:
			if foldPath(c.Dir) == foldPath(dir) && c.Reason == "scan" {
				return c
			}
		case <-deadline:
			t.Fatalf("no change event for %s", dir)
		}
	}
}

func TestWatch(t *testing.T) {
	h := newHarness(t, true)
	// drain initial scan events
	for len(h.changes) > 0 {
		<-h.changes
	}
	dirA := filepath.Join(h.root, "A")

	// New file in a watched directory.
	touch(t, filepath.Join(dirA, "Track 3.flac"), []byte("new"))
	waitChange(t, h, dirA, 5*time.Second)
	a, _ := h.lib.List(dirA)
	if len(a.Tracks) != 4 {
		t.Fatalf("after create: %d tracks", len(a.Tracks))
	}

	// New directory tree.
	dirD := filepath.Join(h.root, "D", "deep")
	touch(t, filepath.Join(dirD, "Track 1.flac"), []byte("d"))
	waitChange(t, h, dirD, 5*time.Second)
	if l, err := h.lib.List(dirD); err != nil || len(l.Tracks) != 1 {
		t.Fatalf("new tree: %+v %v", l, err)
	}
	// And a file added later inside the new tree must be seen (watch added).
	for len(h.changes) > 0 {
		<-h.changes
	}
	touch(t, filepath.Join(dirD, "Track 2.flac"), []byte("dd"))
	waitChange(t, h, dirD, 5*time.Second)
	if l, _ := h.lib.List(dirD); len(l.Tracks) != 2 {
		t.Fatalf("new tree watch: %d", len(l.Tracks))
	}

	// Removal of a file.
	os.Remove(filepath.Join(dirA, "Track 3.flac"))
	waitChange(t, h, dirA, 5*time.Second)
	if a, _ := h.lib.List(dirA); len(a.Tracks) != 3 {
		t.Fatalf("after remove: %d", len(a.Tracks))
	}

	// Removal of a directory.
	os.RemoveAll(filepath.Join(h.root, "D"))
	deadline := time.After(5 * time.Second)
	for {
		select {
		case c := <-h.changes:
			if c.Removed && foldPath(c.Dir) == foldPath(filepath.Join(h.root, "D")) {
				goto removed
			}
		case <-deadline:
			t.Fatal("no removal event for D")
		}
	}
removed:
	if _, err := h.lib.List(dirD); err != ErrNotFound {
		t.Fatal("deep dir should be purged")
	}
}
