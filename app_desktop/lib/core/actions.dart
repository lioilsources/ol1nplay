import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';
import 'package:url_launcher/url_launcher.dart';

import 'providers.dart';

/// Thin layer over [EngineClient] for the things the UI does from several
/// places (tree menu, list menu, drag & drop, shortcuts). Errors become a
/// snackbar instead of an unhandled future.
class EngineActions {
  EngineActions(this.ref);

  final Ref ref;
  EngineClient get client => ref.read(clientProvider);

  Future<void> guard(BuildContext? context, Future<void> Function() f) async {
    // Grab the messenger before awaiting so no context crosses the gap.
    final messenger = context == null
        ? null
        : ScaffoldMessenger.maybeOf(context);
    try {
      await f();
    } on EngineException catch (e) {
      _toast(messenger, '${e.command}: ${e.message}');
    } catch (e) {
      _toast(messenger, e.toString());
    }
  }

  void _toast(ScaffoldMessengerState? m, String msg) {
    m?.showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> playDir(BuildContext? c, String dir, {int index = 0}) =>
      guard(c, () => client.playDir(dir, index: index));

  Future<void> playPaths(
    BuildContext? c,
    List<String> paths, {
    int index = 0,
  }) => guard(c, () => client.playPaths(paths, index: index));

  Future<void> enqueueDir(BuildContext? c, String dir) => guard(c, () async {
    final l = await client.list(dir);
    if (l.tracks.isEmpty) return;
    await client.queueAdd(l.tracks.map((t) => t.path).toList());
  });

  Future<void> playNextDir(BuildContext? c, String dir) => guard(c, () async {
    final l = await client.list(dir);
    if (l.tracks.isEmpty) return;
    final q = ref.read(queueProvider);
    await client.queueInsert(
      l.tracks.map((t) => t.path).toList(),
      (q?.index ?? -1) + 1,
    );
  });

  Future<void> enqueue(BuildContext? c, List<String> paths) =>
      guard(c, () => client.queueAdd(paths));

  Future<void> playNext(BuildContext? c, List<String> paths) => guard(c, () {
    final q = ref.read(queueProvider);
    return client.queueInsert(paths, (q?.index ?? -1) + 1);
  });

  Future<void> favorite(BuildContext? c, String path, bool on) =>
      guard(c, () async {
        on ? await client.addFavorite(path) : await client.removeFavorite(path);
        ref.read(libraryVersionProvider.notifier).bumpAll();
      });

  Future<void> rescan(BuildContext? c, String dir) =>
      guard(c, () => client.rescan(dir));

  /// Opens the folder in Explorer / Finder. Paths on a remote engine are
  /// meaningless here, so the button is only offered for a local engine.
  Future<void> reveal(BuildContext? c, String path) async {
    final messenger = c == null ? null : ScaffoldMessenger.maybeOf(c);
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', ['/select,', path]);
      } else if (Platform.isMacOS) {
        await Process.start('open', ['-R', path]);
      } else {
        await launchUrl(Uri.file(File(path).parent.path));
      }
    } catch (e) {
      _toast(messenger, 'Cannot reveal: $e');
    }
  }

  /// Dropped files/folders: folders are expanded by the engine (`play dir`
  /// for a single folder), files go in as paths.
  Future<void> dropped(
    BuildContext? c,
    List<String> paths, {
    bool enqueue = false,
  }) async {
    if (paths.isEmpty) return;
    final dirs = paths
        .where((p) => FileSystemEntity.isDirectorySync(p))
        .toList();
    final files = paths
        .where((p) => !FileSystemEntity.isDirectorySync(p))
        .toList();
    if (dirs.length == 1 && files.isEmpty) {
      return enqueue ? enqueueDir(c, dirs.first) : playDir(c, dirs.first);
    }
    await guard(c, () async {
      final all = <String>[...files];
      for (final d in dirs) {
        final l = await client.list(d);
        all.addAll(l.tracks.map((t) => t.path));
      }
      if (all.isEmpty) return;
      enqueue ? await client.queueAdd(all) : await client.playPaths(all);
    });
  }
}

final actionsProvider = Provider<EngineActions>((ref) => EngineActions(ref));
