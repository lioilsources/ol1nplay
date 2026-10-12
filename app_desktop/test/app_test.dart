import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ol1nplay_desktop/app.dart';
import 'package:ol1nplay_desktop/core/actions.dart';
import 'package:ol1nplay_desktop/core/engine_target.dart';
import 'package:ol1nplay_desktop/core/prefs.dart';
import 'package:ol1nplay_desktop/core/providers.dart';
import 'package:ol1nplay_desktop/features/output/device_menu.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Widget tests against the shared FakeEngine (a real localhost WebSocket
/// server), so the whole client path is exercised. Socket I/O needs real
/// async: every wait goes through [settle].
void main() {
  late FakeEngine engine;
  late Prefs prefs;
  late ProviderContainer container;

  setUp(() async {
    engine = FakeEngine(tick: const Duration(milliseconds: 50));
    await engine.start();
    SharedPreferences.setMockInitialValues({});
    prefs = await Prefs.memory();
    container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        engineTargetProvider.overrideWithValue(
          EngineTarget(uri: engine.wsUri, token: '', local: false),
        ),
        desktopIntegrationProvider.overrideWithValue(false),
        // The 1 s stats poll would outlive the widget tree and trip the
        // binding's pending-timer check; the counters are not under test.
        outputStatsProvider.overrideWith(
          (ref) => const Stream<OutputStats>.empty(),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await engine.stop();
  });

  /// Real time for the socket, then fake time for gesture arenas (the
  /// double-tap recogniser holds single taps for 300 ms) and animations.
  Future<void> settle(WidgetTester tester, [int ms = 300]) async {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const Ol1nPlayApp(),
      ),
    );
    await tester.pump();
    // Waiting screen first, then the shell once hello succeeds.
    expect(find.textContaining('Connecting'), findsOneWidget);
    for (var i = 0; i < 20; i++) {
      await settle(tester, 150);
      if (container.read(connectionProvider) == ConnectionStatus.connected) {
        break;
      }
    }
    await settle(tester, 200);
    expect(container.read(connectionProvider), ConnectionStatus.connected);
  }

  Future<void> openAlbum(WidgetTester tester) async {
    // Expand the root: the fake's tree only knows folders that hold tracks
    // directly, so "Singles" is its one visible child. Then jump to the
    // album folder the way a tree click would.
    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await settle(tester);
    expect(find.text('Singles'), findsOneWidget);
    container
        .read(selectedDirProvider.notifier)
        .select('/fake/Music/Nina Simone/Pastel Blues');
    await settle(tester);
    expect(find.textContaining('Pastel Blues'), findsWidgets);
  }

  testWidgets('connects and shows the demo library tree', (tester) async {
    await boot(tester);
    expect(find.text('/fake/Music'), findsOneWidget);
    expect(find.text('Nothing playing'), findsOneWidget);
    expect(find.text('Folder'), findsOneWidget); // middle tabs
    expect(
      find.textContaining('127.0.0.1'),
      findsOneWidget,
    ); // status bar target
  });

  testWidgets('folder listing, double-click plays, now playing shows badge', (
    tester,
  ) async {
    await boot(tester);
    await openAlbum(tester);
    expect(find.byType(TrackTile), findsWidgets);
    final first = engine.tracks.firstWhere((t) => t.album == 'Pastel Blues');
    final tile = find.widgetWithText(TrackTile, first.title).first;
    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(tile);
    await settle(tester, 400);
    expect(engine.requests.any((r) => r.type == Cmd.play), isTrue);
    expect(engine.state.isPlaying, isTrue);
    expect(find.byType(FormatBadge), findsWidgets);
    expect(find.textContaining('bit-perfect'), findsWidgets);
    expect(find.text(first.title), findsWidgets);
  });

  testWidgets('search filters the middle pane and Esc clears', (tester) async {
    await boot(tester);
    await tester.enterText(find.byKey(const Key('search-field')), 'amber');
    await settle(tester, 500);
    expect(find.textContaining('Search: amber'), findsOneWidget);
    expect(engine.requests.any((r) => r.type == Cmd.librarySearch), isTrue);
    final hits = engine.tracks.where(
      (t) => t.album.toLowerCase().contains('amber'),
    );
    expect(find.byType(TrackTile), findsNWidgets(hits.length));
    await tester.tap(find.byTooltip('Clear (Esc)'));
    await settle(tester);
    expect(find.textContaining('Search:'), findsNothing);
  });

  testWidgets('A-B set and clear reach the engine', (tester) async {
    await boot(tester);
    await openAlbum(tester);
    final tile = find.byType(TrackTile).first;
    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(tile);
    await settle(tester, 400);
    expect(engine.state.isPlaying, isTrue);

    await tester.tap(find.widgetWithText(FilledButton, 'A'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'B'));
    await settle(tester);
    expect(engine.requests.where((r) => r.type == Cmd.abSetA), isNotEmpty);
    expect(engine.requests.where((r) => r.type == Cmd.abSetB), isNotEmpty);
    expect(engine.state.ab.hasA, isTrue);
    expect(engine.state.ab.hasB, isTrue);

    await tester.tap(find.byTooltip('Clear A-B'));
    await settle(tester);
    expect(engine.requests.where((r) => r.type == Cmd.abClear), isNotEmpty);
    expect(engine.state.ab.isSet, isFalse);
  });

  testWidgets('device dialog lists devices grouped by backend', (tester) async {
    await boot(tester);
    await tester.tap(find.byType(DeviceButton));
    await settle(tester, 400);
    expect(find.text('Output device'), findsOneWidget);
    expect(find.text('Fake DAC'), findsOneWidget);
    expect(find.text('No output'), findsOneWidget); // backend "null" title
    expect(find.textContaining('44.1k'), findsOneWidget);
    await tester.tap(find.text('Fake DAC'));
    await settle(tester);
    expect(engine.requests.any((r) => r.type == Cmd.deviceSelect), isTrue);
  });

  testWidgets('queue tab shows the playing album and survives a reconnect', (
    tester,
  ) async {
    await boot(tester);
    await openAlbum(tester);
    await tester.tap(find.byTooltip('Play folder'));
    await settle(tester, 400);
    await tester.tap(find.text('Queue'));
    await settle(tester);
    expect(find.byType(QueueList), findsOneWidget);
    expect(find.byType(TrackTile), findsWidgets);

    // Engine goes away: banner appears, app keeps running; comes back.
    final port = engine.port;
    await tester.runAsync(engine.stop);
    await settle(tester, 500);
    expect(find.textContaining('reconnecting'), findsOneWidget);
    engine = FakeEngine(tick: const Duration(milliseconds: 50));
    await tester.runAsync(() => engine.start(port: port));
    for (var i = 0; i < 40; i++) {
      await settle(tester, 250);
      if (container.read(connectionProvider) == ConnectionStatus.connected) {
        break;
      }
    }
    await settle(tester);
    expect(find.textContaining('reconnecting'), findsNothing);
    // Requests issued while the socket was down carry a 10 s timeout timer
    // in the fake zone; let them expire before the binding checks.
    await tester.pump(const Duration(seconds: 11));
    // …and give the refetches that expiry triggers real time to be answered.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
  });

  test('EngineTarget parses overrides', () {
    final t = EngineTarget.fromOverride('ws://10.0.0.5:7777/ws?token=abc')!;
    expect(t.uri.toString(), 'ws://10.0.0.5:7777/ws');
    expect(t.token, 'abc');
    expect(t.local, isFalse);
    final h = EngineTarget.fromOverride('192.168.1.2')!;
    expect(h.uri.port, 7777);
    expect(h.uri.path, '/ws');
    final p = EngineTarget.fromOverride(
      'ol1nplay://127.0.0.1:7777/?token=t&http=7778',
    )!;
    expect(p.local, isTrue);
    expect(p.token, 't');
    expect(EngineTarget.fromOverride(''), isNull);
  });
  testWidgets('seek strip: the mono switch has four positions and M cycles', (
    tester,
  ) async {
    await boot(tester);
    final client = container.read(clientProvider);
    final tracks = FakeEngine.demoTracks();
    // Fired, not awaited: the reply only arrives while settle() gives the
    // socket real time.
    unawaited(client.playPaths(tracks.map((t) => t.path).toList(), index: 0));
    await settle(tester);
    await settle(tester);
    expect(find.byKey(const ValueKey('seekStrip')), findsOneWidget);
    // The strip spans the window, not just the right-hand pane.
    expect(
      tester.getSize(find.byKey(const ValueKey('seekStrip'))).width,
      greaterThan(700),
    );
    // Once the track is known its loudness overview is fetched.
    expect(container.read(waveformProvider).value?.isEmpty, isFalse);

    final sw = find.byKey(const ValueKey('monoSwitch'));
    await tester.tap(find.descendant(of: sw, matching: find.text('L')));
    await settle(tester);
    expect(container.read(stateProvider).monoMode, MonoMode.left);
    expect(container.read(stateProvider).mono, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM); // left → right
    await settle(tester);
    expect(container.read(stateProvider).monoMode, MonoMode.right);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM); // right → stereo
    await settle(tester);
    expect(container.read(stateProvider).monoMode, MonoMode.stereo);
  });

  testWidgets('folder view can show only the hearted tracks', (tester) async {
    await boot(tester);
    await openAlbum(tester);
    final listing = container
        .read(listingProvider('/fake/Music/Nina Simone/Pastel Blues'))
        .value!;
    expect(listing.tracks.length, greaterThan(1));
    final fav = listing.tracks.first;
    final other = listing.tracks.last;
    // No hearts yet: nothing to filter by, so no button.
    expect(find.byKey(const ValueKey('favoritesOnly')), findsNothing);

    unawaited(container.read(actionsProvider).favorite(null, fav.path, true));
    await settle(tester);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('favoritesOnly')));
    await settle(tester);
    expect(find.text(fav.displayTitle), findsWidgets);
    expect(find.text(other.displayTitle), findsNothing);

    await tester.tap(find.byKey(const ValueKey('favoritesOnly')));
    await settle(tester);
    expect(find.text(other.displayTitle), findsWidgets);
  });
}
