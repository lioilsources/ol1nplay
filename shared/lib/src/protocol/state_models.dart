import 'dart:convert';
import 'dart:typed_data';

import 'commands.dart';
import 'json_util.dart';
import 'library_models.dart';

/// Answer to hello / version.
class ServerInfo {
  const ServerInfo({
    this.name = '',
    this.version = '',
    this.protocolVersion = 0,
    this.os = '',
    this.hostname = '',
    this.elevated = false,
    this.httpPort = 0,
    this.backends = const [],
  });

  final String name;
  final String version;
  final int protocolVersion;
  final String os;
  final String hostname;

  /// Engine runs as admin (sysmode available).
  final bool elevated;

  /// Covers: GET /cover/{hash}.jpg
  final int httpPort;

  /// e.g. ["asio","wasapi"] or ["coreaudio","null"].
  final List<String> backends;

  factory ServerInfo.fromJson(Json j) => ServerInfo(
    name: str(j, 'name'),
    version: str(j, 'version'),
    protocolVersion: integer(j, 'protocolVersion'),
    os: str(j, 'os'),
    hostname: str(j, 'hostname'),
    elevated: boolean(j, 'elevated'),
    httpPort: integer(j, 'httpPort'),
    backends: strings(j, 'backends'),
  );

  Json toJson() => {
    'name': name,
    'version': version,
    'protocolVersion': protocolVersion,
    'os': os,
    'hostname': hostname,
    'elevated': elevated,
    'httpPort': httpPort,
    'backends': backends,
  };
}

/// Current state of the output device.
class Output {
  const Output({
    this.backend = '',
    this.device = '',
    this.deviceId = '',
    this.status = OutputStatus.closed,
    this.error = '',
    this.format = Format.empty,
    this.bufferFrames = 0,
    this.latencyMs = 0,
    this.bitPerfect = false,
    this.conversion = '',
    this.underruns = 0,
    this.exclusive = false,
    this.nativeDsd = false,
    this.dop = false,
  });

  /// "asio" | "wasapi" | "coreaudio" | "null".
  final String backend;
  final String device;
  final String deviceId;

  /// See [OutputStatus].
  final String status;
  final String error;

  /// What the device is actually running.
  final Format format;
  final int bufferFrames;
  final double latencyMs;

  /// True when nothing but zero-LSB width extension happened.
  final bool bitPerfect;
  final String conversion;
  final int underruns;
  final bool exclusive;
  final bool nativeDsd;
  final bool dop;

  static const empty = Output();

  factory Output.fromJson(Json j) => Output(
    backend: str(j, 'backend'),
    device: str(j, 'device'),
    deviceId: str(j, 'deviceId'),
    status: str(j, 'status', OutputStatus.closed),
    error: str(j, 'error'),
    format: Format.fromJson(obj(j, 'format') ?? const {}),
    bufferFrames: integer(j, 'bufferFrames'),
    latencyMs: dbl(j, 'latencyMs'),
    bitPerfect: boolean(j, 'bitPerfect'),
    conversion: str(j, 'conversion'),
    underruns: integer(j, 'underruns'),
    exclusive: boolean(j, 'exclusive'),
    nativeDsd: boolean(j, 'nativeDSD'),
    dop: boolean(j, 'dop'),
  );

  Json toJson() => compact({
    'backend': backend,
    'device': device,
    'deviceId': deviceId,
    'status': status,
    'error': error,
    'format': format.toJson(),
    'bufferFrames': bufferFrames,
    'latencyMs': latencyMs,
    'bitPerfect': bitPerfect,
    'conversion': conversion,
    'underruns': underruns,
    'exclusive': exclusive,
    'nativeDSD': nativeDsd,
    'dop': dop,
  });

  bool get isRunning => status == OutputStatus.running;
  bool get hasError => status == OutputStatus.error;

  /// "ASIO", "WASAPI", "CoreAudio".
  String get backendLabel => switch (backend) {
    'asio' => 'ASIO',
    'wasapi' => 'WASAPI',
    'coreaudio' => 'CoreAudio',
    'null' => 'null',
    _ => backend.toUpperCase(),
  };
}

/// Hot counters.
class OutputStats {
  const OutputStats({
    this.underruns = 0,
    this.callbacks = 0,
    this.ringFillPct = 0,
    this.maxCallbackUs = 0,
    this.lastUnderrunAt = 0,
    this.threadPriority = '',
    this.cpuCore = -1,
  });

  final int underruns;
  final int callbacks;
  final double ringFillPct;
  final int maxCallbackUs;
  final int lastUnderrunAt;

  /// "Pro Audio/critical", "time-constraint", "normal".
  final String threadPriority;

  /// -1 = not pinned.
  final int cpuCore;

  factory OutputStats.fromJson(Json j) => OutputStats(
    underruns: integer(j, 'underruns'),
    callbacks: integer(j, 'callbacks'),
    ringFillPct: dbl(j, 'ringFillPct'),
    maxCallbackUs: integer(j, 'maxCallbackUs'),
    lastUnderrunAt: integer(j, 'lastUnderrunAt'),
    threadPriority: str(j, 'threadPriority'),
    cpuCore: integer(j, 'cpuCore', -1),
  );

  Json toJson() => compact({
    'underruns': underruns,
    'callbacks': callbacks,
    'ringFillPct': ringFillPct,
    'maxCallbackUs': maxCallbackUs,
    'lastUnderrunAt': lastUnderrunAt == 0 ? null : lastUnderrunAt,
    'threadPriority': threadPriority,
    'cpuCore': cpuCore,
  });
}

/// Sample-accurate loop.
class ABLoop {
  const ABLoop({
    this.a = -1,
    this.b = -1,
    this.active = false,
    this.enabled = false,
    this.aMs = 0,
    this.bMs = 0,
  });

  /// Frames, -1 = unset.
  final int a;
  final int b;

  /// Both set and enabled.
  final bool active;

  /// User toggle.
  final bool enabled;
  final int aMs;
  final int bMs;

  static const none = ABLoop();

  factory ABLoop.fromJson(Json j) => ABLoop(
    a: integer(j, 'a', -1),
    b: integer(j, 'b', -1),
    active: boolean(j, 'active'),
    enabled: boolean(j, 'enabled'),
    aMs: integer(j, 'aMs'),
    bMs: integer(j, 'bMs'),
  );

  Json toJson() => {
    'a': a,
    'b': b,
    'active': active,
    'enabled': enabled,
    'aMs': aMs,
    'bMs': bMs,
  };

  bool get hasA => a >= 0;
  bool get hasB => b >= 0;
  bool get isSet => hasA && hasB;
}

/// Stops playback at [endsAt].
class SleepTimer {
  const SleepTimer({required this.endsAt, this.minutes = 0});

  /// Unix ms.
  final int endsAt;
  final int minutes;

  factory SleepTimer.fromJson(Json j) =>
      SleepTimer(endsAt: integer(j, 'endsAt'), minutes: integer(j, 'minutes'));

  Json toJson() => {'endsAt': endsAt, 'minutes': minutes};

  Duration get remaining {
    final d = endsAt - DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: d < 0 ? 0 : d);
  }
}

/// What the QR code carries.
class RemoteInfo {
  const RemoteInfo({
    this.enabled = false,
    this.port = 0,
    this.httpPort = 0,
    this.token = '',
    this.addresses = const [],
    this.qr = '',
    this.clients = 0,
    this.mdns = false,
  });

  final bool enabled;
  final int port;
  final int httpPort;

  /// Only sent to loopback clients.
  final String token;

  /// LAN IPs.
  final List<String> addresses;

  /// "ol1nplay://host:port/?token=..." – only to loopback.
  final String qr;
  final int clients;
  final bool mdns;

  static const empty = RemoteInfo();

  factory RemoteInfo.fromJson(Json j) => RemoteInfo(
    enabled: boolean(j, 'enabled'),
    port: integer(j, 'port'),
    httpPort: integer(j, 'httpPort'),
    token: str(j, 'token'),
    addresses: strings(j, 'addresses'),
    qr: str(j, 'qr'),
    clients: integer(j, 'clients'),
    mdns: boolean(j, 'mdns'),
  );

  Json toJson() => compact({
    'enabled': enabled,
    'port': port,
    'httpPort': httpPort,
    'token': token,
    'addresses': addresses,
    'qr': qr,
    'clients': clients,
    'mdns': mdns,
  });
}

/// The "playback mode" system tweak configuration + status.
class Sysmode {
  const Sysmode({
    this.enabled = false,
    this.powerPlan = false,
    this.usbSuspend = false,
    this.coreParking = false,
    this.processPriority = false,
    this.suspendProcesses = const [],
    this.killProcesses = const [],
    this.stopServices = const [],
    this.pinCore = -1,
    this.timer1ms = false,
    this.applied = false,
    this.available = false,
    this.changes = const [],
    this.template = const [],
  });

  final bool enabled;
  final bool powerPlan;
  final bool usbSuspend;
  final bool coreParking;
  final bool processPriority;
  final List<String> suspendProcesses;
  final List<String> killProcesses;
  final List<String> stopServices;

  /// Audio thread affinity, -1 = auto (last core).
  final int pinCore;
  final bool timer1ms;

  // Status (read-only on the client).
  final bool applied;

  /// Elevated + Windows.
  final bool available;

  /// Human list of what is currently changed.
  final List<String> changes;

  /// Recommended suspend list for the UI to offer.
  final List<String> template;

  static const empty = Sysmode();

  factory Sysmode.fromJson(Json j) => Sysmode(
    enabled: boolean(j, 'enabled'),
    powerPlan: boolean(j, 'powerPlan'),
    usbSuspend: boolean(j, 'usbSuspend'),
    coreParking: boolean(j, 'coreParking'),
    processPriority: boolean(j, 'processPriority'),
    suspendProcesses: strings(j, 'suspendProcesses'),
    killProcesses: strings(j, 'killProcesses'),
    stopServices: strings(j, 'stopServices'),
    pinCore: integer(j, 'pinCore', -1),
    timer1ms: boolean(j, 'timer1ms'),
    applied: boolean(j, 'applied'),
    available: boolean(j, 'available'),
    changes: strings(j, 'changes'),
    template: strings(j, 'template'),
  );

  Json toJson() => {
    'enabled': enabled,
    'powerPlan': powerPlan,
    'usbSuspend': usbSuspend,
    'coreParking': coreParking,
    'processPriority': processPriority,
    'suspendProcesses': suspendProcesses,
    'killProcesses': killProcesses,
    'stopServices': stopServices,
    'pinCore': pinCore,
    'timer1ms': timer1ms,
    'applied': applied,
    'available': available,
    'changes': changes,
    'template': template,
  };

  Sysmode copyWith({
    bool? enabled,
    bool? powerPlan,
    bool? usbSuspend,
    bool? coreParking,
    bool? processPriority,
    List<String>? suspendProcesses,
    List<String>? killProcesses,
    List<String>? stopServices,
    int? pinCore,
    bool? timer1ms,
    bool? applied,
    bool? available,
    List<String>? changes,
    List<String>? template,
  }) => Sysmode(
    enabled: enabled ?? this.enabled,
    powerPlan: powerPlan ?? this.powerPlan,
    usbSuspend: usbSuspend ?? this.usbSuspend,
    coreParking: coreParking ?? this.coreParking,
    processPriority: processPriority ?? this.processPriority,
    suspendProcesses: suspendProcesses ?? this.suspendProcesses,
    killProcesses: killProcesses ?? this.killProcesses,
    stopServices: stopServices ?? this.stopServices,
    pinCore: pinCore ?? this.pinCore,
    timer1ms: timer1ms ?? this.timer1ms,
    applied: applied ?? this.applied,
    available: available ?? this.available,
    changes: changes ?? this.changes,
    template: template ?? this.template,
  );
}

/// One line of "what I changed".
class SysmodeLogEntry {
  const SysmodeLogEntry({
    this.at = 0,
    this.action = '',
    this.target = '',
    this.detail = '',
  });

  final int at;

  /// "apply" | "restore" | "error" | "recover".
  final String action;
  final String target;
  final String detail;

  factory SysmodeLogEntry.fromJson(Json j) => SysmodeLogEntry(
    at: integer(j, 'at'),
    action: str(j, 'action'),
    target: str(j, 'target'),
    detail: str(j, 'detail'),
  );

  Json toJson() => {
    'at': at,
    'action': action,
    'target': target,
    'detail': detail,
  };
}

/// User-visible log message.
class LogLine {
  const LogLine({
    this.at = 0,
    this.level = 'info',
    this.scope = '',
    this.msg = '',
  });

  final int at;

  /// "info" | "warn" | "error".
  final String level;

  /// "asio", "decode", "library", "sysmode", ...
  final String scope;
  final String msg;

  factory LogLine.fromJson(Json j) => LogLine(
    at: integer(j, 'at'),
    level: str(j, 'level', 'info'),
    scope: str(j, 'scope'),
    msg: str(j, 'msg'),
  );

  Json toJson() => {'at': at, 'level': level, 'scope': scope, 'msg': msg};

  bool get isError => level == 'error';
  bool get isWarn => level == 'warn';
}

/// One selectable output.
class Device {
  const Device({
    required this.backend,
    required this.id,
    required this.name,
    this.isDefault = false,
    this.selected = false,
    this.sampleRates = const [],
    this.formats = const [],
    this.maxChannels = 0,
    this.note = '',
  });

  final String backend;
  final String id;
  final String name;
  final bool isDefault;
  final bool selected;
  final List<int> sampleRates;
  final List<String> formats;
  final int maxChannels;
  final String note;

  factory Device.fromJson(Json j) => Device(
    backend: str(j, 'backend'),
    id: str(j, 'id'),
    name: str(j, 'name'),
    isDefault: boolean(j, 'default'),
    selected: boolean(j, 'selected'),
    sampleRates: ints(j, 'sampleRates'),
    formats: strings(j, 'formats'),
    maxChannels: integer(j, 'maxChannels'),
    note: str(j, 'note'),
  );

  Json toJson() => compact({
    'backend': backend,
    'id': id,
    'name': name,
    'default': isDefault,
    'selected': selected,
    'sampleRates': sampleRates.isEmpty ? null : sampleRates,
    'formats': formats.isEmpty ? null : formats,
    'maxChannels': maxChannels == 0 ? null : maxChannels,
    'note': note,
  });
}

/// The play queue.
class Queue {
  const Queue({
    this.index = -1,
    this.tracks = const [],
    this.shuffle = false,
    this.repeat = Repeat.off,
  });

  final int index;
  final List<Track> tracks;
  final bool shuffle;
  final String repeat;

  static const empty = Queue();

  factory Queue.fromJson(Json j) => Queue(
    index: integer(j, 'index', -1),
    tracks: list(j, 'tracks', Track.fromJson),
    shuffle: boolean(j, 'shuffle'),
    repeat: str(j, 'repeat', Repeat.off),
  );

  Json toJson() => {
    'index': index,
    'tracks': tracks.map((t) => t.toJson()).toList(),
    'shuffle': shuffle,
    'repeat': repeat,
  };

  Track? get current =>
      index >= 0 && index < tracks.length ? tracks[index] : null;
  int get length => tracks.length;
  bool get isEmpty => tracks.isEmpty;
}

/// What the engine does with the channels: two independent choices, mono
/// downmix or not, and both speakers or one. `left` and `right` play the
/// downmix through one speaker only — for comparing the two sides of a
/// system on the same signal; `onlyLeft` and `onlyRight` play that
/// channel's own signal and mute the other.
abstract final class MonoMode {
  static const stereo = 'stereo';
  static const mono = 'mono';
  static const left = 'left';
  static const right = 'right';
  static const onlyLeft = 'onlyLeft';
  static const onlyRight = 'onlyRight';

  static const all = [stereo, mono, left, right, onlyLeft, onlyRight];

  static bool isMono(String mode) =>
      mode == mono || mode == left || mode == right;

  /// 'L', 'R' or '' for both speakers.
  static String side(String mode) => switch (mode) {
    left || onlyLeft => 'L',
    right || onlyRight => 'R',
    _ => '',
  };

  static String of({required bool mono, required String side}) =>
      switch (side) {
        'L' => mono ? left : onlyLeft,
        'R' => mono ? right : onlyRight,
        _ => mono ? MonoMode.mono : stereo,
      };
}

/// A track's loudness overview for the seek bar: one peak and one RMS value
/// per bin across its length, 0..255 on a square-root amplitude scale.
class Waveform {
  const Waveform({this.path = '', required this.peak, required this.rms});

  final String path;
  final Uint8List peak;
  final Uint8List rms;

  static final empty = Waveform(peak: Uint8List(0), rms: Uint8List(0));

  bool get isEmpty => peak.isEmpty || rms.length != peak.length;
  int get bins => peak.length;

  factory Waveform.fromJson(Json j) {
    Uint8List bytes(String k) {
      final v = j[k];
      if (v is! String || v.isEmpty) return Uint8List(0);
      try {
        return base64Decode(v);
      } on FormatException {
        return Uint8List(0);
      }
    }

    return Waveform(
      path: str(j, 'path'),
      peak: bytes('peak'),
      rms: bytes('rms'),
    );
  }

  Json toJson() => {
    'path': path,
    'bins': bins,
    'peak': base64Encode(peak),
    'rms': base64Encode(rms),
  };
}

/// Full now-playing snapshot.
class EngineState {
  const EngineState({
    this.playback = Playback.stopped,
    this.track,
    this.position = 0,
    this.positionMs = 0,
    this.duration = 0,
    this.durationMs = 0,
    this.source = Format.empty,
    this.output = Output.empty,
    this.mono = false,
    this.monoMode = MonoMode.stereo,
    this.waveform = '',
    this.ab = ABLoop.none,
    this.repeat = Repeat.off,
    this.shuffle = false,
    this.queueIndex = -1,
    this.queueLen = 0,
    this.nextTrack,
    this.preloaded = false,
    this.ramBytes = 0,
    this.ramLocked = false,
    this.gain = '0 dB',
    this.sysmode = Sysmode.empty,
    this.sleep,
    this.remote = RemoteInfo.empty,
    this.lyrics,
  });

  /// See [Playback].
  final String playback;
  final Track? track;

  /// Frames.
  final int position;
  final int positionMs;

  /// Frames.
  final int duration;
  final int durationMs;

  /// Decoded format (native, untouched).
  final Format source;
  final Output output;
  final bool mono;

  /// See [MonoMode]. [mono] is true for every mode but stereo.
  final String monoMode;

  /// Path of the track whose [Waveform] can be fetched now; empty when the
  /// playing track has none (streamed from disk, DSD, or nothing playing).
  final String waveform;
  final ABLoop ab;

  /// See [Repeat].
  final String repeat;
  final bool shuffle;
  final int queueIndex;
  final int queueLen;

  /// Pre-decoded for gapless.
  final Track? nextTrack;

  /// Next track is fully in RAM.
  final bool preloaded;

  /// Bytes of PCM resident.
  final int ramBytes;

  /// The resident PCM is pinned in physical RAM ([Settings.lockMemory]).
  final bool ramLocked;

  /// Always "0 dB" – there is no volume.
  final String gain;
  final Sysmode sysmode;
  final SleepTimer? sleep;
  final RemoteInfo remote;
  final Lyrics? lyrics;

  static const empty = EngineState();

  factory EngineState.fromJson(Json j) {
    final t = obj(j, 'track');
    final n = obj(j, 'nextTrack');
    final s = obj(j, 'sleep');
    final l = obj(j, 'lyrics');
    return EngineState(
      playback: str(j, 'playback', Playback.stopped),
      track: t == null ? null : Track.fromJson(t),
      position: integer(j, 'position'),
      positionMs: integer(j, 'positionMs'),
      duration: integer(j, 'duration'),
      durationMs: integer(j, 'durationMs'),
      source: Format.fromJson(obj(j, 'source') ?? const {}),
      output: Output.fromJson(obj(j, 'output') ?? const {}),
      mono: boolean(j, 'mono'),
      // An engine older than 0.2 only sends the bool.
      monoMode: str(
        j,
        'monoMode',
        boolean(j, 'mono') ? MonoMode.mono : MonoMode.stereo,
      ),
      waveform: str(j, 'waveform'),
      ab: ABLoop.fromJson(obj(j, 'ab') ?? const {}),
      repeat: str(j, 'repeat', Repeat.off),
      shuffle: boolean(j, 'shuffle'),
      queueIndex: integer(j, 'queueIndex', -1),
      queueLen: integer(j, 'queueLen'),
      nextTrack: n == null ? null : Track.fromJson(n),
      preloaded: boolean(j, 'preloaded'),
      ramBytes: integer(j, 'ramBytes'),
      ramLocked: boolean(j, 'ramLocked'),
      gain: str(j, 'gain', '0 dB'),
      sysmode: Sysmode.fromJson(obj(j, 'sysmode') ?? const {}),
      sleep: s == null ? null : SleepTimer.fromJson(s),
      remote: RemoteInfo.fromJson(obj(j, 'remote') ?? const {}),
      lyrics: l == null ? null : Lyrics.fromJson(l),
    );
  }

  Json toJson() => compact({
    'playback': playback,
    'track': track?.toJson(),
    'position': position,
    'positionMs': positionMs,
    'duration': duration,
    'durationMs': durationMs,
    'source': source.toJson(),
    'output': output.toJson(),
    'mono': mono,
    'monoMode': monoMode,
    'waveform': waveform,
    'ab': ab.toJson(),
    'repeat': repeat,
    'shuffle': shuffle,
    'queueIndex': queueIndex,
    'queueLen': queueLen,
    'nextTrack': nextTrack?.toJson(),
    'preloaded': preloaded,
    'ramBytes': ramBytes,
    'ramLocked': ramLocked,
    'gain': gain,
    'sysmode': sysmode.toJson(),
    'sleep': sleep?.toJson(),
    'remote': remote.toJson(),
    'lyrics': lyrics?.toJson(),
  });

  EngineState copyWith({
    String? playback,
    Track? track,
    bool clearTrack = false,
    int? position,
    int? positionMs,
    int? duration,
    int? durationMs,
    Format? source,
    Output? output,
    bool? mono,
    String? monoMode,
    String? waveform,
    ABLoop? ab,
    String? repeat,
    bool? shuffle,
    int? queueIndex,
    int? queueLen,
    Track? nextTrack,
    bool? preloaded,
    int? ramBytes,
    bool? ramLocked,
    String? gain,
    Sysmode? sysmode,
    SleepTimer? sleep,
    bool clearSleep = false,
    RemoteInfo? remote,
    Lyrics? lyrics,
    bool clearLyrics = false,
  }) => EngineState(
    playback: playback ?? this.playback,
    track: clearTrack ? null : (track ?? this.track),
    position: position ?? this.position,
    positionMs: positionMs ?? this.positionMs,
    duration: duration ?? this.duration,
    durationMs: durationMs ?? this.durationMs,
    source: source ?? this.source,
    output: output ?? this.output,
    mono: mono ?? this.mono,
    monoMode: monoMode ?? this.monoMode,
    waveform: waveform ?? this.waveform,
    ab: ab ?? this.ab,
    repeat: repeat ?? this.repeat,
    shuffle: shuffle ?? this.shuffle,
    queueIndex: queueIndex ?? this.queueIndex,
    queueLen: queueLen ?? this.queueLen,
    nextTrack: nextTrack ?? this.nextTrack,
    preloaded: preloaded ?? this.preloaded,
    ramBytes: ramBytes ?? this.ramBytes,
    ramLocked: ramLocked ?? this.ramLocked,
    gain: gain ?? this.gain,
    sysmode: sysmode ?? this.sysmode,
    sleep: clearSleep ? null : (sleep ?? this.sleep),
    remote: remote ?? this.remote,
    lyrics: clearLyrics ? null : (lyrics ?? this.lyrics),
  );

  bool get isPlaying => playback == Playback.playing;
  bool get isPaused => playback == Playback.paused;
  bool get isStopped => playback == Playback.stopped;
  bool get isLoading => playback == Playback.loading;
  bool get hasTrack => track != null;

  /// 0..1 of the current track, by the device clock.
  double get progress =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0, 1).toDouble();

  Duration get positionDuration => Duration(milliseconds: positionMs);
  Duration get totalDuration => Duration(milliseconds: durationMs);

  /// Frames per millisecond of the source, for drawing sample positions.
  double get framesPerMs =>
      source.sampleRate <= 0 ? 0 : source.sampleRate / 1000;
}
