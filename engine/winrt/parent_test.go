package winrt

import (
	"os"
	"os/exec"
	"testing"
	"time"
)

func TestParentGone(t *testing.T) {
	select {
	case <-ParentGone(os.Getpid()):
		t.Fatal("own process reported gone")
	case <-time.After(700 * time.Millisecond):
	}

	cmd := exec.Command(os.Args[0], "-test.run=^$")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pid := cmd.Process.Pid
	_ = cmd.Wait()
	select {
	case <-ParentGone(pid):
	case <-time.After(3 * time.Second):
		t.Fatal("exited process not reported gone")
	}
}
