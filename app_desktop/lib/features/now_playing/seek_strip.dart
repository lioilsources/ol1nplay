import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/actions.dart';
import '../../core/providers.dart';

/// The strip under the three panes: the seek bar across the whole window,
/// drawn as the track's loudness, with the Stereo · Mono · L · R switch at
/// its end.
class SeekStrip extends ConsumerWidget {
  const SeekStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stateProvider);
    final client = ref.watch(clientProvider);
    final a = ref.read(actionsProvider);
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outline)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: SeekBar(
                key: const ValueKey('seekStrip'),
                state: s,
                onSeekMs: (ms) => client.seekMs(ms),
                waveform: ref.watch(waveformProvider).value,
                // About a centimetre on a desktop monitor.
                height: 44,
              ),
            ),
            const SizedBox(width: 14),
            MonoModeSwitch(
              mode: s.monoMode,
              onChanged: (m) => a.guard(context, () => client.setMonoMode(m)),
            ),
          ],
        ),
      ),
    );
  }
}
