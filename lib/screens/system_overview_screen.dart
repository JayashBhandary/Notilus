import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../providers/browser_provider.dart';
import '../providers/settings_provider.dart';
import '../services/file_service.dart';
import '../services/system_info_service.dart';
import '../theme.dart';
import '../widgets/shad_spinner.dart';
import '../widgets/skeleton.dart';

/// Which number the folder-snapshot bars are weighted by.
enum _Metric { size, files }

/// Embeddable System Overview page. Rendered inside the app's central content
/// pane (not a full-screen route). Hold a [GlobalKey] to call [refresh].
class SystemOverviewView extends StatefulWidget {
  const SystemOverviewView({super.key, this.service});

  /// Overrides the storage probe. The default shells out to `df`/PowerShell,
  /// whose future never completes under the widget tester's fake async, so
  /// tests inject a canned service instead.
  final SystemInfoService? service;

  @override
  State<SystemOverviewView> createState() => SystemOverviewViewState();
}

class SystemOverviewViewState extends State<SystemOverviewView> {
  late final SystemInfoService _svc;
  late Future<List<DiskUsage>> _disksFuture;
  late Future<List<CategoryBreakdown>> _breakdownsFuture;

  _Metric _metric = _Metric.size;
  String _aiInsight = '';
  bool _aiBusy = false;

  /// Held so the request can be cancelled by the user, and so a dispose
  /// mid-stream tears the HTTP connection down instead of leaking it.
  StreamSubscription<String>? _aiSub;

  /// Identifies the folder set the current [_breakdownsFuture] was built from,
  /// so a shortcut map that arrives late triggers exactly one rescan. Null
  /// until the first scan — an empty shortcut map keys to the empty string, and
  /// starting there would skip the assignment and leave the future unset.
  String? _targetsKey;

  /// Folders the snapshot scans, in display order. iOS only exposes Documents;
  /// missing entries are skipped rather than shown as empty folders.
  static const _scanLabels = ['Desktop', 'Documents', 'Downloads'];

  @override
  void initState() {
    super.initState();
    _svc = widget.service ?? SystemInfoService(FileService());
    // Assigned directly rather than through refresh(): setState() during
    // initState is a no-op at best and an assertion at worst.
    _disksFuture = _svc.diskUsages();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // BrowserProvider.init() fills `shortcuts` from the filesystem after the
    // app starts, so mounting this page early used to freeze an empty target
    // list into the future and show "No shortcut folders available" forever.
    // The `context.select` in build() makes the late arrival land here.
    final targets = _resolveTargets();
    final key = _keyFor(targets);
    if (key == _targetsKey) return;
    _targetsKey = key;
    _breakdownsFuture = _scan(targets);
  }

  @override
  void dispose() {
    _aiSub?.cancel();
    super.dispose();
  }

  void refresh() {
    final targets = _resolveTargets();
    _targetsKey = _keyFor(targets);
    setState(() {
      _disksFuture = _svc.diskUsages();
      _breakdownsFuture = _scan(targets);
    });
  }

  List<(String, String)> _resolveTargets() =>
      _targetsFrom(context.read<BrowserProvider>().shortcuts);

  static List<(String, String)> _targetsFrom(Map<String, String?> shortcuts) => [
        for (final label in _scanLabels)
          if ((shortcuts[label] ?? '').isNotEmpty) (label, shortcuts[label]!),
      ];

  static String _keyFor(List<(String, String)> targets) =>
      targets.map((t) => '${t.$1}=${t.$2}').join('|');

  // Concurrent, not sequential: three independent directory reads shouldn't
  // cost the sum of their latencies.
  Future<List<CategoryBreakdown>> _scan(List<(String, String)> targets) =>
      Future.wait(targets.map((t) => _svc.shallowBreakdown(t.$1, t.$2)));

  Future<void> _openFolder(String path) async {
    final browser = context.read<BrowserProvider>();
    browser.showCenterView(CenterView.files);
    await browser.navigateTo(path);
  }

  Future<void> _copyInsight() async {
    await Clipboard.setData(ClipboardData(text: _aiInsight));
    if (!mounted) return;
    ShadToaster.of(context).show(
      const ShadToast(title: Text('Copied'), description: Text('Insight copied to clipboard.')),
    );
  }

  void _cancelAI() {
    _aiSub?.cancel();
    _aiSub = null;
    if (mounted) setState(() => _aiBusy = false);
  }

  Future<void> _runAIInsight(
    SettingsProvider settings,
    List<DiskUsage> disks,
    List<CategoryBreakdown> breakdowns,
  ) async {
    if (settings.model == null) {
      await showShadDialog<void>(
        context: context,
        builder: (ctx) => ShadDialog.alert(
          title: const Text('No model selected'),
          description:
              const Text('Pick a model in Settings to generate insights.'),
          actions: [
            ShadButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    await _aiSub?.cancel();
    setState(() {
      _aiBusy = true;
      _aiInsight = '';
    });

    final llm = settings.defaultClient();
    final stream = llm.generate(
      model: settings.model!,
      prompt: _buildPrompt(disks, breakdowns),
      temperature: settings.temperature,
    );
    _aiSub = stream.listen(
      (chunk) {
        if (mounted) setState(() => _aiInsight += chunk);
      },
      onError: (Object e) {
        if (mounted) {
          setState(() {
            _aiInsight += '\n\n_Error: ${e}_';
            _aiBusy = false;
          });
        }
      },
      onDone: () {
        if (mounted) setState(() => _aiBusy = false);
      },
      cancelOnError: true,
    );
  }

  String _buildPrompt(
    List<DiskUsage> disks,
    List<CategoryBreakdown> breakdowns,
  ) {
    final stats = StringBuffer()
      ..writeln('Host OS: ${_osName()}')
      ..writeln('Disks:');
    for (final d in disks) {
      stats.writeln(
        '  - ${d.name}${d.isRemovable ? ' (removable)' : ''}: '
        'total ${formatBytes(d.totalBytes)}, '
        'used ${formatBytes(d.usedBytes)} '
        '(${(d.usedFraction * 100).toStringAsFixed(0)}%), '
        'free ${formatBytes(d.freeBytes)}',
      );
    }
    stats.writeln('Shortcut folders (one level deep):');
    for (final b in breakdowns) {
      if (b.error != null) {
        stats.writeln('  - ${b.label}: unreadable (${b.error})');
        continue;
      }
      final parts = [
        for (final entry in b.ranked(byBytes: true))
          '${entry.$1.label}=${entry.$2.files} files/'
              '${formatBytes(entry.$2.bytes)}',
      ];
      stats.writeln(
        '  - ${b.label}: ${b.totalFiles} files '
        '(${formatBytes(b.totalBytes)}) — ${parts.join(', ')}',
      );
    }
    return 'You are a concise system assistant. Given the following stats about '
        "a user's machine, write 4-6 short markdown bullet points: storage "
        'health, biggest consumers, things worth cleaning up, and one '
        'suggestion. Keep it under 120 words. Stats:\n\n$stats';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final settings = context.watch<SettingsProvider>();
    // Depend on the *shortcut paths only*, not on BrowserProvider as a whole:
    // this page would otherwise rebuild on every selection and navigation in
    // the file browser. Registering the dependency is what wakes
    // didChangeDependencies() when the map is populated after startup.
    context.select<BrowserProvider, String>(
      (b) => _keyFor(_targetsFrom(b.shortcuts)),
    );

    return ColoredBox(
      color: palette.scaffoldBg,
      child: SafeArea(
        top: false,
        child: FutureBuilder<List<DiskUsage>>(
          future: _disksFuture,
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const _SystemOverviewSkeleton();
            }
            // diskUsages() swallows its own failures, so an error here means
            // something unexpected — surface it rather than spinning forever.
            if (snap.hasError) {
              return _ErrorState(
                message: '${snap.error}',
                onRetry: refresh,
              );
            }
            final disks = snap.data ?? const <DiskUsage>[];
            return FutureBuilder<List<CategoryBreakdown>>(
              future: _breakdownsFuture,
              builder: (ctx2, snap2) {
                final breakdowns = snap2.data ?? const <CategoryBreakdown>[];
                final scanning =
                    snap2.connectionState == ConnectionState.waiting;
                return LayoutBuilder(
                  builder: (ctx3, constraints) {
                    // Two columns of cards from 760px up; on a maximised
                    // display the content stops widening at 1100 so a drive
                    // row doesn't stretch into a full-width band of nothing.
                    final columns = constraints.maxWidth >= 760 ? 2 : 1;
                    return Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1100),
                        child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            _SummaryCard(disks: disks),
                            const SizedBox(height: 18),
                            _SectionHeader(
                              'Drives',
                              trailing: disks.isEmpty
                                  ? null
                                  : ShadBadge.secondary(
                                      child: Text('${disks.length}'),
                                    ),
                            ),
                            const SizedBox(height: 8),
                            if (disks.isEmpty)
                              const _EmptyNote(
                                icon: LucideIcons.hardDrive,
                                text: 'No drives reported on this platform.',
                              )
                            else
                              _CardGrid(
                                columns: columns,
                                children: [
                                  for (final d in disks) _DriveCard(usage: d),
                                ],
                              ),
                            const SizedBox(height: 18),
                            _SectionHeader(
                              'Folder snapshot',
                              trailing: _MetricToggle(
                                metric: _metric,
                                onChanged: (m) => setState(() => _metric = m),
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (scanning)
                              _CardGrid(
                                columns: columns,
                                children: const [
                                  _SkeletonBreakdownCard(),
                                  _SkeletonBreakdownCard(),
                                ],
                              )
                            else if (breakdowns.isEmpty)
                              const _EmptyNote(
                                icon: LucideIcons.folder,
                                text: 'No shortcut folders available.',
                              )
                            else
                              _CardGrid(
                                columns: columns,
                                children: [
                                  for (final b in breakdowns)
                                    _BreakdownCard(
                                      breakdown: b,
                                      metric: _metric,
                                      onOpen: () => _openFolder(b.path),
                                    ),
                                ],
                              ),
                            const SizedBox(height: 18),
                            _AIInsightCard(
                              insight: _aiInsight,
                              busy: _aiBusy,
                              modelLabel: settings.model,
                              onGenerate: () =>
                                  _runAIInsight(settings, disks, breakdowns),
                              onCancel: _cancelAI,
                              onCopy: _copyInsight,
                            ),
                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Platform labels. dart:io compiles on web but throws on use, so every
// Platform read is guarded — this page is otherwise the first thing to crash
// a web build.
// ──────────────────────────────────────────────────────────────────────────

const Map<String, String> _osNames = {
  'macos': 'macOS',
  'windows': 'Windows',
  'linux': 'Linux',
  'android': 'Android',
  'ios': 'iOS',
  'fuchsia': 'Fuchsia',
};

String _osName() {
  if (kIsWeb) return 'Web';
  try {
    final id = Platform.operatingSystem;
    return _osNames[id] ?? id;
  } catch (_) {
    return 'Unknown';
  }
}

String _hostName() {
  if (kIsWeb) return 'This browser';
  try {
    final host = Platform.localHostname;
    return host.isEmpty ? 'This device' : host;
  } catch (_) {
    return 'This device';
  }
}

IconData _hostIcon() {
  if (kIsWeb) return LucideIcons.monitor;
  try {
    if (Platform.isAndroid || Platform.isIOS) return LucideIcons.smartphone;
  } catch (_) {}
  return LucideIcons.laptop;
}

// ──────────────────────────────────────────────────────────────────────────
// Layout helpers
// ──────────────────────────────────────────────────────────────────────────

/// Lays [children] out in fixed-width columns. A plain `GridView` would need a
/// fixed tile height, and these cards vary (a breakdown card with six legend
/// chips is taller than one with two), so rows size to their tallest child.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  static const _gap = 10.0;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    // One card gets the full width — a lone card in a half-width cell reads as
    // a layout bug rather than as a grid.
    if (columns <= 1 || children.length == 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: _gap),
            children[i],
          ],
        ],
      );
    }
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      final slice = children.sublist(
        i,
        math.min(i + columns, children.length),
      );
      // IntrinsicHeight, not `crossAxisAlignment: stretch`: a Row's cross axis
      // is vertical, and inside a ListView that constraint is unbounded, so
      // stretch resolves to an infinite height and the whole row silently
      // lays out to nothing. Intrinsics give the same equal-height result from
      // a bounded measurement.
      rows.add(IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var c = 0; c < columns; c++) ...[
              if (c > 0) const SizedBox(width: _gap),
              // A short final row keeps the empty cells so the last card stays
              // the same width as the ones above it.
              Expanded(
                child: c < slice.length ? slice[c] : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: _gap),
          rows[i],
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 2),
      child: Row(
        children: [
          Text(
            text.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
              color: colors.mutedForeground,
            ),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return ShadCard(
      child: Row(
        children: [
          Icon(icon, size: 16, color: colors.mutedForeground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: colors.mutedForeground),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ShadAlert.destructive(
            icon: const Icon(LucideIcons.triangleAlert),
            title: const Text('Could not read storage'),
            description: Text(message),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: ShadButton.outline(
              leading: const Icon(LucideIcons.refreshCw, size: 14),
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Loading skeleton — mirrors the real layout so content swaps in without a
// jump. Static (no shimmer) to keep it cheap.
// ──────────────────────────────────────────────────────────────────────────

class _SystemOverviewSkeleton extends StatelessWidget {
  const _SystemOverviewSkeleton();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: ListView(
          padding: const EdgeInsets.all(16),
          // No point scrolling a placeholder; also avoids a scroll-position
          // jump when the real (scrollable) list replaces it.
          physics: const NeverScrollableScrollPhysics(),
          children: const [
            _SkeletonSummaryCard(),
            SizedBox(height: 18),
            _SectionHeader('Drives'),
            SizedBox(height: 8),
            _SkeletonDriveCard(),
            SizedBox(height: 10),
            _SkeletonDriveCard(),
            SizedBox(height: 18),
            _SectionHeader('Folder snapshot'),
            SizedBox(height: 8),
            _SkeletonBreakdownCard(),
            SizedBox(height: 10),
            _SkeletonBreakdownCard(),
          ],
        ),
      ),
    );
  }
}

class _SkeletonSummaryCard extends StatelessWidget {
  const _SkeletonSummaryCard();

  @override
  Widget build(BuildContext context) {
    // Every placeholder is flex-sized rather than a fixed pixel width: with both
    // side panels open on a narrow window the card is under 200px wide, and a
    // hardcoded 120 + 88 row overflows it.
    return const ShadCard(
      child: Row(
        children: [
          SkeletonBlock(width: 76, height: 76, radius: 38),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              // Stretch, so the placeholder lines take the card's width instead
              // of a hardcoded one that overflows a narrow card.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SkeletonBlock(height: 14),
                SizedBox(height: 8),
                SkeletonBlock(height: 11),
                SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(child: SkeletonBlock(height: 26)),
                    SizedBox(width: 14),
                    Expanded(child: SkeletonBlock(height: 26)),
                    SizedBox(width: 14),
                    Expanded(child: SkeletonBlock(height: 26)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SkeletonDriveCard extends StatelessWidget {
  const _SkeletonDriveCard();

  @override
  Widget build(BuildContext context) {
    return const ShadCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                flex: 5,
                child: SkeletonBlock(height: 12),
              ),
              Spacer(flex: 4),
              Expanded(
                flex: 2,
                child: SkeletonBlock(height: 12),
              ),
            ],
          ),
          SizedBox(height: 12),
          SkeletonBlock(height: 6, radius: 3),
          SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 4,
                child: SkeletonBlock(height: 10),
              ),
              Spacer(flex: 3),
              Expanded(
                flex: 5,
                child: SkeletonBlock(height: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SkeletonBreakdownCard extends StatelessWidget {
  const _SkeletonBreakdownCard();

  @override
  Widget build(BuildContext context) {
    return const ShadCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                flex: 5,
                child: SkeletonBlock(height: 12),
              ),
              Spacer(flex: 3),
              Expanded(
                flex: 4,
                child: SkeletonBlock(height: 10),
              ),
            ],
          ),
          SizedBox(height: 12),
          SkeletonBlock(height: 8, radius: 4),
          SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 1,
                child: SkeletonBlock(height: 10),
              ),
              SizedBox(width: 12),
              Expanded(
                flex: 1,
                child: SkeletonBlock(height: 10),
              ),
              SizedBox(width: 12),
              Expanded(
                flex: 1,
                child: SkeletonBlock(height: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Summary
// ──────────────────────────────────────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.disks});

  final List<DiskUsage> disks;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    // Removable media is excluded: a plugged-in 4 TB backup drive would
    // otherwise make a nearly-full internal SSD look like it has room.
    final internal = disks.where((d) => !d.isRemovable).toList();
    final counted = internal.isEmpty ? disks : internal;
    final removableCount = disks.length - internal.length;

    final total = counted.fold<int>(0, (a, d) => a + d.totalBytes);
    final used = counted.fold<int>(0, (a, d) => a + d.usedBytes);
    final free = math.max(0, total - used);
    final usedFrac = total == 0 ? 0.0 : used / total;
    final ringColor = _healthColor(context, _fractionHealth(usedFrac));

    return ShadCard(
      child: Row(
        children: [
          _CapacityRing(
            fraction: usedFrac,
            size: 76,
            strokeWidth: 8,
            color: ringColor,
            trackColor: colors.secondary,
            child: Text(
              total == 0 ? '—' : '${(usedFrac * 100).round()}%',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: colors.foreground,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(_hostIcon(), size: 16, color: colors.primary),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        _hostName(),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colors.foreground,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ShadBadge.outline(child: Text(_osName())),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _subtitle(counted.length, removableCount),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: colors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 14),
                // Wrap, not Row: on a narrow window three stats plus a 76px
                // ring overflow, and a clipped byte count is worse than a
                // second line.
                Wrap(
                  spacing: 20,
                  runSpacing: 10,
                  children: [
                    _Stat(label: 'Used', value: formatBytes(used)),
                    _Stat(label: 'Free', value: formatBytes(free)),
                    _Stat(label: 'Capacity', value: formatBytes(total)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _subtitle(int countedDrives, int removableCount) {
    final drives = '$countedDrives '
        'drive${countedDrives == 1 ? '' : 's'}';
    if (removableCount == 0) return drives;
    return '$drives • $removableCount removable volume'
        '${removableCount == 1 ? '' : 's'} excluded';
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 9.5,
            letterSpacing: 0.6,
            fontWeight: FontWeight.w600,
            color: colors.mutedForeground,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.foreground,
          ),
        ),
      ],
    );
  }
}

/// Arc gauge. A ring reads a single ratio faster than a bar at this size, and
/// it gives the summary card a focal point the old flat bar didn't have.
class _CapacityRing extends StatelessWidget {
  const _CapacityRing({
    required this.fraction,
    required this.size,
    required this.color,
    required this.trackColor,
    this.strokeWidth = 6,
    this.child,
  });

  final double fraction;
  final double size;
  final Color color;
  final Color trackColor;
  final double strokeWidth;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _RingPainter(
          fraction: fraction.clamp(0.0, 1.0),
          color: color,
          trackColor: trackColor,
          strokeWidth: strokeWidth,
        ),
        child: child == null ? null : Center(child: child),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.fraction,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  final double fraction;
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawArc(rect, 0, math.pi * 2, false, track);
    if (fraction <= 0) return;
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    // Starts at 12 o'clock so the filled portion reads clockwise.
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * fraction,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.strokeWidth != strokeWidth;
}

// ──────────────────────────────────────────────────────────────────────────
// Drives
// ──────────────────────────────────────────────────────────────────────────

DiskHealth _fractionHealth(double f) {
  if (f >= 0.9) return DiskHealth.critical;
  if (f >= 0.75) return DiskHealth.filling;
  return DiskHealth.healthy;
}

Color _healthColor(BuildContext context, DiskHealth health) {
  final palette = AppColors.of(context);
  switch (health) {
    case DiskHealth.critical:
      return palette.danger;
    case DiskHealth.filling:
      // Amber isn't in the palette; the same value the drive card used before.
      return const Color(0xFFFF9F0A);
    case DiskHealth.healthy:
      return palette.accent;
  }
}

const Map<DiskHealth, String> _healthLabels = {
  DiskHealth.healthy: 'Healthy',
  DiskHealth.filling: 'Filling up',
  DiskHealth.critical: 'Almost full',
};

class _DriveCard extends StatelessWidget {
  const _DriveCard({required this.usage});

  final DiskUsage usage;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final palette = AppColors.of(context);
    final pct = (usage.usedFraction * 100).round();
    final health = usage.health;
    final accent = _healthColor(context, health);

    return ShadCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                usage.isRemovable ? LucideIcons.usb : LucideIcons.hardDrive,
                size: 16,
                color: usage.isRemovable ? palette.folderIcon : colors.mutedForeground,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  usage.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.foreground,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              ShadTooltip(
                builder: (_) => Text(_healthLabels[health]!),
                child: _HealthBadge(health: health, label: '$pct%'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            usage.path,
            style: TextStyle(fontSize: 11, color: colors.mutedForeground),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          ShadProgress(
            value: usage.usedFraction,
            minHeight: 6,
            color: accent,
            backgroundColor: colors.secondary,
            semanticsLabel: '${usage.name} storage used',
            semanticsValue: '$pct percent',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '${formatBytes(usage.usedBytes)} used',
                style: TextStyle(fontSize: 11, color: colors.mutedForeground),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  '${formatBytes(usage.freeBytes)} free of '
                  '${formatBytes(usage.totalBytes)}',
                  style: TextStyle(fontSize: 11, color: colors.mutedForeground),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HealthBadge extends StatelessWidget {
  const _HealthBadge({required this.health, required this.label});

  final DiskHealth health;
  final String label;

  @override
  Widget build(BuildContext context) {
    final text = Text(label, style: const TextStyle(fontSize: 11));
    switch (health) {
      case DiskHealth.critical:
        return ShadBadge.destructive(child: text);
      case DiskHealth.filling:
        return ShadBadge.secondary(child: text);
      case DiskHealth.healthy:
        return ShadBadge.outline(child: text);
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Folder snapshot
// ──────────────────────────────────────────────────────────────────────────

const Map<FileCategory, Color> _categoryColors = {
  FileCategory.images: Color(0xFF4D9BF5),
  FileCategory.videos: Color(0xFFBF5AF2),
  FileCategory.audio: Color(0xFF34C759),
  FileCategory.documents: Color(0xFFFF9F0A),
  FileCategory.code: Color(0xFF64D2FF),
  FileCategory.other: Color(0xFF8E8E93),
};

/// Size / Files switch. [ShadBadge] carries the selected look and
/// [ShadBadge.outline] the unselected one; both take `onPressed` directly.
class _MetricToggle extends StatelessWidget {
  const _MetricToggle({required this.metric, required this.onChanged});

  final _Metric metric;
  final ValueChanged<_Metric> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final m in _Metric.values) ...[
          if (m != _Metric.values.first) const SizedBox(width: 4),
          if (m == metric)
            ShadBadge(
              onPressed: () => onChanged(m),
              child: Text(
                m == _Metric.size ? 'Size' : 'Files',
                style: const TextStyle(fontSize: 11),
              ),
            )
          else
            ShadBadge.outline(
              onPressed: () => onChanged(m),
              child: Text(
                m == _Metric.size ? 'Size' : 'Files',
                style: const TextStyle(fontSize: 11),
              ),
            ),
        ],
      ],
    );
  }
}

class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({
    required this.breakdown,
    required this.metric,
    required this.onOpen,
  });

  final CategoryBreakdown breakdown;
  final _Metric metric;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final palette = AppColors.of(context);
    final b = breakdown;
    final byBytes = metric == _Metric.size;
    final ranked = b.ranked(byBytes: byBytes);

    return ShadCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(LucideIcons.folder, size: 15, color: palette.folderIcon),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  b.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.foreground,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (b.error == null)
                Text(
                  '${b.totalFiles} files • ${formatBytes(b.totalBytes)}',
                  style: TextStyle(fontSize: 11, color: colors.mutedForeground),
                ),
              const SizedBox(width: 4),
              ShadTooltip(
                builder: (_) => const Text('Open folder'),
                child: ShadIconButton.ghost(
                  width: 22,
                  height: 22,
                  padding: EdgeInsets.zero,
                  iconSize: 13,
                  foregroundColor: colors.mutedForeground,
                  onPressed: onOpen,
                  icon: const Icon(LucideIcons.arrowUpRight),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (b.error != null)
            Row(
              children: [
                Icon(
                  LucideIcons.triangleAlert,
                  size: 13,
                  color: colors.mutedForeground,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    b.error!,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.mutedForeground,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            )
          else if (ranked.isEmpty)
            Text(
              'No files at the top level.',
              style: TextStyle(fontSize: 11, color: colors.mutedForeground),
            )
          else ...[
            _StackedBar(ranked: ranked, byBytes: byBytes),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                for (final entry in ranked)
                  _Legend(
                    color: _categoryColors[entry.$1]!,
                    label: entry.$1.label,
                    value: byBytes
                        ? formatBytes(entry.$2.bytes)
                        : '${entry.$2.files}',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StackedBar extends StatelessWidget {
  const _StackedBar({required this.ranked, required this.byBytes});

  final List<(FileCategory, CategorySlice)> ranked;
  final bool byBytes;

  @override
  Widget build(BuildContext context) {
    // Weighted by bytes by default: 400 source files taking 3 MB shouldn't
    // outweigh two 4 GB videos on a storage screen.
    final weights = [
      for (final e in ranked)
        // A 0-byte category with files in it still gets a hairline so the
        // legend and the bar agree on what's present.
        math.max(1, byBytes ? e.$2.bytes : e.$2.files),
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Row(
          // Without stretch the segments get a loose height and a childless
          // ColoredBox collapses to zero — an invisible bar.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < ranked.length; i++)
              Expanded(
                flex: weights[i],
                child: ColoredBox(color: _categoryColors[ranked[i].$1]!),
              ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.color,
    required this.label,
    required this.value,
  });

  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 5),
        Text(
          '$label ',
          style: TextStyle(fontSize: 11, color: colors.mutedForeground),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: colors.foreground,
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// AI insights
// ──────────────────────────────────────────────────────────────────────────

class _AIInsightCard extends StatelessWidget {
  const _AIInsightCard({
    required this.insight,
    required this.busy,
    required this.modelLabel,
    required this.onGenerate,
    required this.onCancel,
    required this.onCopy,
  });

  final String insight;
  final bool busy;
  final String? modelLabel;
  final VoidCallback onGenerate;
  final VoidCallback onCancel;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = theme.colorScheme;
    final hasText = insight.trim().isNotEmpty;

    return ShadCard(
      title: Row(
        children: [
          Icon(LucideIcons.sparkles, size: 16, color: colors.primary),
          const SizedBox(width: 8),
          Text(
            'AI Insights',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colors.foreground,
            ),
          ),
          const Spacer(),
          if (modelLabel != null)
            Flexible(
              child: ShadBadge.outline(
                child: Text(
                  modelLabel!,
                  style: const TextStyle(fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!hasText && !busy)
              Text(
                'Generate a quick analysis of disk usage, big consumers, and '
                'cleanup suggestions using your selected AI model.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: colors.mutedForeground,
                ),
              )
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: colors.muted,
                  border: Border.all(color: colors.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: hasText
                    // Rendered as markdown because the prompt asks for
                    // bullets; raw text showed the "- " literally.
                    ? MarkdownBody(
                        data: insight,
                        styleSheet: MarkdownStyleSheet(
                          p: TextStyle(
                            fontSize: 12.5,
                            height: 1.55,
                            color: colors.foreground,
                          ),
                          listBullet: TextStyle(
                            fontSize: 12.5,
                            height: 1.55,
                            color: colors.mutedForeground,
                          ),
                          strong: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: colors.foreground,
                          ),
                          em: TextStyle(color: colors.mutedForeground),
                        ),
                      )
                    : Row(
                        children: [
                          const ShadSpinner(size: 14),
                          const SizedBox(width: 8),
                          Text(
                            'Thinking…',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.mutedForeground,
                            ),
                          ),
                        ],
                      ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                ShadButton(
                  onPressed: busy ? null : onGenerate,
                  leading: busy
                      ? ShadSpinner(
                          size: 14,
                          color: colors.primaryForeground,
                        )
                      : const Icon(LucideIcons.sparkles, size: 14),
                  child: Text(hasText ? 'Regenerate' : 'Generate insights'),
                ),
                if (busy) ...[
                  const SizedBox(width: 8),
                  ShadButton.ghost(
                    onPressed: onCancel,
                    child: const Text('Stop'),
                  ),
                ],
                const Spacer(),
                if (hasText && !busy)
                  ShadTooltip(
                    builder: (_) => const Text('Copy insight'),
                    child: ShadIconButton.ghost(
                      onPressed: onCopy,
                      icon: const Icon(LucideIcons.copy),
                      iconSize: 14,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
