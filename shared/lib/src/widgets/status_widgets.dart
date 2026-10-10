import 'package:flutter/material.dart';

import '../protocol/state_models.dart';
import '../theme/theme.dart';

/// Underrun counter: hidden at zero, amber with the count otherwise, and
/// flashes red briefly when the count grows.
class UnderrunIndicator extends StatefulWidget {
  const UnderrunIndicator({
    super.key,
    required this.underruns,
    this.alwaysShow = false,
  });

  final int underruns;
  final bool alwaysShow;

  @override
  State<UnderrunIndicator> createState() => _UnderrunIndicatorState();
}

class _UnderrunIndicatorState extends State<UnderrunIndicator> {
  bool _flash = false;

  @override
  void didUpdateWidget(UnderrunIndicator old) {
    super.didUpdateWidget(old);
    if (widget.underruns > old.underruns) {
      setState(() => _flash = true);
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) setState(() => _flash = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.underruns == 0 && !widget.alwaysShow) {
      return const SizedBox.shrink();
    }
    final color = _flash
        ? Ol1nTheme.errorRed
        : widget.underruns == 0
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : Ol1nTheme.warnAmber;
    return Tooltip(
      message: 'Buffer underruns (zero-filled callbacks)',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            '${widget.underruns}',
            style: Ol1nTheme.mono(context, size: 12, color: color),
          ),
        ],
      ),
    );
  }
}

/// The one line about volume: there is none here.
class NoVolumeNotice extends StatelessWidget {
  const NoVolumeNotice({super.key, this.gain = '0 dB', this.compact = false});

  final String gain;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = compact
        ? 'Fixed $gain · set volume on your DAC / amp'
        : 'No software volume — output is fixed at $gain. Set the level on your DAC or amplifier.';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.volume_off_outlined,
          size: 14,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Small pill with the connection state, for app bars.
class ConnectionDot extends StatelessWidget {
  const ConnectionDot({super.key, required this.status, this.label});

  final ConnectionStatusLike status;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      ConnectionStatusLike.connected => Ol1nTheme.bitPerfectGreen,
      ConnectionStatusLike.connecting => Ol1nTheme.warnAmber,
      ConnectionStatusLike.disconnected => Ol1nTheme.errorRed,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        if (label != null) ...[
          const SizedBox(width: 6),
          Text(label!, style: Ol1nTheme.mono(context, size: 11)),
        ],
      ],
    );
  }
}

/// Three-way view of the client's connection status, so the widget does not
/// depend on the client package.
enum ConnectionStatusLike { connected, connecting, disconnected }

/// Technical readout block for a now-playing panel: source format, output
/// device + format, buffer, latency, RAM, underruns.
class TechInfo extends StatelessWidget {
  const TechInfo({super.key, required this.state, this.stats});

  final EngineState state;
  final OutputStats? stats;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final k = Ol1nTheme.mono(context, size: 11, color: scheme.onSurfaceVariant);
    final v = Ol1nTheme.mono(context, size: 11);
    final o = state.output;
    final t = state.track;
    final rows = <(String, String)>[
      if (t != null)
        (
          'source',
          '${t.codecLabel} ${state.source.short} · ${state.source.channels} ch',
        ),
      ('output', o.device.isEmpty ? '—' : '${o.backendLabel} · ${o.device}'),
      if (!o.format.isEmpty)
        (
          'device',
          '${o.format.short} · ${o.format.sampleFormat}${o.exclusive ? ' · exclusive' : ''}',
        ),
      if (o.bufferFrames > 0)
        (
          'buffer',
          '${o.bufferFrames} frames · ${o.latencyMs.toStringAsFixed(1)} ms',
        ),
      if (state.ramBytes > 0)
        (
          'ram',
          '${(state.ramBytes / (1 << 20)).toStringAsFixed(1)} MB${state.preloaded ? ' · next preloaded' : ''}',
        ),
      ('underruns', '${o.underruns}'),
      if (stats != null)
        (
          'thread',
          '${stats!.threadPriority}${stats!.cpuCore >= 0 ? ' · core ${stats!.cpuCore}' : ''}',
        ),
      if (stats != null)
        (
          'ring',
          '${stats!.ringFillPct.toStringAsFixed(0)} % · max cb ${stats!.maxCallbackUs} µs',
        ),
      ('gain', state.gain),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (key, val) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 72, child: Text(key, style: k)),
                Expanded(child: Text(val, style: v)),
              ],
            ),
          ),
      ],
    );
  }
}
