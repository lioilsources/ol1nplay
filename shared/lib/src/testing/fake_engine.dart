import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/commands.dart';
import '../protocol/library_models.dart';
import '../protocol/messages.dart';
import '../protocol/settings.dart';
import '../protocol/state_models.dart';

/// An in-process engine that speaks the real protocol over a real
/// localhost WebSocket (so `EngineClient` needs no test hooks) with a
/// canned library. Playback is simulated with a timer; the position
/// advances, A-B loops, the queue walks. Both apps use it for widget tests
/// and for a demo mode without the Go engine.
class FakeEngine {
  FakeEngine({
    this.token = '',
    List<Track>? tracks,
    this.tick = const Duration(milliseconds: 250),
    this.backend = 'null',
    this.deviceName = 'Fake DAC',
  }) : _tracks = tracks ?? demoTracks();

  final String token;
  final Duration tick;
  final String backend;
  final String deviceName;
  final List<Track> _tracks;

  HttpServer? _server;
  final _clients = <WebSocket>{};
  Timer? _timer;

  EngineState _state = const EngineState();
  Queue _queue = const Queue();
  Settings _settings = const Settings(backend: 'null', device: 'fake');
  Sysmode _sysmode = const Sysmode(
    template: ['SearchIndexer.exe', 'OneDrive.exe', 'Discord.exe'],
  );
  final _favorites = <String>{};
  final _history = <HistoryEntry>[];
  final _log = <SysmodeLogEntry>[];
  int _playedTicks = 0;

  /// Every request received, for assertions.
  final List<Request> requests = [];

  /// 1x1 PNG served for every cover hash.
  static final Uint8List _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  );

  int get port => _server?.port ?? 0;
  Uri get wsUri =>
      Uri(scheme: 'ws', host: '127.0.0.1', port: port, path: '/ws');
  EngineState get state => _state;
  Queue get queue => _queue;
  List<Track> get tracks => List.unmodifiable(_tracks);

  Future<void> start({int port = 0}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    _timer?.cancel();
    for (final c in List.of(_clients)) {
      await c.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }

  void _handle(HttpRequest req) async {
    if (req.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      _clients.add(ws);
      ws.listen(
        (m) => _onMessage(ws, m),
        onDone: () => _clients.remove(ws),
        onError: (_) => _clients.remove(ws),
      );
      return;
    }
    if (req.uri.path.startsWith('/cover/')) {
      req.response.headers.contentType = ContentType('image', 'png');
      req.response.add(_png);
      await req.response.close();
      return;
    }
    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
  }

  void _onMessage(WebSocket ws, dynamic raw) {
    if (raw is! String) return;
    final j = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final r = Request.fromJson(j);
    requests.add(r);
    try {
      final data = handle(r);
      _send(ws, jsonEncode(Response.okFor(r.id, data)));
    } on EngineException catch (e) {
      _send(ws, jsonEncode(Response.errFor(r.id, e.message)));
    } catch (e) {
      _send(ws, jsonEncode(Response.errFor(r.id, e.toString())));
    }
  }

  /// A client may vanish between receiving a request and our reply;
  /// that is not an error for the engine.
  void _send(WebSocket ws, String s) {
    try {
      if (ws.readyState == WebSocket.open) ws.add(s);
    } catch (_) {
      _clients.remove(ws);
    }
  }

  void _broadcast(String type, Object? data) {
    final s = jsonEncode(Event(type: type, data: data).toJson());
    for (final c in List.of(_clients)) {
      _send(c, s);
    }
  }

  /// Pushes the current state to every client.
  void pushState() => _broadcast(Ev.state, _state.toJson());
  void pushQueue() => _broadcast(Ev.queue, _queue.toJson());
  void pushLog(String msg, {String level = 'info', String scope = 'fake'}) =>
      _broadcast(
        Ev.log,
        LogLine(
          at: DateTime.now().millisecondsSinceEpoch,
          level: level,
          scope: scope,
          msg: msg,
        ).toJson(),
      );

  ServerInfo get serverInfo => ServerInfo(
    name: 'Elfton Player (fake)',
    version: '0.0.0-fake',
    protocolVersion: protocolVersion,
    os: Platform.operatingSystem,
    hostname: 'fake',
    elevated: false,
    httpPort: port,
    backends: [backend],
  );

  /// Dispatches one request. Public so tests can drive the engine without
  /// a socket.
  Object? handle(Request r) {
    switch (r.type) {
      case Cmd.hello:
        if (token.isNotEmpty && r.token != token) {
          throw const EngineException(Cmd.hello, 'bad token');
        }
        return serverInfo.toJson();
      case Cmd.version:
        return serverInfo.toJson();
      case Cmd.state:
        return _state.toJson();

      case Cmd.libraryRoots:
        return [
          Root(
            path: _root,
            tracks: _tracks.length,
            dirs: _dirs.length,
            lastScan: 1,
          ).toJson(),
        ];
      case Cmd.libraryRootAdd:
      case Cmd.libraryRootRemove:
      case Cmd.libraryRescan:
        return null;
      case Cmd.libraryTree:
        final dir = r.dir ?? '';
        if (dir.isEmpty) {
          return [DirNode(path: _root, name: 'Music', hasDirs: true).toJson()];
        }
        return _dirs
            .where((d) => _parentOf(d) == dir)
            .map((d) => _node(d).toJson())
            .toList();
      case Cmd.libraryList:
        final dir = r.dir ?? _root;
        return Listing(
          dir: dir,
          parent: dir == _root ? '' : _parentOf(dir),
          dirs: _dirs.where((d) => _parentOf(d) == dir).map(_node).toList(),
          tracks: _tracks.where((t) => t.dir == dir).map(_decorate).toList(),
          cover: _tracks
              .where((t) => t.dir == dir)
              .map((t) => t.cover)
              .firstWhere((c) => c.isNotEmpty, orElse: () => ''),
        ).toJson();
      case Cmd.librarySearch:
        final q = (r.query ?? '').toLowerCase();
        final hits = _tracks.where(
          (t) =>
              t.title.toLowerCase().contains(q) ||
              t.artist.toLowerCase().contains(q) ||
              t.album.toLowerCase().contains(q) ||
              t.fileName.toLowerCase().contains(q),
        );
        return hits
            .take(r.limit ?? 100)
            .map((t) => _decorate(t).toJson())
            .toList();
      case Cmd.libraryTrack:
        return _decorate(_find(r.path)).toJson();

      case Cmd.play:
        if (r.path != null) {
          _setQueue([_find(r.path)], 0);
        } else if (r.paths != null) {
          _setQueue(r.paths!.map(_find).toList(), r.index ?? 0);
        } else if (r.dir != null) {
          _setQueue(
            _tracks.where((t) => t.dir == r.dir).toList(),
            r.index ?? 0,
          );
        } else if (_state.isPaused) {
          _play();
        }
        _startCurrent();
        return null;
      case Cmd.pause:
        if (_state.isPlaying) _set(_state.copyWith(playback: Playback.paused));
        return null;
      case Cmd.resume:
        if (_state.isPaused) _play();
        return null;
      case Cmd.toggle:
        if (_state.isPlaying) {
          _set(_state.copyWith(playback: Playback.paused));
        } else if (_state.isPaused) {
          _play();
        } else if (_queue.current != null) {
          _startCurrent();
        }
        return null;
      case Cmd.stop:
        _timer?.cancel();
        _set(
          _state.copyWith(
            playback: Playback.stopped,
            position: 0,
            positionMs: 0,
            output: _state.output.copyWithStatus(OutputStatus.open),
          ),
        );
        return null;
      case Cmd.next:
        _advance(1);
        return null;
      case Cmd.prev:
        _advance(-1);
        return null;
      case Cmd.seek:
        final ms = r.samples != null && r.samples! > 0
            ? (r.samples! * 1000 ~/ _rate)
            : (r.ms ?? 0);
        _set(
          _state.copyWith(
            positionMs: ms.clamp(0, _state.durationMs),
            position: ms * _rate ~/ 1000,
          ),
        );
        return null;
      case Cmd.mono:
        final mode = (r.mode ?? '').isNotEmpty
            ? r.mode!
            : (r.flag ?? true ? MonoMode.mono : MonoMode.stereo);
        final on = mode != MonoMode.stereo;
        _set(_state.copyWith(mono: on, monoMode: mode));
        _settings = _settings.copyWith(mono: on);
        return null;
      case Cmd.repeat:
        _set(_state.copyWith(repeat: r.mode ?? Repeat.off));
        _queue = Queue(
          index: _queue.index,
          tracks: _queue.tracks,
          shuffle: _queue.shuffle,
          repeat: _state.repeat,
        );
        return null;
      case Cmd.shuffle:
        _set(_state.copyWith(shuffle: r.flag ?? false));
        return null;

      case Cmd.abSetA:
        final f = r.samples ?? _state.position;
        _setAB(_ab(a: f));
        return null;
      case Cmd.abSetB:
        final f = r.samples ?? _state.position;
        _setAB(_ab(b: f));
        return null;
      case Cmd.abClear:
        _setAB(ABLoop.none);
        return null;
      case Cmd.abNudge:
        final d = (r.ms ?? 0) * _rate ~/ 1000;
        _setAB(
          r.which == 'a' ? _ab(a: _state.ab.a + d) : _ab(b: _state.ab.b + d),
        );
        return null;
      case Cmd.abToggle:
        _setAB(_ab(enabled: r.flag ?? false));
        return null;

      case Cmd.queueGet:
        return _queue.toJson();
      case Cmd.queueSet:
        _setQueue((r.paths ?? const []).map(_find).toList(), r.index ?? 0);
        return null;
      case Cmd.queueAdd:
        final add = (r.paths ?? [if (r.path != null) r.path!])
            .map(_find)
            .toList();
        _setQueue(
          [..._queue.tracks, ...add],
          _queue.index < 0 ? 0 : _queue.index,
          keepState: true,
        );
        return null;
      case Cmd.queueInsert:
        final add = (r.paths ?? const []).map(_find).toList();
        final at = (r.index ?? _queue.index + 1).clamp(0, _queue.tracks.length);
        final list = [..._queue.tracks]..insertAll(at, add);
        _setQueue(list, _queue.index, keepState: true);
        return null;
      case Cmd.queueRemove:
        final i = r.index ?? -1;
        if (i < 0 || i >= _queue.tracks.length) {
          throw const EngineException(Cmd.queueRemove, 'index out of range');
        }
        final list = [..._queue.tracks]..removeAt(i);
        var idx = _queue.index;
        if (i < idx) idx--;
        if (idx >= list.length) idx = list.length - 1;
        _setQueue(list, idx, keepState: true);
        return null;
      case Cmd.queueMove:
        final from = r.index ?? -1, to = r.to ?? -1;
        if (from < 0 ||
            from >= _queue.tracks.length ||
            to < 0 ||
            to >= _queue.tracks.length) {
          throw const EngineException(Cmd.queueMove, 'index out of range');
        }
        final list = [..._queue.tracks];
        final t = list.removeAt(from);
        list.insert(to, t);
        var idx = _queue.index;
        if (idx == from) {
          idx = to;
        } else if (from < idx && to >= idx) {
          idx--;
        } else if (from > idx && to <= idx) {
          idx++;
        }
        _setQueue(list, idx, keepState: true);
        return null;
      case Cmd.queueClear:
        _timer?.cancel();
        _queue = const Queue();
        _set(const EngineState());
        pushQueue();
        return null;
      case Cmd.queueJump:
        final i = r.index ?? -1;
        if (i < 0 || i >= _queue.tracks.length) {
          throw const EngineException(Cmd.queueJump, 'index out of range');
        }
        _queue = Queue(
          index: i,
          tracks: _queue.tracks,
          shuffle: _queue.shuffle,
          repeat: _queue.repeat,
        );
        _startCurrent();
        return null;

      case Cmd.devices:
        return [
          Device(
            backend: backend,
            id: 'fake',
            name: deviceName,
            isDefault: true,
            selected: true,
            sampleRates: const [44100, 48000, 88200, 96000, 176400, 192000],
            formats: const ['s16', 's24', 's32'],
          ).toJson(),
        ];
      case Cmd.deviceSelect:
        _settings = _settings.copyWith(
          backend: r.backend ?? backend,
          device: r.device ?? 'fake',
        );
        return null;
      case Cmd.outputStats:
        return OutputStats(
          underruns: _state.output.underruns,
          callbacks: _playedTicks,
          ringFillPct: 92,
          maxCallbackUs: 180,
          threadPriority: 'fake',
          cpuCore: -1,
        ).toJson();
      case Cmd.outputReset:
        return null;

      case Cmd.sysmodeGet:
        return _sysmode.toJson();
      case Cmd.sysmodeSet:
        if (r.sysmode != null) {
          _sysmode = r.sysmode!.copyWith(
            applied: _sysmode.applied,
            available: false,
            template: _sysmode.template,
            changes: _sysmode.changes,
          );
        }
        _broadcast(Ev.sysmode, _sysmode.toJson());
        return null;
      case Cmd.sysmodeApply:
        throw const EngineException(
          Cmd.sysmodeApply,
          'sysmode is not available on this platform',
        );
      case Cmd.sysmodeRestore:
        return null;
      case Cmd.sysmodeLog:
        return _log.map((e) => e.toJson()).toList();

      case Cmd.remoteInfo:
      case Cmd.remoteEnable:
      case Cmd.remoteRotate:
        final enabled = r.type == Cmd.remoteEnable
            ? (r.flag ?? false)
            : _state.remote.enabled;
        final info = RemoteInfo(
          enabled: enabled,
          port: port,
          httpPort: port,
          token: token,
          addresses: const ['127.0.0.1'],
          qr: 'ol1nplay://127.0.0.1:$port/?token=$token&http=$port',
          clients: _clients.length,
          mdns: false,
        );
        _set(_state.copyWith(remote: info));
        return info.toJson();

      case Cmd.favorites:
        return _tracks
            .where((t) => _favorites.contains(t.path))
            .map((t) => _decorate(t).toJson())
            .toList();
      case Cmd.favoriteAdd:
        _favorites.add(_find(r.path).path);
        _refreshTrackInState();
        return null;
      case Cmd.favoriteRemove:
        _favorites.remove(r.path);
        _refreshTrackInState();
        return null;
      case Cmd.history:
        return _history.reversed
            .take(r.limit ?? 100)
            .map((h) => h.toJson())
            .toList();
      case Cmd.playlists:
        return [
          const Playlist(
            path: '/fake/playlists/Favourites.m3u8',
            name: 'Favourites',
            count: 2,
          ).toJson(),
        ];
      case Cmd.playlistLoad:
        _setQueue(_tracks.take(2).toList(), 0);
        return null;
      case Cmd.playlistSave:
        return null;
      case Cmd.sleepSet:
        final m = r.minutes ?? 0;
        final t = SleepTimer(
          endsAt: DateTime.now().millisecondsSinceEpoch + m * 60000,
          minutes: m,
        );
        _set(_state.copyWith(sleep: t));
        _broadcast(Ev.sleep, t.toJson());
        return null;
      case Cmd.sleepClear:
        _set(_state.copyWith(clearSleep: true));
        _broadcast(Ev.sleep, null);
        return null;
      case Cmd.settingsGet:
        return _settings.toJson();
      case Cmd.settingsSet:
        final merged = _settings.toJson()..addAll(r.settings ?? const {});
        _settings = Settings.fromJson(merged);
        return _settings.toJson();
      case Cmd.lyrics:
        return _lyricsFor(_find(r.path)).toJson();
      case Cmd.waveform:
        return _waveformFor(r.path ?? '').toJson();
      case Cmd.cover:
        final t = _find(r.path);
        return t.cover.isEmpty
            ? null
            : CoverRef(hash: t.cover, url: '/cover/${t.cover}.jpg').toJson();
      case Cmd.shutdown:
        return null;
    }
    throw EngineException(r.type, 'unknown command');
  }

  // ------------------------------------------------------------- playback

  static const _sr = 44100;
  int get _rate =>
      _state.source.sampleRate == 0 ? _sr : _state.source.sampleRate;

  Track _find(String? path) {
    final t = _tracks.where((t) => t.path == path).firstOrNull;
    if (t == null) throw EngineException(Cmd.play, 'not found: $path');
    return t;
  }

  Track _decorate(Track t) => t.copyWith(favorite: _favorites.contains(t.path));

  void _set(EngineState s) {
    _state = s;
    pushState();
  }

  void _setQueue(List<Track> tracks, int index, {bool keepState = false}) {
    _queue = Queue(
      index: tracks.isEmpty ? -1 : index.clamp(0, tracks.length - 1),
      tracks: tracks,
      shuffle: _state.shuffle,
      repeat: _state.repeat,
    );
    pushQueue();
    if (keepState) {
      _set(_state.copyWith(queueIndex: _queue.index, queueLen: _queue.length));
    }
  }

  void _startCurrent() {
    final t = _queue.current;
    if (t == null) return;
    _timer?.cancel();
    final sr = t.sampleRate == 0 ? _sr : t.sampleRate;
    _set(
      EngineState(
        playback: Playback.playing,
        track: _decorate(t),
        position: 0,
        positionMs: 0,
        duration: t.samples,
        durationMs: t.durationMs,
        source: Format(
          sampleRate: sr,
          bitDepth: t.bitDepth,
          channels: t.channels,
          sampleFormat: t.bitDepth == 16 ? 's16' : 's24',
        ),
        output: Output(
          backend: backend,
          device: deviceName,
          deviceId: 'fake',
          status: OutputStatus.running,
          format: Format(
            sampleRate: sr,
            bitDepth: 32,
            channels: t.channels,
            sampleFormat: 's32',
          ),
          bufferFrames: 512,
          latencyMs: 512000 / sr,
          bitPerfect: true,
          conversion: t.bitDepth == 32
              ? ''
              : '${t.bitDepth}→32 bit zero-padded',
          exclusive: true,
        ),
        mono: _state.mono,
        monoMode: _state.monoMode,
        waveform: t.path,
        repeat: _state.repeat,
        shuffle: _state.shuffle,
        queueIndex: _queue.index,
        queueLen: _queue.length,
        nextTrack: _queue.index + 1 < _queue.length
            ? _queue.tracks[_queue.index + 1]
            : null,
        preloaded: _queue.index + 1 < _queue.length,
        ramBytes: t.samples * t.channels * 4,
        sysmode: _sysmode,
        remote: _state.remote,
        sleep: _state.sleep,
        lyrics: _lyricsFor(t),
      ),
    );
    _history.add(
      HistoryEntry(track: t, playedAt: DateTime.now().millisecondsSinceEpoch),
    );
    _timer = Timer.periodic(tick, (_) => _tick());
  }

  void _play() => _set(_state.copyWith(playback: Playback.playing));

  void _tick() {
    if (!_state.isPlaying) return;
    _playedTicks++;
    var ms = _state.positionMs + tick.inMilliseconds;
    final ab = _state.ab;
    if (ab.active && ab.bMs > ab.aMs && ms >= ab.bMs) ms = ab.aMs;
    if (ms >= _state.durationMs) {
      _advance(1, auto: true);
      return;
    }
    _set(
      _state.copyWith(
        positionMs: ms,
        position: ms * _state.source.sampleRate ~/ 1000,
      ),
    );
  }

  void _advance(int dir, {bool auto = false}) {
    if (_queue.isEmpty) return;
    var i = _queue.index + dir;
    if (auto && _state.repeat == Repeat.one) i = _queue.index;
    if (i >= _queue.length) {
      if (_state.repeat == Repeat.all || !auto) {
        i = 0;
      } else {
        _timer?.cancel();
        _set(
          _state.copyWith(
            playback: Playback.stopped,
            position: 0,
            positionMs: 0,
          ),
        );
        return;
      }
    }
    if (i < 0) i = _queue.length - 1;
    _queue = Queue(
      index: i,
      tracks: _queue.tracks,
      shuffle: _queue.shuffle,
      repeat: _queue.repeat,
    );
    pushQueue();
    _startCurrent();
  }

  ABLoop _ab({int? a, int? b, bool? enabled}) {
    final cur = _state.ab;
    final na = a ?? cur.a, nb = b ?? cur.b;
    final en = enabled ?? (a != null || b != null ? true : cur.enabled);
    final sr = _state.source.sampleRate == 0 ? _sr : _state.source.sampleRate;
    return ABLoop(
      a: na,
      b: nb,
      enabled: en,
      active: en && na >= 0 && nb > na,
      aMs: na < 0 ? 0 : na * 1000 ~/ sr,
      bMs: nb < 0 ? 0 : nb * 1000 ~/ sr,
    );
  }

  void _setAB(ABLoop ab) => _set(_state.copyWith(ab: ab));

  void _refreshTrackInState() {
    final t = _state.track;
    if (t != null) _set(_state.copyWith(track: _decorate(t)));
  }

  /// A quiet intro, a swell and a fade: enough shape to see the bar work.
  Waveform _waveformFor(String path) {
    const bins = 256;
    final peak = Uint8List(bins);
    final rms = Uint8List(bins);
    for (var i = 0; i < bins; i++) {
      final x = i / (bins - 1);
      final env = x < 0.1 ? 0.15 : (x > 0.9 ? (1 - x) * 8 : 0.8);
      final wobble = 0.75 + 0.25 * ((i * 37) % 17) / 16;
      peak[i] = (255 * env * wobble).round().clamp(0, 255);
      rms[i] = (peak[i] * 0.6).round();
    }
    return Waveform(path: path, peak: peak, rms: rms);
  }

  Lyrics _lyricsFor(Track t) {
    if (!t.hasLyrics) return const Lyrics();
    return Lyrics(
      source: 'lrc',
      lines: [
        for (var i = 0; i < 20; i++)
          LyricLine(ms: i * 3000, text: 'Line ${i + 1} of ${t.displayTitle}'),
      ],
    );
  }

  // -------------------------------------------------------------- library

  static const _root = '/fake/Music';
  List<String> get _dirs => _tracks.map((t) => t.dir).toSet().toList()..sort();
  String _parentOf(String d) => d.substring(0, d.lastIndexOf('/'));
  DirNode _node(String d) => DirNode(
    path: d,
    name: d.substring(d.lastIndexOf('/') + 1),
    hasDirs: _dirs.any((x) => _parentOf(x) == d),
    tracks: _tracks.where((t) => t.dir == d).length,
    cover: _tracks
        .where((t) => t.dir == d)
        .map((t) => t.cover)
        .firstWhere((c) => c.isNotEmpty, orElse: () => ''),
  );

  /// Two albums, mixed formats – enough to exercise every widget.
  static List<Track> demoTracks() {
    Track t(
      String dir,
      String album,
      String artist,
      int n,
      String title, {
      int sr = 44100,
      int bits = 16,
      String codec = 'flac',
      int ms = 15000,
      String cover = 'c0ffee',
      bool lyrics = false,
    }) {
      return Track(
        path: '$dir/${n.toString().padLeft(2, '0')} $title.$codec',
        dir: dir,
        fileName: '${n.toString().padLeft(2, '0')} $title.$codec',
        title: title,
        artist: artist,
        album: album,
        trackNo: n,
        year: 2020,
        codec: codec,
        container: codec,
        sampleRate: sr,
        bitDepth: bits,
        channels: 2,
        lossless: codec != 'mp3',
        bitrate: codec == 'mp3' ? 320 : 0,
        durationMs: ms,
        samples: ms * sr ~/ 1000,
        sizeBytes: ms * sr ~/ 1000 * 2 * (bits ~/ 8),
        modTime: 1700000000000,
        cover: cover,
        hasLyrics: lyrics,
      );
    }

    const a = '$_root/Nina Simone/Pastel Blues';
    const b = '$_root/Autechre/Amber';
    const c = '$_root/Singles';
    return [
      t(
        a,
        'Pastel Blues',
        'Nina Simone',
        1,
        'Be My Husband',
        sr: 96000,
        bits: 24,
        lyrics: true,
      ),
      t(
        a,
        'Pastel Blues',
        'Nina Simone',
        2,
        'Nobody Knows You When You\'re Down and Out',
        sr: 96000,
        bits: 24,
      ),
      t(
        a,
        'Pastel Blues',
        'Nina Simone',
        3,
        'End of the Line',
        sr: 96000,
        bits: 24,
      ),
      t(b, 'Amber', 'Autechre', 1, 'Foil', cover: 'deadbe'),
      t(b, 'Amber', 'Autechre', 2, 'Montreal', cover: 'deadbe'),
      t(c, '', 'Unknown', 0, 'Demo', codec: 'mp3', bits: 0, cover: ''),
    ];
  }
}

extension on Output {
  Output copyWithStatus(String s) => Output.fromJson(toJson()..['status'] = s);
}
