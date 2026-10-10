import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/actions.dart';
import '../../core/providers.dart';
import '../library/track_list.dart';

/// Middle pane switcher: folder · queue · favorites · history · playlists · lyrics.
class MiddlePane extends ConsumerWidget {
  const MiddlePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(middleViewProvider);
    final query = ref.watch(searchQueryProvider);
    if (query.isNotEmpty) return const TrackListPane();
    return switch (view) {
      MiddleView.folder => const TrackListPane(),
      MiddleView.queue => const QueueView(),
      MiddleView.favorites => const FavoritesView(),
      MiddleView.history => const HistoryView(),
      MiddleView.playlists => const PlaylistsView(),
      MiddleView.lyrics => const LyricsPane(),
    };
  }
}

/// Tabs above the middle pane.
class MiddleTabs extends ConsumerWidget {
  const MiddleTabs({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(middleViewProvider);
    final qlen = ref.watch(stateProvider.select((s) => s.queueLen));
    final scheme = Theme.of(context).colorScheme;
    Widget tab(MiddleView v, IconData icon, String label, {String? badge}) {
      final on = v == view;
      return InkWell(
        onTap: () {
          ref.read(searchQueryProvider.notifier).clear();
          ref.read(middleViewProvider.notifier).set(v);
        },
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: on ? scheme.primary.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: on ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: on ? scheme.primary : scheme.onSurface,
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 5),
                Text(
                  badge,
                  style: Ol1nTheme.mono(
                    context,
                    size: 10,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outline)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            tab(MiddleView.folder, Icons.folder_outlined, 'Folder'),
            tab(
              MiddleView.queue,
              Icons.queue_music,
              'Queue',
              badge: qlen > 0 ? '$qlen' : null,
            ),
            tab(MiddleView.favorites, Icons.favorite_border, 'Favorites'),
            tab(MiddleView.history, Icons.history, 'History'),
            tab(MiddleView.playlists, Icons.playlist_play, 'Playlists'),
            tab(MiddleView.lyrics, Icons.lyrics_outlined, 'Lyrics'),
          ],
        ),
      ),
    );
  }
}

class QueueView extends ConsumerWidget {
  const QueueView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(queueProvider) ?? Queue.empty;
    final playing = ref.watch(stateProvider.select((s) => s.isPlaying));
    final client = ref.watch(clientProvider);
    final a = ref.read(actionsProvider);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outline)),
          ),
          child: Row(
            children: [
              Text(
                '${q.length} tracks · ${fmtDuration(q.tracks.fold(0, (s, t) => s + t.durationMs))}',
                style: Ol1nTheme.mono(
                  context,
                  size: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.save_outlined, size: 16),
                label: const Text('Save as playlist'),
                onPressed: q.isEmpty ? null : () => _savePlaylist(context, ref),
              ),
              TextButton.icon(
                icon: const Icon(Icons.clear_all, size: 16),
                label: const Text('Clear'),
                onPressed: q.isEmpty
                    ? null
                    : () => a.guard(context, client.queueClear),
              ),
            ],
          ),
        ),
        Expanded(
          child: QueueList(
            queue: q,
            playing: playing,
            onJump: (i) => a.guard(context, () => client.queueJump(i)),
            onRemove: (i) => a.guard(context, () => client.queueRemove(i)),
            onMove: (from, to) =>
                a.guard(context, () => client.queueMove(from, to)),
            onFavorite: (p, on) => a.favorite(context, p, on),
          ),
        ),
      ],
    );
  }

  Future<void> _savePlaylist(BuildContext context, WidgetRef ref) async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save queue as playlist'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !context.mounted) return;
    await ref
        .read(actionsProvider)
        .guard(context, () => ref.read(clientProvider).savePlaylist(name));
  }
}

final favoritesProvider = FutureProvider<List<Track>>((ref) async {
  ref.watch(libraryVersionProvider.select((m) => m['']));
  ref.watch(connectionProvider);
  final c = ref.watch(clientProvider);
  return c.isConnected ? c.favorites() : const [];
});

class FavoritesView extends ConsumerWidget {
  const FavoritesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fav = ref.watch(favoritesProvider);
    return fav.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) => TrackList(
        tracks: list,
        showArtist: true,
        emptyLabel: 'No favorites yet — click a heart',
      ),
    );
  }
}

final historyProvider = FutureProvider<List<HistoryEntry>>((ref) async {
  ref.watch(stateProvider.select((s) => s.track?.path));
  ref.watch(connectionProvider);
  final c = ref.watch(clientProvider);
  return c.isConnected ? c.history(limit: 200) : const [];
});

class HistoryView extends ConsumerWidget {
  const HistoryView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final h = ref.watch(historyProvider);
    return h.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) {
        final tracks = list.map((e) => e.track).toList();
        return TrackList(
          tracks: tracks,
          showArtist: true,
          emptyLabel: 'Nothing played yet',
        );
      },
    );
  }
}

final playlistsProvider = FutureProvider<List<Playlist>>((ref) async {
  ref.watch(libraryVersionProvider.select((m) => m['']));
  ref.watch(connectionProvider);
  final c = ref.watch(clientProvider);
  return c.isConnected ? c.playlists() : const [];
});

class PlaylistsView extends ConsumerWidget {
  const PlaylistsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pl = ref.watch(playlistsProvider);
    final a = ref.read(actionsProvider);
    final client = ref.watch(clientProvider);
    final scheme = Theme.of(context).colorScheme;
    return pl.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) => list.isEmpty
          ? Center(
              child: Text(
                'No .m3u playlists found',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          : ListView.builder(
              itemCount: list.length,
              itemBuilder: (_, i) {
                final p = list[i];
                return ListTile(
                  leading: const Icon(Icons.playlist_play),
                  title: Text(p.name.isEmpty ? baseName(p.path) : p.name),
                  subtitle: Text(
                    p.path,
                    style: Ol1nTheme.mono(
                      context,
                      size: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    '${p.count}',
                    style: Ol1nTheme.mono(context, size: 11),
                  ),
                  onTap: () => a.guard(context, () async {
                    await client.loadPlaylist(p.path);
                    await client.resume();
                  }),
                );
              },
            ),
    );
  }
}

class LyricsPane extends ConsumerWidget {
  const LyricsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyrics = ref.watch(lyricsProvider).value;
    final pos = ref.watch(stateProvider.select((s) => s.positionMs));
    final client = ref.watch(clientProvider);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LyricsView(
        lyrics: lyrics,
        positionMs: pos,
        onSeekMs: (ms) => client.seekMs(ms),
        emptyLabel: 'No lyrics (.lrc / .txt sidecar or tag)',
      ),
    );
  }
}
