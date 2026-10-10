import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/providers.dart';

/// Compact window: cover, titles, format, seek, transport. Toggled from
/// the window menu; the window itself is resized by the shell.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  static const size = Size(420, 150);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stateProvider);
    final client = ref.watch(clientProvider);
    final scheme = Theme.of(context).colorScheme;
    final t = s.track;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CoverImage(hash: t?.cover ?? '', client: client, size: 126),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t?.displayTitle ?? 'Nothing playing',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Back to full window',
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.open_in_full),
                        onPressed: () =>
                            ref.read(miniModeProvider.notifier).set(false),
                      ),
                    ],
                  ),
                  Text(
                    t == null
                        ? ''
                        : [
                            t.displayArtist,
                            t.album,
                          ].where((x) => x.isNotEmpty).join(' — '),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  FormatBadge(state: s, compact: true),
                  const Spacer(),
                  SeekBar(state: s, onSeekMs: client.seekMs, height: 18),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: TransportBar(
                      state: s,
                      iconSize: 18,
                      playSize: 28,
                      showToggles: false,
                      onPrev: client.prev,
                      onToggle: client.toggle,
                      onNext: client.next,
                      onStop: client.stop,
                    ),
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
