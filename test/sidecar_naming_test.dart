import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/services/thumbnails/sidecar_naming.dart';

void main() {
  group('the hash agrees with the Rust side', () {
    test('the published FNV-1a vectors come out right', () {
      // The same two assertions live in
      // `core/src/api/thumbnail.rs::the_hash_matches_the_published_vector`.
      // If either side drifts, a thumbnail written by one is invisible to the
      // other and every folder silently re-renders.
      expect(fnv1aHex('abc'), 'e71fa2190541574b');
      expect(fnv1aHex(''), 'cbf29ce484222325');
    });

    test('no hash is ever formatted with a minus sign', () {
      // The bug this replaces: Dart's ints are signed, so half of all hashes
      // used to be written as `-be805be934a29fb`.
      for (var i = 0; i < 2000; i++) {
        final hex = fnv1aHex('file-$i.jpg');
        expect(hex.length, 16, reason: 'got "$hex" for file-$i.jpg');
        expect(hex, matches(RegExp(r'^[0-9a-f]{16}$')));
      }
    });

    test('non-ASCII names hash their UTF-8 bytes, not UTF-16 units', () {
      // Rust hashes bytes. Hashing code units instead would agree on ASCII and
      // disagree on every accented, CJK or emoji filename — which is worse
      // than failing outright, because it only shows up on some users' folders.
      for (final name in ['é', 'ünïcode.jpg', '写真.png', 'a🎉b.webp']) {
        expect(
          fnv1aHex(name),
          _referenceFnv1a(utf8.encode(name)),
          reason: name,
        );
      }
    });
  });

  group('sidecar names travel', () {
    test('a name holds no path and is usable as a filename', () {
      final name = sidecarName(
        name: 'holiday.JPG',
        size: 4096,
        modifiedMs: 1700000000000,
      );
      expect(name, endsWith('.webp'));
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains('\\')));
    });

    test('case and location do not change it', () {
      final upper = sidecarName(
        name: 'Holiday.JPG',
        size: 4096,
        modifiedMs: 1700000000000,
      );
      final lower = sidecarName(
        name: 'holiday.jpg',
        size: 4096,
        modifiedMs: 1700000000000,
      );
      expect(upper, lower);
    });

    test('sub-second precision is dropped so two protocols agree', () {
      // The same file seen over SMB (100ns ticks) and over S3 (whole seconds).
      final smb = sidecarName(name: 'a.png', size: 10, modifiedMs: 1700000000123);
      final s3 = sidecarName(name: 'a.png', size: 10, modifiedMs: 1700000000000);
      expect(smb, s3);
    });

    test('a pre-epoch time rounds downwards rather than towards zero', () {
      final before = sidecarName(name: 'a', size: 1, modifiedMs: -1500);
      final justBefore = sidecarName(name: 'a', size: 1, modifiedMs: -500);
      final after = sidecarName(name: 'a', size: 1, modifiedMs: 500);
      expect(before, isNot(justBefore));
      expect(justBefore, isNot(after));
    });

    test('every part of the identity changes the name', () {
      final base = sidecarName(name: 'a.png', size: 100, modifiedMs: 1000000);
      expect(base,
          isNot(sidecarName(name: 'b.png', size: 100, modifiedMs: 1000000)));
      expect(base,
          isNot(sidecarName(name: 'a.png', size: 101, modifiedMs: 1000000)));
      expect(base,
          isNot(sidecarName(name: 'a.png', size: 100, modifiedMs: 2000000)));
      expect(
        base,
        isNot(sidecarName(
          name: 'a.png',
          size: 100,
          modifiedMs: 1000000,
          dim: 256,
        )),
      );
    });
  });

  group('staleness', () {
    test('an older thumbnail of the same file is recognised', () {
      const name = 'a.png';
      final current = sidecarName(name: name, size: 100, modifiedMs: 1000000);
      final edited = sidecarName(name: name, size: 250, modifiedMs: 9000000);
      final other = sidecarName(name: 'b.png', size: 100, modifiedMs: 1000000);

      expect(isStaleSidecar(edited, name, current), isTrue);
      expect(isStaleSidecar(current, name, current), isFalse,
          reason: 'the current thumbnail is not stale');
      expect(isStaleSidecar(other, name, current), isFalse,
          reason: 'another file\'s thumbnail is not this one\'s to delete');
    });
  });
}

/// FNV-1a over bytes, written the long way round, as the thing
/// [fnv1aHex]'s own UTF-8 conversion is checked against.
String _referenceFnv1a(List<int> bytes) {
  var h = 0xcbf29ce484222325;
  for (final byte in bytes) {
    h ^= byte;
    h = h * 0x100000001b3;
  }
  final hi = (h >> 32) & 0xFFFFFFFF;
  final lo = h & 0xFFFFFFFF;
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}
