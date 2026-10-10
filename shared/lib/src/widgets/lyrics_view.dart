import 'package:flutter/material.dart';

import '../protocol/library_models.dart';

/// Lyrics panel. Timed (LRC) lyrics highlight the current line and keep it
/// centred as [positionMs] advances; plain text just scrolls.
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.lyrics,
    required this.positionMs,
    this.onSeekMs,
    this.lineHeight = 36,
    this.emptyLabel = 'No lyrics',
  });

  final Lyrics? lyrics;
  final int positionMs;

  /// Tap a timed line to jump there.
  final ValueChanged<int>? onSeekMs;
  final double lineHeight;
  final String emptyLabel;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final _ctl = ScrollController();
  int _active = -1;

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    final l = widget.lyrics;
    if (l == null || !l.isTimed) return;
    final idx = l.activeIndex(widget.positionMs);
    if (idx != _active) {
      _active = idx;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(idx));
    }
  }

  void _scrollTo(int idx) {
    if (!_ctl.hasClients || idx < 0) return;
    final viewport = _ctl.position.viewportDimension;
    final target =
        (idx * widget.lineHeight - viewport / 2 + widget.lineHeight / 2).clamp(
          0.0,
          _ctl.position.maxScrollExtent,
        );
    _ctl.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = widget.lyrics;
    if (l == null || l.isEmpty) {
      return Center(
        child: Text(
          widget.emptyLabel,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    if (!l.isTimed) {
      return SingleChildScrollView(
        controller: _ctl,
        padding: const EdgeInsets.all(16),
        child: Text(l.text, style: const TextStyle(height: 1.6)),
      );
    }
    final active = l.activeIndex(widget.positionMs);
    return ListView.builder(
      controller: _ctl,
      itemExtent: widget.lineHeight,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: l.lines.length,
      itemBuilder: (context, i) {
        final line = l.lines[i];
        final isActive = i == active;
        return InkWell(
          onTap: widget.onSeekMs == null
              ? null
              : () => widget.onSeekMs!(line.ms),
          child: Align(
            alignment: Alignment.centerLeft,
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(
                fontSize: isActive ? 18 : 15,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                color: isActive ? scheme.primary : scheme.onSurfaceVariant,
              ),
              child: Text(
                line.text.isEmpty ? '♪' : line.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      },
    );
  }
}
