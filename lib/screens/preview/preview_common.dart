import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../models/file_entry.dart';
import '../../widgets/shad_spinner.dart';

// ──────────────────────────────────────────────────────────────────────────
// Formatting
// ──────────────────────────────────────────────────────────────────────────

/// Human byte size, e.g. `1.2 MB`.
///
/// The old preview carried three near-identical copies of this (one per viewer
/// that needed it) which had drifted apart on precision and unit thresholds.
String formatPreviewBytes(int bytes, {bool exact = false}) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var size = bytes / 1024;
  var idx = 0;
  while (size >= 1024 && idx < units.length - 1) {
    size /= 1024;
    idx++;
  }
  final digits = size >= 100 ? 0 : (size >= 10 ? 1 : 2);
  final short = '${size.toStringAsFixed(digits)} ${units[idx]}';
  return exact ? '$short ($bytes bytes)' : short;
}

/// `mm:ss`, or `h:mm:ss` past an hour. Shared by the video and audio viewers,
/// which previously had one implementation each.
String formatPreviewDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String formatPreviewDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}';
}

const Map<String, String> _kindNames = {
  '.pdf': 'PDF document',
  '.png': 'PNG image',
  '.jpg': 'JPEG image',
  '.jpeg': 'JPEG image',
  '.gif': 'GIF image',
  '.webp': 'WebP image',
  '.svg': 'SVG vector image',
  '.svgz': 'Compressed SVG',
  '.heic': 'HEIC image',
  '.bmp': 'Bitmap image',
  '.tif': 'TIFF image',
  '.tiff': 'TIFF image',
  '.ico': 'Icon image',
  '.md': 'Markdown document',
  '.markdown': 'Markdown document',
  '.txt': 'Plain text',
  '.docx': 'Word document',
  '.doc': 'Word document (legacy)',
  '.odt': 'OpenDocument text',
  '.rtf': 'Rich Text Format',
  '.xlsx': 'Excel spreadsheet',
  '.xls': 'Excel spreadsheet (legacy)',
  '.ods': 'OpenDocument spreadsheet',
  '.pptx': 'PowerPoint presentation',
  '.ppt': 'PowerPoint presentation (legacy)',
  '.odp': 'OpenDocument presentation',
  '.zip': 'ZIP archive',
  '.tar': 'TAR archive',
  '.gz': 'GZip archive',
  '.tgz': 'Compressed TAR archive',
  '.bz2': 'BZip2 archive',
  '.mp4': 'MP4 video',
  '.mov': 'QuickTime video',
  '.mkv': 'Matroska video',
  '.webm': 'WebM video',
  '.mp3': 'MP3 audio',
  '.wav': 'WAV audio',
  '.m4a': 'M4A audio',
  '.flac': 'FLAC audio',
  '.ogg': 'OGG audio',
};

/// Finder-style "Kind" string for an extension.
String previewKind(String ext) =>
    _kindNames[ext] ??
    (ext.isEmpty ? 'File' : '${ext.substring(1).toUpperCase()} file');

/// Bare uppercase extension for the top-bar badge, e.g. `PNG`. Empty when the
/// file has no extension.
String previewExtLabel(FileEntry file) =>
    file.extension.isEmpty ? '' : file.extension.substring(1).toUpperCase();

// ──────────────────────────────────────────────────────────────────────────
// Extension routing
// ──────────────────────────────────────────────────────────────────────────

/// The kinds of content the preview knows how to render.
enum PreviewKind {
  image,
  svg,
  markdown,
  text,
  pdf,
  office,
  archive,
  video,
  audio,
  unsupported,
}

const _imageExts = {
  '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic', '.tif', '.tiff',
  '.ico',
};
const _svgExts = {'.svg', '.svgz'};
const _markdownExts = {'.md', '.markdown', '.mdown'};
const _textExts = {
  '.txt', '.json', '.yaml', '.yml', '.xml', '.csv', '.tsv',
  '.html', '.htm', '.css', '.scss', '.less',
  '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx',
  '.dart', '.py', '.rb', '.go', '.rs', '.c', '.cpp', '.cc', '.h', '.hpp',
  '.java', '.kt', '.swift', '.sh', '.bash', '.zsh', '.fish',
  '.toml', '.ini', '.conf', '.cfg', '.env', '.log',
  '.lua', '.pl', '.php', '.sql', '.r', '.scala', '.groovy',
  '.gradle', '.cmake', '.dockerfile', '.gitignore', '.gitattributes',
};
const _officeExts = {
  '.docx', '.doc', '.odt', '.rtf',
  '.xlsx', '.xls', '.ods',
  '.pptx', '.ppt', '.odp',
};
const _archiveExts = {
  '.zip', '.jar', '.tar', '.tgz', '.gz', '.bz2', '.tbz2', '.tar.gz',
  '.tar.bz2',
};
const _videoExts = {'.mp4', '.mov', '.m4v', '.mkv', '.webm', '.avi'};
const _audioExts = {
  '.mp3', '.wav', '.m4a', '.aac', '.flac', '.ogg', '.opus', '.wma',
};

/// The file's extension, treating compound suffixes like `.tar.gz` as one.
String normalisedExt(FileEntry file) {
  final lower = file.name.toLowerCase();
  if (lower.endsWith('.tar.gz')) return '.tar.gz';
  if (lower.endsWith('.tar.bz2')) return '.tar.bz2';
  return file.extension;
}

PreviewKind previewKindFor(FileEntry file) {
  final ext = normalisedExt(file);
  if (_imageExts.contains(ext)) return PreviewKind.image;
  if (_svgExts.contains(ext)) return PreviewKind.svg;
  if (_markdownExts.contains(ext)) return PreviewKind.markdown;
  if (_textExts.contains(ext)) return PreviewKind.text;
  if (ext == '.pdf') return PreviewKind.pdf;
  if (_officeExts.contains(ext)) return PreviewKind.office;
  if (_archiveExts.contains(ext)) return PreviewKind.archive;
  if (_videoExts.contains(ext)) return PreviewKind.video;
  if (_audioExts.contains(ext)) return PreviewKind.audio;
  return PreviewKind.unsupported;
}

/// Representative glyph for a kind — used by the filmstrip and the fallback
/// viewer so a non-image file still reads as *something*.
IconData previewGlyphFor(PreviewKind kind) => switch (kind) {
      PreviewKind.image => LucideIcons.image,
      PreviewKind.svg => LucideIcons.image,
      PreviewKind.markdown => LucideIcons.fileText,
      PreviewKind.text => LucideIcons.fileCode,
      PreviewKind.pdf => LucideIcons.fileText,
      PreviewKind.office => LucideIcons.fileText,
      PreviewKind.archive => LucideIcons.fileArchive,
      PreviewKind.video => LucideIcons.film,
      PreviewKind.audio => LucideIcons.music,
      PreviewKind.unsupported => LucideIcons.file,
    };

/// True when the filmstrip can render a real bitmap for this file.
bool previewHasBitmapThumb(FileEntry file) =>
    previewKindFor(file) == PreviewKind.image;

// ──────────────────────────────────────────────────────────────────────────
// Opening in the platform's own app
// ──────────────────────────────────────────────────────────────────────────

/// Hands [path] to the OS. Best effort — a missing handler is not worth
/// interrupting the preview for.
Future<void> openPathExternally(String path) async {
  if (kIsWeb) return;
  try {
    if (Platform.isLinux) {
      await Process.run('xdg-open', [path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', path]);
    }
  } catch (_) {}
}

// ──────────────────────────────────────────────────────────────────────────
// Chrome
// ──────────────────────────────────────────────────────────────────────────

/// How much space the shell's own chrome takes at the bottom of the content
/// area, so a viewer's floating toolbar can sit clear of it.
///
/// Provided by the shell and read by [PreviewToolbar]; an inherited value keeps
/// it out of all thirteen viewer constructors.
class PreviewInsets extends InheritedWidget {
  const PreviewInsets({super.key, required this.bottom, required super.child});

  final double bottom;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PreviewInsets>()?.bottom ?? 0;

  @override
  bool updateShouldNotify(PreviewInsets oldWidget) =>
      oldWidget.bottom != bottom;
}

/// Floating control strip a viewer can put over its content.
///
/// Every viewer used to build its own pill with its own padding, radius and
/// shadow. This is the one implementation.
class PreviewToolbar extends StatelessWidget {
  const PreviewToolbar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Positioned(
      bottom: 16 + PreviewInsets.of(context),
      left: 0,
      right: 0,
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.popover.withValues(alpha: 0.94),
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 14,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );
  }
}

/// One icon control inside a [PreviewToolbar].
class PreviewToolbarButton extends StatelessWidget {
  const PreviewToolbarButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.selected = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final button = ShadIconButton.ghost(
      width: 34,
      height: 30,
      padding: EdgeInsets.zero,
      iconSize: 17,
      // ShadIconButton reads its disabled look off `enabled`, not off a null
      // callback, so both have to be set.
      enabled: onPressed != null,
      onPressed: onPressed,
      backgroundColor: selected ? colors.accent : null,
      foregroundColor: selected ? colors.primary : colors.foreground,
      icon: Icon(icon),
    );
    if (tooltip == null) return button;
    return ShadTooltip(
      builder: (_) => Text(tooltip!, style: const TextStyle(fontSize: 11.5)),
      child: button,
    );
  }
}

/// Read-only text inside a [PreviewToolbar] (zoom %, page counter, …).
class PreviewToolbarLabel extends StatelessWidget {
  const PreviewToolbarLabel({super.key, required this.text, this.onTap});
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final label = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: colors.mutedForeground,
        ),
      ),
    );
    if (onTap == null) return label;
    return ShadButton.ghost(
      onPressed: onTap,
      height: 30,
      padding: EdgeInsets.zero,
      child: label,
    );
  }
}

class PreviewToolbarDivider extends StatelessWidget {
  const PreviewToolbarDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: SizedBox(
          height: 18,
          child: ShadSeparator.vertical(
            margin: EdgeInsets.zero,
            thickness: 1,
            color: ShadTheme.of(context).colorScheme.border,
          ),
        ),
      );
}

/// Centred icon + message, used for every "couldn't render this" and
/// "nothing here" state across the viewers.
class PreviewMessage extends StatelessWidget {
  const PreviewMessage({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Tints the glyph with `destructive` — for failures, as opposed to the
  /// merely-unsupported case.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        // 420 left the action button 332px of inner width, 13px short of
        // "Open in external viewer" — every failed-render message overflowed.
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 40,
                color: destructive ? colors.destructive : colors.mutedForeground,
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colors.foreground,
                ),
              ),
              if (body != null) ...[
                const SizedBox(height: 8),
                Text(
                  body!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: colors.mutedForeground,
                  ),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 18),
                ShadButton(
                  onPressed: onAction,
                  leading: const Icon(LucideIcons.externalLink, size: 15),
                  // Flexible as well as the wider box above: at a large OS
                  // text size no fixed width is enough, and an ellipsis beats
                  // an overflow stripe.
                  child: Flexible(
                    child: Text(
                      actionLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Spinner with an optional caption, for the viewers that decode or convert
/// before they can show anything.
class PreviewLoading extends StatelessWidget {
  const PreviewLoading({super.key, this.caption});
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ShadSpinner(size: 22),
          if (caption != null) ...[
            const SizedBox(height: 12),
            Text(
              caption!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: colors.mutedForeground),
            ),
          ],
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Page rail — shared by both PDF viewers
// ──────────────────────────────────────────────────────────────────────────

/// Vertical page-thumbnail rail.
///
/// One widget for both PDF paths: the pdfx viewer renders thumbnails on demand
/// through [thumbnailBuilder], while the Linux/poppler path already has PNGs on
/// disk and returns `Image.file` from the same hook. Previously these were two
/// near-identical classes.
class PreviewPageRail extends StatelessWidget {
  const PreviewPageRail({
    super.key,
    required this.pageCount,
    required this.currentPage,
    required this.onSelect,
    required this.thumbnailBuilder,
  });

  final int pageCount;
  final int currentPage;
  final ValueChanged<int> onSelect;

  /// Builds the bitmap for a 1-based page number.
  final Widget Function(BuildContext context, int page) thumbnailBuilder;

  static const double width = 108;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: colors.muted.withValues(alpha: 0.97),
        border: Border(right: BorderSide(color: colors.border)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'PAGES',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w600,
                color: colors.mutedForeground,
              ),
            ),
          ),
          const ShadSeparator.horizontal(margin: EdgeInsets.zero, thickness: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: pageCount,
              itemBuilder: (ctx, i) {
                final page = i + 1;
                final selected = page == currentPage;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onSelect(page),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFFFFF),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: selected ? colors.primary : colors.border,
                              width: selected ? 2 : 1,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: thumbnailBuilder(ctx, page),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '$page',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w400,
                            color: selected
                                ? colors.primary
                                : colors.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// "Go to page" prompt. Both PDF viewers used to carry a copy of this.
Future<int?> promptForPage(
  BuildContext context, {
  required int current,
  required int pageCount,
}) async {
  final controller = TextEditingController(text: '$current');
  return showShadDialog<int>(
    context: context,
    builder: (ctx) => ShadDialog.alert(
      title: const Text('Go to page'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton(
          onPressed: () =>
              Navigator.of(ctx).pop(int.tryParse(controller.text.trim())),
          child: const Text('Go'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: ShadInput(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          placeholder: Text('1 – $pageCount'),
          onSubmitted: (v) => Navigator.of(ctx).pop(int.tryParse(v.trim())),
        ),
      ),
    ),
  );
}
