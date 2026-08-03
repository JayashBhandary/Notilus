import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Indeterminate spinner in the shadcn idiom.
///
/// shadcn_ui ships no spinner component, so this fills the gap left by
/// `CupertinoActivityIndicator`. A single sweeping arc — deliberately plainer
/// than Cupertino's 8-tick wheel or Material's easing-heavy
/// `CircularProgressIndicator`.
///
/// Colour defaults to the theme's `primary`; pass [color] on filled buttons
/// where the surface is already primary (use `primaryForeground` there).
class ShadSpinner extends StatefulWidget {
  const ShadSpinner({
    super.key,
    this.size = 16,
    this.strokeWidth = 2,
    this.color,
  });

  /// Width and height of the spinner box.
  final double size;

  /// Thickness of the sweeping arc.
  final double strokeWidth;

  /// Arc colour. Defaults to `ShadTheme.of(context).colorScheme.primary`.
  final Color? color;

  @override
  State<ShadSpinner> createState() => _ShadSpinnerState();
}

class _ShadSpinnerState extends State<ShadSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? ShadTheme.of(context).colorScheme.primary;
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        // The painter is the only thing that changes, so build the RepaintBoundary
        // child once and let CustomPaint repaint in isolation.
        builder: (_, __) => CustomPaint(
          painter: _ArcPainter(
            turns: _controller.value,
            color: color,
            strokeWidth: widget.strokeWidth,
          ),
        ),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  const _ArcPainter({
    required this.turns,
    required this.color,
    required this.strokeWidth,
  });

  final double turns;
  final Color color;
  final double strokeWidth;

  /// Three-quarter arc — enough gap to read as rotating at small sizes.
  static const double _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final inset = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    canvas.drawArc(rect, turns * math.pi * 2, _sweep, false, paint);
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.turns != turns ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}
