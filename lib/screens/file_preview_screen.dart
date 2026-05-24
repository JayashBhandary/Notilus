import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show SelectionArea;
import 'package:flutter/services.dart';
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
  };
  static const _textExts = {
    '.txt', '.md', '.json', '.yaml', '.yml', '.xml', '.csv', '.html', '.css',
    '.js', '.ts', '.tsx', '.jsx', '.dart', '.py', '.rb', '.go', '.rs', '.c',
    '.cpp', '.h', '.hpp', '.java', '.kt', '.swift', '.sh', '.toml', '.ini',
    '.conf', '.log',
  };
  static const _pdfExts = {'.pdf'};
  static const _videoExts = {'.mp4', '.mov', '.m4v', '.mkv', '.webm'};
  static const _audioExts = {'.mp3', '.wav', '.m4a', '.aac', '.flac', '.ogg'};

  @override
  Widget build(BuildContext context) {
    final ext = file.extension;
    if (_imageExts.contains(ext)) {
      return _ImageView(file: file);
    }
    if (_textExts.contains(ext)) {
      return _TextView(file: file);
    }
    if (_pdfExts.contains(ext)) {
      return _PdfView(file: file);
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
// Image — InteractiveViewer for pinch + drag.
// ──────────────────────────────────────────────────────────────────────────

class _ImageView extends StatelessWidget {
  const _ImageView({required this.file});
  final FileEntry file;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return ColoredBox(
      color: palette.scaffoldBg,
      child: InteractiveViewer(
        minScale: 1,
        maxScale: 5,
        child: Center(
          child: Image.file(
            File(file.path),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _ErrorBox(
              icon: CupertinoIcons.photo,
              message: 'Couldn\'t decode this image.',
              palette: palette,
            ),
          ),
        ),
      ),
    );
  }
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
// PDF via pdfx (PDFKit on iOS/macOS, PdfRenderer on Android, PDFium on others).
// ──────────────────────────────────────────────────────────────────────────

class _PdfView extends StatefulWidget {
  const _PdfView({required this.file});
  final FileEntry file;

  @override
  State<_PdfView> createState() => _PdfViewState();
}

class _PdfViewState extends State<_PdfView> {
  late final PdfControllerPinch _controller;

  @override
  void initState() {
    super.initState();
    _controller = PdfControllerPinch(
      document: PdfDocument.openFile(widget.file.path),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return PdfViewPinch(
      controller: _controller,
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
    if (widget.isActive && !c.value.isPlaying) {
      // Don't auto-play on first activation; let the user press play.
    } else if (!widget.isActive && c.value.isPlaying) {
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
            if (!kIsWeb && (Platform.isMacOS || Platform.isWindows)) ...[
              const SizedBox(height: 14),
              Text(
                p.dirname(file.path),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: palette.subtleText,
                ),
              ),
            ],
          ],
        ),
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
