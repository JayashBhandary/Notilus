import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../models/file_entry.dart';
import '../providers/browser_provider.dart';
import '../theme.dart';
import 'file_drag_drop.dart';
import 'file_thumbnail.dart';
import '../utils/responsive.dart';
import 'file_list_view.dart' show openFilePreview, openFileInDefaultApp;
import 'marquee_selection.dart';

// ──────────────────────────────────────────────────────────────────────────
// Tile metrics
//
// The grid delegate needs a cell height while the tile builds its own content,
// so both have to agree or the tile either overflows or leaves dead space.
// These are the single source of truth for that; all scale with row density.
// ──────────────────────────────────────────────────────────────────────────

/// Nominal cell width, which decides how many columns fit.
const double kGridTileExtent = 96;

/// Thumbnail edge.
const double kGridIconSize = 44;

/// Filename size. Sits just under the 11.5 used elsewhere for captions, since a
/// grid label is centred and wraps to two lines.
const double kGridLabelSize = 11;

const double _kGridLabelLineHeight = 1.2;
const int _kGridLabelLines = 2;
const double _kGridIconLabelGap = 4;
const double _kGridTilePadding = 2;

/// Exact height a tile needs: thumbnail, gap, two lines of label, padding.
///
/// Kept as a function rather than a constant because every part scales with
/// [BrowserProvider.rowDensity] — and the label with the platform text scale,
/// which the caller passes in. Leaving [textScaler] out of the sum is what let
/// a desktop scaled past 1.0 overflow the tile: the label grew, the cell the
/// grid delegate had been told to reserve did not.
double gridTileHeight(
  double density, {
  double iconScale = 1.0,
  TextScaler textScaler = TextScaler.noScaling,
}) =>
    gridIconEdge(density, iconScale) +
    _kGridIconLabelGap +
    (textScaler.scale(kGridLabelSize) *
        _kGridLabelLineHeight *
        _kGridLabelLines) +
    _kGridTilePadding * 2;

/// Thumbnail edge for the current density and icon-size setting.
double gridIconEdge(double density, double iconScale) =>
    kGridIconSize * density * iconScale;

/// Cell width. Wide icons need a wider cell or neighbouring thumbnails would
/// overlap, so the nominal extent is a floor rather than the answer.
double gridTileExtent(double density, double iconScale) => math.max(
      kGridTileExtent * density,
      gridIconEdge(density, iconScale) + 28,
    );

class FileIconGrid extends StatelessWidget {
  const FileIconGrid({super.key, required this.onSecondaryRowTap});

  final void Function(FileEntry entry, Offset globalPosition) onSecondaryRowTap;

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserProvider>();
    final palette = AppColors.of(context);
    final marquee = context.read<MarqueeController>();
    final groups = browser.groupedEntries();
    final density = browser.rowDensity;
    final iconScale = browser.gridIconScale;
    final tile = gridTileExtent(density, iconScale);
    // Cells used to be forced square (childAspectRatio: 1.0) while their
    // content is only ~76px tall, so every tile carried ~34px of dead space
    // below its label — visible as a selection highlight that ran well past
    // the text. Height is now derived from what a tile actually contains.
    final tileHeight = gridTileHeight(
      density,
      iconScale: iconScale,
      textScaler: MediaQuery.textScalerOf(context),
    );

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
              const spacing = 2.0;
              // The delegate only accepts a ratio, so work back from the cell
              // width this row will actually be given.
              final cellWidth =
                  (constraints.maxWidth - spacing * (crossAxisCount - 1)) /
                      crossAxisCount;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 8),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  childAspectRatio: cellWidth / tileHeight,
                  mainAxisSpacing: spacing,
                  crossAxisSpacing: spacing,
                ),
                itemCount: g.entries.length,
                itemBuilder: (_, i) {
                  final e = g.entries[i];
                  return _IconTile(
                    entry: e,
                    selected: browser.selectedPaths.contains(e.path),
                    onSecondaryTap: (pos) => onSecondaryRowTap(e, pos),
                    density: density,
                    iconScale: iconScale,
                  );
                },
              );
            },
          ),
        ),
      );
    }

    return ListView(
      controller: marquee.scroll,
      // Desktop: disable drag-to-scroll so a marquee drag doesn't fight the
      // scroll gesture; the layer scrolls via wheel + auto-scroll instead.
      physics: marquee.enabled ? const NeverScrollableScrollPhysics() : null,
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
    required this.iconScale,
  });

  final FileEntry entry;
  final bool selected;
  final ValueChanged<Offset> onSecondaryTap;
  final double density;
  final double iconScale;

  @override
  State<_IconTile> createState() => _IconTileState();
}

class _IconTileState extends State<_IconTile>
    with MarqueeItemRegistration<_IconTile> {
  bool _hover = false;

  @override
  String get marqueePath => widget.entry.path;

  @override
  void dispose() {
    marqueeUnregister();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final browser = context.read<BrowserProvider>();
    final palette = AppColors.of(context);
    final compact = isCompact(context);
    final iconSize = gridIconEdge(widget.density, widget.iconScale);
    marqueeRegister();

    final hl = widget.selected
        ? palette.accent.withValues(alpha: 0.18)
        : (_hover ? palette.sidebarHover : null);

    return wrapDragDrop(
      entry: widget.entry,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final additive = HardwareKeyboard.instance.isMetaPressed ||
                HardwareKeyboard.instance.isControlPressed;
            final range = HardwareKeyboard.instance.isShiftPressed;
            if (compact) {
              if (widget.entry.isDirectory) {
                browser.navigateTo(widget.entry.path);
              } else {
                openFilePreview(context, browser, widget.entry);
              }
              return;
            }
            Focus.maybeOf(context)?.requestFocus();
            if (range) {
              browser.selectRange(widget.entry);
            } else {
              browser.toggleSelect(widget.entry, additive: additive);
            }
          },
          onDoubleTap: () {
            // Double-click opens: folders navigate, files open in the OS
            // default app.
            if (widget.entry.isDirectory) {
              browser.navigateTo(widget.entry.path);
            } else {
              openFileInDefaultApp(context, browser, widget.entry);
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
            padding: const EdgeInsets.symmetric(
              vertical: _kGridTilePadding,
              horizontal: 2,
            ),
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
                const SizedBox(height: _kGridIconLabelGap),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    widget.entry.name,
                    textAlign: TextAlign.center,
                    maxLines: _kGridLabelLines,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: kGridLabelSize,
                      height: _kGridLabelLineHeight,
                      color: palette.text,
                    ),
                  ),
                ),
              ],
            ),
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
    final isVideo = isPreviewableVideo(entry);
    return FilePreviewBuilder(
      entry: entry,
      // The media grid's dimension rather than one derived from this tile: the
      // cache key folds in the size, so matching it means a video already
      // thumbnailed there appears here without a second ffmpeg run. A tile big
      // enough to out-resolve that render is the one case worth its own,
      // larger, cache entry — a 320px page blown up to a 176px tile on a 2x
      // display is visibly mushy.
      dim: size * 2 <= _kGeneratedThumbDim
          ? _kGeneratedThumbDim
          : _kLargeGeneratedThumbDim,
      builder: (context, preview) {
        final body = _forPreview(preview);
        if (!isVideo) return body;
        return Stack(
          fit: StackFit.expand,
          children: [
            body,
            // Stays whether or not a frame was extracted, so a video reads as
            // playable even when it falls back to a glyph.
            Positioned(
              right: 1,
              bottom: 1,
              child: _PlayBadge(size: size, palette: palette),
            ),
          ],
        );
      },
    );
  }

  Widget _forPreview(FilePreview preview) {
    switch (preview) {
      case FilePreviewImage(:final file, :final isPaper):
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: palette.divider),
              color: isPaper ? const Color(0xFFFFFFFF) : null,
            ),
            child: Image.file(
              file,
              key: ValueKey(file.path),
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: (size * 2).toInt(),
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => _docPlaceholder(),
            ),
          ),
        );
      case FilePreviewSvg(:final bytes):
        return _ThumbBox(
          palette: palette,
          child: SvgPicture.memory(
            bytes,
            fit: BoxFit.contain,
            placeholderBuilder: (_) => const SizedBox.shrink(),
          ),
        );
      case FilePreviewText(:final snippet):
        return _TextSnippetThumb(text: snippet, size: size, palette: palette);
      case FilePreviewNone():
        return _docPlaceholder();
    }
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
      // Scaled down to fit rather than laid out at its natural height: the
      // glyph is a fraction of the tile but the label underneath follows the
      // platform text scale, so on a desktop scaled past 1.0 the pair grew
      // taller than the square it sits in and the Column overflowed.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          // Required inside a FittedBox, which hands its child unbounded
          // height; a `max` Column would then be infinitely tall.
          mainAxisSize: MainAxisSize.min,
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
                maxLines: 1,
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
      ),
    );
  }

  IconData _iconFor(String ext) {
    // Videos and the office/ebook containers are matched against the shared
    // sets rather than listed again here: this glyph is what a clip shows
    // while its frame renders, and one that fell back to a blank page while
    // the tile next to it showed film would look like two different formats.
    if (isPreviewableVideo(entry)) return CupertinoIcons.film;
    if (isAudioFile(entry)) return CupertinoIcons.music_note;
    if (hasEmbeddedDocumentPreview(entry)) return CupertinoIcons.doc_richtext;
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
      case '.eml':
      case '.msg':
        return CupertinoIcons.envelope;
      default:
        return CupertinoIcons.doc;
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Tile rendering for the previews FilePreviewBuilder resolves.
// ──────────────────────────────────────────────────────────────────────────

/// Pixel width asked of every generated preview.
///
/// Deliberately the media grid's dimension rather than one derived from the
/// tile: the cache key folds in the size, so matching it means a video already
/// thumbnailed on the media page appears here without a second ffmpeg run.
const int _kGeneratedThumbDim = 320;

/// Used instead once a tile is large enough that 320px would be upscaled.
const int _kLargeGeneratedThumbDim = 768;

/// Corner badge marking a tile as a video.
class _PlayBadge extends StatelessWidget {
  const _PlayBadge({required this.size, required this.palette});

  /// The thumbnail's edge, not the badge's — the badge scales with the tile so
  /// it stays legible at every row density without swamping a small icon.
  final double size;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final edge = (size * 0.34).clamp(11.0, 18.0);
    return Container(
      width: edge,
      height: edge,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: palette.cardBg.withValues(alpha: 0.85),
        border: Border.all(color: palette.divider),
      ),
      alignment: Alignment.center,
      child: Icon(
        CupertinoIcons.play_fill,
        size: edge * 0.5,
        color: palette.text,
      ),
    );
  }
}

/// Finder-style miniature of a text file's first lines.
class _TextSnippetThumb extends StatelessWidget {
  const _TextSnippetThumb({
    required this.text,
    required this.size,
    required this.palette,
  });

  final String text;
  final double size;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        decoration: BoxDecoration(
          color: palette.cardBg,
          border: Border.all(color: palette.divider),
        ),
        child: ClipRect(
          child: Text(
            text,
            maxLines: (size / 7).round().clamp(4, 24),
            overflow: TextOverflow.fade,
            softWrap: true,
            style: TextStyle(
              fontFamily: 'Menlo',
              fontSize: (size / 18).clamp(4.5, 7.5),
              height: 1.15,
              color: palette.text,
            ),
          ),
        ),
      ),
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
