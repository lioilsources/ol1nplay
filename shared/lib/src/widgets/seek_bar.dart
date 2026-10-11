import 'package:flutter/material.dart';

import '../protocol/state_models.dart';
import '../theme/theme.dart';
import 'fmt.dart';

/// Position bar driven by the device clock, with the A and B loop points
/// drawn as markers. Dragging emits the target in milliseconds once, on
/// release — the engine flushes its ring on every seek, so we don't spam it.
///
/// With a [waveform] the bar is the track's loudness drawn end to end, so a
/// quiet intro or the loud part is something you can aim at; without one
/// it is a thin line.
class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.state,
    this.onSeekMs,
    this.showTimes = true,
    this.height = 28,
    this.waveform,
  });

  /// Drawn only when it belongs to the playing track.
  final Waveform? waveform;

  final EngineState state;
  final ValueChanged<int>? onSeekMs;
  final bool showTimes;
  final double height;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _drag; // 0..1 while dragging

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final scheme = Theme.of(context).colorScheme;
    final dur = s.durationMs;
    final frac = _drag ?? s.progress;
    final shownMs = _drag == null ? s.positionMs : (_drag! * dur).round();
    final enabled = widget.onSeekMs != null && s.hasTrack && dur > 0;
    final wf = widget.waveform;
    final wave = wf != null && !wf.isEmpty && wf.path == s.track?.path
        ? wf
        : null;

    final bar = LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        double x(int ms) => dur <= 0 ? 0 : (ms / dur).clamp(0, 1) * w;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (d) => _commit(d.localPosition.dx / w) : null,
          onHorizontalDragStart: enabled
              ? (d) =>
                    setState(() => _drag = (d.localPosition.dx / w).clamp(0, 1))
              : null,
          onHorizontalDragUpdate: enabled
              ? (d) =>
                    setState(() => _drag = (d.localPosition.dx / w).clamp(0, 1))
              : null,
          onHorizontalDragEnd: enabled ? (_) => _commit(_drag ?? frac) : null,
          onHorizontalDragCancel: () => setState(() => _drag = null),
          child: SizedBox(
            height: widget.height,
            child: CustomPaint(
              painter: _SeekPainter(
                fraction: frac,
                aX: s.ab.hasA ? x(s.ab.aMs) : null,
                bX: s.ab.hasB ? x(s.ab.bMs) : null,
                loopActive: s.ab.active,
                track: scheme.outline,
                fill: scheme.primary,
                marker: s.ab.active
                    ? Ol1nTheme.bitPerfectGreen
                    : scheme.onSurfaceVariant,
                thumb: enabled,
                wave: wave,
                waveRest: scheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      },
    );

    if (!widget.showTimes) return bar;
    final mono = Ol1nTheme.mono(
      context,
      size: 11,
      color: scheme.onSurfaceVariant,
    );
    return Row(
      children: [
        SizedBox(width: 52, child: Text(fmtDuration(shownMs), style: mono)),
        Expanded(child: bar),
        SizedBox(
          width: 52,
          child: Text(
            fmtDuration(dur),
            style: mono,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  void _commit(double f) {
    final ms = (f.clamp(0, 1) * widget.state.durationMs).round();
    setState(() => _drag = null);
    widget.onSeekMs?.call(ms);
  }
}

class _SeekPainter extends CustomPainter {
  _SeekPainter({
    required this.fraction,
    required this.aX,
    required this.bX,
    required this.loopActive,
    required this.track,
    required this.fill,
    required this.marker,
    required this.thumb,
    this.wave,
    required this.waveRest,
  });

  final Waveform? wave;
  final Color waveRest;

  final double fraction;
  final double? aX;
  final double? bX;
  final bool loopActive;
  final Color track;
  final Color fill;
  final Color marker;
  final bool thumb;

  /// Mirrored bars: the peak faint, the RMS solid on top; amber up to the
  /// play position, grey after it.
  void _paintWave(Canvas canvas, Size size, Waveform w) {
    final cy = size.height / 2;
    final fx = size.width * fraction.clamp(0, 1);
    const pitch = 3.0; // 2 px bar + 1 px gap
    final n = (size.width / pitch).floor();
    if (n <= 0) return;
    final half = size.height / 2 - 1;
    final paint = Paint();
    for (var i = 0; i < n; i++) {
      // Each bar shows the loudest of the bins it covers.
      final from = i * w.bins ~/ n;
      final to = ((i + 1) * w.bins ~/ n).clamp(from + 1, w.bins);
      var pk = 0, rm = 0;
      for (var b = from; b < to; b++) {
        if (w.peak[b] > pk) pk = w.peak[b];
        if (w.rms[b] > rm) rm = w.rms[b];
      }
      final x = i * pitch;
      final base = x + 1 <= fx ? fill : waveRest;
      final ph = (pk / 255 * half).clamp(1.0, half);
      final rh = (rm / 255 * half).clamp(1.0, half);
      paint.color = base.withValues(alpha: 0.35);
      canvas.drawRect(Rect.fromLTRB(x, cy - ph, x + 2, cy + ph), paint);
      paint.color = base.withValues(alpha: x + 1 <= fx ? 1 : 0.7);
      canvas.drawRect(Rect.fromLTRB(x, cy - rh, x + 2, cy + rh), paint);
    }
  }

  void _paintWaveOverlay(Canvas canvas, Size size) {
    final fx = size.width * fraction.clamp(0, 1);
    if (aX != null && bX != null && bX! > aX!) {
      canvas.drawRect(
        Rect.fromLTWH(aX!, 0, bX! - aX!, size.height),
        Paint()..color = marker.withValues(alpha: loopActive ? 0.18 : 0.08),
      );
    }
    final mp = Paint()
      ..color = marker
      ..strokeWidth = 2;
    for (final (x, label) in [(aX, 'A'), (bX, 'B')]) {
      if (x == null) continue;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), mp);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: marker,
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 3, 0));
    }
    if (thumb) {
      canvas.drawRect(
        Rect.fromLTWH(fx - 1, 0, 2, size.height),
        Paint()..color = fill,
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = wave;
    if (w != null && size.height >= 16) {
      _paintWave(canvas, size, w);
      _paintWaveOverlay(canvas, size);
      return;
    }
    final cy = size.height / 2;
    const h = 3.0;
    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, cy - h / 2, size.width, h),
      const Radius.circular(2),
    );
    canvas.drawRRect(r, Paint()..color = track);
    if (aX != null && bX != null && bX! > aX!) {
      canvas.drawRect(
        Rect.fromLTWH(aX!, cy - h * 2, bX! - aX!, h * 4),
        Paint()..color = marker.withValues(alpha: loopActive ? 0.25 : 0.12),
      );
    }
    final fx = size.width * fraction.clamp(0, 1);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, cy - h / 2, fx, h),
        const Radius.circular(2),
      ),
      Paint()..color = fill,
    );
    final mp = Paint()
      ..color = marker
      ..strokeWidth = 2;
    for (final (x, label) in [(aX, 'A'), (bX, 'B')]) {
      if (x == null) continue;
      canvas.drawLine(Offset(x, cy - 9), Offset(x, cy + 9), mp);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: marker,
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 3, cy - 14));
    }
    if (thumb) {
      canvas.drawCircle(Offset(fx, cy), 6, Paint()..color = fill);
    }
  }

  @override
  bool shouldRepaint(_SeekPainter o) =>
      o.fraction != fraction ||
      o.aX != aX ||
      o.bX != bX ||
      o.loopActive != loopActive ||
      o.thumb != thumb ||
      o.wave != wave ||
      o.fill != fill ||
      o.waveRest != waveRest;
}
