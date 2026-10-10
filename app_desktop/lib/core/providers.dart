import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import 'engine_launcher.dart';
import 'engine_target.dart';
import 'prefs.dart';

// ---------------------------------------------------------------- bootstrap

/// Overridden in main() / tests.
final prefsProvider = Provider<Prefs>((_) => throw UnimplementedError('prefs'));
final engineTargetProvider = Provider<EngineTarget>(
  (_) => throw UnimplementedError('engine target'),
);

/// False in tests and headless runs: no window_manager / tray / process spawn.
final desktopIntegrationProvider = Provider<bool>((_) => true);

final clientProvider = Provider<EngineClient>((ref) {
  final c = EngineClient();
  ref.onDispose(() => c.dispose());
  return c;
});

final launcherProvider = Provider<EngineLauncher>((ref) {
  final l = EngineLauncher(
    client: ref.watch(clientProvider),
    target: ref.watch(engineTargetProvider),
    spawn: ref.watch(desktopIntegrationProvider),
  );
  ref.onDispose(() => l.dispose());
  return l;
});

// ---------------------------------------------------------------- client bridges

/// Mirrors one of the client's ValueNotifiers into a Riverpod state.
abstract class _Bridge<T> extends Notifier<T> {
  ValueListenable<T> source(EngineClient c);

  @override
  T build() {
    final s = source(ref.watch(clientProvider));
    void l() => state = s.value;
    s.addListener(l);
    ref.onDispose(() => s.removeListener(l));
    return s.value;
  }
}

class EngineStateNotifier extends _Bridge<EngineState?> {
  @override
  ValueListenable<EngineState?> source(EngineClient c) => c.state;
}

class QueueNotifier extends _Bridge<Queue?> {
  @override
  ValueListenable<Queue?> source(EngineClient c) => c.queue;
}

class ConnectionNotifier extends _Bridge<ConnectionStatus> {
  @override
  ValueListenable<ConnectionStatus> source(EngineClient c) => c.status;
}

class ServerInfoNotifier extends _Bridge<ServerInfo?> {
  @override
  ValueListenable<ServerInfo?> source(EngineClient c) => c.serverInfo;
}

class LastErrorNotifier extends _Bridge<String?> {
  @override
  ValueListenable<String?> source(EngineClient c) => c.lastError;
}

final engineStateProvider = NotifierProvider<EngineStateNotifier, EngineState?>(
  EngineStateNotifier.new,
);
final queueProvider = NotifierProvider<QueueNotifier, Queue?>(
  QueueNotifier.new,
);
final connectionProvider =
    NotifierProvider<ConnectionNotifier, ConnectionStatus>(
      ConnectionNotifier.new,
    );
final serverInfoProvider = NotifierProvider<ServerInfoNotifier, ServerInfo?>(
  ServerInfoNotifier.new,
);
final lastErrorProvider = NotifierProvider<LastErrorNotifier, String?>(
  LastErrorNotifier.new,
);

/// The engine state, never null (empty before the first push).
final stateProvider = Provider<EngineState>(
  (ref) => ref.watch(engineStateProvider) ?? EngineState.empty,
);

// ---------------------------------------------------------------- library

/// Bumped whenever the library changes so cached listings refresh. Keyed
/// by dir so an unrelated folder does not reload.
class LibraryVersionNotifier extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() {
    final c = ref.watch(clientProvider);
    final sub = c.libraryChanged$.listen((ch) {
      state = {
        ...state,
        ch.dir: (state[ch.dir] ?? 0) + 1,
        '': (state[''] ?? 0) + 1,
      };
    });
    ref.onDispose(sub.cancel);
    return const {};
  }

  void bumpAll() => state = {...state, '': (state[''] ?? 0) + 1};
}

final libraryVersionProvider =
    NotifierProvider<LibraryVersionNotifier, Map<String, int>>(
      LibraryVersionNotifier.new,
    );

final rootsProvider = FutureProvider<List<Root>>((ref) async {
  ref.watch(connectionProvider);
  ref.watch(libraryVersionProvider.select((m) => m['']));
  final c = ref.watch(clientProvider);
  if (!c.isConnected) return const [];
  return c.libraryRoots();
});

final treeProvider = FutureProvider.family<List<DirNode>, String>((
  ref,
  dir,
) async {
  ref.watch(connectionProvider);
  ref.watch(libraryVersionProvider.select((m) => m[dir]));
  ref.watch(libraryVersionProvider.select((m) => m['']));
  final c = ref.watch(clientProvider);
  if (!c.isConnected) return const [];
  return c.tree(dir);
});

final listingProvider = FutureProvider.family<Listing, String>((
  ref,
  dir,
) async {
  ref.watch(connectionProvider);
  ref.watch(libraryVersionProvider.select((m) => m[dir]));
  final c = ref.watch(clientProvider);
  if (!c.isConnected) return Listing(dir: dir);
  return c.list(dir);
});

class SelectedDirNotifier extends Notifier<String> {
  @override
  String build() => ref.read(prefsProvider).lastDir;

  void select(String dir) {
    state = dir;
    ref.read(prefsProvider).lastDir = dir;
    ref.read(middleViewProvider.notifier).set(MiddleView.folder);
    ref.read(searchQueryProvider.notifier).clear();
  }
}

final selectedDirProvider = NotifierProvider<SelectedDirNotifier, String>(
  SelectedDirNotifier.new,
);

/// Expanded nodes of the tree.
class ExpandedNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};
  void toggle(String path) => state = state.contains(path)
      ? ({...state}..remove(path))
      : {...state, path};
  void expand(String path) => state = {...state, path};
}

final expandedProvider = NotifierProvider<ExpandedNotifier, Set<String>>(
  ExpandedNotifier.new,
);

// ---------------------------------------------------------------- search

class SearchQueryNotifier extends Notifier<String> {
  Timer? _debounce;

  @override
  String build() {
    ref.onDispose(() => _debounce?.cancel());
    return '';
  }

  /// Debounced: typing does not hammer the engine.
  void set(String q) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 250),
      () => state = q.trim(),
    );
  }

  void clear() {
    _debounce?.cancel();
    state = '';
  }
}

final searchQueryProvider = NotifierProvider<SearchQueryNotifier, String>(
  SearchQueryNotifier.new,
);

final searchResultsProvider = FutureProvider<List<Track>?>((ref) async {
  final q = ref.watch(searchQueryProvider);
  if (q.isEmpty) return null;
  ref.watch(libraryVersionProvider.select((m) => m['']));
  return ref.watch(clientProvider).search(q, limit: 500);
});

// ---------------------------------------------------------------- middle pane

enum MiddleView { folder, queue, favorites, history, playlists, lyrics }

class MiddleViewNotifier extends Notifier<MiddleView> {
  @override
  MiddleView build() {
    final saved = ref.read(prefsProvider).middleView;
    return MiddleView.values.firstWhere(
      (v) => v.name == saved,
      orElse: () => MiddleView.folder,
    );
  }

  void set(MiddleView v) {
    state = v;
    ref.read(prefsProvider).middleView = v.name;
  }
}

final middleViewProvider = NotifierProvider<MiddleViewNotifier, MiddleView>(
  MiddleViewNotifier.new,
);

/// Multi-selection in the track list: paths + the anchor for shift-click.
class Selection {
  const Selection({this.paths = const {}, this.anchor});
  final Set<String> paths;
  final String? anchor;
  bool contains(String p) => paths.contains(p);
  bool get isEmpty => paths.isEmpty;
}

class SelectionNotifier extends Notifier<Selection> {
  @override
  Selection build() => const Selection();

  void click(
    List<Track> list,
    Track t, {
    bool ctrl = false,
    bool shift = false,
  }) {
    if (shift && state.anchor != null) {
      final a = list.indexWhere((x) => x.path == state.anchor);
      final b = list.indexWhere((x) => x.path == t.path);
      if (a >= 0 && b >= 0) {
        final lo = a < b ? a : b;
        final hi = a < b ? b : a;
        final range = list.sublist(lo, hi + 1).map((x) => x.path);
        state = Selection(
          paths: ctrl ? {...state.paths, ...range} : range.toSet(),
          anchor: state.anchor,
        );
        return;
      }
    }
    if (ctrl) {
      final s = {...state.paths};
      s.contains(t.path) ? s.remove(t.path) : s.add(t.path);
      state = Selection(paths: s, anchor: t.path);
      return;
    }
    state = Selection(paths: {t.path}, anchor: t.path);
  }

  void clear() => state = const Selection();
  void all(List<Track> list) => state = Selection(
    paths: list.map((t) => t.path).toSet(),
    anchor: state.anchor,
  );
}

final selectionProvider = NotifierProvider<SelectionNotifier, Selection>(
  SelectionNotifier.new,
);

// ---------------------------------------------------------------- settings

class SettingsNotifier extends Notifier<Settings?> {
  @override
  Settings? build() {
    final c = ref.watch(clientProvider);
    final st = ref.watch(connectionProvider);
    if (st == ConnectionStatus.connected) {
      c.settingsGet().then((s) => state = s, onError: (_) {});
    }
    return null;
  }

  Future<void> patch(Json patch) async {
    final s = await ref.read(clientProvider).settingsSet(patch);
    state = s;
  }

  Future<void> update(Settings next) async {
    final base = state ?? Settings.defaults;
    final s = await ref.read(clientProvider).settingsUpdate(next, base);
    state = s;
  }

  Future<void> reload() async {
    state = await ref.read(clientProvider).settingsGet();
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, Settings?>(
  SettingsNotifier.new,
);

// ---------------------------------------------------------------- output

final devicesProvider = FutureProvider<List<Device>>((ref) async {
  ref.watch(connectionProvider);
  ref.watch(stateProvider.select((s) => s.output.deviceId));
  final c = ref.watch(clientProvider);
  if (!c.isConnected) return const [];
  return c.devices();
});

/// Hot counters, polled once a second while the device runs.
final outputStatsProvider = StreamProvider.autoDispose<OutputStats>((ref) {
  final c = ref.watch(clientProvider);
  final running = ref.watch(stateProvider.select((s) => s.output.isRunning));
  final ctl = StreamController<OutputStats>();
  Timer? t;
  Future<void> poll() async {
    try {
      final s = await c.outputStats();
      if (!ctl.isClosed) ctl.add(s);
    } catch (_) {}
  }

  if (running) {
    poll();
    t = Timer.periodic(const Duration(seconds: 1), (_) => poll());
  }
  ref.onDispose(() {
    t?.cancel();
    ctl.close();
  });
  return ctl.stream;
});

// ---------------------------------------------------------------- log

class LogNotifier extends Notifier<List<LogLine>> {
  static const cap = 200;

  @override
  List<LogLine> build() {
    final c = ref.watch(clientProvider);
    final sub = c.log$.listen((l) {
      final next = [...state, l];
      state = next.length > cap ? next.sublist(next.length - cap) : next;
    });
    ref.onDispose(sub.cancel);
    return const [];
  }

  void clear() => state = const [];
}

final logProvider = NotifierProvider<LogNotifier, List<LogLine>>(
  LogNotifier.new,
);

final scanProgressProvider = StreamProvider<ScanProgress>(
  (ref) => ref.watch(clientProvider).scan$,
);

// ---------------------------------------------------------------- window modes

class BoolNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
  void toggle() => state = !state;
}

final miniModeProvider = NotifierProvider<BoolNotifier, bool>(BoolNotifier.new);
final fullscreenNowPlayingProvider = NotifierProvider<BoolNotifier, bool>(
  BoolNotifier.new,
);
final showLogProvider = NotifierProvider<BoolNotifier, bool>(BoolNotifier.new);

/// Which A/B marker the keyboard nudges (null = none focused).
class ABFocusNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? v) => state = v;
}

final abFocusProvider = NotifierProvider<ABFocusNotifier, String?>(
  ABFocusNotifier.new,
);

/// Lyrics for the current track, fetched when the track changes.
final lyricsProvider = FutureProvider<Lyrics?>((ref) async {
  final path = ref.watch(stateProvider.select((s) => s.track?.path));
  if (path == null) return null;
  final inline = ref.read(stateProvider).lyrics;
  if (inline != null && !inline.isEmpty) return inline;
  try {
    final l = await ref.watch(clientProvider).lyrics(path);
    return l.isEmpty ? null : l;
  } catch (_) {
    return null;
  }
});
