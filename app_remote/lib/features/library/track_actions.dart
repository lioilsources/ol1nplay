import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/providers.dart';

/// Long-press menu shared by every track list: play / play next / add to
/// queue / favorite. [siblings] is the list the track sits in, so "play"
/// starts the whole album from that track like a desktop player would.
Future<void> showTrackActions(
  BuildContext context,
  WidgetRef ref,
  Track track, {
  List<Track> siblings = const [],
}) async {
  final client = ref.read(clientProvider);
  final paths = siblings.isEmpty
      ? [track.path]
      : siblings.map((t) => t.path).toList();
  final index = siblings.isEmpty
      ? 0
      : siblings.indexOf(track).clamp(0, 1 << 30);
  await showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: CoverImage(hash: track.cover, client: client, size: 40),
            title: Text(track.displayTitle),
            subtitle: Text(
              '${track.displayArtist} · ${track.formatBadge}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: const Text('Play'),
            onTap: () {
              Navigator.pop(ctx);
              haptic();
              client.playPaths(paths, index: index);
            },
          ),
          ListTile(
            leading: const Icon(Icons.playlist_play),
            title: const Text('Play next'),
            onTap: () {
              Navigator.pop(ctx);
              client.queueInsert([track.path], 0);
            },
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('Add to queue'),
            onTap: () {
              Navigator.pop(ctx);
              client.queueAdd([track.path]);
            },
          ),
          ListTile(
            leading: Icon(
              track.favorite ? Icons.favorite : Icons.favorite_border,
            ),
            title: Text(track.favorite ? 'Remove favorite' : 'Favorite'),
            onTap: () async {
              Navigator.pop(ctx);
              await toggleFavorite(ref, track);
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> toggleFavorite(WidgetRef ref, Track track) async {
  final client = ref.read(clientProvider);
  if (track.favorite) {
    await client.removeFavorite(track.path);
  } else {
    await client.addFavorite(track.path);
  }
  ref.invalidate(favoritesProvider);
  ref.invalidate(listingProvider(track.dir));
}

/// Folder menu: play / play next / add – via the engine's `play dir`.
Future<void> showDirActions(
  BuildContext context,
  WidgetRef ref,
  DirNode dir,
) async {
  final client = ref.read(clientProvider);
  await showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: CoverImage(hash: dir.cover, client: client, size: 40),
            title: Text(dir.name),
            subtitle: Text('${dir.tracks} tracks'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: const Text('Play folder'),
            onTap: () {
              Navigator.pop(ctx);
              haptic();
              client.playDir(dir.path);
            },
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('Add folder to queue'),
            onTap: () async {
              Navigator.pop(ctx);
              final l = await client.list(dir.path);
              await client.queueAdd(l.tracks.map((t) => t.path).toList());
            },
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('Rescan folder'),
            onTap: () {
              Navigator.pop(ctx);
              client.rescan(dir.path);
            },
          ),
        ],
      ),
    ),
  );
}
