import 'package:flutter/material.dart';

import '../protocol/state_models.dart';

/// Stereo · Mono · L · R. The last two send the mono downmix to one speaker
/// only, so the two sides of a system can be compared on the same signal.
class MonoModeSwitch extends StatelessWidget {
  const MonoModeSwitch({
    super.key,
    required this.mode,
    required this.onChanged,
    this.large = false,
  });

  final String mode;
  final ValueChanged<String>? onChanged;

  /// Finger-sized segments for the remote, where the switch is flipped
  /// while listening rather than while looking.
  final bool large;

  static const _labels = {
    MonoMode.stereo: 'Stereo',
    MonoMode.mono: 'Mono',
    MonoMode.left: 'L',
    MonoMode.right: 'R',
  };

  static const _tooltips = {
    MonoMode.stereo: 'Stereo (untouched)',
    MonoMode.mono: 'Mono downmix in both speakers',
    MonoMode.left: 'Mono downmix, left speaker only',
    MonoMode.right: 'Mono downmix, right speaker only',
  };

  @override
  Widget build(BuildContext context) {
    final selected = MonoMode.all.contains(mode) ? mode : MonoMode.stereo;
    return SegmentedButton<String>(
      key: const ValueKey('monoSwitch'),
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: large ? VisualDensity.standard : VisualDensity.compact,
        tapTargetSize: large
            ? MaterialTapTargetSize.padded
            : MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(
            horizontal: large ? 18 : 8,
            vertical: large ? 14 : 0,
          ),
        ),
        textStyle: WidgetStatePropertyAll(
          Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: large ? 15 : 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      segments: [
        for (final m in MonoMode.all)
          ButtonSegment(
            value: m,
            label: Text(_labels[m]!),
            tooltip: _tooltips[m],
          ),
      ],
      selected: {selected},
      onSelectionChanged: onChanged == null ? null : (v) => onChanged!(v.first),
    );
  }
}
