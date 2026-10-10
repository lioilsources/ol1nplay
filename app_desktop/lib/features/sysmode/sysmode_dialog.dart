import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/providers.dart';

/// "Playback mode" system tweaks: every switch is opt-in, the log shows
/// exactly what was changed, and the honest note is right at the top.
Future<void> showSysmodeDialog(BuildContext context) =>
    showDialog(context: context, builder: (_) => const _SysmodeDialog());

class _SysmodeDialog extends ConsumerStatefulWidget {
  const _SysmodeDialog();

  @override
  ConsumerState<_SysmodeDialog> createState() => _SysmodeDialogState();
}

class _SysmodeDialogState extends ConsumerState<_SysmodeDialog> {
  Sysmode? _cfg;
  List<SysmodeLogEntry> _log = const [];
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = ref.read(clientProvider);
      final cfg = await c.sysmodeGet();
      final log = await c.sysmodeLog();
      if (mounted) {
        setState(() {
          _cfg = cfg;
          _log = log;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _set(Sysmode next) {
    setState(() => _cfg = next);
    _run(() => ref.read(clientProvider).sysmodeSet(next));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cfg = _cfg;
    final c = ref.read(clientProvider);
    return AlertDialog(
      title: Row(
        children: [
          const Text('Playback mode (system tweaks)'),
          const Spacer(),
          if (cfg != null)
            Chip(
              label: Text(
                cfg.applied ? 'APPLIED' : 'not applied',
                style: Ol1nTheme.mono(context, size: 10),
              ),
              backgroundColor: cfg.applied
                  ? Ol1nTheme.bitPerfectGreen.withValues(alpha: 0.15)
                  : null,
            ),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: 560,
        child: cfg == null
            ? Center(
                child: _error != null
                    ? Text(_error!, style: TextStyle(color: scheme.error))
                    : const CircularProgressIndicator(strokeWidth: 2),
              )
            : ListView(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: scheme.outline),
                    ),
                    child: Text(
                      'Honest note: with an asynchronous USB DAC the DAC owns the clock, so power plans, '
                      'core parking and process priorities have little to no measurable effect on the '
                      'audio. These tweaks exist because they cannot hurt the sound and some listeners '
                      'expect them. They can hurt the rest of the system, so each one is opt-in, logged, '
                      'and reverted when playback stops or the engine restarts.',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (!cfg.available)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Not available: the engine must run elevated on Windows.',
                        style: TextStyle(color: scheme.error, fontSize: 12),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(color: scheme.error, fontSize: 12),
                      ),
                    ),
                  SwitchListTile(
                    title: const Text('Enable playback mode'),
                    subtitle: const Text(
                      'Apply the checked tweaks when playback starts, restore on stop',
                    ),
                    value: cfg.enabled,
                    onChanged: (v) => _set(cfg.copyWith(enabled: v)),
                  ),
                  const Divider(),
                  _sw(
                    'High-performance power plan',
                    'powercfg /setactive',
                    cfg.powerPlan,
                    (v) => _set(cfg.copyWith(powerPlan: v)),
                  ),
                  _sw(
                    'Disable USB selective suspend',
                    'keeps the DAC port powered',
                    cfg.usbSuspend,
                    (v) => _set(cfg.copyWith(usbSuspend: v)),
                  ),
                  _sw(
                    'Disable core parking, min CPU 100 %',
                    'no frequency ramps',
                    cfg.coreParking,
                    (v) => _set(cfg.copyWith(coreParking: v)),
                  ),
                  _sw(
                    'Engine process HIGH priority',
                    'never REALTIME — that starves input',
                    cfg.processPriority,
                    (v) => _set(cfg.copyWith(processPriority: v)),
                  ),
                  _sw(
                    '1 ms timer resolution',
                    'timeBeginPeriod(1)',
                    cfg.timer1ms,
                    (v) => _set(cfg.copyWith(timer1ms: v)),
                  ),
                  ListTile(
                    title: const Text('Pin audio thread to core'),
                    subtitle: const Text('-1 = last core'),
                    trailing: SizedBox(
                      width: 70,
                      child: TextFormField(
                        initialValue: '${cfg.pinCore}',
                        textAlign: TextAlign.right,
                        style: Ol1nTheme.mono(context, size: 12),
                        onFieldSubmitted: (v) =>
                            _set(cfg.copyWith(pinCore: int.tryParse(v) ?? -1)),
                      ),
                    ),
                  ),
                  const Divider(),
                  _ListEditor(
                    title:
                        'Suspend processes (NtSuspendProcess, resumed on restore)',
                    items: cfg.suspendProcesses,
                    suggestions: cfg.template,
                    onChanged: (l) => _set(cfg.copyWith(suspendProcesses: l)),
                  ),
                  _ListEditor(
                    title: 'Kill processes (not restarted)',
                    items: cfg.killProcesses,
                    suggestions: cfg.template,
                    onChanged: (l) => _set(cfg.copyWith(killProcesses: l)),
                  ),
                  _ListEditor(
                    title: 'Stop services (restarted on restore)',
                    items: cfg.stopServices,
                    suggestions: const [
                      'WSearch',
                      'SysMain',
                      'DiagTrack',
                      'wuauserv',
                    ],
                    onChanged: (l) => _set(cfg.copyWith(stopServices: l)),
                  ),
                  const Divider(),
                  if (cfg.changes.isNotEmpty) ...[
                    Text(
                      'Currently changed',
                      style: Ol1nTheme.mono(
                        context,
                        size: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    for (final ch in cfg.changes)
                      Text('• $ch', style: Ol1nTheme.mono(context, size: 11)),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    'Log — what I changed',
                    style: Ol1nTheme.mono(
                      context,
                      size: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (_log.isEmpty)
                    Text(
                      '(nothing yet)',
                      style: Ol1nTheme.mono(
                        context,
                        size: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  for (final e in _log.reversed.take(60))
                    Text(
                      '${_ts(e.at)}  ${e.action.padRight(7)} ${e.target}  ${e.detail}',
                      style: Ol1nTheme.mono(
                        context,
                        size: 11,
                        color: e.action == 'error' ? scheme.error : null,
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        if (cfg != null && cfg.available) ...[
          OutlinedButton(
            onPressed: _busy ? null : () => _run(c.sysmodeApply),
            child: const Text('Apply now'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : () => _run(c.sysmodeRestore),
            child: const Text('Restore now'),
          ),
        ],
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _sw(String title, String sub, bool v, ValueChanged<bool> on) =>
      SwitchListTile(
        dense: true,
        title: Text(title),
        subtitle: Text(sub),
        value: v,
        onChanged: on,
      );

  static String _ts(int ms) {
    if (ms == 0) return '--:--:--';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}

class _ListEditor extends StatefulWidget {
  const _ListEditor({
    required this.title,
    required this.items,
    required this.suggestions,
    required this.onChanged,
  });

  final String title;
  final List<String> items;
  final List<String> suggestions;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_ListEditor> createState() => _ListEditorState();
}

class _ListEditorState extends State<_ListEditor> {
  final _ctl = TextEditingController();

  void _add(String s) {
    s = s.trim();
    if (s.isEmpty || widget.items.contains(s)) return;
    widget.onChanged([...widget.items, s]);
    _ctl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final remaining = widget.suggestions
        .where((s) => !widget.items.contains(s))
        .toList();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final it in widget.items)
                InputChip(
                  label: Text(it, style: Ol1nTheme.mono(context, size: 11)),
                  onDeleted: () => widget.onChanged(
                    widget.items.where((x) => x != it).toList(),
                  ),
                ),
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _ctl,
                  style: Ol1nTheme.mono(context, size: 11),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'name.exe ⏎',
                  ),
                  onSubmitted: _add,
                ),
              ),
            ],
          ),
          if (remaining.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                children: [
                  Text(
                    'suggested: ',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  for (final s in remaining)
                    ActionChip(
                      label: Text(s, style: Ol1nTheme.mono(context, size: 10)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _add(s),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
