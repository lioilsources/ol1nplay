package api

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

// helper is the user's companion program (Settings.HelperExe) — for
// instance MinorityClean from the Bug head package, which its author says
// to start before the music. The player ships nothing of the kind; it only
// starts what the user points it at when the engine starts, and stops it
// again when the engine stops. A copy the user started on their own (or
// installed as a service) is not ours and is never touched.
type helper struct {
	logf func(level, scope, msg string, args ...any)

	mu   sync.Mutex
	cmd  *exec.Cmd
	done chan struct{}
}

func (h *helper) start(exe, args string) {
	exe = strings.TrimSpace(exe)
	if exe == "" {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.cmd != nil {
		return
	}
	if st, err := os.Stat(exe); err != nil || st.IsDir() {
		h.logf("warn", "helper", "%s: not a file — nothing started", exe)
		return
	}
	cmd := exec.Command(exe, strings.Fields(args)...)
	cmd.Dir = filepath.Dir(exe)
	if err := cmd.Start(); err != nil {
		h.logf("warn", "helper", "could not start %s: %v", exe, err)
		return
	}
	done := make(chan struct{})
	h.cmd, h.done = cmd, done
	h.logf("info", "helper", "started %s (pid %d)", exe, cmd.Process.Pid)
	go func() {
		err := cmd.Wait()
		h.mu.Lock()
		ours := h.cmd == cmd
		if ours {
			h.cmd, h.done = nil, nil
		}
		h.mu.Unlock()
		if ours {
			h.logf("info", "helper", "%s exited on its own (%v)", filepath.Base(exe), err)
		}
		close(done)
	}()
}

// stop ends the program if this engine started it and it is still running.
func (h *helper) stop() {
	h.mu.Lock()
	cmd, done := h.cmd, h.done
	h.cmd, h.done = nil, nil
	h.mu.Unlock()
	if cmd == nil {
		return
	}
	_ = cmd.Process.Kill()
	<-done
	h.logf("info", "helper", "stopped %s", filepath.Base(cmd.Path))
}

func (h *helper) running() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.cmd != nil
}
