// ol1nplay-engine: the headless player process. The desktop UI and the
// phone remote talk to it over WebSocket; this file is also a usable CLI.
//
//	ol1nplay-engine                      # serve (default)
//	ol1nplay-engine serve [-port 7777] [-root DIR ...] [-qr]
//	ol1nplay-engine play [-backend asio] [-device ID] [-mono MODE] [-ab A,B(ms)] FILE...
//	ol1nplay-engine devices
//	ol1nplay-engine probe FILE
//	ol1nplay-engine sysmode status|apply|restore
//	ol1nplay-engine qr
//	ol1nplay-engine version
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	qrcode "github.com/skip2/go-qrcode"

	"github.com/ol1n/ol1nplay/engine/api"
	"github.com/ol1n/ol1nplay/engine/decode"
	"github.com/ol1n/ol1nplay/engine/library"
	"github.com/ol1n/ol1nplay/engine/playback"
	"github.com/ol1n/ol1nplay/engine/protocol"
	"github.com/ol1n/ol1nplay/engine/sink"
	"github.com/ol1n/ol1nplay/engine/sysmode"
	"github.com/ol1n/ol1nplay/engine/winrt"

	// Output backends register themselves; import order is irrelevant,
	// sink.Preferred() picks the first one that has a device (null last).
	_ "github.com/ol1n/ol1nplay/engine/asio"
	_ "github.com/ol1n/ol1nplay/engine/sink/coreaudio"
	_ "github.com/ol1n/ol1nplay/engine/sink/null"
	_ "github.com/ol1n/ol1nplay/engine/wasapi"
)

func main() {
	args := os.Args[1:]
	cmd := "serve"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd, args = args[0], args[1:]
	}
	var err error
	switch cmd {
	case "serve":
		err = serve(args)
	case "play":
		err = play(args)
	case "devices":
		err = devices()
	case "probe":
		err = probe(args)
	case "sysmode":
		err = sysmodeCmd(args)
	case "qr":
		err = qr()
	case "version":
		fmt.Printf("ol1nplay-engine %s\n%s\nbackends: %s\n", api.Version, decode.Version(), strings.Join(sink.Names(), ", "))
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", cmd)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// logFile is engine.log in the data directory once serve has opened it.
// The app starts the engine with no console, so without the file a track
// that would not play leaves nothing to look at afterwards.
var (
	logMu   sync.Mutex
	logFile *os.File
)

func stderrLog(l protocol.LogLine) {
	at := time.UnixMilli(l.At)
	fmt.Fprintf(os.Stderr, "%s %-5s %-8s %s\n", at.Format("15:04:05.000"), l.Level, l.Scope, l.Msg)
	logMu.Lock()
	if logFile != nil {
		fmt.Fprintf(logFile, "%s %-5s %-8s %s\n", at.Format("2006-01-02 15:04:05.000"), l.Level, l.Scope, l.Msg)
	}
	logMu.Unlock()
}

// openLogFile appends to engine.log, keeping one previous file once it
// passes 2 MB. Failing to open it is not a reason not to play music.
func openLogFile(dir string) {
	path := filepath.Join(dir, "engine.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 2<<20 {
		_ = os.Remove(path + ".1")
		_ = os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	logMu.Lock()
	logFile = f
	logMu.Unlock()
}

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

func serve(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	port := fs.Int("port", 7777, "loopback WebSocket/HTTP port")
	data := fs.String("data", api.DataDir(), "data directory")
	showQR := fs.Bool("qr", false, "print the pairing QR code when remote is enabled")
	noLib := fs.Bool("no-library", false, "run without the library (CLI-only playback)")
	hide := fs.Bool("hide-console", false, "hide the console window (Windows)")
	parent := fs.Int("parent-pid", 0, "shut down when this process exits (set by the app that started the engine)")
	var roots multiFlag
	fs.Var(&roots, "root", "library root (repeatable; persisted)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *hide {
		winrt.HideConsole()
	}
	if err := os.MkdirAll(*data, 0o755); err != nil {
		return err
	}
	openLogFile(*data)
	store, err := api.OpenStore(*data)
	if err != nil {
		return err
	}
	if len(roots) > 0 {
		_ = store.Update(func(s *protocol.Settings) { s.Roots = append(s.Roots, roots...) })
	}

	// The library is opened before the server exists, so its callbacks
	// reach the clients through a late-bound pointer.
	var srv *api.Server
	var lib *library.Library
	if !*noLib {
		lib, err = library.Open(context.Background(), library.Options{
			DBPath:   filepath.Join(*data, "library.db"),
			CoverDir: filepath.Join(*data, "covers"),
			DataDir:  *data,
			Prober:   decode.Prober{},
			Roots:    store.Get().Roots,
			Log:      stderrLog,
			OnChange: func(c protocol.LibraryChange) {
				if srv != nil {
					srv.Broadcast(protocol.EvLibraryChanged, c)
				}
			},
			OnScan: func(sp protocol.ScanProgress) {
				if srv != nil {
					srv.Broadcast(protocol.EvLibraryScan, sp)
				}
			},
		})
		if err != nil {
			return fmt.Errorf("library: %w", err)
		}
	}
	sys := sysmode.New(*data, stderrLog)

	srv, err = api.New(api.Options{DataDir: *data, LocalPort: *port, Store: store, Library: lib, Sysmode: sys, Log: stderrLog})
	if err != nil {
		return err
	}
	if err := srv.Start(); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "ol1nplay-engine %s ready · %s · data %s\n", api.Version, decode.Version(), *data)
	fmt.Fprintf(os.Stderr, "elevated: %v · windows 11: %v · backends: %s\n", winrt.IsElevated(), winrt.IsWindows11(), strings.Join(sink.Names(), ", "))
	if *showQR {
		printQR(srv)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	var orphaned <-chan struct{}
	if *parent > 0 {
		orphaned = winrt.ParentGone(*parent)
	}
	select {
	case <-sig:
		fmt.Fprintln(os.Stderr, "shutting down")
	case <-orphaned:
		// Whatever happened to the app, music must not keep playing with
		// nothing left to stop it.
		fmt.Fprintf(os.Stderr, "process %d that started the engine is gone; shutting down\n", *parent)
	}
	srv.Close()
	if lib != nil {
		lib.Close()
	}
	return nil
}

func printQR(srv *api.Server) {
	info := srv.RemoteInfo()
	if info.QR == "" {
		fmt.Fprintln(os.Stderr, "remote is disabled or no LAN address; enable it in settings (remoteEnabled) to pair a phone")
		return
	}
	code, err := qrcode.New(info.QR, qrcode.Medium)
	if err != nil {
		return
	}
	fmt.Fprintln(os.Stderr, code.ToSmallString(false))
	fmt.Fprintln(os.Stderr, info.QR)
}

func qr() error {
	data := api.DataDir()
	b, err := os.ReadFile(filepath.Join(data, "token"))
	if err != nil {
		return fmt.Errorf("no token yet – run serve once (%w)", err)
	}
	store, err := api.OpenStore(data)
	if err != nil {
		return err
	}
	st := store.Get()
	host, _ := os.Hostname()
	payload := fmt.Sprintf("ol1nplay://%s:%d/?token=%s&http=%d&name=%s", host, st.RemotePort, strings.TrimSpace(string(b)), st.RemotePort, host)
	code, err := qrcode.New(payload, qrcode.Medium)
	if err != nil {
		return err
	}
	fmt.Println(code.ToSmallString(false))
	fmt.Println(payload)
	return nil
}

func devices() error {
	for _, name := range sink.Names() {
		b, _ := sink.Get(name)
		devs, err := b.Devices()
		if err != nil {
			fmt.Printf("%s: error: %v\n", name, err)
			continue
		}
		for _, d := range devs {
			def := " "
			if d.Default {
				def = "*"
			}
			fmt.Printf("%s %-10s %-40q %s", def, name, d.ID, d.Name)
			if len(d.SampleRates) > 0 {
				fmt.Printf("  rates=%v", d.SampleRates)
			}
			if d.Note != "" {
				fmt.Printf("  (%s)", d.Note)
			}
			fmt.Println()
		}
	}
	return nil
}

func probe(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: probe FILE")
	}
	for _, p := range args {
		m, err := decode.Probe(p)
		if err != nil {
			return err
		}
		pic := len(m.Picture)
		m.Picture = nil
		b, _ := json.MarshalIndent(m, "", "  ")
		fmt.Println(string(b))
		if pic > 0 {
			fmt.Printf("embedded picture: %d bytes (%s)\n", pic, m.PictureMime)
		}
	}
	return nil
}

func sysmodeCmd(args []string) error {
	data := api.DataDir()
	m := sysmode.New(data, stderrLog)
	sub := "status"
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "status":
		b, _ := json.MarshalIndent(m.Get(), "", "  ")
		fmt.Println(string(b))
		for _, e := range m.Log() {
			fmt.Printf("%s %-8s %-30s %s\n", time.UnixMilli(e.At).Format("15:04:05"), e.Action, e.Target, e.Detail)
		}
	case "apply":
		m.RecoverOnStart()
		return m.Apply()
	case "restore":
		m.RecoverOnStart()
		return m.Restore()
	default:
		return fmt.Errorf("usage: sysmode status|apply|restore")
	}
	return nil
}

func play(args []string) error {
	fs := flag.NewFlagSet("play", flag.ExitOnError)
	backend := fs.String("backend", "", "output backend (asio, wasapi, coreaudio, null)")
	device := fs.String("device", "", "device id (see `devices`)")
	mono := fs.String("mono", "stereo", "stereo | mono | left | right (mono downmix, optionally through one speaker) | onlyLeft | onlyRight (one channel, the other muted)")
	ab := fs.String("ab", "", "A-B loop in ms, e.g. 12000,15500")
	dsd := fs.String("dsd", "native", "DSD mode: native|dop|pcm")
	ram := fs.Int("ram", 512, "RAM limit MB before streaming")
	quiet := fs.Bool("quiet", false, "no status line")
	if err := fs.Parse(args); err != nil {
		return err
	}
	files := fs.Args()
	if len(files) == 0 {
		return fmt.Errorf("usage: play [flags] FILE...")
	}
	stopped := make(chan struct{}, 1)
	var p *playback.Player
	p = playback.New(playback.Options{
		Backend: *backend, Device: *device, PreloadNext: true, WidthExtension: true, DSDMode: *dsd,
		RAMLimit: int64(*ram) << 20, Log: stderrLog,
		OnState: func(s protocol.State) {
			if s.Playback == "stopped" {
				select {
				case stopped <- struct{}{}:
				default:
				}
			}
		},
	})
	defer p.Close()
	if err := p.PlayPaths(files, 0); err != nil {
		return err
	}
	p.SetMonoMode(*mono)
	if *ab != "" {
		parts := strings.Split(*ab, ",")
		if len(parts) == 2 {
			a, _ := strconv.ParseInt(parts[0], 10, 64)
			b, _ := strconv.ParseInt(parts[1], 10, 64)
			// Wait for the first state with a format so ms → frames is right.
			for i := 0; i < 200; i++ {
				if s := p.State(); s.Playback == "playing" && s.Source.SampleRate > 0 {
					rate := int64(s.Source.SampleRate)
					p.ABSetA(a * rate / 1000)
					p.ABSetB(b * rate / 1000)
					break
				}
				time.Sleep(25 * time.Millisecond)
			}
		}
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-sig:
			fmt.Fprintln(os.Stderr)
			p.Stop()
			return nil
		case <-stopped:
			if !*quiet {
				fmt.Fprintln(os.Stderr)
			}
			return nil
		case <-tick.C:
			if *quiet {
				continue
			}
			s := p.State()
			title := ""
			if s.Track != nil {
				title = s.Track.Title
				if title == "" {
					title = s.Track.FileName
				}
			}
			bp := "bit-perfect"
			if !s.Output.BitPerfect {
				bp = "NOT bit-perfect: " + s.Output.Conversion
			}
			abs := ""
			if s.AB.Active {
				abs = fmt.Sprintf("  A-B %d–%d ms", s.AB.AMs, s.AB.BMs)
			}
			fmt.Fprintf(os.Stderr, "\r\033[K%-8s %s  %s/%s  %s %d/%d → %s %s %d/%d  %s  underruns %d  ring %.0f%%%s",
				s.Playback, title, fmtMs(s.PositionMs), fmtMs(s.DurationMs),
				s.Source.SampleFormat, s.Source.BitDepth, s.Source.SampleRate,
				s.Output.Backend, s.Output.Format.SampleFormat, s.Output.Format.BitDepth, s.Output.Format.SampleRate,
				bp, s.Output.Underruns, ringPct(p), abs)
		}
	}
}

func ringPct(p *playback.Player) float64 { return p.Stats().RingFillPct }

func fmtMs(ms int64) string {
	s := ms / 1000
	return fmt.Sprintf("%d:%02d", s/60, s%60)
}
