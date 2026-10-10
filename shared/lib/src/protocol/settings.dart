import 'commands.dart';
import 'json_util.dart';

/// Persisted engine preferences. `settings.set` merges a partial object;
/// use [toPatch] to send only what changed.
class Settings {
  const Settings({
    this.backend = '',
    this.device = '',
    this.mono = false,
    this.repeat = Repeat.off,
    this.shuffle = false,
    this.ramLimitMB = 0,
    this.preloadNext = true,
    this.resumeOnStart = false,
    this.abCrossfadeMs = 0,
    this.dsdMode = 'native',
    this.widthExtension = true,
    this.bufferPreference = 'preferred',
    this.remoteEnabled = false,
    this.remotePort = 0,
    this.mdns = true,
    this.mediaKeys = true,
    this.scrobble = false,
    this.roots = const [],
    this.theme = 'system',
  });

  final String backend;
  final String device;
  final bool mono;
  final String repeat;
  final bool shuffle;

  /// Above this, stream from disk.
  final int ramLimitMB;

  /// Gapless preload.
  final bool preloadNext;
  final bool resumeOnStart;

  /// 0 = off (default; it is DSP).
  final int abCrossfadeMs;

  /// "native" | "dop" | "pcm".
  final String dsdMode;

  /// Allow 16/24 → 32 zero-padding when the device demands it.
  final bool widthExtension;

  /// "preferred" | "max" | "min".
  final String bufferPreference;
  final bool remoteEnabled;
  final int remotePort;
  final bool mdns;
  final bool mediaKeys;

  /// Writes a local scrobble log.
  final bool scrobble;
  final List<String> roots;

  /// "system" | "dark" | "light".
  final String theme;

  static const defaults = Settings();

  factory Settings.fromJson(Json j) => Settings(
    backend: str(j, 'backend'),
    device: str(j, 'device'),
    mono: boolean(j, 'mono'),
    repeat: str(j, 'repeat', Repeat.off),
    shuffle: boolean(j, 'shuffle'),
    ramLimitMB: integer(j, 'ramLimitMB'),
    preloadNext: boolean(j, 'preloadNext'),
    resumeOnStart: boolean(j, 'resumeOnStart'),
    abCrossfadeMs: integer(j, 'abCrossfadeMs'),
    dsdMode: str(j, 'dsdMode', 'native'),
    widthExtension: boolean(j, 'widthExtension'),
    bufferPreference: str(j, 'bufferPreference', 'preferred'),
    remoteEnabled: boolean(j, 'remoteEnabled'),
    remotePort: integer(j, 'remotePort'),
    mdns: boolean(j, 'mdns'),
    mediaKeys: boolean(j, 'mediaKeys'),
    scrobble: boolean(j, 'scrobble'),
    roots: strings(j, 'roots'),
    theme: str(j, 'theme', 'system'),
  );

  Json toJson() => {
    'backend': backend,
    'device': device,
    'mono': mono,
    'repeat': repeat,
    'shuffle': shuffle,
    'ramLimitMB': ramLimitMB,
    'preloadNext': preloadNext,
    'resumeOnStart': resumeOnStart,
    'abCrossfadeMs': abCrossfadeMs,
    'dsdMode': dsdMode,
    'widthExtension': widthExtension,
    'bufferPreference': bufferPreference,
    'remoteEnabled': remoteEnabled,
    'remotePort': remotePort,
    'mdns': mdns,
    'mediaKeys': mediaKeys,
    'scrobble': scrobble,
    'roots': roots,
    'theme': theme,
  };

  /// Only the keys whose value differs from [base]; the engine merges.
  Json toPatch(Settings base) {
    final mine = toJson();
    final theirs = base.toJson();
    mine.removeWhere((k, v) {
      final o = theirs[k];
      if (v is List && o is List) {
        return v.length == o.length && _listEq(v, o);
      }
      return v == o;
    });
    return mine;
  }

  Settings copyWith({
    String? backend,
    String? device,
    bool? mono,
    String? repeat,
    bool? shuffle,
    int? ramLimitMB,
    bool? preloadNext,
    bool? resumeOnStart,
    int? abCrossfadeMs,
    String? dsdMode,
    bool? widthExtension,
    String? bufferPreference,
    bool? remoteEnabled,
    int? remotePort,
    bool? mdns,
    bool? mediaKeys,
    bool? scrobble,
    List<String>? roots,
    String? theme,
  }) => Settings(
    backend: backend ?? this.backend,
    device: device ?? this.device,
    mono: mono ?? this.mono,
    repeat: repeat ?? this.repeat,
    shuffle: shuffle ?? this.shuffle,
    ramLimitMB: ramLimitMB ?? this.ramLimitMB,
    preloadNext: preloadNext ?? this.preloadNext,
    resumeOnStart: resumeOnStart ?? this.resumeOnStart,
    abCrossfadeMs: abCrossfadeMs ?? this.abCrossfadeMs,
    dsdMode: dsdMode ?? this.dsdMode,
    widthExtension: widthExtension ?? this.widthExtension,
    bufferPreference: bufferPreference ?? this.bufferPreference,
    remoteEnabled: remoteEnabled ?? this.remoteEnabled,
    remotePort: remotePort ?? this.remotePort,
    mdns: mdns ?? this.mdns,
    mediaKeys: mediaKeys ?? this.mediaKeys,
    scrobble: scrobble ?? this.scrobble,
    roots: roots ?? this.roots,
    theme: theme ?? this.theme,
  );
}

bool _listEq(List a, List b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
