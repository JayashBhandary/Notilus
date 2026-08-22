import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../providers/copy_jobs_provider.dart';
import '../../services/remote/remote_path.dart';
import '../../services/system_info_service.dart' show formatBytes;
import '../../theme.dart';

/// The floating transfer panel in the bottom-right corner.
///
/// Network copies don't belong in the full-width bar the local Rust operations
/// use: they run several at a time, they last long enough that the user will
/// go and do something else, and they need to stay visible while that happens
/// without occupying a strip of the window. A corner card that stacks its rows
/// and folds away is the shape that fits — the same one browsers and cloud
/// clients settled on for downloads.
class TransferHud extends StatefulWidget {
  const TransferHud({super.key});

  @override
  State<TransferHud> createState() => _TransferHudState();
}

class _TransferHudState extends State<TransferHud> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final jobs = context.watch<CopyJobs>();
    if (!jobs.hasJobs) return const SizedBox.shrink();

    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    final all = jobs.jobs;
    final running = all.where((j) => j.isRunning).toList();

    return Padding(
      padding: const EdgeInsets.all(12),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        alignment: Alignment.bottomRight,
        child: Container(
          width: 320,
          decoration: BoxDecoration(
            color: palette.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.border),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                total: all.length,
                running: running.length,
                collapsed: _collapsed,
                onToggle: () => setState(() => _collapsed = !_collapsed),
                onClearFinished: jobs.dismissFinished,
                hasFinished: all.length != running.length,
              ),
              if (!_collapsed)
                // Three rows is about a third of a short window; beyond that
                // the list scrolls instead of pushing the card off-screen.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final job in all)
                          _JobRow(
                            job: job,
                            onCancel: () => jobs.cancel(job.id),
                            onDismiss: () => jobs.dismiss(job.id),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.total,
    required this.running,
    required this.collapsed,
    required this.onToggle,
    required this.onClearFinished,
    required this.hasFinished,
  });

  final int total;
  final int running;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback onClearFinished;
  final bool hasFinished;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final label = running > 0
        ? '$running transfer${running == 1 ? '' : 's'} in progress'
        : 'Transfers finished';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
        child: Row(
          children: [
            Icon(
              running > 0 ? LucideIcons.arrowDownUp : LucideIcons.check,
              size: 14,
              color: colors.mutedForeground,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colors.foreground,
                ),
              ),
            ),
            if (hasFinished)
              _IconAction(
                icon: LucideIcons.brush,
                tooltip: 'Clear finished',
                onTap: onClearFinished,
              ),
            _IconAction(
              icon: collapsed ? LucideIcons.chevronUp : LucideIcons.chevronDown,
              tooltip: collapsed ? 'Show transfers' : 'Hide transfers',
              onTap: onToggle,
            ),
          ],
        ),
      ),
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({
    required this.job,
    required this.onCancel,
    required this.onDismiss,
  });

  final CopyJob job;
  final VoidCallback onCancel;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    final name = job.current.isEmpty
        ? 'Preparing…'
        : VPath.basename(job.current);

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 9, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _iconFor(job),
                size: 13,
                color: _toneFor(job, palette, colors),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  job.cancelRequested && job.isRunning
                      ? 'Stopping…'
                      : job.title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: colors.foreground,
                  ),
                ),
              ),
              _IconAction(
                icon: job.isRunning ? LucideIcons.x : LucideIcons.check,
                tooltip: job.isRunning ? 'Cancel' : 'Dismiss',
                onTap: job.isRunning ? onCancel : onDismiss,
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            job.state == CopyJobState.failed
                ? (job.error ?? 'Something went wrong.')
                : name,
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            style: TextStyle(
              fontSize: 11,
              color: job.state == CopyJobState.failed
                  ? colors.destructive
                  : colors.mutedForeground,
            ),
          ),
          if (job.isRunning) ...[
            const SizedBox(height: 7),
            _Bar(fraction: job.fraction, palette: palette),
            const SizedBox(height: 5),
            Text(
              _stats(job),
              style: TextStyle(fontSize: 10.5, color: colors.mutedForeground),
            ),
          ],
        ],
      ),
    );
  }

  static IconData _iconFor(CopyJob job) {
    switch (job.state) {
      case CopyJobState.failed:
        return LucideIcons.triangleAlert;
      case CopyJobState.cancelled:
        return LucideIcons.ban;
      case CopyJobState.done:
        return LucideIcons.circleCheck;
      case CopyJobState.running:
        switch (job.direction) {
          case CopyDirection.upload:
            return LucideIcons.cloudUpload;
          case CopyDirection.download:
            return LucideIcons.cloudDownload;
          case CopyDirection.betweenRemotes:
            return LucideIcons.arrowRightLeft;
          case CopyDirection.local:
            return LucideIcons.copy;
        }
    }
  }

  static Color _toneFor(CopyJob job, AppPalette palette, ShadColorScheme colors) {
    switch (job.state) {
      case CopyJobState.failed:
        return colors.destructive;
      case CopyJobState.done:
        return palette.success;
      case CopyJobState.cancelled:
        return colors.mutedForeground;
      case CopyJobState.running:
        return palette.accent;
    }
  }

  /// "12.4 MB of 300 MB · 3.1 MB/s · about 2 min left" — trimmed down to
  /// whatever is actually known, so an unsized transfer says less rather than
  /// making numbers up.
  static String _stats(CopyJob job) {
    final parts = <String>[];
    if (job.bytesTotal > 0) {
      parts.add('${formatBytes(job.bytesDone)} of ${formatBytes(job.bytesTotal)}');
    } else if (job.bytesDone > 0) {
      parts.add(formatBytes(job.bytesDone));
    }
    if (job.filesTotal > 1) {
      parts.add('${job.filesDone}/${job.filesTotal} files');
    }
    final rate = job.rate;
    if (rate != null && rate > 0) parts.add('${formatBytes(rate.round())}/s');
    final seconds = job.secondsRemaining;
    if (seconds != null) parts.add('${_duration(seconds)} left');
    return parts.join(' · ');
  }

  static String _duration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${(seconds / 60).ceil()} min';
    return '${(seconds / 3600).toStringAsFixed(1)} h';
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.palette});

  final double? fraction;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 4,
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
      builder: (context, _) => FractionallySizedBox(
        alignment: Alignment(-1 + 2 * _controller.value, 0),
        widthFactor: 0.3,
        child: ColoredBox(color: palette.accent),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final button = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(
            icon,
            size: 13,
            color: colors.mutedForeground,
            semanticLabel: tooltip,
          ),
        ),
      ),
    );
    // Tooltips are a pointer affordance; on a touch layout they only get in
    // the way of the tap they describe.
    if (Platform.isIOS || Platform.isAndroid) return button;
    return ShadTooltip(
      builder: (_) => Text(tooltip, style: const TextStyle(fontSize: 11.5)),
      child: button,
    );
  }
}
