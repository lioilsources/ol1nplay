// Package protocol is the single wire contract between the engine and every
// client (desktop UI, mobile remote, CLI). It is plain JSON over WebSocket.
//
// Requests carry an "id" the client chooses; the engine answers with one
// Response that echoes it. Events have no id and may arrive at any time.
// Everything the desktop UI can do, the remote can do: there is one protocol.
//
// Positions are expressed in sample frames of the *current track* so that the
// A-B loop is sample-accurate; millisecond mirrors are included for display.
package protocol

import "encoding/json"

// Version is bumped whenever a message shape changes incompatibly.
const Version = 1

// Request is any client → engine message.
type Request struct {
	ID   int64  `json:"id"`
	Type string `json:"type"`

	// Payload fields; which ones apply depends on Type (see Cmd*).
	Token    string    `json:"token,omitempty"`
	Path     string    `json:"path,omitempty"`
	Paths    []string  `json:"paths,omitempty"`
	Dir      string    `json:"dir,omitempty"`
	Index    int       `json:"index,omitempty"`
	To       int       `json:"to,omitempty"`
	Query    string    `json:"query,omitempty"`
	Limit    int       `json:"limit,omitempty"`
	Samples  int64     `json:"samples,omitempty"`
	Ms       int64     `json:"ms,omitempty"`
	Bool     *bool     `json:"bool,omitempty"`
	Mode     string    `json:"mode,omitempty"`
	Which    string    `json:"which,omitempty"` // ab.nudge: "a" | "b"
	Device   string    `json:"device,omitempty"`
	Backend  string    `json:"backend,omitempty"`
	Name     string    `json:"name,omitempty"`
	Minutes  int       `json:"minutes,omitempty"`
	Sysmode  *Sysmode  `json:"sysmode,omitempty"`
	Settings *Settings `json:"settings,omitempty"`
}

// Response answers exactly one Request.
type Response struct {
	ID    int64           `json:"id"`
	Type  string          `json:"type"` // always "result"
	OK    bool            `json:"ok"`
	Error string          `json:"error,omitempty"`
	Data  json.RawMessage `json:"data,omitempty"`
}

// Event is an unsolicited engine → client message.
type Event struct {
	Type string          `json:"type"` // Ev*
	Data json.RawMessage `json:"data,omitempty"`
}

// Command types (Request.Type).
const (
	CmdHello = "hello" // Token → ServerInfo. Must be first on a remote (LAN) connection.
	CmdState = "state" // → State

	CmdLibraryRoots      = "library.roots"        // → []Root
	CmdLibraryRootAdd    = "library.roots.add"    // Path
	CmdLibraryRootRemove = "library.roots.remove" // Path
	CmdLibraryRescan     = "library.rescan"       // Dir (optional; empty = everything)
	CmdLibraryList       = "library.list"         // Dir → Listing
	CmdLibraryTree       = "library.tree"         // Dir → []DirNode (one level)
	CmdLibrarySearch     = "library.search"       // Query, Limit → []Track
	CmdLibraryTrack      = "library.track"        // Path → Track

	CmdPlay    = "play" // Path (single) or Paths+Index (replace queue) or Dir+Index (whole directory)
	CmdPause   = "pause"
	CmdResume  = "resume"
	CmdToggle  = "toggle"
	CmdStop    = "stop"
	CmdNext    = "next"
	CmdPrev    = "prev"
	CmdSeek    = "seek"    // Samples or Ms (Samples wins if non-zero)
	CmdMono    = "mono"    // Bool
	CmdRepeat  = "repeat"  // Mode: off | one | all
	CmdShuffle = "shuffle" // Bool

	CmdABSetA   = "ab.setA" // Samples (optional; default = current position)
	CmdABSetB   = "ab.setB" // Samples (optional; default = current position)
	CmdABClear  = "ab.clear"
	CmdABNudge  = "ab.nudge"  // Which ("a"|"b"), Ms (signed)
	CmdABToggle = "ab.toggle" // Bool – enable/disable without losing points

	CmdQueueGet    = "queue.get"    // → Queue
	CmdQueueSet    = "queue.set"    // Paths, Index
	CmdQueueAdd    = "queue.add"    // Paths (append) or Path
	CmdQueueInsert = "queue.insert" // Paths, Index (play-next semantics)
	CmdQueueRemove = "queue.remove" // Index
	CmdQueueMove   = "queue.move"   // Index, To
	CmdQueueClear  = "queue.clear"
	CmdQueueJump   = "queue.jump" // Index

	CmdDevices      = "devices"       // → []Device (all backends)
	CmdDeviceSelect = "device.select" // Backend, Device
	CmdOutputStats  = "output.stats"  // → OutputStats
	CmdOutputReset  = "output.reset"  // re-open the device (after driver change)

	CmdSysmodeGet     = "sysmode.get"     // → Sysmode
	CmdSysmodeSet     = "sysmode.set"     // Sysmode (config only; applies on next play if Enabled)
	CmdSysmodeApply   = "sysmode.apply"   // force apply now
	CmdSysmodeRestore = "sysmode.restore" // force restore now
	CmdSysmodeLog     = "sysmode.log"     // → []SysmodeLogEntry

	CmdRemoteInfo   = "remote.info"   // → RemoteInfo (token, port, QR payload)
	CmdRemoteEnable = "remote.enable" // Bool
	CmdRemoteRotate = "remote.rotate" // new token

	CmdFavorites      = "favorites"        // → []Track
	CmdFavoriteAdd    = "favorites.add"    // Path
	CmdFavoriteRemove = "favorites.remove" // Path
	CmdHistory        = "history"          // Limit → []HistoryEntry
	CmdPlaylists      = "playlists"        // → []Playlist (M3U files found in roots + app dir)
	CmdPlaylistLoad   = "playlist.load"    // Path → replaces queue
	CmdPlaylistSave   = "playlist.save"    // Name → saves current queue as M3U8
	CmdSleepSet       = "sleep.set"        // Minutes
	CmdSleepClear     = "sleep.clear"
	CmdSettingsGet    = "settings.get" // → Settings
	CmdSettingsSet    = "settings.set" // Settings (partial merge)
	CmdLyrics         = "lyrics"       // Path → Lyrics (sidecar .lrc / .txt or tag)
	CmdCover          = "cover"        // Path → CoverRef (clients fetch via HTTP)
	CmdVersion        = "version"      // → ServerInfo
	CmdShutdown       = "shutdown"
)

// Event types (Event.Type).
const (
	EvState          = "state"           // State (full snapshot; sent on every change and every ~250 ms while playing)
	EvQueue          = "queue"           // Queue
	EvLibraryChanged = "library.changed" // LibraryChange
	EvLibraryScan    = "library.scan"    // ScanProgress
	EvLog            = "log"             // LogLine
	EvSysmode        = "sysmode"         // Sysmode
	EvOutput         = "output"          // OutputStats (underrun etc.)
	EvError          = "error"           // LogLine with Level="error"
	EvSleep          = "sleep"           // SleepTimer
)

// ServerInfo answers hello/version.
type ServerInfo struct {
	Name            string   `json:"name"`
	Version         string   `json:"version"`
	ProtocolVersion int      `json:"protocolVersion"`
	OS              string   `json:"os"`
	Hostname        string   `json:"hostname"`
	Elevated        bool     `json:"elevated"` // engine runs as admin (sysmode available)
	HTTPPort        int      `json:"httpPort"` // covers: GET /cover/{hash}.jpg, GET /cover?path=...
	Backends        []string `json:"backends"` // e.g. ["asio","wasapi"] or ["coreaudio","null"]
}

// Root is a library root directory.
type Root struct {
	Path     string `json:"path"`
	Tracks   int    `json:"tracks"`
	Dirs     int    `json:"dirs"`
	Scanning bool   `json:"scanning"`
	LastScan int64  `json:"lastScan"` // unix ms, 0 = never
	Missing  bool   `json:"missing"`  // drive unplugged etc.
}

// DirNode is a directory in the tree; children are lazily requested.
type DirNode struct {
	Path    string `json:"path"`
	Name    string `json:"name"`
	HasDirs bool   `json:"hasDirs"`
	Tracks  int    `json:"tracks"`          // direct children only
	Cover   string `json:"cover,omitempty"` // cover hash, if any
}

// Listing is the content of one directory.
type Listing struct {
	Dir    string     `json:"dir"`
	Parent string     `json:"parent,omitempty"`
	Dirs   []DirNode  `json:"dirs"`
	Tracks []Track    `json:"tracks"`
	Cover  string     `json:"cover,omitempty"`
	Cue    []CueSheet `json:"cue,omitempty"`
}

// Track is one playable file (or one CUE track within a file).
type Track struct {
	Path        string  `json:"path"`
	Dir         string  `json:"dir"`
	FileName    string  `json:"fileName"`
	Title       string  `json:"title"`
	Artist      string  `json:"artist"`
	AlbumArtist string  `json:"albumArtist,omitempty"`
	Album       string  `json:"album"`
	TrackNo     int     `json:"trackNo"`
	DiscNo      int     `json:"discNo,omitempty"`
	Year        int     `json:"year,omitempty"`
	Genre       string  `json:"genre,omitempty"`
	Composer    string  `json:"composer,omitempty"`
	Comment     string  `json:"comment,omitempty"`
	Codec       string  `json:"codec"`     // "flac", "alac", "dsd", "mp3", ...
	Container   string  `json:"container"` // "flac", "mov,mp4,m4a...", "wav"
	SampleRate  int     `json:"sampleRate"`
	BitDepth    int     `json:"bitDepth"` // 0 for lossy / float
	Channels    int     `json:"channels"`
	Lossless    bool    `json:"lossless"`
	DSD         bool    `json:"dsd"`
	Bitrate     int     `json:"bitrate"` // kbps, lossy only
	DurationMs  int64   `json:"durationMs"`
	Samples     int64   `json:"samples"` // total frames if known
	SizeBytes   int64   `json:"sizeBytes"`
	ModTime     int64   `json:"modTime"`              // unix ms
	Cover       string  `json:"cover,omitempty"`      // cover hash
	ReplayGain  float64 `json:"replayGain,omitempty"` // displayed, never applied
	Favorite    bool    `json:"favorite"`
	PlayCount   int     `json:"playCount"`
	LastPlayed  int64   `json:"lastPlayed,omitempty"`
	HasLyrics   bool    `json:"hasLyrics"`

	// CUE sub-track: offset within the physical file.
	CueFile  string `json:"cueFile,omitempty"`
	CueStart int64  `json:"cueStart,omitempty"` // frames
	CueEnd   int64  `json:"cueEnd,omitempty"`   // frames, 0 = end of file
}

// CueSheet is a parsed .cue file.
type CueSheet struct {
	Path   string  `json:"path"`
	Title  string  `json:"title"`
	Artist string  `json:"artist"`
	File   string  `json:"file"` // referenced audio file
	Tracks []Track `json:"tracks"`
}

// Format describes a PCM stream exactly.
type Format struct {
	SampleRate   int    `json:"sampleRate"`
	BitDepth     int    `json:"bitDepth"` // meaningful bits (16, 24, 32), 0 for float
	Channels     int    `json:"channels"`
	SampleFormat string `json:"sampleFormat"`      // "s16", "s24", "s32", "f32", "dsd", "dop"
	DSDRate      int    `json:"dsdRate,omitempty"` // DSD64 = 2822400
}

// Output is the current state of the output device.
type Output struct {
	Backend      string  `json:"backend"` // "asio" | "wasapi" | "coreaudio" | "null"
	Device       string  `json:"device"`  // driver / endpoint name
	DeviceID     string  `json:"deviceId"`
	Status       string  `json:"status"` // "closed" | "open" | "running" | "error"
	Error        string  `json:"error,omitempty"`
	Format       Format  `json:"format"` // what the device is actually running
	BufferFrames int     `json:"bufferFrames"`
	LatencyMs    float64 `json:"latencyMs"`
	BitPerfect   bool    `json:"bitPerfect"`           // true when no conversion other than zero-LSB width extension happened
	Conversion   string  `json:"conversion,omitempty"` // human description if not bit-perfect ("24→32 bit zero-padded" is still bit-perfect)
	Underruns    int64   `json:"underruns"`
	Exclusive    bool    `json:"exclusive"`
	NativeDSD    bool    `json:"nativeDSD"`
	DoP          bool    `json:"dop"`
}

// OutputStats is the hot counter set.
type OutputStats struct {
	Underruns      int64   `json:"underruns"`
	CallbackCount  int64   `json:"callbacks"`
	RingFillPct    float64 `json:"ringFillPct"`
	MaxCallbackUs  int64   `json:"maxCallbackUs"`
	LastUnderrunAt int64   `json:"lastUnderrunAt,omitempty"`
	ThreadPriority string  `json:"threadPriority"` // "Pro Audio/critical", "time-constraint", "normal"
	CPUCore        int     `json:"cpuCore"`        // -1 = not pinned
}

// ABLoop is the sample-accurate loop.
type ABLoop struct {
	A       int64 `json:"a"`       // frames, -1 = unset
	B       int64 `json:"b"`       // frames, -1 = unset
	Active  bool  `json:"active"`  // both set and enabled
	Enabled bool  `json:"enabled"` // user toggle
	AMs     int64 `json:"aMs"`
	BMs     int64 `json:"bMs"`
}

// State is the full now-playing snapshot.
type State struct {
	Playback   string      `json:"playback"` // "stopped" | "playing" | "paused" | "loading"
	Track      *Track      `json:"track,omitempty"`
	Position   int64       `json:"position"` // frames
	PositionMs int64       `json:"positionMs"`
	Duration   int64       `json:"duration"` // frames
	DurationMs int64       `json:"durationMs"`
	Source     Format      `json:"source"` // decoded format (native, untouched)
	Output     Output      `json:"output"`
	Mono       bool        `json:"mono"`
	AB         ABLoop      `json:"ab"`
	Repeat     string      `json:"repeat"` // "off" | "one" | "all"
	Shuffle    bool        `json:"shuffle"`
	QueueIndex int         `json:"queueIndex"`
	QueueLen   int         `json:"queueLen"`
	NextTrack  *Track      `json:"nextTrack,omitempty"` // pre-decoded for gapless
	Preloaded  bool        `json:"preloaded"`           // next track is fully in RAM
	RAMBytes   int64       `json:"ramBytes"`            // bytes of PCM resident
	Gain       string      `json:"gain"`                // always "0 dB" – there is no volume
	Sysmode    Sysmode     `json:"sysmode"`
	Sleep      *SleepTimer `json:"sleep,omitempty"`
	Remote     RemoteInfo  `json:"remote"`
	Lyrics     *Lyrics     `json:"lyrics,omitempty"`
}

// Queue is the play queue.
type Queue struct {
	Index   int     `json:"index"`
	Tracks  []Track `json:"tracks"`
	Shuffle bool    `json:"shuffle"`
	Repeat  string  `json:"repeat"`
}

// Device is one selectable output.
type Device struct {
	Backend     string   `json:"backend"`
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Default     bool     `json:"default"`
	Selected    bool     `json:"selected"`
	SampleRates []int    `json:"sampleRates,omitempty"` // probed, if the backend can
	Formats     []string `json:"formats,omitempty"`
	MaxChannels int      `json:"maxChannels,omitempty"`
	Note        string   `json:"note,omitempty"`
}

// Sysmode is the "playback mode" system tweak configuration + status.
type Sysmode struct {
	Enabled          bool     `json:"enabled"`
	PowerPlan        bool     `json:"powerPlan"`        // switch to High performance
	USBSuspend       bool     `json:"usbSuspend"`       // disable USB selective suspend
	CoreParking      bool     `json:"coreParking"`      // disable core parking / min CPU 100 %
	ProcessPriority  bool     `json:"processPriority"`  // HIGH_PRIORITY_CLASS
	SuspendProcesses []string `json:"suspendProcesses"` // exe names to NtSuspendProcess
	KillProcesses    []string `json:"killProcesses"`    // exe names to terminate (restarted? no – user's choice)
	StopServices     []string `json:"stopServices"`     // service names to stop
	PinCore          int      `json:"pinCore"`          // audio thread affinity, -1 = auto (last core)
	Timer1ms         bool     `json:"timer1ms"`         // timeBeginPeriod(1)
	// Status
	Applied   bool     `json:"applied"`
	Available bool     `json:"available"` // elevated + Windows
	Changes   []string `json:"changes"`   // human list of what is currently changed
	Template  []string `json:"template"`  // recommended suspend list for the UI to offer
}

// SysmodeLogEntry is one line of "what I changed".
type SysmodeLogEntry struct {
	At     int64  `json:"at"`
	Action string `json:"action"` // "apply" | "restore" | "error" | "recover"
	Target string `json:"target"`
	Detail string `json:"detail"`
}

// RemoteInfo is what the QR code carries.
type RemoteInfo struct {
	Enabled   bool     `json:"enabled"`
	Port      int      `json:"port"`
	HTTPPort  int      `json:"httpPort"`
	Token     string   `json:"token,omitempty"` // only sent to local (loopback) clients
	Addresses []string `json:"addresses"`       // LAN IPs
	QR        string   `json:"qr,omitempty"`    // "ol1nplay://host:port/?token=..." – only to loopback
	Clients   int      `json:"clients"`
	MDNS      bool     `json:"mdns"`
}

// LibraryChange tells clients what to refresh.
type LibraryChange struct {
	Dir     string `json:"dir"`
	Reason  string `json:"reason"` // "fsnotify" | "scan" | "root"
	Removed bool   `json:"removed"`
}

// ScanProgress reports an ongoing scan.
type ScanProgress struct {
	Root     string `json:"root"`
	Done     int    `json:"done"`
	Total    int    `json:"total"`
	Current  string `json:"current"`
	Finished bool   `json:"finished"`
}

// LogLine is a user-visible log message.
type LogLine struct {
	At    int64  `json:"at"`
	Level string `json:"level"` // "info" | "warn" | "error"
	Scope string `json:"scope"` // "asio", "decode", "library", "sysmode", ...
	Msg   string `json:"msg"`
}

// HistoryEntry is one playback.
type HistoryEntry struct {
	Track    Track `json:"track"`
	PlayedAt int64 `json:"playedAt"`
	Complete bool  `json:"complete"`
}

// Playlist is an M3U file.
type Playlist struct {
	Path  string `json:"path"`
	Name  string `json:"name"`
	Count int    `json:"count"`
}

// SleepTimer stops playback at EndsAt.
type SleepTimer struct {
	EndsAt  int64 `json:"endsAt"` // unix ms
	Minutes int   `json:"minutes"`
}

// Lyrics is sidecar or embedded lyrics; Lines is non-empty for LRC.
type Lyrics struct {
	Text   string      `json:"text,omitempty"`
	Lines  []LyricLine `json:"lines,omitempty"`
	Source string      `json:"source"` // "lrc" | "txt" | "tag" | ""
}

// LyricLine is one timed line.
type LyricLine struct {
	Ms   int64  `json:"ms"`
	Text string `json:"text"`
}

// CoverRef tells clients how to fetch a cover.
type CoverRef struct {
	Hash string `json:"hash"`
	URL  string `json:"url"` // "/cover/<hash>.jpg"
}

// Settings are persisted engine preferences.
type Settings struct {
	Backend          string   `json:"backend"`
	Device           string   `json:"device"`
	Mono             bool     `json:"mono"`
	Repeat           string   `json:"repeat"`
	Shuffle          bool     `json:"shuffle"`
	RAMLimitMB       int      `json:"ramLimitMB"`  // above this, stream from disk
	PreloadNext      bool     `json:"preloadNext"` // gapless preload
	ResumeOnStart    bool     `json:"resumeOnStart"`
	ABCrossfadeMs    int      `json:"abCrossfadeMs"`    // 0 = off (default; it is DSP)
	DSDMode          string   `json:"dsdMode"`          // "native" | "dop" | "pcm" (pcm = FFmpeg conversion, not bit-perfect)
	WidthExtension   bool     `json:"widthExtension"`   // allow 16/24 → 32 zero-padding when the device demands it
	BufferPreference string   `json:"bufferPreference"` // "preferred" | "max" | "min"
	RemoteEnabled    bool     `json:"remoteEnabled"`
	RemotePort       int      `json:"remotePort"`
	MDNS             bool     `json:"mdns"`
	MediaKeys        bool     `json:"mediaKeys"`
	Scrobble         bool     `json:"scrobble"` // writes a local scrobble log (last.fm export format)
	Roots            []string `json:"roots"`
	Theme            string   `json:"theme"` // "system" | "dark" | "light" – stored here so remote + desktop agree
}
