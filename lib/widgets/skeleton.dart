import 'package:flutter/cupertino.dart';

import '../theme.dart';

/// A static placeholder block used to sketch a page's layout while its data
/// loads. Intentionally animation-free — a shimmering gradient would add
/// continuous repaint cost, and here we only need to reserve the shape so the
/// real content doesn't cause a layout jump when it arrives.
class SkeletonBlock extends StatelessWidget {
  const SkeletonBlock({
    super.key,
    this.width,
    this.height = 12,
    this.radius = 6,
  });

  /// Null width stretches to fill the available space (e.g. inside a Row's
  /// Expanded or a stretched Column).
  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: palette.subtleText.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
