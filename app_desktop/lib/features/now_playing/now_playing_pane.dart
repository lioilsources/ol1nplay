import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/actions.dart';
import '../../core/providers.dart';

/// Right pane: cover, titles, format path, seek bar with A/B, transport,
/// A-B controls, technical readout. [fullscreen] drops the tech block in
/// favour of a big cover.
class NowPlayingPane extends ConsumerWidget {
  const NowPlayingPane({super.key, this.fullscreen = false});

  final bool fullscreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stateProvider);
    final client = ref.watch(clientProvider);
    final a = ref.read(actionsProvider);
    final scheme = Theme.of(context).colorScheme;
    final t = s.track;
    final abFocus = ref.watch(abFocusProvider);
    final stats = ref.watch(outputStatsProvider).value;

    return LayoutBuilder(
      builder: (context, box) {
        final coverSize = fullscreen
            ? (box.maxHeight * 0.55).clamp(200.0, 900.0)
            : (box.maxWidth - 32).clamp(120.0, 420.0);
        return Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: SizedBox(
                        width: coverSize,
                        height: coverSize,
                        child: GestureDetector(
                          onDoubleTap: () => ref
                              .read(fullscreenNowPlayingProvider.notifier)
                              .toggle(),
                          child: CoverImage(
                            hash: t?.cover ?? '',
                            client: client,
                            borderRadius: 10,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      t?.displayTitle ?? 'Nothing playing',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: fullscreen ? 26 : 17,
                        fontWeight: FontWeight.w700,
                        color: t == null
                            ? scheme.onSurfaceVariant
                            : scheme.onSurface,
                      ),
                    ),
                    if (t != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        [
                          t.displayArtist,
                          t.album,
                        ].where((x) => x.isNotEmpty).join(' — '),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: fullscreen ? 16 : 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Center(child: FormatBadge(state: s)),
                    // The shell has its own full-width seek strip; only the
                    // fullscreen view needs one here.
                    if (fullscreen) ...[
                      const SizedBox(height: 10),
                      SeekBar(
                        state: s,
                        onSeekMs: (ms) => client.seekMs(ms),
                        waveform: ref.watch(waveformProvider).value,
                        height: 56,
                      ),
                    ],
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: TransportBar(
                        state: s,
                        onPrev: client.prev,
                        onToggle: client.toggle,
                        onNext: client.next,
                        onStop: client.stop,
                        showMono: false,
                        onRepeat: client.setRepeat,
                        onShuffle: client.setShuffle,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 8,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: abFocus != null
                              ? scheme.primary.withValues(alpha: 0.5)
                              : scheme.outline,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'A-B LOOP',
                                style: Ol1nTheme.mono(
                                  context,
                                  size: 10,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              const Spacer(),
                              if (abFocus != null)
                                Text(
                                  '⇧←/→ nudges ${abFocus.toUpperCase()}',
                                  style: Ol1nTheme.mono(
                                    context,
                                    size: 10,
                                    color: scheme.primary,
                                  ),
                                ),
                            ],
                          ),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: ABControls(
                              ab: s.ab,
                              dense: true,
                              onSetA: () {
                                ref.read(abFocusProvider.notifier).set('a');
                                a.guard(context, client.abSetA);
                              },
                              onSetB: () {
                                ref.read(abFocusProvider.notifier).set('b');
                                a.guard(context, client.abSetB);
                              },
                              onNudge: (w, ms) {
                                ref.read(abFocusProvider.notifier).set(w);
                                a.guard(context, () => client.abNudge(w, ms));
                              },
                              onToggle: (on) =>
                                  a.guard(context, () => client.abToggle(on)),
                              onClear: () {
                                ref.read(abFocusProvider.notifier).set(null);
                                a.guard(context, client.abClear);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!fullscreen) ...[
                      const SizedBox(height: 12),
                      TechInfo(state: s, stats: stats),
                      const SizedBox(height: 6),
                      _Extras(state: s, stats: stats),
                    ],
                    const SizedBox(height: 8),
                    const NoVolumeNotice(compact: true),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The readouts TechInfo does not carry: preload, RAM, thread, ring fill,
/// underrun indicator, sleep timer.
class _Extras extends ConsumerWidget {
  const _Extras({required this.state, this.stats});
  final EngineState state;
  final OutputStats? stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final dim = Ol1nTheme.mono(
      context,
      size: 11,
      color: scheme.onSurfaceVariant,
    );
    final val = Ol1nTheme.mono(context, size: 11);
    Widget row(String k, Widget v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(width: 110, child: Text(k, style: dim)),
          Expanded(child: v),
        ],
      ),
    );
    final next = state.nextTrack;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(
          'underruns',
          Row(
            children: [
              Text('${state.output.underruns}', style: val),
              const SizedBox(width: 6),
              UnderrunIndicator(underruns: state.output.underruns),
            ],
          ),
        ),
        if (stats != null) ...[
          row(
            'ring fill',
            Text('${stats!.ringFillPct.toStringAsFixed(0)} %', style: val),
          ),
          row('callback max', Text('${stats!.maxCallbackUs} µs', style: val)),
          row(
            'audio thread',
            Text(
              '${stats!.threadPriority}${stats!.cpuCore >= 0 ? ' · core ${stats!.cpuCore}' : ''}',
              style: val,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        row('RAM resident', Text(fmtBytes(state.ramBytes), style: val)),
        row(
          'next',
          Text(
            next == null
                ? '–'
                : '${next.displayTitle}${state.preloaded ? '  ✓ in RAM' : '  (decoding…)'}',
            style: val.copyWith(
              color: state.preloaded ? Ol1nTheme.bitPerfectGreen : null,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (state.sleep != null)
          row(
            'sleep',
            Text('${state.sleep!.remaining.inMinutes} min left', style: val),
          ),
      ],
    );
  }
}
