import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

/// Host side of `make screenshots-desktop`: walks the macOS build attached
/// to a running demo engine (`make demo-engine`) and captures its window
/// into `$SHOTS_DIR/desktop_<name>.png`. Sizing and capturing the window
/// needs Accessibility and Screen Recording for the terminal.
///
/// Environment: `DEMO_MUSIC` (the library root the engine serves).
Future<void> main() async {
  final env = Platform.environment;
  final dir = env['SHOTS_DIR'] ?? 'build/screenshots';
  final music = env['DEMO_MUSIC']!;
  final process = env['SHOTS_PROCESS'] ?? 'ol1nplay_desktop';
  final size = env['SHOTS_SIZE'] ?? '1360, 850';
  final artist = '$music/Nils Aaberg Trio';
  final album = '$artist/Harbour Lights';
  await Directory(dir).create(recursive: true);

  // The engine itself, for what a screenshot needs but a tap cannot place
  // exactly (seek position, loop points).
  final ws = await WebSocket.connect('ws://127.0.0.1:7777/ws');
  ws.listen((_) {});
  var id = 0;
  void engine(String type, [Map<String, Object?> args = const {}]) =>
      ws.add(jsonEncode({'id': ++id, 'type': type, ...args}));

  Future<String> window(String script) async {
    final r = await Process.run('osascript', [
      '-e',
      'tell application "System Events" to tell process "$process" to $script',
    ]);
    if (r.exitCode != 0) throw StateError('osascript: ${r.stderr}');
    return (r.stdout as String).trim();
  }

  String? windowId;
  Future<void> shot(String name) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    if (windowId == null) {
      final r = await Process.run('swift', [
        '../tools/window_id.swift',
        process,
      ]);
      if (r.exitCode != 0) throw StateError('no $process window on screen');
      windowId = (r.stdout as String).trim();
    }
    await window('set frontmost to true');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // By window id, not by rectangle: no shadow, and nothing of whatever
    // sits behind the rounded corners.
    final r = await Process.run('screencapture', [
      '-x',
      '-o',
      '-l$windowId',
      '$dir/desktop_$name.png',
    ]);
    if (r.exitCode != 0) throw StateError('capture: ${r.stderr}');
    stdout.writeln('shot $name');
  }

  final driver = await FlutterDriver.connect();
  try {
    // The position ticker never lets the frame queue go quiet.
    await driver.runUnsynchronized(() async {
      Future<void> tap(SerializableFinder f) async {
        await driver.waitFor(f, timeout: const Duration(seconds: 20));
        await driver.tap(f);
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }

      Future<void> dialog(String tooltip, String name) async {
        await tap(find.byTooltip(tooltip));
        await shot(name);
        await tap(find.text('Close'));
      }

      await driver.waitFor(
        find.byType('LibraryTree'),
        timeout: const Duration(minutes: 3),
      );
      await window('set position of window 1 to {60, 60}');
      await window('set size of window 1 to {$size}');

      await driver.requestData('open:$music|$artist|$album');
      engine('play', {'dir': album, 'index': 1});
      await Future<void>.delayed(const Duration(seconds: 2));
      engine('seek', {'ms': 9000});
      engine('ab.setA', {'samples': 6 * 96000});
      engine('ab.setB', {'samples': 24 * 96000});
      await shot('main');

      await tap(find.text('Lyrics'));
      await shot('lyrics');
      await tap(find.text('Queue'));
      await shot('queue');
      await tap(find.text('Folder'));

      await dialog('Settings', 'settings');
      await dialog('Playback mode (system tweaks)', 'sysmode');
      await dialog('Remote on · 0 connected', 'remote');
    });
  } finally {
    engine('stop');
    await ws.close();
    await driver.close();
  }
}
