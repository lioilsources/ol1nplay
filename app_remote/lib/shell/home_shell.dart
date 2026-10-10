import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../core/providers.dart';
import '../features/library/library_screen.dart';
import '../features/now_playing/mini_player.dart';
import '../features/now_playing/now_playing_screen.dart';
import '../features/pairing/volume_notice.dart';
import '../features/queue/queue_screen.dart';
import '../features/settings/settings_screen.dart';

/// Phone: bottom navigation (Library · Now playing · Queue · More) with a
/// mini player above the bar. Tablet (≥ 720 dp wide): library on the left,
/// now playing on the right, queue as a sheet.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return VolumeNoticeGate(
      child: wide ? _buildWide(context) : _buildPhone(context),
    );
  }

  Widget _buildPhone(BuildContext context) {
    final pages = const [
      LibraryScreen(),
      NowPlayingScreen(),
      QueueScreen(),
      SettingsScreen(),
    ];
    return Scaffold(
      body: Column(
        children: [
          const ConnectionBanner(),
          Expanded(
            child: IndexedStack(index: _tab, children: pages),
          ),
          if (_tab != 1) MiniPlayer(onTap: () => setState(() => _tab = 1)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.play_circle_outline),
            selectedIcon: Icon(Icons.play_circle),
            label: 'Now playing',
          ),
          NavigationDestination(
            icon: Icon(Icons.queue_music_outlined),
            selectedIcon: Icon(Icons.queue_music),
            label: 'Queue',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: 'More',
          ),
        ],
      ),
    );
  }

  Widget _buildWide(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const ConnectionBanner(),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: 360,
                  child: Column(
                    children: [
                      Expanded(
                        child: IndexedStack(
                          index: _tab == 3 ? 1 : (_tab == 2 ? 2 : 0),
                          children: const [
                            LibraryScreen(),
                            SettingsScreen(),
                            QueueScreen(),
                          ],
                        ),
                      ),
                      NavigationBar(
                        height: 56,
                        labelBehavior:
                            NavigationDestinationLabelBehavior.alwaysHide,
                        selectedIndex: _tab == 3 ? 1 : (_tab == 2 ? 2 : 0),
                        onDestinationSelected: (i) =>
                            setState(() => _tab = [0, 3, 2][i]),
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.library_music_outlined),
                            label: 'Library',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.tune_outlined),
                            label: 'More',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.queue_music_outlined),
                            label: 'Queue',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                const Expanded(child: NowPlayingScreen(embedded: true)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Thin strip above everything while the engine is unreachable, so the
/// user understands why taps do nothing. Disappears when connected.
class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionProvider);
    if (status == ConnectionStatus.connected) return const SizedBox.shrink();
    final err = ref.watch(lastErrorProvider);
    final label = switch (status) {
      ConnectionStatus.connecting => 'Connecting…',
      ConnectionStatus.reconnecting => 'Reconnecting…',
      _ => 'Not connected',
    };
    return Material(
      color: Ol1nTheme.warnAmber.withValues(alpha: 0.15),
      child: SafeArea(
        bottom: false,
        child: InkWell(
          onTap: () => ref.read(connectionProvider.notifier).retry(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                ConnectionDot(status: _like(status)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    err == null || err.isEmpty ? label : '$label · $err',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const Text('Retry', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

ConnectionStatusLike _like(ConnectionStatus s) => switch (s) {
  ConnectionStatus.connected => ConnectionStatusLike.connected,
  ConnectionStatus.connecting ||
  ConnectionStatus.reconnecting => ConnectionStatusLike.connecting,
  ConnectionStatus.disconnected => ConnectionStatusLike.disconnected,
};

ConnectionStatusLike connectionLike(ConnectionStatus s) => _like(s);
