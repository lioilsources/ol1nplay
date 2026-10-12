package memlock

import "testing"

func TestLockUnlock(t *testing.T) {
	b := make([]byte, 1<<20)
	if err := Lock(b); err != nil {
		t.Skipf("the OS refused to lock 1 MB here: %v", err)
	}
	if Locked() != 1<<20 {
		t.Fatalf("locked = %d", Locked())
	}
	b[0], b[len(b)-1] = 1, 2 // still ordinary memory
	Unlock(b)
	if Locked() != 0 {
		t.Fatalf("locked after unlock = %d", Locked())
	}
	if err := Lock(nil); err != nil {
		t.Fatal(err)
	}
}
