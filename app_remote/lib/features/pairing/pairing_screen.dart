import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/engine_store.dart';
import '../../core/providers.dart';
import 'qr_scan_screen.dart';

/// Lists saved engines, engines found on the LAN, and offers manual entry
/// and QR scanning. Selecting an engine makes it current; the root widget
/// then swaps in the shell.
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key, this.asDialog = false});

  /// Pushed from settings (an engine already exists) rather than at launch.
  final bool asDialog;

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  final _found = <DiscoveredEngine>[];
  StreamSubscription? _sub;
  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _discover();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _discover() {
    _sub?.cancel();
    setState(() {
      _found.clear();
      _scanning = true;
      _error = null;
    });
    _sub = ref
        .read(discoveryProvider)
        .discover()
        .listen(
          (e) => setState(() {
            if (!_found.contains(e)) _found.add(e);
          }),
          onError: (Object e) => setState(() => _error = 'mDNS: $e'),
          onDone: () {
            if (mounted) setState(() => _scanning = false);
          },
        );
  }

  Future<void> _use(SavedEngine e) async {
    await ref.read(enginesProvider.notifier).upsert(e);
    await ref.read(currentEngineIdProvider.notifier).set(e.id);
    if (widget.asDialog && mounted) Navigator.of(context).pop();
  }

  Future<void> _pairDiscovered(DiscoveredEngine d) async {
    final known = ref
        .read(enginesProvider.notifier)
        .byId('${d.host}:${d.port}');
    if (known != null && known.token.isNotEmpty) {
      await _use(known.copyWith(name: d.name, httpPort: d.httpPort));
      return;
    }
    final token = await _askToken(d.name);
    if (token == null) return;
    await _use(SavedEngine.fromPairing(d.toPairing(token: token)));
  }

  Future<String?> _askToken(String name) async {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Token for $name'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Pairing token',
            helperText: 'Shown under the QR code on the desktop',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('Pair'),
          ),
        ],
      ),
    );
  }

  Future<void> _manual() async {
    final r = await showDialog<_ManualResult>(
      context: context,
      builder: (_) => const _ManualDialog(),
    );
    if (r == null) return;
    final d = EngineDiscovery.manual(r.hostPort);
    if (d == null) {
      _snack('Enter host or host:port');
      return;
    }
    await _use(SavedEngine.fromPairing(d.toPairing(token: r.token)));
  }

  Future<void> _scanQr() async {
    final s = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (s == null) return;
    await _applyPairingString(s);
  }

  Future<void> _applyPairingString(String s) async {
    final p = PairingInfo.parse(s);
    if (p == null) {
      _snack('Not an Ol1nPlay pairing code');
      return;
    }
    await _use(SavedEngine.fromPairing(p));
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(enginesProvider).value ?? const <SavedEngine>[];
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect to Ol1nPlay'),
        actions: [
          IconButton(
            tooltip: 'Search again',
            onPressed: _scanning ? null : _discover,
            icon: _scanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (saved.isNotEmpty) ...[
            const _Header('Saved engines'),
            for (final e in saved)
              ListTile(
                key: ValueKey('saved:${e.id}'),
                leading: const Icon(Icons.speaker_group_outlined),
                title: Text(e.label),
                subtitle: Text(e.id, style: Ol1nTheme.mono(context, size: 12)),
                onTap: () => _use(e),
                trailing: IconButton(
                  tooltip: 'Forget',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () =>
                      ref.read(enginesProvider.notifier).forget(e.id),
                ),
              ),
          ],
          const _Header('On this network'),
          if (_found.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _scanning
                    ? 'Looking for engines (_ol1nplay._tcp)…'
                    : _error ??
                          'Nothing found. Enable the remote on the desktop, '
                              'or scan its QR code.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          for (final d in _found)
            ListTile(
              key: ValueKey('found:${d.host}:${d.port}'),
              leading: const Icon(Icons.wifi_tethering),
              title: Text(d.name),
              subtitle: Text(
                '${d.host}:${d.port}',
                style: Ol1nTheme.mono(context, size: 12),
              ),
              onTap: () => _pairDiscovered(d),
            ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _scanQr,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR code'),
                ),
                OutlinedButton.icon(
                  key: const Key('manualEntry'),
                  onPressed: _manual,
                  icon: const Icon(Icons.keyboard),
                  label: const Text('Enter address'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'The remote controls the engine on your Windows PC over the '
              'local network. Your phone never carries audio – and it has no '
              'volume control either: the level is set on your DAC or amplifier.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        letterSpacing: 1.2,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _ManualResult {
  const _ManualResult(this.hostPort, this.token);
  final String hostPort;
  final String token;
}

class _ManualDialog extends StatefulWidget {
  const _ManualDialog();

  @override
  State<_ManualDialog> createState() => _ManualDialogState();
}

class _ManualDialogState extends State<_ManualDialog> {
  final _host = TextEditingController();
  final _token = TextEditingController();

  @override
  void dispose() {
    _host.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Engine address'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('manualHost'),
          controller: _host,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'host[:port] or ol1nplay:// link',
            hintText: '192.168.1.20:7777',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('manualToken'),
          controller: _token,
          decoration: const InputDecoration(
            labelText: 'Token',
            helperText: 'From the desktop remote dialog',
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('manualConnect'),
        onPressed: () {
          // A pasted pairing link carries its own token.
          final p = PairingInfo.parse(_host.text);
          Navigator.pop(
            context,
            _ManualResult(
              _host.text,
              p != null && p.token.isNotEmpty ? p.token : _token.text.trim(),
            ),
          );
        },
        child: const Text('Connect'),
      ),
    ],
  );
}
