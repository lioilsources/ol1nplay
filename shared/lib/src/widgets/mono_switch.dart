import 'package:flutter/material.dart';

import '../protocol/state_models.dart';

/// Mono · L · R: three independent toggles. Mono is the (L+R)/2 downmix; L
/// and R play one speaker only and mute the other. Together they put the
/// same signal in either speaker, so the two sides of a system can be
/// compared; L or R alone plays that channel's own signal.
class MonoModeSwitch extends StatelessWidget {
  const MonoModeSwitch({
    super.key,
    required this.mode,
    required this.onChanged,
    this.large = false,
  });

  final String mode;
  final ValueChanged<String>? onChanged;

  /// Finger-sized buttons for the remote, where the switch is flipped
  /// while listening rather than while looking.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final mono = MonoMode.isMono(mode);
    final side = MonoMode.side(mode);
    void set({bool? m, String? s}) =>
        onChanged?.call(MonoMode.of(mono: m ?? mono, side: s ?? side));

    Widget button(
      String key,
      String label,
      String tip,
      bool on,
      VoidCallback tap,
    ) {
      final scheme = Theme.of(context).colorScheme;
      return Tooltip(
        message: tip,
        child: Padding(
          padding: EdgeInsets.only(left: large ? 8 : 4),
          child: OutlinedButton(
            key: ValueKey(key),
            onPressed: onChanged == null ? null : tap,
            style: OutlinedButton.styleFrom(
              backgroundColor: on ? scheme.primary : null,
              foregroundColor: on ? scheme.onPrimary : scheme.onSurface,
              side: BorderSide(color: on ? scheme.primary : scheme.outline),
              minimumSize: large ? const Size(64, 52) : const Size(36, 30),
              padding: EdgeInsets.symmetric(horizontal: large ? 18 : 10),
              tapTargetSize: large
                  ? MaterialTapTargetSize.padded
                  : MaterialTapTargetSize.shrinkWrap,
              visualDensity: large
                  ? VisualDensity.standard
                  : VisualDensity.compact,
              textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontSize: large ? 15 : 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Text(label),
          ),
        ),
      );
    }

    return Row(
      key: const ValueKey('monoSwitch'),
      mainAxisSize: MainAxisSize.min,
      children: [
        button(
          'monoToggle',
          'Mono',
          mono ? 'Mono downmix on — back to stereo' : 'Mono downmix (L+R)/2',
          mono,
          () => set(m: !mono),
        ),
        button(
          'onlyL',
          'L',
          side == 'L'
              ? 'Left speaker only — back to both'
              : 'Left speaker only, right muted',
          side == 'L',
          () => set(s: side == 'L' ? '' : 'L'),
        ),
        button(
          'onlyR',
          'R',
          side == 'R'
              ? 'Right speaker only — back to both'
              : 'Right speaker only, left muted',
          side == 'R',
          () => set(s: side == 'R' ? '' : 'R'),
        ),
      ],
    );
  }
}
