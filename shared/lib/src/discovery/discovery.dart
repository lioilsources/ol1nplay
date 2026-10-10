import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

import 'pairing.dart';

/// An engine seen on the LAN.
class DiscoveredEngine {
  const DiscoveredEngine({
    required this.name,
    required this.host,
    required this.port,
    this.httpPort = 0,
    this.manual = false,
  });

  final String name;
  final String host;
  final int port;
  final int httpPort;

  /// Entered by hand rather than found via mDNS.
  final bool manual;

  /// A pairing without a token; the user still has to scan / type it.
  PairingInfo toPairing({String token = ''}) => PairingInfo(
    host: host,
    port: port,
    token: token,
    httpPort: httpPort,
    name: name,
  );

  @override
  String toString() => '$name @ $host:$port';

  @override
  bool operator ==(Object other) =>
      other is DiscoveredEngine && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

/// Finds engines. Abstract so tests and the desktop app (which only ever
/// talks to localhost) can substitute a static implementation.
abstract class EngineDiscovery {
  /// Service type the engine advertises.
  static const serviceType = '_ol1nplay._tcp';

  /// Default engine port when nothing better is known.
  static const defaultPort = 7777;

  /// Emits every engine found until [timeout] elapses; the stream then closes.
  Stream<DiscoveredEngine> discover({
    Duration timeout = const Duration(seconds: 4),
  });

  /// Builds an entry from a user-typed "host[:port]".
  static DiscoveredEngine? manual(String input, {String name = 'Manual'}) {
    final s = input.trim();
    if (s.isEmpty) return null;
    final p = PairingInfo.parse(s);
    if (p != null) {
      return DiscoveredEngine(
        name: p.name.isEmpty ? name : p.name,
        host: p.host,
        port: p.port,
        httpPort: p.httpPort,
        manual: true,
      );
    }
    var host = s;
    var port = defaultPort;
    final i = s.lastIndexOf(':');
    if (i > 0 && !s.contains(']') && s.indexOf(':') == i) {
      host = s.substring(0, i);
      port = int.tryParse(s.substring(i + 1)) ?? defaultPort;
    }
    if (host.isEmpty) return null;
    return DiscoveredEngine(name: name, host: host, port: port, manual: true);
  }
}

/// mDNS implementation over `multicast_dns`.
class MdnsEngineDiscovery extends EngineDiscovery {
  MdnsEngineDiscovery({MDnsClient Function()? clientFactory})
    : _factory = clientFactory ?? MDnsClient.new;

  final MDnsClient Function() _factory;

  @override
  Stream<DiscoveredEngine> discover({
    Duration timeout = const Duration(seconds: 4),
  }) {
    final ctl = StreamController<DiscoveredEngine>();
    final seen = <DiscoveredEngine>{};
    () async {
      final client = _factory();
      try {
        await client.start();
        final deadline = DateTime.now().add(timeout);
        await for (final ptr
            in client
                .lookup<PtrResourceRecord>(
                  ResourceRecordQuery.serverPointer(
                    EngineDiscovery.serviceType,
                  ),
                )
                .timeout(timeout, onTimeout: (s) => s.close())) {
          if (DateTime.now().isAfter(deadline)) break;
          await for (final srv
              in client
                  .lookup<SrvResourceRecord>(
                    ResourceRecordQuery.service(ptr.domainName),
                  )
                  .timeout(
                    const Duration(seconds: 1),
                    onTimeout: (s) => s.close(),
                  )) {
            var httpPort = 0;
            await for (final txt
                in client
                    .lookup<TxtResourceRecord>(
                      ResourceRecordQuery.text(ptr.domainName),
                    )
                    .timeout(
                      const Duration(milliseconds: 500),
                      onTimeout: (s) => s.close(),
                    )) {
              for (final line in txt.text.split('\n')) {
                if (line.startsWith('http=')) {
                  httpPort = int.tryParse(line.substring(5)) ?? 0;
                }
              }
            }
            // Prefer an IPv4 address; fall back to the SRV target host name.
            var host = srv.target;
            await for (final a
                in client
                    .lookup<IPAddressResourceRecord>(
                      ResourceRecordQuery.addressIPv4(srv.target),
                    )
                    .timeout(
                      const Duration(milliseconds: 500),
                      onTimeout: (s) => s.close(),
                    )) {
              host = a.address.address;
              break;
            }
            final e = DiscoveredEngine(
              name: _instanceName(ptr.domainName),
              host: host,
              port: srv.port,
              httpPort: httpPort,
            );
            if (seen.add(e) && !ctl.isClosed) ctl.add(e);
          }
        }
      } catch (e) {
        if (!ctl.isClosed) ctl.addError(e);
      } finally {
        client.stop();
        await ctl.close();
      }
    }();
    return ctl.stream;
  }

  static String _instanceName(String domain) {
    final i = domain.indexOf('.${EngineDiscovery.serviceType}');
    return i > 0 ? domain.substring(0, i) : domain;
  }
}

/// Returns a fixed list – for tests and for the desktop app, whose engine is
/// always on localhost.
class StaticEngineDiscovery extends EngineDiscovery {
  StaticEngineDiscovery(this.engines);

  final List<DiscoveredEngine> engines;

  @override
  Stream<DiscoveredEngine> discover({
    Duration timeout = const Duration(seconds: 4),
  }) => Stream.fromIterable(engines);
}
