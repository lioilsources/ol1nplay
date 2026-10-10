import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/actions.dart';
import '../../core/providers.dart';

/// Context menu for a folder (tree node or listing header).
Future<void> showFolderMenu(
  BuildContext context,
  WidgetRef ref,
  String dir,
  Offset at,
) async {
  final a = ref.read(actionsProvider);
  final local = ref.read(engineTargetProvider).local;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      at & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: const [
      PopupMenuItem(
        value: 'play',
        child: ListTile(
          dense: true,
          leading: Icon(Icons.play_arrow),
          title: Text('Play folder'),
        ),
      ),
      PopupMenuItem(
        value: 'next',
        child: ListTile(
          dense: true,
          leading: Icon(Icons.playlist_play),
          title: Text('Play next'),
        ),
      ),
      PopupMenuItem(
        value: 'add',
        child: ListTile(
          dense: true,
          leading: Icon(Icons.playlist_add),
          title: Text('Add to queue'),
        ),
      ),
      PopupMenuDivider(),
      PopupMenuItem(
        value: 'rescan',
        child: ListTile(
          dense: true,
          leading: Icon(Icons.refresh),
          title: Text('Rescan'),
        ),
      ),
      PopupMenuItem(
        value: 'reveal',
        child: ListTile(
          dense: true,
          leading: Icon(Icons.folder_open),
          title: Text('Reveal in file manager'),
        ),
      ),
    ],
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'play':
      await a.playDir(context, dir);
    case 'next':
      await a.playNextDir(context, dir);
    case 'add':
      await a.enqueueDir(context, dir);
    case 'rescan':
      await a.rescan(context, dir);
    case 'reveal':
      if (local) await a.reveal(context, dir);
  }
}
