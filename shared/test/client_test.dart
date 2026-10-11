import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

void main() {
  late FakeEngine engine;
  late EngineClient client;

  /// Subscribes to state events *before* sending the command: the engine
  /// pushes the state change ahead of the command's response.
  Future<EngineState> until(
    bool Function(EngineState) pred,
    Future<void> Function() act,
  ) async {
    final f = client.state$.firstWhere(pred);
    await act();
    return f.timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw TimeoutException(
        'state change not observed (last: ${client.state.value?.playback})',
      ),
    );
  }

  setUp(() async {
    engine = FakeEngine(
      token: 'secret',
      tick: const Duration(milliseconds: 20),
    );
    await engine.start();
    client = EngineClient(requestTimeout: const Duration(seconds: 3));
  });

  tearDown(() async {
    await client.dispose();
    await engine.stop();
  });

  test('hello with the right token connects and primes state', () async {
    final info = await client.connect(engine.wsUri, token: 'secret');
    expect(info.name, contains('Elfton Player'));
    expect(info.httpPort, engine.port);
    expect(client.status.value, ConnectionStatus.connected);
    expect(
      client.coverUrl('abc'),
      Uri.parse('http://127.0.0.1:${engine.port}/cover/abc.jpg'),
    );
    expect(client.coverUrl('abc', thumb: true)!.path, '/cover/abc_t.jpg');
    final s = await client.getState();
    expect(s.isStopped, isTrue);
  });

  test('wrong token is rejected', () async {
    await expectLater(
      client.connect(engine.wsUri, token: 'nope'),
      throwsA(isA<EngineException>()),
    );
    await client.close();
  });

  test('library browsing', () async {
    await client.connect(engine.wsUri, token: 'secret');
    final roots = await client.libraryRoots();
    expect(roots.single.tracks, engine.tracks.length);
    final top = await client.tree();
    expect(top.single.hasDirs, isTrue);
    final l = await client.list(engine.tracks.first.dir);
    expect(l.tracks, hasLength(3));
    expect(l.tracks.first.formatBadge, 'FLAC 24/96k');
    final hits = await client.search('autechre');
    expect(hits, hasLength(2));
    final t = await client.track(engine.tracks.first.path);
    expect(t.title, engine.tracks.first.title);
  });

  test('play → state events → A-B → queue', () async {
    await client.connect(engine.wsUri, token: 'secret');
    final first = client.state$.firstWhere((s) => s.isPlaying);
    await client.playDir(engine.tracks.first.dir, index: 1);
    final s = await first.timeout(const Duration(seconds: 2));
    expect(s.track?.trackNo, 2);
    expect(s.output.bitPerfect, isTrue);
    expect(s.queueLen, 3);
    expect(s.nextTrack, isNotNull);

    // position advances on the fake device clock
    final moved = await client.state$
        .firstWhere((s) => s.positionMs > 0)
        .timeout(const Duration(seconds: 2));
    expect(moved.isPlaying, isTrue);

    await client.abSetA(96000);
    final ab = await until((s) => s.ab.active, () => client.abSetB(192000));
    expect(ab.ab.aMs, 1000);
    expect(ab.ab.bMs, 2000);
    final nudged = await until(
      (s) => s.ab.bMs == 2010,
      () => client.abNudge('b', 10),
    );
    expect(nudged.ab.b, 192960);
    await client.abToggle(false);
    final cleared = await until((s) => !s.ab.hasA, () => client.abClear());
    expect(cleared.ab.isSet, isFalse);

    await until((s) => s.isPaused, () => client.pause());
    await until((s) => s.isPlaying, () => client.toggle());
    await until((s) => s.mono, () => client.setMono(true));
    await until((s) => s.positionMs >= 5000, () => client.seekMs(5000));

    final q = await client.queueGet();
    expect(q.index, 1);
    final qf = client.queue$.first;
    await client.queueAdd([engine.tracks.last.path]);
    final q2 = await qf.timeout(const Duration(seconds: 2));
    expect(q2.length, 4);
    await client.queueMove(3, 0);
    final q3 = await client.queueGet();
    expect(q3.tracks.first.path, engine.tracks.last.path);
    expect(q3.index, 2);
    await until((s) => s.queueIndex == 3, () => client.next());
    await client.queueRemove(0);
    expect((await client.queueGet()).length, 3);
    await until((s) => s.isStopped, () => client.stop());
    expect(engine.requests.map((r) => r.type), contains(Cmd.abNudge));
  });

  test(
    'favorites, history, settings, sleep, lyrics, cover, devices, sysmode',
    () async {
      await client.connect(engine.wsUri, token: 'secret');
      final p = engine.tracks.first.path;
      await client.addFavorite(p);
      expect((await client.favorites()).single.favorite, isTrue);
      await client.removeFavorite(p);
      expect(await client.favorites(), isEmpty);

      await until((s) => s.isPlaying, () => client.play(p));
      expect(await client.history(), isNotEmpty);

      final s0 = await client.settingsGet();
      final s1 = await client.settingsUpdate(
        s0.copyWith(theme: 'dark', mono: true),
        s0,
      );
      expect(s1.theme, 'dark');
      expect(s1.mono, isTrue);

      final sleepEv = client.sleep$.first;
      await client.sleepSet(30);
      expect((await sleepEv.timeout(const Duration(seconds: 2)))?.minutes, 30);
      await client.sleepClear();

      final ly = await client.lyrics(p);
      expect(ly.isTimed, isTrue);
      final cv = await client.cover(p);
      expect(cv?.hash, engine.tracks.first.cover);
      expect(await client.cover(engine.tracks.last.path), isNull);

      final devs = await client.devices();
      expect(devs.single.selected, isTrue);
      await client.selectDevice(devs.single.backend, devs.single.id);
      final st = await client.outputStats();
      expect(st.ringFillPct, greaterThan(0));

      final sm = await client.sysmodeGet();
      expect(sm.template, isNotEmpty);
      await client.sysmodeSet(
        sm.copyWith(enabled: true, suspendProcesses: ['OneDrive.exe']),
      );
      expect((await client.sysmodeGet()).suspendProcesses, ['OneDrive.exe']);
      await expectLater(client.sysmodeApply(), throwsA(isA<EngineException>()));
      expect(await client.sysmodeLog(), isEmpty);

      final ri = await client.remoteEnable(true);
      expect(ri.enabled, isTrue);
      expect(PairingInfo.parse(ri.qr)?.token, 'secret');
      expect(await client.playlists(), isNotEmpty);
      await client.loadPlaylist('x');
      expect((await client.queueGet()).length, 2);
      final info = await client.version();
      expect(info.protocolVersion, protocolVersion);
    },
  );

  test('reconnects after the engine goes away and comes back', () async {
    await client.connect(engine.wsUri, token: 'secret');
    final port = engine.port;
    await engine.stop();
    await client.status.waitFor((s) => s == ConnectionStatus.reconnecting);
    engine = FakeEngine(token: 'secret');
    await engine.start(port: port);
    await client.status.waitFor(
      (s) => s == ConnectionStatus.connected,
      timeout: const Duration(seconds: 10),
    );
    expect((await client.version()).httpPort, port);
  });

  test('requests fail fast when not connected', () async {
    await expectLater(client.pause(), throwsA(isA<EngineException>()));
  });
}

extension<T> on ValueListenable<T> {
  Future<void> waitFor(
    bool Function(T) pred, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (pred(value)) return Future.value();
    final c = Completer<void>();
    void l() {
      if (pred(value) && !c.isCompleted) c.complete();
    }

    addListener(l);
    return c.future.timeout(timeout).whenComplete(() => removeListener(l));
  }
}
