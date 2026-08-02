import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/models/file_entry.dart';
import 'package:notilus/services/duplicate_finder_service.dart';
import 'package:path/path.dart' as p;

import 'native_test_support.dart';

void main() {
  late Directory root;
  // The scan itself now runs in the Rust core, so these exercise the real
  // native pipeline rather than a Dart reimplementation of it.
  late bool native;

  setUpAll(() async {
    native = await NativeTestSupport.ensureLoaded();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dupfinder_test_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> write(String relPath, String content) async {
    final f = File(p.join(root.path, relPath));
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    return f;
  }

  test('finds byte-identical files with different names', () async {
    if (!native) return markTestSkipped(NativeTestSupport.skipReason);
    await write('a.txt', 'hello world duplicate content');
    await write('sub/b.txt', 'hello world duplicate content');
    await write('unique.txt', 'i am one of a kind');

    final groups = await DuplicateFinderService().scan(roots: [root.path]);

    expect(groups, hasLength(1));
    expect(groups.first.files, hasLength(2));
    expect(groups.first.reclaimableBytes, groups.first.size);
  });

  test('skips excluded directories by name', () async {
    if (!native) return markTestSkipped(NativeTestSupport.skipReason);
    await write('keep/a.bin', 'shared payload xyz');
    await write('node_modules/b.bin', 'shared payload xyz');

    final groups = await DuplicateFinderService().scan(
      roots: [root.path],
      excludedDirNames: DuplicateFinderService.defaultExcludedDirs,
    );

    // The node_modules copy is skipped, so no duplicate remains.
    expect(groups, isEmpty);
  });

  test('honors the file-type (extension) filter', () async {
    if (!native) return markTestSkipped(NativeTestSupport.skipReason);
    await write('one.png', 'PNGDATA-identical');
    await write('two.png', 'PNGDATA-identical');
    await write('one.txt', 'TXT-identical');
    await write('two.txt', 'TXT-identical');

    final groups = await DuplicateFinderService().scan(
      roots: [root.path],
      allowedExtensions: {'.png'},
    );

    expect(groups, hasLength(1));
    expect(
      groups.first.files.every((f) => f.path.endsWith('.png')),
      isTrue,
    );
  });

  test('does not descend into macOS .app bundles when skipBundles is on',
      () async {
    if (!native) return markTestSkipped(NativeTestSupport.skipReason);
    await write('Real.txt', 'bundle-dupe-body');
    await write('Foo.app/Contents/Real.txt', 'bundle-dupe-body');

    final withBundles =
        await DuplicateFinderService().scan(roots: [root.path]);
    expect(withBundles, isEmpty, reason: 'bundle contents ignored by default');

    final scanned = await DuplicateFinderService()
        .scan(roots: [root.path], skipBundles: false);
    expect(scanned, hasLength(1),
        reason: 'bundle contents included when skipBundles is off');
  });

  test('DuplicateGroup survives a JSON round-trip', () {
    final group = DuplicateGroup(
      hash: 'abc123',
      size: 4096,
      files: [
        FileEntry(
          path: '/tmp/a.bin',
          name: 'a.bin',
          isDirectory: false,
          size: 4096,
          modified: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
        FileEntry(
          path: '/tmp/b.bin',
          name: 'b.bin',
          isDirectory: false,
          size: 4096,
          modified: DateTime.fromMillisecondsSinceEpoch(1700000001000),
        ),
      ],
    );

    final restored = DuplicateGroup.fromJson(group.toJson());

    expect(restored.hash, group.hash);
    expect(restored.size, group.size);
    expect(restored.files.map((f) => f.path), group.files.map((f) => f.path));
    expect(restored.files.first.modified, group.files.first.modified);
    expect(restored.reclaimableBytes, group.reclaimableBytes);
  });
}
