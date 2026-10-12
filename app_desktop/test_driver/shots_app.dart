import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_desktop/app.dart';
import 'package:ol1nplay_desktop/core/engine_target.dart';
import 'package:ol1nplay_desktop/core/prefs.dart';
import 'package:ol1nplay_desktop/core/providers.dart';
import 'package:ol1nplay_desktop/features/tray/desktop_integration.dart';

/// App side of `make screenshots-desktop`: the real app attached to the
/// local engine, with the driver extension on. The one thing the host
/// cannot do by tapping is open a folder deep in the tree, so
/// `open:<root>|<dir>|<dir>…` expands that chain and selects its last entry.
Future<void> main() async {
  late final ProviderContainer container;
  enableFlutterDriverExtension(
    handler: (message) async {
      if (message == null || !message.startsWith('open:')) return 'unknown';
      final chain = message.substring('open:'.length).split('|');
      for (final dir in chain.take(chain.length - 1)) {
        container.read(expandedProvider.notifier).expand(dir);
      }
      container.read(selectedDirProvider.notifier).select(chain.last);
      return 'ok';
    },
  );
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await Prefs.load();
  await DesktopIntegration.initWindow(prefs);
  container = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      engineTargetProvider.overrideWithValue(EngineTarget.localEngine()),
    ],
  );
  runApp(
    UncontrolledProviderScope(container: container, child: const Ol1nPlayApp()),
  );
}
