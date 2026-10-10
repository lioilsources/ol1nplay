import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../protocol/commands.dart';
import '../protocol/json_util.dart';
import '../protocol/library_models.dart';
import '../protocol/messages.dart';
import '../protocol/settings.dart';
import '../protocol/state_models.dart';

/// Connection lifecycle as seen by the UI.
enum ConnectionStatus { disconnected, connecting, connected, reconnecting }

/// Opens a WebSocket for [uri]. Injectable so tests can plug in an
/// in-process channel (see `FakeEngine`).
typedef ChannelFactory = Future<WebSocketChannel> Function(Uri uri);

Future<WebSocketChannel> _defaultChannelFactory(Uri uri) async {
  final ch = WebSocketChannel.connect(uri);
  await ch.ready;
  return ch;
}

/// Client for the engine's JSON-over-WebSocket protocol.
///
/// One instance per engine. The desktop app and the mobile remote use the
/// same class; the only difference is the URI and whether a token is needed
/// (the engine requires `hello` with a token on non-loopback connections, we
/// always send it — an empty token is fine locally).
class EngineClient {
  EngineClient({
    ChannelFactory? channelFactory,
    this.requestTimeout = const Duration(seconds: 10),
    this.maxBackoff = const Duration(seconds: 15),
  }) : _factory = channelFactory ?? _defaultChannelFactory;

  final ChannelFactory _factory;
  final Duration requestTimeout;
  final Duration maxBackoff;

  Uri? _uri;
  String _token = '';
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  int _nextId = 1;
  int _attempt = 0;
  bool _closed = false;
  Timer? _reconnect;
  final _pending = <int, _Pending>{};

  /// Last snapshot pushed by the engine; null until the first one arrives.
  final ValueNotifier<EngineState?> state = ValueNotifier(null);

  /// Last queue pushed by the engine.
  final ValueNotifier<Queue?> queue = ValueNotifier(null);

  final ValueNotifier<ConnectionStatus> status = ValueNotifier(
    ConnectionStatus.disconnected,
  );

  /// Filled after `hello`; needed for [coverUrl].
  final ValueNotifier<ServerInfo?> serverInfo = ValueNotifier(null);

  /// Last connection error, for the UI to show next to a retry button.
  final ValueNotifier<String?> lastError = ValueNotifier(null);

  final _stateCtl = StreamController<EngineState>.broadcast();
  final _queueCtl = StreamController<Queue>.broadcast();
  final _libraryChangedCtl = StreamController<LibraryChange>.broadcast();
  final _scanCtl = StreamController<ScanProgress>.broadcast();
  final _logCtl = StreamController<LogLine>.broadcast();
  final _outputCtl = StreamController<OutputStats>.broadcast();
  final _sleepCtl = StreamController<SleepTimer?>.broadcast();
  final _sysmodeCtl = StreamController<Sysmode>.broadcast();
  final _rawCtl = StreamController<Event>.broadcast();

  Stream<EngineState> get state$ => _stateCtl.stream;
  Stream<Queue> get queue$ => _queueCtl.stream;
  Stream<LibraryChange> get libraryChanged$ => _libraryChangedCtl.stream;
  Stream<ScanProgress> get scan$ => _scanCtl.stream;
  Stream<LogLine> get log$ => _logCtl.stream;
  Stream<OutputStats> get output$ => _outputCtl.stream;
  Stream<SleepTimer?> get sleep$ => _sleepCtl.stream;
  Stream<Sysmode> get sysmode$ => _sysmodeCtl.stream;

  /// Every event, untyped — for a debug console.
  Stream<Event> get events$ => _rawCtl.stream;

  Uri? get uri => _uri;
  bool get isConnected => status.value == ConnectionStatus.connected;

  // ---------------------------------------------------------------- lifecycle

  /// Connects (or re-targets) the client. Resolves once `hello` succeeded.
  /// On failure it throws, but also arms the reconnect loop so the UI can
  /// just wait on [status].
  Future<ServerInfo> connect(Uri uri, {String token = ''}) async {
    _uri = uri;
    _token = token;
    _closed = false;
    _attempt = 0;
    await _teardownSocket();
    return _open();
  }

  /// Stops reconnecting and closes the socket.
  Future<void> close() async {
    _closed = true;
    _reconnect?.cancel();
    await _teardownSocket();
    status.value = ConnectionStatus.disconnected;
  }

  /// Releases streams and notifiers. The client is unusable afterwards.
  Future<void> dispose() async {
    await close();
    for (final c in [
      _stateCtl,
      _queueCtl,
      _libraryChangedCtl,
      _scanCtl,
      _logCtl,
      _outputCtl,
      _sleepCtl,
      _sysmodeCtl,
      _rawCtl,
    ]) {
      await c.close();
    }
    state.dispose();
    queue.dispose();
    status.dispose();
    serverInfo.dispose();
    lastError.dispose();
  }

  Future<ServerInfo> _open() async {
    final uri = _uri!;
    status.value = _attempt == 0
        ? ConnectionStatus.connecting
        : ConnectionStatus.reconnecting;
    try {
      final ch = await _factory(uri);
      _ch = ch;
      _sub = ch.stream.listen(
        _onMessage,
        onError: _onSocketError,
        onDone: _onSocketDone,
      );
      final info = ServerInfo.fromJson(
        await _call(Cmd.hello, token: _token) as Json,
      );
      serverInfo.value = info;
      _attempt = 0;
      lastError.value = null;
      status.value = ConnectionStatus.connected;
      // Prime the state so the UI has something before the first push.
      unawaited(getState().then((s) => _publishState(s)).catchError((_) {}));
      return info;
    } catch (e) {
      lastError.value = e.toString();
      await _teardownSocket();
      _scheduleReconnect();
      rethrow;
    }
  }

  void _scheduleReconnect() {
    if (_closed || _uri == null) {
      status.value = ConnectionStatus.disconnected;
      return;
    }
    status.value = ConnectionStatus.reconnecting;
    _reconnect?.cancel();
    // Exponential backoff with jitter, capped – a remote on a flaky Wi-Fi
    // should not hammer the engine, but should come back fast.
    final base = min(maxBackoff.inMilliseconds, 500 * (1 << min(_attempt, 5)));
    final delay = Duration(milliseconds: base + Random().nextInt(250));
    _attempt++;
    _reconnect = Timer(delay, () {
      if (_closed) return;
      _open().catchError((_) => const ServerInfo());
    });
  }

  Future<void> _teardownSocket() async {
    _reconnect?.cancel();
    await _sub?.cancel();
    _sub = null;
    final ch = _ch;
    _ch = null;
    if (ch != null) {
      try {
        await ch.sink.close();
      } catch (_) {}
    }
    _failPending('connection closed');
  }

  void _failPending(String why) {
    final p = List.of(_pending.values);
    _pending.clear();
    for (final x in p) {
      x.timer.cancel();
      if (!x.completer.isCompleted) {
        x.completer.completeError(EngineException(x.command, why));
      }
    }
  }

  void _onSocketError(Object e) {
    lastError.value = e.toString();
  }

  void _onSocketDone() {
    _failPending('connection closed');
    _ch = null;
    _sub = null;
    _scheduleReconnect();
  }

  // ---------------------------------------------------------------- messages

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    Json j;
    try {
      final d = jsonDecode(raw);
      if (d is! Map) return;
      j = Map<String, dynamic>.from(d);
    } catch (_) {
      return;
    }
    final type = str(j, 'type');
    if (type == Ev.result) {
      final r = Response.fromJson(j);
      final p = _pending.remove(r.id);
      if (p == null) return;
      p.timer.cancel();
      if (r.ok) {
        p.completer.complete(r.data);
      } else {
        p.completer.completeError(EngineException(p.command, r.error));
      }
      return;
    }
    final ev = Event.fromJson(j);
    _rawCtl.add(ev);
    final d = ev.dataMap;
    switch (type) {
      case Ev.state:
        _publishState(EngineState.fromJson(d));
      case Ev.queue:
        final q = Queue.fromJson(d);
        queue.value = q;
        _queueCtl.add(q);
      case Ev.libraryChanged:
        _libraryChangedCtl.add(LibraryChange.fromJson(d));
      case Ev.libraryScan:
        _scanCtl.add(ScanProgress.fromJson(d));
      case Ev.log:
      case Ev.error:
        _logCtl.add(LogLine.fromJson(d));
      case Ev.output:
        _outputCtl.add(OutputStats.fromJson(d));
      case Ev.sleep:
        _sleepCtl.add(ev.data == null ? null : SleepTimer.fromJson(d));
      case Ev.sysmode:
        _sysmodeCtl.add(Sysmode.fromJson(d));
    }
  }

  void _publishState(EngineState s) {
    state.value = s;
    _stateCtl.add(s);
  }

  /// Sends one request and waits for its result payload.
  Future<dynamic> _call(
    String type, {
    String? token,
    String? path,
    List<String>? paths,
    String? dir,
    int? index,
    int? to,
    String? query,
    int? limit,
    int? samples,
    int? ms,
    bool? flag,
    String? mode,
    String? which,
    String? device,
    String? backend,
    String? name,
    int? minutes,
    Sysmode? sysmode,
    Json? settings,
  }) {
    final ch = _ch;
    if (ch == null) {
      return Future.error(EngineException(type, 'not connected'));
    }
    final id = _nextId++;
    final req = Request(
      id: id,
      type: type,
      token: token,
      path: path,
      paths: paths,
      dir: dir,
      index: index,
      to: to,
      query: query,
      limit: limit,
      samples: samples,
      ms: ms,
      flag: flag,
      mode: mode,
      which: which,
      device: device,
      backend: backend,
      name: name,
      minutes: minutes,
      sysmode: sysmode,
      settings: settings,
    );
    final c = Completer<dynamic>();
    final t = Timer(requestTimeout, () {
      _pending.remove(id);
      if (!c.isCompleted) c.completeError(EngineException(type, 'timeout'));
    });
    _pending[id] = _Pending(type, c, t);
    try {
      ch.sink.add(jsonEncode(req.toJson()));
    } catch (e) {
      _pending.remove(id);
      t.cancel();
      return Future.error(EngineException(type, e.toString()));
    }
    return c.future;
  }

  Json _m(dynamic d) => d is Map ? Map<String, dynamic>.from(d) : const {};
  List<T> _l<T>(dynamic d, T Function(Json) f) => d is List
      ? d
            .whereType<Map>()
            .map((e) => f(Map<String, dynamic>.from(e)))
            .toList(growable: false)
      : const [];

  // ---------------------------------------------------------------- covers

  /// Absolute URL of a cover thumbnail, or null when not connected.
  Uri? coverUrl(String hash, {bool thumb = false}) {
    if (hash.isEmpty) return null;
    final u = _uri;
    final port = serverInfo.value?.httpPort ?? 0;
    if (u == null || port == 0) return null;
    return Uri(
      scheme: 'http',
      host: u.host,
      port: port,
      path: '/cover/$hash${thumb ? '_t' : ''}.jpg',
    );
  }

  // ---------------------------------------------------------------- commands

  Future<ServerInfo> version() async =>
      ServerInfo.fromJson(_m(await _call(Cmd.version)));
  Future<EngineState> getState() async =>
      EngineState.fromJson(_m(await _call(Cmd.state)));

  // library
  Future<List<Root>> libraryRoots() async =>
      _l(await _call(Cmd.libraryRoots), Root.fromJson);
  Future<void> addRoot(String path) => _call(Cmd.libraryRootAdd, path: path);
  Future<void> removeRoot(String path) =>
      _call(Cmd.libraryRootRemove, path: path);
  Future<void> rescan([String dir = '']) =>
      _call(Cmd.libraryRescan, dir: dir.isEmpty ? null : dir);
  Future<Listing> list(String dir) async =>
      Listing.fromJson(_m(await _call(Cmd.libraryList, dir: dir)));
  Future<List<DirNode>> tree([String dir = '']) async => _l(
    await _call(Cmd.libraryTree, dir: dir.isEmpty ? null : dir),
    DirNode.fromJson,
  );
  Future<List<Track>> search(String query, {int limit = 100}) async => _l(
    await _call(Cmd.librarySearch, query: query, limit: limit),
    Track.fromJson,
  );
  Future<Track> track(String path) async =>
      Track.fromJson(_m(await _call(Cmd.libraryTrack, path: path)));

  // transport
  Future<void> play(String path) => _call(Cmd.play, path: path);
  Future<void> playPaths(List<String> paths, {int index = 0}) =>
      _call(Cmd.play, paths: paths, index: index);
  Future<void> playDir(String dir, {int index = 0}) =>
      _call(Cmd.play, dir: dir, index: index);
  Future<void> pause() => _call(Cmd.pause);
  Future<void> resume() => _call(Cmd.resume);
  Future<void> toggle() => _call(Cmd.toggle);
  Future<void> stop() => _call(Cmd.stop);
  Future<void> next() => _call(Cmd.next);
  Future<void> prev() => _call(Cmd.prev);
  Future<void> seekMs(int ms) => _call(Cmd.seek, ms: ms);
  Future<void> seekSamples(int samples) => _call(Cmd.seek, samples: samples);
  Future<void> setMono(bool on) => _call(Cmd.mono, flag: on);
  Future<void> setRepeat(String mode) => _call(Cmd.repeat, mode: mode);
  Future<void> setShuffle(bool on) => _call(Cmd.shuffle, flag: on);

  // A-B
  Future<void> abSetA([int? samples]) => _call(Cmd.abSetA, samples: samples);
  Future<void> abSetB([int? samples]) => _call(Cmd.abSetB, samples: samples);
  Future<void> abClear() => _call(Cmd.abClear);
  Future<void> abNudge(String which, int ms) =>
      _call(Cmd.abNudge, which: which, ms: ms);
  Future<void> abToggle(bool enabled) => _call(Cmd.abToggle, flag: enabled);

  // queue
  Future<Queue> queueGet() async =>
      Queue.fromJson(_m(await _call(Cmd.queueGet)));
  Future<void> queueSet(List<String> paths, {int index = 0}) =>
      _call(Cmd.queueSet, paths: paths, index: index);
  Future<void> queueAdd(List<String> paths) =>
      _call(Cmd.queueAdd, paths: paths);
  Future<void> queueInsert(List<String> paths, int index) =>
      _call(Cmd.queueInsert, paths: paths, index: index);
  Future<void> queueRemove(int index) => _call(Cmd.queueRemove, index: index);
  Future<void> queueMove(int index, int to) =>
      _call(Cmd.queueMove, index: index, to: to);
  Future<void> queueClear() => _call(Cmd.queueClear);
  Future<void> queueJump(int index) => _call(Cmd.queueJump, index: index);

  // output
  Future<List<Device>> devices() async =>
      _l(await _call(Cmd.devices), Device.fromJson);
  Future<void> selectDevice(String backend, String deviceId) =>
      _call(Cmd.deviceSelect, backend: backend, device: deviceId);
  Future<OutputStats> outputStats() async =>
      OutputStats.fromJson(_m(await _call(Cmd.outputStats)));
  Future<void> outputReset() => _call(Cmd.outputReset);

  // sysmode
  Future<Sysmode> sysmodeGet() async =>
      Sysmode.fromJson(_m(await _call(Cmd.sysmodeGet)));
  Future<void> sysmodeSet(Sysmode cfg) => _call(Cmd.sysmodeSet, sysmode: cfg);
  Future<void> sysmodeApply() => _call(Cmd.sysmodeApply);
  Future<void> sysmodeRestore() => _call(Cmd.sysmodeRestore);
  Future<List<SysmodeLogEntry>> sysmodeLog() async =>
      _l(await _call(Cmd.sysmodeLog), SysmodeLogEntry.fromJson);

  // remote
  Future<RemoteInfo> remoteInfo() async =>
      RemoteInfo.fromJson(_m(await _call(Cmd.remoteInfo)));
  Future<RemoteInfo> remoteEnable(bool on) async =>
      RemoteInfo.fromJson(_m(await _call(Cmd.remoteEnable, flag: on)));
  Future<RemoteInfo> remoteRotate() async =>
      RemoteInfo.fromJson(_m(await _call(Cmd.remoteRotate)));

  // favorites / history / playlists
  Future<List<Track>> favorites() async =>
      _l(await _call(Cmd.favorites), Track.fromJson);
  Future<void> addFavorite(String path) => _call(Cmd.favoriteAdd, path: path);
  Future<void> removeFavorite(String path) =>
      _call(Cmd.favoriteRemove, path: path);
  Future<List<HistoryEntry>> history({int limit = 100}) async =>
      _l(await _call(Cmd.history, limit: limit), HistoryEntry.fromJson);
  Future<List<Playlist>> playlists() async =>
      _l(await _call(Cmd.playlists), Playlist.fromJson);
  Future<void> loadPlaylist(String path) => _call(Cmd.playlistLoad, path: path);
  Future<void> savePlaylist(String name) => _call(Cmd.playlistSave, name: name);

  // sleep
  Future<void> sleepSet(int minutes) => _call(Cmd.sleepSet, minutes: minutes);
  Future<void> sleepClear() => _call(Cmd.sleepClear);

  // settings
  Future<Settings> settingsGet() async =>
      Settings.fromJson(_m(await _call(Cmd.settingsGet)));

  /// Sends a partial object; the engine merges it.
  Future<Settings> settingsSet(Json patch) async =>
      Settings.fromJson(_m(await _call(Cmd.settingsSet, settings: patch)));

  /// Convenience: diff against [base] and send only the changes.
  Future<Settings> settingsUpdate(Settings next, Settings base) =>
      settingsSet(next.toPatch(base));

  // misc
  Future<Lyrics> lyrics(String path) async =>
      Lyrics.fromJson(_m(await _call(Cmd.lyrics, path: path)));
  Future<CoverRef?> cover(String path) async {
    final d = await _call(Cmd.cover, path: path);
    if (d == null) return null;
    final r = CoverRef.fromJson(_m(d));
    return r.hash.isEmpty ? null : r;
  }

  Future<void> shutdown() => _call(Cmd.shutdown);

  /// Escape hatch for commands added to the engine before this package.
  Future<dynamic> raw(
    String type, {
    String? path,
    String? dir,
    bool? flag,
    String? mode,
  }) => _call(type, path: path, dir: dir, flag: flag, mode: mode);
}

class _Pending {
  _Pending(this.command, this.completer, this.timer);

  final String command;
  final Completer<dynamic> completer;
  final Timer timer;
}
