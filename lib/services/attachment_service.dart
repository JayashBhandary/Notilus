import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/file_entry.dart';

enum AttachmentKind { text, image, unsupported }

class ChatAttachment {
  ChatAttachment({
    required this.kind,
    required this.name,
    this.text,
    this.imageBase64,
    this.notice,
  });

  /// What was extracted.
  final AttachmentKind kind;

  /// Original filename, for display + LLM prompt context.
  final String name;

  /// Extracted plain text (for text/PDF/Office/CSV/etc).
  final String? text;

  /// Base64-encoded raw bytes (for images sent to vision models).
  final String? imageBase64;

  /// Optional human-readable hint shown to the user (e.g. "needs vision model").
  final String? notice;
}

/// Converts a file into something Ollama can consume.
class AttachmentService {
  static const int _textReadCap = 200 * 1024; // 200KB
  static const int _imageByteCap = 6 * 1024 * 1024; // 6MB

  static const _imageExts = {
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp',
  };
  static const _textExts = {
    '.txt', '.md', '.markdown', '.mdown', '.log',
    '.json', '.yaml', '.yml', '.xml', '.csv', '.tsv',
    '.html', '.htm', '.css', '.scss', '.less',
    '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx',
    '.dart', '.py', '.rb', '.go', '.rs', '.c', '.cpp', '.cc', '.h', '.hpp',
    '.java', '.kt', '.swift', '.sh', '.bash', '.zsh', '.fish',
    '.toml', '.ini', '.conf', '.cfg', '.env',
    '.lua', '.pl', '.php', '.sql', '.r', '.scala', '.groovy',
    '.gradle', '.cmake', '.rtf',
  };
  static const _pdfExts = {'.pdf'};
  static const _officeTextExts = {'.docx', '.doc', '.odt'};
  static const _officeSheetExts = {'.xlsx', '.xls', '.ods'};
  static const _officeSlideExts = {'.pptx', '.ppt', '.odp'};

  Future<ChatAttachment> prepare(FileEntry file) async {
    final ext = file.extension;
    if (_imageExts.contains(ext)) {
      return _prepareImage(file);
    }
    if (_pdfExts.contains(ext)) {
      return _preparePdf(file);
    }
    if (_officeTextExts.contains(ext)) {
      return _prepareViaSoffice(file, 'txt');
    }
    if (_officeSheetExts.contains(ext)) {
      return _prepareViaSoffice(file, 'csv');
    }
    if (_officeSlideExts.contains(ext)) {
      // PowerPoint → PDF → text is more reliable than → txt.
      return _prepareSlide(file);
    }
    if (_textExts.contains(ext)) {
      return _prepareText(file);
    }
    return ChatAttachment(
      kind: AttachmentKind.unsupported,
      name: file.name,
      notice:
          'Unsupported attachment type "${ext.isEmpty ? '?' : ext}". Sent as filename only.',
    );
  }

  Future<ChatAttachment> _prepareImage(FileEntry file) async {
    final f = File(file.path);
    final size = await f.length();
    if (size > _imageByteCap) {
      return ChatAttachment(
        kind: AttachmentKind.unsupported,
        name: file.name,
        notice:
            'Image is ${(size / 1024 / 1024).toStringAsFixed(1)} MB — too large to attach (max 6 MB).',
      );
    }
    final bytes = await f.readAsBytes();
    return ChatAttachment(
      kind: AttachmentKind.image,
      name: file.name,
      imageBase64: base64Encode(bytes),
      notice:
          'Image attached. Use a vision-capable model (e.g. llava, llama3.2-vision, qwen2.5vl).',
    );
  }

  Future<ChatAttachment> _prepareText(FileEntry file) async {
    final f = File(file.path);
    if (!await f.exists()) {
      return ChatAttachment(
        kind: AttachmentKind.unsupported,
        name: file.name,
        notice: 'File not found.',
      );
    }
    final size = await f.length();
    String text;
    if (size <= _textReadCap) {
      text = await f.readAsString();
    } else {
      final raf = await f.open();
      try {
        final bytes = await raf.read(_textReadCap);
        text = '${String.fromCharCodes(bytes)}\n\n[truncated after '
            '${_textReadCap ~/ 1024} KB]';
      } finally {
        await raf.close();
      }
    }
    return ChatAttachment(
      kind: AttachmentKind.text,
      name: file.name,
      text: text,
    );
  }

  /// Try `pdftotext` first (poppler-utils); fall back to LibreOffice
  /// `--convert-to txt`. Returns unsupported with hint if neither exists.
  Future<ChatAttachment> _preparePdf(FileEntry file) async {
    // Path 1: pdftotext (poppler).
    try {
      final r = await Process.run('pdftotext', [
        '-layout',
        '-enc', 'UTF-8',
        file.path,
        '-', // stdout
      ]);
      if (r.exitCode == 0 && r.stdout is String) {
        final text = _capText(r.stdout as String);
        if (text.trim().isNotEmpty) {
          return ChatAttachment(
            kind: AttachmentKind.text,
            name: file.name,
            text: text,
          );
        }
      }
    } on ProcessException {
      // fall through
    } catch (_) {
      // fall through
    }

    // Path 2: LibreOffice convert-to txt.
    final soffice = await _findSoffice();
    if (soffice != null) {
      final tmp = await Directory.systemTemp.createTemp('notilus_attach_');
      try {
        final r = await Process.run(soffice, [
          '--headless',
          '--norestore',
          '--nologo',
          '--nofirststartwizard',
          '--convert-to', 'txt',
          '--outdir', tmp.path,
          file.path,
        ]);
        if (r.exitCode == 0) {
          final base = p.basenameWithoutExtension(file.path);
          final out = File(p.join(tmp.path, '$base.txt'));
          if (await out.exists()) {
            return ChatAttachment(
              kind: AttachmentKind.text,
              name: file.name,
              text: _capText(await out.readAsString()),
            );
          }
        }
      } catch (_) {
        // fall through
      } finally {
        unawaited(tmp.delete(recursive: true).catchError((_) => tmp));
      }
    }

    return ChatAttachment(
      kind: AttachmentKind.unsupported,
      name: file.name,
      notice: 'PDF text extraction needs poppler-utils (`pdftotext`) or '
          'LibreOffice installed.',
    );
  }

  Future<ChatAttachment> _prepareSlide(FileEntry file) async {
    final soffice = await _findSoffice();
    if (soffice == null) {
      return ChatAttachment(
        kind: AttachmentKind.unsupported,
        name: file.name,
        notice: 'Slide deck extraction needs LibreOffice installed.',
      );
    }
    final tmp = await Directory.systemTemp.createTemp('notilus_attach_');
    try {
      // Convert to PDF first.
      final r1 = await Process.run(soffice, [
        '--headless',
        '--norestore',
        '--nologo',
        '--nofirststartwizard',
        '--convert-to', 'pdf',
        '--outdir', tmp.path,
        file.path,
      ]);
      if (r1.exitCode != 0) {
        return ChatAttachment(
          kind: AttachmentKind.unsupported,
          name: file.name,
          notice: 'LibreOffice failed to convert the slide deck.',
        );
      }
      final base = p.basenameWithoutExtension(file.path);
      final pdf = File(p.join(tmp.path, '$base.pdf'));
      if (!await pdf.exists()) {
        return ChatAttachment(
          kind: AttachmentKind.unsupported,
          name: file.name,
          notice: 'LibreOffice did not produce a PDF.',
        );
      }
      // Then pdftotext for clean text.
      try {
        final r2 = await Process.run('pdftotext', [
          '-layout',
          '-enc', 'UTF-8',
          pdf.path,
          '-',
        ]);
        if (r2.exitCode == 0 && r2.stdout is String) {
          return ChatAttachment(
            kind: AttachmentKind.text,
            name: file.name,
            text: _capText(r2.stdout as String),
          );
        }
      } on ProcessException {
        // fall through
      } catch (_) {
        // fall through
      }
      return ChatAttachment(
        kind: AttachmentKind.unsupported,
        name: file.name,
        notice:
            'Converted slides to PDF but `pdftotext` is missing for text '
            'extraction. Install poppler-utils.',
      );
    } finally {
      unawaited(tmp.delete(recursive: true).catchError((_) => tmp));
    }
  }

  Future<ChatAttachment> _prepareViaSoffice(
    FileEntry file,
    String targetFormat,
  ) async {
    final soffice = await _findSoffice();
    if (soffice == null) {
      return ChatAttachment(
        kind: AttachmentKind.unsupported,
        name: file.name,
        notice: 'This format needs LibreOffice installed to extract text.',
      );
    }
    final tmp = await Directory.systemTemp.createTemp('notilus_attach_');
    try {
      final r = await Process.run(soffice, [
        '--headless',
        '--norestore',
        '--nologo',
        '--nofirststartwizard',
        '--convert-to', targetFormat,
        '--outdir', tmp.path,
        file.path,
      ]);
      if (r.exitCode != 0) {
        return ChatAttachment(
          kind: AttachmentKind.unsupported,
          name: file.name,
          notice: 'LibreOffice failed: '
              '${r.stderr is String && (r.stderr as String).isNotEmpty ? r.stderr : "exit ${r.exitCode}"}',
        );
      }
      final base = p.basenameWithoutExtension(file.path);
      final out = File(p.join(tmp.path, '$base.$targetFormat'));
      if (!await out.exists()) {
        return ChatAttachment(
          kind: AttachmentKind.unsupported,
          name: file.name,
          notice: 'LibreOffice produced no $targetFormat output.',
        );
      }
      return ChatAttachment(
        kind: AttachmentKind.text,
        name: file.name,
        text: _capText(await out.readAsString()),
      );
    } finally {
      unawaited(tmp.delete(recursive: true).catchError((_) => tmp));
    }
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

  String _capText(String text) {
    if (text.length <= _textReadCap) return text;
    return '${text.substring(0, _textReadCap)}\n\n[truncated after '
        '${_textReadCap ~/ 1024} KB]';
  }
}

