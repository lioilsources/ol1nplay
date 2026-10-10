import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/providers.dart';
import '../queue/queue_screen.dart';

/// The big screen: cover on a blurred backdrop, titles, format path, seek
/// bar with A/B markers, transport, A-B controls, lyrics / tech tabs and a
/// swipe-up queue sheet. [embedded] is the tablet right pane (no app bar).
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key, this.embedded = false});
  final bool embedded;

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  int _tab = 0; // 0 controls · 1 lyrics · 2 tech

  @override
  void initState() {
    super.initState();
    // Keep the screen on while this is the front screen; a remote that
    // locks mid-album is useless. Plugins are absent in tests – ignore.
    WakelockPlus.enable().catchError((_) {});
  }

  @override
  void dispose() {
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(clientProvider);
    final s = ref.watch(engineStateProvider);
    final theme = Theme.of(context);
    if (s == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final t = s.track;
    final cover = t?.cover ?? '';

    final body = Stack(
      fit: StackFit.expand,
      children: [
        if (cover.isNotEmpty) _Backdrop(hash: cover, client: client),
        SafeArea(
          child: Column(
            children: [
              if (!widget.embedded)
                Row(
                  children: [
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                    _SleepButton(state: s),
                    IconButton(
                      tooltip: 'Queue',
                      icon: const Icon(Icons.queue_music),
                      onPressed: () => showQueueSheet(context),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              Expanded(
                child: _tab == 0
                    ? _CoverPane(state: s, client: client)
                    : _tab == 1
                    ? _LyricsPane(state: s)
                    : _TechPane(state: s),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t?.displayTitle ?? 'Nothing playing',
                      key: const Key('npTitle'),
                      style: theme.textTheme.titleLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (t != null)
                      Text(
                        [
                          t.displayArtist,
                          if (t.album.isNotEmpty) t.album,
                        ].join(' · '),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 8),
                    FormatBadge(state: s),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: SeekBar(state: s, onSeekMs: (ms) => client.seekMs(ms)),
              ),
              TransportBar(
                state: s,
                onPrev: () {
                  haptic();
                  client.prev();
                },
                onToggle: () {
                  haptic();
                  client.toggle();
                },
                onNext: () {
                  haptic();
                  client.next();
                },
                onStop: () => client.stop(),
                onMono: (v) => client.setMono(v),
                onRepeat: (m) => client.setRepeat(m),
                onShuffle: (v) => client.setShuffle(v),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: ABControls(
                  ab: s.ab,
                  dense: true,
                  onSetA: () => client.abSetA(),
                  onSetB: () => client.abSetB(),
                  onNudge: (which, ms) => client.abNudge(which, ms),
                  onToggle: (v) => client.abToggle(v),
                  onClear: () => client.abClear(),
                ),
              ),
              _PaneTabs(
                index: _tab,
                hasLyrics: t?.hasLyrics ?? false,
                onChanged: (i) => setState(() => _tab = i),
              ),
              if (widget.embedded)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextButton.icon(
                    onPressed: () => showQueueSheet(context),
                    icon: const Icon(Icons.queue_music, size: 18),
                    label: Text('Queue · ${s.queueIndex + 1}/${s.queueLen}'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    if (widget.embedded) return body;
    // Swipe up anywhere on the lower half opens the queue.
    return Scaffold(
      body: GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < -400) showQueueSheet(context);
        },
        child: body,
      ),
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.hash, required this.client});
  final String hash;
  final EngineClient client;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        CoverImage(
          hash: hash,
          client: client,
          borderRadius: 0,
          fit: BoxFit.cover,
        ),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: ColoredBox(
            color: Theme.of(
              context,
            ).colorScheme.surface.withValues(alpha: dark ? 0.78 : 0.86),
          ),
        ),
      ],
    );
  }
}

class _CoverPane extends StatelessWidget {
  const _CoverPane({required this.state, required this.client});
  final EngineState state;
  final EngineClient client;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final size = (c.maxWidth < c.maxHeight ? c.maxWidth : c.maxHeight) - 40;
        return Center(
          child: Stack(
            alignment: Alignment.bottomRight,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 30,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: CoverImage(
                  hash: state.track?.cover ?? '',
                  client: client,
                  size: size.clamp(120, 520),
                  borderRadius: 12,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: UnderrunIndicator(underruns: state.output.underruns),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LyricsPane extends ConsumerWidget {
  const _LyricsPane({required this.state});
  final EngineState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyrics = ref.watch(lyricsProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: lyrics.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (l) => LyricsView(
          lyrics: l,
          positionMs: state.positionMs,
          onSeekMs: (ms) => ref.read(clientProvider).seekMs(ms),
          emptyLabel: 'No lyrics for this track',
        ),
      ),
    );
  }
}

class _TechPane extends ConsumerWidget {
  const _TechPane({required this.state});
  final EngineState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(outputStatsProvider).value;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TechInfo(state: state, stats: stats),
          const SizedBox(height: 12),
          const NoVolumeNotice(compact: true),
        ],
      ),
    );
  }
}

class _PaneTabs extends StatelessWidget {
  const _PaneTabs({
    required this.index,
    required this.hasLyrics,
    required this.onChanged,
  });
  final int index;
  final bool hasLyrics;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SegmentedButton<int>(
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        segments: [
          const ButtonSegment(value: 0, icon: Icon(Icons.album, size: 18)),
          ButtonSegment(
            value: 1,
            icon: Icon(
              hasLyrics ? Icons.lyrics : Icons.lyrics_outlined,
              size: 18,
            ),
          ),
          const ButtonSegment(value: 2, icon: Icon(Icons.memory, size: 18)),
        ],
        selected: {index},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

class _SleepButton extends ConsumerWidget {
  const _SleepButton({required this.state});
  final EngineState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    final sleep = state.sleep;
    return PopupMenuButton<int>(
      tooltip: 'Sleep timer',
      icon: Icon(
        sleep == null ? Icons.bedtime_outlined : Icons.bedtime,
        color: sleep == null ? null : Ol1nTheme.accent,
      ),
      onSelected: (m) => m == 0 ? client.sleepClear() : client.sleepSet(m),
      itemBuilder: (_) => [
        if (sleep != null)
          PopupMenuItem(
            value: 0,
            child: Text('Off (${sleep.remaining.inMinutes} min left)'),
          ),
        for (final m in [15, 30, 45, 60, 90])
          PopupMenuItem(value: m, child: Text('$m minutes')),
      ],
    );
  }
}
