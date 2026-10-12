package api

import (
	"os/exec"
	"runtime"
	"testing"
)

func TestHelperStartsAndStops(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("uses /bin/sleep")
	}
	sleep, err := exec.LookPath("sleep")
	if err != nil {
		t.Skip("no sleep binary")
	}
	h := helper{logf: func(string, string, string, ...any) {}}
	h.start(sleep, "30")
	if !h.running() {
		t.Fatal("helper did not start")
	}
	h.start(sleep, "30") // a second start while running is a no-op
	h.stop()
	if h.running() {
		t.Fatal("helper still running after stop")
	}
	h.stop() // idempotent

	h.start("/no/such/program", "")
	if h.running() {
		t.Fatal("started a program that does not exist")
	}
}

func TestTouchesHelper(t *testing.T) {
	for raw, want := range map[string]bool{
		`{"theme":"black"}`:            false,
		`{"helperExe":"C:\\x.exe"}`:    true,
		`{"helperArgs":"-q"}`:          true,
		`{"mono":true,"helperExe":""}`: true,
	} {
		if got := touchesHelper([]byte(raw)); got != want {
			t.Errorf("touchesHelper(%s) = %v, want %v", raw, got, want)
		}
	}
}
