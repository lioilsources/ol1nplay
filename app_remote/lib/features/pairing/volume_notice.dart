import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/providers.dart';

/// Shows the "there is no volume control" notice exactly once, as a bottom
/// sheet over the shell, then remembers that it was seen.
class VolumeNoticeGate extends ConsumerStatefulWidget {
  const VolumeNoticeGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<VolumeNoticeGate> createState() => _VolumeNoticeGateState();
}

class _VolumeNoticeGateState extends ConsumerState<VolumeNoticeGate> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final seen = ref.watch(volumeNoticeSeenProvider);
    if (!_shown && seen.hasValue && seen.value == false) {
      _shown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _show());
    }
    return widget.child;
  }

  Future<void> _show() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'No volume here – on purpose',
              style: Theme.of(ctx).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const NoVolumeNotice(),
            const SizedBox(height: 8),
            Text(
              'Ol1nPlay never touches the samples: no software volume, no '
              'EQ, no resampling. Set the level on your DAC or amplifier.',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Got it'),
              ),
            ),
          ],
        ),
      ),
    );
    await ref.read(engineStoreProvider).setFlag('volumeNoticeSeen', true);
    ref.invalidate(volumeNoticeSeenProvider);
  }
}
