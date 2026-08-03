import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../models/file_entry.dart';
import 'preview_common.dart';

/// Horizontal strip of the sibling files, so jumping between them is a visual
/// choice rather than a blind click on a chevron.
///
/// Images decode a real thumbnail (downscaled via `cacheWidth`, so a folder of
/// 40MP photos doesn't blow up memory); everything else gets a glyph tile
/// carrying its extension.
class PreviewFilmstrip extends StatefulWidget {
  const PreviewFilmstrip({
    super.key,
    required this.files,
    required this.index,
    required this.onSelect,
  });

  final List<FileEntry> files;
  final int index;
  final ValueChanged<int> onSelect;

  static const double height = 88;
  static const double _tileWidth = 64;
  static const double _tileHeight = 52;

  @override
  State<PreviewFilmstrip> createState() => _PreviewFilmstripState();
}

class _PreviewFilmstripState extends State<PreviewFilmstrip> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant PreviewFilmstrip old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _revealCurrent();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Keeps the selected tile on screen as the shell pages through siblings.
  void _revealCurrent() {
    if (!_scroll.hasClients) return;
    const stride = PreviewFilmstrip._tileWidth + 8;
    final viewport = _scroll.position.viewportDimension;
    final target = (widget.index * stride) - (viewport / 2) + (stride / 2);
    _scroll.animateTo(
      target.clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Container(
      height: PreviewFilmstrip.height,
      decoration: BoxDecoration(
        color: colors.muted,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: widget.files.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => _FilmstripTile(
          file: widget.files[i],
          selected: i == widget.index,
          onTap: () => widget.onSelect(i),
        ),
      ),
    );
  }
}

class _FilmstripTile extends StatelessWidget {
  const _FilmstripTile({
    required this.file,
    required this.selected,
    required this.onTap,
  });

  final FileEntry file;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return ShadTooltip(
      builder: (_) => Text(file.name, style: const TextStyle(fontSize: 11.5)),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: SizedBox(
            width: PreviewFilmstrip._tileWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: PreviewFilmstrip._tileWidth,
                  height: PreviewFilmstrip._tileHeight,
                  decoration: BoxDecoration(
                    color: colors.card,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: selected ? colors.primary : colors.border,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _Thumb(file: file),
                ),
                const SizedBox(height: 3),
                Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color:
                        selected ? colors.primary : colors.mutedForeground,
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

class _Thumb extends StatelessWidget {
  const _Thumb({required this.file});
  final FileEntry file;

  @override
  Widget build(BuildContext context) {
    final kind = previewKindFor(file);

    if (previewHasBitmapThumb(file)) {
      return Image.file(
        File(file.path),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        // The strip can hold dozens of tiles; decode small.
        cacheWidth: 160,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _GlyphTile(kind: kind, file: file),
      );
    }
    return _GlyphTile(kind: kind, file: file);
  }
}

class _GlyphTile extends StatelessWidget {
  const _GlyphTile({required this.kind, required this.file});
  final PreviewKind kind;
  final FileEntry file;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final ext = previewExtLabel(file);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          previewGlyphFor(kind),
          size: 18,
          color: colors.mutedForeground,
        ),
        if (ext.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              ext,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: 7.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: colors.mutedForeground,
              ),
            ),
          ),
      ],
    );
  }
}
