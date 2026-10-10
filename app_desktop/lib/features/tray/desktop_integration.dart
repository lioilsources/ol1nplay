import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/prefs.dart';
import '../../core/providers.dart';
import '../now_playing/mini_player.dart';

/// window_manager + tray_manager glue. Everything is best-effort: a
/// MissingPluginException (tests, unsupported platform) must never take
/// the UI down with it.
class DesktopIntegration with TrayListener, WindowListener {
  DesktopIntegration(this.ref);

  final Ref ref;
  bool _ready = false;
  Size? _normalSize;
  Offset? _normalPos;

  static Future<void> initWindow(Prefs prefs) async {
    try {
      await windowManager.ensureInitialized();
      final b = prefs.windowBounds;
      final opts = WindowOptions(
        minimumSize: const Size(900, 560),
        size: b == null ? const Size(1280, 800) : Size(b[2], b[3]),
        title: 'Ol1nPlay',
        titleBarStyle: TitleBarStyle.normal,
      );
      await windowManager.waitUntilReadyToShow(opts, () async {
        if (b != null) {
          try {
            await windowManager.setPosition(Offset(b[0], b[1]));
          } catch (_) {}
        }
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (e) {
      debugPrint('window_manager unavailable: $e');
    }
  }

  Future<void> start() async {
    if (_ready) return;
    _ready = true;
    try {
      windowManager.addListener(this);
    } catch (_) {}
    try {
      await trayManager.setIcon(_trayIcon());
      await _menu();
      trayManager.addListener(this);
    } catch (e) {
      debugPrint('tray unavailable: $e');
    }
    ref.listen<EngineState>(stateProvider, (prev, next) {
      final title = next.track == null
          ? 'Ol1nPlay'
          : 'Ol1nPlay — ${next.track!.displayTitle}';
      if (prev?.track?.path != next.track?.path ||
          prev?.playback != next.playback) {
        windowManager.setTitle(title).catchError((_) {});
        _menu();
      }
    });
    ref.listen<bool>(miniModeProvider, (_, mini) => _applyMini(mini));
  }

  String _trayIcon() =>
      Platform.isWindows ? 'assets/tray/icon.ico' : 'assets/tray/icon.png';

  Future<void> _menu() async {
    final s = ref.read(stateProvider);
    try {
      await trayManager.setToolTip(
        s.track == null ? 'Ol1nPlay' : s.track!.displayTitle,
      );
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'toggle', label: s.isPlaying ? 'Pause' : 'Play'),
            MenuItem(key: 'next', label: 'Next'),
            MenuItem(key: 'prev', label: 'Previous'),
            MenuItem.separator(),
            MenuItem(key: 'show', label: 'Show window'),
            MenuItem(key: 'quit', label: 'Quit'),
          ],
        ),
      );
    } catch (_) {}
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show().catchError((_) {});
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu().catchError((_) {});
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final c = ref.read(clientProvider);
    switch (menuItem.key) {
      case 'toggle':
        c.toggle();
      case 'next':
        c.next();
      case 'prev':
        c.prev();
      case 'show':
        windowManager.show().catchError((_) {});
      case 'quit':
        windowManager.close().catchError((_) {});
    }
  }

  @override
  void onWindowMoved() => _saveBounds();

  @override
  void onWindowResized() => _saveBounds();

  Future<void> _saveBounds() async {
    if (ref.read(miniModeProvider)) return;
    try {
      final b = await windowManager.getBounds();
      ref.read(prefsProvider).windowBounds = [b.left, b.top, b.width, b.height];
    } catch (_) {}
  }

  Future<void> _applyMini(bool mini) async {
    try {
      if (mini) {
        final b = await windowManager.getBounds();
        _normalSize = b.size;
        _normalPos = b.topLeft;
        await windowManager.setMinimumSize(MiniPlayer.size);
        await windowManager.setSize(MiniPlayer.size);
        await windowManager.setAlwaysOnTop(true);
      } else {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setMinimumSize(const Size(900, 560));
        if (_normalSize != null) await windowManager.setSize(_normalSize!);
        if (_normalPos != null) await windowManager.setPosition(_normalPos!);
      }
    } catch (_) {}
  }

  void dispose() {
    try {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
      trayManager.destroy();
    } catch (_) {}
  }
}

final desktopIntegrationControllerProvider = Provider<DesktopIntegration?>((
  ref,
) {
  if (!ref.watch(desktopIntegrationProvider)) return null;
  final d = DesktopIntegration(ref);
  ref.onDispose(d.dispose);
  return d;
});
