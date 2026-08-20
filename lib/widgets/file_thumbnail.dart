import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/file_entry.dart';
import '../services/remote/remote_path.dart';
import '../models/media_kind.dart';
import '../services/thumbnail_service.dart';

// ──────────────────────────────────────────────────────────────────────────
// One answer to "what can this file be shown as?"
//
// The icon grid and the info panel draw previews very differently — the grid
// speaks Cupertino at 44px, the panel speaks Lucide at 300 — but they must
// agree on *which* files get a preview at all, or the same document is a
// thumbnail in one pane and a grey glyph in the other. So the routing lives
// here once and each surface renders the result in its own idiom.
// ──────────────────────────────────────────────────────────────────────────

/// Vector images, which need a renderer rather than the image codec.
const Set<String> kSvgExtensions = {'.svg', '.svgz'};

/// Files worth showing the first few lines of.
///
/// Wider than [ThumbnailService]'s own list because a folder of source code is
/// exactly where a miniature earns its keep — telling `main.dart` from
/// `theme.dart` at a glance is the whole point.
const Set<String> kTextPreviewExtensions = {
  '.txt', '.md', '.markdown', '.mdown', '.log', '.rtf',
  '.json', '.yaml', '.yml', '.xml', '.csv', '.tsv',
  '.html', '.htm', '.css', '.scss', '.less',
  '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx',
  '.dart', '.py', '.rb', '.go', '.rs', '.c', '.cpp', '.cc', '.h', '.hpp',
  '.java', '.kt', '.swift', '.sh', '.bash', '.zsh', '.fish',
  '.toml', '.ini', '.conf', '.cfg', '.env',
  '.lua', '.pl', '.php', '.sql', '.r', '.scala', '.groovy',
  '.gradle', '.cmake',
};

/// What a file turned out to be previewable as.
sealed class FilePreview {
  const FilePreview();
}

/// A decodable image on disk: either the file itself, or the PNG that
/// [ThumbnailService] generated and cached for it.
class FilePreviewImage extends FilePreview {
  const FilePreviewImage(this.file, {this.isPaper = false});

  final File file;

  /// A rendered document page. Its margins are transparent, so it needs white
  /// behind it or a dark theme shows through the paper.
  final bool isPaper;
}

class FilePreviewSvg extends FilePreview {
  const FilePreviewSvg(this.bytes);
  final Uint8List bytes;
}

class FilePreviewText extends FilePreview {
  const FilePreviewText(this.snippet);
  final String snippet;
}

/// Nothing better than an icon — either the format has no preview or this
/// machine has no renderer for it.
class FilePreviewNone extends FilePreview {
  const FilePreviewNone();
}

/// Whether [entry] is a video, so a surface can mark it playable even when the
/// frame never arrives.
bool isPreviewableVideo(FileEntry entry) =>
    ThumbnailService.instance.isVideo(entry);

/// Whether [entry] is an office document or ebook carrying its own cover.
bool hasEmbeddedDocumentPreview(FileEntry entry) =>
    ThumbnailService.instance.hasEmbeddedPreview(entry);

/// Whether [entry] is audio. There is no cover-art extraction yet, so this
/// only picks a glyph.
bool isAudioFile(FileEntry entry) =>
    kAudioExtensions.contains(entry.extension);

/// Whether [entry] can show anything at all beyond a glyph. Cheap and
/// synchronous — extension checks only, no I/O.
bool hasFilePreview(FileEntry entry) {
  if (entry.isDirectory) return false;
  final ext = entry.extension;
  final service = ThumbnailService.instance;
  return kImageExtensions.contains(ext) ||
      kSvgExtensions.contains(ext) ||
      ext == '.pdf' ||
      service.isVideo(entry) ||
      service.hasEmbeddedPreview(entry) ||
      kTextPreviewExtensions.contains(ext);
}

/// Resolves the best preview for [entry] and hands it to [builder].
///
/// [builder] is called with [FilePreviewNone] while generation is still in
/// flight, so a surface's glyph doubles as its loading state — a grid that
/// filled with spinners resolving to nothing was worse than one that simply
/// sharpened as previews landed.
class FilePreviewBuilder extends StatefulWidget {
  const FilePreviewBuilder({
    super.key,
    required this.entry,
    required this.dim,
    required this.builder,
  });

  final FileEntry entry;

  /// Pixel width to generate at. Part of the cache key, so surfaces that pass
  /// the same value share generated files instead of re-running ffmpeg.
  final int dim;

  final Widget Function(BuildContext context, FilePreview preview) builder;

  @override
  State<FilePreviewBuilder> createState() => _FilePreviewBuilderState();
}

class _FilePreviewBuilderState extends State<FilePreviewBuilder> {
  Future<FilePreview>? _future;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant FilePreviewBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Tiles are recycled as a listing scrolls and as the sort order changes,
    // and the info panel keeps one widget across selections.
    if (oldWidget.entry.path != widget.entry.path ||
        oldWidget.dim != widget.dim) {
      _start();
    }
  }

  void _start() {
    _future = _immediate(widget.entry) == null ? _load() : null;
  }

  /// The preview that needs no work at all.
  ///
  /// Deferring this to a future would cost a frame of placeholder before every
  /// image — visible as a flicker when clicking through a folder of photos —
  /// for a file the image codec can open directly.
  FilePreview? _immediate(FileEntry entry) {
    if (entry.isDirectory) return const FilePreviewNone();
    // Cloud items get their type icon rather than a thumbnail. Rendering one
    // means downloading the file, and a folder of photos on S3 would quietly
    // pull every megabyte of it just by being scrolled past; the preview
    // window downloads on demand instead, when the user asks for that file.
    if (VPath.isRemote(entry.path)) return const FilePreviewNone();
    final ext = entry.extension;
    if (kImageExtensions.contains(ext) && !kSvgExtensions.contains(ext)) {
      return FilePreviewImage(File(entry.path));
    }
    if (!hasFilePreview(entry)) return const FilePreviewNone();
    return null;
  }

  Future<FilePreview> _load() async {
    final entry = widget.entry;
    final service = ThumbnailService.instance;
    final ext = entry.extension;

    if (kSvgExtensions.contains(ext)) {
      final bytes = await _svgBytes(entry);
      return bytes == null ? const FilePreviewNone() : FilePreviewSvg(bytes);
    }
    if (ext == '.pdf') {
      final f = await service.pdfThumbnail(entry, dim: widget.dim);
      return f == null
          ? const FilePreviewNone()
          : FilePreviewImage(f, isPaper: true);
    }
    if (service.isVideo(entry)) {
      final f = await service.videoThumbnail(entry, dim: widget.dim);
      return f == null ? const FilePreviewNone() : FilePreviewImage(f);
    }
    if (service.hasEmbeddedPreview(entry)) {
      final f = await service.embeddedThumbnail(entry, dim: widget.dim);
      return f == null ? const FilePreviewNone() : FilePreviewImage(f);
    }
    if (kTextPreviewExtensions.contains(ext)) {
      final text = await service.textSnippet(entry);
      return text == null || text.trim().isEmpty
          ? const FilePreviewNone()
          : FilePreviewText(text);
    }
    return const FilePreviewNone();
  }

  Future<Uint8List?> _svgBytes(FileEntry entry) async {
    try {
      final raw = await File(entry.path).readAsBytes();
      // .svgz is gzipped SVG, and so is the occasional .svg served that way.
      if (raw.length >= 2 && raw[0] == 0x1F && raw[1] == 0x8B) {
        try {
          return Uint8List.fromList(gzip.decode(raw));
        } catch (_) {
          return raw;
        }
      }
      return raw;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final immediate = _immediate(widget.entry);
    if (immediate != null) return widget.builder(context, immediate);
    return FutureBuilder<FilePreview>(
      future: _future,
      builder: (context, snap) =>
          widget.builder(context, snap.data ?? const FilePreviewNone()),
    );
  }
}
