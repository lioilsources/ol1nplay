import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/actions.dart';
import '../../core/providers.dart';
import '../../core/shortcuts.dart';
import '../library/library_tree.dart';
import '../now_playing/mini_player.dart';
import '../now_playing/now_playing_pane.dart';
import '../tray/desktop_integration.dart';
import '../views/middle_views.dart';
import 'pane_splitter.dart';
import 'status_bar.dart';
import 'top_bar.dart';
import 'waiting_screen.dart';

/// Root widget after the theme: waits for the engine, then shows the
/// three-pane shell (or the mini player / fullscreen now playing).
class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});

  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  final _searchFocus = FocusNode();
  bool _everConnected = false;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(launcherProvider).start();
      ref.read(desktopIntegrationControllerProvider)?.start();
    });
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(connectionProvider);
    if (st == ConnectionStatus.connected) _everConnected = true;
    if (!_everConnected) return const WaitingScreen();

    final mini = ref.watch(miniModeProvider);
    final full = ref.watch(fullscreenNowPlayingProvider);
    final prefs = ref.watch(prefsProvider);
    final showLog = ref.watch(showLogProvider);
    final a = ref.read(actionsProvider);
    final scheme = Theme.of(context).colorScheme;

    Widget body;
    if (mini) {
      body = const MiniPlayer();
    } else if (full) {
      body = Scaffold(
        body: Stack(
          children: [
            const NowPlayingPane(fullscreen: true),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                tooltip: 'Exit fullscreen (Esc)',
                icon: const Icon(Icons.close_fullscreen),
                onPressed: () =>
                    ref.read(fullscreenNowPlayingProvider.notifier).set(false),
              ),
            ),
          ],
        ),
      );
    } else {
      body = Scaffold(
        body: Column(
          children: [
            TopBar(searchFocus: _searchFocus),
            Expanded(
              child: ListenableBuilder(
                listenable: prefs,
                builder: (context, _) => Row(
                  children: [
                    SizedBox(
                      width: prefs.treeWidth,
                      child: const LibraryTree(),
                    ),
                    PaneSplitter(
                      onDrag: (dx) => prefs.treeWidth = (prefs.treeWidth + dx)
                          .clamp(160, 600),
                    ),
                    const Expanded(
                      child: Column(
                        children: [
                          MiddleTabs(),
                          Expanded(child: MiddlePane()),
                        ],
                      ),
                    ),
                    PaneSplitter(
                      onDrag: (dx) => prefs.nowPlayingWidth =
                          (prefs.nowPlayingWidth - dx).clamp(260, 700),
                    ),
                    SizedBox(
                      width: prefs.nowPlayingWidth,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                        ),
                        child: const NowPlayingPane(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (showLog) const LogDrawer(),
            const StatusBar(),
          ],
        ),
      );
    }

    // Reconnecting banner over whatever is shown.
    if (st != ConnectionStatus.connected) {
      body = Stack(
        children: [
          body,
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Material(
              color: Ol1nTheme.warnAmber,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'Engine connection lost — reconnecting…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: scheme.onPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Shortcuts(
      shortcuts: appShortcuts,
      child: Actions(
        actions: appActions(ref, _searchFocus),
        child: Focus(
          autofocus: true,
          child: DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: (d) {
              setState(() => _dragging = false);
              a.dropped(context, d.files.map((f) => f.path).toList());
            },
            child: Stack(
              children: [
                body,
                if (_dragging)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        color: scheme.primary.withValues(alpha: 0.12),
                        child: Center(
                          child: Text(
                            'Drop to play',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
