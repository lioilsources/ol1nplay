/// What the desktop UI shows in its QR code and the remote scans:
/// `ol1nplay://host:port/?token=...&http=...&name=...`
class PairingInfo {
  const PairingInfo({
    required this.host,
    required this.port,
    this.token = '',
    this.httpPort = 0,
    this.name = '',
  });

  final String host;

  /// WebSocket port.
  final int port;
  final String token;

  /// Cover HTTP port; 0 = ask the engine via `hello`.
  final int httpPort;

  /// Friendly engine / machine name.
  final String name;

  static const scheme = 'ol1nplay';

  /// Parses a pairing URI; returns null for anything that is not one.
  static PairingInfo? parse(String s) {
    final u = Uri.tryParse(s.trim());
    if (u == null || u.scheme != scheme || u.host.isEmpty) return null;
    final port = u.hasPort ? u.port : 7777;
    return PairingInfo(
      host: u.host,
      port: port,
      token: u.queryParameters['token'] ?? '',
      httpPort: int.tryParse(u.queryParameters['http'] ?? '') ?? 0,
      name: u.queryParameters['name'] ?? '',
    );
  }

  Uri toUri() => Uri(
    scheme: scheme,
    host: host,
    port: port,
    path: '/',
    queryParameters: {
      if (token.isNotEmpty) 'token': token,
      if (httpPort != 0) 'http': '$httpPort',
      if (name.isNotEmpty) 'name': name,
    },
  );

  /// The WebSocket endpoint the client connects to.
  Uri get wsUri => Uri(scheme: 'ws', host: host, port: port, path: '/ws');

  @override
  String toString() => toUri().toString();

  @override
  bool operator ==(Object other) =>
      other is PairingInfo &&
      other.host == host &&
      other.port == port &&
      other.token == token &&
      other.httpPort == httpPort &&
      other.name == name;

  @override
  int get hashCode => Object.hash(host, port, token, httpPort, name);
}
