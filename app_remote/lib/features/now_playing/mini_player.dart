import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/providers.dart';

/// Compact strip above the navigation bar: cover, title, format, play/pause.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(engineStateProvider);
    final client = ref.watch(clientProvider);
    final t = s?.track;
    if (s == null || t == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: s.progress,
              minHeight: 2,
              backgroundColor: Colors.transparent,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              child: Row(
                children: [
                  CoverImage(
                    hash: t.cover,
                    client: client,
                    size: 40,
                    thumb: true,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.displayTitle,
                          key: const Key('miniTitle'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                        Text(
                          '${t.displayArtist} · ${t.formatBadge}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (s.output.bitPerfect)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(
                        Icons.circle,
                        size: 8,
                        color: Ol1nTheme.bitPerfectGreen,
                      ),
                    ),
                  IconButton(
                    key: const Key('miniToggle'),
                    icon: Icon(s.isPlaying ? Icons.pause : Icons.play_arrow),
                    onPressed: () {
                      haptic();
                      client.toggle();
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: () {
                      haptic();
                      client.next();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
