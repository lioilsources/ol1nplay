//go:build !windows

package winrt

import (
	"syscall"
	"time"
)

// ParentGone is closed when the process with the given id exits, or at once
// when it is already gone.
func ParentGone(pid int) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		// EPERM still means the process exists.
		for syscall.Kill(pid, 0) != syscall.ESRCH {
			time.Sleep(500 * time.Millisecond)
		}
		close(done)
	}()
	return done
}
