// Package lrc parses LRC (timed lyrics) files into protocol.Lyrics.
package lrc

import (
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/ol1n/ol1nplay/engine/protocol"
)

// A line may carry several timestamps ("[00:12.00][01:15.00]chorus"), each
// producing its own entry. Fractions may be 2 or 3 digits (hundredths or
// milliseconds) – both are in the wild.
var tsRe = regexp.MustCompile(`^\[(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\]`)
var metaRe = regexp.MustCompile(`^\[([a-zA-Z]+):(.*)\]$`)

// Parse converts LRC text. Metadata tags ([ar:], [ti:], [offset:]) are
// honoured for offset only; the rest the library already knows from tags.
func Parse(text string) *protocol.Lyrics {
	text = strings.TrimPrefix(text, "\xEF\xBB\xBF")
	var lines []protocol.LyricLine
	var plain []string
	offset := int64(0)
	for _, raw := range strings.Split(text, "\n") {
		raw = strings.TrimRight(raw, "\r")
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		if m := metaRe.FindStringSubmatch(line); m != nil && !tsRe.MatchString(line) {
			if strings.EqualFold(m[1], "offset") {
				if v, err := strconv.ParseInt(strings.TrimSpace(m[2]), 10, 64); err == nil {
					offset = v
				}
			}
			continue
		}
		var stamps []int64
		rest := line
		for {
			m := tsRe.FindStringSubmatch(rest)
			if m == nil {
				break
			}
			min, _ := strconv.Atoi(m[1])
			sec, _ := strconv.Atoi(m[2])
			frac := int64(0)
			if m[3] != "" {
				f := m[3]
				for len(f) < 3 {
					f += "0"
				}
				frac, _ = strconv.ParseInt(f, 10, 64)
			}
			stamps = append(stamps, int64(min)*60000+int64(sec)*1000+frac)
			rest = rest[len(m[0]):]
		}
		if len(stamps) == 0 {
			plain = append(plain, line)
			continue
		}
		txt := strings.TrimSpace(rest)
		for _, s := range stamps {
			ms := s + offset
			if ms < 0 {
				ms = 0
			}
			lines = append(lines, protocol.LyricLine{Ms: ms, Text: txt})
		}
	}
	sort.SliceStable(lines, func(i, j int) bool { return lines[i].Ms < lines[j].Ms })
	if len(lines) == 0 {
		return &protocol.Lyrics{Text: strings.Join(plain, "\n"), Source: "txt"}
	}
	var b strings.Builder
	for i, l := range lines {
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(l.Text)
	}
	return &protocol.Lyrics{Text: b.String(), Lines: lines, Source: "lrc"}
}
