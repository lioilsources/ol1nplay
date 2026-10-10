import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

/// Fixtures shaped exactly like the Go `json` tags produce them, including
/// omitted zero fields.
const _trackJson = {
  'path': r'D:\Music\Nina Simone\Pastel Blues\01 Be My Husband.flac',
  'dir': r'D:\Music\Nina Simone\Pastel Blues',
  'fileName': '01 Be My Husband.flac',
  'title': 'Be My Husband',
  'artist': 'Nina Simone',
  'album': 'Pastel Blues',
  'trackNo': 1,
  'year': 1965,
  'codec': 'flac',
  'container': 'flac',
  'sampleRate': 96000,
  'bitDepth': 24,
  'channels': 2,
  'lossless': true,
  'dsd': false,
  'bitrate': 0,
  'durationMs': 184000,
  'samples': 17664000,
  'sizeBytes': 61234567,
  'modTime': 1700000000000,
  'cover': 'a1b2c3d4e5f60718',
  'favorite': false,
  'playCount': 3,
  'hasLyrics': true,
};

const _stateJson = {
  'playback': 'playing',
  'track': _trackJson,
  'position': 441000,
  'positionMs': 4593,
  'duration': 17664000,
  'durationMs': 184000,
  'source': {
    'sampleRate': 96000,
    'bitDepth': 24,
    'channels': 2,
    'sampleFormat': 's24',
  },
  'output': {
    'backend': 'asio',
    'device': 'RME ADI-2 DAC',
    'deviceId': 'ASIO MADIface USB',
    'status': 'running',
    'format': {
      'sampleRate': 96000,
      'bitDepth': 32,
      'channels': 2,
      'sampleFormat': 's32',
    },
    'bufferFrames': 256,
    'latencyMs': 2.67,
    'bitPerfect': true,
    'conversion': '24→32 bit zero-padded',
    'underruns': 0,
    'exclusive': true,
    'nativeDSD': false,
    'dop': false,
  },
  'mono': false,
  'ab': {
    'a': 96000,
    'b': 960000,
    'active': true,
    'enabled': true,
    'aMs': 1000,
    'bMs': 10000,
  },
  'repeat': 'off',
  'shuffle': false,
  'queueIndex': 0,
  'queueLen': 12,
  'preloaded': true,
  'ramBytes': 141312000,
  'gain': '0 dB',
  'sysmode': {
    'enabled': false,
    'powerPlan': true,
    'usbSuspend': true,
    'coreParking': false,
    'processPriority': true,
    'suspendProcesses': ['OneDrive.exe'],
    'killProcesses': [],
    'stopServices': [],
    'pinCore': -1,
    'timer1ms': true,
    'applied': false,
    'available': true,
    'changes': [],
    'template': ['SearchIndexer.exe', 'OneDrive.exe'],
  },
  'remote': {
    'enabled': true,
    'port': 7777,
    'httpPort': 7778,
    'addresses': ['192.168.1.20'],
    'clients': 1,
    'mdns': true,
  },
};

void main() {
  group('Track', () {
    test('round-trips and derives labels', () {
      final t = Track.fromJson(_trackJson);
      expect(t.title, 'Be My Husband');
      expect(t.displayTitle, 'Be My Husband');
      expect(t.formatBadge, 'FLAC 24/96k');
      expect(t.codecLabel, 'FLAC');
      expect(t.duration, const Duration(seconds: 184));
      final back = Track.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
      );
      expect(back.toJson(), t.toJson());
      expect(back, t);
    });

    test('untagged track falls back to file name', () {
      final t = Track.fromJson({
        'path': '/x/y/03 Something.wav',
        'fileName': '03 Something.wav',
        'codec': 'pcm_s16le',
        'container': 'wav',
        'bitDepth': 16,
        'sampleRate': 44100,
        'lossless': true,
      });
      expect(t.displayTitle, '03 Something');
      expect(t.formatBadge, 'WAV 16/44.1k');
    });

    test('lossy and DSD badges', () {
      final mp3 = Track.fromJson({
        'path': 'a.mp3',
        'codec': 'mp3',
        'bitrate': 320,
        'sampleRate': 44100,
      });
      expect(mp3.formatBadge, 'MP3 320');
      final dsd = Track.fromJson({
        'path': 'a.dsf',
        'codec': 'dsd_lsbf_planar',
        'dsd': true,
        'sampleRate': 2822400,
        'lossless': true,
      });
      expect(dsd.formatBadge, 'DSD64');
      expect(dsdLabel(5644800), 'DSD128');
    });
  });

  group('EngineState', () {
    test('parses the full snapshot', () {
      final s = EngineState.fromJson(_stateJson);
      expect(s.isPlaying, isTrue);
      expect(s.track?.artist, 'Nina Simone');
      expect(s.output.backendLabel, 'ASIO');
      expect(s.output.bitPerfect, isTrue);
      expect(s.output.format.short, '32/96k');
      expect(s.source.short, '24/96k');
      expect(s.ab.active, isTrue);
      expect(s.ab.bMs, 10000);
      expect(s.remote.addresses, ['192.168.1.20']);
      expect(s.sysmode.template, hasLength(2));
      expect(s.progress, closeTo(4593 / 184000, 1e-9));
      expect(s.sleep, isNull);
      expect(s.lyrics, isNull);
    });

    test('round-trips through JSON', () {
      final s = EngineState.fromJson(_stateJson);
      final back = EngineState.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(back.toJson(), s.toJson());
    });

    test('empty object yields safe defaults', () {
      final s = EngineState.fromJson(const {});
      expect(s.isStopped, isTrue);
      expect(s.track, isNull);
      expect(s.ab.hasA, isFalse);
      expect(s.gain, '0 dB');
      expect(s.queueIndex, -1);
      expect(s.output.status, OutputStatus.closed);
    });

    test('copyWith clears optionals explicitly', () {
      final s = EngineState.fromJson(_stateJson);
      expect(s.copyWith(clearTrack: true).track, isNull);
      expect(s.copyWith(mono: true).mono, isTrue);
      expect(
        s
            .copyWith(sleep: const SleepTimer(endsAt: 5))
            .copyWith(clearSleep: true)
            .sleep,
        isNull,
      );
    });
  });

  group('smaller models', () {
    test('Queue', () {
      final q = Queue.fromJson({
        'index': 1,
        'tracks': [_trackJson, _trackJson],
        'shuffle': true,
        'repeat': 'all',
      });
      expect(q.current, isNotNull);
      expect(q.length, 2);
      expect(Queue.fromJson(q.toJson()).toJson(), q.toJson());
    });

    test('Device uses the "default" wire key', () {
      final d = Device.fromJson({
        'backend': 'asio',
        'id': 'x',
        'name': 'DAC',
        'default': true,
        'sampleRates': [44100, 96000],
      });
      expect(d.isDefault, isTrue);
      expect(d.toJson()['default'], isTrue);
      expect(d.sampleRates, [44100, 96000]);
    });

    test('Settings patch only carries changes', () {
      const base = Settings(mono: false, theme: 'system', roots: ['/a']);
      final next = base.copyWith(mono: true, roots: ['/a', '/b']);
      final p = next.toPatch(base);
      expect(p.keys.toSet(), {'mono', 'roots'});
      expect(Settings.fromJson(const {}).theme, 'system');
      expect(Settings.fromJson(base.toJson()).toJson(), base.toJson());
    });

    test('Sysmode copyWith and round-trip', () {
      final s = Sysmode.fromJson(_stateJson['sysmode'] as Map<String, dynamic>);
      expect(s.copyWith(enabled: true).enabled, isTrue);
      expect(Sysmode.fromJson(s.toJson()).toJson(), s.toJson());
    });

    test('Listing, DirNode, Root, CueSheet', () {
      final l = Listing.fromJson({
        'dir': '/m/a',
        'parent': '/m',
        'dirs': [
          {'path': '/m/a/b', 'name': 'b', 'hasDirs': false, 'tracks': 3},
        ],
        'tracks': [_trackJson],
        'cover': 'abc',
        'cue': [
          {
            'path': '/m/a/x.cue',
            'title': 'X',
            'file': 'x.flac',
            'tracks': [_trackJson],
          },
        ],
      });
      expect(l.dirs.single.name, 'b');
      expect(l.cue.single.tracks, hasLength(1));
      expect(l.totalDuration.inSeconds, 184);
      expect(Listing.fromJson(l.toJson()).toJson(), l.toJson());
      final r = Root.fromJson({
        'path': r'D:\Music',
        'tracks': 5,
        'missing': true,
      });
      expect(r.name, 'Music');
      expect(r.missing, isTrue);
    });

    test('Lyrics active index', () {
      final l = Lyrics.fromJson({
        'source': 'lrc',
        'lines': [
          {'ms': 0, 'text': 'a'},
          {'ms': 1000, 'text': 'b'},
          {'ms': 2000, 'text': 'c'},
        ],
      });
      expect(l.isTimed, isTrue);
      expect(l.activeIndex(-1), -1);
      expect(l.activeIndex(0), 0);
      expect(l.activeIndex(1500), 1);
      expect(l.activeIndex(9999), 2);
      expect(Lyrics.fromJson(l.toJson()).lines.length, 3);
    });

    test(
      'Format, OutputStats, ABLoop, RemoteInfo, LogLine, HistoryEntry, Playlist, CoverRef, ScanProgress, LibraryChange, SysmodeLogEntry, ServerInfo, SleepTimer',
      () {
        expect(
          Format.fromJson(const {
            'sampleRate': 44100,
            'bitDepth': 16,
            'channels': 2,
            'sampleFormat': 's16',
          }).short,
          '16/44.1k',
        );
        expect(
          Format.fromJson(const {
            'sampleRate': 48000,
            'channels': 2,
            'sampleFormat': 'f32',
          }).short,
          '32f/48k',
        );
        expect(
          Format.fromJson(const {
            'sampleFormat': 'dop',
            'dsdRate': 2822400,
          }).short,
          'DSD64',
        );
        final os = OutputStats.fromJson(const {
          'underruns': 2,
          'callbacks': 100,
          'ringFillPct': 88.5,
          'maxCallbackUs': 120,
          'threadPriority': 'Pro Audio/critical',
          'cpuCore': 7,
        });
        expect(OutputStats.fromJson(os.toJson()).cpuCore, 7);
        expect(OutputStats.fromJson(const {}).cpuCore, -1);
        expect(ABLoop.fromJson(const {}).isSet, isFalse);
        expect(ABLoop.fromJson(const {'a': 0, 'b': 10}).isSet, isTrue);
        final ri = RemoteInfo.fromJson(const {
          'enabled': true,
          'port': 7777,
          'token': 't',
          'qr': 'ol1nplay://h:7777/?token=t',
        });
        expect(RemoteInfo.fromJson(ri.toJson()).qr, ri.qr);
        expect(
          LogLine.fromJson(const {'level': 'error', 'msg': 'x'}).isError,
          isTrue,
        );
        final h = HistoryEntry.fromJson({
          'track': _trackJson,
          'playedAt': 5,
          'complete': true,
        });
        expect(HistoryEntry.fromJson(h.toJson()).complete, isTrue);
        expect(
          Playlist.fromJson(const {
            'path': '/p.m3u8',
            'name': 'p',
            'count': 4,
          }).count,
          4,
        );
        expect(
          CoverRef.fromJson(const {'hash': 'h', 'url': '/cover/h.jpg'}).url,
          '/cover/h.jpg',
        );
        expect(
          ScanProgress.fromJson(const {'done': 5, 'total': 10}).fraction,
          0.5,
        );
        expect(
          LibraryChange.fromJson(const {
            'dir': '/a',
            'reason': 'fsnotify',
          }).reason,
          'fsnotify',
        );
        expect(
          SysmodeLogEntry.fromJson(const {
            'at': 1,
            'action': 'apply',
            'target': 'powercfg',
          }).target,
          'powercfg',
        );
        final si = ServerInfo.fromJson(const {
          'name': 'Ol1nPlay',
          'version': '1.0',
          'protocolVersion': 1,
          'httpPort': 7778,
          'backends': ['asio', 'wasapi'],
        });
        expect(ServerInfo.fromJson(si.toJson()).backends, ['asio', 'wasapi']);
        final st = SleepTimer(
          endsAt: DateTime.now().millisecondsSinceEpoch + 60000,
          minutes: 1,
        );
        expect(st.remaining.inSeconds, inInclusiveRange(55, 60));
      },
    );
  });

  group('envelopes', () {
    test('Request serialises bool under the wire name and drops nulls', () {
      final r = Request(id: 7, type: Cmd.mono, flag: true);
      final j = r.toJson();
      expect(j, {'id': 7, 'type': 'mono', 'bool': true});
      final back = Request.fromJson(j);
      expect(back.flag, isTrue);
      expect(back.path, isNull);
    });

    test('Response and Event parse', () {
      final r = Response.fromJson(const {
        'id': 1,
        'type': 'result',
        'ok': false,
        'error': 'nope',
      });
      expect(r.ok, isFalse);
      expect(r.error, 'nope');
      final e = Event.fromJson({'type': Ev.state, 'data': _stateJson});
      expect(e.type, Ev.state);
      expect(e.dataMap['playback'], 'playing');
    });

    test('Repeat cycles', () {
      expect(Repeat.nextOf(Repeat.off), Repeat.all);
      expect(Repeat.nextOf(Repeat.all), Repeat.one);
      expect(Repeat.nextOf(Repeat.one), Repeat.off);
    });
  });

  group('fmt', () {
    test('durations', () {
      expect(fmtDuration(0), '0:00');
      expect(fmtDuration(184000), '3:04');
      expect(fmtDuration(3765000), '1:02:45');
      expect(fmtDuration(-1), '–:––');
      expect(fmtDurationMs(1250), '0:01.250');
    });
    test('bytes and hz', () {
      expect(fmtBytes(512), '512 B');
      expect(fmtBytes(141312000), '134.8 MB');
      expect(fmtHz(44100), '44.1 kHz');
      expect(fmtHz(96000), '96 kHz');
      expect(fmtHz(2822400), '2.8224 MHz');
    });
  });
}
