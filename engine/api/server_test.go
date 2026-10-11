package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ol1n/ol1nplay/engine/decode"
	"github.com/ol1n/ol1nplay/engine/library"
	"github.com/ol1n/ol1nplay/engine/protocol"
	_ "github.com/ol1n/ol1nplay/engine/sink/null"
	"github.com/ol1n/ol1nplay/engine/sysmode"
)

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

type wsClient struct {
	t    *testing.T
	c    *websocket.Conn
	id   int64
	evs  chan protocol.Event
	resp chan protocol.Response
}

func dial(t *testing.T, url string) *wsClient {
	t.Helper()
	c, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatal(err)
	}
	w := &wsClient{t: t, c: c, evs: make(chan protocol.Event, 1024), resp: make(chan protocol.Response, 16)}
	go func() {
		for {
			_, msg, err := c.ReadMessage()
			if err != nil {
				close(w.evs)
				return
			}
			var probe struct {
				Type string `json:"type"`
			}
			_ = json.Unmarshal(msg, &probe)
			if probe.Type == "result" {
				var r protocol.Response
				_ = json.Unmarshal(msg, &r)
				w.resp <- r
			} else {
				var e protocol.Event
				_ = json.Unmarshal(msg, &e)
				select {
				case w.evs <- e:
				default:
				}
			}
		}
	}()
	t.Cleanup(func() { c.Close() })
	return w
}

func (w *wsClient) call(req protocol.Request) protocol.Response {
	w.t.Helper()
	w.id++
	req.ID = w.id
	if err := w.c.WriteJSON(req); err != nil {
		w.t.Fatal(err)
	}
	select {
	case r := <-w.resp:
		if r.ID != req.ID {
			w.t.Fatalf("response id %d for request %d", r.ID, req.ID)
		}
		return r
	case <-time.After(5 * time.Second):
		w.t.Fatalf("timeout waiting for %s", req.Type)
	}
	return protocol.Response{}
}

// callRaw sends an arbitrary JSON object (partial settings patches cannot
// be expressed through protocol.Request, whose Settings has no omitempty).
func (w *wsClient) callRaw(m map[string]any) protocol.Response {
	w.t.Helper()
	w.id++
	m["id"] = w.id
	if err := w.c.WriteJSON(m); err != nil {
		w.t.Fatal(err)
	}
	select {
	case r := <-w.resp:
		return r
	case <-time.After(5 * time.Second):
		w.t.Fatalf("timeout waiting for %v", m["type"])
	}
	return protocol.Response{}
}

func (w *wsClient) must(req protocol.Request) json.RawMessage {
	w.t.Helper()
	r := w.call(req)
	if !r.OK {
		w.t.Fatalf("%s: %s", req.Type, r.Error)
	}
	return r.Data
}

func (w *wsClient) waitState(pred func(protocol.State) bool, d time.Duration) protocol.State {
	w.t.Helper()
	deadline := time.After(d)
	for {
		select {
		case e, ok := <-w.evs:
			if !ok {
				w.t.Fatal("connection closed")
			}
			if e.Type == protocol.EvState {
				var s protocol.State
				_ = json.Unmarshal(e.Data, &s)
				if pred(s) {
					return s
				}
			}
		case <-deadline:
			w.t.Fatal("state condition not met")
		}
	}
}

func newServer(t *testing.T, withLib bool) (*Server, int) {
	t.Helper()
	dir := t.TempDir()
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	_ = store.Update(func(s *protocol.Settings) {
		s.Backend = "null"
		s.ResumeOnStart = false
		s.MediaKeys = false
		s.RemotePort = freePort(t)
	})
	var lib *library.Library
	if withLib {
		root := t.TempDir()
		for _, f := range []string{"sine16_44.flac", "sine24_96.flac", "sine_cover.flac"} {
			b, err := os.ReadFile(filepath.Join("..", "testdata", f))
			if err != nil {
				t.Skip("fixtures missing")
			}
			_ = os.WriteFile(filepath.Join(root, f), b, 0o644)
		}
		lib, err = library.Open(context.Background(), library.Options{
			DBPath: filepath.Join(dir, "lib.db"), CoverDir: filepath.Join(dir, "covers"), DataDir: dir,
			Prober: decode.Prober{}, Roots: []string{root}, NoWatch: true,
		})
		if err != nil {
			t.Fatal(err)
		}
		lib.Wait()
		t.Cleanup(lib.Close)
	}
	port := freePort(t)
	srv, err := New(Options{DataDir: dir, LocalPort: port, Store: store, Library: lib, Sysmode: sysmode.New(dir, nil)})
	if err != nil {
		t.Fatal(err)
	}
	if err := srv.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Close)
	return srv, port
}

func TestHelloStateAndPlay(t *testing.T) {
	_, port := newServer(t, true)
	c := dial(t, fmt.Sprintf("ws://127.0.0.1:%d/ws", port))

	var info protocol.ServerInfo
	_ = json.Unmarshal(c.must(protocol.Request{Type: protocol.CmdHello}), &info)
	if info.Name != "Elfton Player" || info.ProtocolVersion != protocol.Version || info.HTTPPort != port {
		t.Fatalf("info = %+v", info)
	}

	var roots []protocol.Root
	_ = json.Unmarshal(c.must(protocol.Request{Type: protocol.CmdLibraryRoots}), &roots)
	if len(roots) != 1 || roots[0].Tracks != 3 {
		t.Fatalf("roots = %+v", roots)
	}
	var listing protocol.Listing
	_ = json.Unmarshal(c.must(protocol.Request{Type: protocol.CmdLibraryList, Dir: roots[0].Path}), &listing)
	if len(listing.Tracks) != 3 {
		t.Fatalf("listing = %+v", listing)
	}

	idx := -1
	for i, t := range listing.Tracks {
		if t.FileName == "sine24_96.flac" {
			idx = i
		}
	}
	c.must(protocol.Request{Type: protocol.CmdPlay, Dir: roots[0].Path, Index: idx})
	s := c.waitState(func(s protocol.State) bool { return s.Playback == "playing" && s.Track != nil }, 5*time.Second)
	if s.Track.FileName != "sine24_96.flac" || s.Output.Backend != "null" || !s.Output.BitPerfect || s.Gain != "0 dB" {
		t.Fatalf("state = %+v", s)
	}
	if s.Source.SampleRate != 96000 || s.Source.BitDepth != 24 {
		t.Fatalf("source = %+v", s.Source)
	}

	c.must(protocol.Request{Type: protocol.CmdMono, Bool: ptr(true)})
	s = c.waitState(func(s protocol.State) bool { return s.Mono }, 2*time.Second)
	if s.Output.BitPerfect {
		t.Fatal("mono must clear bit-perfect")
	}
	c.must(protocol.Request{Type: protocol.CmdMono, Mode: protocol.MonoRight})
	s = c.waitState(func(s protocol.State) bool { return s.MonoMode == protocol.MonoRight }, 2*time.Second)
	if !s.Mono || s.Output.BitPerfect {
		t.Fatalf("right-speaker mono: mono=%v bitPerfect=%v", s.Mono, s.Output.BitPerfect)
	}
	c.must(protocol.Request{Type: protocol.CmdABSetA, Samples: 1000})
	c.must(protocol.Request{Type: protocol.CmdABSetB, Samples: 9000})
	s = c.waitState(func(s protocol.State) bool { return s.AB.Active }, 2*time.Second)
	if s.AB.A != 1000 || s.AB.B != 9000 {
		t.Fatalf("ab = %+v", s.AB)
	}
	c.must(protocol.Request{Type: protocol.CmdABClear})
	c.must(protocol.Request{Type: protocol.CmdPause})
	c.waitState(func(s protocol.State) bool { return s.Playback == "paused" }, 2*time.Second)

	var q protocol.Queue
	_ = json.Unmarshal(c.must(protocol.Request{Type: protocol.CmdQueueGet}), &q)
	if len(q.Tracks) != 3 || q.Index != idx {
		t.Fatalf("queue = %+v", q)
	}

	var devs []protocol.Device
	_ = json.Unmarshal(c.must(protocol.Request{Type: protocol.CmdDevices}), &devs)
	if len(devs) == 0 {
		t.Fatal("no devices")
	}

	// Partial settings merge: only ramLimitMB changes, the rest stays.
	var st protocol.Settings
	r := c.callRaw(map[string]any{"type": protocol.CmdSettingsSet, "settings": map[string]any{"ramLimitMB": 128}})
	if !r.OK {
		t.Fatal(r.Error)
	}
	_ = json.Unmarshal(r.Data, &st)
	if st.RAMLimitMB != 128 || !st.PreloadNext || st.Backend != "null" {
		t.Fatalf("settings merge broke: %+v", st)
	}

	// Cover of the tagged file is served over HTTP.
	var ref protocol.CoverRef
	_ = json.Unmarshal(c.must(protocol.Request{Type: protocol.CmdCover, Path: filepath.Join(roots[0].Path, "sine_cover.flac")}), &ref)
	if ref.Hash == "" {
		t.Fatal("no cover hash")
	}
	c.must(protocol.Request{Type: protocol.CmdStop})
	c.waitState(func(s protocol.State) bool { return s.Playback == "stopped" }, 2*time.Second)
}

func ptr(b bool) *bool { return &b }

func TestRemoteNeedsToken(t *testing.T) {
	srv, port := newServer(t, false)
	local := dial(t, fmt.Sprintf("ws://127.0.0.1:%d/ws", port))
	var ri protocol.RemoteInfo
	_ = json.Unmarshal(local.must(protocol.Request{Type: protocol.CmdRemoteEnable, Bool: ptr(true)}), &ri)
	if !ri.Enabled || ri.Token != srv.Token() || ri.Port == 0 {
		t.Fatalf("remote info = %+v", ri)
	}
	// Loopback through the LAN listener still counts as local; emulate a
	// remote by dialing the LAN port from a non-loopback address if any.
	addrs := lanAddresses()
	if len(addrs) == 0 {
		t.Skip("no LAN address on this machine")
	}
	url := fmt.Sprintf("ws://%s:%d/ws", addrs[0], ri.Port)
	bad := dial(t, url)
	r := bad.call(protocol.Request{Type: protocol.CmdState})
	if r.OK {
		t.Fatal("remote without hello must be refused")
	}
	wrong := dial(t, url)
	if r := wrong.call(protocol.Request{Type: protocol.CmdHello, Token: "nope"}); r.OK {
		t.Fatal("wrong token accepted")
	}
	good := dial(t, url)
	good.must(protocol.Request{Type: protocol.CmdHello, Token: srv.Token()})
	var st protocol.State
	_ = json.Unmarshal(good.must(protocol.Request{Type: protocol.CmdState}), &st)
	if st.Remote.Token != "" || st.Remote.QR != "" {
		t.Fatal("token leaked to a remote client")
	}
	if r := good.call(protocol.Request{Type: protocol.CmdRemoteRotate}); r.OK {
		t.Fatal("remote client must not rotate the token")
	}
}
