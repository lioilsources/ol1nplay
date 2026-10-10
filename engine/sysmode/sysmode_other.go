//go:build !windows

package sysmode

// On non-Windows platforms the manager still keeps configuration and the
// log so the UI and tests behave identically; it just never touches the OS.

func available() bool  { return false }
func isElevated() bool { return false }

func applyPlatform(m *Manager) error {
	m.logLocked("error", "", ErrUnavailable.Error())
	return ErrUnavailable
}

func restorePlatform(m *Manager) error {
	// Nothing can have been applied here; clear whatever a copied state
	// file claims so it is not reported forever.
	*m.state = appliedState{}
	return nil
}
