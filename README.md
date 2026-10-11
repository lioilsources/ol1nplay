# Elfton Player

*(repository and code name: Ol1nPlay)*

A local music player for Windows 11 whose only priority is the quality of
the USB output. No streaming, no upsampling, no volume, no EQ. The signal
path is **file → decoder → RAM → ASIO → DAC**, and nothing in between
touches a sample.

```
┌───────────────────────────────┐        ┌──────────────────────┐
│ Flutter desktop UI (Windows)  │◄──────►│ Flutter phone remote  │
│  tree · tracks · now playing  │  WS    │  (LAN, QR pairing)    │
└───────────────┬───────────────┘        └──────────────────────┘
                │ WebSocket, JSON (one protocol for both)
┌───────────────▼─────────────────────────────────────────────┐
│ ol1nplay-engine (Go, one process, no UI)                     │
│  decode/   FFmpeg → native PCM or raw DSD, whole track in RAM│
│  playback/ queue · gapless · SR switching · A-B · mono       │
│  asio/     SDK-free ASIO host, C callback, lock-free ring    │
│  wasapi/   exclusive-mode fallback when there is no ASIO     │
│  library/  folders 1:1 · fsnotify · SQLite cache · covers    │
│  sysmode/  power plan · USB suspend · priorities · processes │
│  api/      WebSocket + cover HTTP · token · mDNS             │
└─────────────────────────────────────────────────────────────┘
```

## What it does

- **Bit-perfect ASIO output** in the track's native format. Sample rate and
  bit depth follow the file; the device is reopened between tracks when
  they differ. The only conversion ever performed is widening an integer
  container with zero bits (16 → 24/32, 24 → 32), which is lossless. Float
  files play as float; if the device cannot take float, the engine says so
  instead of dithering.
- **DSD** (.dsf/.dff): native DSD over ASIO when the driver supports
  `kAsioSetIoFormat`, otherwise DoP, otherwise — only if you opt in —
  FFmpeg's DSD→PCM conversion, clearly flagged as *not bit-perfect*.
- **Whole track in RAM** before it starts (configurable limit, above which
  it streams through a 1.5 s ring buffer). Zero disk IO during playback.
- **Gapless**: the next track is decoded while this one plays and joins
  the ring buffer without a break when the format matches.
- **A-B loop** with sample accuracy; ±10 ms nudges; toggle without losing
  the points. No crossfade by default (it would be DSP).
- **Mono** downmix as the one permitted DSP, done in double precision in
  the callback and flagged in the UI as not bit-perfect while on.
- **Library** = your folders, nothing else. fsnotify keeps it current,
  SQLite caches tags and covers, CUE sheets become tracks, M3U playlists
  load and save, .lrc lyrics scroll.
- **Everything else people expect**: search, favorites, history, play
  counts, queue (play next / reorder), repeat / shuffle, sleep timer,
  resume on start, media keys, system tray, mini player, drag & drop,
  WASAPI exclusive fallback, a phone remote with QR pairing and mDNS.
- **Playback mode** for the system (opt-in, admin): High-performance power
  plan, USB selective suspend off, core parking off, engine at high
  priority, a user-chosen list of processes to suspend and services to
  stop — all logged, all restored on stop, and restored on the next start
  if the engine ever crashed mid-session.
- **Honest readouts**: the now-playing panel shows the real path
  (`FLAC 24/96 → ASIO Int32 · bit-perfect`), underrun counter, ring fill,
  audio thread priority and core, resident RAM.

## What actually matters (the honest part)

If your DAC is an asynchronous USB device — nearly every DAC made in the
last decade — **its own clock drives the conversion**. The computer only
has to deliver the right bits before they are needed. Given that:

| Feature | Effect on the analogue output |
|---|---|
| Bit-perfect path, no volume, no resampling | **Real.** This is the whole point. Any software volume or resampler changes the bits. |
| Native DSD / DoP instead of DSD→PCM | **Real.** DSD→PCM is a lossy conversion. |
| Exclusive device access (ASIO / WASAPI exclusive) | **Real.** Shared mode lets Windows mix and resample. |
| Whole track in RAM | Prevents underruns on slow or busy disks. No effect on sound while there are no underruns. |
| MMCSS "Pro Audio", pinned core, high priority | Prevents underruns under load. No effect on sound while there are no underruns. |
| Power plan, USB selective suspend, core parking | Prevents a USB device from being suspended or a core from waking late. Same caveat. |
| Suspending Discord / OneDrive / the indexer | Frees CPU and IO. Same caveat — and it can break those programs. |
| Mono downmix | Changes the signal on purpose (it is a listening tool, not a quality feature). |

The engine shows an underrun counter precisely so you can see whether any
of the "system" features are doing anything for you: if the counter stays
at zero with them off, they are not. They are implemented because they
cannot hurt the bits and because people expect them — not because they
make a bit-perfect stream more perfect.

## Formats

Everything FFmpeg decodes: FLAC, WAV, AIFF, ALAC, APE, WavPack, TAK, TTA,
MP3, AAC, Vorbis, Opus, Musepack, WMA, DSF, DFF. CUE sheets over any of
them. Gapless MP3/AAC/Opus uses libavcodec's own delay/padding trimming.

## Running

```
ol1nplay-engine serve            # start the engine (the desktop app does this for you)
ol1nplay-engine devices          # list ASIO / WASAPI / CoreAudio devices
ol1nplay-engine play song.flac   # CLI playback with a live status line
ol1nplay-engine play -ab 61000,64500 -mono song.flac
ol1nplay-engine probe song.dsf   # tags + format as JSON
ol1nplay-engine qr               # pairing QR for the phone remote
ol1nplay-engine sysmode status   # what the playback mode changed
```

The desktop app (`app_desktop/`) spawns the engine if it is not running
and connects to `ws://127.0.0.1:7777/ws`. The remote (`app_remote/`) pairs
by scanning the QR from the desktop app's Remote dialog, or finds the
engine via mDNS (`_ol1nplay._tcp`).

Data lives in `%LOCALAPPDATA%\Ol1nPlay` (settings, library DB, covers,
playlists, token, sysmode state). Delete the folder to reset.

## Building

See [BUILD.md](BUILD.md). In short: Go 1.24+, an FFmpeg shared build,
Flutter 3.44; MinGW-w64 if you cross-compile from macOS/Linux. The ASIO SDK
is **not** required — the host interface is declared independently
(`engine/asio/iasio.h`), the way JUCE does it — but Steinberg's licence
terms for the ASIO trademark still apply to anything you distribute; see
[LICENSES.md](LICENSES.md).

## Development on a Mac

The whole pipeline runs on macOS through a CoreAudio backend (hog mode,
nominal rate set to the track, integer formats) so the engine, library,
protocol and UI can be developed and tested without Windows. The Windows
backends compile under `GOOS=windows` with MinGW; they are exercised on a
real machine, not emulated.

## Layout

```
engine/        Go module: cmd/engine, decode, playback, asio, wasapi, sink/{coreaudio,null},
               library/{cue,m3u,lrc}, sysmode, mediakeys, api, protocol, ringbuf, native/rb.h
shared/        Dart package ol1nplay_shared: protocol models, EngineClient, theme, widgets, FakeEngine
app_desktop/   Flutter Windows/macOS app
app_remote/    Flutter iOS/Android remote
```

## Status

The engine, library, protocol and both apps are complete and tested
against each other on macOS (null and CoreAudio backends). The ASIO and
WASAPI backends and the Windows playback mode compile and have unit tests
for everything that does not need a driver; their first contact with real
hardware is the next milestone (see `BUILD.md` → "Testing on Windows").
