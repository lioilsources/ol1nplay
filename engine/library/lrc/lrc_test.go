package lrc

import "testing"

func TestParse(t *testing.T) {
	src := "\xEF\xBB\xBF[ar:Someone]\n[offset:-100]\n[00:12.00][01:15.50]chorus line\n[00:05.123]intro\n\nplain\n"
	l := Parse(src)
	if l.Source != "lrc" || len(l.Lines) != 3 {
		t.Fatalf("%+v", l)
	}
	if l.Lines[0].Ms != 5023 || l.Lines[0].Text != "intro" {
		t.Fatalf("first %+v", l.Lines[0])
	}
	if l.Lines[1].Ms != 11900 || l.Lines[2].Ms != 75400 || l.Lines[2].Text != "chorus line" {
		t.Fatalf("%+v", l.Lines)
	}
	if p := Parse("just\ntext"); p.Source != "txt" || p.Text != "just\ntext" || p.Lines != nil {
		t.Fatalf("plain: %+v", p)
	}
}
