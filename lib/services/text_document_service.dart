import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/file_entry.dart';
import 'remote/remote_file_system.dart';
import 'remote/remote_hub.dart';
import 'remote/remote_path.dart';

/// Why a file can't be opened in the editor. Messages are written to be shown
/// to the user unchanged.
class TextEditException implements Exception {
  TextEditException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Raised when the file changed underneath the editor between opening it and
/// saving. The UI turns this into an overwrite-or-cancel question rather than
/// silently winning the race.
class TextConflictException implements Exception {
  TextConflictException(this.detail);

  final String detail;

  @override
  String toString() => detail;
}

/// The line ending a file uses, preserved across a save.
///
/// Rewriting a Windows file with LF endings would turn a one-line edit into a
/// whole-file diff — the kind of thing that gets noticed in a code review of
/// someone else's commit, not in the editor that did it.
enum LineEnding {
  lf('\n', 'LF'),
  crlf('\r\n', 'CRLF');

  const LineEnding(this.sequence, this.label);

  final String sequence;
  final String label;
}

/// What the file looked like when it was read, so a save can tell whether
/// anything else has touched it since.
class TextStamp {
  const TextStamp({required this.size, required this.modifiedMs});

  const TextStamp.unknown()
      : size = -1,
        modifiedMs = -1;

  final int size;
  final int modifiedMs;

  /// Some providers can't report either value — S3 gives no useful mtime for a
  /// key it has only listed. An unusable stamp means the conflict check is
  /// skipped rather than guessed at.
  bool get isUsable => size >= 0;

  bool matches(TextStamp other) {
    if (!isUsable || !other.isUsable) return true;
    // Modification time alone is too coarse on filesystems with one-second
    // resolution; size alone misses same-length edits. Both together catch
    // everything a text editor realistically does.
    return size == other.size && modifiedMs == other.modifiedMs;
  }
}

/// A text file loaded for editing, with everything needed to write it back the
/// way it came.
class TextDocument {
  const TextDocument({
    required this.path,
    required this.text,
    required this.stamp,
    required this.lineEnding,
    required this.hasBom,
  });

  final String path;

  /// Contents with line endings normalised to `\n`, which is what a Flutter
  /// text field produces. [TextDocumentService.save] puts them back.
  final String text;
  final TextStamp stamp;
  final LineEnding lineEnding;

  /// Whether the file began with a UTF-8 byte-order mark. Windows tooling
  /// writes them and notices when they disappear.
  final bool hasBom;

  bool get isRemote => VPath.isRemote(path);
  String get name => VPath.basename(path);
}

/// Reads and writes text files, wherever they live.
///
/// The editor is deliberately built on this rather than on the
/// download-to-cache path the preview uses: editing a cached copy and pushing
/// it back leaves two files that can disagree. Here the bytes are read once,
/// held in the editor, and written straight back to the source.
class TextDocumentService {
  const TextDocumentService();

  /// Above this the editor declines. A file this size is not being edited by
  /// hand, and holding it as a `String` in a text field would make the UI
  /// unusable long before it ran out of memory.
  static const int maxEditableBytes = 5 * 1024 * 1024;

  /// Extension-less files that are text by convention. Without these, editing
  /// a `Dockerfile` or a `Makefile` — exactly the files people edit on a
  /// server — would be refused.
  static const Set<String> _knownNames = {
    'makefile', 'dockerfile', 'containerfile', 'jenkinsfile', 'vagrantfile',
    'procfile', 'brewfile', 'gemfile', 'rakefile', 'license', 'licence',
    'readme', 'changelog', 'authors', 'contributing', 'notice', 'todo',
    'codeowners', '.gitignore', '.gitattributes', '.dockerignore', '.env',
    '.editorconfig', '.bashrc', '.zshrc', '.profile', '.bash_profile',
    '.vimrc', '.gitconfig', '.npmrc', '.curlrc', 'authorized_keys',
    'known_hosts', 'hosts', 'crontab', 'fstab', 'sshd_config', 'ssh_config',
  };

  static const Set<String> _editableExtensions = {
    '.txt', '.md', '.markdown', '.mdown', '.rst', '.log', '.text',
    '.json', '.jsonc', '.json5', '.yaml', '.yml', '.xml', '.csv', '.tsv',
    '.html', '.htm', '.css', '.scss', '.sass', '.less', '.svg',
    '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx', '.vue', '.svelte',
    '.dart', '.py', '.rb', '.go', '.rs', '.c', '.cpp', '.cc', '.cxx',
    '.h', '.hpp', '.hh', '.java', '.kt', '.kts', '.swift', '.m', '.mm',
    '.sh', '.bash', '.zsh', '.fish', '.ps1', '.bat', '.cmd',
    '.toml', '.ini', '.conf', '.cfg', '.properties', '.env', '.editorconfig',
    '.lua', '.pl', '.pm', '.php', '.sql', '.r', '.scala', '.groovy', '.ex',
    '.exs', '.erl', '.hs', '.clj', '.lisp', '.el', '.vim', '.zig', '.nim',
    '.gradle', '.cmake', '.mk', '.make', '.dockerfile', '.gitignore',
    '.patch', '.diff', '.srt', '.vtt', '.tex', '.bib', '.graphql', '.proto',
  };

  /// Whether the editor should be offered for [name]. Directories are the
  /// caller's business to exclude.
  static bool looksEditable(String name) {
    final lower = name.toLowerCase();
    if (_knownNames.contains(lower)) return true;
    final ext = p.extension(lower);
    if (ext.isEmpty) return false;
    return _editableExtensions.contains(ext);
  }

  static bool canEdit(FileEntry entry) =>
      !entry.isDirectory && looksEditable(entry.name);

  // ── loading ──────────────────────────────────────────────────────────────

  Future<TextDocument> load(String path) async {
    final bytes = VPath.isRemote(path)
        ? await _readRemote(path)
        : await _readLocal(path);
    return _decode(path, bytes, await stampOf(path));
  }

  Future<Uint8List> _readLocal(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw TextEditException('"${p.basename(path)}" isn\'t there any more.');
    }
    final length = await file.length();
    if (length > maxEditableBytes) throw _tooBig(p.basename(path), length);
    try {
      return await file.readAsBytes();
    } on FileSystemException catch (e) {
      throw TextEditException(
        'Couldn\'t read "${p.basename(path)}": ${e.osError?.message ?? e.message}',
      );
    }
  }

  Future<Uint8List> _readRemote(String path) async {
    final fs = await _fsFor(path);
    final RemoteDownload download;
    try {
      download = await fs.download(path);
    } on RemoteException catch (e) {
      throw TextEditException(e.message);
    }
    if (download.length > maxEditableBytes) {
      throw _tooBig(VPath.basename(path), download.length);
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in download.stream) {
      builder.add(chunk);
      // A server that under-reports its length — or doesn't report one — can't
      // be allowed to fill memory.
      if (builder.length > maxEditableBytes) {
        throw _tooBig(VPath.basename(path), builder.length);
      }
    }
    return builder.takeBytes();
  }

  TextEditException _tooBig(String name, int size) => TextEditException(
        '"$name" is ${(size / (1024 * 1024)).toStringAsFixed(1)} MB. '
        'The editor opens files up to '
        '${maxEditableBytes ~/ (1024 * 1024)} MB.',
      );

  TextDocument _decode(String path, Uint8List bytes, TextStamp stamp) {
    // A NUL byte is the oldest and most reliable "this is not text" signal,
    // and it is what stops the editor from turning a binary into a corrupted
    // binary the moment someone saves.
    if (bytes.contains(0)) {
      throw TextEditException(
        '"${VPath.basename(path)}" looks like a binary file, not text.',
      );
    }

    var content = bytes;
    var hasBom = false;
    if (content.length >= 3 &&
        content[0] == 0xEF &&
        content[1] == 0xBB &&
        content[2] == 0xBF) {
      hasBom = true;
      content = Uint8List.sublistView(content, 3);
    }

    final String text;
    try {
      text = utf8.decode(content);
    } on FormatException {
      throw TextEditException(
        '"${VPath.basename(path)}" isn\'t UTF-8 text. Editing it here would '
        'change bytes that aren\'t meant to change.',
      );
    }

    // CRLF wins only if the file is actually CRLF-terminated; a stray \r\n in
    // an otherwise LF file shouldn't convert the whole thing on save.
    final crlfCount = '\r\n'.allMatches(text).length;
    final lfCount = '\n'.allMatches(text).length;
    final ending = crlfCount > 0 && crlfCount >= lfCount - crlfCount
        ? LineEnding.crlf
        : LineEnding.lf;

    return TextDocument(
      path: path,
      text: text.replaceAll('\r\n', '\n'),
      stamp: stamp,
      lineEnding: ending,
      hasBom: hasBom,
    );
  }

  // ── saving ───────────────────────────────────────────────────────────────

  /// Writes [text] back to [document]'s path and returns the new stamp.
  ///
  /// Throws [TextConflictException] when something else changed the file since
  /// it was read, unless [force] is set.
  Future<TextStamp> save(
    TextDocument document,
    String text, {
    bool force = false,
  }) async {
    if (!force && document.stamp.isUsable) {
      final current = await stampOf(document.path);
      if (current.isUsable && !document.stamp.matches(current)) {
        throw TextConflictException(
          '"${document.name}" has changed since you opened it.',
        );
      }
    }

    final restored = document.lineEnding == LineEnding.crlf
        ? text.replaceAll('\n', '\r\n')
        : text;
    final body = utf8.encode(restored);
    final bytes = document.hasBom
        ? (BytesBuilder(copy: false)
              ..add(const [0xEF, 0xBB, 0xBF])
              ..add(body))
            .takeBytes()
        : Uint8List.fromList(body);

    if (document.isRemote) {
      await _writeRemote(document.path, bytes);
    } else {
      await _writeLocal(document.path, bytes);
    }
    return stampOf(document.path);
  }

  /// Written in place rather than through a temporary file and a rename.
  ///
  /// A rename would replace the inode, which quietly drops the file's
  /// permissions, its owner, any hard links to it, and — if the path is a
  /// symlink — the link itself, replacing it with a regular file. For a
  /// manager that people will point at `~/.ssh/config` and `/etc`-style files,
  /// keeping the file identity intact matters more than surviving a crash
  /// during a sub-millisecond write.
  Future<void> _writeLocal(String path, Uint8List bytes) async {
    try {
      await File(path).writeAsBytes(bytes, flush: true);
    } on FileSystemException catch (e) {
      throw TextEditException(
        'Couldn\'t save "${p.basename(path)}": ${e.osError?.message ?? e.message}',
      );
    }
  }

  Future<void> _writeRemote(String path, Uint8List bytes) async {
    final fs = await _fsFor(path);
    try {
      await fs.upload(
        vpath: path,
        data: Stream.value(bytes),
        length: bytes.length,
      );
    } on RemoteException catch (e) {
      throw TextEditException(e.message);
    }
  }

  // ── stamps ───────────────────────────────────────────────────────────────

  Future<TextStamp> stampOf(String path) async {
    if (VPath.isRemote(path)) {
      try {
        final fs = await _fsFor(path);
        final entry = await fs.stat(path);
        if (entry == null) return const TextStamp.unknown();
        return TextStamp(
          size: entry.size,
          modifiedMs: entry.modified.millisecondsSinceEpoch,
        );
      } catch (_) {
        return const TextStamp.unknown();
      }
    }
    try {
      final stat = await File(path).stat();
      if (stat.type == FileSystemEntityType.notFound) {
        return const TextStamp.unknown();
      }
      return TextStamp(
        size: stat.size,
        modifiedMs: stat.modified.millisecondsSinceEpoch,
      );
    } catch (_) {
      return const TextStamp.unknown();
    }
  }

  Future<RemoteFileSystem> _fsFor(String path) async {
    final id = VPath.connectionOf(path);
    if (id == null) {
      throw TextEditException('That file isn\'t on a remote source.');
    }
    try {
      return await RemoteHub.instance.fsFor(id);
    } on RemoteException catch (e) {
      throw TextEditException(e.message);
    }
  }
}
