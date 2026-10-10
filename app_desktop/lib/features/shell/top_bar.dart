import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/actions.dart';
import '../../core/providers.dart';
import '../output/device_menu.dart';
import '../remote/remote_dialog.dart';
import '../settings/settings_dialog.dart';
import '../sysmode/sysmode_dialog.dart';

/// Search · roots · device · remote · sysmode · settings · window modes.
class TopBar extends ConsumerStatefulWidget {
  const TopBar({super.key, required this.searchFocus});

  final FocusNode searchFocus;

  @override
  ConsumerState<TopBar> createState() => _TopBarState();
}

class _TopBarState extends ConsumerState<TopBar> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final query = ref.watch(searchQueryProvider);
    if (query.isEmpty && _ctl.text.isNotEmpty) {
      // Cleared from elsewhere (Esc, folder click).
      WidgetsBinding.instance.addPostFrameCallback((_) => _ctl.clear());
    }
    final sysmode = ref.watch(stateProvider.select((s) => s.sysmode));
    final remote = ref.watch(stateProvider.select((s) => s.remote));
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outline)),
      ),
      child: Row(
        children: [
          Icon(Icons.graphic_eq_rounded, color: scheme.primary, size: 20),
          const SizedBox(width: 8),
          SizedBox(
            width: 280,
            height: 32,
            child: TextField(
              key: const Key('search-field'),
              controller: _ctl,
              focusNode: widget.searchFocus,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 16),
                hintText: 'Search library  (Ctrl+F)',
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 6,
                  horizontal: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                suffixIcon: query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 14),
                        onPressed: () {
                          _ctl.clear();
                          ref.read(searchQueryProvider.notifier).clear();
                        },
                      )
                    : null,
              ),
              onChanged: (v) => ref.read(searchQueryProvider.notifier).set(v),
            ),
          ),
          const SizedBox(width: 6),
          _RootsButton(),
          const Spacer(),
          const DeviceButton(),
          const SizedBox(width: 6),
          IconButton(
            tooltip: remote.enabled
                ? 'Remote on · ${remote.clients} connected'
                : 'Mobile remote (QR pairing)',
            icon: Icon(
              Icons.qr_code_2,
              size: 20,
              color: remote.enabled ? scheme.primary : null,
            ),
            onPressed: () => showRemoteDialog(context),
          ),
          IconButton(
            tooltip: sysmode.applied
                ? 'Playback mode applied'
                : 'Playback mode (system tweaks)',
            icon: Icon(
              Icons.bolt,
              size: 20,
              color: sysmode.applied ? Ol1nTheme.bitPerfectGreen : null,
            ),
            onPressed: () => showSysmodeDialog(context),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.tune, size: 20),
            onPressed: () => showSettingsDialog(context),
          ),
          PopupMenuButton<String>(
            tooltip: 'Window',
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (v) {
              switch (v) {
                case 'mini':
                  ref.read(miniModeProvider.notifier).toggle();
                case 'full':
                  ref.read(fullscreenNowPlayingProvider.notifier).toggle();
                case 'log':
                  ref.read(showLogProvider.notifier).toggle();
                case 'sleep':
                  _sleep(context);
                case 'quit':
                  ref.read(clientProvider).shutdown();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'mini', child: Text('Mini player')),
              PopupMenuItem(
                value: 'full',
                child: Text('Fullscreen now playing  (F11)'),
              ),
              PopupMenuItem(value: 'log', child: Text('Engine log')),
              PopupMenuItem(value: 'sleep', child: Text('Sleep timer…')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'quit', child: Text('Shut down engine')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _sleep(BuildContext context) async {
    final c = ref.read(clientProvider);
    final cur = ref.read(stateProvider).sleep;
    final minutes = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
          cur == null
              ? 'Sleep timer'
              : 'Sleep in ${cur.remaining.inMinutes} min',
        ),
        children: [
          for (final m in [15, 30, 45, 60, 90, 120])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, m),
              child: Text('$m minutes'),
            ),
          if (cur != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 0),
              child: const Text('Cancel timer'),
            ),
        ],
      ),
    );
    if (minutes == null || !context.mounted) return;
    await ref
        .read(actionsProvider)
        .guard(
          context,
          () => minutes == 0 ? c.sleepClear() : c.sleepSet(minutes),
        );
  }
}

class _RootsButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roots = ref.watch(rootsProvider).value ?? const <Root>[];
    final a = ref.read(actionsProvider);
    final c = ref.read(clientProvider);
    final local = ref.read(engineTargetProvider).local;
    return PopupMenuButton<String>(
      tooltip: 'Library folders',
      icon: const Icon(Icons.create_new_folder_outlined, size: 20),
      onSelected: (v) async {
        if (v == '+') {
          final messenger = ScaffoldMessenger.of(context);
          if (!local) {
            messenger.showSnackBar(
              const SnackBar(
                content: Text(
                  'Remote engine: add folders on the engine machine.',
                ),
              ),
            );
            return;
          }
          final dir = await getDirectoryPath();
          if (dir == null || !context.mounted) return;
          await a.guard(context, () => c.addRoot(dir));
          ref.read(libraryVersionProvider.notifier).bumpAll();
        } else if (v.startsWith('-')) {
          await a.guard(context, () => c.removeRoot(v.substring(1)));
          ref.read(libraryVersionProvider.notifier).bumpAll();
        } else if (v.startsWith('~')) {
          await a.rescan(context, v.substring(1));
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: '+',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.add),
            title: Text('Add folder…'),
          ),
        ),
        if (roots.isNotEmpty) const PopupMenuDivider(),
        for (final r in roots) ...[
          PopupMenuItem(
            value: '~${r.path}',
            child: ListTile(
              dense: true,
              leading: Icon(
                r.missing ? Icons.folder_off_outlined : Icons.refresh,
              ),
              title: Text(r.path, overflow: TextOverflow.ellipsis),
              subtitle: Text('${r.tracks} tracks · rescan'),
            ),
          ),
          PopupMenuItem(
            value: '-${r.path}',
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.remove_circle_outline),
              title: Text('Remove ${baseName(r.path)}'),
            ),
          ),
        ],
      ],
    );
  }
}
