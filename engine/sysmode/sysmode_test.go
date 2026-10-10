package sysmode

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/ol1n/ol1nplay/engine/protocol"
)

func TestProtectedList(t *testing.T) {
	for _, n := range []string{"csrss.exe", "LSASS.EXE", "svchost", "dwm.exe", "System", "audiodg.exe", "MsMpEng.exe", "ol1nplay-engine.exe"} {
		if !isProtected(n, true, "ol1nplay-engine.exe") {
			t.Errorf("%s should be protected", n)
		}
	}
	if !isProtected("explorer.exe", false, "") {
		t.Error("explorer must be protected unless explicitly allowed")
	}
	if isProtected("explorer.exe", true, "") {
		t.Error("explorer may be suspended when allowed")
	}
	if !isProtected("myplayer.exe", false, "myplayer.exe") {
		t.Error("the engine's own image must be protected")
	}
	if isProtected("OneDrive.exe", false, "") {
		t.Error("OneDrive is a legitimate target")
	}
	if !isProtected("   ", false, "") {
		t.Error("empty names are refused")
	}
}

func TestFilterTargets(t *testing.T) {
	ok, refused := filterTargets([]string{"OneDrive.exe", "csrss.exe", "onedrive", "Discord.exe", "explorer.exe", ""}, false, "")
	if len(ok) != 2 || ok[0] != "Discord.exe" || ok[1] != "OneDrive.exe" {
		t.Errorf("ok = %v", ok)
	}
	if len(refused) != 2 || refused[0] != "csrss.exe" || refused[1] != "explorer.exe" {
		t.Errorf("refused = %v", refused)
	}
	okS, refS := filterServices([]string{"WSearch", "Audiosrv", "wsearch", "SysMain"})
	if len(okS) != 2 || len(refS) != 1 || refS[0] != "Audiosrv" {
		t.Errorf("services ok=%v refused=%v", okS, refS)
	}
}

func TestMatchesExe(t *testing.T) {
	if !matchesExe("OneDrive.exe", "onedrive") || !matchesExe("steam.exe", "Steam.EXE") || matchesExe("steamwebhelper.exe", "steam.exe") {
		t.Error("exe matching is case-insensitive and extension-agnostic, exact otherwise")
	}
}

func TestTemplateIsSafe(t *testing.T) {
	for _, n := range Template() {
		if isProtected(n, false, "") {
			t.Errorf("template entry %s is protected", n)
		}
	}
	for _, s := range TemplateServices() {
		if _, refused := filterServices([]string{s}); len(refused) != 0 {
			t.Errorf("template service %s is protected", s)
		}
	}
}

func TestConfigRoundTrip(t *testing.T) {
	dir := t.TempDir()
	var lines []protocol.LogLine
	m := New(dir, func(l protocol.LogLine) { lines = append(lines, l) })
	cfg := m.Get()
	if cfg.PinCore != -1 || cfg.Enabled || len(cfg.Template) == 0 || cfg.Changes == nil {
		t.Errorf("defaults: %+v", cfg)
	}
	cfg.Enabled = true
	cfg.SuspendProcesses = []string{"OneDrive.exe"}
	cfg.StopServices = []string{"WSearch"}
	cfg.Applied = true // must be ignored
	m.Set(cfg)
	m.SetAllowExplorer(true)

	m2 := New(dir, nil)
	got := m2.Get()
	if !got.Enabled || got.Applied || len(got.SuspendProcesses) != 1 || got.StopServices[0] != "WSearch" || !m2.AllowExplorer() {
		t.Errorf("reloaded: %+v allowExplorer=%v", got, m2.AllowExplorer())
	}
}

func TestStateFileRecovery(t *testing.T) {
	dir := t.TempDir()
	st := appliedState{StartedAt: 1, Timer1ms: true, Suspended: []proc{{PID: 4242, Name: "OneDrive.exe"}}}
	b, _ := json.Marshal(st)
	if err := os.WriteFile(filepath.Join(dir, stateFile), b, 0o644); err != nil {
		t.Fatal(err)
	}
	var lines []protocol.LogLine
	m := New(dir, func(l protocol.LogLine) { lines = append(lines, l) })
	m.RecoverOnStart()
	if _, err := os.Stat(filepath.Join(dir, stateFile)); !os.IsNotExist(err) && runtime.GOOS != "windows" {
		t.Error("stale state file must be removed on a platform that cannot restore")
	}
	if len(m.Log()) == 0 || m.Log()[0].Action != "recover" {
		t.Errorf("recovery must be logged: %+v", m.Log())
	}
	if m.Applied() && runtime.GOOS != "windows" {
		t.Error("nothing should remain applied")
	}
}

func TestApplyUnavailable(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("needs a non-elevated run to be deterministic")
	}
	m := New(t.TempDir(), nil)
	if err := m.Apply(); err != ErrUnavailable {
		t.Errorf("expected ErrUnavailable, got %v", err)
	}
	if m.Applied() {
		t.Error("nothing applied")
	}
	if err := m.Restore(); err != nil {
		t.Errorf("restore must be a no-op: %v", err)
	}
	if _, err := os.Stat(filepath.Join(m.stateDir, stateFile)); !os.IsNotExist(err) {
		t.Error("no state file may remain")
	}
}

func TestLogCap(t *testing.T) {
	m := New(t.TempDir(), nil)
	for i := 0; i < maxLog+50; i++ {
		m.logLocked("apply", "x", "y")
	}
	if n := len(m.Log()); n != maxLog {
		t.Errorf("log should be capped at %d, got %d", maxLog, n)
	}
}
