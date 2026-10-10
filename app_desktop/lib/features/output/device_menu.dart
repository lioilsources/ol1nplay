import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/actions.dart';
import '../../core/providers.dart';

/// Output device dropdown in the top bar, grouped by backend. Shows the
/// device's probed sample rates so the user can see what the DAC accepts.
class DeviceButton extends ConsumerWidget {
  const DeviceButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final out = ref.watch(stateProvider.select((s) => s.output));
    final scheme = Theme.of(context).colorScheme;
    final color = switch (out.status) {
      OutputStatus.running => Ol1nTheme.bitPerfectGreen,
      OutputStatus.error => scheme.error,
      OutputStatus.open => scheme.primary,
      _ => scheme.onSurfaceVariant,
    };
    final label = out.device.isNotEmpty
        ? '${out.backendLabel} · ${out.device}'
        : (out.backend.isNotEmpty ? out.backendLabel : 'Output');
    return Tooltip(
      message: out.error.isNotEmpty ? out.error : 'Output device',
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          visualDensity: VisualDensity.compact,
        ),
        icon: Icon(Icons.speaker_outlined, size: 16, color: color),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
        onPressed: () => showDeviceDialog(context, ref),
      ),
    );
  }
}

Future<void> showDeviceDialog(BuildContext context, WidgetRef ref) {
  return showDialog(context: context, builder: (_) => const _DeviceDialog());
}

class _DeviceDialog extends ConsumerWidget {
  const _DeviceDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final out = ref.watch(stateProvider.select((s) => s.output));
    final client = ref.watch(clientProvider);
    final a = ref.read(actionsProvider);
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          const Text('Output device'),
          const Spacer(),
          IconButton(
            tooltip: 'Re-open device (after a driver reset)',
            icon: const Icon(Icons.restart_alt, size: 18),
            onPressed: () => a.guard(context, client.outputReset),
          ),
          IconButton(
            tooltip: 'Refresh list',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: () => ref.invalidate(devicesProvider),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 420,
        child: devices.when(
          loading: () =>
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          error: (e, _) => Center(
            child: Text('$e', style: TextStyle(color: scheme.error)),
          ),
          data: (list) {
            if (list.isEmpty) {
              return Center(
                child: Text(
                  'No output devices. Install an ASIO driver or plug in a DAC.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              );
            }
            final backends = list.map((d) => d.backend).toSet().toList();
            return ListView(
              children: [
                if (out.error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      out.error,
                      style: Ol1nTheme.mono(
                        context,
                        size: 11,
                        color: scheme.error,
                      ),
                    ),
                  ),
                for (final b in backends) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                    child: Text(
                      _backendTitle(b),
                      style: Ol1nTheme.mono(
                        context,
                        size: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final d in list.where((d) => d.backend == b))
                    ListTile(
                      selected: d.selected,
                      leading: Icon(
                        d.selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 18,
                      ),
                      title: Text(d.name),
                      subtitle: Text(
                        [
                          if (d.isDefault) 'default',
                          if (d.maxChannels > 0) '${d.maxChannels} ch',
                          if (d.sampleRates.isNotEmpty)
                            d.sampleRates.map(sampleRateLabel).join(' '),
                          if (d.formats.isNotEmpty) d.formats.join('/'),
                          if (d.note.isNotEmpty) d.note,
                        ].join(' · '),
                        style: Ol1nTheme.mono(
                          context,
                          size: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      onTap: () async {
                        await a.guard(
                          context,
                          () => client.selectDevice(d.backend, d.id),
                        );
                        ref.invalidate(devicesProvider);
                      },
                    ),
                ],
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  static String _backendTitle(String b) => switch (b) {
    'asio' => 'ASIO — bit-perfect, exclusive',
    'wasapi' => 'WASAPI exclusive — fallback when there is no ASIO driver',
    'coreaudio' => 'CoreAudio (hog mode) — development backend',
    'null' => 'No output',
    _ => b.toUpperCase(),
  };
}
