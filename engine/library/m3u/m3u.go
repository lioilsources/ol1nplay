// Package m3u reads and writes M3U / M3U8 playlists.
//
// Reading is deliberately forgiving: a playlist is just a list of paths,
// and users drag them between machines, so relative entries are resolved
// against the playlist's own directory and both slash styles are accepted.
// Writing always produces UTF-8 M3U8 with #EXTINF so other players keep the
// titles.
package m3u

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding/charmap"
)

// Entry is one playlist line.
type Entry struct {
	Path     string // absolute
	Title    string // from #EXTINF, may be empty
	Duration int    // seconds from #EXTINF, -1 unknown
}

// Read parses a playlist file. `.m3u8` is always UTF-8; `.m3u` is tried as
// UTF-8 first and falls back to Windows-1250 (Central European, the
// author's locale) – a wrong guess only mangles titles, never paths, when
// paths are ASCII.
func Read(path string) ([]Entry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Parse(path, data)
}

// Parse decodes playlist bytes; path is used for relative resolution and
// for the UTF-8 / legacy decision.
func Parse(path string, data []byte) ([]Entry, error) {
	data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})
	if !utf8.Valid(data) && !strings.EqualFold(filepath.Ext(path), ".m3u8") {
		if d, err := charmap.Windows1250.NewDecoder().Bytes(data); err == nil {
			data = d
		}
	}
	dir := filepath.Dir(path)
	var out []Entry
	pending := Entry{Duration: -1}
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "#") {
			if strings.HasPrefix(strings.ToUpper(line), "#EXTINF:") {
				body := line[len("#EXTINF:"):]
				dur, title, _ := strings.Cut(body, ",")
				pending.Title = strings.TrimSpace(title)
				pending.Duration = -1
				fmt.Sscanf(strings.TrimSpace(dur), "%d", &pending.Duration)
			}
			continue
		}
		p := strings.ReplaceAll(line, "\\", string(filepath.Separator))
		p = strings.ReplaceAll(p, "/", string(filepath.Separator))
		if strings.HasPrefix(line, "file://") {
			p = strings.TrimPrefix(line, "file://")
		}
		if !filepath.IsAbs(p) {
			p = filepath.Join(dir, p)
		}
		pending.Path = filepath.Clean(p)
		out = append(out, pending)
		pending = Entry{Duration: -1}
	}
	return out, sc.Err()
}

// Write stores entries as UTF-8 M3U8 (absolute paths, #EXTINF when a title
// is known).
func Write(path string, entries []Entry) error {
	var b strings.Builder
	b.WriteString("#EXTM3U\n")
	for _, e := range entries {
		if e.Title != "" || e.Duration >= 0 {
			d := e.Duration
			if d < 0 {
				d = -1
			}
			fmt.Fprintf(&b, "#EXTINF:%d,%s\n", d, e.Title)
		}
		b.WriteString(e.Path)
		b.WriteByte('\n')
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}
