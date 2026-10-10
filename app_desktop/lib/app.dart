import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import 'core/providers.dart';
import 'features/shell/shell.dart';

/// MaterialApp with the shared theme; the theme mode follows the engine's
/// settings so the remote and the desktop agree.
class Ol1nPlayApp extends ConsumerWidget {
  const Ol1nPlayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp(
      title: 'Ol1nPlay',
      debugShowCheckedModeBanner: false,
      theme: Ol1nTheme.light(),
      darkTheme: Ol1nTheme.dark(),
      themeMode: Ol1nTheme.modeOfSettings(settings),
      home: const Shell(),
    );
  }
}
