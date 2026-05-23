import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/file_entry.dart';
import '../providers/browser_provider.dart';
import '../theme.dart';

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
          browser.toggleSelect(widget.entry, additive: additive);
        },
        onDoubleTap: () {
          if (widget.entry.isDirectory) {
            browser.navigateTo(widget.entry.path);
          }
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

  @override
  Widget build(BuildContext context) {
    if (entry.isDirectory) {
      return Icon(
        CupertinoIcons.folder_fill,
        size: size * 0.9,
        color: palette.folderIcon,
      );
    }
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
