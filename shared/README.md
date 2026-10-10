# ol1nplay_shared

Dart package shared by the Ol1nPlay desktop app (`app_desktop/`) and the
mobile remote (`app_remote/`). It is the Dart side of the wire contract in
`engine/protocol/protocol.go` — change both together.

```dart
import 'package:ol1nplay_shared/ol1nplay_shared.dart';
```

Depends only on `web_socket_channel`, `multicast_dns`, `http`, `collection`.
No code generation.

## Naming note

The Go struct `State` is `EngineState` in Dart and `RepeatMode` is `Repeat`,
because Flutter already exports `State` and `RepeatMode`. Everything else
keeps the Go name. The wire key for `Request.Bool` is `bool`; the Dart field
is `flag`. `Device.Default` is `Device.isDefault`.

## Protocol (`lib/src/protocol/`)

| Dart | Go |
|---|---|
| `Cmd.*`, `Ev.*`, `Playback.*`, `Repeat.*`, `OutputStatus.*`, `protocolVersion` | `Cmd*`, `Ev*` constants |
| `Request`, `Response`, `Event`, `EngineException` | envelopes |
| `ServerInfo`, `Root`, `DirNode`, `Listing`, `Track`, `CueSheet`, `Format`, `Output`, `OutputStats`, `ABLoop`, `EngineState`, `Queue`, `Device`, `Sysmode`, `SysmodeLogEntry`, `RemoteInfo`, `LibraryChange`, `ScanProgress`, `LogLine`, `HistoryEntry`, `Playlist`, `SleepTimer`, `Lyrics`, `LyricLine`, `CoverRef`, `Settings` | same |

Every model has `fromJson` / `toJson` and tolerates missing keys (the engine
uses `omitempty`). `copyWith` on `EngineState`, `Settings`, `Sysmode`,
`Track`. Helpers: `Track.displayTitle`, `displayArtist`, `codecLabel`,
`formatBadge` ("FLAC 24/96k", "DSD64", "MP3 320"), `Format.short`,
`EngineState.progress`, `isPlaying/isPaused/isStopped`, `ABLoop.isSet/active`,
`Lyrics.activeIndex(ms)`, `Settings.toPatch(base)`, `Repeat.nextOf(mode)`,
`sampleRateLabel(hz)`, `dsdLabel(rate)`.

## Client (`EngineClient`)

```dart
final client = EngineClient();
final info = await client.connect(Uri.parse('ws://127.0.0.1:7777/ws'), token: '');
client.state.addListener(() => print(client.state.value?.track?.title));
await client.playDir(r'D:\Music\Album', index: 0);
```

- `connect(uri, {token})` sends `hello` first and resolves with `ServerInfo`;
  `close()`, `dispose()`. Auto-reconnect with capped jittered backoff.
- Notifiers: `state` (`EngineState?`), `queue`, `status` (`ConnectionStatus`),
  `serverInfo`, `lastError`.
- Streams: `state$`, `queue$`, `libraryChanged$`, `scan$`, `log$`, `output$`,
  `sleep$`, `sysmode$`, `events$` (raw).
- Commands (one method per `Cmd`): `version`, `getState`, `libraryRoots`,
  `addRoot`, `removeRoot`, `rescan`, `list(dir)`, `tree(dir)`, `search`,
  `track`, `play(path)`, `playPaths`, `playDir`, `pause`, `resume`, `toggle`,
  `stop`, `next`, `prev`, `seekMs`, `seekSamples`, `setMono`, `setRepeat`,
  `setShuffle`, `abSetA`, `abSetB`, `abClear`, `abNudge(which, ms)`,
  `abToggle`, `queueGet/Set/Add/Insert/Remove/Move/Clear/Jump`, `devices`,
  `selectDevice`, `outputStats`, `outputReset`, `sysmodeGet/Set/Apply/Restore/Log`,
  `remoteInfo/Enable/Rotate`, `favorites`, `addFavorite`, `removeFavorite`,
  `history`, `playlists`, `loadPlaylist`, `savePlaylist`, `sleepSet`,
  `sleepClear`, `settingsGet`, `settingsSet(patch)`, `settingsUpdate(next, base)`,
  `lyrics`, `cover`, `shutdown`, `raw`.
- `coverUrl(hash, {thumb})` → `http://host:httpPort/cover/<hash>[_t].jpg`.
- Errors surface as `EngineException(command, message)`.

Note: the engine pushes the state event *before* the command's response, so
subscribe before sending if you wait for a specific change.

## Discovery (`lib/src/discovery/`)

- `PairingInfo.parse('ol1nplay://host:port/?token=…&http=…&name=…')`,
  `toUri()`, `wsUri`.
- `EngineDiscovery` (abstract, `discover({timeout})` → `Stream<DiscoveredEngine>`),
  `MdnsEngineDiscovery` (`_ol1nplay._tcp`, TXT `http=`),
  `StaticEngineDiscovery`, `EngineDiscovery.manual('host[:port]')`.

## Theme (`Ol1nTheme`)

`Ol1nTheme.dark()`, `light()`, `modeOf(settings.theme)`, `modeOfSettings`,
`mono(context, …)` text style for readouts, colour constants `accent`,
`bitPerfectGreen`, `warnAmber`, `errorRed`.

## Widgets (`lib/src/widgets/`)

`CoverImage(hash, client, size, thumb)` (+ `CoverCache`), `FormatBadge(state)`,
`FormatChip(track)`, `TransportBar(state, on…)`, `MonoToggle`,
`SeekBar(state, onSeekMs)`, `ABControls(ab, …)`, `TrackTile(track, …)`,
`QueueList(queue, onJump/onRemove/onMove)`, `LyricsView(lyrics, positionMs)`,
`UnderrunIndicator(underruns)`, `NoVolumeNotice`, `ConnectionDot`,
`TechInfo(state, stats)`, `fmtDuration(ms)`, `fmtDurationMs`, `fmtBytes`,
`fmtHz`.

## Testing (`FakeEngine`)

`FakeEngine(token:, tracks:, tick:)` is a real localhost WebSocket + HTTP
server speaking the protocol with a canned two-album library, simulated
playback (position, gapless queue walk, A-B loop, repeat), favorites,
history, settings, sleep timer, lyrics and 1×1 PNG covers. `start()`,
`stop()`, `wsUri`, `requests` (everything received), `handle(Request)` for
socket-free unit tests, `FakeEngine.demoTracks()`.

```sh
flutter analyze && flutter test
```
