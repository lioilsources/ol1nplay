import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_remote/app.dart';
import 'package:ol1nplay_remote/core/engine_store.dart';
import 'package:ol1nplay_remote/core/providers.dart';

/// App side of `make screenshots-remote`: the real app with the driver
/// extension on and nothing remembered, so every run starts at pairing.
void main() {
  enableFlutterDriverExtension();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ProviderScope(
      overrides: [engineStoreProvider.overrideWithValue(MemoryEngineStore())],
      child: const Ol1nRemoteApp(),
    ),
  );
}
