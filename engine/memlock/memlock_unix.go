//go:build !windows

package memlock

import "syscall"

func lock(b []byte, _ int64) error { return syscall.Mlock(b) }

func unlock(b []byte, _ int64) { _ = syscall.Munlock(b) }
