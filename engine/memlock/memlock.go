// Package memlock pins decoded audio in physical RAM so the feeder never
// takes a page fault on it. It is the one "Bug head"-style measure with a
// plain engineering reason: a track that was decoded minutes ago and then
// paged out would otherwise be read back from the pagefile mid-playback.
//
// Locking is best effort. The OS may refuse (quota, not enough RAM); the
// caller logs that and plays on.
package memlock

import "sync"

var (
	mu    sync.Mutex
	total int64 // bytes currently locked through this package
)

// Lock pins b. A nil error means every page of b is resident and stays so
// until Unlock.
func Lock(b []byte) error {
	if len(b) == 0 {
		return nil
	}
	mu.Lock()
	defer mu.Unlock()
	if err := lock(b, total+int64(len(b))); err != nil {
		return err
	}
	total += int64(len(b))
	return nil
}

// Unlock releases a slice previously passed to Lock.
func Unlock(b []byte) {
	if len(b) == 0 {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	total -= int64(len(b))
	if total < 0 {
		total = 0
	}
	unlock(b, total)
}

// Locked is the number of bytes pinned right now.
func Locked() int64 {
	mu.Lock()
	defer mu.Unlock()
	return total
}
