import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/engine_target.dart';
import '../../core/prefs.dart';
import '../../core/providers.dart';

Future<void> showSettingsDialog(BuildContext context) =>
    showDialog(context: context, builder: (_) => const _SettingsDialog());

class _SettingsDialog extends ConsumerStatefulWidget {
  const _SettingsDialog();

  @override
  ConsumerState<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<_SettingsDialog> {
  Settings? _s;
  String? _error;

  @override
  void initState() {
    super.initState();
    _s = ref.read(settingsProvider);
    if (_s == null) {
      ref
          .read(settingsProvider.notifier)
          .reload()
          .then((_) {
            if (mounted) setState(() => _s = ref.read(settingsProvider));
          })
          .catchError((e) {
            if (mounted) setState(() => _error = '$e');
          });
    }
  }

  Future<void> _save(Settings next) async {
    setState(() => _s = next);
    try {
      await ref.read(settingsProvider.notifier).update(next);
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = _s;
    final prefs = ref.watch(prefsProvider);
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 600,
        height: 560,
        child: s == null
            ? Center(
                child: _error != null
                    ? Text(_error!, style: TextStyle(color: scheme.error))
                    : const CircularProgressIndicator(strokeWidth: 2),
              )
            : ListView(
                children: [
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(color: scheme.error, fontSize: 12),
                    ),
                  _section(context, 'Appearance'),
                  ListTile(
                    title: const Text('Theme'),
                    trailing: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'system', label: Text('System')),
                        ButtonSegment(value: 'dark', label: Text('Dark')),
                        ButtonSegment(value: 'black', label: Text('Black')),
                        ButtonSegment(value: 'light', label: Text('Light')),
                      ],
                      selected: {s.theme},
                      onSelectionChanged: (v) =>
                          _save(s.copyWith(theme: v.first)),
                    ),
                  ),
                  _section(context, 'Playback'),
                  ListTile(
                    title: const Text('RAM limit per track'),
                    subtitle: const Text(
                      'Tracks above this stream from disk through the ring buffer',
                    ),
                    trailing: SizedBox(
                      width: 90,
                      child: TextFormField(
                        initialValue:
                            '${s.ramLimitMB == 0 ? 512 : s.ramLimitMB}',
                        textAlign: TextAlign.right,
                        style: Ol1nTheme.mono(context, size: 12),
                        decoration: const InputDecoration(
                          suffixText: 'MB',
                          isDense: true,
                        ),
                        onFieldSubmitted: (v) => _save(
                          s.copyWith(
                            ramLimitMB: int.tryParse(v) ?? s.ramLimitMB,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Preload next track (gapless)'),
                    subtitle: const Text(
                      'Decode the following track into RAM while this one plays',
                    ),
                    value: s.preloadNext,
                    onChanged: (v) => _save(s.copyWith(preloadNext: v)),
                  ),
                  SwitchListTile(
                    title: const Text('Resume on start'),
                    subtitle: const Text('Reopen the last queue and position'),
                    value: s.resumeOnStart,
                    onChanged: (v) => _save(s.copyWith(resumeOnStart: v)),
                  ),
                  _section(context, 'Output format'),
                  ListTile(
                    title: const Text('DSD'),
                    subtitle: Text(
                      switch (s.dsdMode) {
                        'dop' =>
                          'DSD over PCM: DSD bits untouched inside 24-bit frames — bit-perfect.',
                        'pcm' =>
                          'FFmpeg converts DSD to PCM float. NOT bit-perfect; only for DACs with no DSD path.',
                        _ =>
                          'Native DSD when the driver accepts it, DoP otherwise.',
                      },
                      style: TextStyle(
                        color: s.dsdMode == 'pcm' ? scheme.error : null,
                      ),
                    ),
                    trailing: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'native', label: Text('Native')),
                        ButtonSegment(value: 'dop', label: Text('DoP')),
                        ButtonSegment(value: 'pcm', label: Text('PCM')),
                      ],
                      selected: {s.dsdMode},
                      onSelectionChanged: (v) =>
                          _save(s.copyWith(dsdMode: v.first)),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Allow width extension'),
                    subtitle: const Text(
                      '16/24-bit into a 32-bit container with zero LSBs when the driver asks — still bit-perfect',
                    ),
                    value: s.widthExtension,
                    onChanged: (v) => _save(s.copyWith(widthExtension: v)),
                  ),
                  ListTile(
                    title: const Text('ASIO buffer size'),
                    subtitle: const Text(
                      'Preferred is what the driver recommends; latency does not matter here, stability does',
                    ),
                    trailing: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'preferred',
                          label: Text('Preferred'),
                        ),
                        ButtonSegment(value: 'max', label: Text('Max')),
                        ButtonSegment(value: 'min', label: Text('Min')),
                      ],
                      selected: {s.bufferPreference},
                      onSelectionChanged: (v) =>
                          _save(s.copyWith(bufferPreference: v.first)),
                    ),
                  ),
                  ListTile(
                    title: const Text('A-B crossfade'),
                    subtitle: const Text(
                      '0 = off. Anything else is DSP on the loop point.',
                    ),
                    trailing: SizedBox(
                      width: 90,
                      child: TextFormField(
                        initialValue: '${s.abCrossfadeMs}',
                        textAlign: TextAlign.right,
                        style: Ol1nTheme.mono(context, size: 12),
                        decoration: const InputDecoration(
                          suffixText: 'ms',
                          isDense: true,
                        ),
                        onFieldSubmitted: (v) => _save(
                          s.copyWith(abCrossfadeMs: int.tryParse(v) ?? 0),
                        ),
                      ),
                    ),
                  ),
                  _section(context, 'Integration'),
                  SwitchListTile(
                    title: const Text('Media keys'),
                    subtitle: const Text(
                      'Play/pause, next, previous from the keyboard',
                    ),
                    value: s.mediaKeys,
                    onChanged: (v) => _save(s.copyWith(mediaKeys: v)),
                  ),
                  SwitchListTile(
                    title: const Text('Scrobble log'),
                    subtitle: const Text(
                      'Write a local scrobble log (last.fm export format)',
                    ),
                    value: s.scrobble,
                    onChanged: (v) => _save(s.copyWith(scrobble: v)),
                  ),
                  _section(context, 'Remote'),
                  SwitchListTile(
                    title: const Text('Enable LAN remote'),
                    value: s.remoteEnabled,
                    onChanged: (v) => _save(s.copyWith(remoteEnabled: v)),
                  ),
                  SwitchListTile(
                    title: const Text('Advertise via mDNS'),
                    subtitle: const Text(
                      '_ol1nplay._tcp so the phone finds the engine without typing an address',
                    ),
                    value: s.mdns,
                    onChanged: (v) => _save(s.copyWith(mdns: v)),
                  ),
                  ListTile(
                    title: const Text('Remote port'),
                    trailing: SizedBox(
                      width: 90,
                      child: TextFormField(
                        initialValue:
                            '${s.remotePort == 0 ? 7777 : s.remotePort}',
                        textAlign: TextAlign.right,
                        style: Ol1nTheme.mono(context, size: 12),
                        decoration: const InputDecoration(isDense: true),
                        onFieldSubmitted: (v) => _save(
                          s.copyWith(
                            remotePort: int.tryParse(v) ?? s.remotePort,
                          ),
                        ),
                      ),
                    ),
                  ),
                  _section(context, 'This app'),
                  ListTile(
                    title: const Text('Engine address override'),
                    subtitle: Text(
                      prefs.engineOverride.isEmpty
                          ? 'Local engine (${EngineTarget.localUri}). Takes effect after restart.'
                          : '${prefs.engineOverride}  (restart to apply)',
                      style: Ol1nTheme.mono(context, size: 11),
                    ),
                    trailing: TextButton(
                      onPressed: () => _editOverride(prefs),
                      child: const Text('Change'),
                    ),
                  ),
                ],
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

  Widget _section(BuildContext context, String s) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(
      s.toUpperCase(),
      style: Ol1nTheme.mono(
        context,
        size: 10,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Future<void> _editOverride(Prefs prefs) async {
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
              hintText: 'ws://host:7777/ws?token=…  (empty = local)',
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
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok == true) {
      prefs.engineOverride = ctl.text.trim();
      if (mounted) setState(() {});
    }
  }
}
