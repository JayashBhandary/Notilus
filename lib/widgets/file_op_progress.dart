import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../providers/file_ops_provider.dart';
import '../services/system_info_service.dart' show formatBytes;
import '../theme.dart';

/// A determinate progress bar for a running copy/move, with a Cancel button.
///
/// Shown as a bottom overlay rather than a modal: a long copy shouldn't stop
/// the user browsing elsewhere, and the operation is already safe to run in
/// the background — Rust owns it, and cancelling is a single flag flip.
class FileOpProgressBar extends StatelessWidget {
  const FileOpProgressBar({super.key});

  @override
  Widget build(BuildContext context) {
    final ops = context.watch<FileOpsProvider>();
    final active = ops.activeOperation;
    if (active == null) return const SizedBox.shrink();

    final palette = AppColors.of(context);
    final fraction = active.fraction;
    final name = active.current.isEmpty
        ? 'Preparing…'
        : active.current.split(Platform.pathSeparator).last;

    return Container(
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      active.cancelling ? 'Cancelling…' : active.label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: palette.text,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.subtleText,
                        ),
                      ),
                    ),
                    if (active.filesTotal > 0)
                      Text(
                        '${active.filesDone}/${active.filesTotal}'
                        '${active.bytesTotal > 0 ? ' · ${formatBytes(active.bytesDone)} of ${formatBytes(active.bytesTotal)}' : ''}',
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.subtleText,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                _Bar(fraction: fraction, palette: palette),
              ],
            ),
          ),
          const SizedBox(width: 12),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: Size.zero,
            onPressed: active.cancelling ? null : ops.cancelActive,
            child: Text(
              'Cancel',
              style: TextStyle(fontSize: 12, color: palette.accent),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.palette});

  /// Null renders an indeterminate sweep — used while the pre-pass is still
  /// totalling the work.
  final double? fraction;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 5,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: palette.divider)),
            if (fraction != null)
              FractionallySizedBox(
                widthFactor: fraction!.clamp(0.0, 1.0),
                child: ColoredBox(color: palette.accent),
              )
            else
              const _IndeterminateSweep(),
          ],
        ),
      ),
    );
  }
}

class _IndeterminateSweep extends StatefulWidget {
  const _IndeterminateSweep();

  @override
  State<_IndeterminateSweep> createState() => _IndeterminateSweepState();
}

class _IndeterminateSweepState extends State<_IndeterminateSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return FractionallySizedBox(
          alignment: Alignment(-1 + 2 * _controller.value, 0),
          widthFactor: 0.3,
          child: ColoredBox(color: palette.accent),
        );
      },
    );
  }
}
