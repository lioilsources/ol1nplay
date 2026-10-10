import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../client/engine_client.dart';

/// Process-wide cover cache keyed by hash. Covers are immutable (the hash
/// is of the source bytes) so there is never a reason to refetch.
class CoverCache {
  CoverCache._();

  static final instance = CoverCache._();

  final _bytes = <String, Uint8List>{};
  final _inflight = <String, Future<Uint8List?>>{};
  int _size = 0;

  /// Soft cap; oldest entries are evicted past it.
  int maxBytes = 64 << 20;

  Uint8List? peek(String key) => _bytes[key];

  Future<Uint8List?> fetch(String key, Uri uri, {http.Client? client}) {
    final hit = _bytes[key];
    if (hit != null) return Future.value(hit);
    return _inflight.putIfAbsent(key, () async {
      try {
        final c = client ?? http.Client();
        try {
          final r = await c.get(uri).timeout(const Duration(seconds: 8));
          if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
          _put(key, r.bodyBytes);
          return r.bodyBytes;
        } finally {
          if (client == null) c.close();
        }
      } catch (_) {
        return null;
      } finally {
        _inflight.remove(key);
      }
    });
  }

  void _put(String key, Uint8List b) {
    _bytes[key] = b;
    _size += b.length;
    while (_size > maxBytes && _bytes.length > 1) {
      final k = _bytes.keys.first;
      _size -= _bytes.remove(k)!.length;
    }
  }

  void clear() {
    _bytes.clear();
    _size = 0;
  }
}

/// Album art for a cover hash, fetched from the engine's HTTP port.
/// Shows a neutral placeholder when there is no cover or no connection.
class CoverImage extends StatefulWidget {
  const CoverImage({
    super.key,
    required this.hash,
    required this.client,
    this.size,
    this.thumb = false,
    this.borderRadius = 6,
    this.fit = BoxFit.cover,
    this.placeholderIcon = Icons.album_outlined,
  });

  final String hash;
  final EngineClient client;

  /// Square size; null = fill the parent.
  final double? size;

  /// Request the 96 px thumbnail instead of the 512 px cover.
  final bool thumb;
  final double borderRadius;
  final BoxFit fit;
  final IconData placeholderIcon;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  Uint8List? _bytes;
  String _loadedKey = '';

  String get _key => '${widget.hash}${widget.thumb ? '_t' : ''}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoverImage old) {
    super.didUpdateWidget(old);
    if (old.hash != widget.hash || old.thumb != widget.thumb) _load();
  }

  void _load() {
    final key = _key;
    if (widget.hash.isEmpty) {
      setState(() {
        _bytes = null;
        _loadedKey = key;
      });
      return;
    }
    final cached = CoverCache.instance.peek(key);
    if (cached != null) {
      _bytes = cached;
      _loadedKey = key;
      return;
    }
    final uri = widget.client.coverUrl(widget.hash, thumb: widget.thumb);
    if (uri == null) {
      _bytes = null;
      _loadedKey = key;
      return;
    }
    CoverCache.instance.fetch(key, uri).then((b) {
      if (!mounted || _key != key) return;
      setState(() {
        _bytes = b;
        _loadedKey = key;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = _loadedKey == _key ? _bytes : null;
    Widget child = bytes == null
        ? ColoredBox(
            color: scheme.surfaceContainerHigh,
            child: Center(
              child: Icon(
                widget.placeholderIcon,
                color: scheme.onSurfaceVariant,
                size: widget.size == null ? 48 : widget.size! * 0.4,
              ),
            ),
          )
        : Image.memory(bytes, fit: widget.fit, gaplessPlayback: true);
    child = ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: child,
    );
    if (widget.size != null) {
      return SizedBox(width: widget.size, height: widget.size, child: child);
    }
    return AspectRatio(aspectRatio: 1, child: child);
  }
}
