package winrt

import (
	"runtime"
	"testing"
)

func TestTopology(t *testing.T) {
	if ProcessorCount() < 1 {
		t.Error("at least one processor")
	}
	if LastCore() != ProcessorCount()-1 {
		t.Errorf("LastCore %d vs %d", LastCore(), ProcessorCount())
	}
	if runtime.GOOS != "windows" {
		if IsWindows11() || IsElevated() || BuildNumber() != 0 {
			t.Error("non-Windows stubs must answer false/0")
		}
		HideConsole() // must not panic
	}
}
