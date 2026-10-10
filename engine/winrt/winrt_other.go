//go:build !windows

package winrt

// IsWindows11 is false here.
func IsWindows11() bool { return false }

// BuildNumber is 0 here.
func BuildNumber() int { return 0 }

// IsElevated is false here.
func IsElevated() bool { return false }

// HideConsole does nothing here.
func HideConsole() {}
