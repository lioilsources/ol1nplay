//go:build windows

package mediakeys

import (
	"errors"
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	user32                = windows.NewLazySystemDLL("user32.dll")
	procRegisterHotKey    = user32.NewProc("RegisterHotKey")
	procUnregisterHotKey  = user32.NewProc("UnregisterHotKey")
	procGetMessageW       = user32.NewProc("GetMessageW")
	procPostThreadMessage = user32.NewProc("PostThreadMessageW")
)

const (
	wmHotKey  = 0x0312
	wmQuit    = 0x0012
	modNoRept = 0x4000 // MOD_NOREPEAT: one event per press, not autorepeat

	vkMediaNextTrack = 0xB0
	vkMediaPrevTrack = 0xB1
	vkMediaStop      = 0xB2
	vkMediaPlayPause = 0xB3
)

// msg is the Win32 MSG structure (x64 layout: HWND, UINT+pad, WPARAM,
// LPARAM, DWORD time, POINT, DWORD lPrivate).
type msg struct {
	HWnd     uintptr
	Message  uint32
	_        uint32
	WParam   uintptr
	LParam   uintptr
	Time     uint32
	Pt       struct{ X, Y int32 }
	LPrivate uint32
}

var bindings = []struct {
	id uintptr
	vk uintptr
	ev Event
}{
	{1, vkMediaPlayPause, PlayPause},
	{2, vkMediaNextTrack, Next},
	{3, vkMediaPrevTrack, Prev},
	{4, vkMediaStop, Stop},
}

// Start registers the media keys and pumps messages on its own locked OS
// thread (hot keys are delivered to the registering thread's queue).
// Events are delivered non-blocking: if ch is full the press is dropped,
// because the audio path must never wait on the UI. Keys another
// application already owns are skipped; Start fails only if none could be
// registered.
func Start(ch chan<- Event) (stop func(), err error) {
	errc := make(chan error, 1)
	stopped := make(chan struct{})
	var tid uint32
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		defer close(stopped)
		tid = windows.GetCurrentThreadId()

		registered := 0
		for _, b := range bindings {
			if r, _, _ := procRegisterHotKey.Call(0, b.id, modNoRept, b.vk); r != 0 {
				registered++
			}
		}
		if registered == 0 {
			errc <- errors.New("mediakeys: no media key could be registered (another player owns them)")
			return
		}
		errc <- nil

		var m msg
		for {
			r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
			if int32(r) <= 0 { // WM_QUIT or error
				break
			}
			if m.Message != wmHotKey {
				continue
			}
			for _, b := range bindings {
				if b.id == m.WParam {
					select {
					case ch <- b.ev:
					default:
					}
				}
			}
		}
		for _, b := range bindings {
			procUnregisterHotKey.Call(0, b.id)
		}
	}()
	if err := <-errc; err != nil {
		<-stopped
		return nil, err
	}
	return func() {
		procPostThreadMessage.Call(uintptr(tid), wmQuit, 0, 0)
		<-stopped
	}, nil
}
