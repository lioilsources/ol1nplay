import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ol1nplay_remote/app.dart';
import 'package:ol1nplay_remote/core/engine_store.dart';
import 'package:ol1nplay_remote/core/providers.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

/// End-to-end widget tests against the shared FakeEngine: a real
/// localhost WebSocket, so the whole client path is exercised.
void main() {
  late FakeEngine engine;
  late MemoryEngineStore store;

  setUp(() async {
    engine = FakeEngine(
      token: 'secret',
      tick: const Duration(milliseconds: 30),
    );
    await engine.start();
    store = MemoryEngineStore()..flags['volumeNoticeSeen'] = true;
  });

  tearDown(() async => engine.stop());

  late ProviderContainer container;

  Widget app() {
    container = ProviderContainer(
      overrides: [
        engineStoreProvider.overrideWithValue(store),
        discoveryProvider.overrideWithValue(
          StaticEngineDiscovery([
            DiscoveredEngine(
              name: 'Fake PC',
              host: '127.0.0.1',
              port: engine.port,
              httpPort: engine.port,
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: const Ol1nRemoteApp(),
    );
  }

  /// Pumps until [finder] matches or [timeout] elapses (real async I/O
  /// underneath, so a fixed pump count is not enough).
  Future<void> pumpUntil(
    WidgetTester t,
    Finder finder, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      // Inside runAsync the socket is real, so wait on the real clock too.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await t.pump();
      if (finder.evaluate().isNotEmpty) return;
    }
    throw TestFailure('timed out waiting for $finder');
  }

  /// Phone-sized view: ≥ 720 dp wide switches to the tablet layout.
  void phone(WidgetTester t) {
    t.view.physicalSize = const Size(420, 860);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  Future<void> pairManually(WidgetTester t) async {
    phone(t);
    await t.pumpWidget(app());
    await pumpUntil(t, find.byKey(const Key('manualEntry')));
    await t.tap(find.byKey(const Key('manualEntry')));
    await t.pump();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await t.pump();
    await t.enterText(
      find.byKey(const Key('manualHost')),
      '127.0.0.1:${engine.port}',
    );
    await t.enterText(find.byKey(const Key('manualToken')), 'secret');
    await t.tap(find.byKey(const Key('manualConnect')));
    // Shell appears, connection comes up, roots load.
    await pumpUntil(t, find.byKey(const ValueKey('root:/fake/Music')));
  }

  /// Root → /fake/Music → Singles (a folder that holds tracks directly).
  Future<void> openSingles(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('root:/fake/Music')));
    await pumpUntil(t, find.byKey(const ValueKey('dir:/fake/Music/Singles')));
    await t.tap(find.byKey(const ValueKey('dir:/fake/Music/Singles')));
  }

  testWidgets(
    'pair by manual entry → library → play → now playing badge',
    (t) => t.runAsync(() async {
      await pairManually(t);
      expect(store.engines.single.token, 'secret');
      expect(store.current, '127.0.0.1:${engine.port}');

      // Walk into the root and the first album.
      await openSingles(t);
      await pumpUntil(t, find.byKey(const Key('playFolder')));

      // Play the folder; the fake engine starts "playing" and pushes state.
      await t.tap(find.byKey(const Key('playFolder')));
      await pumpUntil(t, find.byKey(const Key('miniTitle')));
      expect(engine.requests.any((r) => r.type == Cmd.play), isTrue);

      // Open now playing from the mini player and check the format badge.
      await t.tap(find.byKey(const Key('miniTitle')));
      await pumpUntil(t, find.byKey(const Key('npTitle')));
      expect(find.byType(FormatBadge), findsOneWidget);
      expect(find.byType(SeekBar), findsOneWidget);
      expect(find.byType(TransportBar), findsOneWidget);
      final title = t.widget<Text>(find.byKey(const Key('npTitle'))).data;
      expect(title, isNot('Nothing playing'));
    }),
  );

  testWidgets(
    'A-B set from now playing reaches the engine',
    (t) => t.runAsync(() async {
      await pairManually(t);
      await openSingles(t);
      await pumpUntil(t, find.byKey(const Key('playFolder')));
      await t.tap(find.byKey(const Key('playFolder')));
      await pumpUntil(t, find.byKey(const Key('miniTitle')));
      await t.tap(find.byKey(const Key('miniTitle')));
      await pumpUntil(t, find.byType(ABControls));

      final ab = find.byType(ABControls);
      // The widget exposes its buttons by tooltip / label; find "A" then "B".
      await t.tap(find.descendant(of: ab, matching: find.text('A')).first);
      // Let the fake engine's clock move on so B lands after A.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await t.pump();
      await t.tap(find.descendant(of: ab, matching: find.text('B')).first);
      await pumpUntil(
        t,
        find.byWidgetPredicate((w) => w is ABControls && w.ab.isSet),
      );
      expect(engine.requests.where((r) => r.type == Cmd.abSetA), isNotEmpty);
      expect(engine.requests.where((r) => r.type == Cmd.abSetB), isNotEmpty);
      expect(engine.state.ab.isSet, isTrue);
      expect(engine.state.ab.b, greaterThan(engine.state.ab.a));
    }),
  );

  testWidgets(
    'queue tab lists tracks and move reaches the engine',
    (t) => t.runAsync(() async {
      await pairManually(t);
      await openSingles(t);
      await pumpUntil(t, find.byKey(const Key('playFolder')));
      await t.tap(find.byKey(const Key('playFolder')));
      await pumpUntil(t, find.byKey(const Key('miniTitle')));

      // Singles holds one track; the FakeEngine cannot browse into artist
      // folders, so enqueue the rest of the demo library via the client.
      await container
          .read(clientProvider)
          .queueAdd(engine.tracks.map((x) => x.path).toList());
      await t.tap(find.text('Queue'));
      await pumpUntil(
        t,
        find.byWidgetPredicate(
          (w) => w is QueueList && w.queue.tracks.length > 1,
        ),
      );
      final list = t.widget<QueueList>(find.byType(QueueList));
      expect(list.queue.tracks.length, greaterThan(1));
      // Drive the callback the same way a drag would.
      list.onMove!(0, 1);
      await pumpUntil(
        t,
        find.byWidgetPredicate(
          (w) =>
              w is QueueList &&
              w.queue.tracks.first.path == list.queue.tracks[1].path,
        ),
      );
      expect(engine.requests.where((r) => r.type == Cmd.queueMove), isNotEmpty);
    }),
  );

  testWidgets(
    'discovered engine appears and Forget removes a saved one',
    (t) => t.runAsync(() async {
      store.engines = [
        SavedEngine(host: '10.0.0.5', port: 7777, name: 'Old PC', token: 'x'),
      ];
      await t.pumpWidget(app());
      await pumpUntil(
        t,
        find.byKey(ValueKey('found:127.0.0.1:${engine.port}')),
      );
      expect(find.byKey(const ValueKey('saved:10.0.0.5:7777')), findsOneWidget);
      await t.tap(find.byIcon(Icons.delete_outline).first);
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await t.pump();
      expect(find.byKey(const ValueKey('saved:10.0.0.5:7777')), findsNothing);
      expect(store.engines, isEmpty);
    }),
  );

  test('PairingInfo parses the desktop QR payload', () {
    final p = PairingInfo.parse(
      'ol1nplay://192.168.1.20:7777/?token=abc123&http=7778&name=Studio%20PC',
    );
    expect(p, isNotNull);
    expect(p!.host, '192.168.1.20');
    expect(p.port, 7777);
    expect(p.token, 'abc123');
    expect(p.httpPort, 7778);
    expect(p.name, 'Studio PC');
    expect(p.wsUri.toString(), 'ws://192.168.1.20:7777/ws');
    final e = SavedEngine.fromPairing(p);
    expect(e.id, '192.168.1.20:7777');
    expect(SavedEngine.fromJson(e.toJson(), token: e.token).pairing, p);
    expect(PairingInfo.parse('https://example.com'), isNull);
  });
}
