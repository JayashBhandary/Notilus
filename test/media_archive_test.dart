import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:notilus/services/media_archive_service.dart';

/// The Compress action behind the media pages' selection bar. The encode runs
/// in a background isolate, so these are real end-to-end zips rather than a
/// mocked encoder.
void main() {
  late Directory tmp;
  late Directory dest;
  const service = MediaArchiveService();

  File write(String relative, String contents) {
    final f = File(p.join(tmp.path, relative));
    f.parent.createSync(recursive: true);
    return f..writeAsStringSync(contents);
  }

  List<String> namesIn(String zipPath) {
    final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
    return archive.files.map((f) => f.name).toList()..sort();
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('notilus_archive_test');
    dest = Directory(p.join(tmp.path, 'Desktop'))..createSync();
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('writes a dated archive holding the selected files', () async {
    final a = write('a.txt', 'alpha');
    final b = write('b.txt', 'beta');

    final result = await service.compressToZip(
      paths: [a.path, b.path],
      destDir: dest.path,
      baseName: 'Images',
      stamp: DateTime(2026, 8, 7),
    );

    expect(result.wroteArchive, isTrue);
    expect(result.added, 2);
    expect(result.skipped, 0);
    expect(p.basename(result.zipPath), 'Images-2026-08-07.zip');
    expect(File(result.zipPath).existsSync(), isTrue);
    expect(namesIn(result.zipPath), ['a.txt', 'b.txt']);
  });

  test('round-trips contents intact', () async {
    final a = write('notes.txt', 'the quick brown fox');

    final result = await service.compressToZip(
      paths: [a.path],
      destDir: dest.path,
      baseName: 'Documents',
      stamp: DateTime(2026, 1, 9),
    );

    final archive =
        ZipDecoder().decodeBytes(File(result.zipPath).readAsBytesSync());
    final file = archive.files.single;
    expect(String.fromCharCodes(file.content as List<int>),
        'the quick brown fox');
  });

  test('same basename from two folders keeps both copies', () async {
    final one = write('trip/photo.txt', 'one');
    final two = write('work/photo.txt', 'two');

    final result = await service.compressToZip(
      paths: [one.path, two.path],
      destDir: dest.path,
      baseName: 'Images',
      stamp: DateTime(2026, 8, 7),
    );

    expect(result.added, 2);
    expect(namesIn(result.zipPath), ['photo (2).txt', 'photo.txt']);
  });

  test('never overwrites an existing archive', () async {
    final a = write('a.txt', 'alpha');
    final stamp = DateTime(2026, 8, 7);

    final first = await service.compressToZip(
      paths: [a.path],
      destDir: dest.path,
      baseName: 'Images',
      stamp: stamp,
    );
    final second = await service.compressToZip(
      paths: [a.path],
      destDir: dest.path,
      baseName: 'Images',
      stamp: stamp,
    );

    expect(p.basename(first.zipPath), 'Images-2026-08-07.zip');
    expect(p.basename(second.zipPath), 'Images-2026-08-07-2.zip');
    expect(File(first.zipPath).existsSync(), isTrue);
  });

  test('missing files are skipped, not fatal', () async {
    final a = write('a.txt', 'alpha');

    final result = await service.compressToZip(
      paths: [a.path, p.join(tmp.path, 'ghost.txt')],
      destDir: dest.path,
      baseName: 'Images',
      stamp: DateTime(2026, 8, 7),
    );

    expect(result.added, 1);
    expect(result.skipped, 1);
    expect(namesIn(result.zipPath), ['a.txt']);
  });

  test('a selection with nothing readable writes no archive at all', () async {
    final result = await service.compressToZip(
      paths: [p.join(tmp.path, 'ghost.txt')],
      destDir: dest.path,
      baseName: 'Images',
      stamp: DateTime(2026, 8, 7),
    );

    expect(result.wroteArchive, isFalse);
    expect(result.zipPath, isEmpty);
    expect(dest.listSync(), isEmpty);
  });

  test('creates the destination folder when it is missing', () async {
    final a = write('a.txt', 'alpha');
    final missing = p.join(tmp.path, 'not-there-yet');

    final result = await service.compressToZip(
      paths: [a.path],
      destDir: missing,
      baseName: 'Images',
      stamp: DateTime(2026, 8, 7),
    );

    expect(File(result.zipPath).existsSync(), isTrue);
    expect(p.dirname(result.zipPath), missing);
  });
}
