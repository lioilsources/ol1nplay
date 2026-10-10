import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import 'engine_target.dart';

/// Keeps the app attached to an engine: connects, spawns the local engine
/// when nothing answers, and lets [EngineClient]'s own reconnect loop do
/// the rest. The UI only ever watches [client.status] and [message].
class EngineLauncher {
  EngineLauncher({
    required this.client,
    required this.target,
    this.spawn = true,
    this.autoReconnect = true,
  });

  final EngineClient client;
  final EngineTarget target;

  /// False in tests: never start a process.
  final bool spawn;
  final bool autoReconnect;

  /// Human-readable progress for the waiting screen.
  final ValueNotifier<String> message = ValueNotifier('Connecting…');

  Process? _process;
  bool _spawned = false;
  bool _closed = false;
  int _attempt = 0;
  Timer? _retry;

  Future<void> start() async {
    _closed = false;
    await _try();
  }

  Future<void> _try() async {
    if (_closed) return;
    _attempt++;
    message.value = _attempt == 1
        ? 'Connecting to ${target.uri.host}:${target.uri.port}…'
        : 'Retrying ($_attempt)…';
    try {
      await client.connect(target.uri, token: target.token);
      _attempt = 0;
      message.value = 'Connected';
      // The client reconnects by itself from here on; we just keep an eye
      // on it so a dead local engine gets respawned.
      client.status.addListener(_onStatus);
    } catch (e) {
      final text = e.toString();
      if (target.local && spawn && !_spawned && _looksRefused(text)) {
        await _spawnEngine();
      }
      await client.close();
      if (!autoReconnect || _closed) return;
      final delay = Duration(milliseconds: 600 * (_attempt < 6 ? _attempt : 6));
      message.value = _spawned
          ? 'Starting engine… ($text)'
          : 'No engine at ${target.uri.host}:${target.uri.port} — $text';
      _retry = Timer(delay, _try);
    }
  }

  void _onStatus() {
    if (_closed) return;
    if (client.status.value == ConnectionStatus.reconnecting &&
        target.local &&
        spawn &&
        _process != null) {
      // The engine we started went away; let it be restarted on the next
      // refused attempt.
      _spawned = false;
    }
  }

  static bool _looksRefused(String e) =>
      e.contains('refused') ||
      e.contains('SocketException') ||
      e.contains('Connection') ||
      e.contains('errno') ||
      e.contains('closed');

  Future<void> _spawnEngine() async {
    for (final path in EngineTarget.engineBinaryCandidates()) {
      if (!File(path).existsSync()) continue;
      try {
        message.value = 'Starting engine: $path';
        _process = await Process.start(
          path,
          const ['serve'],
          mode: ProcessStartMode.detachedWithStdio,
          workingDirectory: File(path).parent.path,
        );
        _spawned = true;
        // Give it a moment to bind before the next attempt.
        await Future<void>.delayed(const Duration(milliseconds: 800));
        return;
      } catch (e) {
        message.value = 'Could not start $path: $e';
      }
    }
    _spawned = true; // don't loop over the filesystem on every retry
    message.value =
        'Engine binary not found. Looked in: ${EngineTarget.engineBinaryCandidates().join(', ')}';
  }

  Future<void> dispose() async {
    _closed = true;
    _retry?.cancel();
    client.status.removeListener(_onStatus);
    message.dispose();
  }
}
