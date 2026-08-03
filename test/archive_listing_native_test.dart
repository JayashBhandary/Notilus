import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/services/native_core.dart';

import 'native_test_support.dart';

/// Verifies the archive preview actually reaches the Rust core.
///
/// The preview used to decode archives with the pure-Dart `package:archive`,
/// materialising the whole file in memory; the native implementation existed but
/// nothing called it. These tests pin the wiring — including the `BigInt` sizes
/// that come back across the FFI boundary, which the UI has to convert.
void main() {
  var native = false;

  setUpAll(() async {
    native = await NativeTestSupport.ensureLoaded();
  });

  group('NativeCore.listArchive', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('notilus_archive_test');
    });
    tearDown(() async => dir.delete(recursive: true));

    test('lists a gzip payload as a single entry', () async {
      if (!native) return markTestSkipped(NativeTestSupport.skipReason);
      // Built with dart:io's gzip so the fixture needs no archive package —
      // the very dependency this change removed.
      final payload = utf8.encode('the quick brown fox');
      final file = File('${dir.path}/notes.txt.gz');
      await file.writeAsBytes(gzip.encode(payload));

      final entries = await NativeCore.instance.listArchive(file.path);

      expect(entries, hasLength(1));
      // Rust reports the inner name (file stem), not the archive's own name.
      expect(entries.single.name, 'notes.txt');
      expect(entries.single.isDir, isFalse);
      // Size arrives as BigInt (u64) — the widget calls .toInt() on it.
      expect(entries.single.size.toInt(), payload.length);
    });

    test('reports a readable error for an unreadable file', () async {
      if (!native) return markTestSkipped(NativeTestSupport.skipReason);
      final missing = '${dir.path}/nope.zip';

      await expectLater(
        NativeCore.instance.listArchive(missing),
        throwsA(anything),
      );
    });

    test('lists a real multi-entry tar.gz', () async {
      if (!native) return markTestSkipped(NativeTestSupport.skipReason);
      // `tar` is present on macOS and Linux; skip elsewhere rather than vendor
      // a tar writer just for this.
      if (!Platform.isMacOS && !Platform.isLinux) return;

      await File('${dir.path}/a.txt').writeAsString('alpha');
      await File('${dir.path}/b.txt').writeAsString('bravo!!');
      final archive = '${dir.path}/bundle.tar.gz';
      final r = await Process.run(
        'tar',
        ['-czf', archive, '-C', dir.path, 'a.txt', 'b.txt'],
      );
      expect(r.exitCode, 0, reason: 'tar failed: ${r.stderr}');

      final entries = await NativeCore.instance.listArchive(archive);
      final byName = {for (final e in entries) e.name: e};

      expect(byName.keys, containsAll(['a.txt', 'b.txt']));
      expect(byName['a.txt']!.size.toInt(), 5);
      expect(byName['b.txt']!.size.toInt(), 7);
      // Rust sorts by name before returning, which the UI relies on.
      final names = [for (final e in entries) e.name];
      expect(names, orderedEquals([...names]..sort()));
    });
  });
}
