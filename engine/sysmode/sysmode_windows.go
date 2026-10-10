//go:build windows

package sysmode

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

// Power scheme and setting GUIDs (documented in `powercfg /query` output).
const (
	schemeHighPerf = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
	schemeUltimate = "e9a42b02-d5df-448d-aa00-03f14749eb61"

	subUSB        = "2a737441-1930-4402-8d77-b2bebba308a3" // USB settings
	setUSBSuspend = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226" // USB selective suspend setting

	subProcessor  = "54533251-82be-4824-96c1-47b60b740d00" // Processor power management
	setParkingMin = "0cc5b647-c1df-4637-891a-dec35c318583" // Processor performance core parking min cores
	setMinState   = "893dee8e-2bef-41e0-89c6-b55d0929964c" // Minimum processor state
)

var (
	ntdll          = windows.NewLazySystemDLL("ntdll.dll")
	procNtSuspend  = ntdll.NewProc("NtSuspendProcess")
	procNtResume   = ntdll.NewProc("NtResumeProcess")
	winmm          = windows.NewLazySystemDLL("winmm.dll")
	procTimeBegin  = winmm.NewProc("timeBeginPeriod")
	procTimeEnd    = winmm.NewProc("timeEndPeriod")
	guidRe         = regexp.MustCompile(`([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})`)
	acIndexRe      = regexp.MustCompile(`Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)`)
	dcIndexRe      = regexp.MustCompile(`Current DC Power Setting Index:\s*(0x[0-9a-fA-F]+)`)
	processSuspend = uint32(0x0800) // PROCESS_SUSPEND_RESUME
)

func available() bool { return isElevated() }

func isElevated() bool {
	return windows.GetCurrentProcessToken().IsElevated()
}

func selfName() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Base(exe)
}

// ---- powercfg ---------------------------------------------------------------

func powercfg(args ...string) (string, error) {
	cmd := exec.Command("powercfg", args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("powercfg %s: %w (%s)", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

func activeScheme() (string, error) {
	out, err := powercfg("/getactivescheme")
	if err != nil {
		return "", err
	}
	m := guidRe.FindStringSubmatch(out)
	if m == nil {
		return "", errors.New("powercfg: cannot parse active scheme")
	}
	return strings.ToLower(m[1]), nil
}

func hasScheme(guid string) bool {
	out, err := powercfg("/list")
	return err == nil && strings.Contains(strings.ToLower(out), guid)
}

// readIndex returns the current AC/DC indices of a setting as decimal strings.
func readIndex(scheme, sub, setting string) (ac, dc string, err error) {
	out, err := powercfg("/query", scheme, sub, setting)
	if err != nil {
		return "", "", err
	}
	parse := func(re *regexp.Regexp) (string, error) {
		m := re.FindStringSubmatch(out)
		if m == nil {
			return "", errors.New("powercfg: cannot parse setting index")
		}
		v, err := strconv.ParseUint(strings.TrimPrefix(m[1], "0x"), 16, 32)
		if err != nil {
			return "", err
		}
		return strconv.FormatUint(v, 10), nil
	}
	if ac, err = parse(acIndexRe); err != nil {
		return "", "", err
	}
	if dc, err = parse(dcIndexRe); err != nil {
		// Desktops without a battery sometimes omit the DC line.
		dc = ac
	}
	return ac, dc, nil
}

func setIndex(scheme, sub, setting, ac, dc string) error {
	if _, err := powercfg("/setacvalueindex", scheme, sub, setting, ac); err != nil {
		return err
	}
	if _, err := powercfg("/setdcvalueindex", scheme, sub, setting, dc); err != nil {
		return err
	}
	// Index changes take effect only when the scheme is (re)activated.
	_, err := powercfg("/setactive", scheme)
	return err
}

// ---- processes ------------------------------------------------------------------

func listProcesses() ([]proc, error) {
	h, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil, err
	}
	defer windows.CloseHandle(h)
	var pe windows.ProcessEntry32
	pe.Size = uint32(unsafe.Sizeof(pe))
	var out []proc
	for err = windows.Process32First(h, &pe); err == nil; err = windows.Process32Next(h, &pe) {
		out = append(out, proc{PID: pe.ProcessID, Name: windows.UTF16ToString(pe.ExeFile[:])})
	}
	return out, nil
}

func ntCall(p *windows.LazyProc, pid uint32) error {
	h, err := windows.OpenProcess(processSuspend, false, pid)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(h)
	status, _, _ := p.Call(uintptr(h))
	if status != 0 {
		return fmt.Errorf("NTSTATUS 0x%08x", uint32(status))
	}
	return nil
}

func suspendProcess(pid uint32) error { return ntCall(procNtSuspend, pid) }
func resumeProcess(pid uint32) error  { return ntCall(procNtResume, pid) }

func killProcess(pid uint32) error {
	h, err := windows.OpenProcess(windows.PROCESS_TERMINATE, false, pid)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(h)
	return windows.TerminateProcess(h, 1)
}

// ---- services -------------------------------------------------------------------

func withService(name string, f func(s *mgr.Service) error) error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	s, err := m.OpenService(name)
	if err != nil {
		return err
	}
	defer s.Close()
	return f(s)
}

func stopService(name string) (wasRunning bool, err error) {
	err = withService(name, func(s *mgr.Service) error {
		st, err := s.Query()
		if err != nil {
			return err
		}
		if st.State == svc.Stopped || st.State == svc.StopPending {
			return nil
		}
		wasRunning = true
		if _, err := s.Control(svc.Stop); err != nil {
			return err
		}
		deadline := time.Now().Add(15 * time.Second)
		for time.Now().Before(deadline) {
			st, err := s.Query()
			if err != nil {
				return err
			}
			if st.State == svc.Stopped {
				return nil
			}
			time.Sleep(100 * time.Millisecond)
		}
		return errors.New("timeout waiting for service to stop")
	})
	return wasRunning, err
}

func startService(name string) error {
	return withService(name, func(s *mgr.Service) error {
		st, err := s.Query()
		if err != nil {
			return err
		}
		if st.State == svc.Running || st.State == svc.StartPending {
			return nil
		}
		return s.Start()
	})
}

// ---- apply / restore ----------------------------------------------------------

func applyPlatform(m *Manager) error {
	st := m.state
	cfg := m.cfg
	self := selfName()
	var firstErr error
	fail := func(target string, err error) {
		if firstErr == nil {
			firstErr = err
		}
		m.logLocked("error", target, err.Error())
	}

	if cfg.PowerPlan {
		prev, err := activeScheme()
		if err != nil {
			fail("power plan", err)
		} else {
			target := schemeHighPerf
			if hasScheme(schemeUltimate) {
				target = schemeUltimate
			}
			if prev != target {
				st.PowerScheme = prev
				m.persistStateLocked()
				if _, err := powercfg("/setactive", target); err != nil {
					st.PowerScheme = ""
					m.persistStateLocked()
					fail("power plan", err)
				} else {
					m.logLocked("apply", "power plan", prev+" → "+target)
				}
			} else {
				m.logLocked("apply", "power plan", "already "+target)
			}
		}
	}

	scheme, err := activeScheme()
	if err != nil {
		fail("power scheme", err)
	}
	tweak := func(name, sub, setting, value string, slot **acdc) {
		if scheme == "" {
			return
		}
		ac, dc, err := readIndex(scheme, sub, setting)
		if err != nil {
			fail(name, err)
			return
		}
		if ac == value && dc == value {
			m.logLocked("apply", name, "already "+value)
			return
		}
		*slot = &acdc{Scheme: scheme, AC: ac, DC: dc}
		m.persistStateLocked()
		if err := setIndex(scheme, sub, setting, value, value); err != nil {
			*slot = nil
			m.persistStateLocked()
			fail(name, err)
			return
		}
		m.logLocked("apply", name, fmt.Sprintf("AC %s / DC %s → %s", ac, dc, value))
	}
	if cfg.USBSuspend {
		tweak("USB selective suspend", subUSB, setUSBSuspend, "0", &st.USBSuspend)
	}
	if cfg.CoreParking {
		tweak("core parking min cores", subProcessor, setParkingMin, "100", &st.CoreParking)
		tweak("minimum processor state", subProcessor, setMinState, "100", &st.MinProcState)
	}

	if cfg.ProcessPriority {
		prev, err := windows.GetPriorityClass(windows.CurrentProcess())
		if err != nil {
			fail("process priority", err)
		} else if prev != windows.HIGH_PRIORITY_CLASS {
			st.PriorityClass = prev
			m.persistStateLocked()
			// HIGH, never REALTIME: REALTIME starves input and the mouse,
			// and the audio thread already has MMCSS.
			if err := windows.SetPriorityClass(windows.CurrentProcess(), windows.HIGH_PRIORITY_CLASS); err != nil {
				st.PriorityClass = 0
				m.persistStateLocked()
				fail("process priority", err)
			} else {
				m.logLocked("apply", "process priority", "HIGH_PRIORITY_CLASS")
			}
		}
	}

	if cfg.Timer1ms {
		st.Timer1ms = true
		m.persistStateLocked()
		if r, _, _ := procTimeBegin.Call(1); r != 0 {
			st.Timer1ms = false
			m.persistStateLocked()
			fail("timer resolution", fmt.Errorf("timeBeginPeriod returned %d", r))
		} else {
			m.logLocked("apply", "timer resolution", "1 ms")
		}
	}

	okSuspend, refused := filterTargets(cfg.SuspendProcesses, cfg.AllowExplorer, self)
	okKill, refusedKill := filterTargets(cfg.KillProcesses, cfg.AllowExplorer, self)
	for _, r := range append(refused, refusedKill...) {
		m.logLocked("error", r, "refused: protected process")
	}
	if len(okSuspend) > 0 || len(okKill) > 0 {
		procs, err := listProcesses()
		if err != nil {
			fail("process list", err)
		} else {
			for _, p := range procs {
				for _, name := range okSuspend {
					if !matchesExe(p.Name, name) {
						continue
					}
					st.Suspended = append(st.Suspended, p)
					m.persistStateLocked()
					if err := suspendProcess(p.PID); err != nil {
						st.Suspended = st.Suspended[:len(st.Suspended)-1]
						m.persistStateLocked()
						fail(p.Name, fmt.Errorf("suspend pid %d: %w", p.PID, err))
					} else {
						m.logLocked("apply", p.Name, fmt.Sprintf("suspended pid %d", p.PID))
					}
				}
				for _, name := range okKill {
					if !matchesExe(p.Name, name) {
						continue
					}
					if err := killProcess(p.PID); err != nil {
						fail(p.Name, fmt.Errorf("terminate pid %d: %w", p.PID, err))
					} else {
						st.Killed = append(st.Killed, p.Name)
						m.persistStateLocked()
						m.logLocked("apply", p.Name, fmt.Sprintf("terminated pid %d", p.PID))
					}
				}
			}
		}
	}

	okSvc, refusedSvc := filterServices(cfg.StopServices)
	for _, r := range refusedSvc {
		m.logLocked("error", r, "refused: protected service")
	}
	for _, name := range okSvc {
		st.StoppedSvcs = append(st.StoppedSvcs, name)
		m.persistStateLocked()
		wasRunning, err := stopService(name)
		if err != nil {
			fail(name, fmt.Errorf("stop service: %w", err))
			if !wasRunning {
				st.StoppedSvcs = st.StoppedSvcs[:len(st.StoppedSvcs)-1]
				m.persistStateLocked()
			}
			continue
		}
		if !wasRunning {
			st.StoppedSvcs = st.StoppedSvcs[:len(st.StoppedSvcs)-1]
			m.persistStateLocked()
			m.logLocked("apply", name, "service was not running")
			continue
		}
		m.logLocked("apply", name, "service stopped")
	}
	return firstErr
}

func restorePlatform(m *Manager) error {
	st := m.state
	var firstErr error
	fail := func(target string, err error) {
		if firstErr == nil {
			firstErr = err
		}
		m.logLocked("error", target, err.Error())
	}

	// Reverse order of apply.
	var keepSvc []string
	for _, name := range st.StoppedSvcs {
		if err := startService(name); err != nil {
			fail(name, fmt.Errorf("start service: %w", err))
			keepSvc = append(keepSvc, name)
			continue
		}
		m.logLocked("restore", name, "service started")
	}
	st.StoppedSvcs = keepSvc
	m.persistStateLocked()

	var keepProc []proc
	for _, p := range st.Suspended {
		if err := resumeProcess(p.PID); err != nil {
			// The process may simply have exited meanwhile; that is not a
			// failure worth keeping in the state file.
			if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
				m.logLocked("restore", p.Name, fmt.Sprintf("pid %d no longer exists", p.PID))
				continue
			}
			fail(p.Name, fmt.Errorf("resume pid %d: %w", p.PID, err))
			keepProc = append(keepProc, p)
			continue
		}
		m.logLocked("restore", p.Name, fmt.Sprintf("resumed pid %d", p.PID))
	}
	st.Suspended = keepProc
	st.Killed = nil
	m.persistStateLocked()

	if st.Timer1ms {
		procTimeEnd.Call(1)
		st.Timer1ms = false
		m.persistStateLocked()
		m.logLocked("restore", "timer resolution", "released")
	}

	if st.PriorityClass != 0 {
		if err := windows.SetPriorityClass(windows.CurrentProcess(), st.PriorityClass); err != nil {
			fail("process priority", err)
		} else {
			m.logLocked("restore", "process priority", fmt.Sprintf("class 0x%x", st.PriorityClass))
			st.PriorityClass = 0
			m.persistStateLocked()
		}
	}

	untweak := func(name string, sub, setting string, slot **acdc) {
		if *slot == nil {
			return
		}
		s := *slot
		if err := setIndex(s.Scheme, sub, setting, s.AC, s.DC); err != nil {
			fail(name, err)
			return
		}
		m.logLocked("restore", name, fmt.Sprintf("AC %s / DC %s", s.AC, s.DC))
		*slot = nil
		m.persistStateLocked()
	}
	untweak("minimum processor state", subProcessor, setMinState, &st.MinProcState)
	untweak("core parking min cores", subProcessor, setParkingMin, &st.CoreParking)
	untweak("USB selective suspend", subUSB, setUSBSuspend, &st.USBSuspend)

	if st.PowerScheme != "" {
		if _, err := powercfg("/setactive", st.PowerScheme); err != nil {
			fail("power plan", err)
		} else {
			m.logLocked("restore", "power plan", st.PowerScheme)
			st.PowerScheme = ""
			m.persistStateLocked()
		}
	}
	return firstErr
}
