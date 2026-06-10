import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../models/file_entry.dart';
import '../providers/browser_provider.dart';
import '../services/thumbnail_service.dart';
import '../theme.dart';
import '../utils/responsive.dart';
import 'file_list_view.dart' show openFilePreview;

class FileIconGrid extends StatelessWidget {
  const FileIconGrid({super.key, required this.onSecondaryRowTap});

  final void Function(FileEntry entry, Offset globalPosition)
      onSecondaryRowTap;

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserProvider>();
    final palette = AppColors.of(context);
    final groups = browser.groupedEntries();
    final tile = 110.0 * browser.rowDensity;

    final flat = <Widget>[];
    for (final g in groups) {
      if (g.label != null) {
        flat.add(_GroupHeader(label: g.label!, palette: palette));
      }
      flat.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final crossAxisCount =
                  (constraints.maxWidth / tile).floor().clamp(2, 12);
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 8),
                gridDelegate:
                    SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  childAspectRatio: 1.0,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                ),
                itemCount: g.entries.length,
                itemBuilder: (_, i) {
                  final e = g.entries[i];
                  return _IconTile(
                    entry: e,
                    selected: browser.selectedPaths.contains(e.path),
                    onSecondaryTap: (pos) => onSecondaryRowTap(e, pos),
                    density: browser.rowDensity,
                  );
                },
              );
            },
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: flat,
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.palette});
  final String label;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 2),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          letterSpacing: 0.4,
          fontWeight: FontWeight.w600,
          color: palette.subtleText,
        ),
      ),
    );
  }
}

class _IconTile extends StatefulWidget {
  const _IconTile({
    required this.entry,
    required this.selected,
    required this.onSecondaryTap,
    required this.density,
  });

  final FileEntry entry;
  final bool selected;
  final ValueChanged<Offset> onSecondaryTap;
  final double density;

  @override
  State<_IconTile> createState() => _IconTileState();
}

class _IconTileState extends State<_IconTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final browser = context.read<BrowserProvider>();
    final palette = AppColors.of(context);
    final compact = isCompact(context);
    final iconSize = 52.0 * widget.density;

    final hl = widget.selected
        ? palette.accent.withValues(alpha: 0.18)
        : (_hover ? palette.sidebarHover : null);

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final additive = HardwareKeyboard.instance.isMetaPressed ||
              HardwareKeyboard.instance.isControlPressed;
          if (compact) {
            if (widget.entry.isDirectory) {
              browser.navigateTo(widget.entry.path);
            } else {
              openFilePreview(context, browser, widget.entry);
            }
            return;
          }
          Focus.maybeOf(context)?.requestFocus();
          browser.toggleSelect(widget.entry, additive: additive);
        },
        onDoubleTap: () {
          if (widget.entry.isDirectory) {
            browser.navigateTo(widget.entry.path);
          }
        },
        onLongPressStart: (d) {
          if (!widget.selected) {
            browser.toggleSelect(widget.entry, additive: false);
          }
          widget.onSecondaryTap(d.globalPosition);
        },
        onSecondaryTapDown: (d) {
          if (!widget.selected) {
            browser.toggleSelect(widget.entry, additive: false);
          }
          widget.onSecondaryTap(d.globalPosition);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
          decoration: BoxDecoration(
            color: hl,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: iconSize,
                height: iconSize,
                child: _Thumbnail(
                  entry: widget.entry,
                  size: iconSize,
                  palette: palette,
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  widget.entry.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.2,
                    color: palette.text,
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

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.entry,
    required this.size,
    required this.palette,
  });

  final FileEntry entry;
  final double size;
  final AppPalette palette;

  static const _svgExts = {'.svg', '.svgz'};
  static const _pdfExts = {'.pdf'};
  static const _textExts = {
    '.txt', '.md', '.markdown', '.mdown', '.log',
    '.json', '.yaml', '.yml', '.xml', '.csv', '.tsv',
    '.html', '.htm', '.css', '.scss', '.less',
    '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx',
    '.dart', '.py', '.rb', '.go', '.rs', '.c', '.cpp', '.cc', '.h', '.hpp',
    '.java', '.kt', '.swift', '.sh', '.bash', '.zsh', '.fish',
    '.toml', '.ini', '.conf', '.cfg', '.env',
    '.lua', '.pl', '.php', '.sql', '.r', '.scala', '.groovy',
    '.gradle', '.cmake',
  };

  @override
  Widget build(BuildContext context) {
    if (entry.isDirectory) {
      return Icon(
        CupertinoIcons.folder_fill,
        size: size * 0.9,
        color: palette.folderIcon,
      );
    }
    final ext = entry.extension;
    if (entry.isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          File(entry.path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: (size * 2).toInt(),
          errorBuilder: (_, __, ___) => _docPlaceholder(),
        ),
      );
    }
    if (_svgExts.contains(ext)) {
      return _SvgThumb(entry: entry, size: size, palette: palette);
    }
    if (_pdfExts.contains(ext)) {
      return _PdfThumb(entry: entry, size: size, palette: palette);
    }
    if (_textExts.contains(ext)) {
      return _TextSnippetThumb(entry: entry, size: size, palette: palette);
    }
    return _docPlaceholder();
  }

  Widget _docPlaceholder() {
    final label = entry.extension.isEmpty
        ? ''
        : entry.extension.substring(1).toUpperCase();
    return Container(
      decoration: BoxDecoration(
        color: palette.cardBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _iconFor(entry.extension),
            size: size * 0.5,
            color: palette.subtleText,
          ),
          if (label.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: palette.subtleText,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _iconFor(String ext) {
    switch (ext) {
      case '.txt':
      case '.md':
      case '.log':
        return CupertinoIcons.doc_text;
      case '.json':
      case '.yaml':
      case '.yml':
      case '.xml':
        return CupertinoIcons.doc_chart;
      case '.dart':
      case '.py':
      case '.js':
      case '.ts':
      case '.go':
      case '.rs':
        return CupertinoIcons.chevron_left_slash_chevron_right;
      case '.pdf':
        return CupertinoIcons.doc_richtext;
      case '.mp4':
      case '.mov':
      case '.mkv':
        return CupertinoIcons.film;
      case '.mp3':
      case '.wav':
      case '.flac':
        return CupertinoIcons.music_note;
      default:
        return CupertinoIcons.doc;
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────
// SVG thumbnail — direct render via flutter_svg.
// ──────────────────────────────────────────────────────────────────────────

class _SvgThumb extends StatelessWidget {
  const _SvgThumb({
    required this.entry,
    required this.size,
    required this.palette,
  });
  final FileEntry entry;
  final double size;
  final AppPalette palette;

  Future<Uint8List> _bytes() async {
    final raw = await File(entry.path).readAsBytes();
    if (entry.name.toLowerCase().endsWith('.svgz') &&
        raw.length >= 2 &&
        raw[0] == 0x1F &&
        raw[1] == 0x8B) {
      try {
        return Uint8List.fromList(gzip.decode(raw));
      } catch (_) {
        return raw;
      }
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes(),
      builder: (_, snap) {
        if (!snap.hasData) {
          return _ThumbBox(
            palette: palette,
            child: const CupertinoActivityIndicator(radius: 8),
          );
        }
        return _ThumbBox(
          palette: palette,
          child: SvgPicture.memory(
            snap.data!,
            fit: BoxFit.contain,
            placeholderBuilder: (_) => const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// PDF thumbnail — first page, cached on disk.
// ──────────────────────────────────────────────────────────────────────────

class _PdfThumb extends StatefulWidget {
  const _PdfThumb({
    required this.entry,
    required this.size,
    required this.palette,
  });
  final FileEntry entry;
  final double size;
  final AppPalette palette;

  @override
  State<_PdfThumb> createState() => _PdfThumbState();
}

class _PdfThumbState extends State<_PdfThumb> {
  late final Future<File?> _future;

  @override
  void initState() {
    super.initState();
    _future = ThumbnailService.instance.pdfThumbnail(
      widget.entry,
      dim: (widget.size * 2).round().clamp(120, 480),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _future,
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _ThumbBox(
            palette: widget.palette,
            child: const CupertinoActivityIndicator(radius: 8),
          );
        }
        final f = snap.data;
        if (f == null) {
          return _DocLabelPlaceholder(
            ext: widget.entry.extension,
            icon: CupertinoIcons.doc_richtext,
            size: widget.size,
            palette: widget.palette,
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: widget.palette.divider),
              color: const Color(0xFFFFFFFF),
            ),
            child: Image.file(
              f,
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
              cacheWidth: (widget.size * 2).toInt(),
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => _DocLabelPlaceholder(
                ext: widget.entry.extension,
                icon: CupertinoIcons.doc_richtext,
                size: widget.size,
                palette: widget.palette,
              ),
            ),
          ),
        );
      },
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Text snippet thumbnail — Finder-style miniature of the first lines.
// ──────────────────────────────────────────────────────────────────────────

class _TextSnippetThumb extends StatefulWidget {
  const _TextSnippetThumb({
    required this.entry,
    required this.size,
    required this.palette,
  });
  final FileEntry entry;
  final double size;
  final AppPalette palette;

  @override
  State<_TextSnippetThumb> createState() => _TextSnippetThumbState();
}

class _TextSnippetThumbState extends State<_TextSnippetThumb> {
  late final Future<String?> _future;

  @override
  void initState() {
    super.initState();
    _future = ThumbnailService.instance.textSnippet(widget.entry);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _future,
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _ThumbBox(
            palette: widget.palette,
            child: const CupertinoActivityIndicator(radius: 8),
          );
        }
        final txt = snap.data;
        if (txt == null || txt.trim().isEmpty) {
          return _DocLabelPlaceholder(
            ext: widget.entry.extension,
            icon: CupertinoIcons.doc_text,
            size: widget.size,
            palette: widget.palette,
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Container(
            width: widget.size,
            height: widget.size,
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            decoration: BoxDecoration(
              color: widget.palette.cardBg,
              border: Border.all(color: widget.palette.divider),
            ),
            child: ClipRect(
              child: Text(
                txt,
                maxLines: (widget.size / 7).round().clamp(4, 24),
                overflow: TextOverflow.fade,
                softWrap: true,
                style: TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: (widget.size / 18).clamp(4.5, 7.5),
                  height: 1.15,
                  color: widget.palette.text,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// Shared rounded outlined container for thumbnails that aren't full-bleed.
class _ThumbBox extends StatelessWidget {
  const _ThumbBox({required this.child, required this.palette});
  final Widget child;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: palette.cardBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(4),
      child: Center(child: child),
    );
  }
}

class _DocLabelPlaceholder extends StatelessWidget {
  const _DocLabelPlaceholder({
    required this.ext,
    required this.icon,
    required this.size,
    required this.palette,
  });
  final String ext;
  final IconData icon;
  final double size;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final label = ext.isEmpty ? '' : ext.substring(1).toUpperCase();
    return Container(
      decoration: BoxDecoration(
        color: palette.cardBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: size * 0.5, color: palette.subtleText),
          if (label.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: palette.subtleText,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
