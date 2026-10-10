import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/engine_target.dart';
import 'core/prefs.dart';
import 'core/providers.dart';
import 'features/tray/desktop_integration.dart';

/// `ol1nplay_desktop [--engine=ws://host:7777/ws?token=…]`
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await Prefs.load();
  await DesktopIntegration.initWindow(prefs);

  String? engineArg;
  for (final a in args) {
    if (a.startsWith('--engine=')) engineArg = a.substring('--engine='.length);
  }
  final target =
      EngineTarget.fromArg(engineArg) ??
      EngineTarget.fromOverride(prefs.engineOverride) ??
      EngineTarget.localEngine();

  runApp(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        engineTargetProvider.overrideWithValue(target),
      ],
      child: const Ol1nPlayApp(),
    ),
  );
}
