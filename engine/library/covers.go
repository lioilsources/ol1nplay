package library

import (
	"bytes"
	"crypto/sha1"
	"encoding/hex"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"strings"
	"sync"

	_ "image/gif"
	_ "image/png"

	"golang.org/x/image/bmp"
	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp"

	"github.com/ol1n/ol1nplay/engine/meta"
)

const (
	coverSize = 512
	thumbSize = 96
)

// coverStore turns cover sources (files or embedded pictures) into cached
// JPEG thumbnails named by content hash. Hashing the *source bytes* means
// the same artwork embedded in twelve tracks of an album is encoded once and
// shares one file, and a re-tagged file with identical art keeps its hash.
type coverStore struct {
	l  *Library
	mu sync.Mutex // serialises encode of the same source across workers
}

func newCoverStore(l *Library) *coverStore { return &coverStore{l: l} }

func init() {
	image.RegisterFormat("bmp", "BM", bmp.Decode, bmp.DecodeConfig)
}

// CoverPath returns the 512 px thumbnail path for a hash.
func (l *Library) CoverPath(hash string) (string, bool) {
	if hash == "" || strings.ContainsAny(hash, `/\.`) {
		return "", false
	}
	p := filepath.Join(l.opt.CoverDir, hash+".jpg")
	if _, err := os.Stat(p); err != nil {
		return "", false
	}
	return p, true
}

// ThumbPath returns the 96 px thumbnail path for a hash.
func (l *Library) ThumbPath(hash string) (string, bool) {
	if hash == "" || strings.ContainsAny(hash, `/\.`) {
		return "", false
	}
	p := filepath.Join(l.opt.CoverDir, hash+"_t.jpg")
	if _, err := os.Stat(p); err != nil {
		return "", false
	}
	return p, true
}

// CoverFor returns the cover hash of a track ("" if none): the track's own
// (directory or embedded), falling back to its directory's.
func (l *Library) CoverFor(trackPath string) string {
	phys, _ := splitCuePath(trackPath)
	if t, err := l.db.track(phys); err == nil && t.Cover != "" {
		return t.Cover
	}
	if d, ok := l.db.dirRow(filepath.Dir(phys)); ok {
		return d.Cover
	}
	return ""
}

// fromDir picks the directory's cover file by the plan's priority:
// cover.* → folder.* → front.* → other known names → first image file.
func (c *coverStore) fromDir(dir string, images []string) string {
	if len(images) == 0 {
		return ""
	}
	pick := ""
	for _, name := range meta.CoverNames {
		for _, img := range images {
			base := strings.ToLower(strings.TrimSuffix(filepath.Base(img), filepath.Ext(img)))
			if base == name {
				pick = img
				break
			}
		}
		if pick != "" {
			break
		}
	}
	if pick == "" {
		pick = images[0]
	}
	fi, err := os.Stat(pick)
	if err != nil {
		return ""
	}
	if h, ok := c.l.db.coverBySource(pick, fi.Size(), fi.ModTime().UnixMilli()); ok {
		if _, exists := c.l.CoverPath(h); exists {
			return h
		}
	}
	data, err := os.ReadFile(pick)
	if err != nil {
		return ""
	}
	return c.encode(pick, fi.Size(), fi.ModTime().UnixMilli(), data)
}

// fromBytes caches an embedded picture; source identifies the track file so
// an unchanged track is never re-encoded.
func (c *coverStore) fromBytes(source string, size, mtime int64, data []byte) string {
	if h, ok := c.l.db.coverBySource(source, size, mtime); ok {
		if _, exists := c.l.CoverPath(h); exists {
			return h
		}
	}
	return c.encode(source, size, mtime, data)
}

func (c *coverStore) encode(source string, size, mtime int64, data []byte) string {
	sum := sha1.Sum(data)
	hash := hex.EncodeToString(sum[:])[:16]
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, exists := c.l.CoverPath(hash); exists && c.l.db.coverExists(hash) {
		_ = c.l.db.putCover(hash, source, size, mtime, 0, 0)
		return hash
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		c.l.logf("warn", "cover %s: %v", source, err)
		return ""
	}
	big := resize(img, coverSize)
	small := resize(img, thumbSize)
	if err := writeJPEG(filepath.Join(c.l.opt.CoverDir, hash+".jpg"), big); err != nil {
		c.l.logf("warn", "cover write: %v", err)
		return ""
	}
	if err := writeJPEG(filepath.Join(c.l.opt.CoverDir, hash+"_t.jpg"), small); err != nil {
		c.l.logf("warn", "thumb write: %v", err)
	}
	b := big.Bounds()
	if err := c.l.db.putCover(hash, source, size, mtime, b.Dx(), b.Dy()); err != nil {
		c.l.logf("warn", "cover db: %v", err)
	}
	return hash
}

// resize scales img so its longer side is max px (never upscales).
func resize(img image.Image, max int) *image.RGBA {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w > max || h > max {
		if w >= h {
			h = h * max / w
			w = max
		} else {
			w = w * max / h
			h = max
		}
	}
	if w < 1 {
		w = 1
	}
	if h < 1 {
		h = 1
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.CatmullRom.Scale(dst, dst.Bounds(), img, b, draw.Over, nil)
	return dst
}

func writeJPEG(path string, img image.Image) error {
	tmp := path + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if err := jpeg.Encode(f, img, &jpeg.Options{Quality: 85}); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}
