package cue

import (
	"path/filepath"
	"testing"
)

const sample = "\xEF\xBB\xBFREM GENRE \"Alternative Rock\"\r\n" +
	"REM DATE 1997\r\n" +
	"PERFORMER \"Radiohead\"\r\n" +
	"TITLE \"OK Computer\"\r\n" +
	"FILE \"OK Computer.flac\" WAVE\r\n" +
	"  TRACK 01 AUDIO\r\n" +
	"    TITLE \"Airbag\"\r\n" +
	"    PERFORMER \"Radiohead\"\r\n" +
	"    INDEX 01 00:00:00\r\n" +
	"  TRACK 02 AUDIO\r\n" +
	"    TITLE \"Paranoid Android\"\r\n" +
	"    INDEX 00 04:42:00\r\n" +
	"    INDEX 01 04:44:15\r\n" +
	"  TRACK 03 AUDIO\r\n" +
	"    TITLE \"Subterranean Homesick Alien\"\r\n" +
	"    INDEX 01 11:07:60\r\n"

func TestParse(t *testing.T) {
	sh, err := ParseBytes(filepath.Join("x", "album.cue"), []byte(sample))
	if err != nil {
		t.Fatal(err)
	}
	if sh.Title != "OK Computer" || sh.Performer != "Radiohead" || sh.Genre != "Alternative Rock" || sh.Date != "1997" {
		t.Fatalf("header: %+v", sh)
	}
	if len(sh.Tracks) != 3 {
		t.Fatalf("tracks: %d", len(sh.Tracks))
	}
	if sh.Tracks[0].File != filepath.Join("x", "OK Computer.flac") {
		t.Fatalf("file: %q", sh.Tracks[0].File)
	}
	// Track 1 ends at track 2's INDEX 00 (pregap belongs to track 2).
	if got := sh.Tracks[0].EndCDFrames; got != 4*60*75+42*75 {
		t.Fatalf("t1 end %d", got)
	}
	if got := sh.Tracks[1].StartCDFrames; got != 4*60*75+44*75+15 {
		t.Fatalf("t2 start %d", got)
	}
	if got := sh.Tracks[1].EndCDFrames; got != 11*60*75+7*75+60 {
		t.Fatalf("t2 end %d", got)
	}
	if sh.Tracks[2].EndCDFrames != 0 {
		t.Fatalf("last track must run to EOF")
	}
	if ToSamples(75, 44100) != 44100 || ToSamples(1, 44100) != 588 {
		t.Fatal("ToSamples at 44.1k")
	}
	if ToSamples(75, 96000) != 96000 {
		t.Fatal("ToSamples at 96k")
	}
}

func TestLatin1Fallback(t *testing.T) {
	// "Dvořák" in Windows-1252 is not valid UTF-8; we must not choke.
	raw := []byte("TITLE \"Dvo\xf8\xe1k\"\nFILE \"a.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n")
	sh, err := ParseBytes("a.cue", raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(sh.Tracks) != 1 || sh.Title == "" {
		t.Fatalf("%+v", sh)
	}
}
