import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/providers.dart';
import '../library/track_actions.dart';

/// Queue as a tab (phone) – reorder by drag, swipe to remove, tap to jump.
class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    final q = ref.watch(queueProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(q == null ? 'Queue' : 'Queue · ${q.tracks.length}'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                client.queueGet().then((v) => client.queue.value = v),
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: q == null || q.tracks.isEmpty
                ? null
                : () => client.queueClear(),
          ),
        ],
      ),
      body: QueueBody(queue: q),
    );
  }
}

/// Shared between the tab and the bottom sheet.
class QueueBody extends ConsumerWidget {
  const QueueBody({super.key, required this.queue});
  final Queue? queue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    final playing = ref.watch(
      engineStateProvider.select((s) => s?.isPlaying ?? false),
    );
    final q = queue;
    if (q == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return QueueList(
      queue: q,
      playing: playing,
      onJump: (i) {
        haptic();
        client.queueJump(i);
      },
      onRemove: (i) => client.queueRemove(i),
      onMove: (from, to) => client.queueMove(from, to),
      onFavorite: (path, fav) {
        final t = q.tracks.where((x) => x.path == path).firstOrNull;
        if (t != null) toggleFavorite(ref, t);
      },
      emptyLabel: 'Queue is empty – pick something in the library',
    );
  }
}

Future<void> showQueueSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (ctx, _) => Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(ctx).colorScheme.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Consumer(
              builder: (ctx, ref, _) =>
                  QueueBody(queue: ref.watch(queueProvider)),
            ),
          ),
        ],
      ),
    ),
  );
}
