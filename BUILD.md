# Building Ol1nPlay

## Prerequisites

| Part | Needs |
|---|---|
| Engine (Go) | Go 1.24+, a C compiler, FFmpeg **shared** libraries (libavformat/libavcodec/libavutil) with headers |
| Engine on Windows | MSYS2/MinGW-w64 (`pacman -S mingw-w64-x86_64-gcc`), or cross-compile from macOS/Linux with `brew install mingw-w64` / `apt install gcc-mingw-w64-x86-64` |
| Desktop app | Flutter 3.44+, Visual Studio 2022 "Desktop development with C++" (Windows) or Xcode (macOS) |
| Remote app | Flutter 3.44+, Xcode and/or Android SDK |

No ASIO SDK is needed to compile. `engine/asio/iasio.h` declares the IASIO
COM interface independently (same approach as JUCE 6+). Read
`LICENSES.md` before distributing.

## Engine

### macOS / Linux (development)

```
brew install go ffmpeg pkgconf          # macOS
cd engine && go build -o bin/ol1nplay-engine ./cmd/engine
go test ./...                           # uses the null backend + CoreAudio enumeration
```

`decode` finds FFmpeg through `pkg-config`. The CoreAudio backend is built
automatically on macOS.

### Windows, native (MSYS2 MINGW64 shell)

```
pacman -S mingw-w64-x86_64-go mingw-w64-x86_64-gcc mingw-w64-x86_64-ffmpeg
cd engine
go build -ldflags "-s -w" -o bin/ol1nplay-engine.exe ./cmd/engine
```

With MSYS2's FFmpeg the `pkg-config` path works as on macOS. If you use a
downloaded FFmpeg build instead, follow the cross-compile layout below.

### Cross-compile for Windows from macOS/Linux

1. Download a Windows **shared** FFmpeg build (LGPL or GPL — see
   LICENSES.md), e.g. from https://github.com/BtbN/FFmpeg-Builds/releases
   (`ffmpeg-*-win64-gpl-shared.zip` or `-lgpl-shared`).
2. Unpack so that these exist (the folder is git-ignored):
   ```
   engine/ffmpeg-win/include/libavformat/avformat.h
   engine/ffmpeg-win/lib/avformat.lib  (or libavformat.dll.a)
   engine/ffmpeg-win/bin/avformat-*.dll ...
   ```
3. Build:
   ```
   make engine-windows
   # = cd engine && CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc \
   #     go build -o bin/ol1nplay-engine.exe ./cmd/engine
   ```
4. Ship `ol1nplay-engine.exe` together with `avcodec-*.dll`,
   `avformat-*.dll`, `avutil-*.dll`, `swresample-*.dll` (`make dist-windows`
   copies them to `dist/windows/engine/`).

The engine links `ole32 oleaut32 uuid avrt winmm ksuser ntdll`, all part of
Windows.

### Tests and checks

```
make test        # go test ./...  (decode fixtures in engine/testdata, regenerate with make fixtures)
make test-race
make vet         # native + GOOS=windows vet of the Windows-only packages
make lint        # + gofmt
```

The decoder test compares our output byte-for-byte with the `ffmpeg` CLI
for FLAC 16/24, WAV 24 and ALAC 24; the playback test plays through the
null backend and checks the bytes that reach the "device" are identical to
the file, across gapless joins and sample-rate changes.

## Flutter apps

```
cd shared      && flutter pub get && flutter test
cd app_desktop && flutter pub get && flutter build windows   # or: flutter run -d macos
cd app_remote  && flutter pub get && flutter build apk / ios
```

The desktop app expects the engine at `engine/ol1nplay-engine.exe` next to
its own executable (it spawns it on start if nothing answers on
`ws://127.0.0.1:7777/ws`). `--engine=ws://host:7778/ws?token=…` points it at
another machine.

## Testing on Windows (the first real-hardware milestone)

1. `ol1nplay-engine devices` — every driver in `HKLM\SOFTWARE\ASIO` should
   be listed, plus WASAPI endpoints.
2. `ol1nplay-engine play -backend asio -device "<driver name>" test24_96.flac`
   — the DAC's display should show 96 kHz; the status line should say
   `bit-perfect` with `underruns 0`.
3. Loopback test: record the DAC's digital output (or use a USB analyser)
   and compare with `ffmpeg -i test.flac -f s32le -`.
4. Sample-rate change between queued tracks; DSD (`.dsf`) native then DoP;
   `play -ab`.
5. `sysmode apply` / `restore` as administrator; watch `sysmode status`;
   kill the engine mid-session and start it again to see the recovery.
6. Reference drivers: your DAC's own ASIO driver and ASIO4ALL (which
   wraps WDM — useful to see how a "software" driver differs).

Things the code cannot know until then: whether a given driver honours
`setSampleRate` synchronously, which channel sample type it reports
(Int32LSB is the norm; Int24LSB and Int32LSB24 are handled; MSB types are
refused), and whether `outputReady` is supported.

## Versioning

`-ldflags "-X github.com/ol1n/ol1nplay/engine/api.Version=1.2.3"`; the
Makefile fills it from `git describe`.
