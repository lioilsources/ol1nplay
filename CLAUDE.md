# Ol1nPlay (Elfton Player)

<!-- Max 80 řádků. Co se nevejde, jde do docs/ a sem jeden odkaz. Veřejné repo: žádné LAN IP, domovské cesty, ID. -->

## Účel
Lokální hudební přehrávač pro Windows 11 s bit-perfect výstupem přes ASIO
(fallback WASAPI exclusive). Go engine bez UI, Flutter desktop UI a Flutter
dálkové ovládání v telefonu; obě aplikace mluví s enginem jedním WebSocket/JSON protokolem.

## Build a test
Gate (to samé co `.github/workflows/ci.yml`):
```
make lint        # gofmt + go vet nativně i pro GOOS=windows (potřebuje MinGW)
make test-race   # engine testy; fixtures: make fixtures (potřebuje ffmpeg CLI)
make apps        # shared, app_desktop, app_remote: pub get + analyze + test
```
Další: `make engine`, `make engine-windows` (potřebuje `engine/ffmpeg-win`),
`make dist-windows`. Prerekvizity a ruční test na Windows: `BUILD.md`.
Release: push tagu `v*` spustí `.github/workflows/release.yml`.

## Mapa
- `engine/` — Go modul: `cmd/engine`, `decode`, `playback`, `asio`, `wasapi`, `sink/`, `library/`, `sysmode`, `api`, `protocol`, `ringbuf`
- `shared/` — Dart balík `ol1nplay_shared`: modely protokolu, EngineClient, téma, widgety, FakeEngine
- `app_desktop/` — Flutter aplikace Windows/macOS
- `app_remote/` — Flutter dálkové ovládání iOS/Android
- `tools/` — `install.ps1` (instalace z Releases), demo knihovna, ikona

## Invarianty
- Signálová cesta soubor → dekodér → RAM → ASIO → DAC: žádná hlasitost,
  resampling ani EQ. Jediná povolená DSP je mono downmix, v UI označený
  jako ne-bit-perfect. Jediná konverze je rozšíření int kontejneru nulami.
- Windows backendy se jen kompilují pod `GOOS=windows`; na Macu běží CoreAudio a null backend.
- ASIO SDK se nepoužívá (`engine/asio/iasio.h`); licence viz `LICENSES.md`.

## Kam dál
`README.md`, `BUILD.md`, `CHANGELOG.md`, `LICENSES.md`
