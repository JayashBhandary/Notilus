import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../models/file_entry.dart';
import '../providers/browser_provider.dart';
import '../theme.dart';

class InfoPanel extends StatelessWidget {
  const InfoPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserProvider>();
    final palette = AppColors.of(context);
    final entry = browser.primarySelection;

    return ColoredBox(
      color: palette.contentBg,
      child: entry == null
          ? _EmptyState(palette: palette)
          : _Details(entry: entry, palette: palette),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.info_circle,
              size: 32,
              color: palette.subtleText,
            ),
            const SizedBox(height: 10),
            Text(
              'Select a file to see details',
              style: TextStyle(
                fontSize: 13,
                color: palette.subtleText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.entry, required this.palette});
  final FileEntry entry;
  final AppPalette palette;

  String _formatSize(int b) {
    if (b < 1024) return '$b bytes';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

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
    final ext = entry.extension;
    final modified = _formatDate(entry.modified);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Preview
          Center(
            child: _Preview(entry: entry, palette: palette),
          ),
          const SizedBox(height: 14),
          // Name (bold, centered)
          Text(
            entry.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: palette.text,
            ),
          ),
          const SizedBox(height: 4),
          // Subtitle
          Text(
            entry.isDirectory
                ? _kind()
                : '${_kind()} — ${_formatSize(entry.size)}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: palette.subtleText,
            ),
          ),
          const SizedBox(height: 20),
          // Information section
          _SectionLabel('Information', palette: palette),
          const SizedBox(height: 6),
          _Row(label: 'Modified', value: modified, palette: palette),
          _Row(
            label: 'Where',
            value: p.dirname(entry.path),
            palette: palette,
            wrap: true,
          ),
          _Row(label: 'Kind', value: _kind(), palette: palette),
          if (!entry.isDirectory)
            _Row(
              label: 'Size',
              value: _formatSize(entry.size),
              palette: palette,
            ),
          if (ext.isNotEmpty)
            _Row(label: 'Extension', value: ext, palette: palette),
          const SizedBox(height: 16),
          _SectionLabel('Tags', palette: palette),
          const SizedBox(height: 8),
          Text(
            'Add Tags…',
            style: TextStyle(
              fontSize: 12,
              color: palette.subtleText,
            ),
          ),
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.entry, required this.palette});
  final FileEntry entry;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    const size = 168.0;
    if (entry.isDirectory) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Icon(
            CupertinoIcons.folder_fill,
            size: 140,
            color: palette.folderIcon,
          ),
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
          errorBuilder: (_, __, ___) => _placeholder(),
        ),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    final label = entry.extension.isEmpty
        ? ''
        : entry.extension.substring(1).toUpperCase();
    return Container(
      width: 168,
      height: 168,
      decoration: BoxDecoration(
        color: palette.cardBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.doc,
            size: 80,
            color: palette.subtleText,
          ),
          if (label.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: palette.subtleText,
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
  const _SectionLabel(this.text, {required this.palette});
  final String text;
  final AppPalette palette;
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: palette.text,
        letterSpacing: 0.3,
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    required this.palette,
    this.wrap = false,
  });

  final String label;
  final String value;
  final AppPalette palette;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
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
                color: palette.subtleText,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              maxLines: wrap ? 3 : 1,
              overflow:
                  wrap ? TextOverflow.ellipsis : TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: palette.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
