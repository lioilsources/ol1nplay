import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import 'providers.dart';

/// Keyboard intents. Bound once at the shell; text fields swallow what
/// they need because [Shortcuts] only fires for unhandled keys.
class PlayPauseIntent extends Intent {
  const PlayPauseIntent();
}

class SeekIntent extends Intent {
  const SeekIntent(this.deltaMs);
  final int deltaMs;
}

class NudgeABIntent extends Intent {
  const NudgeABIntent(this.deltaMs);
  final int deltaMs;
}

class SetAIntent extends Intent {
  const SetAIntent();
}

class SetBIntent extends Intent {
  const SetBIntent();
}

class ClearABIntent extends Intent {
  const ClearABIntent();
}

class MonoIntent extends Intent {
  const MonoIntent();
}

class NextIntent extends Intent {
  const NextIntent();
}

class PrevIntent extends Intent {
  const PrevIntent();
}

class SearchIntent extends Intent {
  const SearchIntent();
}

class FullscreenIntent extends Intent {
  const FullscreenIntent();
}

class EscapeIntent extends Intent {
  const EscapeIntent();
}

const appShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.space): PlayPauseIntent(),
  SingleActivator(LogicalKeyboardKey.arrowLeft): SeekIntent(-5000),
  SingleActivator(LogicalKeyboardKey.arrowRight): SeekIntent(5000),
  SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): NudgeABIntent(
    -10,
  ),
  SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): NudgeABIntent(
    10,
  ),
  SingleActivator(LogicalKeyboardKey.bracketLeft): SetAIntent(),
  SingleActivator(LogicalKeyboardKey.bracketRight): SetBIntent(),
  SingleActivator(LogicalKeyboardKey.backslash): ClearABIntent(),
  SingleActivator(LogicalKeyboardKey.keyM): MonoIntent(),
  SingleActivator(LogicalKeyboardKey.keyN): NextIntent(),
  SingleActivator(LogicalKeyboardKey.keyP): PrevIntent(),
  SingleActivator(LogicalKeyboardKey.keyF, control: true): SearchIntent(),
  SingleActivator(LogicalKeyboardKey.keyF, meta: true): SearchIntent(),
  SingleActivator(LogicalKeyboardKey.f11): FullscreenIntent(),
  SingleActivator(LogicalKeyboardKey.escape): EscapeIntent(),
};

/// Builds the action map against the live client.
Map<Type, Action<Intent>> appActions(WidgetRef ref, FocusNode searchFocus) {
  final c = ref.read(clientProvider);
  return {
    PlayPauseIntent: CallbackAction<PlayPauseIntent>(
      onInvoke: (_) => c.toggle(),
    ),
    SeekIntent: CallbackAction<SeekIntent>(
      onInvoke: (i) {
        final s = ref.read(stateProvider);
        if (!s.hasTrack) return null;
        final to = (s.positionMs + i.deltaMs).clamp(
          0,
          s.durationMs > 0 ? s.durationMs : 1 << 40,
        );
        return c.seekMs(to);
      },
    ),
    NudgeABIntent: CallbackAction<NudgeABIntent>(
      onInvoke: (i) {
        final which = ref.read(abFocusProvider);
        if (which == null) return null;
        return c.abNudge(which, i.deltaMs);
      },
    ),
    SetAIntent: CallbackAction<SetAIntent>(
      onInvoke: (_) {
        ref.read(abFocusProvider.notifier).set('a');
        return c.abSetA();
      },
    ),
    SetBIntent: CallbackAction<SetBIntent>(
      onInvoke: (_) {
        ref.read(abFocusProvider.notifier).set('b');
        return c.abSetB();
      },
    ),
    ClearABIntent: CallbackAction<ClearABIntent>(
      onInvoke: (_) {
        ref.read(abFocusProvider.notifier).set(null);
        return c.abClear();
      },
    ),
    MonoIntent: CallbackAction<MonoIntent>(
      // Stereo → Mono → L → R → Stereo.
      onInvoke: (_) {
        final i = MonoMode.all.indexOf(ref.read(stateProvider).monoMode);
        return c.setMonoMode(MonoMode.all[(i + 1) % MonoMode.all.length]);
      },
    ),
    NextIntent: CallbackAction<NextIntent>(onInvoke: (_) => c.next()),
    PrevIntent: CallbackAction<PrevIntent>(onInvoke: (_) => c.prev()),
    SearchIntent: CallbackAction<SearchIntent>(
      onInvoke: (_) {
        searchFocus.requestFocus();
        return null;
      },
    ),
    FullscreenIntent: CallbackAction<FullscreenIntent>(
      onInvoke: (_) {
        ref.read(fullscreenNowPlayingProvider.notifier).toggle();
        return null;
      },
    ),
    EscapeIntent: CallbackAction<EscapeIntent>(
      onInvoke: (_) {
        if (ref.read(fullscreenNowPlayingProvider)) {
          ref.read(fullscreenNowPlayingProvider.notifier).set(false);
        } else if (ref.read(searchQueryProvider).isNotEmpty) {
          ref.read(searchQueryProvider.notifier).clear();
        } else {
          ref.read(selectionProvider.notifier).clear();
        }
        return null;
      },
    ),
  };
}
