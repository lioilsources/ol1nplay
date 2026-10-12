import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/actions.dart';
import '../../core/providers.dart';
import 'folder_menu.dart';
import 'track_menu.dart';

/// Middle pane in folder mode: the selected directory's tracks (or search
/// results when a query is active). Virtualised; multi-select; double-click
/// plays the whole list from that track.
class TrackListPane extends ConsumerWidget {
  const TrackListPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(searchQueryProvider);
    if (query.isNotEmpty) {
      final results = ref.watch(searchResultsProvider);
      return results.when(
        loading: () => const _Loading(),
        error: (e, _) => _Error('$e'),
        data: (list) => TrackList(
          tracks: list ?? const [],
          header: _Header(
            icon: Icons.search,
            title: 'Search: $query',
            subtitle: '${list?.length ?? 0} tracks',
            onClose: () => ref.read(searchQueryProvider.notifier).clear(),
          ),
          showArtist: true,
          emptyLabel: 'Nothing matches "$query"',
        ),
      );
    }
    final dir = ref.watch(selectedDirProvider);
    if (dir.isEmpty) {
      return const _Empty('Select a folder on the left');
    }
    final listing = ref.watch(listingProvider(dir));
    final favOnly = ref.watch(favoritesOnlyProvider);
    return listing.when(
      loading: () => const _Loading(),
      error: (e, _) => _Error('$e'),
      data: (l) => TrackList(
        // Filtered here, so double-click plays just the hearts too.
        tracks: favOnly ? l.tracks.where((t) => t.favorite).toList() : l.tracks,
        header: _FolderHeader(listing: l),
        subdirs: favOnly ? const [] : l.dirs,
        emptyLabel: favOnly
            ? 'No favorites in this folder'
            : (l.dirs.isEmpty ? 'No audio files in this folder' : ''),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}

class _Error extends StatelessWidget {
  const _Error(this.msg);
  final String msg;
  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      msg,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.msg);
  final String msg;
  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      msg,
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onClose,
    this.leading,
    this.actions,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onClose;
  final Widget? leading;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outline)),
      ),
      child: Row(
        children: [
          leading ?? Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: Ol1nTheme.mono(
                      context,
                      size: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          ...?actions,
          ?onClose == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: onClose,
                  tooltip: 'Clear (Esc)',
                ),
        ],
      ),
    );
  }
}

class _FolderHeader extends ConsumerWidget {
  const _FolderHeader({required this.listing});
  final Listing listing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    final a = ref.read(actionsProvider);
    final favOnly = ref.watch(favoritesOnlyProvider);
    final first = listing.tracks.isEmpty ? null : listing.tracks.first;
    final album = first?.album ?? '';
    final artist = first?.albumArtist.isNotEmpty == true
        ? first!.albumArtist
        : (first?.artist ?? '');
    final parts = <String>[
      if (listing.tracks.isNotEmpty) '${listing.tracks.length} tracks',
      if (listing.tracks.isNotEmpty)
        fmtDuration(listing.totalDuration.inMilliseconds),
      if (listing.cue.isNotEmpty) '${listing.cue.length} CUE',
    ];
    return _Header(
      icon: Icons.folder_outlined,
      leading: CoverImage(
        hash: listing.cover,
        client: client,
        size: 36,
        thumb: true,
      ),
      title: album.isNotEmpty
          ? '$album${artist.isNotEmpty ? ' — $artist' : ''}'
          : baseName(listing.dir),
      subtitle: parts.isEmpty
          ? listing.dir
          : '${parts.join(' · ')}  ·  ${listing.dir}',
      actions: [
        if (favOnly || listing.tracks.any((t) => t.favorite))
          IconButton(
            key: const ValueKey('favoritesOnly'),
            tooltip: favOnly ? 'Show all tracks' : 'Show favorites only',
            isSelected: favOnly,
            icon: Icon(
              favOnly ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: 16,
              color: favOnly ? Theme.of(context).colorScheme.primary : null,
            ),
            onPressed: () => ref.read(favoritesOnlyProvider.notifier).toggle(),
          ),
        if (listing.parent.isNotEmpty)
          IconButton(
            tooltip: 'Up',
            icon: const Icon(Icons.arrow_upward, size: 16),
            onPressed: () =>
                ref.read(selectedDirProvider.notifier).select(listing.parent),
          ),
        IconButton(
          tooltip: 'Play folder',
          icon: const Icon(Icons.play_arrow, size: 18),
          onPressed: listing.tracks.isEmpty
              ? null
              : () => a.playDir(context, listing.dir),
        ),
        IconButton(
          tooltip: 'More',
          icon: const Icon(Icons.more_horiz, size: 18),
          onPressed: () {
            final box = context.findRenderObject() as RenderBox;
            final pos = box.localToGlobal(
              Offset(box.size.width - 40, box.size.height),
            );
            showFolderMenu(context, ref, listing.dir, pos);
          },
        ),
      ],
    );
  }
}

/// Reusable virtualised track list with selection and context menu.
class TrackList extends ConsumerWidget {
  const TrackList({
    super.key,
    required this.tracks,
    this.header,
    this.subdirs = const [],
    this.showArtist = false,
    this.emptyLabel = '',
    this.onPlayAt,
  });

  final List<Track> tracks;
  final Widget? header;
  final List<DirNode> subdirs;
  final bool showArtist;
  final String emptyLabel;

  /// Override for double-click (default: play the list from that index).
  final void Function(int index)? onPlayAt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final a = ref.read(actionsProvider);
    final nowPath = ref.watch(stateProvider.select((s) => s.track?.path));
    final playing = ref.watch(stateProvider.select((s) => s.isPlaying));
    final sel = ref.watch(selectionProvider);
    final client = ref.watch(clientProvider);
    final showAlbum = tracks.map((t) => t.album).toSet().length > 1;

    final count = subdirs.length + tracks.length;
    return Column(
      children: [
        ?header,
        Expanded(
          child: count == 0
              ? _Empty(emptyLabel)
              : ListView.builder(
                  itemCount: count,
                  itemExtent: 36,
                  itemBuilder: (context, i) {
                    if (i < subdirs.length) {
                      final d = subdirs[i];
                      return InkWell(
                        onTap: () => ref
                            .read(selectedDirProvider.notifier)
                            .select(d.path),
                        onDoubleTap: () => a.playDir(context, d.path),
                        onSecondaryTapDown: (e) => showFolderMenu(
                          context,
                          ref,
                          d.path,
                          e.globalPosition,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              if (d.cover.isNotEmpty)
                                CoverImage(
                                  hash: d.cover,
                                  client: client,
                                  size: 24,
                                  thumb: true,
                                  borderRadius: 3,
                                )
                              else
                                Icon(
                                  Icons.folder_outlined,
                                  size: 18,
                                  color: scheme.onSurfaceVariant,
                                ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  d.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (d.tracks > 0)
                                Text(
                                  '${d.tracks}',
                                  style: Ol1nTheme.mono(
                                    context,
                                    size: 11,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    }
                    final idx = i - subdirs.length;
                    final t = tracks[idx];
                    return TrackTile(
                      track: t,
                      dense: true,
                      nowPlaying: t.path == nowPath,
                      playing: playing,
                      selected: sel.contains(t.path),
                      showArtist: showArtist || showAlbum,
                      showNumber: !showArtist,
                      onTap: () {
                        final keys = HardwareKeyboard.instance;
                        ref
                            .read(selectionProvider.notifier)
                            .click(
                              tracks,
                              t,
                              ctrl: keys.isControlPressed || keys.isMetaPressed,
                              shift: keys.isShiftPressed,
                            );
                      },
                      onDoubleTap: () => onPlayAt != null
                          ? onPlayAt!(idx)
                          : a.playPaths(
                              context,
                              tracks.map((x) => x.path).toList(),
                              index: idx,
                            ),
                      onFavorite: (on) => a.favorite(context, t.path, on),
                      onSecondaryTap: () {
                        final box = context.findRenderObject() as RenderBox;
                        final pos = box.localToGlobal(Offset(80, 0));
                        final targets = sel.contains(t.path)
                            ? tracks.where((x) => sel.contains(x.path)).toList()
                            : [t];
                        if (!sel.contains(t.path)) {
                          ref.read(selectionProvider.notifier).click(tracks, t);
                        }
                        showTrackMenu(
                          context,
                          ref,
                          pos,
                          all: tracks,
                          clicked: t,
                          targets: targets,
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}
