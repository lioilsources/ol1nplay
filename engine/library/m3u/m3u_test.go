package m3u

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	dir := t.TempDir()
	in := []Entry{
		{Path: filepath.Join(dir, "a", "Dvořák.flac"), Title: "Symfonie č. 9", Duration: 2700},
		{Path: filepath.Join(dir, "b.wav"), Duration: -1},
	}
	p := filepath.Join(dir, "list.m3u8")
	if err := Write(p, in); err != nil {
		t.Fatal(err)
	}
	out, err := Read(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 2 || out[0] != in[0] || out[1].Path != in[1].Path || out[1].Title != "" {
		t.Fatalf("got %+v", out)
	}
}

func TestRelativeAndLegacy(t *testing.T) {
	dir := t.TempDir()
	// Windows-1250 "č" is 0xE8; backslashes must resolve on every OS.
	raw := []byte("#EXTM3U\n#EXTINF:10,P\xe8\nsub\\x.mp3\n")
	p := filepath.Join(dir, "old.m3u")
	if err := os.WriteFile(p, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	out, err := Read(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 1 || out[0].Path != filepath.Join(dir, "sub", "x.mp3") || out[0].Title != "Pč" {
		t.Fatalf("got %+v", out)
	}
}
