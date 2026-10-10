import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/providers.dart';
import 'track_actions.dart';

class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favs = ref.watch(favoritesProvider);
    final client = ref.watch(clientProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Favorites'),
        actions: [
          favs.maybeWhen(
            data: (t) => IconButton(
              tooltip: 'Play all',
              icon: const Icon(Icons.play_arrow),
              onPressed: t.isEmpty
                  ? null
                  : () => client.playPaths(t.map((x) => x.path).toList()),
            ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: _TrackListBody(
        value: favs,
        empty: 'No favorites yet',
        onRetry: () => ref.invalidate(favoritesProvider),
      ),
    );
  }
}

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hist = ref.watch(historyProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: _TrackListBody(
        value: hist.whenData((h) => h.map((e) => e.track).toList()),
        subtitles: hist.value
            ?.map((e) => _ago(e.playedAt) + (e.complete ? '' : ' · skipped'))
            .toList(),
        empty: 'Nothing played yet',
        onRetry: () => ref.invalidate(historyProvider),
      ),
    );
  }

  static String _ago(int ms) {
    if (ms == 0) return '';
    final d = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(ms),
    );
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}

class PlaylistsScreen extends ConsumerWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pls = ref.watch(playlistsProvider);
    final client = ref.watch(clientProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlists'),
        actions: [
          IconButton(
            tooltip: 'Save queue as playlist',
            icon: const Icon(Icons.save_outlined),
            onPressed: () async {
              final name = await _askName(context);
              if (name == null || name.isEmpty) return;
              await client.savePlaylist(name);
              ref.invalidate(playlistsProvider);
            },
          ),
        ],
      ),
      body: pls.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => list.isEmpty
            ? const Center(child: Text('No M3U playlists found'))
            : ListView.builder(
                itemCount: list.length,
                itemBuilder: (ctx, i) {
                  final p = list[i];
                  return ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: Text(p.name.isEmpty ? p.path : p.name),
                    subtitle: Text('${p.count} tracks'),
                    onTap: () {
                      haptic();
                      client.loadPlaylist(p.path);
                    },
                  );
                },
              ),
      ),
    );
  }

  static Future<String?> _askName(BuildContext context) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Playlist name'),
        content: TextField(controller: ctl, autofocus: true),
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
  }
}

class _TrackListBody extends ConsumerWidget {
  const _TrackListBody({
    required this.value,
    required this.empty,
    required this.onRetry,
    this.subtitles,
  });

  final AsyncValue<List<Track>> value;
  final List<String>? subtitles;
  final String empty;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    return value.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$e'),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
      data: (tracks) => tracks.isEmpty
          ? Center(child: Text(empty))
          : ListView.builder(
              itemCount: tracks.length,
              itemBuilder: (ctx, i) {
                final t = tracks[i];
                final sub = subtitles != null && i < subtitles!.length
                    ? subtitles![i]
                    : null;
                return TrackTile(
                  key: ValueKey('x:$i:${t.path}'),
                  track: t,
                  showNumber: false,
                  onTap: () {
                    haptic();
                    client.playPaths(
                      tracks.map((x) => x.path).toList(),
                      index: i,
                    );
                  },
                  onSecondaryTap: () =>
                      showTrackActions(ctx, ref, t, siblings: tracks),
                  onFavorite: (_) => toggleFavorite(ref, t),
                  trailing: sub == null
                      ? null
                      : Text(sub, style: Ol1nTheme.mono(ctx, size: 10)),
                );
              },
            ),
    );
  }
}
