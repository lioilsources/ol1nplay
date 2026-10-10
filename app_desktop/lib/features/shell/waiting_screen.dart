import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/engine_target.dart';
import '../../core/providers.dart';

/// Shown until the first successful `hello`. The launcher keeps retrying
/// (and starts the local engine) in the background; this just narrates.
class WaitingScreen extends ConsumerWidget {
  const WaitingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final launcher = ref.watch(launcherProvider);
    final target = ref.watch(engineTargetProvider);
    final err = ref.watch(lastErrorProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.graphic_eq_rounded,
                      color: scheme.primary,
                      size: 32,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Ol1nPlay',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const LinearProgressIndicator(minHeight: 2),
                const SizedBox(height: 16),
                ValueListenableBuilder<String>(
                  valueListenable: launcher.message,
                  builder: (_, msg, _) =>
                      Text(msg, style: Ol1nTheme.mono(context, size: 12)),
                ),
                if (err != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    err,
                    style: Ol1nTheme.mono(
                      context,
                      size: 11,
                      color: scheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  target.local
                      ? 'The engine runs as a separate process (ol1nplay-engine). '
                            'It is started automatically when found next to the app in engine/.\n'
                            'Data directory: ${EngineTarget.dataDir()}'
                      : 'Remote engine: ${target.uri.host}:${target.uri.port}',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Retry now'),
                      onPressed: () => launcher.start(),
                    ),
                    TextButton(
                      onPressed: () => _editTarget(context, ref),
                      child: const Text('Connect to another engine…'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editTarget(BuildContext context, WidgetRef ref) async {
    final prefs = ref.read(prefsProvider);
    final ctl = TextEditingController(text: prefs.engineOverride);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Engine address'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: ctl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText:
                  'ws://host:7777/ws?token=…  or  ol1nplay://…  (empty = local)',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save & restart'),
          ),
        ],
      ),
    );
    if (ok == true) {
      prefs.engineOverride = ctl.text.trim();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Saved. Restart Ol1nPlay to use the new address.'),
          ),
        );
      }
    }
  }
}
