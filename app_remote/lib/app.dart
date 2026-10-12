import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import 'core/providers.dart';
import 'features/pairing/pairing_screen.dart';
import 'shell/home_shell.dart';

/// Root: pairing screen until an engine is chosen, then the shell. The
/// shell stays up while the connection drops; it shows the status itself.
class Ol1nRemoteApp extends ConsumerWidget {
  const Ol1nRemoteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value;
    final id = ref.watch(currentEngineIdProvider);
    final engines = ref.watch(enginesProvider);
    final hasEngine =
        id != null && (engines.value?.any((e) => e.id == id) ?? false);
    return MaterialApp(
      title: 'Elfton Remote',
      debugShowCheckedModeBanner: false,
      theme: Ol1nTheme.light(),
      darkTheme: Ol1nTheme.darkOfSettings(settings),
      themeMode: Ol1nTheme.modeOfSettings(settings),
      home: engines.isLoading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : hasEngine
          ? const HomeShell()
          : const PairingScreen(),
    );
  }
}
