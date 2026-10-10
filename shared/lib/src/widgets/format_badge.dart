import 'package:flutter/material.dart';

import '../protocol/commands.dart';
import '../protocol/library_models.dart';
import '../protocol/state_models.dart';
import '../theme/theme.dart';

/// "FLAC 24/96 → ASIO 32-bit · bit-perfect" with a status dot:
/// green = bit-perfect, amber = converted, grey = output closed, red = error.
class FormatBadge extends StatelessWidget {
  const FormatBadge({super.key, required this.state, this.compact = false});

  final EngineState state;

  /// Single line, no conversion note.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final out = state.output;
    final src = state.source;
    final track = state.track;

    final Color dot;
    final String status;
    if (out.hasError) {
      dot = Ol1nTheme.errorRed;
      status = 'error';
    } else if (out.status == OutputStatus.closed || track == null) {
      dot = Theme.of(context).colorScheme.outline;
      status = 'idle';
    } else if (out.bitPerfect) {
      dot = Ol1nTheme.bitPerfectGreen;
      status = 'bit-perfect';
    } else {
      dot = Ol1nTheme.warnAmber;
      status = 'converted';
    }

    final srcLabel = track == null ? '' : _sourceLabel(track, src);
    final outLabel = out.status == OutputStatus.closed ? '' : _outputLabel(out);
    final text = [
      if (srcLabel.isNotEmpty) srcLabel,
      if (outLabel.isNotEmpty) '→ $outLabel',
      '· $status',
    ].join(' ');

    final line = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: Ol1nTheme.mono(context, size: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    if (compact || (out.conversion.isEmpty && out.error.isEmpty)) return line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        line,
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Text(
            out.error.isNotEmpty ? out.error : out.conversion,
            style: Ol1nTheme.mono(
              context,
              size: 11,
              color: out.error.isNotEmpty
                  ? Ol1nTheme.errorRed
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  static String _sourceLabel(Track t, Format src) {
    if (src.isEmpty) return t.formatBadge;
    return '${t.codecLabel} ${src.short}';
  }

  static String _outputLabel(Output o) {
    final f = o.format;
    final bits = f.isDsd
        ? (o.nativeDsd ? 'native DSD' : 'DoP')
        : '${f.bitDepth}-bit';
    return '${o.backendLabel} $bits';
  }
}

/// Small chip for a track list: "FLAC 24/96".
class FormatChip extends StatelessWidget {
  const FormatChip({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        track.formatBadge,
        style: Ol1nTheme.mono(
          context,
          size: 10,
          color: track.lossless || track.dsd
              ? scheme.onSurface
              : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
