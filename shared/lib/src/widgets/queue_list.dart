import 'package:flutter/material.dart';

import '../protocol/state_models.dart';
import 'track_tile.dart';

/// The play queue, reorderable. Emits the engine's queue.* commands.
class QueueList extends StatelessWidget {
  const QueueList({
    super.key,
    required this.queue,
    this.playing = false,
    this.onJump,
    this.onRemove,
    this.onMove,
    this.onFavorite,
    this.dense = true,
    this.emptyLabel = 'Queue is empty',
  });

  final Queue queue;
  final bool playing;
  final ValueChanged<int>? onJump;
  final ValueChanged<int>? onRemove;

  /// (from, to)
  final void Function(int from, int to)? onMove;

  /// (path, favorite)
  final void Function(String path, bool favorite)? onFavorite;
  final bool dense;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    if (queue.isEmpty) {
      return Center(
        child: Text(
          emptyLabel,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ReorderableListView.builder(
      buildDefaultDragHandles: onMove != null,
      itemCount: queue.tracks.length,
      // onReorderItem already reports the final index (unlike the older
      // onReorder, which gave the insertion slot).
      onReorderItem: (from, to) {
        if (onMove != null && from != to) onMove!(from, to);
      },
      itemBuilder: (context, i) {
        final t = queue.tracks[i];
        return Dismissible(
          key: ValueKey('${t.path}#$i'),
          direction: onRemove == null
              ? DismissDirection.none
              : DismissDirection.endToStart,
          onDismissed: (_) => onRemove?.call(i),
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            color: Theme.of(context).colorScheme.error.withValues(alpha: 0.3),
            child: const Icon(Icons.delete_outline),
          ),
          child: TrackTile(
            track: t,
            dense: dense,
            nowPlaying: i == queue.index,
            playing: i == queue.index && playing,
            showNumber: false,
            onTap: onJump == null ? null : () => onJump!(i),
            onFavorite: onFavorite == null
                ? null
                : (f) => onFavorite!(t.path, f),
            trailing: onRemove == null
                ? null
                : IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => onRemove!(i),
                  ),
          ),
        );
      },
    );
  }
}
