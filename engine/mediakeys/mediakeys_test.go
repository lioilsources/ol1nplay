package mediakeys

import (
	"runtime"
	"testing"
)

func TestEventString(t *testing.T) {
	for ev, want := range map[Event]string{PlayPause: "play/pause", Next: "next", Prev: "prev", Stop: "stop", Event(0): "unknown"} {
		if ev.String() != want {
			t.Errorf("%d: got %s want %s", ev, ev, want)
		}
	}
}

func TestStartStop(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("registers global hot keys; not for CI")
	}
	ch := make(chan Event, 1)
	stop, err := Start(ch)
	if err != nil {
		t.Fatal(err)
	}
	stop()
	stop() // must be safe to call twice
}
