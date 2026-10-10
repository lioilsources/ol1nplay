import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/providers.dart';
import '../../shell/home_shell.dart';
import '../pairing/pairing_screen.dart';

/// "More": engine + connection, output device, sysmode (read-only view plus
/// the on/off switch), output stats, sleep timer, saved engines.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionProvider);
    final info = ref.watch(serverInfoProvider);
    final s = ref.watch(engineStateProvider);
    final engines = ref.watch(enginesProvider).value ?? const [];
    final currentId = ref.watch(currentEngineIdProvider);
    final current = engines.where((e) => e.id == currentId).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        children: [
          ListTile(
            leading: ConnectionDot(status: connectionLike(status)),
            title: Text(current?.label ?? 'No engine'),
            subtitle: Text(
              info == null
                  ? (current?.id ?? '')
                  : '${current?.id} · ${info.name} ${info.version}'
                        '${info.elevated ? ' · admin' : ''}',
              style: Ol1nTheme.mono(context, size: 11),
            ),
            trailing: TextButton(
              child: const Text('Switch'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const PairingScreen(asDialog: true),
                ),
              ),
            ),
          ),
          const Divider(),
          const _Section('Output'),
          const _DeviceTile(),
          if (s != null)
            ListTile(
              leading: const Icon(Icons.graphic_eq),
              title: Text(
                s.output.device.isEmpty ? s.output.backend : s.output.device,
              ),
              subtitle: Text(
                '${s.output.status} · ${s.output.format.short}'
                '${s.output.bitPerfect ? ' · bit-perfect' : ''}'
                '${s.output.conversion.isNotEmpty ? '\n${s.output.conversion}' : ''}',
                style: Ol1nTheme.mono(context, size: 11),
              ),
              isThreeLine: s.output.conversion.isNotEmpty,
            ),
          const _StatsTile(),
          const Divider(),
          const _Section('Playback'),
          if (s != null) ...[
            SwitchListTile(
              secondary: const Icon(Icons.hearing),
              title: const Text('Mono downmix'),
              subtitle: const Text('(L+R)/2 – the only DSP, off by default'),
              value: s.mono,
              onChanged: (v) => ref.read(clientProvider).setMono(v),
            ),
            ListTile(
              leading: const Icon(Icons.bedtime_outlined),
              title: const Text('Sleep timer'),
              subtitle: Text(
                s.sleep == null
                    ? 'Off'
                    : 'Stops in ${s.sleep!.remaining.inMinutes} min',
              ),
              trailing: PopupMenuButton<int>(
                icon: const Icon(Icons.more_horiz),
                onSelected: (m) => m == 0
                    ? ref.read(clientProvider).sleepClear()
                    : ref.read(clientProvider).sleepSet(m),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 0, child: Text('Off')),
                  for (final m in [15, 30, 45, 60, 90])
                    PopupMenuItem(value: m, child: Text('$m minutes')),
                ],
              ),
            ),
            const _DsdTile(),
          ],
          const Divider(),
          const _Section('System playback mode'),
          const _SysmodeTile(),
          const Divider(),
          const _Section('Saved engines'),
          for (final e in engines)
            ListTile(
              leading: Icon(
                e.id == currentId
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              title: Text(e.label),
              subtitle: Text(e.id, style: Ol1nTheme.mono(context, size: 11)),
              onTap: () => ref.read(currentEngineIdProvider.notifier).set(e.id),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () =>
                    ref.read(enginesProvider.notifier).forget(e.id),
              ),
            ),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: NoVolumeNotice(compact: true),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        letterSpacing: 1.2,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _DeviceTile extends ConsumerWidget {
  const _DeviceTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    return ListTile(
      key: const Key('deviceTile'),
      leading: const Icon(Icons.speaker_outlined),
      title: const Text('Output device'),
      subtitle: devices.when(
        loading: () => const Text('…'),
        error: (e, _) => Text('$e'),
        data: (list) {
          final sel = list.where((d) => d.selected).firstOrNull;
          return Text(
            sel == null
                ? 'Not selected'
                : '${sel.backend.toUpperCase()} · ${sel.name}',
          );
        },
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _pick(context, ref),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    ref.invalidate(devicesProvider);
    final list = await ref.read(devicesProvider.future);
    if (!context.mounted) return;
    final chosen = await showModalBottomSheet<Device>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final d in list)
              ListTile(
                key: ValueKey('dev:${d.backend}:${d.id}'),
                leading: Icon(
                  d.selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(d.name),
                subtitle: Text(
                  '${d.backend.toUpperCase()}'
                  '${d.sampleRates.isNotEmpty ? ' · ${d.sampleRates.map(sampleRateLabel).join(' ')}' : ''}'
                  '${d.note.isNotEmpty ? '\n${d.note}' : ''}',
                  style: Ol1nTheme.mono(ctx, size: 10),
                ),
                onTap: () => Navigator.pop(ctx, d),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    await ref.read(clientProvider).selectDevice(chosen.backend, chosen.id);
    ref.invalidate(devicesProvider);
  }
}

class _StatsTile extends ConsumerWidget {
  const _StatsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(outputStatsProvider).value;
    final s = ref.watch(engineStateProvider);
    if (st == null || s == null) return const SizedBox.shrink();
    return ListTile(
      leading: UnderrunIndicator(underruns: st.underruns, alwaysShow: true),
      title: Text(
        '${st.underruns} underruns · ring ${st.ringFillPct.toStringAsFixed(0)} %',
        style: Ol1nTheme.mono(context, size: 12),
      ),
      subtitle: Text(
        '${st.threadPriority}${st.cpuCore >= 0 ? ' · core ${st.cpuCore}' : ''}'
        ' · max cb ${st.maxCallbackUs} µs · RAM ${fmtBytes(s.ramBytes)}'
        '${s.preloaded ? ' · next preloaded' : ''}',
        style: Ol1nTheme.mono(context, size: 10),
      ),
    );
  }
}

class _DsdTile extends ConsumerWidget {
  const _DsdTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value;
    if (settings == null) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.blur_on),
      title: const Text('DSD output'),
      subtitle: Text(switch (settings.dsdMode) {
        'dop' => 'DoP (DSD over PCM)',
        'pcm' => 'Convert to PCM – not bit-perfect',
        _ => 'Native, DoP as fallback',
      }),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_horiz),
        onSelected: (m) async {
          await ref.read(clientProvider).settingsSet({'dsdMode': m});
          ref.invalidate(settingsProvider);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'native', child: Text('Native (then DoP)')),
          PopupMenuItem(value: 'dop', child: Text('DoP')),
          PopupMenuItem(value: 'pcm', child: Text('PCM (lossy)')),
        ],
      ),
    );
  }
}

class _SysmodeTile extends ConsumerWidget {
  const _SysmodeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sm = ref.watch(sysmodeProvider);
    return sm.when(
      loading: () => const ListTile(title: Text('…')),
      error: (e, _) => ListTile(title: Text('$e')),
      data: (m) => Column(
        children: [
          SwitchListTile(
            key: const Key('sysmodeSwitch'),
            secondary: Icon(
              m.applied ? Icons.bolt : Icons.bolt_outlined,
              color: m.applied ? Ol1nTheme.accent : null,
            ),
            title: const Text('Playback mode'),
            subtitle: Text(
              !m.available
                  ? 'Unavailable (engine not elevated or not Windows)'
                  : m.applied
                  ? 'Applied · ${m.changes.length} changes'
                  : 'Power plan, USB suspend, priorities, paused processes',
            ),
            value: m.enabled,
            onChanged: m.available
                ? (v) async {
                    await ref
                        .read(clientProvider)
                        .sysmodeSet(m.copyWith(enabled: v));
                    ref.invalidate(sysmodeProvider);
                  }
                : null,
          ),
          if (m.changes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final c in m.changes)
                    Text('• $c', style: Ol1nTheme.mono(context, size: 11)),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Honest note: with an asynchronous USB DAC the DAC owns the clock, '
              'so these tweaks change little that can be measured. They are '
              'here because they cannot hurt – and are configured on the desktop.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
