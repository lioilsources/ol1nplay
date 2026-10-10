import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One engine the phone knows about. The token is stored separately
/// (secure storage) and joined back in by the store.
class SavedEngine {
  const SavedEngine({
    required this.host,
    required this.port,
    this.httpPort = 0,
    this.name = '',
    this.token = '',
    this.lastSeen = 0,
  });

  final String host;
  final int port;
  final int httpPort;
  final String name;
  final String token;
  final int lastSeen;

  /// Stable identity: the same host:port is the same engine even if the
  /// name or token changes.
  String get id => '$host:$port';

  String get label => name.isEmpty ? id : name;

  PairingInfo get pairing => PairingInfo(
    host: host,
    port: port,
    token: token,
    httpPort: httpPort,
    name: name,
  );

  SavedEngine copyWith({
    String? name,
    String? token,
    int? httpPort,
    int? lastSeen,
  }) => SavedEngine(
    host: host,
    port: port,
    httpPort: httpPort ?? this.httpPort,
    name: name ?? this.name,
    token: token ?? this.token,
    lastSeen: lastSeen ?? this.lastSeen,
  );

  static SavedEngine fromPairing(PairingInfo p) => SavedEngine(
    host: p.host,
    port: p.port,
    httpPort: p.httpPort,
    name: p.name,
    token: p.token,
  );

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'httpPort': httpPort,
    'name': name,
    'lastSeen': lastSeen,
  };

  static SavedEngine fromJson(Map<String, dynamic> j, {String token = ''}) =>
      SavedEngine(
        host: j['host'] as String? ?? '',
        port: j['port'] as int? ?? EngineDiscovery.defaultPort,
        httpPort: j['httpPort'] as int? ?? 0,
        name: j['name'] as String? ?? '',
        lastSeen: j['lastSeen'] as int? ?? 0,
        token: token,
      );
}

/// Persistence for saved engines and small app preferences. Abstract so
/// tests run without platform plugins.
abstract class EngineStore {
  Future<List<SavedEngine>> load();
  Future<void> save(List<SavedEngine> engines);

  /// Id of the engine to connect to on launch.
  Future<String?> currentId();
  Future<void> setCurrentId(String? id);

  Future<bool> flag(String key);
  Future<void> setFlag(String key, bool value);
}

/// In-memory store for tests and demos.
class MemoryEngineStore implements EngineStore {
  List<SavedEngine> engines = [];
  String? current;
  final flags = <String, bool>{};

  @override
  Future<List<SavedEngine>> load() async => List.of(engines);
  @override
  Future<void> save(List<SavedEngine> e) async => engines = List.of(e);
  @override
  Future<String?> currentId() async => current;
  @override
  Future<void> setCurrentId(String? id) async => current = id;
  @override
  Future<bool> flag(String key) async => flags[key] ?? false;
  @override
  Future<void> setFlag(String key, bool value) async => flags[key] = value;
}

/// Real store: engine list in shared_preferences, tokens in the keychain /
/// keystore so a backup or a casual look at prefs does not leak them.
class PrefsEngineStore implements EngineStore {
  PrefsEngineStore({FlutterSecureStorage? secure})
    : _secure = secure ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secure;
  static const _kEngines = 'engines';
  static const _kCurrent = 'currentEngine';

  @override
  Future<List<SavedEngine>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kEngines);
    if (raw == null) return [];
    final list = (jsonDecode(raw) as List).cast<Map>();
    final out = <SavedEngine>[];
    for (final m in list) {
      final j = Map<String, dynamic>.from(m);
      final e = SavedEngine.fromJson(j);
      String token = '';
      try {
        token = await _secure.read(key: 'token:${e.id}') ?? '';
      } catch (_) {
        // Secure storage can be unavailable (no keychain entitlement in a
        // dev build); the user re-pairs instead of the app crashing.
      }
      out.add(e.copyWith(token: token));
    }
    return out;
  }

  @override
  Future<void> save(List<SavedEngine> engines) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kEngines,
      jsonEncode(engines.map((e) => e.toJson()).toList()),
    );
    for (final e in engines) {
      try {
        await _secure.write(key: 'token:${e.id}', value: e.token);
      } catch (_) {}
    }
  }

  @override
  Future<String?> currentId() async =>
      (await SharedPreferences.getInstance()).getString(_kCurrent);

  @override
  Future<void> setCurrentId(String? id) async {
    final p = await SharedPreferences.getInstance();
    if (id == null) {
      await p.remove(_kCurrent);
    } else {
      await p.setString(_kCurrent, id);
    }
  }

  @override
  Future<bool> flag(String key) async =>
      (await SharedPreferences.getInstance()).getBool('flag:$key') ?? false;

  @override
  Future<void> setFlag(String key, bool value) async =>
      (await SharedPreferences.getInstance()).setBool('flag:$key', value);
}
