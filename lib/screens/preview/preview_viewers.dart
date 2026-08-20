import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Material, SelectionArea;
import 'package:flutter/widgets.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path/path.dart' as p;
import 'package:pdfx/pdfx.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:video_player/video_player.dart';

import '../../models/file_entry.dart';
import '../../widgets/shad_spinner.dart';
import 'preview_common.dart';

/// Routes one file to the viewer for its kind.
class PreviewViewerHost extends StatelessWidget {
  const PreviewViewerHost({
    super.key,
    required this.file,
    required this.isActive,
    this.onEdit,
  });

  final FileEntry file;

  /// False for the off-screen pages the [PageView] keeps alive; media viewers
  /// use it to pause themselves when swiped away from.
  final bool isActive;

  /// Opens the editor on whatever this preview is *of*. Null when the file
  /// isn't text, or when the preview is showing a downloaded copy whose
  /// original isn't known — editing the copy would write to a cache.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    switch (previewKindFor(file)) {
      case PreviewKind.image:
        return ImageViewer(file: file);
      case PreviewKind.svg:
        return SvgViewer(file: file);
      case PreviewKind.markdown:
        return MarkdownViewer(file: file, onEdit: onEdit);
      case PreviewKind.text:
        return TextViewer(file: file, onEdit: onEdit);
      case PreviewKind.pdf:
        // pdfx ships no Linux plugin, so that platform renders through poppler.
        if (!kIsWeb && Platform.isLinux) return PopplerPdfViewer(file: file);
        return PdfxViewer(file: file);
      case PreviewKind.office:
        return OfficeViewer(file: file);
      case PreviewKind.archive:
        return ArchiveViewer(file: file);
      case PreviewKind.video:
        return VideoViewer(file: file, isActive: isActive);
      case PreviewKind.audio:
        return AudioViewer(file: file, isActive: isActive);
      case PreviewKind.unsupported:
        return UnsupportedViewer(file: file);
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Image
// ──────────────────────────────────────────────────────────────────────────

class ImageViewer extends StatefulWidget {
  const ImageViewer({super.key, required this.file});
  final FileEntry file;

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  final TransformationController _xform = TransformationController();
  int _quarterTurns = 0;
  double _scale = 1;

  @override
  void dispose() {
    _xform.dispose();
    super.dispose();
  }

  void _setScale(double s) {
    final clamped = s.clamp(1.0, 6.0);
    _xform.value = Matrix4.identity()
      ..scaleByDouble(clamped, clamped, clamped, 1);
    setState(() => _scale = clamped);
  }

  void _reset() {
    _xform.value = Matrix4.identity();
    setState(() {
      _scale = 1;
      _quarterTurns = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            transformationController: _xform,
            minScale: 1,
            maxScale: 6,
            onInteractionUpdate: (_) {
              final s = _xform.value.getMaxScaleOnAxis();
              if ((s - _scale).abs() > 0.01) setState(() => _scale = s);
            },
            child: Center(
              child: RotatedBox(
                quarterTurns: _quarterTurns,
                child: Image.file(
                  File(widget.file.path),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const PreviewMessage(
                    icon: LucideIcons.image,
                    title: 'Couldn\'t decode this image',
                    destructive: true,
                  ),
                ),
              ),
            ),
          ),
        ),
        PreviewToolbar(
          children: [
            PreviewToolbarButton(
              icon: LucideIcons.zoomOut,
              tooltip: 'Zoom out',
              onPressed: _scale > 1.01 ? () => _setScale(_scale / 1.25) : null,
            ),
            PreviewToolbarLabel(text: '${(_scale * 100).round()}%'),
            PreviewToolbarButton(
              icon: LucideIcons.zoomIn,
              tooltip: 'Zoom in',
              onPressed: _scale < 5.9 ? () => _setScale(_scale * 1.25) : null,
            ),
            const PreviewToolbarDivider(),
            PreviewToolbarButton(
              icon: LucideIcons.rotateCw,
              tooltip: 'Rotate',
              onPressed: () =>
                  setState(() => _quarterTurns = (_quarterTurns + 1) % 4),
            ),
            PreviewToolbarButton(
              icon: LucideIcons.rotateCcw,
              tooltip: 'Reset',
              onPressed: (_scale > 1.01 || _quarterTurns != 0) ? _reset : null,
            ),
          ],
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// SVG
// ──────────────────────────────────────────────────────────────────────────

class SvgViewer extends StatefulWidget {
  const SvgViewer({super.key, required this.file});
  final FileEntry file;

  @override
  State<SvgViewer> createState() => _SvgViewerState();
}

class _SvgViewerState extends State<SvgViewer> {
  final TransformationController _xform = TransformationController();
  double _scale = 1;
  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    _future = _loadBytes();
  }

  @override
  void dispose() {
    _xform.dispose();
    super.dispose();
  }

  void _setScale(double s) {
    final clamped = s.clamp(1.0, 8.0);
    _xform.value = Matrix4.identity()
      ..scaleByDouble(clamped, clamped, clamped, 1);
    setState(() => _scale = clamped);
  }

  Future<Uint8List> _loadBytes() async {
    final raw = await File(widget.file.path).readAsBytes();
    if (widget.file.name.toLowerCase().endsWith('.svgz')) {
      return Uint8List.fromList(GZipDecoder().decodeBytes(raw));
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: FutureBuilder<Uint8List>(
            future: _future,
            builder: (_, snap) {
              if (snap.hasError) {
                return PreviewMessage(
                  icon: LucideIcons.image,
                  title: 'Couldn\'t open this SVG',
                  body: '${snap.error}',
                  destructive: true,
                );
              }
              if (!snap.hasData) return const PreviewLoading();
              return InteractiveViewer(
                transformationController: _xform,
                minScale: 1,
                maxScale: 8,
                onInteractionUpdate: (_) {
                  final s = _xform.value.getMaxScaleOnAxis();
                  if ((s - _scale).abs() > 0.01) setState(() => _scale = s);
                },
                child: Center(
                  child: SvgPicture.memory(
                    snap.data!,
                    fit: BoxFit.contain,
                    placeholderBuilder: (_) => const PreviewLoading(),
                  ),
                ),
              );
            },
          ),
        ),
        PreviewToolbar(
          children: [
            PreviewToolbarButton(
              icon: LucideIcons.zoomOut,
              tooltip: 'Zoom out',
              onPressed: _scale > 1.01 ? () => _setScale(_scale / 1.25) : null,
            ),
            PreviewToolbarLabel(text: '${(_scale * 100).round()}%'),
            PreviewToolbarButton(
              icon: LucideIcons.zoomIn,
              tooltip: 'Zoom in',
              onPressed: _scale < 7.9 ? () => _setScale(_scale * 1.25) : null,
            ),
            const PreviewToolbarDivider(),
            PreviewToolbarButton(
              icon: LucideIcons.rotateCcw,
              tooltip: 'Reset',
              onPressed: _scale > 1.01
                  ? () {
                      _xform.value = Matrix4.identity();
                      setState(() => _scale = 1);
                    }
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Markdown
// ──────────────────────────────────────────────────────────────────────────

/// Reads a text file, capping how much is pulled into memory.
Future<String> _readCapped(String path, {int cap = 1024 * 1024}) async {
  final f = File(path);
  final size = await f.length();
  if (size <= cap) return f.readAsString();
  final raf = await f.open();
  try {
    final bytes = await raf.read(cap);
    return '${String.fromCharCodes(bytes)}\n\n[truncated after '
        '${cap ~/ 1024} KB of ${(size / 1024).toStringAsFixed(0)} KB]';
  } finally {
    await raf.close();
  }
}

class MarkdownViewer extends StatefulWidget {
  const MarkdownViewer({super.key, required this.file, this.onEdit});
  final FileEntry file;
  final VoidCallback? onEdit;

  @override
  State<MarkdownViewer> createState() => _MarkdownViewerState();
}

class _MarkdownViewerState extends State<MarkdownViewer> {
  Future<String>? _future;
  bool _raw = false;

  @override
  void initState() {
    super.initState();
    _future = _readCapped(widget.file.path);
  }

  MarkdownStyleSheet _sheet(ShadColorScheme colors, ShadThemeData theme) {
    return MarkdownStyleSheet(
      p: TextStyle(fontSize: 13.5, height: 1.6, color: colors.foreground),
      h1: TextStyle(
        fontSize: 23,
        fontWeight: FontWeight.w700,
        height: 1.3,
        color: colors.foreground,
      ),
      h2: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        height: 1.35,
        color: colors.foreground,
      ),
      h3: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: colors.foreground,
      ),
      code: TextStyle(
        fontFamily: 'Menlo',
        fontSize: 12,
        backgroundColor: colors.muted,
        color: colors.foreground,
      ),
      codeblockDecoration: BoxDecoration(
        color: colors.muted,
        border: Border.all(color: colors.border),
        borderRadius: theme.radius,
      ),
      blockquoteDecoration: BoxDecoration(
        color: colors.muted.withValues(alpha: 0.5),
        border: Border(left: BorderSide(color: colors.primary, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      blockquote: TextStyle(fontSize: 13, color: colors.mutedForeground),
      a: TextStyle(color: colors.primary),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border)),
      ),
      tableBorder: TableBorder.all(color: colors.border),
      tableHeadAlign: TextAlign.left,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = theme.colorScheme;
    final bottomPad = 80 + PreviewInsets.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: FutureBuilder<String>(
            future: _future,
            builder: (_, snap) {
              if (snap.hasError) {
                return PreviewMessage(
                  icon: LucideIcons.fileText,
                  title: 'Couldn\'t read this file',
                  body: '${snap.error}',
                  destructive: true,
                );
              }
              if (!snap.hasData) return const PreviewLoading();
              if (_raw) {
                return SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(20, 18, 20, bottomPad),
                  child: SelectionArea(
                    child: Text(
                      snap.data!,
                      style: TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 12,
                        height: 1.5,
                        color: colors.foreground,
                      ),
                    ),
                  ),
                );
              }
              // Markdown renders links and tables through Material widgets.
              return Material(
                color: const Color(0x00000000),
                child: Center(
                  child: ConstrainedBox(
                    // Long-form text is unreadable at full desktop width.
                    constraints: const BoxConstraints(maxWidth: 780),
                    child: Markdown(
                      data: snap.data!,
                      selectable: true,
                      padding: EdgeInsets.fromLTRB(24, 20, 24, bottomPad),
                      styleSheet: _sheet(colors, theme),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        PreviewToolbar(
          children: [
            PreviewToolbarButton(
              icon: _raw ? LucideIcons.eye : LucideIcons.fileCode,
              tooltip: _raw ? 'Show rendered' : 'Show source',
              onPressed: () => setState(() => _raw = !_raw),
            ),
            PreviewToolbarLabel(text: _raw ? 'Source' : 'Rendered'),
            if (widget.onEdit != null)
              PreviewToolbarButton(
                icon: LucideIcons.pencil,
                tooltip: 'Edit',
                onPressed: widget.onEdit!,
              ),
          ],
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Text / source
// ──────────────────────────────────────────────────────────────────────────

class TextViewer extends StatefulWidget {
  const TextViewer({super.key, required this.file, this.onEdit});
  final FileEntry file;
  final VoidCallback? onEdit;

  @override
  State<TextViewer> createState() => _TextViewerState();
}

class _TextViewerState extends State<TextViewer> {
  Future<String>? _future;
  bool _wrap = false;

  @override
  void initState() {
    super.initState();
    _future = _readCapped(widget.file.path);
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = 80 + PreviewInsets.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: FutureBuilder<String>(
            future: _future,
            builder: (_, snap) {
              if (snap.hasError) {
                return PreviewMessage(
                  icon: LucideIcons.fileCode,
                  title: 'Couldn\'t read this file',
                  body: '${snap.error}',
                  destructive: true,
                );
              }
              if (!snap.hasData) return const PreviewLoading();
              final lines = snap.data!.split('\n');
              return SingleChildScrollView(
                padding: EdgeInsets.only(top: 12, bottom: bottomPad),
                child: _wrap
                    ? _WrappedSource(text: snap.data!)
                    // Unwrapped source scrolls sideways instead of reflowing,
                    // which is what makes the line numbers meaningful.
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: _NumberedSource(lines: lines),
                      ),
              );
            },
          ),
        ),
        PreviewToolbar(
          children: [
            PreviewToolbarButton(
              icon: LucideIcons.scanText,
              tooltip: _wrap ? 'Disable wrapping' : 'Wrap long lines',
              selected: _wrap,
              onPressed: () => setState(() => _wrap = !_wrap),
            ),
            PreviewToolbarLabel(text: _wrap ? 'Wrapped' : 'No wrap'),
            if (widget.onEdit != null)
              PreviewToolbarButton(
                icon: LucideIcons.pencil,
                tooltip: 'Edit',
                onPressed: widget.onEdit!,
              ),
          ],
        ),
      ],
    );
  }
}

const TextStyle _sourceStyle =
    TextStyle(fontFamily: 'Menlo', fontSize: 12, height: 1.55);

/// Source text with a line-number gutter — new in this redesign; the old text
/// viewer was an undifferentiated blob of monospace.
///
/// Sized to its content, never with a flex child: this sits inside a horizontal
/// [SingleChildScrollView], so its incoming width is unbounded and an `Expanded`
/// in here would throw.
class _NumberedSource extends StatelessWidget {
  const _NumberedSource({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final gutterWidth = 16.0 + (lines.length.toString().length * 8.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: gutterWidth,
          child: Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < lines.length; i++)
                  Text(
                    '${i + 1}',
                    style: _sourceStyle.copyWith(
                      color: colors.mutedForeground.withValues(alpha: 0.65),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Container(width: 1, color: colors.border),
        Padding(
          padding: const EdgeInsets.only(left: 12, right: 24),
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in lines)
                  Text(
                    // An empty line still needs to occupy a row so the gutter
                    // stays in step.
                    line.isEmpty ? ' ' : line,
                    softWrap: false,
                    maxLines: 1,
                    style: _sourceStyle.copyWith(color: colors.foreground),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Reflowing source. No gutter: a wrapped line spans several visual rows, so
/// line numbers would drift out of step with the text.
class _WrappedSource extends StatelessWidget {
  const _WrappedSource({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: SelectionArea(
        child: Text(
          text,
          style: _sourceStyle.copyWith(color: colors.foreground),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// PDF via pdfx (macOS/iOS/Android/Windows)
// ──────────────────────────────────────────────────────────────────────────

class PdfxViewer extends StatefulWidget {
  const PdfxViewer({super.key, required this.file});
  final FileEntry file;

  @override
  State<PdfxViewer> createState() => _PdfxViewerState();
}

class _PdfxViewerState extends State<PdfxViewer> {
  late final PdfControllerPinch _controller;
  PdfDocument? _thumbDoc;
  int _page = 1;
  int _pageCount = 0;
  bool _showRail = false;

  /// Width / height of the first page. PdfViewPinch always lays pages out to
  /// the width it is given, so the viewer is handed a width derived from the
  /// height instead — that is what fits a page to the viewport.
  double _pageAspect = 612 / 792;

  @override
  void initState() {
    super.initState();
    _controller = PdfControllerPinch(
      document: PdfDocument.openFile(widget.file.path),
    );
    PdfDocument.openFile(widget.file.path).then((d) {
      if (!mounted) {
        d.close();
        return;
      }
      setState(() {
        _thumbDoc = d;
        _pageCount = d.pagesCount;
      });
      _readAspect(d);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _controller.dispose();
    _thumbDoc?.close();
    super.dispose();
  }

  Future<void> _readAspect(PdfDocument doc) async {
    try {
      final pg = await doc.getPage(1);
      final aspect = pg.width / pg.height;
      await pg.close();
      if (!mounted || aspect <= 0 || !aspect.isFinite) return;
      setState(() => _pageAspect = aspect);
    } catch (_) {}
  }

  Future<void> _goto(int page) async {
    if (_pageCount == 0) return;
    await _controller.animateToPage(pageNumber: page.clamp(1, _pageCount));
  }

  Future<void> _jumpDialog() async {
    final picked = await promptForPage(
      context,
      current: _page,
      pageCount: _pageCount,
    );
    if (picked != null) await _goto(picked);
  }

  Future<Uint8List?> _thumb(int page) async {
    final doc = _thumbDoc;
    if (doc == null) return null;
    try {
      final pg = await doc.getPage(page);
      try {
        final img = await pg.render(
          width: 120,
          height: (120 * pg.height / pg.width).clamp(40, 220),
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        return img?.bytes;
      } finally {
        await pg.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Boxes [child] so a page is as tall as the space available instead of as
  /// wide as it, which is the one thing PdfViewPinch won't do on its own. A
  /// landscape page still shrinks to fit the width.
  Widget _fitToHeight({required Widget child}) {
    // Matches PdfViewPinch's own page padding, so the arithmetic below lands
    // on the real page box rather than the box plus its margins.
    const pinchPadding = 10.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight - pinchPadding * 2;
        if (height <= 0 || !constraints.hasBoundedWidth) return child;
        final width = math.min(
          constraints.maxWidth,
          height * _pageAspect + pinchPadding * 2,
        );
        return Center(child: SizedBox(width: width, child: child));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(
              left: _showRail ? PreviewPageRail.width : 0,
              bottom: 80 + PreviewInsets.of(context),
            ),
            child: _fitToHeight(
              child: PdfViewPinch(
                controller: _controller,
                onDocumentLoaded: (d) {
                  if (mounted) setState(() => _pageCount = d.pagesCount);
                },
                onPageChanged: (p) {
                  if (mounted) setState(() => _page = p);
                },
                onDocumentError: (_) {},
                builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
                  options: const DefaultBuilderOptions(),
                  documentLoaderBuilder: (_) => const PreviewLoading(),
                  pageLoaderBuilder: (_) => const PreviewLoading(),
                  errorBuilder: (_, e) => PreviewMessage(
                    icon: LucideIcons.fileText,
                    title: 'Couldn\'t open this PDF',
                    body: '$e',
                    destructive: true,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_showRail && _thumbDoc != null)
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            child: PreviewPageRail(
              pageCount: _pageCount,
              currentPage: _page,
              onSelect: _goto,
              thumbnailBuilder: (_, page) => FutureBuilder<Uint8List?>(
                future: _thumb(page),
                builder: (_, snap) => snap.data == null
                    ? const SizedBox(
                        width: 84,
                        height: 108,
                        child: Center(child: ShadSpinner(size: 16)),
                      )
                    : Image.memory(
                        snap.data!,
                        width: 84,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
              ),
            ),
          ),
        _PdfToolbar(
          page: _page,
          pageCount: _pageCount,
          railOpen: _showRail,
          onToggleRail: _thumbDoc == null
              ? null
              : () => setState(() => _showRail = !_showRail),
          onGoto: _goto,
          onJumpDialog: _pageCount > 0 ? _jumpDialog : null,
        ),
      ],
    );
  }
}

/// Page controls shared by both PDF viewers.
class _PdfToolbar extends StatelessWidget {
  const _PdfToolbar({
    required this.page,
    required this.pageCount,
    required this.railOpen,
    required this.onToggleRail,
    required this.onGoto,
    required this.onJumpDialog,
  });

  final int page;
  final int pageCount;
  final bool railOpen;
  final VoidCallback? onToggleRail;
  final ValueChanged<int> onGoto;
  final VoidCallback? onJumpDialog;

  @override
  Widget build(BuildContext context) {
    return PreviewToolbar(
      children: [
        PreviewToolbarButton(
          icon: LucideIcons.panelLeft,
          tooltip: railOpen ? 'Hide pages' : 'Show pages',
          selected: railOpen,
          onPressed: onToggleRail,
        ),
        const PreviewToolbarDivider(),
        PreviewToolbarButton(
          icon: LucideIcons.chevronLeft,
          tooltip: 'Previous page',
          onPressed: page > 1 ? () => onGoto(page - 1) : null,
        ),
        PreviewToolbarLabel(
          text: pageCount == 0 ? '— / —' : '$page / $pageCount',
          onTap: onJumpDialog,
        ),
        PreviewToolbarButton(
          icon: LucideIcons.chevronRight,
          tooltip: 'Next page',
          onPressed:
              pageCount > 0 && page < pageCount ? () => onGoto(page + 1) : null,
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// PDF on Linux — poppler's pdftoppm to PNGs, shown as a scrolling list.
// ──────────────────────────────────────────────────────────────────────────

class PopplerPdfViewer extends StatefulWidget {
  const PopplerPdfViewer({super.key, required this.file});
  final FileEntry file;

  @override
  State<PopplerPdfViewer> createState() => _PopplerPdfViewerState();
}

class _PopplerPdfViewerState extends State<PopplerPdfViewer> {
  /// Hard ceiling on how many pages the viewer will list. Pages are rendered
  /// on demand now, so this only bounds the scrollbar, not the work done.
  static const _maxPages = 1000;
  static const _dpi = 110;

  /// Kicked off as soon as the page count is known, before anything is
  /// scrolled — enough that opening a document lands on a drawn first page.
  static const _eagerPages = 3;

  /// Pages rendered ahead of the one being looked at.
  static const _prefetch = 2;

  /// Concurrent `pdftoppm` processes. Two keeps a scroll filling quickly
  /// without handing the whole machine to poppler.
  static const _maxConcurrent = 2;

  /// A single page that takes longer than this is abandoned, so one pathological
  /// page can't wedge the render queue.
  static const _pageTimeout = Duration(seconds: 30);

  Directory? _tmpDir;
  int _pageCount = 0;

  /// Width / height of the document's first page, used to size the placeholder
  /// for pages that haven't been rendered yet. Mixed-orientation documents
  /// letterbox inside this box rather than making the list jump as pages land.
  double _pageAspect = 612 / 792;

  final Map<int, File> _rendered = {};
  final Set<int> _requested = {};
  final Set<int> _failed = {};
  final Queue<int> _queue = Queue<int>();
  int _running = 0;

  bool _loading = true;
  bool _popplerMissing = false;
  String? _errorMsg;
  bool _disposed = false;

  final ScrollController _scroll = ScrollController();
  final List<GlobalKey> _pageKeys = [];
  int _currentPage = 1;
  bool _showRail = false;

  /// Height of one page slot, as measured during the last layout. Pages are
  /// fitted to the viewport's height rather than its width, so this — not the
  /// available width — is what off-screen scroll offsets are computed from.
  double? _slotHeight;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _start();
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    final t = _tmpDir;
    if (t != null) {
      t.delete(recursive: true).catchError((_) => t);
    }
    super.dispose();
  }

  void _onScroll() {
    if (_pageKeys.isEmpty) return;
    for (var i = 0; i < _pageKeys.length; i++) {
      final ctx = _pageKeys[i].currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null) continue;
      if (box.localToGlobal(Offset.zero).dy > 80) {
        final page = (i - 1).clamp(0, _pageKeys.length - 1) + 1;
        if (page != _currentPage) setState(() => _currentPage = page);
        return;
      }
    }
    if (_currentPage != _pageKeys.length) {
      setState(() => _currentPage = _pageKeys.length);
    }
  }

  /// Learns the document's shape, then paints immediately and fills pages in
  /// behind the scroll.
  ///
  /// The viewer used to rasterise every page up front — a hundred-page
  /// document meant a hundred pages of poppler before a single pixel appeared.
  /// `pdfinfo` costs milliseconds and gives the page count and page size, which
  /// is everything needed to lay out placeholders and render the rest lazily.
  Future<void> _start() async {
    Directory tmp;
    try {
      tmp = await Directory.systemTemp.createTemp('notilus_pdf_');
    } catch (e) {
      _fail('Couldn\'t create temp dir: $e');
      return;
    }
    _tmpDir = tmp;

    final info = await _probeDocument();
    if (_disposed) return;

    if (info == null) {
      // pdfinfo is in the same package as pdftoppm, so this is a strange
      // machine rather than a normal one. Fall back to the old render-it-all
      // path so the document still opens.
      await _renderEverything();
      return;
    }

    setState(() {
      _pageCount = info.pages.clamp(1, _maxPages);
      _pageAspect = info.aspect;
      _pageKeys
        ..clear()
        ..addAll(List.generate(_pageCount, (_) => GlobalKey()));
      _loading = false;
    });

    for (var page = 1; page <= _eagerPages && page <= _pageCount; page++) {
      _request(page);
    }
  }

  void _fail(String message) {
    if (_disposed || !mounted) return;
    setState(() {
      _loading = false;
      _errorMsg = message;
    });
  }

  Future<PdfInfo?> _probeDocument() async {
    try {
      final result = await Process.run('pdfinfo', [widget.file.path]);
      if (result.exitCode != 0) return null;
      return PdfInfo.parse('${result.stdout}');
    } on ProcessException {
      if (!_disposed && mounted) {
        setState(() {
          _loading = false;
          _popplerMissing = true;
        });
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Queues [page] for rendering unless it is already done, queued or known bad.
  void _request(int page) {
    if (page < 1 || page > _pageCount) return;
    if (_requested.contains(page) || _failed.contains(page)) return;
    _requested.add(page);
    _queue.add(page);
    _pump();
  }

  void _pump() {
    while (!_disposed && _running < _maxConcurrent && _queue.isNotEmpty) {
      final page = _queue.removeFirst();
      _running++;
      _renderPage(page).whenComplete(() {
        _running--;
        _pump();
      });
    }
  }

  Future<void> _renderPage(int page) async {
    final tmp = _tmpDir;
    if (tmp == null || _disposed) return;
    // -singlefile fixes the output name: without it poppler pads the page
    // number to the document's digit count, which differs per document.
    final prefix = p.join(tmp.path, 'page-$page');
    final out = File('$prefix.png');
    try {
      if (!await out.exists()) {
        final code = await _runPoppler([
          '-png',
          '-r',
          '$_dpi',
          '-f',
          '$page',
          '-l',
          '$page',
          '-singlefile',
          widget.file.path,
          prefix,
        ]);
        if (code != 0 || !await out.exists()) {
          _requested.remove(page);
          _failed.add(page);
          return;
        }
      }
      if (_disposed || !mounted) return;
      setState(() => _rendered[page] = out);
    } catch (_) {
      _requested.remove(page);
      _failed.add(page);
    }
  }

  /// Runs pdftoppm, killing it if it outlives [_pageTimeout].
  Future<int> _runPoppler(List<String> args) async {
    Process? proc;
    try {
      proc = await Process.start('pdftoppm', args);
      // Drained so a chatty page can't block on a full stderr pipe.
      proc.stdout.drain<void>().catchError((_) {});
      proc.stderr.drain<void>().catchError((_) {});
      return await proc.exitCode.timeout(
        _pageTimeout,
        onTimeout: () {
          proc?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {
      return -1;
    }
  }

  /// Last-resort path for a machine with pdftoppm but no pdfinfo: one batch,
  /// capped, exactly as the viewer used to behave.
  Future<void> _renderEverything() async {
    final tmp = _tmpDir;
    if (tmp == null) return;
    try {
      final code = await _runPoppler([
        '-png',
        '-r',
        '$_dpi',
        '-f',
        '1',
        '-l',
        '100',
        widget.file.path,
        p.join(tmp.path, 'p'),
      ]);
      if (code != 0) {
        _fail('pdftoppm exited $code');
        return;
      }
    } on ProcessException {
      if (!_disposed && mounted) {
        setState(() {
          _loading = false;
          _popplerMissing = true;
        });
      }
      return;
    } catch (e) {
      _fail('$e');
      return;
    }

    final pages = await tmp
        .list()
        .where((e) => e is File && e.path.endsWith('.png'))
        .cast<File>()
        .toList();
    pages.sort((a, b) => a.path.compareTo(b.path));
    if (_disposed || !mounted) return;
    setState(() {
      _pageCount = pages.length;
      _rendered
        ..clear()
        ..addEntries([
          for (var i = 0; i < pages.length; i++) MapEntry(i + 1, pages[i]),
        ]);
      _requested.addAll(_rendered.keys);
      _pageKeys
        ..clear()
        ..addAll(List.generate(pages.length, (_) => GlobalKey()));
      _loading = false;
    });
  }

  Future<void> _goto(int page) async {
    if (page < 1 || page > _pageKeys.length) return;
    final ctx = _pageKeys[page - 1].currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0,
      );
      return;
    }

    // Off-screen pages have no context to scroll to — the list only builds
    // what's visible. Every page occupies the same box, so the offset is
    // arithmetic. (Jumping to a distant page used to silently do nothing.)
    _request(page);
    final pageHeight = _slotHeight;
    if (pageHeight == null || pageHeight <= 0 || !_scroll.hasClients) return;
    final target = (page - 1) * (pageHeight + 12);
    await _scroll.animateTo(
      target.clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _jumpDialog() async {
    final picked = await promptForPage(
      context,
      current: _currentPage,
      pageCount: _pageCount,
    );
    if (picked != null) await _goto(picked);
  }

  /// Requests [page] and the next few, from outside the build phase.
  void _ensureRendered(int page) {
    if (_rendered.containsKey(page) &&
        _requested.containsAll([
          for (var i = 1; i <= _prefetch; i++) page + i,
        ])) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      _request(page);
      for (var i = 1; i <= _prefetch; i++) {
        _request(page + i);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    if (_loading) {
      return PreviewLoading(caption: 'Opening ${widget.file.name}…');
    }
    if (_popplerMissing) {
      return PreviewMessage(
        icon: LucideIcons.fileText,
        title: 'Install poppler-utils for inline PDF preview',
        body: 'Notilus renders PDFs on Linux with pdftoppm.\n'
            'Run: sudo apt install poppler-utils',
        actionLabel: 'Open in external viewer',
        onAction: () => openPathExternally(widget.file.path),
      );
    }
    if (_errorMsg != null || _pageCount == 0) {
      return PreviewMessage(
        icon: LucideIcons.fileText,
        title: 'Couldn\'t render this PDF',
        body: _errorMsg ?? 'No pages were produced.',
        destructive: true,
        actionLabel: 'Open in external viewer',
        onAction: () => openPathExternally(widget.file.path),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const topPad = 16.0;
              final bottomPad = 80 + PreviewInsets.of(context);
              final leftPad = (_showRail ? PreviewPageRail.width : 0) + 16.0;

              // Pages are fitted to the height they have to stand in, so one
              // page fills the viewport at a time. Fitting them to the width
              // instead made every page taller than the window on a wide
              // panel, which is unreadable for anything but a narrow document.
              final availHeight = math.max(
                120.0,
                constraints.maxHeight - topPad - bottomPad,
              );
              final availWidth = math.max(
                80.0,
                constraints.maxWidth - leftPad - 16.0,
              );
              // Landscape pages still can't spill sideways.
              final pageHeight = math.min(
                availHeight,
                availWidth / _pageAspect,
              );
              _slotHeight = pageHeight;

              return ListView.separated(
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(leftPad, topPad, 16, bottomPad),
                itemCount: _pageCount,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (_, i) {
                  final page = i + 1;
                  _ensureRendered(page);
                  return KeyedSubtree(
                    key: _pageKeys[i],
                    child: Center(
                      child: SizedBox(
                        height: pageHeight,
                        width: pageHeight * _pageAspect,
                        child: _PdfPageSlot(
                          file: _rendered[page],
                          failed: _failed.contains(page),
                          border: colors.border,
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        if (_showRail)
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            child: PreviewPageRail(
              pageCount: _pageCount,
              currentPage: _currentPage,
              onSelect: _goto,
              thumbnailBuilder: (_, page) {
                final file = _rendered[page];
                if (file == null) {
                  // The rail is opt-in, so pulling its pages forward is a cost
                  // the user asked for by opening it.
                  _ensureRendered(page);
                  return SizedBox(
                    width: 84,
                    height: 84 / _pageAspect,
                    child: const Center(child: ShadSpinner(size: 14)),
                  );
                }
                return Image.file(
                  file,
                  width: 84,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                );
              },
            ),
          ),
        _PdfToolbar(
          page: _currentPage,
          pageCount: _pageCount,
          railOpen: _showRail,
          onToggleRail: () => setState(() => _showRail = !_showRail),
          onGoto: _goto,
          onJumpDialog: _jumpDialog,
        ),
      ],
    );
  }
}

/// One page's box in the scrolling list: the rendered PNG once poppler has
/// produced it, and a correctly-sized blank page before that.
///
/// The box keeps the document's page ratio whether or not the image has
/// arrived, so pages landing behind the scroll never shift what is under the
/// reader's eye.
class _PdfPageSlot extends StatelessWidget {
  const _PdfPageSlot({
    required this.file,
    required this.failed,
    required this.border,
  });

  final File? file;
  final bool failed;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        border: Border.all(color: border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: file != null
          ? Image.file(file!, fit: BoxFit.contain, gaplessPlayback: true)
          : Center(
              child: failed
                  ? const Icon(
                      LucideIcons.fileWarning,
                      size: 22,
                      color: Color(0xFF9A9A9A),
                    )
                  : const ShadSpinner(size: 16),
            ),
    );
  }
}

/// The two facts `pdfinfo` supplies that the viewer needs before it can lay
/// anything out.
class PdfInfo {
  const PdfInfo({required this.pages, required this.aspect});

  final int pages;

  /// Width / height of the first page.
  final double aspect;

  /// Parses `pdfinfo` output. Lines look like:
  ///   Pages:           12
  ///   Page size:       612 x 792 pts (letter)
  static PdfInfo? parse(String output) {
    int? pages;
    double? aspect;

    for (final line in output.split('\n')) {
      if (pages == null && line.startsWith('Pages:')) {
        pages = int.tryParse(line.substring(6).trim());
      } else if (aspect == null && line.startsWith('Page size:')) {
        final match =
            RegExp(r'([\d.]+)\s*x\s*([\d.]+)').firstMatch(line.substring(10));
        if (match != null) {
          final w = double.tryParse(match.group(1)!);
          final h = double.tryParse(match.group(2)!);
          if (w != null && h != null && w > 0 && h > 0) aspect = w / h;
        }
      }
    }

    if (pages == null || pages < 1) return null;
    // A rotated or malformed page size isn't worth failing over — letter is a
    // close enough placeholder until the real page renders over it.
    return PdfInfo(pages: pages, aspect: aspect ?? 612 / 792);
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Office — convert to PDF with LibreOffice, then reuse the PDF pipeline.
// ──────────────────────────────────────────────────────────────────────────

class OfficeViewer extends StatefulWidget {
  const OfficeViewer({super.key, required this.file});
  final FileEntry file;

  @override
  State<OfficeViewer> createState() => _OfficeViewerState();
}

class _OfficeViewerState extends State<OfficeViewer> {
  Directory? _tmpDir;
  FileEntry? _converted;
  bool _loading = true;
  bool _missing = false;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    _convert();
  }

  @override
  void dispose() {
    final t = _tmpDir;
    if (t != null) {
      t.delete(recursive: true).catchError((_) => t);
    }
    super.dispose();
  }

  Future<String?> _findSoffice() async {
    for (final name in const ['soffice', 'libreoffice']) {
      try {
        final r = await Process.run(name, ['--version']);
        if (r.exitCode == 0) return name;
      } on ProcessException {
        continue;
      } catch (_) {
        continue;
      }
    }
    if (!kIsWeb) {
      final candidates = <String>[
        if (Platform.isMacOS)
          '/Applications/LibreOffice.app/Contents/MacOS/soffice',
        if (Platform.isWindows)
          r'C:\Program Files\LibreOffice\program\soffice.exe',
        if (Platform.isWindows)
          r'C:\Program Files (x86)\LibreOffice\program\soffice.exe',
      ];
      for (final path in candidates) {
        if (await File(path).exists()) return path;
      }
    }
    return null;
  }

  Future<void> _convert() async {
    final soffice = await _findSoffice();
    if (soffice == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _missing = true;
        });
      }
      return;
    }

    Directory tmp;
    try {
      tmp = await Directory.systemTemp.createTemp('notilus_office_');
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMsg = 'Couldn\'t create temp dir: $e';
        });
      }
      return;
    }
    _tmpDir = tmp;

    try {
      final r = await Process.run(soffice, [
        '--headless',
        '--norestore',
        '--nologo',
        '--nofirststartwizard',
        '--convert-to',
        'pdf',
        '--outdir',
        tmp.path,
        widget.file.path,
      ]);
      if (r.exitCode != 0) {
        if (mounted) {
          setState(() {
            _loading = false;
            _errorMsg = (r.stderr is String && (r.stderr as String).isNotEmpty)
                ? r.stderr as String
                : 'LibreOffice exited ${r.exitCode}';
          });
        }
        return;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMsg = '$e';
        });
      }
      return;
    }

    final base = p.basenameWithoutExtension(widget.file.path);
    var pdf = File(p.join(tmp.path, '$base.pdf'));
    if (!await pdf.exists()) {
      // LibreOffice sometimes picks a different base name.
      final any = await tmp
          .list()
          .where((e) => e is File && e.path.toLowerCase().endsWith('.pdf'))
          .cast<File>()
          .toList();
      if (any.isEmpty) {
        if (mounted) {
          setState(() {
            _loading = false;
            _errorMsg = 'Conversion produced no PDF.';
          });
        }
        return;
      }
      pdf = any.first;
    }
    final entry = await FileEntry.from(pdf);
    if (!mounted) return;
    setState(() {
      _converted = entry;
      _loading = false;
      if (entry == null) _errorMsg = 'Couldn\'t read the converted PDF.';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return PreviewLoading(caption: 'Converting ${widget.file.name}…');
    }
    if (_missing) {
      return PreviewMessage(
        icon: LucideIcons.fileText,
        title: 'Install LibreOffice for inline Office previews',
        body: 'Notilus uses LibreOffice (soffice) to render Word, Excel and '
            'PowerPoint files. Once installed this preview works '
            'automatically.',
        actionLabel: 'Open in external app',
        onAction: () => openPathExternally(widget.file.path),
      );
    }
    final pdf = _converted;
    if (pdf == null) {
      return PreviewMessage(
        icon: LucideIcons.fileText,
        title: 'Couldn\'t render this document',
        body: _errorMsg ?? 'Unknown error.',
        destructive: true,
        actionLabel: 'Open in external app',
        onAction: () => openPathExternally(widget.file.path),
      );
    }
    if (!kIsWeb && Platform.isLinux) return PopplerPdfViewer(file: pdf);
    return PdfxViewer(file: pdf);
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Archive listing
// ──────────────────────────────────────────────────────────────────────────

class ArchiveEntryInfo {
  ArchiveEntryInfo(this.name, this.size, this.isDir);
  final String name;
  final int size;
  final bool isDir;
}

class ArchiveViewer extends StatefulWidget {
  const ArchiveViewer({super.key, required this.file});
  final FileEntry file;

  @override
  State<ArchiveViewer> createState() => _ArchiveViewerState();
}

class _ArchiveViewerState extends State<ArchiveViewer> {
  Future<List<ArchiveEntryInfo>>? _future;

  @override
  void initState() {
    super.initState();
    _future = compute(decodeArchiveListing, widget.file.path);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return FutureBuilder<List<ArchiveEntryInfo>>(
      future: _future,
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return PreviewLoading(caption: 'Reading ${widget.file.name}…');
        }
        if (snap.hasError) {
          return PreviewMessage(
            icon: LucideIcons.fileArchive,
            title: 'Couldn\'t read this archive',
            body: '${snap.error}',
            destructive: true,
          );
        }
        final entries = snap.data!;
        if (entries.isEmpty) {
          return const PreviewMessage(
            icon: LucideIcons.fileArchive,
            title: 'Archive is empty',
          );
        }
        final total = entries.fold<int>(0, (a, b) => a + b.size);
        final dirs = entries.where((e) => e.isDir).length;
        return Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              decoration: BoxDecoration(
                color: colors.muted,
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.fileArchive,
                    size: 16,
                    color: colors.mutedForeground,
                  ),
                  const SizedBox(width: 10),
                  ShadBadge.secondary(
                    child: Text('${entries.length - dirs} files'),
                  ),
                  if (dirs > 0) ...[
                    const SizedBox(width: 6),
                    ShadBadge.secondary(child: Text('$dirs folders')),
                  ],
                  const SizedBox(width: 6),
                  ShadBadge.outline(
                    child: Text('${formatPreviewBytes(total)} uncompressed'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.only(bottom: PreviewInsets.of(context)),
                itemCount: entries.length,
                separatorBuilder: (_, __) => const ShadSeparator.horizontal(
                  margin: EdgeInsets.zero,
                  thickness: 1,
                ),
                itemBuilder: (_, i) {
                  final e = entries[i];
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    child: Row(
                      children: [
                        Icon(
                          e.isDir ? LucideIcons.folder : LucideIcons.file,
                          size: 15,
                          color: colors.mutedForeground,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            e.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Menlo',
                              fontSize: 11.5,
                              color: colors.foreground,
                            ),
                          ),
                        ),
                        if (!e.isDir)
                          Text(
                            formatPreviewBytes(e.size),
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.mutedForeground,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Reads the archive at [path] and lists its entries.
///
/// Runs on a background isolate via [compute]. The pure-Dart inflate/bunzip2
/// decoders are slow enough — and the whole file has to be materialised in
/// memory to decode it — that doing this inline froze the UI for seconds on a
/// large archive. Sync I/O is fine here: the isolate has nothing else to do.
List<ArchiveEntryInfo> decodeArchiveListing(String path) {
  final name = p.basename(path);
  final lower = name.toLowerCase();
  final bytes = File(path).readAsBytesSync();

  Archive? archive;
  try {
    if (lower.endsWith('.zip') || lower.endsWith('.jar')) {
      archive = ZipDecoder().decodeBytes(bytes);
    } else if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    } else if (lower.endsWith('.tar.bz2') || lower.endsWith('.tbz2')) {
      archive = TarDecoder().decodeBytes(BZip2Decoder().decodeBytes(bytes));
    } else if (lower.endsWith('.tar')) {
      archive = TarDecoder().decodeBytes(bytes);
    } else if (lower.endsWith('.gz')) {
      final gunz = GZipDecoder().decodeBytes(bytes);
      return [
        ArchiveEntryInfo(p.basenameWithoutExtension(name), gunz.length, false),
      ];
    } else if (lower.endsWith('.bz2')) {
      final bunz = BZip2Decoder().decodeBytes(bytes);
      return [
        ArchiveEntryInfo(p.basenameWithoutExtension(name), bunz.length, false),
      ];
    }
  } catch (e) {
    throw 'Decode failed: $e';
  }
  if (archive == null) return const [];
  final entries = archive
      .map((f) => ArchiveEntryInfo(f.name, f.size, f.isFile == false))
      .toList();
  entries.sort((a, b) => a.name.compareTo(b.name));
  return entries;
}

// ──────────────────────────────────────────────────────────────────────────
// Video
// ──────────────────────────────────────────────────────────────────────────

class VideoViewer extends StatefulWidget {
  const VideoViewer({
    super.key,
    required this.file,
    required this.isActive,
  });
  final FileEntry file;
  final bool isActive;

  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  VideoPlayerController? _controller;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final c = VideoPlayerController.file(File(widget.file.path));
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (_) {
      if (mounted) setState(() => _error = true);
      await c.dispose();
    }
  }

  @override
  void didUpdateWidget(covariant VideoViewer old) {
    super.didUpdateWidget(old);
    final c = _controller;
    if (c == null) return;
    if (!widget.isActive && c.value.isPlaying) c.pause();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return const PreviewMessage(
        icon: LucideIcons.film,
        title: 'Couldn\'t play this video',
        destructive: true,
      );
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) return const PreviewLoading();
    return Center(
      child: AspectRatio(
        aspectRatio: c.value.aspectRatio,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                c.value.isPlaying ? c.pause() : c.play();
                setState(() {});
              },
              child: VideoPlayer(c),
            ),
            _VideoControls(controller: c),
          ],
        ),
      ),
    );
  }
}

class _VideoControls extends StatefulWidget {
  const _VideoControls({required this.controller});
  final VideoPlayerController controller;

  @override
  State<_VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<_VideoControls> {
  late final ShadSliderController _seek = ShadSliderController(initialValue: 0);

  /// While the user drags, playback position must not fight the thumb.
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTick);
    _seek.dispose();
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    if (!_dragging) {
      final v = widget.controller.value;
      final total =
          v.duration.inMilliseconds.toDouble().clamp(1.0, double.infinity);
      _seek.value = v.position.inMilliseconds.toDouble().clamp(0.0, total);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.controller.value;
    final total =
        v.duration.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    const white = Color(0xFFFFFFFF);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xB0000000)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 36, 12, 12),
        child: Row(
          children: [
            ShadIconButton.ghost(
              width: 32,
              height: 32,
              padding: EdgeInsets.zero,
              iconSize: 20,
              foregroundColor: white,
              hoverBackgroundColor: const Color(0x33FFFFFF),
              onPressed: () => v.isPlaying
                  ? widget.controller.pause()
                  : widget.controller.play(),
              icon: Icon(v.isPlaying ? LucideIcons.pause : LucideIcons.play),
            ),
            const SizedBox(width: 10),
            Text(
              formatPreviewDuration(v.position),
              style: const TextStyle(color: white, fontSize: 11),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: ShadSlider(
                  controller: _seek,
                  min: 0,
                  max: total,
                  thumbColor: white,
                  activeTrackColor: white,
                  inactiveTrackColor: const Color(0x55FFFFFF),
                  onChangeStart: (_) => _dragging = true,
                  onChangeEnd: (val) {
                    widget.controller
                        .seekTo(Duration(milliseconds: val.toInt()));
                    _dragging = false;
                  },
                  onChanged: (_) {},
                ),
              ),
            ),
            Text(
              formatPreviewDuration(v.duration),
              style: const TextStyle(color: white, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Audio
// ──────────────────────────────────────────────────────────────────────────

class AudioViewer extends StatefulWidget {
  const AudioViewer({
    super.key,
    required this.file,
    required this.isActive,
  });
  final FileEntry file;
  final bool isActive;

  @override
  State<AudioViewer> createState() => _AudioViewerState();
}

class _AudioViewerState extends State<AudioViewer> {
  final _player = ja.AudioPlayer();
  late final ShadSliderController _seek = ShadSliderController(initialValue: 0);
  Duration _duration = Duration.zero;
  bool _error = false;

  /// While the user drags, the position stream must not fight the thumb.
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _duration = await _player.setFilePath(widget.file.path) ?? Duration.zero;
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void didUpdateWidget(covariant AudioViewer old) {
    super.didUpdateWidget(old);
    if (!widget.isActive && _player.playing) _player.pause();
  }

  @override
  void dispose() {
    _player.dispose();
    _seek.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    if (_error) {
      return const PreviewMessage(
        icon: LucideIcons.music,
        title: 'Couldn\'t play this audio file',
        destructive: true,
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: ShadCard(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 160,
                decoration: BoxDecoration(
                  color: colors.muted,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colors.border),
                ),
                alignment: Alignment.center,
                child: Icon(
                  LucideIcons.music,
                  size: 72,
                  color: colors.mutedForeground,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                widget.file.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colors.foreground,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${previewKind(widget.file.extension)} · '
                '${formatPreviewBytes(widget.file.size)}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  color: colors.mutedForeground,
                ),
              ),
              const SizedBox(height: 18),
              StreamBuilder<Duration>(
                stream: _player.positionStream,
                builder: (_, snap) {
                  final pos = snap.data ?? Duration.zero;
                  final totalMs = _duration.inMilliseconds
                      .toDouble()
                      .clamp(1.0, double.infinity);
                  if (!_dragging) {
                    _seek.value =
                        pos.inMilliseconds.toDouble().clamp(0.0, totalMs);
                  }
                  return Column(
                    children: [
                      ShadSlider(
                        controller: _seek,
                        min: 0,
                        max: totalMs,
                        onChangeStart: (_) => _dragging = true,
                        onChangeEnd: (v) {
                          _player.seek(Duration(milliseconds: v.toInt()));
                          _dragging = false;
                        },
                        onChanged: (_) {},
                      ),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            formatPreviewDuration(pos),
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.mutedForeground,
                            ),
                          ),
                          Text(
                            formatPreviewDuration(_duration),
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.mutedForeground,
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              StreamBuilder<ja.PlayerState>(
                stream: _player.playerStateStream,
                builder: (_, ps) {
                  final playing = ps.data?.playing ?? false;
                  return ShadButton(
                    onPressed: () => playing ? _player.pause() : _player.play(),
                    leading: Icon(
                      playing ? LucideIcons.pause : LucideIcons.play,
                      size: 16,
                    ),
                    child: Text(playing ? 'Pause' : 'Play'),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Unknown / binary
// ──────────────────────────────────────────────────────────────────────────

class UnsupportedViewer extends StatelessWidget {
  const UnsupportedViewer({super.key, required this.file});
  final FileEntry file;

  @override
  Widget build(BuildContext context) {
    final ext = previewExtLabel(file);
    return PreviewMessage(
      icon: LucideIcons.file,
      title: file.name,
      body: '${ext.isEmpty ? 'Document' : '$ext file'} · '
          '${formatPreviewBytes(file.size)}\n\n'
          'No inline preview for this file type.',
      actionLabel: kIsWeb ? null : 'Open in external app',
      onAction: kIsWeb ? null : () => openPathExternally(file.path),
    );
  }
}
