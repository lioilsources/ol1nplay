import 'package:flutter/material.dart';

import '../protocol/state_models.dart';
import '../theme/theme.dart';
import 'fmt.dart';

/// Sample-accurate loop controls: set A, set B, ±10 ms nudges on each,
/// enable toggle, clear. Mirrors AIMP's A-B repeat.
class ABControls extends StatelessWidget {
  const ABControls({
    super.key,
    required this.ab,
    this.onSetA,
    this.onSetB,
    this.onNudge,
    this.onToggle,
    this.onClear,
    this.nudgeMs = 10,
    this.dense = false,
  });

  final ABLoop ab;
  final VoidCallback? onSetA;
  final VoidCallback? onSetB;

  /// (which: "a" | "b", deltaMs)
  final void Function(String which, int ms)? onNudge;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onClear;
  final int nudgeMs;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mono = Ol1nTheme.mono(context, size: dense ? 11 : 12);

    Widget point(String which, bool has, int ms, VoidCallback? onSet) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.tonal(
            onPressed: onSet,
            style: FilledButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 14),
              backgroundColor: has ? scheme.primaryContainer : null,
            ),
            child: Text(
              which.toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: '−$nudgeMs ms',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove, size: 16),
            onPressed: has && onNudge != null
                ? () => onNudge!(which, -nudgeMs)
                : null,
          ),
          SizedBox(
            width: dense ? 68 : 78,
            child: Text(
              has ? fmtDurationMs(ms) : '–',
              style: mono,
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            tooltip: '+$nudgeMs ms',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add, size: 16),
            onPressed: has && onNudge != null
                ? () => onNudge!(which, nudgeMs)
                : null,
          ),
        ],
      );
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: dense ? 4 : 10,
      runSpacing: 4,
      children: [
        point('a', ab.hasA, ab.aMs, onSetA),
        point('b', ab.hasB, ab.bMs, onSetB),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: ab.isSet
                  ? (ab.enabled ? 'Loop on' : 'Loop off')
                  : 'Set A and B first',
              child: Switch(
                value: ab.enabled && ab.isSet,
                onChanged: ab.isSet && onToggle != null ? onToggle : null,
              ),
            ),
            IconButton(
              tooltip: 'Clear A-B',
              icon: const Icon(Icons.close, size: 18),
              onPressed: ab.hasA || ab.hasB ? onClear : null,
            ),
          ],
        ),
      ],
    );
  }
}
