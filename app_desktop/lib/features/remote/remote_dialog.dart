import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/providers.dart';

/// Remote control pairing: QR code of the pairing URI, LAN addresses,
/// enable/disable, rotate token, connected client count.
Future<void> showRemoteDialog(BuildContext context) =>
    showDialog(context: context, builder: (_) => const _RemoteDialog());

class _RemoteDialog extends ConsumerStatefulWidget {
  const _RemoteDialog();

  @override
  ConsumerState<_RemoteDialog> createState() => _RemoteDialogState();
}

class _RemoteDialogState extends ConsumerState<_RemoteDialog> {
  RemoteInfo? _info;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([Future<RemoteInfo> Function()? op]) async {
    try {
      final c = ref.read(clientProvider);
      final r = await (op ?? c.remoteInfo)();
      if (mounted) setState(() => _info = r);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.read(clientProvider);
    final scheme = Theme.of(context).colorScheme;
    final info = _info;
    return AlertDialog(
      title: const Text('Mobile remote'),
      content: SizedBox(
        width: 520,
        child: info == null
            ? SizedBox(
                height: 120,
                child: Center(
                  child: _error != null
                      ? Text(_error!, style: TextStyle(color: scheme.error))
                      : const CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Allow control from the local network'),
                    subtitle: Text(
                      info.enabled
                          ? 'Listening on port ${info.port} · ${info.clients} client${info.clients == 1 ? '' : 's'}'
                                '${info.mdns ? ' · discoverable (mDNS)' : ''}'
                          : 'Off — only this app can control the engine',
                      style: Ol1nTheme.mono(
                        context,
                        size: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    value: info.enabled,
                    onChanged: (on) => _load(() => c.remoteEnable(on)),
                  ),
                  const SizedBox(height: 8),
                  if (info.enabled) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: info.qr.isEmpty
                              ? const SizedBox(
                                  width: 180,
                                  height: 180,
                                  child: Center(child: Text('no QR')),
                                )
                              : QrImageView(
                                  data: info.qr,
                                  size: 180,
                                  backgroundColor: Colors.white,
                                ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Scan with the Ol1nPlay remote app.',
                                style: TextStyle(fontSize: 13),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Addresses',
                                style: Ol1nTheme.mono(
                                  context,
                                  size: 10,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              for (final a in info.addresses)
                                Text(
                                  '$a:${info.port}',
                                  style: Ol1nTheme.mono(context, size: 12),
                                ),
                              const SizedBox(height: 8),
                              Text(
                                'Pairing URI',
                                style: Ol1nTheme.mono(
                                  context,
                                  size: 10,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              SelectableText(
                                info.qr,
                                style: Ol1nTheme.mono(context, size: 10),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  OutlinedButton.icon(
                                    icon: const Icon(Icons.copy, size: 14),
                                    label: const Text('Copy'),
                                    onPressed: () => Clipboard.setData(
                                      ClipboardData(text: info.qr),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton.icon(
                                    icon: const Icon(Icons.key_off, size: 14),
                                    label: const Text('Rotate token'),
                                    onPressed: () => _load(c.remoteRotate),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Anyone with the token can control playback and browse the library. '
                      'Rotate it to disconnect every paired phone.',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
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
}
