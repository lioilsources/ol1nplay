import 'package:flutter/material.dart';

import '../protocol/library_models.dart';
import '../theme/theme.dart';
import 'fmt.dart';
import 'format_badge.dart';

/// One row in a track list: number, title, artist, duration, format chip,
/// favorite heart, now-playing indicator.
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    this.nowPlaying = false,
    this.playing = false,
    this.selected = false,
    this.showArtist = true,
    this.showNumber = true,
    this.showFormat = true,
    this.onTap,
    this.onDoubleTap,
    this.onFavorite,
    this.onSecondaryTap,
    this.trailing,
    this.dense = false,
  });

  final Track track;

  /// This is the current track.
  final bool nowPlaying;

  /// ...and it is actually playing (vs paused).
  final bool playing;
  final bool selected;
  final bool showArtist;
  final bool showNumber;
  final bool showFormat;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final ValueChanged<bool>? onFavorite;
  final VoidCallback? onSecondaryTap;
  final Widget? trailing;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleColor = nowPlaying ? scheme.primary : scheme.onSurface;
    final mono = Ol1nTheme.mono(
      context,
      size: dense ? 11 : 12,
      color: scheme.onSurfaceVariant,
    );

    Widget leading;
    if (nowPlaying) {
      leading = Icon(
        playing ? Icons.volume_up_rounded : Icons.pause_rounded,
        size: 18,
        color: scheme.primary,
      );
    } else if (showNumber && track.trackNo > 0) {
      leading = Text(
        '${track.trackNo}',
        style: mono,
        textAlign: TextAlign.right,
      );
    } else {
      leading = const SizedBox.shrink();
    }

    return GestureDetector(
      onDoubleTap: onDoubleTap,
      onSecondaryTap: onSecondaryTap,
      child: ListTile(
        dense: dense,
        selected: selected || nowPlaying,
        onTap: onTap,
        contentPadding: EdgeInsets.symmetric(horizontal: dense ? 8 : 12),
        minLeadingWidth: 28,
        leading: SizedBox(width: 28, child: Center(child: leading)),
        title: Text(
          track.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: titleColor,
            fontWeight: nowPlaying ? FontWeight.w600 : null,
          ),
        ),
        subtitle: showArtist && track.displayArtist.isNotEmpty
            ? Text(
                track.displayArtist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showFormat) ...[
              FormatChip(track: track),
              const SizedBox(width: 8),
            ],
            Text(fmtDuration(track.durationMs), style: mono),
            if (onFavorite != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: track.favorite ? 'Unfavorite' : 'Favorite',
                icon: Icon(
                  track.favorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  size: 18,
                  color: track.favorite
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                onPressed: () => onFavorite!(!track.favorite),
              ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
