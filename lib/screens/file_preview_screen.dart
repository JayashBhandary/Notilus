import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Material, SelectionArea;
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path/path.dart' as p;
import 'package:pdfx/pdfx.dart';
import 'package:video_player/video_player.dart';

import '../models/file_entry.dart';
import '../theme.dart';

/// Quick-Look-style full-screen viewer.
///
/// [files] is the list of sibling files in the current folder (directories
/// excluded) and [initialIndex] picks the one to open first. Arrow keys
/// (desktop) and swiping (touch) jump between siblings.
class FilePreviewScreen extends StatefulWidget {
  const FilePreviewScreen({
    super.key,
    required this.files,
    required this.initialIndex,
  });

  final List<FileEntry> files;
  final int initialIndex;

  @override
  State<FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<FilePreviewScreen> {
  late PageController _pageController;
  late int _index;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.files.length - 1);
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _jump(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.files.length) return;
    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _showInfo() async {
    final current = widget.files[_index];
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => _InfoSheet(file: current),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.space) {
      _jump(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowUp) {
      _jump(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyI) {
      _showInfo();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final current = widget.files[_index];

    return CupertinoPageScaffold(
      backgroundColor: palette.scaffoldBg,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: palette.headerBg,
        border: Border(bottom: BorderSide(color: palette.divider)),
        middle: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              current.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: palette.text),
            ),
            if (widget.files.length > 1)
              Text(
                '${_index + 1} of ${widget.files.length}',
                style: TextStyle(fontSize: 10, color: palette.subtleText),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              onPressed:
                  widget.files.length > 1 && _index > 0 ? () => _jump(-1) : null,
              child: const Icon(CupertinoIcons.chevron_left, size: 20),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              onPressed: widget.files.length > 1 &&
                      _index < widget.files.length - 1
                  ? () => _jump(1)
                  : null,
              child: const Icon(CupertinoIcons.chevron_right, size: 20),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              onPressed: _showInfo,
              child: const Icon(CupertinoIcons.info_circle, size: 20),
            ),
          ],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Focus(
          autofocus: true,
          focusNode: _focusNode,
          onKeyEvent: _onKey,
          child: PageView.builder(
            controller: _pageController,
            itemCount: widget.files.length,
            physics: const BouncingScrollPhysics(),
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => _ViewerHost(
              file: widget.files[i],
              isActive: i == _index,
            ),
          ),
        ),
      ),
    );
  }
}

// Routes a single file to the right viewer based on its extension.
class _ViewerHost extends StatelessWidget {
  const _ViewerHost({required this.file, required this.isActive});

  final FileEntry file;
  final bool isActive;

  static const _imageExts = {
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic', '.tif', '.tiff',
    '.ico',
  };
  static const _svgExts = {'.svg', '.svgz'};
  static const _markdownExts = {'.md', '.markdown', '.mdown'};
  static const _textExts = {
    '.txt', '.json', '.yaml', '.yml', '.xml', '.csv', '.tsv',
    '.html', '.htm', '.css', '.scss', '.less',
    '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx',
    '.dart', '.py', '.rb', '.go', '.rs', '.c', '.cpp', '.cc', '.h', '.hpp',
    '.java', '.kt', '.swift', '.sh', '.bash', '.zsh', '.fish',
    '.toml', '.ini', '.conf', '.cfg', '.env', '.log',
    '.lua', '.pl', '.php', '.sql', '.r', '.scala', '.groovy',
    '.gradle', '.cmake', '.dockerfile', '.gitignore', '.gitattributes',
  };
  static const _pdfExts = {'.pdf'};
  static const _officeExts = {
    '.docx', '.doc', '.odt', '.rtf',
    '.xlsx', '.xls', '.ods',
    '.pptx', '.ppt', '.odp',
  };
  static const _archiveExts = {
    '.zip', '.jar', '.tar', '.tgz', '.gz', '.bz2', '.tbz2', '.tar.gz', '.tar.bz2',
  };
  static const _videoExts = {'.mp4', '.mov', '.m4v', '.mkv', '.webm', '.avi'};
  static const _audioExts = {
    '.mp3', '.wav', '.m4a', '.aac', '.flac', '.ogg', '.opus', '.wma',
  };

  /// Returns the matching extension, treating compound suffixes like
  /// `.tar.gz` as a single extension.
  String _normalisedExt() {
    final lower = file.name.toLowerCase();
    if (lower.endsWith('.tar.gz')) return '.tar.gz';
    if (lower.endsWith('.tar.bz2')) return '.tar.bz2';
    return file.extension;
  }

  @override
  Widget build(BuildContext context) {
    final ext = _normalisedExt();
    if (_imageExts.contains(ext)) {
      return _ImageView(file: file);
    }
    if (_svgExts.contains(ext)) {
      return _SvgView(file: file);
    }
    if (_markdownExts.contains(ext)) {
      return _MarkdownView(file: file);
    }
    if (_textExts.contains(ext)) {
      return _TextView(file: file);
    }
    if (_pdfExts.contains(ext)) {
      if (!kIsWeb && Platform.isLinux) {
        return _LinuxPdfView(file: file);
      }
      return _PdfView(file: file);
    }
    if (_officeExts.contains(ext)) {
      return _OfficeView(file: file);
    }
    if (_archiveExts.contains(ext)) {
      return _ArchiveView(file: file);
    }
    if (_videoExts.contains(ext)) {
      return _VideoView(file: file, isActive: isActive);
    }
    if (_audioExts.contains(ext)) {
      return _AudioView(file: file, isActive: isActive);
    }
    return _UnsupportedView(file: file);
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Shared transform controller for zoom/rotate toolbar.
// ──────────────────────────────────────────────────────────────────────────

class _ViewerToolbar extends StatelessWidget {
  const _ViewerToolbar({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return Positioned(
      bottom: 16,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: palette.cardBg.withValues(alpha: 0.92),
            border: Border.all(color: palette.divider),
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 10,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.onPressed,
  });
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      onPressed: onPressed,
      child: Icon(
        icon,
        size: 18,
        color: onPressed == null ? palette.subtleText : palette.text,
      ),
    );
  }
}

class _ToolbarLabel extends StatelessWidget {
  const _ToolbarLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: palette.subtleText),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Image — InteractiveViewer + zoom + rotate toolbar.
// ──────────────────────────────────────────────────────────────────────────

class _ImageView extends StatefulWidget {
  const _ImageView({required this.file});
  final FileEntry file;

  @override
  State<_ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends State<_ImageView> {
  final TransformationController _xform = TransformationController();
  int _quarterTurns = 0;
  double _scale = 1.0;

  @override
  void dispose() {
    _xform.dispose();
    super.dispose();
  }

  void _setScale(double s) {
    final clamped = s.clamp(1.0, 6.0);
    _xform.value = Matrix4.identity()..scaleByDouble(clamped, clamped, clamped, 1);
    setState(() => _scale = clamped);
  }

  void _zoomIn() => _setScale(_scale * 1.25);
  void _zoomOut() => _setScale(_scale / 1.25);
  void _reset() {
    _xform.value = Matrix4.identity();
    setState(() => _scale = 1.0);
  }

  void _rotate() => setState(() => _quarterTurns = (_quarterTurns + 1) % 4);

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return ColoredBox(
      color: palette.scaffoldBg,
      child: Stack(
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
                    errorBuilder: (_, __, ___) => _ErrorBox(
                      icon: CupertinoIcons.photo,
                      message: 'Couldn\'t decode this image.',
                      palette: palette,
                    ),
                  ),
                ),
              ),
            ),
          ),
          _ViewerToolbar(
            children: [
              _ToolbarButton(
                icon: CupertinoIcons.zoom_out,
                onPressed: _scale > 1.01 ? _zoomOut : null,
              ),
              _ToolbarLabel(text: '${(_scale * 100).round()}%'),
              _ToolbarButton(
                icon: CupertinoIcons.zoom_in,
                onPressed: _scale < 5.9 ? _zoomIn : null,
              ),
              _ToolbarButton(
                icon: CupertinoIcons.arrow_counterclockwise,
                onPressed: _reset,
              ),
              _ToolbarButton(
                icon: CupertinoIcons.rotate_right,
                onPressed: _rotate,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// SVG — zoom + reset.
// ──────────────────────────────────────────────────────────────────────────

class _SvgView extends StatefulWidget {
  const _SvgView({required this.file});
  final FileEntry file;

  @override
  State<_SvgView> createState() => _SvgViewState();
}

class _SvgViewState extends State<_SvgView> {
  final TransformationController _xform = TransformationController();
  double _scale = 1.0;

  @override
  void dispose() {
    _xform.dispose();
    super.dispose();
  }

  void _setScale(double s) {
    final clamped = s.clamp(1.0, 8.0);
    _xform.value = Matrix4.identity()..scaleByDouble(clamped, clamped, clamped, 1);
    setState(() => _scale = clamped);
  }

  void _reset() {
    _xform.value = Matrix4.identity();
    setState(() => _scale = 1.0);
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
    final palette = AppColors.of(context);
    return ColoredBox(
      color: palette.scaffoldBg,
      child: Stack(
        children: [
          Positioned.fill(
            child: FutureBuilder<Uint8List>(
              future: _loadBytes(),
              builder: (_, snap) {
                if (!snap.hasData) {
                  return const Center(child: CupertinoActivityIndicator());
                }
                if (snap.hasError) {
                  return _ErrorBox(
                    icon: CupertinoIcons.cube_box,
                    message: 'Couldn\'t open this SVG: ${snap.error}',
                    palette: palette,
                  );
                }
                return InteractiveViewer(
                  transformationController: _xform,
                  minScale: 1,
                  maxScale: 8,
                  onInteractionUpdate: (_) {
                    final s = _xform.value.getMaxScaleOnAxis();
                    if ((s - _scale).abs() > 0.01) {
                      setState(() => _scale = s);
                    }
                  },
                  child: Center(
                    child: SvgPicture.memory(
                      snap.data!,
                      fit: BoxFit.contain,
                      placeholderBuilder: (_) =>
                          const Center(child: CupertinoActivityIndicator()),
                    ),
                  ),
                );
              },
            ),
          ),
          _ViewerToolbar(
            children: [
              _ToolbarButton(
                icon: CupertinoIcons.zoom_out,
                onPressed: _scale > 1.01 ? () => _setScale(_scale / 1.25) : null,
              ),
              _ToolbarLabel(text: '${(_scale * 100).round()}%'),
              _ToolbarButton(
                icon: CupertinoIcons.zoom_in,
                onPressed: _scale < 7.9 ? () => _setScale(_scale * 1.25) : null,
              ),
              _ToolbarButton(
                icon: CupertinoIcons.arrow_counterclockwise,
                onPressed: _reset,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Markdown — flutter_markdown rendered, with a toggle to view raw source.
// ──────────────────────────────────────────────────────────────────────────

class _MarkdownView extends StatefulWidget {
  const _MarkdownView({required this.file});
  final FileEntry file;

  @override
  State<_MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<_MarkdownView> {
  static const _cap = 1024 * 1024;
  Future<String>? _future;
  bool _raw = false;

  @override
  void initState() {
    super.initState();
    _future = _read();
  }

  Future<String> _read() async {
    final f = File(widget.file.path);
    final size = await f.length();
    if (size <= _cap) return f.readAsString();
    final raf = await f.open();
    try {
      final bytes = await raf.read(_cap);
      return '${String.fromCharCodes(bytes)}\n\n[truncated]';
    } finally {
      await raf.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return ColoredBox(
      color: palette.scaffoldBg,
      child: Stack(
        children: [
          Positioned.fill(
            child: FutureBuilder<String>(
              future: _future,
              builder: (_, snap) {
                if (!snap.hasData) {
                  return const Center(child: CupertinoActivityIndicator());
                }
                if (snap.hasError) {
                  return _ErrorBox(
                    icon: CupertinoIcons.doc_text,
                    message: 'Couldn\'t read this file: ${snap.error}',
                    palette: palette,
                  );
                }
                if (_raw) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 72),
                    child: SelectionArea(
                      child: Text(
                        snap.data!,
                        style: TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 12,
                          height: 1.45,
                          color: palette.text,
                        ),
                      ),
                    ),
                  );
                }
                return Material(
                  color: Colors.transparent,
                  child: Markdown(
                    data: snap.data!,
                    selectable: true,
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 72),
                    styleSheet: MarkdownStyleSheet(
                      p: TextStyle(
                        fontSize: 13.5,
                        height: 1.55,
                        color: palette.text,
                      ),
                      h1: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: palette.text,
                      ),
                      h2: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: palette.text,
                      ),
                      h3: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: palette.text,
                      ),
                      code: TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 12,
                        backgroundColor: palette.cardBg,
                        color: palette.text,
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: palette.cardBg,
                        border: Border.all(color: palette.divider),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      blockquoteDecoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: palette.divider, width: 3),
                        ),
                      ),
                      blockquote: TextStyle(
                        fontSize: 13,
                        color: palette.subtleText,
                        fontStyle: FontStyle.italic,
                      ),
                      a: const TextStyle(color: CupertinoColors.activeBlue),
                      tableBorder: TableBorder.all(color: palette.divider),
                    ),
                  ),
                );
              },
            ),
          ),
          _ViewerToolbar(
            children: [
              _ToolbarButton(
                icon: _raw
                    ? CupertinoIcons.eye
                    : CupertinoIcons.doc_plaintext,
                onPressed: () => setState(() => _raw = !_raw),
              ),
              _ToolbarLabel(text: _raw ? 'Raw' : 'Rendered'),
            ],
          ),
        ],
      ),
    );
  }
}

// Material's transparent placeholder needs an explicit color import alias.
class Colors {
  static const Color transparent = Color(0x00000000);
}

// ──────────────────────────────────────────────────────────────────────────
// Text / source code.
// ──────────────────────────────────────────────────────────────────────────

class _TextView extends StatefulWidget {
  const _TextView({required this.file});
  final FileEntry file;

  @override
  State<_TextView> createState() => _TextViewState();
}

class _TextViewState extends State<_TextView> {
  static const _cap = 1024 * 1024; // 1 MB
  Future<String>? _future;

  @override
  void initState() {
    super.initState();
    _future = _read();
  }

  Future<String> _read() async {
    final f = File(widget.file.path);
    final size = await f.length();
    if (size <= _cap) return f.readAsString();
    final raf = await f.open();
    try {
      final bytes = await raf.read(_cap);
      return '${String.fromCharCodes(bytes)}\n\n[truncated after '
          '${_cap ~/ 1024} KB of ${(size / 1024).toStringAsFixed(0)} KB]';
    } finally {
      await raf.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return FutureBuilder<String>(
      future: _future,
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Center(child: CupertinoActivityIndicator());
        }
        if (snap.hasError) {
          return _ErrorBox(
            icon: CupertinoIcons.doc_text,
            message: 'Couldn\'t read this file: ${snap.error}',
            palette: palette,
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectionArea(
            child: Text(
              snap.data!,
              style: TextStyle(
                fontFamily: 'Menlo',
                fontSize: 12,
                height: 1.45,
                color: palette.text,
              ),
            ),
          ),
        );
      },
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// PDF via pdfx (PDFKit on iOS/macOS, PdfRenderer on Android, PDFium on Win).
// With page navigator, zoom + thumbnail rail.
// ──────────────────────────────────────────────────────────────────────────

class _PdfView extends StatefulWidget {
  const _PdfView({required this.file});
  final FileEntry file;

  @override
  State<_PdfView> createState() => _PdfViewState();
}

class _PdfViewState extends State<_PdfView> {
  late final PdfControllerPinch _controller;
  PdfDocument? _thumbDoc;
  int _page = 1;
  int _pagesCount = 0;
  bool _showThumbs = false;
  final _jumpCtl = TextEditingController();

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
        _pagesCount = d.pagesCount;
      });
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _controller.dispose();
    _thumbDoc?.close();
    _jumpCtl.dispose();
    super.dispose();
  }

  void _onPageChanged(int page) {
    if (!mounted) return;
    setState(() => _page = page);
  }

  Future<void> _goto(int page) async {
    if (_pagesCount == 0) return;
    final clamped = page.clamp(1, _pagesCount);
    await _controller.animateToPage(pageNumber: clamped);
  }

  Future<void> _promptJump() async {
    _jumpCtl.text = '$_page';
    final picked = await showCupertinoDialog<int>(
      context: context,
      builder: (ctx) {
        return CupertinoAlertDialog(
          title: const Text('Go to page'),
          content: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: CupertinoTextField(
              controller: _jumpCtl,
              keyboardType: TextInputType.number,
              autofocus: true,
              placeholder: '1 – $_pagesCount',
              onSubmitted: (v) =>
                  Navigator.of(ctx).pop(int.tryParse(v.trim())),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            CupertinoDialogAction(
              onPressed: () =>
                  Navigator.of(ctx).pop(int.tryParse(_jumpCtl.text.trim())),
              child: const Text('Go'),
            ),
          ],
        );
      },
    );
    if (picked != null) _goto(picked);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: PdfViewPinch(
            controller: _controller,
            onDocumentLoaded: (d) {
              if (!mounted) return;
              setState(() => _pagesCount = d.pagesCount);
            },
            onPageChanged: _onPageChanged,
            onDocumentError: (_) {},
            builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
              options: const DefaultBuilderOptions(),
              documentLoaderBuilder: (_) =>
                  const Center(child: CupertinoActivityIndicator()),
              pageLoaderBuilder: (_) =>
                  const Center(child: CupertinoActivityIndicator()),
              errorBuilder: (_, e) => _ErrorBox(
                icon: CupertinoIcons.doc_richtext,
                message: 'Couldn\'t open this PDF: $e',
                palette: palette,
              ),
            ),
          ),
        ),
        if (_showThumbs && _thumbDoc != null)
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            child: _PdfThumbnailRail(
              doc: _thumbDoc!,
              currentPage: _page,
              onTap: _goto,
            ),
          ),
        _ViewerToolbar(
          children: [
            _ToolbarButton(
              icon: CupertinoIcons.sidebar_left,
              onPressed: _thumbDoc == null
                  ? null
                  : () => setState(() => _showThumbs = !_showThumbs),
            ),
            _ToolbarButton(
              icon: CupertinoIcons.chevron_left,
              onPressed: _page > 1 ? () => _goto(_page - 1) : null,
            ),
            GestureDetector(
              onTap: _pagesCount > 0 ? _promptJump : null,
              child: _ToolbarLabel(
                text: _pagesCount == 0
                    ? '— / —'
                    : '$_page / $_pagesCount',
              ),
            ),
            _ToolbarButton(
              icon: CupertinoIcons.chevron_right,
              onPressed:
                  _pagesCount > 0 && _page < _pagesCount ? () => _goto(_page + 1) : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _PdfThumbnailRail extends StatelessWidget {
  const _PdfThumbnailRail({
    required this.doc,
    required this.currentPage,
    required this.onTap,
  });
  final PdfDocument doc;
  final int currentPage;
  final void Function(int page) onTap;

  Future<Uint8List?> _thumb(int page) async {
    try {
      final p = await doc.getPage(page);
      try {
        final img = await p.render(
          width: 120,
          height: (120 * p.height / p.width).clamp(40, 220),
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        return img?.bytes;
      } finally {
        await p.close();
      }
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return Container(
      width: 100,
      color: palette.headerBg.withValues(alpha: 0.96),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: palette.divider)),
            ),
            child: Text(
              'Pages',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: palette.subtleText,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: doc.pagesCount,
              itemBuilder: (_, i) {
                final page = i + 1;
                final selected = page == currentPage;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(page),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: selected
                                  ? CupertinoColors.activeBlue
                                  : palette.divider,
                              width: selected ? 2 : 1,
                            ),
                            color: const Color(0xFFFFFFFF),
                          ),
                          child: FutureBuilder<Uint8List?>(
                            future: _thumb(page),
                            builder: (_, snap) {
                              if (snap.data == null) {
                                return const SizedBox(
                                  width: 84,
                                  height: 108,
                                  child:
                                      Center(child: CupertinoActivityIndicator()),
                                );
                              }
                              return Image.memory(
                                snap.data!,
                                width: 84,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$page',
                          style: TextStyle(
                            fontSize: 10,
                            color: selected
                                ? CupertinoColors.activeBlue
                                : palette.subtleText,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
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

// ──────────────────────────────────────────────────────────────────────────
// PDF on Linux — pdfx has no Linux plugin, so render with poppler's
// `pdftoppm` to PNGs and show as a scrollable list. Falls back to
// `xdg-open` (external viewer) if poppler isn't installed.
// ──────────────────────────────────────────────────────────────────────────

class _LinuxPdfView extends StatefulWidget {
  const _LinuxPdfView({required this.file});
  final FileEntry file;

  @override
  State<_LinuxPdfView> createState() => _LinuxPdfViewState();
}

class _LinuxPdfViewState extends State<_LinuxPdfView> {
  static const _maxPages = 100;
  static const _dpi = 110;

  Directory? _tmpDir;
  List<File> _pages = const [];
  bool _loading = true;
  bool _popplerMissing = false;
  String? _errorMsg;

  final ScrollController _scroll = ScrollController();
  final List<GlobalKey> _pageKeys = [];
  int _currentPage = 1;
  bool _showThumbs = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _render();
  }

  void _onScroll() {
    if (_pageKeys.isEmpty) return;
    // Find first key whose top is below 0; previous one is the currently-visible.
    for (var i = 0; i < _pageKeys.length; i++) {
      final ctx = _pageKeys[i].currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final pos = box.localToGlobal(Offset.zero);
      if (pos.dy > 80) {
        final page = (i - 1).clamp(0, _pageKeys.length - 1) + 1;
        if (page != _currentPage) setState(() => _currentPage = page);
        return;
      }
    }
    if (_currentPage != _pageKeys.length) {
      setState(() => _currentPage = _pageKeys.length);
    }
  }

  Future<void> _render() async {
    Directory tmp;
    try {
      tmp = await Directory.systemTemp.createTemp('notilus_pdf_');
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
      final result = await Process.run('pdftoppm', [
        '-png',
        '-r', '$_dpi',
        '-f', '1',
        '-l', '$_maxPages',
        widget.file.path,
        p.join(tmp.path, 'p'),
      ]);
      if (result.exitCode != 0) {
        if (mounted) {
          setState(() {
            _loading = false;
            _errorMsg =
                (result.stderr is String && (result.stderr as String).isNotEmpty)
                    ? result.stderr as String
                    : 'pdftoppm exited ${result.exitCode}';
          });
        }
        return;
      }
    } on ProcessException {
      if (mounted) {
        setState(() {
          _loading = false;
          _popplerMissing = true;
        });
      }
      return;
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMsg = '$e';
        });
      }
      return;
    }

    final pages = tmp
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (mounted) {
      setState(() {
        _pages = pages;
        _pageKeys.clear();
        _pageKeys.addAll(List.generate(pages.length, (_) => GlobalKey()));
        _loading = false;
      });
    }
  }

  Future<void> _openExternally() async {
    try {
      await Process.run('xdg-open', [widget.file.path]);
    } catch (_) {}
  }

  Future<void> _goto(int page) async {
    if (page < 1 || page > _pageKeys.length) return;
    final ctx = _pageKeys[page - 1].currentContext;
    if (ctx == null) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      alignment: 0,
    );
  }

  Future<void> _promptJump() async {
    final ctl = TextEditingController(text: '$_currentPage');
    final picked = await showCupertinoDialog<int>(
      context: context,
      builder: (ctx) {
        return CupertinoAlertDialog(
          title: const Text('Go to page'),
          content: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: CupertinoTextField(
              controller: ctl,
              keyboardType: TextInputType.number,
              autofocus: true,
              placeholder: '1 – ${_pages.length}',
              onSubmitted: (v) =>
                  Navigator.of(ctx).pop(int.tryParse(v.trim())),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            CupertinoDialogAction(
              onPressed: () =>
                  Navigator.of(ctx).pop(int.tryParse(ctl.text.trim())),
              child: const Text('Go'),
            ),
          ],
        );
      },
    );
    if (picked != null) _goto(picked);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    final t = _tmpDir;
    if (t != null) {
      t.delete(recursive: true).catchError((_) => t);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    if (_loading) {
      return const Center(child: CupertinoActivityIndicator());
    }
    if (_popplerMissing) {
      return _PdfFallbackBox(
        palette: palette,
        title: 'Install poppler-utils for inline PDF preview',
        body: 'Run: sudo apt install poppler-utils\n'
            '(or your distro\'s equivalent)',
        onOpenExternal: _openExternally,
      );
    }
    if (_errorMsg != null || _pages.isEmpty) {
      return _PdfFallbackBox(
        palette: palette,
        title: 'Couldn\'t render this PDF',
        body: _errorMsg ?? 'No pages were produced.',
        onOpenExternal: _openExternally,
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: palette.scaffoldBg,
            child: ListView.separated(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(
                _showThumbs ? 108 : 8,
                12,
                8,
                72,
              ),
              itemCount: _pages.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => KeyedSubtree(
                key: _pageKeys[i],
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: palette.divider),
                    color: const Color(0xFFFFFFFF),
                  ),
                  child: Image.file(_pages[i], fit: BoxFit.contain),
                ),
              ),
            ),
          ),
        ),
        if (_showThumbs)
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            child: _LinuxPdfThumbnailRail(
              pages: _pages,
              currentPage: _currentPage,
              onTap: _goto,
            ),
          ),
        _ViewerToolbar(
          children: [
            _ToolbarButton(
              icon: CupertinoIcons.sidebar_left,
              onPressed: () => setState(() => _showThumbs = !_showThumbs),
            ),
            _ToolbarButton(
              icon: CupertinoIcons.chevron_left,
              onPressed:
                  _currentPage > 1 ? () => _goto(_currentPage - 1) : null,
            ),
            GestureDetector(
              onTap: _promptJump,
              child: _ToolbarLabel(
                text: '$_currentPage / ${_pages.length}',
              ),
            ),
            _ToolbarButton(
              icon: CupertinoIcons.chevron_right,
              onPressed: _currentPage < _pages.length
                  ? () => _goto(_currentPage + 1)
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _LinuxPdfThumbnailRail extends StatelessWidget {
  const _LinuxPdfThumbnailRail({
    required this.pages,
    required this.currentPage,
    required this.onTap,
  });
  final List<File> pages;
  final int currentPage;
  final void Function(int page) onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return Container(
      width: 100,
      color: palette.headerBg.withValues(alpha: 0.96),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: palette.divider)),
            ),
            child: Text(
              'Pages',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: palette.subtleText,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: pages.length,
              itemBuilder: (_, i) {
                final page = i + 1;
                final selected = page == currentPage;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(page),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: selected
                                  ? CupertinoColors.activeBlue
                                  : palette.divider,
                              width: selected ? 2 : 1,
                            ),
                            color: const Color(0xFFFFFFFF),
                          ),
                          child: Image.file(
                            pages[i],
                            width: 84,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$page',
                          style: TextStyle(
                            fontSize: 10,
                            color: selected
                                ? CupertinoColors.activeBlue
                                : palette.subtleText,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
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

class _PdfFallbackBox extends StatelessWidget {
  const _PdfFallbackBox({
    required this.palette,
    required this.title,
    required this.body,
    required this.onOpenExternal,
  });
  final AppPalette palette;
  final String title;
  final String body;
  final VoidCallback onOpenExternal;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.doc_richtext,
              size: 44,
              color: palette.subtleText,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: palette.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: palette.subtleText,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            CupertinoButton.filled(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              onPressed: onOpenExternal,
              child: const Text('Open in external viewer'),
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Office documents — convert to PDF via LibreOffice (soffice/libreoffice
// in PATH) and reuse the PDF pipeline. Falls back to a message if
// LibreOffice isn't installed.
// ──────────────────────────────────────────────────────────────────────────

class _OfficeView extends StatefulWidget {
  const _OfficeView({required this.file});
  final FileEntry file;

  @override
  State<_OfficeView> createState() => _OfficeViewState();
}

class _OfficeViewState extends State<_OfficeView> {
  Directory? _tmpDir;
  File? _convertedPdf;
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
    // Try common executable names on PATH.
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
    // Try platform-specific install locations.
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
        '--convert-to', 'pdf',
        '--outdir', tmp.path,
        widget.file.path,
      ]);
      if (r.exitCode != 0) {
        if (mounted) {
          setState(() {
            _loading = false;
            _errorMsg =
                (r.stderr is String && (r.stderr as String).isNotEmpty)
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
    final pdf = File(p.join(tmp.path, '$base.pdf'));
    if (!await pdf.exists()) {
      // Sometimes LibreOffice picks a different base name.
      final any = tmp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.pdf'))
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
      if (mounted) {
        setState(() {
          _convertedPdf = any.first;
          _loading = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _convertedPdf = pdf;
        _loading = false;
      });
    }
  }

  Future<void> _openExternally() async {
    try {
      if (Platform.isLinux) {
        await Process.run('xdg-open', [widget.file.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [widget.file.path]);
      } else if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', widget.file.path]);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(),
            const SizedBox(height: 10),
            Text(
              'Converting ${widget.file.name}…',
              style: TextStyle(fontSize: 12, color: palette.subtleText),
            ),
          ],
        ),
      );
    }
    if (_missing) {
      return _PdfFallbackBox(
        palette: palette,
        title: 'Install LibreOffice for inline Office previews',
        body: 'Notilus uses LibreOffice (`soffice`) to render Word, Excel '
            'and PowerPoint files. Once installed, this preview will work '
            'automatically.',
        onOpenExternal: _openExternally,
      );
    }
    if (_convertedPdf == null) {
      return _PdfFallbackBox(
        palette: palette,
        title: 'Couldn\'t render this document',
        body: _errorMsg ?? 'Unknown error.',
        onOpenExternal: _openExternally,
      );
    }
    // Reuse the PDF pipeline on the converted file.
    final asPdfEntry = FileEntry(
      path: _convertedPdf!.path,
      name: p.basename(_convertedPdf!.path),
      isDirectory: false,
      size: _convertedPdf!.lengthSync(),
      modified: _convertedPdf!.lastModifiedSync(),
    );
    if (!kIsWeb && Platform.isLinux) {
      return _LinuxPdfView(file: asPdfEntry);
    }
    return _PdfView(file: asPdfEntry);
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Archive listing — .zip / .tar / .tar.gz / .gz / .bz2.
// ──────────────────────────────────────────────────────────────────────────

class _ArchiveView extends StatefulWidget {
  const _ArchiveView({required this.file});
  final FileEntry file;

  @override
  State<_ArchiveView> createState() => _ArchiveViewState();
}

class _ArchiveEntry {
  _ArchiveEntry(this.name, this.size, this.isDir);
  final String name;
  final int size;
  final bool isDir;
}

class _ArchiveViewState extends State<_ArchiveView> {
  Future<List<_ArchiveEntry>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _scan();
  }

  Future<List<_ArchiveEntry>> _scan() async {
    final lower = widget.file.name.toLowerCase();
    final bytes = await File(widget.file.path).readAsBytes();

    Archive? archive;
    try {
      if (lower.endsWith('.zip') || lower.endsWith('.jar')) {
        archive = ZipDecoder().decodeBytes(bytes);
      } else if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
        final gunz = GZipDecoder().decodeBytes(bytes);
        archive = TarDecoder().decodeBytes(gunz);
      } else if (lower.endsWith('.tar.bz2') || lower.endsWith('.tbz2')) {
        final bunz = BZip2Decoder().decodeBytes(bytes);
        archive = TarDecoder().decodeBytes(bunz);
      } else if (lower.endsWith('.tar')) {
        archive = TarDecoder().decodeBytes(bytes);
      } else if (lower.endsWith('.gz')) {
        final gunz = GZipDecoder().decodeBytes(bytes);
        return [
          _ArchiveEntry(
            p.basenameWithoutExtension(widget.file.name),
            gunz.length,
            false,
          ),
        ];
      } else if (lower.endsWith('.bz2')) {
        final bunz = BZip2Decoder().decodeBytes(bytes);
        return [
          _ArchiveEntry(
            p.basenameWithoutExtension(widget.file.name),
            bunz.length,
            false,
          ),
        ];
      }
    } catch (e) {
      throw 'Decode failed: $e';
    }
    if (archive == null) return const [];
    return archive
        .map((f) => _ArchiveEntry(f.name, f.size, f.isFile == false))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return FutureBuilder<List<_ArchiveEntry>>(
      future: _future,
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CupertinoActivityIndicator());
        }
        if (snap.hasError) {
          return _ErrorBox(
            icon: CupertinoIcons.archivebox,
            message: 'Couldn\'t read this archive: ${snap.error}',
            palette: palette,
          );
        }
        final entries = snap.data!;
        if (entries.isEmpty) {
          return _ErrorBox(
            icon: CupertinoIcons.archivebox,
            message: 'Archive is empty.',
            palette: palette,
          );
        }
        final totalSize = entries.fold<int>(0, (a, b) => a + b.size);
        return ColoredBox(
          color: palette.scaffoldBg,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                decoration: BoxDecoration(
                  color: palette.headerBg,
                  border: Border(bottom: BorderSide(color: palette.divider)),
                ),
                child: Row(
                  children: [
                    Icon(
                      CupertinoIcons.archivebox,
                      size: 18,
                      color: palette.subtleText,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${entries.length} entries '
                        '• ${_fmtSize(totalSize)} uncompressed',
                        style:
                            TextStyle(fontSize: 12, color: palette.subtleText),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => Container(
                    height: 1,
                    color: palette.divider,
                  ),
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          Icon(
                            e.isDir
                                ? CupertinoIcons.folder
                                : CupertinoIcons.doc,
                            size: 16,
                            color: palette.subtleText,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              e.name,
                              style: TextStyle(
                                fontFamily: 'Menlo',
                                fontSize: 12,
                                color: palette.text,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (!e.isDir)
                            Text(
                              _fmtSize(e.size),
                              style: TextStyle(
                                fontSize: 11,
                                color: palette.subtleText,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Video via video_player.
// ──────────────────────────────────────────────────────────────────────────

class _VideoView extends StatefulWidget {
  const _VideoView({required this.file, required this.isActive});
  final FileEntry file;
  final bool isActive;

  @override
  State<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<_VideoView> {
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
  void didUpdateWidget(covariant _VideoView old) {
    super.didUpdateWidget(old);
    final c = _controller;
    if (c == null) return;
    if (!widget.isActive && c.value.isPlaying) {
      c.pause();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    if (_error) {
      return _ErrorBox(
        icon: CupertinoIcons.film,
        message: 'Couldn\'t play this video.',
        palette: palette,
      );
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CupertinoActivityIndicator());
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (c.value.isPlaying) {
          c.pause();
        } else {
          c.play();
        }
        setState(() {});
      },
      child: Center(
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              VideoPlayer(c),
              _VideoControls(controller: c, palette: palette),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoControls extends StatefulWidget {
  const _VideoControls({required this.controller, required this.palette});
  final VideoPlayerController controller;
  final AppPalette palette;

  @override
  State<_VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<_VideoControls> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.controller.value;
    final total = v.duration.inMilliseconds.toDouble().clamp(1, double.infinity);
    final pos = v.position.inMilliseconds.toDouble().clamp(0.0, total);
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0x88000000)],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 32, 12, 12),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (v.isPlaying) {
                widget.controller.pause();
              } else {
                widget.controller.play();
              }
            },
            child: Icon(
              v.isPlaying
                  ? CupertinoIcons.pause_fill
                  : CupertinoIcons.play_fill,
              color: CupertinoColors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _fmt(v.position),
            style: const TextStyle(color: CupertinoColors.white, fontSize: 11),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: CupertinoSlider(
                min: 0,
                max: total.toDouble(),
                value: pos.toDouble(),
                onChanged: (val) {
                  widget.controller.seekTo(
                    Duration(milliseconds: val.toInt()),
                  );
                },
              ),
            ),
          ),
          Text(
            _fmt(v.duration),
            style: const TextStyle(color: CupertinoColors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Audio via just_audio.
// ──────────────────────────────────────────────────────────────────────────

class _AudioView extends StatefulWidget {
  const _AudioView({required this.file, required this.isActive});
  final FileEntry file;
  final bool isActive;

  @override
  State<_AudioView> createState() => _AudioViewState();
}

class _AudioViewState extends State<_AudioView> {
  final _player = ja.AudioPlayer();
  Duration _duration = Duration.zero;
  bool _error = false;

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
  void didUpdateWidget(covariant _AudioView old) {
    super.didUpdateWidget(old);
    if (!widget.isActive && _player.playing) {
      _player.pause();
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60);
    return '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    if (_error) {
      return _ErrorBox(
        icon: CupertinoIcons.music_note,
        message: 'Couldn\'t play this audio file.',
        palette: palette,
      );
    }
    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (_, snap) {
        final pos = snap.data ?? Duration.zero;
        final totalMs =
            _duration.inMilliseconds.toDouble().clamp(1, double.infinity);
        final posMs = pos.inMilliseconds.toDouble().clamp(0.0, totalMs);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 168,
                    height: 168,
                    decoration: BoxDecoration(
                      color: palette.cardBg,
                      border: Border.all(color: palette.divider),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      CupertinoIcons.music_note_2,
                      size: 100,
                      color: palette.subtleText,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    widget.file.name,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: palette.text,
                    ),
                  ),
                  const SizedBox(height: 14),
                  CupertinoSlider(
                    min: 0,
                    max: totalMs.toDouble(),
                    value: posMs.toDouble(),
                    onChanged: (v) => _player
                        .seek(Duration(milliseconds: v.toInt())),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _fmt(pos),
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.subtleText,
                        ),
                      ),
                      Text(
                        _fmt(_duration),
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.subtleText,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  StreamBuilder<ja.PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (_, ps) {
                      final playing = ps.data?.playing ?? false;
                      return CupertinoButton.filled(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 26,
                          vertical: 10,
                        ),
                        onPressed: () {
                          if (playing) {
                            _player.pause();
                          } else {
                            _player.play();
                          }
                        },
                        child: Icon(
                          playing
                              ? CupertinoIcons.pause_fill
                              : CupertinoIcons.play_fill,
                          color: CupertinoColors.white,
                          size: 22,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Fallback for unknown / binary types.
// ──────────────────────────────────────────────────────────────────────────

class _UnsupportedView extends StatelessWidget {
  const _UnsupportedView({required this.file});
  final FileEntry file;

  String _formatSize(int b) {
    if (b < 1024) return '$b bytes';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _openExternally() async {
    try {
      if (kIsWeb) return;
      if (Platform.isLinux) {
        await Process.run('xdg-open', [file.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [file.path]);
      } else if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', file.path]);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final ext = file.extension.isEmpty
        ? ''
        : file.extension.substring(1).toUpperCase();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: palette.cardBg,
                border: Border.all(color: palette.divider),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    CupertinoIcons.doc,
                    size: 60,
                    color: palette.subtleText,
                  ),
                  if (ext.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        ext,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: palette.subtleText,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(
              file.name,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: palette.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${ext.isEmpty ? 'Document' : '$ext file'} '
              '— ${_formatSize(file.size)}',
              style: TextStyle(fontSize: 12, color: palette.subtleText),
            ),
            const SizedBox(height: 14),
            Text(
              'No preview available for this file type.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: palette.subtleText,
                height: 1.4,
              ),
            ),
            if (!kIsWeb) ...[
              const SizedBox(height: 16),
              CupertinoButton.filled(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                onPressed: _openExternally,
                child: const Text('Open in external app'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Info sheet — Finder/Explorer-style metadata popover.
// ──────────────────────────────────────────────────────────────────────────

class _InfoSheet extends StatefulWidget {
  const _InfoSheet({required this.file});
  final FileEntry file;

  @override
  State<_InfoSheet> createState() => _InfoSheetState();
}

class _InfoSheetState extends State<_InfoSheet> {
  Size? _imageDims;
  bool _dimsLoaded = false;

  @override
  void initState() {
    super.initState();
    if (widget.file.isImage) _loadDims();
  }

  Future<void> _loadDims() async {
    try {
      final bytes = await File(widget.file.path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      if (mounted) {
        setState(() {
          _imageDims = Size(img.width.toDouble(), img.height.toDouble());
          _dimsLoaded = true;
        });
      }
      img.dispose();
      codec.dispose();
    } catch (_) {
      if (mounted) setState(() => _dimsLoaded = true);
    }
  }

  String _fmtSize(int b) {
    if (b < 1024) return '$b bytes';
    if (b < 1024 * 1024) {
      return '${(b / 1024).toStringAsFixed(1)} KB ($b bytes)';
    }
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB ($b bytes)';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB ($b bytes)';
  }

  String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  String _kind(String ext) {
    const map = {
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
    return map[ext] ?? (ext.isEmpty ? 'File' : '${ext.substring(1).toUpperCase()} file');
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final f = widget.file;
    final ext = f.extension;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 80),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.divider),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 30,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        CupertinoIcons.info_circle_fill,
                        size: 20,
                        color: palette.subtleText,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Info',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: palette.text,
                          ),
                        ),
                      ),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: Icon(
                          CupertinoIcons.xmark_circle_fill,
                          size: 22,
                          color: palette.subtleText,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SelectionArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _row('Name', f.name, palette),
                        _row('Kind', _kind(ext), palette),
                        _row('Size', _fmtSize(f.size), palette),
                        _row('Modified', _fmtDate(f.modified), palette),
                        _row('Path', f.path, palette),
                        if (f.isImage)
                          _row(
                            'Dimensions',
                            _dimsLoaded
                                ? (_imageDims == null
                                    ? 'unknown'
                                    : '${_imageDims!.width.round()} × '
                                        '${_imageDims!.height.round()} px')
                                : 'reading…',
                            palette,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String k, String v, AppPalette palette) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              k,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: palette.subtleText,
              ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: TextStyle(fontSize: 12, color: palette.text),
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({
    required this.icon,
    required this.message,
    required this.palette,
  });
  final IconData icon;
  final String message;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: palette.subtleText),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: palette.subtleText,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
