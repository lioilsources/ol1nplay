// Package sysmode implements the "playback mode" system tweaks of plan §4.6:
// power plan, USB selective suspend, core parking, process priority, the 1 ms
// timer, and the user's opt-in list of processes/services to pause while
// music plays.
//
// Honesty note (also in the README): with an asynchronous USB DAC the DAC's
// own clock drives playback, so these tweaks have a measurably small to
// zero effect on the bits that reach it. They exist because they cannot
// hurt the audio and users expect them. What they CAN hurt is the rest of
// the system, hence the rules: everything is opt-in, a hard-coded protected
// list is never touched, every change is written to a state file *before*
// it is made so that a crash can be undone on the next start, and the log
// of "what I changed" is always visible.
package sysmode

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/ol1n/ol1nplay/engine/protocol"
)

const (
	configFile = "sysmode.json"       // the user's configuration
	stateFile  = "sysmode_state.json" // what is currently changed; exists only while applied
	maxLog     = 500
)

// ErrUnavailable is returned by Apply when the platform or privileges do
// not allow system changes.
var ErrUnavailable = errors.New("sysmode: not available (Windows + administrator required)")

// config is what gets persisted. It embeds the protocol struct and adds the
// one knob the protocol does not carry.
type config struct {
	protocol.Sysmode
	AllowExplorer bool `json:"allowExplorer"` // explorer.exe may be suspended only with this
}

// acdc remembers a powercfg setting's previous AC/DC indices on a scheme.
type acdc struct {
	Scheme string `json:"scheme"`
	AC     string `json:"ac"`
	DC     string `json:"dc"`
}

// proc is a suspended process we must resume.
type proc struct {
	PID  uint32 `json:"pid"`
	Name string `json:"name"`
}

// appliedState is the crash-safe record of every change currently in effect.
// Fields are cleared as they are undone.
type appliedState struct {
	StartedAt     int64    `json:"startedAt"`
	PowerScheme   string   `json:"powerScheme,omitempty"` // GUID that was active before
	USBSuspend    *acdc    `json:"usbSuspend,omitempty"`
	CoreParking   *acdc    `json:"coreParking,omitempty"`
	MinProcState  *acdc    `json:"minProcState,omitempty"`
	PriorityClass uint32   `json:"priorityClass,omitempty"` // previous class of this process
	Timer1ms      bool     `json:"timer1ms,omitempty"`
	Suspended     []proc   `json:"suspended,omitempty"`
	Killed        []string `json:"killed,omitempty"` // informational; nothing to undo
	StoppedSvcs   []string `json:"stoppedServices,omitempty"`
}

func (s *appliedState) empty() bool {
	return s.PowerScheme == "" && s.USBSuspend == nil && s.CoreParking == nil && s.MinProcState == nil &&
		s.PriorityClass == 0 && !s.Timer1ms && len(s.Suspended) == 0 && len(s.StoppedSvcs) == 0
}

// Manager owns the configuration, the applied state and the log.
type Manager struct {
	mu       sync.Mutex
	stateDir string
	logFn    func(protocol.LogLine)

	cfg     config
	state   *appliedState // non-nil while something is applied
	entries []protocol.SysmodeLogEntry
}

// New loads the configuration from stateDir (created if missing). It does
// not touch the system; call RecoverOnStart next.
func New(stateDir string, log func(protocol.LogLine)) *Manager {
	if log == nil {
		log = func(protocol.LogLine) {}
	}
	m := &Manager{stateDir: stateDir, logFn: log}
	m.cfg.Sysmode = defaults()
	_ = os.MkdirAll(stateDir, 0o755)
	if b, err := os.ReadFile(filepath.Join(stateDir, configFile)); err == nil {
		var c config
		if json.Unmarshal(b, &c) == nil {
			// Status fields are never trusted from disk.
			c.Applied, c.Available, c.Changes, c.Template = false, false, nil, nil
			m.cfg = c
		}
	}
	return m
}

func defaults() protocol.Sysmode {
	return protocol.Sysmode{
		Enabled:         false,
		PowerPlan:       true,
		USBSuspend:      true,
		CoreParking:     true,
		ProcessPriority: true,
		Timer1ms:        true,
		PinCore:         -1,
	}
}

// Template is the recommended suspend list offered by the UI. Nothing on it
// is applied unless the user copies it into SuspendProcesses.
func Template() []string {
	return []string{
		"SearchIndexer.exe", "OneDrive.exe", "Dropbox.exe", "GoogleDriveFS.exe",
		"steam.exe", "steamwebhelper.exe", "EpicGamesLauncher.exe",
		"Discord.exe", "Teams.exe", "ms-teams.exe", "Spotify.exe",
		"MoUsoCoreWorker.exe", "UsoClient.exe",
		"CCXProcess.exe", "Creative Cloud.exe", "AdobeUpdateService.exe",
	}
}

// TemplateServices is the recommended stop list for services.
func TemplateServices() []string {
	return []string{"WSearch", "SysMain", "wuauserv", "DiagTrack", "BITS", "DoSvc"}
}

// Template is the method form for callers holding a Manager.
func (m *Manager) Template() []string { return Template() }

// Get returns configuration plus live status.
func (m *Manager) Get() protocol.Sysmode {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.snapshotLocked()
}

func (m *Manager) snapshotLocked() protocol.Sysmode {
	s := m.cfg.Sysmode
	s.Applied = m.state != nil
	s.Available = available()
	s.Template = Template()
	s.Changes = m.changesLocked()
	if s.SuspendProcesses == nil {
		s.SuspendProcesses = []string{}
	}
	if s.KillProcesses == nil {
		s.KillProcesses = []string{}
	}
	if s.StopServices == nil {
		s.StopServices = []string{}
	}
	return s
}

// changesLocked renders the applied state as a human list.
func (m *Manager) changesLocked() []string {
	st := m.state
	if st == nil {
		return []string{}
	}
	var out []string
	if st.PowerScheme != "" {
		out = append(out, "power plan switched (previous "+st.PowerScheme+")")
	}
	if st.USBSuspend != nil {
		out = append(out, "USB selective suspend disabled")
	}
	if st.CoreParking != nil {
		out = append(out, "core parking disabled")
	}
	if st.MinProcState != nil {
		out = append(out, "minimum processor state 100 %")
	}
	if st.PriorityClass != 0 {
		out = append(out, "engine priority HIGH")
	}
	if st.Timer1ms {
		out = append(out, "timer resolution 1 ms")
	}
	for _, p := range st.Suspended {
		out = append(out, "suspended "+p.Name)
	}
	for _, k := range st.Killed {
		out = append(out, "terminated "+k)
	}
	for _, s := range st.StoppedSvcs {
		out = append(out, "stopped service "+s)
	}
	return out
}

// Set replaces the configuration (status fields are ignored) and persists
// it. It does not apply anything; Apply happens when playback starts if
// Enabled is set.
func (m *Manager) Set(cfg protocol.Sysmode) {
	m.mu.Lock()
	defer m.mu.Unlock()
	cfg.Applied, cfg.Available, cfg.Changes, cfg.Template = false, false, nil, nil
	m.cfg.Sysmode = cfg
	m.saveConfigLocked()
}

// SetAllowExplorer lets explorer.exe be suspended. Off by default because a
// frozen shell looks exactly like a hung computer.
func (m *Manager) SetAllowExplorer(ok bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.cfg.AllowExplorer = ok
	m.saveConfigLocked()
}

// AllowExplorer reports the flag.
func (m *Manager) AllowExplorer() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.cfg.AllowExplorer
}

func (m *Manager) saveConfigLocked() {
	b, err := json.MarshalIndent(m.cfg, "", "  ")
	if err != nil {
		return
	}
	_ = os.WriteFile(filepath.Join(m.stateDir, configFile), b, 0o644)
}

// Log returns the change log, oldest first.
func (m *Manager) Log() []protocol.SysmodeLogEntry {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]protocol.SysmodeLogEntry(nil), m.entries...)
}

// Available reports whether Apply can do anything here.
func (m *Manager) Available() bool { return available() }

// IsElevated reports whether the process runs with administrator rights.
func (m *Manager) IsElevated() bool { return isElevated() }

// Applied reports whether changes are in effect.
func (m *Manager) Applied() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.state != nil
}

// Apply makes the configured changes. Idempotent: a second call while
// applied is a no-op. Partial failure leaves successful changes in place
// (they are recorded and will be restored) and returns the first error.
func (m *Manager) Apply() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.state != nil {
		return nil
	}
	if !available() {
		m.logLocked("error", "", ErrUnavailable.Error())
		return ErrUnavailable
	}
	m.state = &appliedState{StartedAt: time.Now().UnixMilli()}
	m.persistStateLocked()
	err := applyPlatform(m)
	if m.state != nil && m.state.empty() {
		m.state = nil
		m.removeStateLocked()
	}
	return err
}

// Restore undoes everything recorded in the state, in reverse order, and
// deletes the state file. Safe to call any number of times.
func (m *Manager) Restore() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.restoreLocked()
}

func (m *Manager) restoreLocked() error {
	if m.state == nil {
		return nil
	}
	err := restorePlatform(m)
	if m.state.empty() || err == nil {
		m.state = nil
		m.removeStateLocked()
	}
	return err
}

// RecoverOnStart undoes changes left behind by a previous engine instance
// that did not get to Restore (crash, kill, power loss).
func (m *Manager) RecoverOnStart() {
	m.mu.Lock()
	defer m.mu.Unlock()
	b, err := os.ReadFile(filepath.Join(m.stateDir, stateFile))
	if err != nil {
		return
	}
	var st appliedState
	if json.Unmarshal(b, &st) != nil || st.empty() {
		m.removeStateLocked()
		return
	}
	m.state = &st
	m.logLocked("recover", "", "state file from a previous run found; restoring")
	if !available() {
		// Nothing we can do on this platform; drop the stale file so it is
		// not reported forever.
		m.logLocked("recover", "", "cannot restore here; discarding state")
		m.state = nil
		m.removeStateLocked()
		return
	}
	if err := m.restoreLocked(); err != nil {
		m.logLocked("error", "", "recovery incomplete: "+err.Error())
	}
}

// ---- internals shared with the platform files ---------------------------

func (m *Manager) persistStateLocked() {
	if m.state == nil {
		return
	}
	b, err := json.MarshalIndent(m.state, "", "  ")
	if err != nil {
		return
	}
	path := filepath.Join(m.stateDir, stateFile)
	tmp := path + ".tmp"
	if os.WriteFile(tmp, b, 0o644) == nil {
		_ = os.Rename(tmp, path)
	}
}

func (m *Manager) removeStateLocked() {
	_ = os.Remove(filepath.Join(m.stateDir, stateFile))
}

func (m *Manager) logLocked(action, target, detail string) {
	e := protocol.SysmodeLogEntry{At: time.Now().UnixMilli(), Action: action, Target: target, Detail: detail}
	m.entries = append(m.entries, e)
	if len(m.entries) > maxLog {
		m.entries = m.entries[len(m.entries)-maxLog:]
	}
	level := "info"
	if action == "error" {
		level = "warn"
	}
	msg := action
	if target != "" {
		msg += " " + target
	}
	if detail != "" {
		msg += ": " + detail
	}
	m.logFn(protocol.LogLine{At: e.At, Level: level, Scope: "sysmode", Msg: msg})
}

// ---- protected list ---------------------------------------------------------

// protected are process image names (lower case, without extension) that
// are never suspended or killed, whatever the configuration says.
var protected = map[string]bool{
	"system": true, "registry": true, "memory compression": true, "secure system": true,
	"smss": true, "csrss": true, "wininit": true, "winlogon": true, "services": true,
	"lsass": true, "svchost": true, "dwm": true, "audiodg": true, "fontdrvhost": true,
	"sihost": true, "ctfmon": true, "conhost": true, "runtimebroker": true,
	"msmpeng": true, "nissrv": true, "securityhealthservice": true,
	"ol1nplay-engine": true, "ol1nplay": true, "engine": true,
}

// protectedServices are never stopped.
var protectedServices = map[string]bool{
	"audiosrv": true, "audioendpointbuilder": true, "rpcss": true, "dcomlaunch": true,
	"plugplay": true, "power": true, "eventlog": true, "windefend": true, "wlansvc": true,
	"dhcp": true, "dnscache": true, "lanmanworkstation": true, "winmgmt": true,
	"profsvc": true, "usermanager": true, "themes": true, "mmcss": true, "schedule": true,
	"cryptsvc": true, "keyiso": true, "samss": true, "lsm": true, "brokerinfrastructure": true,
}

func normalizeExe(name string) string {
	n := strings.ToLower(strings.TrimSpace(name))
	n = strings.TrimSuffix(n, ".exe")
	return n
}

// isProtected tells whether an image name must be left alone. self is the
// engine's own image name (without extension).
func isProtected(name string, allowExplorer bool, self string) bool {
	n := normalizeExe(name)
	if n == "" {
		return true
	}
	if n == "explorer" {
		return !allowExplorer
	}
	if self != "" && n == normalizeExe(self) {
		return true
	}
	return protected[n]
}

// filterTargets splits a user list into allowed and refused names.
func filterTargets(list []string, allowExplorer bool, self string) (ok, refused []string) {
	seen := map[string]bool{}
	for _, raw := range list {
		n := normalizeExe(raw)
		if n == "" || seen[n] {
			continue
		}
		seen[n] = true
		if isProtected(raw, allowExplorer, self) {
			refused = append(refused, strings.TrimSpace(raw))
			continue
		}
		ok = append(ok, strings.TrimSpace(raw))
	}
	sort.Strings(ok)
	sort.Strings(refused)
	return ok, refused
}

// filterServices splits a user service list into allowed and refused.
func filterServices(list []string) (ok, refused []string) {
	seen := map[string]bool{}
	for _, raw := range list {
		n := strings.ToLower(strings.TrimSpace(raw))
		if n == "" || seen[n] {
			continue
		}
		seen[n] = true
		if protectedServices[n] {
			refused = append(refused, strings.TrimSpace(raw))
			continue
		}
		ok = append(ok, strings.TrimSpace(raw))
	}
	sort.Strings(ok)
	sort.Strings(refused)
	return ok, refused
}

// matchesExe compares a running image name against a configured one.
func matchesExe(running, configured string) bool {
	return normalizeExe(running) == normalizeExe(configured)
}
