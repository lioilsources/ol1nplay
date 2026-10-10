# Ol1nPlay Remote

Phone / tablet remote for the Ol1nPlay engine (Windows, ASIO). It talks the
same JSON-over-WebSocket protocol as the desktop UI, over the LAN. It never
carries audio and — on purpose — has no volume slider: the level is set on
your DAC or amplifier.

## What it does

- **Pairing**: scan the desktop's QR code (`ol1nplay://host:port/?token=…`),
  pick an engine found via mDNS (`_ol1nplay._tcp`), or type `host[:port]` +
  token. Several engines can be saved; tokens live in the keychain /
  keystore. "Forget" removes one.
- **Transport**: play/pause/stop/next/prev, seek, mono, repeat, shuffle,
  sample-accurate **A-B loop** with ±10 ms nudges, sleep timer.
- **Library**: folder tree 1:1 with the engine's roots, breadcrumbs, folder
  covers, long-press → play / play next / add to queue / favorite; search;
  favorites, history, M3U playlists; lyrics (auto-scroll).
- **Queue**: reorder by drag, swipe to remove, tap to jump; swipe-up sheet
  on the now-playing screen.
- **Now playing**: cover on a blurred backdrop, format path badge
  ("FLAC 24/96 → ASIO 32-bit · bit-perfect"), seek bar with A/B markers,
  underrun indicator, tech readout (device, buffer, latency, thread, RAM).
- **More**: output device selection, output stats, DSD mode, sysmode on/off
  with a read-only "what I changed" list, saved engines.
- Tablet (≥ 720 dp): library left, now playing right.

## Build

```sh
cd app_remote
flutter pub get
flutter run                 # phone or simulator
flutter build apk --release
flutter build ipa --release # needs a signing team in Xcode
```

Platform bits already set: iOS `NSLocalNetworkUsageDescription`,
`NSBonjourServices` (`_ol1nplay._tcp`), `NSCameraUsageDescription`,
`NSAllowsLocalNetworking`; Android `INTERNET`, `CAMERA`,
`CHANGE_WIFI_MULTICAST_STATE`, `ACCESS_WIFI_STATE`, cleartext traffic
(the engine speaks plain `ws://` on the LAN).

The QR scanner falls back to a paste field when there is no camera (simulator).

## Layout

```
lib/
  main.dart, app.dart              ProviderScope → pairing or shell
  core/engine_store.dart           SavedEngine + EngineStore (prefs/keychain, memory for tests)
  core/providers.dart              client, connection controller, state bridges, listings, search…
  shell/home_shell.dart            phone bottom-nav / tablet master-detail, connection banner
  features/pairing/                pairing screen, QR scanner, one-time no-volume notice
  features/library/                browser, search, favorites/history/playlists, track menus
  features/now_playing/            now playing, mini player
  features/queue/                  queue tab + sheet
  features/settings/               "More"
test/app_test.dart                 widget tests against the shared FakeEngine
```

## Tests

```sh
flutter analyze && flutter test
```

The widget tests start the shared `FakeEngine` (a real localhost WebSocket)
and drive the UI: manual pairing → library → play → now-playing badge,
A-B set, queue move, discovery + forget, QR payload parsing.
