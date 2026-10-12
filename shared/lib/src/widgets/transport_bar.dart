import 'package:flutter/material.dart';

import '../protocol/commands.dart';
import '../protocol/state_models.dart';

/// prev · play/pause · next · stop, plus mono / repeat / shuffle toggles.
/// Pure callbacks; wire them to an [EngineClient] in the app.
class TransportBar extends StatelessWidget {
  const TransportBar({
    super.key,
    required this.state,
    this.onPrev,
    this.onToggle,
    this.onNext,
    this.onStop,
    this.onMono,
    this.onRepeat,
    this.onShuffle,
    this.iconSize = 24,
    this.playSize = 40,
    this.showToggles = true,
    this.showMono = true,
  });

  /// False where a [MonoModeSwitch] sits next to the bar instead.
  final bool showMono;

  final EngineState state;
  final VoidCallback? onPrev;
  final VoidCallback? onToggle;
  final VoidCallback? onNext;
  final VoidCallback? onStop;
  final ValueChanged<bool>? onMono;
  final ValueChanged<String>? onRepeat;
  final ValueChanged<bool>? onShuffle;
  final double iconSize;
  final double playSize;
  final bool showToggles;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasTrack = state.hasTrack;
    final playIcon = state.isPlaying
        ? Icons.pause_rounded
        : state.isLoading
        ? Icons.hourglass_top_rounded
        : Icons.play_arrow_rounded;

    final repeatIcon = switch (state.repeat) {
      Repeat.one => Icons.repeat_one_rounded,
      _ => Icons.repeat_rounded,
    };
    final repeatOn = state.repeat != Repeat.off;

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (showToggles)
          IconButton(
            tooltip: 'Shuffle',
            iconSize: iconSize,
            isSelected: state.shuffle,
            color: state.shuffle ? scheme.primary : null,
            icon: const Icon(Icons.shuffle_rounded),
            onPressed: onShuffle == null
                ? null
                : () => onShuffle!(!state.shuffle),
          ),
        IconButton(
          tooltip: 'Previous',
          iconSize: iconSize,
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: hasTrack ? onPrev : null,
        ),
        IconButton.filled(
          tooltip: state.isPlaying ? 'Pause' : 'Play',
          iconSize: playSize,
          icon: Icon(playIcon),
          onPressed: hasTrack ? onToggle : null,
        ),
        IconButton(
          tooltip: 'Next',
          iconSize: iconSize,
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: hasTrack ? onNext : null,
        ),
        IconButton(
          tooltip: 'Stop',
          iconSize: iconSize,
          icon: const Icon(Icons.stop_rounded),
          onPressed: state.isStopped ? null : onStop,
        ),
        if (showToggles) ...[
          IconButton(
            tooltip: 'Repeat: ${state.repeat}',
            iconSize: iconSize,
            isSelected: repeatOn,
            color: repeatOn ? scheme.primary : null,
            icon: Icon(repeatIcon),
            onPressed: onRepeat == null
                ? null
                : () => onRepeat!(Repeat.nextOf(state.repeat)),
          ),
          if (showMono)
            MonoToggle(mono: state.mono, onChanged: onMono, iconSize: iconSize),
        ],
      ],
    );
  }
}

/// The only DSP there is: "M" button for (L+R)/2.
class MonoToggle extends StatelessWidget {
  const MonoToggle({
    super.key,
    required this.mono,
    this.onChanged,
    this.iconSize = 24,
  });

  final bool mono;
  final ValueChanged<bool>? onChanged;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: mono ? 'Mono (L+R)/2 – on' : 'Mono – off',
      iconSize: iconSize,
      isSelected: mono,
      color: mono ? scheme.primary : null,
      icon: Text(
        'M',
        style: TextStyle(
          fontSize: iconSize * 0.7,
          fontWeight: FontWeight.w800,
          color: mono ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
      onPressed: onChanged == null ? null : () => onChanged!(!mono),
    );
  }
}
