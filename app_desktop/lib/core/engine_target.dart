import 'dart:io';

import 'package:ol1nplay_shared/ol1nplay_shared.dart';
import 'package:path/path.dart' as p;

/// Where the engine is and how to talk to it. Resolved once at startup
/// from (in priority order) the `--engine=` CLI argument, the saved
/// override, and the local default.
class EngineTarget {
  const EngineTarget({
    required this.uri,
    required this.token,
    required this.local,
  });

  final Uri uri;
  final String token;

  /// True when the engine is expected on this machine, so the app may
  /// spawn it when the connection is refused.
  final bool local;

  static const defaultPort = 7777;

  static Uri get localUri =>
      Uri(scheme: 'ws', host: '127.0.0.1', port: defaultPort, path: '/ws');

  /// `--engine=ws://host:port/ws?token=…` or `--engine=ol1nplay://…`.
  static EngineTarget? fromArg(String? arg) {
    if (arg == null || arg.isEmpty) return null;
    return fromOverride(arg);
  }

  /// Parses a user-entered override (ws URI, pairing URI or `host[:port]`).
  static EngineTarget? fromOverride(String s) {
    s = s.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('ol1nplay://')) {
      final info = PairingInfo.parse(s);
      if (info == null) return null;
      return EngineTarget(
        uri: info.wsUri,
        token: info.token,
        local: _isLoopback(info.wsUri.host),
      );
    }
    var uri = Uri.tryParse(s.contains('://') ? s : 'ws://$s');
    if (uri == null || uri.host.isEmpty) return null;
    final token = uri.queryParameters['token'] ?? '';
    if (uri.path.isEmpty || uri.path == '/') uri = uri.replace(path: '/ws');
    if (!uri.hasPort) uri = uri.replace(port: defaultPort);
    uri = uri.replace(queryParameters: const {}).replace(query: null);
    return EngineTarget(
      uri: Uri(scheme: 'ws', host: uri.host, port: uri.port, path: uri.path),
      token: token,
      local: _isLoopback(uri.host),
    );
  }

  /// The local engine with the token file read from the data directory.
  static EngineTarget localEngine() {
    var token = '';
    try {
      final f = File(p.join(dataDir(), 'token'));
      if (f.existsSync()) token = f.readAsStringSync().trim();
    } catch (_) {}
    return EngineTarget(uri: localUri, token: token, local: true);
  }

  /// `%LOCALAPPDATA%\Ol1nPlay` or `~/Library/Application Support/Ol1nPlay`.
  static String dataDir() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final base = env['LOCALAPPDATA'] ?? env['APPDATA'] ?? '.';
      return p.join(base, 'Ol1nPlay');
    }
    if (Platform.isMacOS) {
      return p.join(
        env['HOME'] ?? '.',
        'Library',
        'Application Support',
        'Ol1nPlay',
      );
    }
    final xdg = env['XDG_DATA_HOME'];
    return p.join(
      xdg ?? p.join(env['HOME'] ?? '.', '.local', 'share'),
      'Ol1nPlay',
    );
  }

  /// Candidate paths of the engine binary, best first: next to the app
  /// (`engine/`), the app directory itself, then a dev-tree checkout.
  static List<String> engineBinaryCandidates() {
    final exe = Platform.resolvedExecutable;
    final dir = p.dirname(exe);
    final name = Platform.isWindows ? 'ol1nplay-engine.exe' : 'ol1nplay-engine';
    final out = <String>[p.join(dir, 'engine', name), p.join(dir, name)];
    if (Platform.isMacOS) {
      // app bundle: Contents/MacOS/<exe> → Contents/Resources/engine/<name>
      out.add(p.join(dir, '..', 'Resources', 'engine', name));
    }
    // Development checkout: <repo>/engine/bin/<name>.
    var d = Directory(dir);
    for (var i = 0; i < 6; i++) {
      out.add(p.join(d.path, 'engine', 'bin', name));
      final parent = d.parent;
      if (parent.path == d.path) break;
      d = parent;
    }
    return out;
  }

  static bool _isLoopback(String host) =>
      host == '127.0.0.1' || host == 'localhost' || host == '::1';

  @override
  String toString() =>
      'EngineTarget($uri local=$local token=${token.isEmpty ? 'none' : '***'})';
}
