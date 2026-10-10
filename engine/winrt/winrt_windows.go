//go:build windows

package winrt

import (
	"golang.org/x/sys/windows"
)

var (
	kernel32                   = windows.NewLazySystemDLL("kernel32.dll")
	user32                     = windows.NewLazySystemDLL("user32.dll")
	procGetConsoleWindow       = kernel32.NewProc("GetConsoleWindow")
	procShowWindow             = user32.NewProc("ShowWindow")
	procGetWindowThreadProcess = user32.NewProc("GetWindowThreadProcessId")
)

// IsWindows11 reports build 22000 or newer. RtlGetVersion is used because
// GetVersionEx lies to un-manifested processes.
func IsWindows11() bool {
	v := windows.RtlGetVersion()
	return v != nil && v.MajorVersion >= 10 && v.BuildNumber >= 22000
}

// BuildNumber is the OS build number (0 if unknown).
func BuildNumber() int {
	v := windows.RtlGetVersion()
	if v == nil {
		return 0
	}
	return int(v.BuildNumber)
}

// IsElevated reports whether the process token is elevated (administrator).
func IsElevated() bool { return windows.GetCurrentProcessToken().IsElevated() }

// HideConsole hides the console window, but only if this process owns it:
// when launched from a terminal the console belongs to the shell and hiding
// it would take the user's terminal away.
func HideConsole() {
	h, _, _ := procGetConsoleWindow.Call()
	if h == 0 {
		return
	}
	var pid uint32
	procGetWindowThreadProcess.Call(h, uintptrOf(&pid))
	if pid != windows.GetCurrentProcessId() {
		return
	}
	const swHide = 0
	procShowWindow.Call(h, swHide)
}
