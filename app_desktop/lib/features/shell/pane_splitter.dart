import 'package:flutter/material.dart';

/// A thin vertical drag handle between two panes. The parent owns the
/// width; this only reports deltas.
class PaneSplitter extends StatefulWidget {
  const PaneSplitter({super.key, required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  State<PaneSplitter> createState() => _PaneSplitterState();
}

class _PaneSplitterState extends State<PaneSplitter> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        child: SizedBox(
          width: 6,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: _hover ? 2 : 1,
              color: _hover ? Theme.of(context).colorScheme.primary : outline,
            ),
          ),
        ),
      ),
    );
  }
}
