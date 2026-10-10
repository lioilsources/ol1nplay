import 'package:flutter/material.dart';

import '../protocol/state_models.dart';
import '../theme/theme.dart';
import 'fmt.dart';

/// Position bar driven by the device clock, with the A and B loop points
/// drawn as markers. Dragging emits the target in milliseconds once, on
/// release — the engine flushes its ring on every seek, so we don't spam it.
class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.state,
    this.onSeekMs,
    this.showTimes = true,
    this.height = 28,
  });

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
  });

  final double fraction;
  final double? aX;
  final double? bX;
  final bool loopActive;
  final Color track;
  final Color fill;
  final Color marker;
  final bool thumb;

  @override
  void paint(Canvas canvas, Size size) {
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
      o.thumb != thumb;
}
