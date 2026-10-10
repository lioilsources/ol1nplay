import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

/// Camera scanner for the desktop's QR code. Pops with the raw pairing
/// string. On a simulator or when the camera is unavailable the user can
/// paste the `ol1nplay://` link instead.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  final _paste = TextEditingController();
  bool _done = false;
  String? _cameraError;

  @override
  void dispose() {
    _controller.dispose();
    _paste.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture cap) {
    if (_done) return;
    for (final b in cap.barcodes) {
      final v = b.rawValue;
      if (v != null && PairingInfo.parse(v) != null) {
        _done = true;
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  void _usePasted() {
    final v = _paste.text.trim();
    if (PairingInfo.parse(v) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not an ol1nplay:// pairing link')),
      );
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing code')),
      body: Column(
        children: [
          Expanded(
            child: _cameraError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Camera unavailable: $_cameraError\n\nPaste the link below instead.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : MobileScanner(
                    controller: _controller,
                    onDetect: _onDetect,
                    errorBuilder: (ctx, err) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && _cameraError == null) {
                          setState(
                            () => _cameraError =
                                err.errorDetails?.message ?? err.errorCode.name,
                          );
                        }
                      });
                      return const SizedBox.shrink();
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _paste,
                    decoration: const InputDecoration(
                      labelText: 'or paste ol1nplay://… link',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _usePasted(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _usePasted, child: const Text('Use')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
