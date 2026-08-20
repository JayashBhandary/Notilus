import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/file_entry.dart';
import '../providers/browser_provider.dart';
import '../services/system_info_service.dart' show formatBytes;
import '../services/remote/remote_path.dart';
import '../theme.dart';
import 'file_thumbnail.dart';

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
          _Row(label: 'Where', value: VPath.dirname(entry.path), wrap: true),
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

/// The big preview at the top of the panel.
///
/// Every format the app can preview shows here, not just images: a frame from
/// a video, a PDF's first page, the cover inside an office document or ebook,
/// the opening lines of a text file. [FilePreviewBuilder] decides which, so
/// this pane and the icon grid always agree about what a file can show.
class _Preview extends StatelessWidget {
  const _Preview({required this.entry});
  final FileEntry entry;

  /// The preview grows with the panel instead of sitting at a fixed 168px —
  /// the pane is 320 to 400-odd wide and a detail view is the one place worth
  /// spending that space. Capped so a very wide pane doesn't push the
  /// Information rows off the first screen.
  static const double _maxSize = 320;
  static const double _minSize = 140;

  /// Pixel width previews are generated and decoded at.
  ///
  /// A constant rather than `size * 2`: the dimension is part of the on-disk
  /// cache key, so deriving it from a resizable pane would mint a new cache
  /// entry — and re-run ffmpeg — on every drag of the divider. Twice the
  /// widest the box ever gets, so it stays sharp on a Retina panel.
  static const int _previewDim = 640;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : _maxSize;
        final size = available.clamp(_minSize, _maxSize);
        return SizedBox(
          width: size,
          height: size,
          child: _content(context, size),
        );
      },
    );
  }

  Widget _content(BuildContext context, double size) {
    final palette = AppColors.of(context);
    if (entry.isDirectory) {
      return Center(
        child: Icon(
          LucideIcons.folder,
          size: size * 0.78,
          color: palette.folderIcon,
        ),
      );
    }

    final isVideo = isPreviewableVideo(entry);
    return FilePreviewBuilder(
      entry: entry,
      dim: _previewDim,
      builder: (context, preview) {
        final body = _forPreview(context, preview, size);
        if (!isVideo) return body;
        return Stack(
          fit: StackFit.expand,
          children: [
            body,
            // Stays whether or not a frame was extracted, so a video reads as
            // playable even when it falls back to a glyph.
            Positioned(
              right: 8,
              bottom: 8,
              child: _PlayBadge(size: size),
            ),
          ],
        );
      },
    );
  }

  Widget _forPreview(BuildContext context, FilePreview preview, double size) {
    switch (preview) {
      case FilePreviewImage(:final file, :final isPaper):
        return _Framed(
          isPaper: isPaper,
          child: Image.file(
            file,
            key: ValueKey(file.path),
            fit: BoxFit.contain,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: _previewDim,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _Placeholder(entry: entry),
          ),
        );
      case FilePreviewSvg(:final bytes):
        return _Framed(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SvgPicture.memory(
              bytes,
              fit: BoxFit.contain,
              placeholderBuilder: (_) => const SizedBox.shrink(),
            ),
          ),
        );
      case FilePreviewText(:final snippet):
        return _TextMiniature(text: snippet, size: size);
      case FilePreviewNone():
        return _Placeholder(entry: entry);
    }
  }
}

/// Rounded, bordered box the non-glyph previews sit in.
class _Framed extends StatelessWidget {
  const _Framed({required this.child, this.isPaper = false});
  final Widget child;
  final bool isPaper;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: isPaper ? const Color(0xFFFFFFFF) : colors.muted,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: child,
    );
  }
}

/// Finder-style miniature of a text file's opening lines.
class _TextMiniature extends StatelessWidget {
  const _TextMiniature({required this.text, required this.size});
  final String text;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return _Framed(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 6, 0),
        child: ClipRect(
          child: Text(
            text,
            maxLines: (size / 11).round().clamp(8, 30),
            overflow: TextOverflow.fade,
            softWrap: true,
            style: TextStyle(
              fontFamily: 'Menlo',
              // Readable here, unlike the grid's 5.5pt smudge: this box is
              // twenty times the area and the text is meant to be skimmed.
              fontSize: (size / 32).clamp(7.0, 10.0),
              height: 1.25,
              color: colors.foreground,
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayBadge extends StatelessWidget {
  const _PlayBadge({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final edge = (size * 0.16).clamp(24.0, 44.0);
    return Container(
      width: edge,
      height: edge,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colors.card.withValues(alpha: 0.85),
        border: Border.all(color: colors.border),
      ),
      alignment: Alignment.center,
      child: Icon(
        LucideIcons.play,
        size: edge * 0.45,
        color: colors.foreground,
      ),
    );
  }
}

/// Shown while a preview is being generated and when there is none to be had.
///
/// Sized by its parent rather than fixed, so it fills the same box the real
/// preview will and nothing shifts when one arrives.
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.hasBoundedWidth ? constraints.maxWidth : 168.0;
        return Container(
          decoration: BoxDecoration(
            color: colors.muted,
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                LucideIcons.file,
                size: (size * 0.43).clamp(48.0, 120.0),
                color: colors.mutedForeground,
              ),
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
      },
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
