//go:build windows

package winrt

import "golang.org/x/sys/windows"

// ParentGone is closed when the process with the given id exits, or at once
// when it cannot be opened (it is already gone).
func ParentGone(pid int) <-chan struct{} {
	done := make(chan struct{})
	h, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		close(done)
		return done
	}
	go func() {
		defer windows.CloseHandle(h)
		_, _ = windows.WaitForSingleObject(h, windows.INFINITE)
		close(done)
	}()
	return done
}
