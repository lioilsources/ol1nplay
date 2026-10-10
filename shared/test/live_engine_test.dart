// End-to-end check of the Dart client against the real Go engine (null
// backend), so a drift between protocol.go and the Dart models cannot hide
// behind the FakeEngine. Skipped unless the engine binary has been built:
//
//   make engine && cd shared && flutter test test/live_engine_test.dart
@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

void main() {
  final bin = File(
    Platform.environment['OL1NPLAY_ENGINE'] ?? '../engine/bin/ol1nplay-engine',
  );
  final fixtures = Directory('../engine/testdata');
  final skip = !bin.existsSync() || !fixtures.existsSync()
      ? 'engine binary or fixtures missing (run `make engine`)'
      : null;

  late Directory data, root;
  late Process engine;
  late EngineClient client;
  const port = 7793;

  setUpAll(() async {
    if (skip != null) return;
    data = await Directory.systemTemp.createTemp('ol1nplay-live-data');
    root = await Directory.systemTemp.createTemp('ol1nplay-live-root');
    for (final f in ['sine16_44.flac', 'sine24_96.flac', 'sine_cover.flac']) {
      File('${fixtures.path}/$f').copySync('${root.path}/$f');
    }
    File('${data.path}/settings.json').writeAsStringSync(
      jsonEncode({
        'backend': 'null',
        'resumeOnStart': false,
        'mediaKeys': false,
      }),
    );
    engine = await Process.start(bin.path, [
      'serve',
      '-port',
      '$port',
      '-data',
      data.path,
      '-root',
      root.path,
    ]);
    engine.stderr.drain<void>();
    engine.stdout.drain<void>();
    client = EngineClient();
    final uri = Uri.parse('ws://127.0.0.1:$port/ws');
    for (var i = 0; ; i++) {
      try {
        await client.connect(uri);
        break;
      } catch (_) {
        if (i > 40) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  });

  tearDownAll(() async {
    if (skip != null) return;
    await client.dispose();
    engine.kill(ProcessSignal.sigint);
    await engine.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        engine.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    data.deleteSync(recursive: true);
    root.deleteSync(recursive: true);
  });

  Future<EngineState> until(bool Function(EngineState) ok) async {
    for (var i = 0; i < 100; i++) {
      final s = await client.getState();
      if (ok(s)) return s;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('state condition not reached');
  }

  test('hello, library, play, mono, A-B, queue, settings, cover', () async {
    final info = client.serverInfo.value!;
    expect(info.name, 'Ol1nPlay');
    expect(info.protocolVersion, protocolVersion);
    expect(info.httpPort, port);
    expect(info.backends, contains('null'));

    // The initial scan runs in the background.
    var roots = await client.libraryRoots();
    for (var i = 0; i < 100 && (roots.isEmpty || roots.first.tracks < 3); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      roots = await client.libraryRoots();
    }
    expect(roots.single.tracks, 3);
    final listing = await client.list(roots.single.path);
    expect(listing.tracks, hasLength(3));
    final hi = listing.tracks.indexWhere((t) => t.fileName == 'sine24_96.flac');
    expect(listing.tracks[hi].sampleRate, 96000);
    expect(listing.tracks[hi].bitDepth, 24);
    expect(listing.tracks[hi].lossless, isTrue);
    expect(listing.tracks[hi].formatBadge, contains('24/96'));

    final hits = await client.search('sixteen');
    // sine_cover.flac is the same recording with a picture attached.
    expect(hits, hasLength(2));
    expect(hits.every((t) => t.title == 'Sine Sixteen'), isTrue);

    await client.playDir(roots.single.path, index: hi);
    var s = await until((s) => s.isPlaying && s.track != null);
    expect(s.track!.fileName, 'sine24_96.flac');
    expect(s.source.sampleRate, 96000);
    expect(s.output.backend, 'null');
    expect(s.output.bitPerfect, isTrue);
    expect(s.queueLen, 3);

    await client.setMono(true);
    s = await until((s) => s.mono);
    expect(s.output.bitPerfect, isFalse);
    await client.setMono(false);

    await client.abSetA(1000);
    await client.abSetB(9000);
    s = await until((s) => s.ab.active);
    expect(s.ab.a, 1000);
    expect(s.ab.b, 9000);
    await client.abClear();

    final q = await client.queueGet();
    expect(q.tracks, hasLength(3));
    expect(q.index, hi);

    final devices = await client.devices();
    expect(devices.any((d) => d.backend == 'null'), isTrue);

    final st = await client.settingsSet({'ramLimitMB': 128});
    expect(st.ramLimitMB, 128);
    expect(st.backend, 'null');
    expect(st.preloadNext, isTrue);

    final cover = await client.cover('${roots.single.path}/sine_cover.flac');
    expect(cover, isNotNull);
    final res = await HttpClient()
        .getUrl(client.coverUrl(cover!.hash)!)
        .then((r) => r.close());
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'image/jpeg');
    await res.drain<void>();

    await client.stop();
    await until((s) => s.playback == Playback.stopped);
  }, skip: skip);
}
