import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ol1nplay_shared/ol1nplay_shared.dart';

import '../../core/providers.dart';

/// Bottom strip: connection, engine + FFmpeg version, scan progress, last
/// log line, log drawer toggle.
class StatusBar extends ConsumerWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final st = ref.watch(connectionProvider);
    final info = ref.watch(serverInfoProvider);
    final scan = ref.watch(scanProgressProvider).value;
    final log = ref.watch(logProvider);
    final showLog = ref.watch(showLogProvider);
    final target = ref.watch(engineTargetProvider);
    final last = log.isEmpty ? null : log.last;
    final dim = Ol1nTheme.mono(
      context,
      size: 10,
      color: scheme.onSurfaceVariant,
    );
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outline)),
      ),
      child: Row(
        children: [
          ConnectionDot(
            status: switch (st) {
              ConnectionStatus.connected => ConnectionStatusLike.connected,
              ConnectionStatus.connecting ||
              ConnectionStatus.reconnecting => ConnectionStatusLike.connecting,
              ConnectionStatus.disconnected =>
                ConnectionStatusLike.disconnected,
            },
            label: '${target.uri.host}:${target.uri.port}',
          ),
          const SizedBox(width: 12),
          if (info != null)
            Text(
              '${info.name} ${info.version}${info.elevated ? ' · admin' : ''} · ${info.backends.join('/')}',
              style: dim,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(width: 12),
          if (scan != null && !scan.finished)
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 80,
                    child: LinearProgressIndicator(
                      value: scan.total == 0 ? null : scan.fraction,
                      minHeight: 2,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'scanning ${scan.done}/${scan.total}  ${scan.current}',
                      style: dim,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            )
          else if (last != null)
            Expanded(
              child: Text(
                '[${last.scope}] ${last.msg}',
                style: Ol1nTheme.mono(
                  context,
                  size: 10,
                  color: last.isError
                      ? scheme.error
                      : (last.isWarn
                            ? Ol1nTheme.warnAmber
                            : scheme.onSurfaceVariant),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            const Spacer(),
          InkWell(
            onTap: () => ref.read(showLogProvider.notifier).toggle(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  Icon(
                    showLog ? Icons.expand_more : Icons.expand_less,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  Text(' log ${log.length}', style: dim),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Last 200 engine log lines, newest at the bottom.
class LogDrawer extends ConsumerWidget {
  const LogDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final log = ref.watch(logProvider);
    return Container(
      height: 160,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(top: BorderSide(color: scheme.outline)),
      ),
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              itemCount: log.length,
              itemBuilder: (_, i) {
                final l = log[log.length - 1 - i];
                final d = DateTime.fromMillisecondsSinceEpoch(l.at);
                String two(int n) => n.toString().padLeft(2, '0');
                return SelectableText(
                  '${two(d.hour)}:${two(d.minute)}:${two(d.second)} ${l.level.padRight(5)} ${l.scope.padRight(8)} ${l.msg}',
                  style: Ol1nTheme.mono(
                    context,
                    size: 11,
                    color: l.isError
                        ? scheme.error
                        : (l.isWarn ? Ol1nTheme.warnAmber : null),
                  ),
                );
              },
            ),
          ),
          Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: () => ref.read(logProvider.notifier).clear(),
                child: const Text('Clear'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
