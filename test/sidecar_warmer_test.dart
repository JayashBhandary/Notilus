import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/models/file_entry.dart';
import 'package:notilus/services/thumbnail_service.dart';
import 'package:notilus/services/thumbnails/sidecar_naming.dart';
import 'package:notilus/services/thumbnails/sidecar_thumbnails.dart';
import 'package:notilus/services/thumbnails/sidecar_warmer.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'native_test_support.dart';

/// Thumbnails made for files nobody opened.
///
/// The demand-driven path covers the machine doing the browsing. This covers
/// everyone else: a folder published over SMB has to arrive at the client with
/// its `.thumbs` already filled, because the client cannot make one without
/// pulling every full-size photo across the network.

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

/// A real image the Rust decoder opens, written without an encoder.
///
/// BMP is 54 bytes of header and then raw pixels, so a test can produce one
/// directly — and it is in [kImageExtensions], which is what the warmer walks.
File _writeBmp(Directory dir, String name, {int width = 64, int height = 48}) {
  final rowBytes = width * 3;
  final padding = (4 - rowBytes % 4) % 4;
  final pixels = BytesBuilder();
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      pixels.add([(x * 4) % 256, (y * 5) % 256, (x + y) % 256]);
    }
    pixels.add(List<int>.filled(padding, 0));
  }
  final body = pixels.takeBytes();
  final header = ByteData(54);
  header.setUint8(0, 0x42); // 'B'
  header.setUint8(1, 0x4D); // 'M'
  header.setUint32(2, 54 + body.length, Endian.little);
  header.setUint32(10, 54, Endian.little);
  header.setUint32(14, 40, Endian.little); // DIB header size
  header.setInt32(18, width, Endian.little);
  header.setInt32(22, height, Endian.little);
  header.setUint16(26, 1, Endian.little); // planes
  header.setUint16(28, 24, Endian.little); // bits per pixel
  header.setUint32(34, body.length, Endian.little);
  final file = File(p.join(dir.path, name));
  file.writeAsBytesSync([...header.buffer.asUint8List(), ...body]);
  return file;
}

FileEntry _entryFor(File file) {
  final stat = file.statSync();
  return FileEntry(
    path: file.path,
    name: p.basename(file.path),
    isDirectory: false,
    size: stat.size,
    modified: stat.modified,
  );
}

Set<String> _sidecarNames(Directory folder) {
  final dir = Directory(p.join(folder.path, kSidecarDir));
  if (!dir.existsSync()) return const {};
  return {
    for (final entry in dir.listSync().whereType<File>())
      p.basename(entry.path),
  };
}

/// Converts [source] to HEIC with the system encoder, or null where there
/// isn't one. Only macOS has both halves of this — the encoder to build the
/// fixture and the decoder under test.
File? _writeHeic(File source, String name) {
  if (!Platform.isMacOS) return null;
  final out = File(p.join(source.parent.path, name));
  try {
    final result = Process.runSync('sips', [
      '-s', 'format', 'heic',
      source.path,
      '--out', out.path,
    ]);
    if (result.exitCode != 0 || !out.existsSync() || out.lengthSync() == 0) {
      return null;
    }
    return out;
  } catch (_) {
    return null;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  late Directory scratch;
  late Directory cache;
  final realPathProvider = PathProviderPlatform.instance;
  var native = false;

  setUpAll(() async {
    native = await NativeTestSupport.ensureLoaded();
  });

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('notilus_warmer_test');
    cache = await Directory.systemTemp.createTemp('notilus_warmer_cache');
    PathProviderPlatform.instance = _FakePathProvider(cache.path);
    SidecarThumbnails.instance.debugReset();
    SidecarWarmer.instance.debugReset();
    ThumbnailService.instance.debugClearFailures();
  });

  tearDown(() async {
    PathProviderPlatform.instance = realPathProvider;
    SidecarWarmer.instance.debugReset();
    for (final dir in [scratch, cache]) {
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });

  group('a folder somebody opened', () {
    test('is filled past the tiles that were on screen', () async {
      if (!native) return;
      final folder = Directory(p.join(scratch.path, 'photos'))
        ..createSync(recursive: true);
      final files = [
        for (var i = 0; i < 12; i++) _writeBmp(folder, 'shot-$i.bmp'),
      ];

      await SidecarWarmer.instance
          .warmFolder(folder.path, files.map(_entryFor).toList());

      final made = _sidecarNames(folder);
      expect(made.length, files.length,
          reason: 'every photo in the folder, not the screenful on display');
      for (final file in files) {
        final entry = _entryFor(file);
        expect(
          made,
          contains(sidecarName(
            name: entry.name,
            size: entry.size,
            modifiedMs: entry.modified.millisecondsSinceEpoch,
          )),
        );
      }
    });

    test('leaves what is already there alone', () async {
      if (!native) return;
      final folder = Directory(p.join(scratch.path, 'again'))
        ..createSync(recursive: true);
      final files = [
        for (var i = 0; i < 4; i++) _writeBmp(folder, 'shot-$i.bmp'),
      ];
      final entries = files.map(_entryFor).toList();
      await SidecarWarmer.instance.warmFolder(folder.path, entries);
      final first = _sidecarNames(folder);
      final stamps = {
        for (final name in first)
          name: File(p.join(folder.path, kSidecarDir, name)).statSync().modified,
      };

      SidecarWarmer.instance.debugReset();
      SidecarThumbnails.instance.debugReset();
      await SidecarWarmer.instance.warmFolder(folder.path, entries);

      expect(_sidecarNames(folder), first);
      for (final entry in stamps.entries) {
        expect(
          File(p.join(folder.path, kSidecarDir, entry.key)).statSync().modified,
          entry.value,
          reason: 'a second pass must not re-encode what it found',
        );
      }
    });

    test('skips the companions a Mac scatters over a volume', () async {
      if (!native) return;
      final folder = Directory(p.join(scratch.path, 'appledouble'))
        ..createSync(recursive: true);
      final real = _writeBmp(folder, 'holiday.bmp');
      // Same extension, four kilobytes of metadata inside, and one wasted
      // decode each if they aren't recognised for what they are.
      final shadow = File(p.join(folder.path, '._holiday.bmp'))
        ..writeAsBytesSync(List<int>.filled(4096, 0));

      await SidecarWarmer.instance.warmFolder(
        folder.path,
        [_entryFor(real), _entryFor(shadow)],
      );

      expect(_sidecarNames(folder).length, 1);
    });
  });

  group('a folder published to the network', () {
    test('fills every folder under the share, not just the top', () async {
      if (!native) return;
      final root = Directory(p.join(scratch.path, 'share'))
        ..createSync(recursive: true);
      final months = [
        for (final name in ['2026/JUNE', '2026/MAY', '2025/DECEMBER'])
          Directory(p.join(root.path, name))..createSync(recursive: true),
      ];
      for (final month in months) {
        _writeBmp(month, 'a.bmp');
        _writeBmp(month, 'b.bmp');
      }
      // Nothing of ours belongs in a dot-folder: caches, trash, Spotlight.
      final hidden = Directory(p.join(root.path, '.Trashes'))
        ..createSync(recursive: true);
      _writeBmp(hidden, 'deleted.bmp');

      await SidecarWarmer.instance.warmShare(root.path);

      for (final month in months) {
        expect(
          _sidecarNames(month).length,
          2,
          reason: '${month.path} was never opened by anyone here',
        );
      }
      expect(_sidecarNames(hidden), isEmpty);
    });

    test('stops when sharing stops', () async {
      if (!native) return;
      final root = Directory(p.join(scratch.path, 'stopped'))
        ..createSync(recursive: true);
      final months = [
        for (var i = 0; i < 6; i++)
          Directory(p.join(root.path, 'month-$i'))..createSync(recursive: true),
      ];
      for (final month in months) {
        _writeBmp(month, 'a.bmp');
        _writeBmp(month, 'b.bmp');
      }

      // The walk suspends on its first listing, so the stop lands before any
      // folder is filled — which is the point: turning sharing off gets the
      // machine back rather than queueing an evening of decoding behind it.
      final walking = SidecarWarmer.instance.warmShare(root.path);
      SidecarWarmer.instance.stopShares();
      await walking;

      for (final month in months) {
        expect(_sidecarNames(month), isEmpty);
      }
    });
  });

  group('formats only the operating system can open', () {
    test('a HEIC still gets a thumbnail beside it', () async {
      if (!native) return;
      final folder = Directory(p.join(scratch.path, 'iphone'))
        ..createSync(recursive: true);
      final source = _writeBmp(folder, 'source.bmp', width: 800, height: 600);
      final heic = _writeHeic(source, 'IMG_6812.HEIC');
      if (heic == null) return; // No system HEIC encoder to build a fixture.
      source.deleteSync();

      final entry = _entryFor(heic);
      final hit = await SidecarThumbnails.instance
          .generateFromFile(entry, entry.path);

      expect(
        hit,
        isNotNull,
        reason: 'a camera roll is almost entirely HEIC — no decoder here, but '
            'the OS has one, and the share needs the thumbnail either way',
      );
      expect(
        _sidecarNames(folder),
        contains(sidecarName(
          name: entry.name,
          size: entry.size,
          modifiedMs: entry.modified.millisecondsSinceEpoch,
        )),
      );
    });

    test('an unreadable file is still a miss, not a crash', () async {
      if (!native) return;
      final folder = Directory(p.join(scratch.path, 'broken'))
        ..createSync(recursive: true);
      final junk = File(p.join(folder.path, 'not-really.heic'))
        ..writeAsStringSync('this is not a picture');

      final hit = await SidecarThumbnails.instance
          .generateFromFile(_entryFor(junk), junk.path);

      expect(hit, isNull);
      expect(_sidecarNames(folder), isEmpty);
    });
  });
}
