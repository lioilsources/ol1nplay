package api

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	"github.com/ol1n/ol1nplay/engine/protocol"
)

// DataDir is where the engine keeps everything: settings, token, library
// DB, covers, playlists, sysmode state.
//
//	Windows: %LOCALAPPDATA%\Ol1nPlay
//	macOS:   ~/Library/Application Support/Ol1nPlay
//	Linux:   $XDG_DATA_HOME/ol1nplay or ~/.local/share/ol1nplay
func DataDir() string {
	if d := os.Getenv("OL1NPLAY_DATA"); d != "" {
		return d
	}
	switch runtime.GOOS {
	case "windows":
		if d := os.Getenv("LOCALAPPDATA"); d != "" {
			return filepath.Join(d, "Ol1nPlay")
		}
	case "darwin":
		if h, err := os.UserHomeDir(); err == nil {
			return filepath.Join(h, "Library", "Application Support", "Ol1nPlay")
		}
	default:
		if d := os.Getenv("XDG_DATA_HOME"); d != "" {
			return filepath.Join(d, "ol1nplay")
		}
		if h, err := os.UserHomeDir(); err == nil {
			return filepath.Join(h, ".local", "share", "ol1nplay")
		}
	}
	return "ol1nplay-data"
}

// DefaultSettings are what a fresh install runs with.
func DefaultSettings() protocol.Settings {
	return protocol.Settings{
		Backend:          "",
		Device:           "",
		Repeat:           "off",
		RAMLimitMB:       512,
		PreloadNext:      true,
		ResumeOnStart:    true,
		DSDMode:          "native",
		WidthExtension:   true,
		BufferPreference: "preferred",
		RemotePort:       7778,
		MDNS:             true,
		MediaKeys:        true,
		Theme:            "system",
	}
}

// Store persists Settings as JSON with partial-merge semantics: a client
// sends only the fields it changes, so we merge at the JSON level instead
// of overwriting zero values.
type Store struct {
	mu   sync.Mutex
	path string
	cur  protocol.Settings
}

// OpenStore loads <dir>/settings.json (defaults when absent).
func OpenStore(dir string) (*Store, error) {
	s := &Store{path: filepath.Join(dir, "settings.json"), cur: DefaultSettings()}
	b, err := os.ReadFile(s.path)
	if err == nil {
		// Merge over defaults so new fields get their default, not zero.
		if err := mergeJSON(&s.cur, b); err != nil {
			return nil, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	return s, nil
}

// Get returns a copy.
func (s *Store) Get() protocol.Settings {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.cur
	c.Roots = append([]string(nil), c.Roots...)
	return c
}

// Patch merges a partial JSON object and saves.
func (s *Store) Patch(raw json.RawMessage) (protocol.Settings, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := s.cur
	if err := mergeJSON(&next, raw); err != nil {
		return s.cur, err
	}
	if err := validate(&next); err != nil {
		return s.cur, err
	}
	s.cur = next
	return s.cur, s.saveLocked()
}

// Set replaces the whole struct and saves.
func (s *Store) Set(v protocol.Settings) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := validate(&v); err != nil {
		return err
	}
	s.cur = v
	return s.saveLocked()
}

// Update applies f under the lock and saves.
func (s *Store) Update(f func(*protocol.Settings)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	f(&s.cur)
	s.cur.MonoMode = protocol.NormalizeMonoMode(s.cur.MonoMode)
	s.cur.Mono = s.cur.MonoMode != protocol.MonoStereo
	return s.saveLocked()
}

func (s *Store) saveLocked() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(s.cur, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

func mergeJSON(dst *protocol.Settings, raw []byte) error {
	if len(raw) == 0 {
		return nil
	}
	base, _ := json.Marshal(dst)
	var m map[string]json.RawMessage
	if err := json.Unmarshal(base, &m); err != nil {
		return err
	}
	var patch map[string]json.RawMessage
	if err := json.Unmarshal(raw, &patch); err != nil {
		return err
	}
	for k, v := range patch {
		m[k] = v
	}
	// A client that only knows the stereo/mono switch sends the bare bool.
	if _, ok := patch["mono"]; ok {
		if _, ok := patch["monoMode"]; !ok {
			delete(m, "monoMode")
		}
	}
	merged, _ := json.Marshal(m)
	return json.Unmarshal(merged, dst)
}

func validate(s *protocol.Settings) error {
	// MonoMode is the setting and Mono mirrors it. Only a missing mode (a
	// file from 0.1, or a patch that sent the bare bool) reads the bool.
	if s.MonoMode == "" && s.Mono {
		s.MonoMode = protocol.MonoBoth
	}
	s.MonoMode = protocol.NormalizeMonoMode(s.MonoMode)
	s.Mono = s.MonoMode != protocol.MonoStereo
	switch s.Repeat {
	case "", "off", "one", "all":
	default:
		return errors.New("repeat must be off|one|all")
	}
	switch s.DSDMode {
	case "", "native", "dop", "pcm":
	default:
		return errors.New("dsdMode must be native|dop|pcm")
	}
	if s.CooltimeSec < 0 || s.CooltimeSec > 8 {
		return errors.New("cooltimeSec must be 0–8")
	}
	s.HelperExe = strings.TrimSpace(s.HelperExe)
	if s.HelperExe != "" && !filepath.IsAbs(s.HelperExe) {
		return errors.New("helperExe must be a full path")
	}
	if s.RAMLimitMB < 16 {
		s.RAMLimitMB = 16
	}
	if s.RemotePort <= 0 || s.RemotePort > 65535 {
		s.RemotePort = 7778
	}
	return nil
}

// Resume is the last-session snapshot for "resume on start".
type Resume struct {
	Paths      []string `json:"paths"`
	Index      int      `json:"index"`
	PositionMs int64    `json:"positionMs"`
	Mono       bool     `json:"mono"`
	MonoMode   string   `json:"monoMode,omitempty"`
}

func loadResume(dir string) (Resume, bool) {
	var r Resume
	b, err := os.ReadFile(filepath.Join(dir, "resume.json"))
	if err != nil || json.Unmarshal(b, &r) != nil || len(r.Paths) == 0 {
		return r, false
	}
	return r, true
}

func saveResume(dir string, r Resume) {
	b, _ := json.Marshal(r)
	_ = os.WriteFile(filepath.Join(dir, "resume.json"), b, 0o644)
}
