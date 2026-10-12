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
                  _section(context, 'Rituals'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      'Borrowed from Bug head. With an asynchronous USB DAC '
                      'none of this changes the bits the DAC receives; only '
                      'the RAM lock has an engineering reason. All off by '
                      'default.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  SwitchListTile(
                    key: const ValueKey('lockMemory'),
                    title: const Text('Lock audio in RAM'),
                    subtitle: const Text(
                      'Pins each decoded track in physical memory, so Windows '
                      'cannot page it out while it plays',
                    ),
                    value: s.lockMemory,
                    onChanged: (v) => _save(s.copyWith(lockMemory: v)),
                  ),
                  ListTile(
                    title: const Text('Memory cooltime'),
                    subtitle: Text(
                      s.cooltimeSec == 0
                          ? 'Off — playback starts as soon as the track is loaded'
                          : 'Waits ${s.cooltimeSec} s after loading before a '
                                'start from silence. Gapless transitions are '
                                'never delayed.',
                    ),
                    trailing: SizedBox(
                      width: 180,
                      child: Slider(
                        key: const ValueKey('cooltime'),
                        value: s.cooltimeSec.toDouble().clamp(0, 8),
                        max: 8,
                        divisions: 8,
                        label: '${s.cooltimeSec} s',
                        onChanged: (v) =>
                            _save(s.copyWith(cooltimeSec: v.round())),
                      ),
                    ),
                  ),
                  ListTile(
                    title: const Text('Helper program'),
                    subtitle: Text(
                      s.helperExe.isEmpty
                          ? 'None. A program of yours (for example '
                                'MinorityClean.exe) that the engine starts '
                                'with itself and stops when it quits. Not '
                                'part of Elfton Player.'
                          : '${s.helperExe} ${s.helperArgs}'.trim(),
                      style: s.helperExe.isEmpty
                          ? null
                          : Ol1nTheme.mono(context, size: 11),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (s.helperExe.isNotEmpty)
                          IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () => _save(
                              s.copyWith(helperExe: '', helperArgs: ''),
                            ),
                          ),
                        TextButton(
                          key: const ValueKey('helperChoose'),
                          onPressed: () => _editHelper(s),
                          child: const Text('Choose'),
                        ),
                      ],
                    ),
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

  /// Full path + arguments. A plain text field rather than only a file
  /// picker: the engine may be on another machine, where a local picker
  /// would browse the wrong disk.
  Future<void> _editHelper(Settings s) async {
    final exe = TextEditingController(text: s.helperExe);
    final args = TextEditingController(text: s.helperArgs);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Helper program'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: exe,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Full path on the engine\'s computer',
                  hintText: r'C:\Audio\MinorityClean 61 x64\MinorityClean.exe',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: args,
                decoration: const InputDecoration(
                  labelText: 'Arguments (optional)',
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Started with normal rights when the engine starts and '
                'stopped when it quits. A copy you run yourself or as a '
                'service is left alone.',
                style: TextStyle(fontSize: 12),
              ),
            ],
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
      await _save(
        s.copyWith(helperExe: exe.text.trim(), helperArgs: args.text.trim()),
      );
    }
  }

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
