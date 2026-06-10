import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../providers/browser_provider.dart';
import '../providers/settings_provider.dart';
import '../services/file_service.dart';
import '../services/ollama_service.dart';
import '../services/system_info_service.dart';
import '../theme.dart';

class SystemOverviewScreen extends StatefulWidget {
  const SystemOverviewScreen({super.key});

  @override
  State<SystemOverviewScreen> createState() => _SystemOverviewScreenState();
}

class _SystemOverviewScreenState extends State<SystemOverviewScreen> {
  late final SystemInfoService _svc;
  late Future<List<DiskUsage>> _disksFuture;
  late Future<List<CategoryBreakdown>> _breakdownsFuture;
  String _aiInsight = '';
  bool _aiBusy = false;

  @override
  void initState() {
    super.initState();
    _svc = SystemInfoService(FileService());
    _refresh();
  }

  void _refresh() {
    setState(() {
      _disksFuture = _svc.diskUsages();
      _breakdownsFuture = _loadBreakdowns();
    });
  }

  Future<List<CategoryBreakdown>> _loadBreakdowns() async {
    final browser = context.read<BrowserProvider>();
    final shortcuts = browser.shortcuts;
    final targets = [
      ('Desktop', shortcuts['Desktop']),
      ('Documents', shortcuts['Documents']),
      ('Downloads', shortcuts['Downloads']),
    ];
    final out = <CategoryBreakdown>[];
    for (final t in targets) {
      final path = t.$2;
      if (path == null || path.isEmpty) continue;
      out.add(await _svc.shallowBreakdown(t.$1, path));
    }
    return out;
  }

  Future<void> _runAIInsight(
    SettingsProvider settings,
    List<DiskUsage> disks,
    List<CategoryBreakdown> breakdowns,
  ) async {
    if (settings.model == null) {
      await showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('No model selected'),
          content: const Text(
              'Pick an Ollama model in Settings to generate insights.'),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    setState(() {
      _aiBusy = true;
      _aiInsight = '';
    });
    final stats = StringBuffer();
    stats.writeln('Host OS: ${Platform.operatingSystem}');
    stats.writeln('Disks:');
    for (final d in disks) {
      stats.writeln(
        '  - ${d.name}: total ${formatBytes(d.totalBytes)}, '
        'used ${formatBytes(d.usedBytes)} (${(d.usedFraction * 100).toStringAsFixed(0)}%), '
        'free ${formatBytes(d.freeBytes)}',
      );
    }
    stats.writeln('Shortcut folders (one level deep):');
    for (final b in breakdowns) {
      stats.writeln(
        '  - ${b.label}: ${b.totalFiles} files (${formatBytes(b.totalBytes)}) — '
        'images=${b.images}, videos=${b.videos}, audio=${b.audio}, '
        'docs=${b.documents}, code=${b.code}, other=${b.other}',
      );
    }
    final prompt =
        'You are a concise system assistant. Given the following stats about a '
        "user's machine, write 4-6 short bullet points: storage health, biggest "
        'consumers, things worth cleaning up, and one suggestion. Keep it under '
        '120 words. Stats:\n\n${stats.toString()}';

    final ollama = OllamaService(settings.host);
    try {
      await for (final chunk in ollama.generate(
        model: settings.model!,
        prompt: prompt,
        temperature: settings.temperature,
      )) {
        if (!mounted) return;
        setState(() => _aiInsight += chunk);
      }
    } catch (e) {
      if (mounted) setState(() => _aiInsight += '\n\n[error: $e]');
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final settings = context.watch<SettingsProvider>();

    return CupertinoPageScaffold(
      backgroundColor: palette.scaffoldBg,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: palette.headerBg,
        border: Border(bottom: BorderSide(color: palette.divider)),
        middle: const Text('System Overview'),
        trailing: CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          onPressed: _refresh,
          child: Icon(
            CupertinoIcons.arrow_clockwise,
            size: 18,
            color: palette.accent,
          ),
        ),
      ),
      child: SafeArea(
        child: FutureBuilder<List<DiskUsage>>(
          future: _disksFuture,
          builder: (ctx, snap) {
            if (!snap.hasData) {
              return const Center(child: CupertinoActivityIndicator());
            }
            final disks = snap.data!;
            return FutureBuilder<List<CategoryBreakdown>>(
              future: _breakdownsFuture,
              builder: (ctx2, snap2) {
                final breakdowns = snap2.data ?? const [];
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _SystemSummaryCard(
                      disks: disks,
                      palette: palette,
                    ),
                    const SizedBox(height: 16),
                    _SectionLabel('Drives', palette: palette),
                    const SizedBox(height: 8),
                    if (disks.isEmpty)
                      Text(
                        'No drives reported.',
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.subtleText,
                        ),
                      )
                    else
                      ...disks.map((d) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _DriveCard(usage: d, palette: palette),
                          )),
                    const SizedBox(height: 16),
                    _SectionLabel('Quick Folder Scan', palette: palette),
                    const SizedBox(height: 8),
                    if (snap2.connectionState == ConnectionState.waiting)
                      const Center(child: CupertinoActivityIndicator())
                    else if (breakdowns.isEmpty)
                      Text(
                        'No shortcut folders available.',
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.subtleText,
                        ),
                      )
                    else
                      ...breakdowns.map((b) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _BreakdownCard(
                              breakdown: b,
                              palette: palette,
                            ),
                          )),
                    const SizedBox(height: 16),
                    _AISection(
                      palette: palette,
                      insight: _aiInsight,
                      busy: _aiBusy,
                      onGenerate: () =>
                          _runAIInsight(settings, disks, breakdowns),
                      modelLabel: settings.model,
                    ),
                    const SizedBox(height: 24),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {required this.palette});
  final String text;
  final AppPalette palette;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          letterSpacing: 0.5,
          fontWeight: FontWeight.w600,
          color: palette.subtleText,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, required this.palette});
  final Widget child;
  final AppPalette palette;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.cardBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }
}

class _SystemSummaryCard extends StatelessWidget {
  const _SystemSummaryCard({required this.disks, required this.palette});
  final List<DiskUsage> disks;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final total = disks.fold<int>(0, (a, d) => a + d.totalBytes);
    final used = disks.fold<int>(0, (a, d) => a + d.usedBytes);
    final free = total - used;
    final usedFrac = total == 0 ? 0.0 : used / total;

    return _Card(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.device_laptop,
                size: 22,
                color: palette.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      Platform.localHostname,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: palette.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${Platform.operatingSystem.toUpperCase()} • '
                      '${disks.length} drive${disks.length == 1 ? '' : 's'}',
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.subtleText,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _UsageBar(
            fraction: usedFrac,
            palette: palette,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _LegendDot(
                color: palette.accent,
                label: 'Used',
                value: formatBytes(used),
                palette: palette,
              ),
              const SizedBox(width: 18),
              _LegendDot(
                color: palette.divider,
                label: 'Free',
                value: formatBytes(free),
                palette: palette,
              ),
              const Spacer(),
              Text(
                formatBytes(total),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DriveCard extends StatelessWidget {
  const _DriveCard({required this.usage, required this.palette});
  final DiskUsage usage;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final pct = (usage.usedFraction * 100).toStringAsFixed(0);
    final accent = usage.usedFraction > 0.9
        ? palette.danger
        : (usage.usedFraction > 0.75 ? const Color(0xFFFF9F0A) : palette.accent);
    return _Card(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                usage.isRoot
                    ? CupertinoIcons.device_laptop
                    : CupertinoIcons.archivebox_fill,
                size: 18,
                color: usage.isRoot ? palette.subtleText : palette.folderIcon,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  usage.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '$pct%',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            usage.path,
            style: TextStyle(
              fontSize: 11,
              color: palette.subtleText,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          _UsageBar(
            fraction: usage.usedFraction,
            palette: palette,
            color: accent,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                '${formatBytes(usage.usedBytes)} used',
                style: TextStyle(
                  fontSize: 11,
                  color: palette.subtleText,
                ),
              ),
              const Spacer(),
              Text(
                '${formatBytes(usage.freeBytes)} free of ${formatBytes(usage.totalBytes)}',
                style: TextStyle(
                  fontSize: 11,
                  color: palette.subtleText,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({required this.breakdown, required this.palette});
  final CategoryBreakdown breakdown;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final b = breakdown;
    return _Card(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.folder_fill,
                size: 16,
                color: palette.folderIcon,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  b.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
              ),
              Text(
                '${b.totalFiles} files • ${formatBytes(b.totalBytes)}',
                style: TextStyle(
                  fontSize: 11,
                  color: palette.subtleText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _StackedBar(breakdown: b, palette: palette),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              _Legend(
                color: const Color(0xFF4D9BF5),
                label: 'Images',
                count: b.images,
                palette: palette,
              ),
              _Legend(
                color: const Color(0xFFBF5AF2),
                label: 'Videos',
                count: b.videos,
                palette: palette,
              ),
              _Legend(
                color: const Color(0xFF34C759),
                label: 'Audio',
                count: b.audio,
                palette: palette,
              ),
              _Legend(
                color: const Color(0xFFFF9F0A),
                label: 'Docs',
                count: b.documents,
                palette: palette,
              ),
              _Legend(
                color: const Color(0xFF8E8E93),
                label: 'Code',
                count: b.code,
                palette: palette,
              ),
              _Legend(
                color: const Color(0xFF6E6E73),
                label: 'Other',
                count: b.other,
                palette: palette,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StackedBar extends StatelessWidget {
  const _StackedBar({required this.breakdown, required this.palette});
  final CategoryBreakdown breakdown;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final b = breakdown;
    final total = b.totalFiles;
    if (total == 0) {
      return Container(
        height: 8,
        decoration: BoxDecoration(
          color: palette.divider,
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }
    final segments = <_Segment>[
      _Segment(b.images, const Color(0xFF4D9BF5)),
      _Segment(b.videos, const Color(0xFFBF5AF2)),
      _Segment(b.audio, const Color(0xFF34C759)),
      _Segment(b.documents, const Color(0xFFFF9F0A)),
      _Segment(b.code, const Color(0xFF8E8E93)),
      _Segment(b.other, const Color(0xFF6E6E73)),
    ].where((s) => s.value > 0).toList();

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Row(
          children: segments
              .map((s) => Expanded(
                    flex: s.value,
                    child: Container(color: s.color),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

class _Segment {
  _Segment(this.value, this.color);
  final int value;
  final Color color;
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({
    required this.fraction,
    required this.palette,
    this.color,
  });
  final double fraction;
  final AppPalette palette;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 8,
      decoration: BoxDecoration(
        color: palette.divider,
        borderRadius: BorderRadius.circular(4),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: fraction.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            color: color ?? palette.accent,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({
    required this.color,
    required this.label,
    required this.value,
    required this.palette,
  });
  final Color color;
  final String label;
  final String value;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration:
              BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 6),
        Text(
          '$label  ',
          style: TextStyle(fontSize: 11, color: palette.subtleText),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: palette.text,
          ),
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.color,
    required this.label,
    required this.count,
    required this.palette,
  });
  final Color color;
  final String label;
  final int count;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
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
          style: TextStyle(fontSize: 11, color: palette.subtleText),
        ),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: palette.text,
          ),
        ),
      ],
    );
  }
}

class _AISection extends StatelessWidget {
  const _AISection({
    required this.palette,
    required this.insight,
    required this.busy,
    required this.onGenerate,
    required this.modelLabel,
  });
  final AppPalette palette;
  final String insight;
  final bool busy;
  final VoidCallback onGenerate;
  final String? modelLabel;

  @override
  Widget build(BuildContext context) {
    return _Card(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.sparkles,
                size: 18,
                color: palette.accent,
              ),
              const SizedBox(width: 8),
              Text(
                'AI Insights',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                ),
              ),
              const Spacer(),
              if (modelLabel != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: palette.headerBg,
                    border: Border.all(color: palette.divider),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    modelLabel!,
                    style: TextStyle(
                      fontSize: 10,
                      color: palette.subtleText,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (insight.isEmpty && !busy)
            Text(
              'Generate a quick analysis of disk usage, big consumers, and '
              'cleanup suggestions using your selected Ollama model.',
              style: TextStyle(
                fontSize: 12,
                color: palette.subtleText,
                height: 1.4,
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: palette.headerBg,
                border: Border.all(color: palette.divider),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                insight.isEmpty ? '…' : insight,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: palette.text,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: CupertinoButton.filled(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              onPressed: busy ? null : onGenerate,
              child: busy
                  ? const CupertinoActivityIndicator(
                      color: CupertinoColors.white,
                      radius: 8,
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          CupertinoIcons.sparkles,
                          size: 14,
                          color: CupertinoColors.white,
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Generate insights',
                          style: TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
