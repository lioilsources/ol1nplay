//go:build windows

package memlock

import (
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

// VirtualLock can only pin what fits in the process's minimum working set,
// which starts at a few hundred kilobytes. So the minimum is raised to
// cover everything locked (plus headroom for the rest of the engine) before
// each lock, and lowered again after each unlock.
const (
	headroom = 64 << 20
	slack    = 256 << 20 // maximum stays at least this far above the minimum
)

var (
	baseMin, baseMax uintptr
	baseFlags        uint32
	haveBase         bool
)

func setWorkingSet(locked int64) error {
	h := windows.CurrentProcess()
	if !haveBase {
		windows.GetProcessWorkingSetSizeEx(h, &baseMin, &baseMax, &baseFlags)
		if baseMax == 0 {
			return fmt.Errorf("GetProcessWorkingSetSizeEx: no working set limits reported")
		}
		haveBase = true
	}
	if locked <= 0 {
		return windows.SetProcessWorkingSetSizeEx(h, baseMin, baseMax, baseFlags)
	}
	min := baseMin + uintptr(locked) + headroom
	max := baseMax
	if max < min+slack {
		max = min + slack
	}
	if err := windows.SetProcessWorkingSetSizeEx(h, min, max, baseFlags); err != nil {
		return fmt.Errorf("SetProcessWorkingSetSizeEx(%d MB): %w", min>>20, err)
	}
	return nil
}

func lock(b []byte, totalAfter int64) error {
	if err := setWorkingSet(totalAfter); err != nil {
		return err
	}
	if err := windows.VirtualLock(uintptr(unsafe.Pointer(&b[0])), uintptr(len(b))); err != nil {
		_ = setWorkingSet(totalAfter - int64(len(b)))
		return fmt.Errorf("VirtualLock(%d MB): %w", len(b)>>20, err)
	}
	return nil
}

func unlock(b []byte, totalAfter int64) {
	_ = windows.VirtualUnlock(uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)))
	_ = setWorkingSet(totalAfter)
}
