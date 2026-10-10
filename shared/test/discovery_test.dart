import 'package:flutter_test/flutter_test.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

void main() {
  group('PairingInfo', () {
    test('parses the QR payload', () {
      final p = PairingInfo.parse(
        'ol1nplay://192.168.1.20:7777/?token=abc123&http=7778&name=Studio',
      );
      expect(p, isNotNull);
      expect(p!.host, '192.168.1.20');
      expect(p.port, 7777);
      expect(p.token, 'abc123');
      expect(p.httpPort, 7778);
      expect(p.name, 'Studio');
      expect(p.wsUri, Uri.parse('ws://192.168.1.20:7777/ws'));
    });

    test('defaults the port and tolerates whitespace', () {
      final p = PairingInfo.parse('  ol1nplay://host/?token=t ');
      expect(p?.port, 7777);
      expect(p?.httpPort, 0);
    });

    test('rejects other schemes', () {
      expect(PairingInfo.parse('https://example.com'), isNull);
      expect(PairingInfo.parse('garbage'), isNull);
      expect(PairingInfo.parse(''), isNull);
    });

    test('round-trips through toUri', () {
      const p = PairingInfo(
        host: 'h',
        port: 1234,
        token: 't',
        httpPort: 1235,
        name: 'n',
      );
      expect(PairingInfo.parse(p.toUri().toString()), p);
      expect(PairingInfo.parse(p.toString()), p);
    });
  });

  group('EngineDiscovery', () {
    test('manual entry parses host[:port] and pairing URIs', () {
      expect(
        EngineDiscovery.manual('10.0.0.5')?.port,
        EngineDiscovery.defaultPort,
      );
      final e = EngineDiscovery.manual('10.0.0.5:8000');
      expect(e?.host, '10.0.0.5');
      expect(e?.port, 8000);
      expect(e?.manual, isTrue);
      expect(
        EngineDiscovery.manual('ol1nplay://box:7000/?token=x')?.port,
        7000,
      );
      expect(EngineDiscovery.manual(''), isNull);
    });

    test('static discovery streams the list', () async {
      final d = StaticEngineDiscovery(const [
        DiscoveredEngine(name: 'a', host: 'h', port: 1),
      ]);
      expect(await d.discover().toList(), hasLength(1));
      expect(
        const DiscoveredEngine(
          name: 'a',
          host: 'h',
          port: 1,
        ).toPairing(token: 't').token,
        't',
      );
    });
  });
}
