import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/utils/gzipped_bytes.dart';

void main() {
  group('maybeGunzip', () {
    final svg = utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"/>');

    test('inflates gzip-compressed bytes', () {
      final gzipped = Uint8List.fromList(gzip.encode(svg));
      // Sanity: the fixture really is gzip, or the test proves nothing.
      expect(gzipped[0], 0x1F);
      expect(gzipped[1], 0x8B);

      expect(maybeGunzip(gzipped), svg);
    });

    test('passes plain bytes through untouched', () {
      final plain = Uint8List.fromList(svg);
      expect(maybeGunzip(plain), svg);
    });

    test('detects by magic bytes, not by extension', () {
      // A .svg that is actually gzipped still has to render — detection can't
      // depend on the filename, which this helper never sees.
      expect(maybeGunzip(Uint8List.fromList(gzip.encode(svg))), svg);
    });

    test('falls back to the raw bytes on a corrupt gzip stream', () {
      // Correct magic, garbage payload. Note `gzip.decode` returns an empty
      // list here rather than throwing, so a naive try/catch would silently
      // yield zero bytes and render a blank frame.
      final corrupt = Uint8List.fromList([0x1F, 0x8B, 8, 0, 1, 2, 3, 4, 5, 6]);
      expect(gzip.decode(corrupt), isEmpty, reason: 'premise of this test');
      expect(maybeGunzip(corrupt), corrupt);
    });

    test('handles inputs too short to carry a magic number', () {
      expect(maybeGunzip(Uint8List.fromList([])), isEmpty);
      expect(maybeGunzip(Uint8List.fromList([0x1F])), [0x1F]);
    });
  });

  group('readMaybeGzipped', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('notilus_gzip_test');
    });
    tearDown(() async => dir.delete(recursive: true));

    test('reads and inflates an .svgz from disk', () async {
      final svg = utf8.encode('<svg/>');
      final file = File('${dir.path}/icon.svgz');
      await file.writeAsBytes(gzip.encode(svg));

      expect(await readMaybeGzipped(file.path), svg);
    });

    test('reads a plain .svg unchanged', () async {
      final svg = utf8.encode('<svg/>');
      final file = File('${dir.path}/icon.svg');
      await file.writeAsBytes(svg);

      expect(await readMaybeGzipped(file.path), svg);
    });
  });
}
