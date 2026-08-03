import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/file_entry.dart';
import '../providers/browser_provider.dart';
import '../services/system_info_service.dart' show formatBytes;
import '../theme.dart';

class InfoPanel extends StatelessWidget {
  const InfoPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserProvider>();
    final colors = ShadTheme.of(context).colorScheme;
    final entry = browser.primarySelection;

    return ColoredBox(
      color: colors.background,
      child: entry == null
          ? const _EmptyState()
          : _Details(entry: entry),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.info, size: 32, color: colors.mutedForeground),
            const SizedBox(height: 10),
            Text(
              'Select a file to see details',
              style: TextStyle(
                fontSize: 13,
                color: colors.mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.entry});
  final FileEntry entry;

  String _formatDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    final months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${two(dt.day)} ${months[dt.month - 1]} ${dt.year} at '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  String _kind() {
    if (entry.isDirectory) return 'Folder';
    final ext = entry.extension;
    if (ext.isEmpty) return 'Document';
    return '${ext.substring(1).toUpperCase()} file';
  }

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final ext = entry.extension;
    final modified = _formatDate(entry.modified);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Preview
          Center(child: _Preview(entry: entry)),
          const SizedBox(height: 14),
          // Name (bold, centered)
          Text(
            entry.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colors.foreground,
            ),
          ),
          const SizedBox(height: 4),
          // Subtitle
          Text(
            entry.isDirectory
                ? _kind()
                : '${_kind()} — ${formatBytes(entry.size)}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: colors.mutedForeground,
            ),
          ),
          const SizedBox(height: 20),
          // Information section
          const _SectionLabel('Information'),
          const SizedBox(height: 6),
          _Row(label: 'Modified', value: modified),
          _Row(label: 'Where', value: p.dirname(entry.path), wrap: true),
          _Row(label: 'Kind', value: _kind()),
          if (!entry.isDirectory)
            _Row(label: 'Size', value: formatBytes(entry.size)),
          if (ext.isNotEmpty) _Row(label: 'Extension', value: ext),
          const SizedBox(height: 16),
          const _SectionLabel('Tags'),
          const SizedBox(height: 8),
          // Inert, like the sidebar's Tags rows — there is no tag storage yet.
          Text(
            'Add Tags…',
            style: TextStyle(fontSize: 12, color: colors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.entry});
  final FileEntry entry;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    const size = 168.0;
    if (entry.isDirectory) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Icon(LucideIcons.folder, size: 132, color: palette.folderIcon),
        ),
      );
    }
    if (entry.isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(entry.path),
          width: size,
          height: size,
          fit: BoxFit.contain,
          cacheWidth: 400,
          errorBuilder: (_, __, ___) => _Placeholder(entry: entry),
        ),
      );
    }
    return _Placeholder(entry: entry);
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.entry});
  final FileEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = theme.colorScheme;
    final label = entry.extension.isEmpty
        ? ''
        : entry.extension.substring(1).toUpperCase();
    return Container(
      width: 168,
      height: 168,
      decoration: BoxDecoration(
        color: colors.muted,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.file, size: 72, color: colors.mutedForeground),
          if (label.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.mutedForeground,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: ShadTheme.of(context).colorScheme.foreground,
        letterSpacing: 0.3,
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.wrap = false,
  });

  final String label;
  final String value;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                color: colors.mutedForeground,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              maxLines: wrap ? 3 : 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.foreground),
            ),
          ),
        ],
      ),
    );
  }
}
