import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/actions.dart';
import '../../core/providers.dart';

/// Context menu for one or more tracks. [all] is the visible list (so
/// "play" starts the list from the clicked track), [targets] the selection.
Future<void> showTrackMenu(
  BuildContext context,
  WidgetRef ref,
  Offset at, {
  required List<Track> all,
  required Track clicked,
  required List<Track> targets,
}) async {
  final a = ref.read(actionsProvider);
  final local = ref.read(engineTargetProvider).local;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final many = targets.length > 1;
  final fav = targets.every((t) => t.favorite);
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      at & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: [
      PopupMenuItem(
        value: 'play',
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.play_arrow),
          title: Text(many ? 'Play selected' : 'Play'),
        ),
      ),
      PopupMenuItem(
        value: 'playfrom',
        child: const ListTile(
          dense: true,
          leading: Icon(Icons.playlist_play),
          title: Text('Play list from here'),
        ),
      ),
      const PopupMenuItem(
        value: 'next',
        child: ListTile(
          dense: true,
          leading: Icon(Icons.skip_next),
          title: Text('Play next'),
        ),
      ),
      const PopupMenuItem(
        value: 'add',
        child: ListTile(
          dense: true,
          leading: Icon(Icons.playlist_add),
          title: Text('Add to queue'),
        ),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: 'fav',
        child: ListTile(
          dense: true,
          leading: Icon(fav ? Icons.favorite : Icons.favorite_border),
          title: Text(fav ? 'Remove from favorites' : 'Add to favorites'),
        ),
      ),
      if (local && !many)
        const PopupMenuItem(
          value: 'reveal',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.folder_open),
            title: Text('Reveal in file manager'),
          ),
        ),
      const PopupMenuItem(
        value: 'info',
        child: ListTile(
          dense: true,
          leading: Icon(Icons.info_outline),
          title: Text('Properties'),
        ),
      ),
    ],
  );
  if (!context.mounted) return;
  final paths = targets.map((t) => t.path).toList();
  switch (choice) {
    case 'play':
      await a.playPaths(context, paths);
    case 'playfrom':
      await a.playPaths(
        context,
        all.map((t) => t.path).toList(),
        index: all.indexOf(clicked),
      );
    case 'next':
      await a.playNext(context, paths);
    case 'add':
      await a.enqueue(context, paths);
    case 'fav':
      for (final p in paths) {
        await a.favorite(context, p, !fav);
      }
    case 'reveal':
      await a.reveal(context, clicked.isCue ? clicked.cueFile : clicked.path);
    case 'info':
      await showTrackInfo(context, clicked);
  }
}

Future<void> showTrackInfo(BuildContext context, Track t) {
  final rows = <MapEntry<String, String>>[
    MapEntry('Path', t.path),
    if (t.isCue) MapEntry('CUE file', t.cueFile),
    MapEntry('Title', t.title),
    MapEntry('Artist', t.artist),
    MapEntry('Album artist', t.albumArtist),
    MapEntry('Album', t.album),
    MapEntry(
      'Track',
      '${t.trackNo}${t.discNo > 0 ? ' / disc ${t.discNo}' : ''}',
    ),
    MapEntry('Year', t.year == 0 ? '' : '${t.year}'),
    MapEntry('Genre', t.genre),
    MapEntry('Composer', t.composer),
    MapEntry('Codec', '${t.codec} (${t.container})'),
    MapEntry('Format', t.formatBadge),
    MapEntry('Channels', '${t.channels}'),
    MapEntry('Duration', fmtDuration(t.durationMs)),
    MapEntry('Samples', '${t.samples}'),
    MapEntry('Size', fmtBytes(t.sizeBytes)),
    if (t.replayGain != 0)
      MapEntry('ReplayGain (not applied)', '${t.replayGain} dB'),
    MapEntry('Play count', '${t.playCount}'),
    if (t.comment.isNotEmpty) MapEntry('Comment', t.comment),
  ].where((e) => e.value.isNotEmpty).toList();
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.displayTitle),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 150,
                        child: Text(
                          r.key,
                          style: TextStyle(
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Expanded(
                        child: SelectableText(
                          r.value,
                          style: Ol1nTheme.mono(ctx, size: 12),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
