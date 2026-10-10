import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/actions.dart';
import '../../core/providers.dart';
import 'folder_menu.dart';

/// Left pane: roots → folders, 1:1 with the file system, lazily loaded.
class LibraryTree extends ConsumerWidget {
  const LibraryTree({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roots = ref.watch(rootsProvider);
    final scheme = Theme.of(context).colorScheme;
    return roots.when(
      loading: () => const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (e, _) => Center(
        child: Text('$e', style: TextStyle(color: scheme.error)),
      ),
      data: (list) {
        if (list.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.folder_open_outlined,
                    color: scheme.onSurfaceVariant,
                    size: 36,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'No library folders yet',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Use the folder button above to add one.',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: [
            for (final r in list)
              _Node(
                node: DirNode(
                  path: r.path,
                  name: r.name,
                  hasDirs: true,
                  tracks: r.tracks,
                ),
                depth: 0,
                root: r,
              ),
          ],
        );
      },
    );
  }
}

class _Node extends ConsumerWidget {
  const _Node({required this.node, required this.depth, this.root});

  final DirNode node;
  final int depth;
  final Root? root;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(
      expandedProvider.select((s) => s.contains(node.path)),
    );
    final selected = ref.watch(selectedDirProvider) == node.path;
    final playingDir = ref.watch(stateProvider.select((s) => s.track?.dir));
    final client = ref.watch(clientProvider);
    final scheme = Theme.of(context).colorScheme;
    final actions = ref.read(actionsProvider);

    final isPlayingHere = playingDir == node.path;
    final missing = root?.missing ?? false;

    final row = InkWell(
      onTap: () => ref.read(selectedDirProvider.notifier).select(node.path),
      onDoubleTap: () => actions.playDir(context, node.path),
      onSecondaryTapDown: (d) =>
          showFolderMenu(context, ref, node.path, d.globalPosition),
      child: Container(
        height: 28,
        padding: EdgeInsets.only(left: 4 + depth * 14.0, right: 6),
        color: selected ? scheme.primary.withValues(alpha: 0.10) : null,
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: node.hasDirs
                  ? IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      iconSize: 16,
                      icon: Icon(
                        expanded ? Icons.expand_more : Icons.chevron_right,
                      ),
                      onPressed: () =>
                          ref.read(expandedProvider.notifier).toggle(node.path),
                    )
                  : null,
            ),
            const SizedBox(width: 2),
            if (node.cover.isNotEmpty)
              CoverImage(
                hash: node.cover,
                client: client,
                size: 18,
                thumb: true,
                borderRadius: 3,
              )
            else
              Icon(
                root != null
                    ? (missing
                          ? Icons.folder_off_outlined
                          : Icons.storage_rounded)
                    : (expanded
                          ? Icons.folder_open_outlined
                          : Icons.folder_outlined),
                size: 16,
                color: missing
                    ? scheme.error
                    : (selected ? scheme.primary : scheme.onSurfaceVariant),
              ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                root != null ? root!.path : node.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: missing
                      ? scheme.onSurfaceVariant
                      : (selected || isPlayingHere
                            ? scheme.primary
                            : scheme.onSurface),
                  fontWeight: isPlayingHere ? FontWeight.w600 : null,
                ),
              ),
            ),
            if (isPlayingHere)
              Icon(Icons.volume_up_rounded, size: 13, color: scheme.primary),
            if (node.tracks > 0 && !isPlayingHere)
              Text(
                '${node.tracks}',
                style: Ol1nTheme.mono(
                  context,
                  size: 10,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (root?.scanning ?? false)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ),
          ],
        ),
      ),
    );

    if (!expanded) return row;
    final children = ref.watch(treeProvider(node.path));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        children.when(
          loading: () => Padding(
            padding: EdgeInsets.only(
              left: 24 + depth * 14.0,
              top: 4,
              bottom: 4,
            ),
            child: const Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            ),
          ),
          error: (e, _) => Padding(
            padding: EdgeInsets.only(left: 24 + depth * 14.0),
            child: Text(
              '$e',
              style: TextStyle(color: scheme.error, fontSize: 11),
            ),
          ),
          data: (kids) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final k in kids) _Node(node: k, depth: depth + 1)],
          ),
        ),
      ],
    );
  }
}
