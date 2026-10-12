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

## Install (Windows 11)

In PowerShell — downloads the latest release into
`%LOCALAPPDATA%\Programs\Elfton Player` and adds Start menu and desktop
shortcuts; no administrator rights, nothing else to install:

```powershell
irm https://raw.githubusercontent.com/lioilsources/ol1nplay/main/tools/install.ps1 | iex
```

Or unpack the zip from [Releases](https://github.com/lioilsources/ol1nplay/releases)
anywhere and run `Elfton Player.exe`. For ASIO, install your DAC's own
64-bit ASIO driver; without one the player offers WASAPI exclusive.

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
- **L and R**, two buttons next to Mono, play one speaker and mute the
  other. With Mono on, both sides get the same signal in turn — flip
  between them (from the phone, in the listening seat) to compare the two
  sides of a system. Without Mono, L or R plays that channel's own signal.
- **Seek bar drawn as the track's loudness**, across the whole window, so
  a quiet intro is something you can see and skip.
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
| Lock audio in RAM | Stops Windows paging a decoded track out while it plays. Prevents underruns on a machine short of memory; same caveat. |
| Memory cooltime, helper program (MinorityClean) | Nothing measurable. See below. |

The engine shows an underrun counter precisely so you can see whether any
of the "system" features are doing anything for you: if the counter stays
at zero with them off, they are not. They are implemented because they
cannot hurt the bits and because people expect them — not because they
make a bit-perfect stream more perfect.

## Bug head, MinorityClean and the "rituals"

[Bug head](https://www.softpedia.com/get/Multimedia/Audio/Audio-Players/Bug-head.shtml)
has a reputation as the best-sounding Windows player, and its author
credits a list of techniques: averaging the electrical state of the RAM
chips, a pause after loading, avoiding CALL/RET, 32-bit float output, a
maximum ASIO buffer. Settings → *Rituals* offers the ones that are cheap,
reversible and cannot hurt the bits — all off by default:

- **Lock audio in RAM** — pins each decoded track in physical memory
  (`VirtualLock`). The one item with a plain engineering reason.
- **Memory cooltime** — waits 0–8 s between loading a track and starting
  from silence, as Bug head does. Never applied to a gapless transition.
- **Helper program** — a program of yours that the engine starts with
  itself and stops when it quits. Point it at `MinorityClean.exe` from the
  Bug head package to have it running whenever the player is. It is started
  with normal rights; only the desktop app can set it, never the phone.
- **Largest ASIO buffer** — Settings → Output format → ASIO buffer size:
  *Max*.

MinorityClean itself is **not included and will not be**: it is someone
else's unsigned binary with no licence to redistribute, the same rule that
keeps the ASIO SDK out of this repository.

Not implemented, on purpose:

- **32-bit float output.** It converts every sample; the opposite of
  bit-perfect.
- **A built-in "memory averaging" loop.** Writing patterns to RAM in the
  background is constant memory traffic and CPU load while music plays.
- **Rewriting driver DLLs, switching the antivirus off, banning AVX.**
  Nothing outside the player's own folder is modified, ever.

None of these change what an asynchronous DAC receives — the table above
applies. If you hear a difference with the helper running, the underrun
counter and a null test are the ways to find out what changed.

## Formats

Everything FFmpeg decodes: FLAC, WAV, AIFF, ALAC, APE, WavPack, TAK, TTA,
MP3, AAC, Vorbis, Opus, Musepack, WMA, DSF, DFF. CUE sheets over any of
them. Gapless MP3/AAC/Opus uses libavcodec's own delay/padding trimming.

## Running

```
ol1nplay-engine serve            # start the engine (the desktop app does this for you)
ol1nplay-engine devices          # list ASIO / WASAPI / CoreAudio devices
ol1nplay-engine play song.flac   # CLI playback with a live status line
ol1nplay-engine play -ab 61000,64500 -mono left song.flac
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

The engine, library, protocol and both apps are tested against each other
on macOS (null and CoreAudio backends). 0.1.0 has run on one listener's
Windows 11 machine through ASIO — a Behringer UMC204HD (UMC ASIO Driver)
and an SMSL D200: 24/192 WAV went out as 32-bit ASIO with no conversion
and no underruns, and the phone remote controls it. That is the engine's
own report of its signal path; nobody has yet captured the output and
compared it bit for bit. The Windows playback mode has not been exercised
there (it needs administrator rights) — see `BUILD.md` → "Testing on
Windows" for what is still to be checked. Everything new in 0.2.x has unit
and widget tests but has not yet run on Windows.
