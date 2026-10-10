import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import 'engine_store.dart';

/// Overridden in tests with a [MemoryEngineStore].
final engineStoreProvider = Provider<EngineStore>((ref) => PrefsEngineStore());

/// Overridden in tests with a [StaticEngineDiscovery].
final discoveryProvider = Provider<EngineDiscovery>(
  (ref) => MdnsEngineDiscovery(),
);

/// One client for the whole app; re-targeted when the user picks another
/// engine so every provider below keeps working.
final clientProvider = Provider<EngineClient>((ref) {
  final c = EngineClient();
  ref.onDispose(c.dispose);
  return c;
});

/// Saved engines + which one is active. Persisted through [EngineStore].
class EnginesNotifier extends AsyncNotifier<List<SavedEngine>> {
  @override
  Future<List<SavedEngine>> build() => ref.read(engineStoreProvider).load();

  Future<void> upsert(SavedEngine e) async {
    final list = List<SavedEngine>.of(state.value ?? const []);
    final i = list.indexWhere((x) => x.id == e.id);
    if (i >= 0) {
      list[i] = e;
    } else {
      list.add(e);
    }
    state = AsyncData(list);
    await ref.read(engineStoreProvider).save(list);
  }

  Future<void> forget(String id) async {
    final list = (state.value ?? const <SavedEngine>[])
        .where((x) => x.id != id)
        .toList();
    state = AsyncData(list);
    await ref.read(engineStoreProvider).save(list);
    final cur = ref.read(currentEngineIdProvider);
    if (cur == id) {
      await ref.read(currentEngineIdProvider.notifier).set(null);
    }
  }

  SavedEngine? byId(String? id) {
    if (id == null) return null;
    for (final e in state.value ?? const <SavedEngine>[]) {
      if (e.id == id) return e;
    }
    return null;
  }
}

final enginesProvider =
    AsyncNotifierProvider<EnginesNotifier, List<SavedEngine>>(
      EnginesNotifier.new,
    );

class CurrentEngineId extends Notifier<String?> {
  @override
  String? build() {
    unawaited(
      ref.read(engineStoreProvider).currentId().then((id) {
        if (id != null && state == null) state = id;
      }),
    );
    return null;
  }

  Future<void> set(String? id) async {
    state = id;
    await ref.read(engineStoreProvider).setCurrentId(id);
  }
}

final currentEngineIdProvider = NotifierProvider<CurrentEngineId, String?>(
  CurrentEngineId.new,
);

/// Drives the connection: whenever the current engine changes, the client
/// is pointed at it. Exposes the connection status for the UI.
class ConnectionController extends Notifier<ConnectionStatus> {
  StreamSubscription? _sub;
  String? _connectedId;

  @override
  ConnectionStatus build() {
    final client = ref.watch(clientProvider);
    void onStatus() => state = client.status.value;
    client.status.addListener(onStatus);
    ref.onDispose(() {
      client.status.removeListener(onStatus);
      _sub?.cancel();
    });

    final id = ref.watch(currentEngineIdProvider);
    final engines = ref.watch(enginesProvider).value;
    final e = engines?.where((x) => x.id == id).firstOrNull;
    if (e != null && _connectedId != e.id) {
      _connectedId = e.id;
      unawaited(_connect(client, e));
    } else if (e == null && _connectedId != null) {
      _connectedId = null;
      unawaited(client.close());
    }
    return client.status.value;
  }

  Future<void> _connect(EngineClient client, SavedEngine e) async {
    try {
      final info = await client.connect(e.pairing.wsUri, token: e.token);
      // Remember what the engine calls itself and when we last saw it.
      await ref
          .read(enginesProvider.notifier)
          .upsert(
            e.copyWith(
              name: info.hostname.isNotEmpty ? info.hostname : e.name,
              httpPort: info.httpPort,
              lastSeen: DateTime.now().millisecondsSinceEpoch,
            ),
          );
    } catch (_) {
      // The client keeps retrying on its own; status/lastError tell the UI.
    }
  }

  /// Retry now instead of waiting for the backoff.
  Future<void> retry() async {
    final e = ref
        .read(enginesProvider.notifier)
        .byId(ref.read(currentEngineIdProvider));
    if (e != null) await _connect(ref.read(clientProvider), e);
  }
}

final connectionProvider =
    NotifierProvider<ConnectionController, ConnectionStatus>(
      ConnectionController.new,
    );

/// Bridges one of the client's ValueNotifiers into a provider, so widgets
/// can `select` fields and rebuild only when those change.
abstract class _Bridge<T> extends Notifier<T> {
  ValueListenable<T> source(EngineClient c);

  @override
  T build() {
    final c = ref.watch(clientProvider);
    final v = source(c);
    void on() => state = v.value;
    v.addListener(on);
    ref.onDispose(() => v.removeListener(on));
    return v.value;
  }
}

class _EngineStateBridge extends _Bridge<EngineState?> {
  @override
  ValueListenable<EngineState?> source(EngineClient c) => c.state;
}

class _QueueBridge extends _Bridge<Queue?> {
  @override
  ValueListenable<Queue?> source(EngineClient c) => c.queue;
}

class _ServerInfoBridge extends _Bridge<ServerInfo?> {
  @override
  ValueListenable<ServerInfo?> source(EngineClient c) => c.serverInfo;
}

class _LastErrorBridge extends _Bridge<String?> {
  @override
  ValueListenable<String?> source(EngineClient c) => c.lastError;
}

/// Latest engine state (null until the first push).
final engineStateProvider = NotifierProvider<_EngineStateBridge, EngineState?>(
  _EngineStateBridge.new,
);
final queueProvider = NotifierProvider<_QueueBridge, Queue?>(_QueueBridge.new);
final serverInfoProvider = NotifierProvider<_ServerInfoBridge, ServerInfo?>(
  _ServerInfoBridge.new,
);
final lastErrorProvider = NotifierProvider<_LastErrorBridge, String?>(
  _LastErrorBridge.new,
);

/// Directory listings, cached per path and dropped when the engine reports
/// a change under that directory.
final listingProvider = FutureProvider.family<Listing, String>((
  ref,
  dir,
) async {
  final client = ref.watch(clientProvider);
  final sub = client.libraryChanged$.listen((c) {
    if (c.dir == dir || dir.startsWith(c.dir) || c.dir.startsWith(dir)) {
      ref.invalidateSelf();
    }
  });
  ref.onDispose(sub.cancel);
  // Keep listings around while the user walks back and forth.
  final link = ref.keepAlive();
  Timer(const Duration(minutes: 10), link.close);
  return client.list(dir);
});

final rootsProvider = FutureProvider<List<Root>>((ref) {
  final client = ref.watch(clientProvider);
  ref.watch(connectionProvider);
  return client.libraryRoots();
});

final searchQueryProvider = NotifierProvider<_SearchQuery, String>(
  _SearchQuery.new,
);

class _SearchQuery extends Notifier<String> {
  @override
  String build() => '';
  void set(String q) => state = q;
}

final searchResultsProvider = FutureProvider<List<Track>>((ref) async {
  final q = ref.watch(searchQueryProvider).trim();
  if (q.length < 2) return const [];
  // Debounce: wait a beat, bail out if the query moved on.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  if (ref.read(searchQueryProvider).trim() != q) return const [];
  return ref.read(clientProvider).search(q);
});

final favoritesProvider = FutureProvider<List<Track>>(
  (ref) => ref.watch(clientProvider).favorites(),
);
final historyProvider = FutureProvider<List<HistoryEntry>>(
  (ref) => ref.watch(clientProvider).history(),
);
final playlistsProvider = FutureProvider<List<Playlist>>(
  (ref) => ref.watch(clientProvider).playlists(),
);
final devicesProvider = FutureProvider<List<Device>>(
  (ref) => ref.watch(clientProvider).devices(),
);
final sysmodeProvider = FutureProvider<Sysmode>(
  (ref) => ref.watch(clientProvider).sysmodeGet(),
);
final sysmodeLogProvider = FutureProvider<List<SysmodeLogEntry>>(
  (ref) => ref.watch(clientProvider).sysmodeLog(),
);
final settingsProvider = FutureProvider<Settings>(
  (ref) => ref.watch(clientProvider).settingsGet(),
);

/// Lyrics for the current track, refetched when the track changes.
final lyricsProvider = FutureProvider<Lyrics?>((ref) async {
  final path = ref.watch(engineStateProvider.select((s) => s?.track?.path));
  if (path == null || path.isEmpty) return null;
  final l = await ref.watch(clientProvider).lyrics(path);
  return (l.text.isEmpty && l.lines.isEmpty) ? null : l;
});

/// Output stats polled while playing (underruns, ring fill, thread).
final outputStatsProvider = StreamProvider<OutputStats>((ref) async* {
  final client = ref.watch(clientProvider);
  while (true) {
    try {
      yield await client.outputStats();
    } catch (_) {}
    await Future<void>.delayed(const Duration(seconds: 2));
  }
});

/// Whether the one-time "no volume here" notice was acknowledged.
final volumeNoticeSeenProvider = FutureProvider<bool>(
  (ref) => ref.watch(engineStoreProvider).flag('volumeNoticeSeen'),
);

/// Transport taps feel better with a tick; tests and desktops ignore it.
void haptic() {
  if (kIsWeb) return;
  unawaited(HapticFeedback.selectionClick().catchError((_) {}));
}
