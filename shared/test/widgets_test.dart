import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: Ol1nTheme.dark(),
  home: Scaffold(body: Center(child: child)),
);

final _track = FakeEngine.demoTracks().first;

EngineState _playing({
  int positionMs = 4000,
  ABLoop ab = ABLoop.none,
  Lyrics? lyrics,
}) => EngineState(
  playback: Playback.playing,
  track: _track,
  positionMs: positionMs,
  position: positionMs * 96,
  durationMs: _track.durationMs,
  duration: _track.samples,
  source: const Format(
    sampleRate: 96000,
    bitDepth: 24,
    channels: 2,
    sampleFormat: 's24',
  ),
  output: const Output(
    backend: 'asio',
    device: 'DAC',
    status: OutputStatus.running,
    format: Format(
      sampleRate: 96000,
      bitDepth: 32,
      channels: 2,
      sampleFormat: 's32',
    ),
    bufferFrames: 256,
    bitPerfect: true,
    conversion: '24→32 bit zero-padded',
  ),
  ab: ab,
  lyrics: lyrics,
);

void main() {
  testWidgets('FormatBadge shows source → output · bit-perfect', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(FormatBadge(state: _playing())));
    expect(find.textContaining('FLAC 24/96k'), findsOneWidget);
    expect(find.textContaining('ASIO 32-bit'), findsOneWidget);
    expect(find.textContaining('bit-perfect'), findsOneWidget);
    expect(find.text('24→32 bit zero-padded'), findsOneWidget);

    await tester.pumpWidget(_wrap(const FormatBadge(state: EngineState())));
    expect(find.textContaining('idle'), findsOneWidget);
  });

  testWidgets('TransportBar fires callbacks and reflects state', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(
      _wrap(
        TransportBar(
          state: _playing(),
          onPrev: () => log.add('prev'),
          onToggle: () => log.add('toggle'),
          onNext: () => log.add('next'),
          onStop: () => log.add('stop'),
          onMono: (v) => log.add('mono:$v'),
          onRepeat: (m) => log.add('repeat:$m'),
          onShuffle: (v) => log.add('shuffle:$v'),
        ),
      ),
    );
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.tap(find.byIcon(Icons.skip_next_rounded));
    await tester.tap(find.byIcon(Icons.skip_previous_rounded));
    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.tap(find.text('M'));
    await tester.tap(find.byIcon(Icons.repeat_rounded));
    await tester.tap(find.byIcon(Icons.shuffle_rounded));
    expect(log, [
      'toggle',
      'next',
      'prev',
      'stop',
      'mono:true',
      'repeat:all',
      'shuffle:true',
    ]);
  });

  testWidgets('SeekBar shows times and emits a seek on tap', (tester) async {
    int? seeked;
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 400,
          child: SeekBar(
            state: _playing(
              ab: const ABLoop(
                a: 96000,
                b: 960000,
                aMs: 1000,
                bMs: 10000,
                enabled: true,
                active: true,
              ),
            ),
            onSeekMs: (ms) => seeked = ms,
          ),
        ),
      ),
    );
    expect(find.text('0:04'), findsOneWidget);
    expect(find.text('0:15'), findsOneWidget);
    final bar = find.byType(CustomPaint).last;
    final r = tester.getRect(bar);
    await tester.tapAt(Offset(r.left + r.width / 2, r.center.dy));
    await tester.pump();
    expect(seeked, isNotNull);
    expect(seeked, closeTo(_track.durationMs / 2, 600));
  });

  testWidgets('ABControls', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(
      _wrap(
        ABControls(
          ab: const ABLoop(
            a: 96000,
            b: 960000,
            aMs: 1000,
            bMs: 10000,
            enabled: true,
            active: true,
          ),
          onSetA: () => log.add('A'),
          onSetB: () => log.add('B'),
          onNudge: (w, ms) => log.add('$w$ms'),
          onToggle: (v) => log.add('t$v'),
          onClear: () => log.add('clear'),
        ),
      ),
    );
    expect(find.text('0:01.000'), findsOneWidget);
    expect(find.text('0:10.000'), findsOneWidget);
    await tester.tap(find.text('A'));
    await tester.tap(find.text('B'));
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.tap(find.byIcon(Icons.remove).last);
    await tester.tap(find.byType(Switch));
    await tester.tap(find.byIcon(Icons.close));
    expect(log, ['A', 'B', 'a10', 'b-10', 'tfalse', 'clear']);
  });

  testWidgets('TrackTile renders and toggles favorite', (tester) async {
    bool? fav;
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 600,
          child: TrackTile(
            track: _track,
            nowPlaying: true,
            playing: true,
            onFavorite: (v) => fav = v,
          ),
        ),
      ),
    );
    expect(find.text(_track.title), findsOneWidget);
    expect(find.text('FLAC 24/96k'), findsOneWidget);
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.favorite_border_rounded));
    expect(fav, isTrue);
  });

  testWidgets('QueueList jump and remove', (tester) async {
    final log = <String>[];
    final q = Queue(index: 0, tracks: FakeEngine.demoTracks().take(3).toList());
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 600,
          height: 400,
          child: QueueList(
            queue: q,
            playing: true,
            onJump: (i) => log.add('jump$i'),
            onRemove: (i) => log.add('rm$i'),
            onMove: (a, b) => log.add('mv$a>$b'),
          ),
        ),
      ),
    );
    await tester.tap(find.text(q.tracks[1].title));
    await tester.tap(find.byIcon(Icons.close).first);
    expect(log, ['jump1', 'rm0']);
    await tester.pumpWidget(_wrap(const QueueList(queue: Queue())));
    expect(find.text('Queue is empty'), findsOneWidget);
  });

  testWidgets('LyricsView highlights and scrolls with position', (
    tester,
  ) async {
    final lyrics = Lyrics(
      source: 'lrc',
      lines: [
        for (var i = 0; i < 60; i++) LyricLine(ms: i * 1000, text: 'line $i'),
      ],
    );
    Widget at(int ms) => _wrap(
      SizedBox(
        width: 400,
        height: 200,
        child: LyricsView(lyrics: lyrics, positionMs: ms),
      ),
    );
    await tester.pumpWidget(at(0));
    expect(find.text('line 0'), findsOneWidget);
    expect(find.text('line 40'), findsNothing);
    await tester.pumpWidget(at(40000));
    await tester.pumpAndSettle();
    expect(find.text('line 40'), findsOneWidget);
    final active = tester.widget<AnimatedDefaultTextStyle>(
      find
          .ancestor(
            of: find.text('line 40'),
            matching: find.byType(AnimatedDefaultTextStyle),
          )
          .first,
    );
    expect(active.style.fontWeight, FontWeight.w600);

    await tester.pumpWidget(
      _wrap(const LyricsView(lyrics: null, positionMs: 0)),
    );
    expect(find.text('No lyrics'), findsOneWidget);
    await tester.pumpWidget(
      _wrap(
        const LyricsView(
          lyrics: Lyrics(text: 'plain words', source: 'txt'),
          positionMs: 0,
        ),
      ),
    );
    expect(find.text('plain words'), findsOneWidget);
  });

  testWidgets(
    'UnderrunIndicator, NoVolumeNotice, TechInfo, CoverImage placeholder',
    (tester) async {
      await tester.pumpWidget(_wrap(const UnderrunIndicator(underruns: 0)));
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
      await tester.pumpWidget(_wrap(const UnderrunIndicator(underruns: 3)));
      expect(find.text('3'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));

      await tester.pumpWidget(_wrap(const NoVolumeNotice()));
      expect(find.textContaining('0 dB'), findsOneWidget);

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 400,
            child: TechInfo(
              state: _playing(),
              stats: const OutputStats(
                threadPriority: 'Pro Audio/critical',
                cpuCore: 7,
                ringFillPct: 90,
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('ASIO · DAC'), findsOneWidget);
      expect(find.textContaining('core 7'), findsOneWidget);

      final client = EngineClient();
      await tester.pumpWidget(
        _wrap(CoverImage(hash: '', client: client, size: 64)),
      );
      expect(find.byIcon(Icons.album_outlined), findsOneWidget);
      await client.dispose();
    },
  );

  test('theme builds both modes and resolves settings', () {
    expect(Ol1nTheme.dark().brightness, Brightness.dark);
    expect(Ol1nTheme.light().brightness, Brightness.light);
    expect(Ol1nTheme.modeOf('dark'), ThemeMode.dark);
    expect(
      Ol1nTheme.modeOfSettings(const Settings(theme: 'light')),
      ThemeMode.light,
    );
    expect(Ol1nTheme.modeOfSettings(null), ThemeMode.system);
  });

  test('black is a dark theme of its own, darker than dark', () {
    const s = Settings(theme: 'black');
    expect(Ol1nTheme.modeOfSettings(s), ThemeMode.dark);
    final black = Ol1nTheme.darkOfSettings(s);
    expect(black.brightness, Brightness.dark);
    expect(black.scaffoldBackgroundColor, const Color(0xFF000000));
    expect(
      Ol1nTheme.darkOfSettings(
        const Settings(theme: 'dark'),
      ).scaffoldBackgroundColor,
      Ol1nTheme.dark().scaffoldBackgroundColor,
    );
  });

  testWidgets('MonoModeSwitch reports the tapped mode', (t) async {
    String? got;
    await t.pumpWidget(
      _wrap(MonoModeSwitch(mode: MonoMode.mono, onChanged: (m) => got = m)),
    );
    await t.tap(find.text('L'));
    expect(got, MonoMode.left);
    await t.tap(find.text('R'));
    expect(got, MonoMode.right);
    await t.tap(find.text('Stereo'));
    expect(got, MonoMode.stereo);
  });

  testWidgets('SeekBar with a waveform still seeks where it is tapped', (
    t,
  ) async {
    int? ms;
    final wave = Waveform(
      path: _track.path,
      peak: Uint8List.fromList(List.generate(64, (i) => i * 4)),
      rms: Uint8List.fromList(List.generate(64, (i) => i * 2)),
    );
    await t.pumpWidget(
      _wrap(
        SizedBox(
          width: 400,
          child: SeekBar(
            state: _playing(),
            showTimes: false,
            height: 44,
            waveform: wave,
            onSeekMs: (v) => ms = v,
          ),
        ),
      ),
    );
    final box = t.getRect(find.byType(SeekBar));
    await t.tapAt(Offset(box.left + box.width * 0.75, box.center.dy));
    expect(ms, closeTo(_track.durationMs * 0.75, _track.durationMs * 0.01));
  });

  test('Waveform survives JSON and tolerates an engine without one', () {
    final w = Waveform(
      path: 'a.flac',
      peak: Uint8List.fromList([0, 128, 255]),
      rms: Uint8List.fromList([0, 64, 200]),
    );
    final back = Waveform.fromJson(w.toJson());
    expect(back.path, 'a.flac');
    expect(back.peak, [0, 128, 255]);
    expect(back.rms, [0, 64, 200]);
    expect(Waveform.fromJson(const {'path': 'a.flac'}).isEmpty, isTrue);
  });

  test('EngineState reads the mono mode, and the bare bool of 0.1', () {
    expect(
      EngineState.fromJson(const {'mono': true, 'monoMode': 'left'}).monoMode,
      MonoMode.left,
    );
    expect(EngineState.fromJson(const {'mono': true}).monoMode, MonoMode.mono);
    expect(EngineState.fromJson(const {}).monoMode, MonoMode.stereo);
  });
}
