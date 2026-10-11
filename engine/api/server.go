// Package api exposes the engine over WebSocket (JSON, protocol package)
// and a small HTTP endpoint for cover images. One protocol serves the
// desktop UI (loopback) and the phone remote (LAN, token-gated).
package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/grandcat/zeroconf"

	"github.com/ol1n/ol1nplay/engine/decode"
	"github.com/ol1n/ol1nplay/engine/library"
	"github.com/ol1n/ol1nplay/engine/mediakeys"
	"github.com/ol1n/ol1nplay/engine/playback"
	"github.com/ol1n/ol1nplay/engine/protocol"
	"github.com/ol1n/ol1nplay/engine/sink"
	"github.com/ol1n/ol1nplay/engine/sysmode"
)

// Version is set by the build (-ldflags "-X ...api.Version=1.0.0").
var Version = "dev"

// Options wire the server to the engine parts.
type Options struct {
	DataDir   string
	LocalPort int // loopback WS+HTTP, default 7777
	Store     *Store
	Library   *library.Library
	Sysmode   *sysmode.Manager
	Log       func(protocol.LogLine)
	// Player is created by the server (it needs the callbacks) unless given.
	Player *playback.Player
}

// Server is the engine front door.
type Server struct {
	opts     Options
	store    *Store
	lib      *library.Library
	player   *playback.Player
	sys      *sysmode.Manager
	token    string
	localSrv *http.Server
	lanSrv   *http.Server
	lanLn    net.Listener
	mdns     *zeroconf.Server
	up       websocket.Upgrader

	mu         sync.Mutex
	clients    map[*client]struct{}
	lastState  protocol.State
	logBuf     []protocol.LogLine
	stopKeys   func()
	resumeAt   time.Time
	sysApplied bool
	closed     bool
}

type client struct {
	conn      *websocket.Conn
	send      chan []byte
	remote    bool // LAN connection: needs hello+token
	authed    bool
	closeOnce sync.Once
}

// New builds the server and the player.
func New(opts Options) (*Server, error) {
	if opts.LocalPort == 0 {
		opts.LocalPort = 7777
	}
	if opts.Log == nil {
		opts.Log = func(protocol.LogLine) {}
	}
	s := &Server{opts: opts, store: opts.Store, lib: opts.Library, sys: opts.Sysmode,
		clients: map[*client]struct{}{},
		up:      websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }, ReadBufferSize: 1 << 16, WriteBufferSize: 1 << 16}}
	if err := s.loadToken(); err != nil {
		return nil, err
	}
	st := s.store.Get()
	if opts.Player != nil {
		s.player = opts.Player
	} else {
		s.player = playback.New(playback.Options{
			Backend: st.Backend, Device: st.Device,
			RAMLimit: int64(st.RAMLimitMB) << 20, PreloadNext: st.PreloadNext,
			DSDMode: st.DSDMode, WidthExtension: st.WidthExtension,
			Resolve:  s.resolve,
			Log:      s.log,
			OnState:  s.onState,
			OnQueue:  func(q protocol.Queue) { s.broadcast(protocol.EvQueue, q) },
			OnPlayed: s.onPlayed,
		})
	}
	s.player.SetMono(st.Mono)
	s.player.SetRepeat(st.Repeat)
	s.player.SetShuffle(st.Shuffle)
	return s, nil
}

// Player exposes the transport (CLI).
func (s *Server) Player() *playback.Player { return s.player }

// Broadcast sends an event to every authenticated client.
func (s *Server) Broadcast(typ string, data any) { s.broadcast(typ, data) }

// RemoteInfo is the pairing information including the token (local use).
func (s *Server) RemoteInfo() protocol.RemoteInfo { return s.remoteInfo(true) }

// Token is the pairing secret.
func (s *Server) Token() string { return s.token }

func (s *Server) loadToken() error {
	p := filepath.Join(s.opts.DataDir, "token")
	b, err := os.ReadFile(p)
	if err == nil && len(strings.TrimSpace(string(b))) >= 16 {
		s.token = strings.TrimSpace(string(b))
		return nil
	}
	return s.rotateToken()
}

func (s *Server) rotateToken() error {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return err
	}
	s.token = hex.EncodeToString(b[:])
	if err := os.MkdirAll(s.opts.DataDir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(s.opts.DataDir, "token"), []byte(s.token), 0o600)
}

func (s *Server) log(l protocol.LogLine) {
	if l.At == 0 {
		l.At = time.Now().UnixMilli()
	}
	s.opts.Log(l)
	s.mu.Lock()
	s.logBuf = append(s.logBuf, l)
	if len(s.logBuf) > 500 {
		s.logBuf = s.logBuf[len(s.logBuf)-500:]
	}
	s.mu.Unlock()
	s.broadcast(protocol.EvLog, l)
	if l.Level == "error" {
		s.broadcast(protocol.EvError, l)
	}
}

func (s *Server) logf(level, scope, msg string, args ...any) {
	s.log(protocol.LogLine{Level: level, Scope: scope, Msg: fmt.Sprintf(msg, args...)})
}

// Start opens the loopback listener (always) and the LAN listener (if
// enabled in settings), restores the last session and hooks media keys.
func (s *Server) Start() error {
	mux := s.mux()
	addr := fmt.Sprintf("127.0.0.1:%d", s.opts.LocalPort)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("api: listen %s: %w", addr, err)
	}
	s.localSrv = &http.Server{Handler: mux}
	go func() { _ = s.localSrv.Serve(ln) }()
	s.logf("info", "api", "listening on ws://%s/ws", addr)

	st := s.store.Get()
	if st.RemoteEnabled {
		if err := s.enableRemote(true); err != nil {
			s.logf("error", "remote", "%v", err)
		}
	}
	if st.MediaKeys {
		s.startMediaKeys()
	}
	if s.sys != nil {
		s.sys.RecoverOnStart()
	}
	if st.ResumeOnStart {
		s.restoreSession()
	}
	go s.resumeSaver()
	return nil
}

// Close shuts everything down and restores the system.
func (s *Server) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	stopKeys := s.stopKeys
	s.mu.Unlock()
	s.saveSession()
	if stopKeys != nil {
		stopKeys()
	}
	s.player.Close()
	if s.sys != nil && s.sys.Applied() {
		if err := s.sys.Restore(); err != nil {
			s.logf("error", "sysmode", "restore: %v", err)
		}
	}
	_ = s.enableRemote(false)
	if s.localSrv != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = s.localSrv.Shutdown(ctx)
		cancel()
	}
}

func (s *Server) mux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", s.handleWS)
	mux.HandleFunc("/cover/", s.handleCover)
	mux.HandleFunc("/cover", s.handleCoverByPath)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		_, _ = fmt.Fprintf(w, "ol1nplay %s\n", Version)
	})
	return mux
}

// ---------------------------------------------------------------- remote

func (s *Server) enableRemote(on bool) error {
	// Logging takes s.mu, so every log line is emitted after the unlock.
	var notes []protocol.LogLine
	defer func() {
		for _, n := range notes {
			s.log(n)
		}
	}()
	note := func(level, msg string, args ...any) {
		notes = append(notes, protocol.LogLine{Level: level, Scope: "remote", Msg: fmt.Sprintf(msg, args...)})
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if on {
		if s.lanSrv != nil {
			return nil
		}
		st := s.store.Get()
		port := st.RemotePort
		ln, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", port))
		if err != nil {
			return fmt.Errorf("remote: listen :%d: %w", port, err)
		}
		s.lanLn = ln
		s.lanSrv = &http.Server{Handler: s.mux()}
		go func() { _ = s.lanSrv.Serve(ln) }()
		note("info", "LAN remote listening on :%d", port)
		if st.MDNS {
			host, _ := os.Hostname()
			srv, err := zeroconf.Register("Elfton Player @ "+host, "_ol1nplay._tcp", "local.", port,
				[]string{fmt.Sprintf("http=%d", port), "name=" + host}, nil)
			if err != nil {
				note("warn", "mDNS: %v", err)
			} else {
				s.mdns = srv
			}
		}
		return nil
	}
	if s.mdns != nil {
		s.mdns.Shutdown()
		s.mdns = nil
	}
	if s.lanSrv != nil {
		srv := s.lanSrv
		s.lanSrv = nil
		s.lanLn = nil
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			_ = srv.Shutdown(ctx)
			cancel()
		}()
		// Drop remote clients: their token may be rotating.
		for c := range s.clients {
			if c.remote {
				c.close()
			}
		}
	}
	return nil
}

func lanAddresses() []string {
	var out []string
	ifs, _ := net.Interfaces()
	for _, i := range ifs {
		if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := i.Addrs()
		for _, a := range addrs {
			if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil && !ipn.IP.IsLinkLocalUnicast() {
				out = append(out, ipn.IP.String())
			}
		}
	}
	return out
}

func (s *Server) remoteInfo(local bool) protocol.RemoteInfo {
	st := s.store.Get()
	s.mu.Lock()
	enabled := s.lanSrv != nil
	n := 0
	for c := range s.clients {
		if c.remote {
			n++
		}
	}
	mdns := s.mdns != nil
	s.mu.Unlock()
	ri := protocol.RemoteInfo{Enabled: enabled, Port: st.RemotePort, HTTPPort: st.RemotePort, Addresses: lanAddresses(), Clients: n, MDNS: mdns}
	if local {
		ri.Token = s.token
		host, _ := os.Hostname()
		if len(ri.Addresses) > 0 {
			ri.QR = fmt.Sprintf("ol1nplay://%s:%d/?token=%s&http=%d&name=%s", ri.Addresses[0], st.RemotePort, s.token, st.RemotePort, host)
		}
	}
	return ri
}

// ---------------------------------------------------------------- HTTP

func (s *Server) handleCover(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/cover/")
	name = strings.TrimSuffix(name, ".jpg")
	thumb := strings.HasSuffix(name, "_t")
	hash := strings.TrimSuffix(name, "_t")
	if s.lib == nil || hash == "" || strings.ContainsAny(hash, "/\\.") {
		http.NotFound(w, r)
		return
	}
	var p string
	var ok bool
	if thumb {
		p, ok = s.lib.ThumbPath(hash)
	} else {
		p, ok = s.lib.CoverPath(hash)
	}
	if !ok {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	http.ServeFile(w, r, p)
}

func (s *Server) handleCoverByPath(w http.ResponseWriter, r *http.Request) {
	if s.lib == nil {
		http.NotFound(w, r)
		return
	}
	h := s.lib.CoverFor(r.URL.Query().Get("path"))
	if h == "" {
		http.NotFound(w, r)
		return
	}
	http.Redirect(w, r, "/cover/"+h+".jpg", http.StatusFound)
}

// ---------------------------------------------------------------- WS

func isLoopback(remoteAddr string) bool {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := s.up.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c := &client{conn: conn, send: make(chan []byte, 256), remote: !isLoopback(r.RemoteAddr)}
	c.authed = !c.remote
	s.mu.Lock()
	s.clients[c] = struct{}{}
	s.mu.Unlock()
	go c.writer()
	// A fresh client gets the current state immediately.
	if c.authed {
		s.sendEvent(c, protocol.EvState, s.player.State())
	}
	s.reader(c)
}

// writer owns the socket's write side and its close: when the send
// channel is closed it flushes what is queued (an "unauthorized" reply,
// for instance) and only then closes the connection.
func (c *client) writer() {
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()
	defer c.conn.Close()
	for {
		select {
		case b, ok := <-c.send:
			if !ok {
				_ = c.conn.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""))
				return
			}
			_ = c.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if err := c.conn.WriteMessage(websocket.TextMessage, b); err != nil {
				return
			}
		case <-ticker.C:
			_ = c.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (c *client) close() {
	c.closeOnce.Do(func() { close(c.send) })
}

func (c *client) push(b []byte) {
	select {
	case c.send <- b:
	default:
		// A client that cannot keep up with 4 state events/s is dropped
		// rather than allowed to back up the engine.
		c.close()
	}
}

func (s *Server) reader(c *client) {
	defer func() {
		s.mu.Lock()
		delete(s.clients, c)
		s.mu.Unlock()
		c.close()
	}()
	c.conn.SetReadLimit(1 << 20)
	_ = c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	c.conn.SetPongHandler(func(string) error { return c.conn.SetReadDeadline(time.Now().Add(60 * time.Second)) })
	for {
		_, msg, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		_ = c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		var req protocol.Request
		if err := json.Unmarshal(msg, &req); err != nil {
			s.reply(c, protocol.Response{ID: req.ID, Type: "result", Error: "bad json"})
			continue
		}
		var raw struct {
			Settings json.RawMessage `json:"settings"`
		}
		_ = json.Unmarshal(msg, &raw)
		if !c.authed {
			if req.Type != protocol.CmdHello || req.Token != s.token {
				s.reply(c, protocol.Response{ID: req.ID, Type: "result", Error: "unauthorized: send hello with a valid token"})
				return
			}
			c.authed = true
		}
		data, err := s.dispatch(c, req, raw.Settings)
		resp := protocol.Response{ID: req.ID, Type: "result", OK: err == nil}
		if err != nil {
			resp.Error = err.Error()
		} else if data != nil {
			b, _ := json.Marshal(data)
			resp.Data = b
		}
		s.reply(c, resp)
		if req.Type == protocol.CmdShutdown && err == nil {
			go s.Close()
		}
	}
}

func (s *Server) reply(c *client, r protocol.Response) {
	b, _ := json.Marshal(r)
	c.push(b)
}

func (s *Server) sendEvent(c *client, typ string, data any) {
	b, _ := json.Marshal(data)
	ev, _ := json.Marshal(protocol.Event{Type: typ, Data: b})
	c.push(ev)
}

func (s *Server) broadcast(typ string, data any) {
	b, _ := json.Marshal(data)
	ev, _ := json.Marshal(protocol.Event{Type: typ, Data: b})
	s.mu.Lock()
	cs := make([]*client, 0, len(s.clients))
	for c := range s.clients {
		if c.authed {
			cs = append(cs, c)
		}
	}
	s.mu.Unlock()
	for _, c := range cs {
		c.push(ev)
	}
}

// ---------------------------------------------------------------- hooks

func (s *Server) onState(st protocol.State) {
	st.Remote = s.remoteInfo(false)
	if s.sys != nil {
		st.Sysmode = s.sys.Get()
	}
	s.mu.Lock()
	prev := s.lastState
	s.lastState = st
	s.mu.Unlock()
	// Playback mode: apply the system tweaks when music starts, undo them
	// when it stops. Both are idempotent in the manager.
	if s.sys != nil && s.sys.Get().Enabled {
		switch {
		case st.Playback == "playing" && prev.Playback != "playing" && !s.sys.Applied():
			go func() {
				if err := s.sys.Apply(); err != nil {
					s.logf("warn", "sysmode", "apply: %v", err)
				}
				s.broadcast(protocol.EvSysmode, s.sys.Get())
			}()
		case st.Playback == "stopped" && prev.Playback != "stopped" && s.sys.Applied():
			go func() {
				if err := s.sys.Restore(); err != nil {
					s.logf("warn", "sysmode", "restore: %v", err)
				}
				s.broadcast(protocol.EvSysmode, s.sys.Get())
			}()
		}
	}
	// Token only to loopback clients: build two payloads.
	local := st
	local.Remote = s.remoteInfo(true)
	bl, _ := json.Marshal(local)
	br, _ := json.Marshal(st)
	evl, _ := json.Marshal(protocol.Event{Type: protocol.EvState, Data: bl})
	evr, _ := json.Marshal(protocol.Event{Type: protocol.EvState, Data: br})
	s.mu.Lock()
	cs := make([]*client, 0, len(s.clients))
	for c := range s.clients {
		if c.authed {
			cs = append(cs, c)
		}
	}
	s.mu.Unlock()
	for _, c := range cs {
		if c.remote {
			c.push(evr)
		} else {
			c.push(evl)
		}
	}
}

func (s *Server) onPlayed(t protocol.Track, complete bool) {
	if s.lib != nil {
		_ = s.lib.RecordPlay(t.Path, complete)
	}
	if complete && s.store.Get().Scrobble {
		f, err := os.OpenFile(filepath.Join(s.opts.DataDir, "scrobble.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err == nil {
			_, _ = fmt.Fprintf(f, "%d\t%s\t%s\t%s\t%d\n", time.Now().Unix(), t.Artist, t.Title, t.Album, t.DurationMs/1000)
			_ = f.Close()
		}
	}
}

func (s *Server) startMediaKeys() {
	ch := make(chan mediakeys.Event, 8)
	stop, err := mediakeys.Start(ch)
	if err != nil {
		s.logf("warn", "mediakeys", "%v", err)
		return
	}
	s.mu.Lock()
	s.stopKeys = stop
	s.mu.Unlock()
	go func() {
		for e := range ch {
			switch e {
			case mediakeys.PlayPause:
				s.player.Toggle()
			case mediakeys.Next:
				s.player.Next()
			case mediakeys.Prev:
				s.player.Prev()
			case mediakeys.Stop:
				s.player.Stop()
			}
		}
	}()
}

func (s *Server) restoreSession() {
	r, ok := loadResume(s.opts.DataDir)
	if !ok {
		return
	}
	tracks := make([]protocol.Track, 0, len(r.Paths))
	for _, p := range r.Paths {
		t, err := s.resolve(p)
		if err == nil {
			tracks = append(tracks, t)
		}
	}
	if len(tracks) == 0 {
		return
	}
	if r.Index >= len(tracks) {
		r.Index = 0
	}
	s.player.QueueSet(tracks, r.Index)
	s.logf("info", "api", "restored queue of %d tracks", len(tracks))
}

func (s *Server) saveSession() {
	q := s.player.Queue()
	st := s.player.State()
	r := Resume{Index: q.Index, PositionMs: st.PositionMs, Mono: st.Mono}
	for _, t := range q.Tracks {
		r.Paths = append(r.Paths, t.Path)
	}
	if len(r.Paths) > 0 {
		saveResume(s.opts.DataDir, r)
	}
}

func (s *Server) resumeSaver() {
	t := time.NewTicker(10 * time.Second)
	defer t.Stop()
	for range t.C {
		s.mu.Lock()
		closed := s.closed
		s.mu.Unlock()
		if closed {
			return
		}
		s.saveSession()
	}
}

// resolve turns a path (or CUE virtual path) into a Track.
func (s *Server) resolve(path string) (protocol.Track, error) {
	if s.lib != nil {
		if t, err := s.lib.Track(path); err == nil {
			return t, nil
		}
	}
	return playback.ProbeTrack(path)
}

func (s *Server) resolveAll(paths []string) ([]protocol.Track, error) {
	out := make([]protocol.Track, 0, len(paths))
	for _, p := range paths {
		t, err := s.resolve(p)
		if err != nil {
			s.logf("warn", "api", "%s: %v", p, err)
			continue
		}
		out = append(out, t)
	}
	if len(out) == 0 {
		return nil, errors.New("no playable tracks")
	}
	return out, nil
}

// ---------------------------------------------------------------- dispatch

func (s *Server) serverInfo() protocol.ServerInfo {
	host, _ := os.Hostname()
	elevated := false
	if s.sys != nil {
		elevated = s.sys.IsElevated()
	}
	return protocol.ServerInfo{Name: "Elfton Player", Version: Version + " / " + decode.Version(), ProtocolVersion: protocol.Version,
		OS: runtime.GOOS, Hostname: host, Elevated: elevated, HTTPPort: s.opts.LocalPort, Backends: sink.Names()}
}

func boolOf(b *bool, def bool) bool {
	if b == nil {
		return def
	}
	return *b
}

func (s *Server) dispatch(c *client, r protocol.Request, rawSettings json.RawMessage) (any, error) {
	p := s.player
	switch r.Type {
	case protocol.CmdHello, protocol.CmdVersion:
		info := s.serverInfo()
		if c.remote {
			info.HTTPPort = s.store.Get().RemotePort
		}
		return info, nil
	case protocol.CmdState:
		st := p.State()
		st.Remote = s.remoteInfo(!c.remote)
		if s.sys != nil {
			st.Sysmode = s.sys.Get()
		}
		if s.lib != nil && st.Track != nil {
			st.Lyrics = s.lib.Lyrics(st.Track.Path)
		}
		return st, nil

	// ---- library
	case protocol.CmdLibraryRoots:
		return s.needLib(func() (any, error) { return s.lib.Roots(), nil })
	case protocol.CmdLibraryRootAdd:
		return s.needLib(func() (any, error) {
			if err := s.lib.AddRoot(r.Path); err != nil {
				return nil, err
			}
			_ = s.store.Update(func(st *protocol.Settings) { st.Roots = rootPaths(s.lib.Roots()) })
			s.broadcast(protocol.EvLibraryChanged, protocol.LibraryChange{Dir: "", Reason: "root"})
			return s.lib.Roots(), nil
		})
	case protocol.CmdLibraryRootRemove:
		return s.needLib(func() (any, error) {
			if err := s.lib.RemoveRoot(r.Path); err != nil {
				return nil, err
			}
			_ = s.store.Update(func(st *protocol.Settings) { st.Roots = rootPaths(s.lib.Roots()) })
			s.broadcast(protocol.EvLibraryChanged, protocol.LibraryChange{Dir: "", Reason: "root", Removed: true})
			return s.lib.Roots(), nil
		})
	case protocol.CmdLibraryRescan:
		return s.needLib(func() (any, error) {
			go func() {
				if err := s.lib.Rescan(r.Dir); err != nil {
					s.logf("error", "library", "rescan: %v", err)
				}
			}()
			return nil, nil
		})
	case protocol.CmdLibraryList:
		return s.needLib(func() (any, error) { return s.lib.List(r.Dir) })
	case protocol.CmdLibraryTree:
		return s.needLib(func() (any, error) { return s.lib.Tree(r.Dir), nil })
	case protocol.CmdLibrarySearch:
		return s.needLib(func() (any, error) {
			limit := r.Limit
			if limit <= 0 {
				limit = 200
			}
			return s.lib.Search(r.Query, limit), nil
		})
	case protocol.CmdLibraryTrack:
		return s.resolve(r.Path)
	case protocol.CmdCover:
		if s.lib == nil {
			return nil, errors.New("no library")
		}
		h := s.lib.CoverFor(r.Path)
		if h == "" {
			return protocol.CoverRef{}, nil
		}
		return protocol.CoverRef{Hash: h, URL: "/cover/" + h + ".jpg"}, nil
	case protocol.CmdLyrics:
		if s.lib == nil {
			return nil, errors.New("no library")
		}
		l := s.lib.Lyrics(r.Path)
		if l == nil {
			return protocol.Lyrics{}, nil
		}
		return l, nil

	// ---- transport
	case protocol.CmdPlay:
		switch {
		case r.Dir != "":
			if s.lib == nil {
				return nil, errors.New("no library")
			}
			l, err := s.lib.List(r.Dir)
			if err != nil {
				return nil, err
			}
			if len(l.Tracks) == 0 {
				return nil, errors.New("directory has no tracks")
			}
			return nil, p.Play(l.Tracks, clampIdx(r.Index, len(l.Tracks)))
		case len(r.Paths) > 0:
			tracks, err := s.resolveAll(r.Paths)
			if err != nil {
				return nil, err
			}
			return nil, p.Play(tracks, clampIdx(r.Index, len(tracks)))
		case r.Path != "":
			t, err := s.resolve(r.Path)
			if err != nil {
				return nil, err
			}
			return nil, p.Play([]protocol.Track{t}, 0)
		default:
			p.Resume()
			return nil, nil
		}
	case protocol.CmdPause:
		p.Pause()
	case protocol.CmdResume:
		p.Resume()
	case protocol.CmdToggle:
		p.Toggle()
	case protocol.CmdStop:
		p.Stop()
	case protocol.CmdNext:
		p.Next()
	case protocol.CmdPrev:
		p.Prev()
	case protocol.CmdSeek:
		if r.Samples > 0 {
			p.SeekFrame(r.Samples)
		} else {
			p.SeekMs(r.Ms)
		}
	case protocol.CmdMono:
		on := boolOf(r.Bool, true)
		p.SetMono(on)
		_ = s.store.Update(func(st *protocol.Settings) { st.Mono = on })
	case protocol.CmdRepeat:
		p.SetRepeat(r.Mode)
		_ = s.store.Update(func(st *protocol.Settings) { st.Repeat = r.Mode })
	case protocol.CmdShuffle:
		on := boolOf(r.Bool, true)
		p.SetShuffle(on)
		_ = s.store.Update(func(st *protocol.Settings) { st.Shuffle = on })

	// ---- A-B
	case protocol.CmdABSetA:
		p.ABSetA(sampleOrNeg(r))
	case protocol.CmdABSetB:
		p.ABSetB(sampleOrNeg(r))
	case protocol.CmdABClear:
		p.ABClear()
	case protocol.CmdABNudge:
		p.ABNudge(strings.ToLower(r.Which), r.Ms)
	case protocol.CmdABToggle:
		p.ABToggle(boolOf(r.Bool, true))

	// ---- queue
	case protocol.CmdQueueGet:
		return p.Queue(), nil
	case protocol.CmdQueueSet:
		tracks, err := s.resolveAll(r.Paths)
		if err != nil {
			return nil, err
		}
		p.QueueSet(tracks, clampIdx(r.Index, len(tracks)))
	case protocol.CmdQueueAdd:
		paths := r.Paths
		if r.Path != "" {
			paths = append(paths, r.Path)
		}
		if r.Dir != "" && s.lib != nil {
			if l, err := s.lib.List(r.Dir); err == nil {
				for _, t := range l.Tracks {
					paths = append(paths, t.Path)
				}
			}
		}
		tracks, err := s.resolveAll(paths)
		if err != nil {
			return nil, err
		}
		p.QueueAdd(tracks)
	case protocol.CmdQueueInsert:
		paths := r.Paths
		if r.Path != "" {
			paths = append(paths, r.Path)
		}
		if r.Dir != "" && s.lib != nil {
			if l, err := s.lib.List(r.Dir); err == nil {
				for _, t := range l.Tracks {
					paths = append(paths, t.Path)
				}
			}
		}
		tracks, err := s.resolveAll(paths)
		if err != nil {
			return nil, err
		}
		p.QueueInsert(tracks)
	case protocol.CmdQueueRemove:
		p.QueueRemove(r.Index)
	case protocol.CmdQueueMove:
		p.QueueMove(r.Index, r.To)
	case protocol.CmdQueueClear:
		p.QueueClear()
	case protocol.CmdQueueJump:
		p.Jump(r.Index)

	// ---- output
	case protocol.CmdDevices:
		return p.Devices(), nil
	case protocol.CmdDeviceSelect:
		if err := p.SetOutput(r.Backend, r.Device); err != nil {
			return nil, err
		}
		_ = s.store.Update(func(st *protocol.Settings) { st.Backend = r.Backend; st.Device = r.Device })
		return p.Output(), nil
	case protocol.CmdOutputStats:
		return p.Stats(), nil
	case protocol.CmdOutputReset:
		return nil, p.ResetOutput()

	// ---- sysmode
	case protocol.CmdSysmodeGet:
		if s.sys == nil {
			return protocol.Sysmode{}, nil
		}
		return s.sys.Get(), nil
	case protocol.CmdSysmodeSet:
		if s.sys == nil || r.Sysmode == nil {
			return nil, errors.New("no sysmode config")
		}
		s.sys.Set(*r.Sysmode)
		s.broadcast(protocol.EvSysmode, s.sys.Get())
		return s.sys.Get(), nil
	case protocol.CmdSysmodeApply:
		if s.sys == nil {
			return nil, errors.New("sysmode unavailable")
		}
		err := s.sys.Apply()
		s.broadcast(protocol.EvSysmode, s.sys.Get())
		return s.sys.Get(), err
	case protocol.CmdSysmodeRestore:
		if s.sys == nil {
			return nil, errors.New("sysmode unavailable")
		}
		err := s.sys.Restore()
		s.broadcast(protocol.EvSysmode, s.sys.Get())
		return s.sys.Get(), err
	case protocol.CmdSysmodeLog:
		if s.sys == nil {
			return []protocol.SysmodeLogEntry{}, nil
		}
		return s.sys.Log(), nil

	// ---- remote
	case protocol.CmdRemoteInfo:
		return s.remoteInfo(!c.remote), nil
	case protocol.CmdRemoteEnable:
		if c.remote {
			return nil, errors.New("only the local UI can change remote access")
		}
		on := boolOf(r.Bool, true)
		if err := s.enableRemote(on); err != nil {
			return nil, err
		}
		_ = s.store.Update(func(st *protocol.Settings) { st.RemoteEnabled = on })
		return s.remoteInfo(true), nil
	case protocol.CmdRemoteRotate:
		if c.remote {
			return nil, errors.New("only the local UI can rotate the token")
		}
		if err := s.rotateToken(); err != nil {
			return nil, err
		}
		s.mu.Lock()
		for cl := range s.clients {
			if cl.remote {
				cl.close()
			}
		}
		s.mu.Unlock()
		return s.remoteInfo(true), nil

	// ---- favorites / history / playlists
	case protocol.CmdFavorites:
		return s.needLib(func() (any, error) { return s.lib.Favorites(), nil })
	case protocol.CmdFavoriteAdd:
		return s.needLib(func() (any, error) { return nil, s.lib.AddFavorite(r.Path) })
	case protocol.CmdFavoriteRemove:
		return s.needLib(func() (any, error) { return nil, s.lib.RemoveFavorite(r.Path) })
	case protocol.CmdHistory:
		return s.needLib(func() (any, error) {
			n := r.Limit
			if n <= 0 {
				n = 100
			}
			return s.lib.History(n), nil
		})
	case protocol.CmdPlaylists:
		return s.needLib(func() (any, error) { return s.lib.Playlists(), nil })
	case protocol.CmdPlaylistLoad:
		return s.needLib(func() (any, error) {
			tracks, err := s.lib.LoadPlaylist(r.Path)
			if err != nil {
				return nil, err
			}
			if len(tracks) == 0 {
				return nil, errors.New("playlist is empty")
			}
			return nil, p.Play(tracks, 0)
		})
	case protocol.CmdPlaylistSave:
		return s.needLib(func() (any, error) {
			q := p.Queue()
			paths := make([]string, 0, len(q.Tracks))
			for _, t := range q.Tracks {
				paths = append(paths, t.Path)
			}
			path, err := s.lib.SavePlaylist(r.Name, paths)
			if err != nil {
				return nil, err
			}
			return protocol.Playlist{Path: path, Name: r.Name, Count: len(paths)}, nil
		})

	// ---- misc
	case protocol.CmdSleepSet:
		p.SleepSet(r.Minutes)
		s.broadcast(protocol.EvSleep, p.State().Sleep)
	case protocol.CmdSleepClear:
		p.SleepClear()
		s.broadcast(protocol.EvSleep, nil)
	case protocol.CmdSettingsGet:
		return s.store.Get(), nil
	case protocol.CmdSettingsSet:
		if len(rawSettings) == 0 {
			return nil, errors.New("settings missing")
		}
		before := s.store.Get()
		st, err := s.store.Patch(rawSettings)
		if err != nil {
			return nil, err
		}
		s.applySettings(before, st)
		return st, nil
	case protocol.CmdShutdown:
		if c.remote {
			return nil, errors.New("only the local UI can shut the engine down")
		}
		return nil, nil
	default:
		return nil, fmt.Errorf("unknown command %q", r.Type)
	}
	return nil, nil
}

func (s *Server) needLib(f func() (any, error)) (any, error) {
	if s.lib == nil {
		return nil, errors.New("no library configured")
	}
	return f()
}

func rootPaths(roots []protocol.Root) []string {
	out := make([]string, 0, len(roots))
	for _, r := range roots {
		out = append(out, r.Path)
	}
	return out
}

func clampIdx(i, n int) int {
	if i < 0 || i >= n {
		return 0
	}
	return i
}

func sampleOrNeg(r protocol.Request) int64 {
	if r.Samples > 0 {
		return r.Samples
	}
	if r.Ms > 0 {
		return -1 // the player converts ms only via SeekMs; callers use samples for A/B
	}
	return -1
}

// applySettings pushes changed preferences into the running parts.
func (s *Server) applySettings(before, after protocol.Settings) {
	if before.Mono != after.Mono {
		s.player.SetMono(after.Mono)
	}
	if before.Repeat != after.Repeat {
		s.player.SetRepeat(after.Repeat)
	}
	if before.Shuffle != after.Shuffle {
		s.player.SetShuffle(after.Shuffle)
	}
	if before.Backend != after.Backend || before.Device != after.Device {
		if err := s.player.SetOutput(after.Backend, after.Device); err != nil {
			s.logf("error", "output", "%v", err)
		}
	}
	if before.RemoteEnabled != after.RemoteEnabled || before.RemotePort != after.RemotePort || before.MDNS != after.MDNS {
		_ = s.enableRemote(false)
		if after.RemoteEnabled {
			if err := s.enableRemote(true); err != nil {
				s.logf("error", "remote", "%v", err)
			}
		}
	}
	if before.MediaKeys != after.MediaKeys {
		s.mu.Lock()
		stop := s.stopKeys
		s.stopKeys = nil
		s.mu.Unlock()
		if stop != nil {
			stop()
		}
		if after.MediaKeys {
			s.startMediaKeys()
		}
	}
	if before.RAMLimitMB != after.RAMLimitMB || before.PreloadNext != after.PreloadNext || before.DSDMode != after.DSDMode || before.WidthExtension != after.WidthExtension {
		s.logf("info", "api", "decoder/output preferences change on the next track")
	}
}
