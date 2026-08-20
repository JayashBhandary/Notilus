import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:notilus/models/file_entry.dart';
import 'package:notilus/models/remote/remote_connection.dart';
import 'package:notilus/services/remote/remote_file_system.dart';
import 'package:notilus/services/remote/remote_hub.dart';
import 'package:notilus/services/remote/remote_path.dart';
import 'package:notilus/services/text_document_service.dart';

/// An in-memory source, so the editor's remote path is exercised without a
/// network. Only what the editor touches is implemented.
class _MemoryRemote extends RemoteFileSystem {
  _MemoryRemote(super.connectionId);

  final Map<String, List<int>> files = {};
  final Map<String, DateTime> modified = {};

  @override
  Future<void> connect() async {}

  @override
  Future<List<RemoteEntry>> list(String vpath) async => const [];

  @override
  Future<RemoteEntry?> stat(String vpath) async {
    final bytes = files[vpath];
    if (bytes == null) return null;
    return RemoteEntry(
      path: vpath,
      name: VPath.basename(vpath),
      isDirectory: false,
      size: bytes.length,
      modified: modified[vpath] ?? DateTime.utc(2024),
    );
  }

  @override
  Future<RemoteDownload> download(String vpath) async {
    final bytes = files[vpath];
    if (bytes == null) throw RemoteException('gone', statusCode: 404);
    return RemoteDownload(stream: Stream.value(bytes), length: bytes.length);
  }

  @override
  Future<void> upload({
    required String vpath,
    required Stream<List<int>> data,
    required int length,
  }) async {
    final bytes = <int>[];
    await for (final chunk in data) {
      bytes.addAll(chunk);
    }
    files[vpath] = bytes;
    modified[vpath] = DateTime.utc(2025);
  }

  @override
  Future<void> createDirectory(String vpath) async {}

  @override
  Future<void> delete(String vpath, {required bool isDirectory}) async {}

  @override
  Future<String> rename(String vpath, String newName) async => vpath;
}

void main() {
  const service = TextDocumentService();
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('notilus-editor');
  });

  tearDown(() {
    RemoteHub.instance.resetForTesting();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File write(String name, List<int> bytes) {
    final file = File(p.join(temp.path, name));
    file.writeAsBytesSync(bytes);
    return file;
  }

  group('what can be edited', () {
    test('recognises source, config and extension-less convention files', () {
      for (final name in [
        'notes.txt', 'main.dart', 'nginx.conf', 'docker-compose.yml',
        'Makefile', 'Dockerfile', '.env', '.gitignore', 'authorized_keys',
        'README',
      ]) {
        expect(TextDocumentService.looksEditable(name), isTrue, reason: name);
      }
    });

    test('leaves binaries and media alone', () {
      for (final name in [
        'photo.jpg', 'clip.mp4', 'archive.zip', 'report.pdf', 'app.exe',
        'library.so', 'sheet.xlsx',
      ]) {
        expect(TextDocumentService.looksEditable(name), isFalse, reason: name);
      }
    });

    test('a folder is never editable, whatever it is called', () {
      final folder = FileEntry(
        path: '/tmp/notes.txt',
        name: 'notes.txt',
        isDirectory: true,
        size: 0,
        modified: DateTime.utc(2024),
      );
      expect(TextDocumentService.canEdit(folder), isFalse);
    });
  });

  group('loading', () {
    test('reads a plain file and reports its shape', () async {
      final file = write('a.txt', utf8.encode('hello\nworld\n'));

      final document = await service.load(file.path);

      expect(document.text, 'hello\nworld\n');
      expect(document.lineEnding, LineEnding.lf);
      expect(document.hasBom, isFalse);
      expect(document.stamp.isUsable, isTrue);
    });

    test('normalises CRLF for editing and remembers it for saving', () async {
      final file = write('win.txt', utf8.encode('one\r\ntwo\r\n'));

      final document = await service.load(file.path);

      // The editor never sees a \r; a text field can't produce one anyway.
      expect(document.text, 'one\ntwo\n');
      expect(document.lineEnding, LineEnding.crlf);
    });

    test('keeps a byte-order mark out of the text but records it', () async {
      final file = write('bom.txt', [0xEF, 0xBB, 0xBF, ...utf8.encode('hi')]);

      final document = await service.load(file.path);

      expect(document.text, 'hi');
      expect(document.hasBom, isTrue);
    });

    test('refuses a binary file instead of mangling it', () async {
      final file = write('blob.txt', [0x89, 0x50, 0x00, 0x4E, 0x47]);

      expect(
        () => service.load(file.path),
        throwsA(isA<TextEditException>()
            .having((e) => e.message, 'message', contains('binary'))),
      );
    });

    test('refuses text that is not UTF-8', () async {
      // A lone 0xFF can't start a UTF-8 sequence.
      final file = write('latin.txt', [0x68, 0x69, 0xFF, 0x21]);

      expect(
        () => service.load(file.path),
        throwsA(isA<TextEditException>()
            .having((e) => e.message, 'message', contains('UTF-8'))),
      );
    });

    test('refuses a file too large to edit by hand', () async {
      final file = write(
        'huge.log',
        Uint8List(TextDocumentService.maxEditableBytes + 1)..fillRange(0, 1, 65),
      );

      expect(
        () => service.load(file.path),
        throwsA(isA<TextEditException>()
            .having((e) => e.message, 'message', contains('MB'))),
      );
    });
  });

  group('saving locally', () {
    test('writes the edit back and returns a fresh stamp', () async {
      final file = write('a.txt', utf8.encode('before'));
      final document = await service.load(file.path);

      final stamp = await service.save(document, 'after');

      expect(file.readAsStringSync(), 'after');
      expect(stamp.size, 'after'.length);
    });

    test('a CRLF file stays CRLF', () async {
      final file = write('win.txt', utf8.encode('one\r\ntwo\r\n'));
      final document = await service.load(file.path);

      await service.save(document, 'one\ntwo\nthree\n');

      expect(file.readAsStringSync(), 'one\r\ntwo\r\nthree\r\n');
    });

    test('a BOM survives a round trip', () async {
      final file = write('bom.txt', [0xEF, 0xBB, 0xBF, ...utf8.encode('hi')]);
      final document = await service.load(file.path);

      await service.save(document, 'hi there');

      final bytes = file.readAsBytesSync();
      expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      expect(utf8.decode(bytes.sublist(3)), 'hi there');
    });

    test('writing in place keeps the file identity', () async {
      final file = write('kept.txt', utf8.encode('one'));
      final link = Link(p.join(temp.path, 'link.txt'))..createSync(file.path);
      final document = await service.load(link.path);

      await service.save(document, 'two');

      // A temp-file-and-rename save would have replaced the symlink with a
      // regular file and left the target untouched.
      expect(link.targetSync(), file.path);
      expect(file.readAsStringSync(), 'two');
    }, skip: Platform.isWindows ? 'symlinks need privileges on Windows' : null);

    test('refuses to clobber a file that changed underneath, unless forced',
        () async {
      final file = write('shared.txt', utf8.encode('mine'));
      final document = await service.load(file.path);

      // Somebody else writes to it — a different length and a later mtime.
      file.writeAsStringSync('theirs, longer');
      file.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));

      await expectLater(
        service.save(document, 'my edit'),
        throwsA(isA<TextConflictException>()),
      );
      expect(file.readAsStringSync(), 'theirs, longer');

      await service.save(document, 'my edit', force: true);
      expect(file.readAsStringSync(), 'my edit');
    });
  });

  group('saving to a remote source', () {
    const connectionId = 'mem';
    final path = VPath.build(connectionId, '/etc/app.conf');
    late _MemoryRemote remote;

    setUp(() {
      remote = _MemoryRemote(connectionId);
      RemoteHub.instance.resetForTesting();
      RemoteHub.instance.mountForTesting(
        const RemoteConnection(
          id: connectionId,
          kind: RemoteKind.sftp,
          label: 'Server',
        ),
        remote,
      );
    });

    test('loads over the provider and writes straight back to it', () async {
      remote.files[path] = utf8.encode('listen 80;\n');

      final document = await service.load(path);
      expect(document.text, 'listen 80;\n');
      expect(document.isRemote, isTrue);

      await service.save(document, 'listen 443;\n');

      expect(utf8.decode(remote.files[path]!), 'listen 443;\n');
    });

    test('a remote file changed by someone else is caught too', () async {
      remote.files[path] = utf8.encode('a');
      final document = await service.load(path);

      remote.files[path] = utf8.encode('changed elsewhere');
      remote.modified[path] = DateTime.utc(2030);

      await expectLater(
        service.save(document, 'b'),
        throwsA(isA<TextConflictException>()),
      );
    });

    test('a source that reports nothing useful skips the conflict check',
        () async {
      remote.files[path] = utf8.encode('a');
      final document = TextDocument(
        path: path,
        text: 'a',
        // What an S3 key looks like: listed, but with no dependable stamp.
        stamp: const TextStamp.unknown(),
        lineEnding: LineEnding.lf,
        hasBom: false,
      );

      await service.save(document, 'b');

      expect(utf8.decode(remote.files[path]!), 'b');
    });
  });
}
