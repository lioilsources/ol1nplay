// Package meta is the tiny shared vocabulary between the decoder (which
// knows how to read a file) and the library (which caches what it read).
// It has no dependencies so both can import it.
package meta

import (
	"path/filepath"
	"strings"
)

// Meta is everything a probe learns about one audio file.
type Meta struct {
	Title       string
	Artist      string
	AlbumArtist string
	Album       string
	Genre       string
	Composer    string
	Comment     string
	TrackNo     int
	DiscNo      int
	Year        int

	Codec      string // "flac", "alac", "pcm_s24le", "mp3", "dsd_lsbf_planar", ...
	Container  string // libavformat iformat name
	SampleRate int
	BitDepth   int // meaningful bits; 0 for lossy or float
	Channels   int
	Bitrate    int // kbps, lossy only
	Lossless   bool
	DSD        bool
	DSDRate    int // DSD64 = 2822400
	DurationMs int64
	Samples    int64 // total frames, 0 if unknown

	ReplayGainTrack float64 // dB, displayed only
	Lyrics          string  // from tag (UNSYNCEDLYRICS / LYRICS / ©lyr)

	Picture     []byte // embedded front cover, raw encoded image
	PictureMime string
}

// Prober reads metadata without decoding audio.
type Prober interface {
	Probe(path string) (*Meta, error)
}

// AudioExts are the file extensions the library indexes (lower case, with dot).
var AudioExts = map[string]bool{
	".flac": true, ".wav": true, ".wv": true, ".ape": true, ".tak": true,
	".aif": true, ".aiff": true, ".aifc": true,
	".m4a": true, ".mp4": true, ".alac": true, ".caf": true,
	".mp3": true, ".mp2": true, ".aac": true, ".ogg": true, ".oga": true, ".opus": true,
	".dsf": true, ".dff": true,
	".mpc": true, ".tta": true, ".ofr": true, ".shn": true, ".wma": true,
}

// CoverNames is the cover-art file priority (base names, any image ext).
var CoverNames = []string{"cover", "folder", "front", "albumart", "album", "artwork"}

// ImageExts are recognised cover image extensions.
var ImageExts = map[string]bool{".jpg": true, ".jpeg": true, ".png": true, ".webp": true, ".bmp": true, ".gif": true}

// IsAudio reports whether path has an indexable extension.
func IsAudio(path string) bool { return AudioExts[strings.ToLower(filepath.Ext(path))] }

// IsImage reports whether path is a candidate cover file.
func IsImage(path string) bool { return ImageExts[strings.ToLower(filepath.Ext(path))] }

// IsCue reports a CUE sheet.
func IsCue(path string) bool { return strings.EqualFold(filepath.Ext(path), ".cue") }

// IsPlaylist reports an M3U / M3U8 file.
func IsPlaylist(path string) bool {
	e := strings.ToLower(filepath.Ext(path))
	return e == ".m3u" || e == ".m3u8"
}
