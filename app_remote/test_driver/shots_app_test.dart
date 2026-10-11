import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

/// Host side of `make screenshots-remote`: pairs the app with a running demo
/// engine (`make demo-engine`), walks its screens and captures each with
/// `simctl` into `$SHOTS_DIR/remote_<name>.png`.
///
/// Environment: `DEMO_MUSIC` (the library root the engine serves),
/// `DEMO_TOKEN` (its pairing token), `SHOTS_DEVICE` (simulator name).
Future<void> main() async {
  final env = Platform.environment;
  final dir = env['SHOTS_DIR'] ?? 'build/screenshots';
  final device = env['SHOTS_DEVICE'] ?? 'booted';
  final music = env['DEMO_MUSIC']!;
  final token = env['DEMO_TOKEN']!;
  final album = '$music/Nils Aaberg Trio/Harbour Lights';
  await Directory(dir).create(recursive: true);

  // The engine itself, for what a screenshot needs but a tap cannot place
  // exactly (seek position, loop points).
  final ws = await WebSocket.connect('ws://127.0.0.1:7777/ws');
  ws.listen((_) {});
  var id = 0;
  void engine(String type, [Map<String, Object?> args = const {}]) =>
      ws.add(jsonEncode({'id': ++id, 'type': type, ...args}));

  final driver = await FlutterDriver.connect();

  Future<void> shot(String name) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    final r = await Process.run('xcrun', [
      'simctl',
      'io',
      device,
      'screenshot',
      '$dir/remote_$name.png',
    ]);
    if (r.exitCode != 0) throw StateError('capture: ${r.stderr}');
    stdout.writeln('shot $name');
  }

  final nav = find.byType('NavigationBar');
  SerializableFinder tab(String label) =>
      find.descendant(of: nav, matching: find.text(label));

  try {
    // The position ticker never lets the frame queue go quiet.
    await driver.runUnsynchronized(() async {
      Future<void> tap(SerializableFinder f) async {
        await driver.waitFor(f, timeout: const Duration(seconds: 20));
        await driver.tap(f);
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }

      await driver.waitFor(
        find.byValueKey('manualEntry'),
        timeout: const Duration(minutes: 3),
      );
      // Give mDNS a moment to list the engine.
      await Future<void>.delayed(const Duration(seconds: 4));
      await shot('pairing');

      await tap(find.byValueKey('manualEntry'));
      await tap(find.byValueKey('manualHost'));
      await driver.enterText('127.0.0.1:7778');
      await tap(find.byValueKey('manualToken'));
      await driver.enterText(token);
      await tap(find.byValueKey('manualConnect'));

      await driver.waitFor(find.text('Got it'));
      await shot('no_volume');
      await tap(find.text('Got it'));

      await tap(find.byValueKey('root:$music'));
      await shot('library');
      await tap(find.byValueKey('dir:$music/Nils Aaberg Trio'));
      await tap(find.byValueKey('dir:$album'));
      await tap(find.byValueKey('track:$album/02 Harbour Lights.flac'));
      await shot('album');

      engine('seek', {'ms': 9000});
      engine('ab.setA', {'samples': 6 * 96000});
      engine('ab.setB', {'samples': 24 * 96000});
      await tap(tab('Now playing'));
      await shot('now_playing');

      await tap(tab('Queue'));
      await shot('queue');
      await tap(tab('More'));
      await shot('more');
    });
  } finally {
    engine('stop');
    await ws.close();
    await driver.close();
  }
}
