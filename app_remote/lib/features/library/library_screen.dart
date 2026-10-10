import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/providers.dart';
import 'extras_screens.dart';
import 'track_actions.dart';

/// Folder browser mirroring the file system 1:1, with breadcrumbs, a
/// search field that replaces the listing while typing, and shortcuts to
/// favorites / history / playlists.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  /// Path stack; empty = roots.
  final List<String> _stack = [];
  final _search = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(String dir) => setState(() => _stack.add(dir));

  bool _back() {
    if (_searching) {
      setState(() {
        _searching = false;
        _search.clear();
        ref.read(searchQueryProvider.notifier).set('');
      });
      return true;
    }
    if (_stack.isEmpty) return false;
    setState(_stack.removeLast);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final dir = _stack.isEmpty ? '' : _stack.last;
    return PopScope(
      canPop: _stack.isEmpty && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _stack.isEmpty && !_searching
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _back,
                ),
          title: _searching
              ? TextField(
                  key: const Key('searchField'),
                  controller: _search,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search title, artist, album…',
                    border: InputBorder.none,
                  ),
                  onChanged: (q) =>
                      ref.read(searchQueryProvider.notifier).set(q),
                )
              : _Breadcrumbs(
                  stack: _stack,
                  onJump: (i) =>
                      setState(() => _stack.removeRange(i + 1, _stack.length)),
                ),
          actions: [
            if (!_searching)
              IconButton(
                key: const Key('searchButton'),
                icon: const Icon(Icons.search),
                onPressed: () => setState(() => _searching = true),
              ),
            if (!_searching)
              PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'fav' => _push(const FavoritesScreen()),
                  'hist' => _push(const HistoryScreen()),
                  'pl' => _push(const PlaylistsScreen()),
                  'rescan' => ref.read(clientProvider).rescan(dir),
                  _ => null,
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'fav', child: Text('Favorites')),
                  PopupMenuItem(value: 'hist', child: Text('History')),
                  PopupMenuItem(value: 'pl', child: Text('Playlists')),
                  PopupMenuDivider(),
                  PopupMenuItem(value: 'rescan', child: Text('Rescan')),
                ],
              ),
          ],
        ),
        body: _searching
            ? const _SearchResults()
            : _stack.isEmpty
            ? const _RootsList()
            : _DirListing(dir: dir, onOpen: _open),
      ),
    );
  }

  void _push(Widget w) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.stack, required this.onJump});
  final List<String> stack;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    if (stack.isEmpty) return const Text('Library');
    final names = stack.map(_leaf).toList();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(
        children: [
          for (var i = 0; i < names.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.chevron_right, size: 16),
              ),
            InkWell(
              onTap: i == names.length - 1 ? null : () => onJump(i),
              child: Text(
                names[i],
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: i == names.length - 1
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _leaf(String p) {
    final s = p.replaceAll(RegExp(r'[\\/]+$'), '');
    final i = s.lastIndexOf(RegExp(r'[\\/]'));
    return i < 0 ? s : s.substring(i + 1);
  }
}

class _RootsList extends ConsumerWidget {
  const _RootsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    final tree = ref.watch(_rootNodesProvider);
    return tree.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorRetry(
        error: e,
        onRetry: () => ref.invalidate(_rootNodesProvider),
      ),
      data: (nodes) => nodes.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No library roots yet. Add a music folder on the desktop.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: nodes.length,
              itemBuilder: (ctx, i) {
                final n = nodes[i];
                return ListTile(
                  key: ValueKey('root:${n.path}'),
                  leading: CoverImage(
                    hash: n.cover,
                    client: client,
                    size: 44,
                    thumb: true,
                    placeholderIcon: Icons.folder_outlined,
                  ),
                  title: Text(n.name),
                  subtitle: Text(
                    n.path,
                    style: Ol1nTheme.mono(ctx, size: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => ctx
                      .findAncestorStateOfType<_LibraryScreenState>()
                      ?._open(n.path),
                  onLongPress: () => showDirActions(ctx, ref, n),
                );
              },
            ),
    );
  }
}

final _rootNodesProvider = FutureProvider<List<DirNode>>((ref) {
  ref.watch(connectionProvider);
  return ref.watch(clientProvider).tree('');
});

class _DirListing extends ConsumerWidget {
  const _DirListing({required this.dir, required this.onOpen});
  final String dir;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    final listing = ref.watch(listingProvider(dir));
    final nowPath = ref.watch(
      engineStateProvider.select((s) => s?.track?.path),
    );
    final playing = ref.watch(
      engineStateProvider.select((s) => s?.isPlaying ?? false),
    );
    return listing.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorRetry(
        error: e,
        onRetry: () => ref.invalidate(listingProvider(dir)),
      ),
      data: (l) {
        final items = <Widget>[];
        if (l.cover.isNotEmpty || l.tracks.isNotEmpty) {
          items.add(_FolderHeader(listing: l));
        }
        for (final d in l.dirs) {
          items.add(
            ListTile(
              key: ValueKey('dir:${d.path}'),
              leading: CoverImage(
                hash: d.cover,
                client: client,
                size: 44,
                thumb: true,
                placeholderIcon: Icons.folder_outlined,
              ),
              title: Text(d.name),
              subtitle: d.tracks > 0 ? Text('${d.tracks} tracks') : null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onOpen(d.path),
              onLongPress: () => showDirActions(context, ref, d),
            ),
          );
        }
        for (final t in l.tracks) {
          items.add(
            TrackTile(
              key: ValueKey('track:${t.path}'),
              track: t,
              nowPlaying: t.path == nowPath,
              playing: playing,
              onTap: () {
                haptic();
                client.playPaths(
                  l.tracks.map((x) => x.path).toList(),
                  index: l.tracks.indexOf(t),
                );
              },
              onSecondaryTap: () =>
                  showTrackActions(context, ref, t, siblings: l.tracks),
              onFavorite: (_) => toggleFavorite(ref, t),
              trailing: IconButton(
                icon: const Icon(Icons.more_vert, size: 20),
                onPressed: () =>
                    showTrackActions(context, ref, t, siblings: l.tracks),
              ),
            ),
          );
        }
        if (items.isEmpty) {
          return const Center(child: Text('Empty folder'));
        }
        return ListView(children: items);
      },
    );
  }
}

class _FolderHeader extends ConsumerWidget {
  const _FolderHeader({required this.listing});
  final Listing listing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    final t = listing.tracks.isNotEmpty ? listing.tracks.first : null;
    final total = listing.tracks.fold<int>(0, (a, t) => a + t.durationMs);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          CoverImage(hash: listing.cover, client: client, size: 96),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (t != null) ...[
                  Text(
                    t.album.isEmpty ? _Breadcrumbs._leaf(listing.dir) : t.album,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    t.albumArtist.isNotEmpty ? t.albumArtist : t.artist,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${listing.tracks.length} tracks · ${fmtDuration(total)}',
                    style: Ol1nTheme.mono(context, size: 11),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      key: const Key('playFolder'),
                      onPressed: listing.tracks.isEmpty
                          ? null
                          : () {
                              haptic();
                              client.playDir(listing.dir);
                            },
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const Text('Play'),
                    ),
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      tooltip: 'Add to queue',
                      onPressed: listing.tracks.isEmpty
                          ? null
                          : () => client.queueAdd(
                              listing.tracks.map((t) => t.path).toList(),
                            ),
                      icon: const Icon(Icons.playlist_add, size: 18),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(searchQueryProvider);
    final res = ref.watch(searchResultsProvider);
    final client = ref.watch(clientProvider);
    if (q.trim().length < 2) {
      return const Center(child: Text('Type at least two characters'));
    }
    return res.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (tracks) => tracks.isEmpty
          ? const Center(child: Text('No matches'))
          : ListView.builder(
              itemCount: tracks.length,
              itemBuilder: (ctx, i) {
                final t = tracks[i];
                return TrackTile(
                  key: ValueKey('hit:${t.path}'),
                  track: t,
                  showNumber: false,
                  onTap: () {
                    haptic();
                    client.play(t.path);
                  },
                  onSecondaryTap: () =>
                      showTrackActions(ctx, ref, t, siblings: tracks),
                  trailing: IconButton(
                    icon: const Icon(Icons.more_vert, size: 20),
                    onPressed: () =>
                        showTrackActions(ctx, ref, t, siblings: tracks),
                  ),
                );
              },
            ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('$error', textAlign: TextAlign.center),
        ),
        OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}
