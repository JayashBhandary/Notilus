import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/models/file_entry.dart';
import 'package:notilus/services/native_core.dart';
import 'package:notilus/services/thumbnails/sidecar_naming.dart';
import 'package:notilus/services/thumbnails/sidecar_policy.dart';
import 'package:notilus/services/thumbnails/sidecar_store.dart';
import 'package:notilus/services/thumbnails/sidecar_thumbnails.dart';
import 'package:notilus/widgets/file_thumbnail.dart';
import 'package:path/path.dart' as p;

import 'native_test_support.dart';

late Directory _scratch;

Directory _folder(String name) {
  final dir = Directory(p.join(_scratch.path, name));
  dir.createSync(recursive: true);
  return dir;
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

/// Writes a photo-like image the encoder has real work to do on.
///
/// A PPM: raw RGB behind a three-line header, which `image` decodes and which
/// needs no encoder here to produce. Gradients plus grain, so the result
/// compresses like a photograph rather than like a flat colour.
File _writeImage(
  Directory dir,
  String name, {
  int width = 1200,
  int height = 900,
}) {
  final file = File(p.join(dir.path, name));
  final header = 'P6\n$width $height\n255\n';
  final pixels = Uint8List(width * height * 3);
  var seed = 7;
  for (var i = 0; i < pixels.length; i += 3) {
    seed = (seed * 1664525 + 1013904223) & 0x7FFFFFFF;
    pixels[i] = (i ~/ 3) % 256;
    pixels[i + 1] = ((i ~/ 3) ~/ width) % 256;
    pixels[i + 2] = (seed >> 16) & 0xFF;
  }
  file.writeAsBytesSync([...header.codeUnits, ...pixels]);
  return file;
}

/// The `.thumbs` name [entry]'s thumbnail is stored under.
String _nameOf(FileEntry entry) => sidecarName(
      name: entry.name,
      size: entry.size,
      modifiedMs: entry.modified.millisecondsSinceEpoch,
    );

/// Writes a real WebP photo, which is what the widget path needs.
///
/// The service-level tests can hand the encoder a `.ppm`, but the widget routes
/// on extension, and `.ppm` is not something a file manager offers a preview
/// for. So the core encodes one: a PPM in, a WebP on disk under a name the grid
/// will actually try to draw.
Future<File> _writeWebp(Directory dir, String name) async {
  final source = _writeImage(dir, '$name.source.ppm', width: 900, height: 700);
  final encoded = await NativeCore.instance.thumbnailBytes(
    src: source.path,
    maxDim: 1024,
  );
  final out = File(p.join(dir.path, name));
  out.writeAsBytesSync(encoded.bytes);
  source.deleteSync();
  return out;
}

void main() {
  setUpAll(() async {
    _scratch = Directory.systemTemp.createTempSync('notilus_sidecar_test_');
    await NativeTestSupport.ensureLoaded();
  });

  tearDownAll(() {
    try {
      _scratch.deleteSync(recursive: true);
    } catch (_) {
      // A leftover temp directory is not worth failing a suite over.
    }
  });

  group('a local .thumbs folder', () {
    test('starts absent and is not created by looking', () async {
      final dir = _folder('untouched');
      final store = LocalSidecarStore(dir.path);

      expect(await store.listNames(), isNull);
      expect(
        Directory(p.join(dir.path, kSidecarDir)).existsSync(),
        isFalse,
        reason: 'browsing a read-only source must leave no trace',
      );
    });

    test('round-trips a thumbnail through the name it is stored under',
        () async {
      final dir = _folder('roundtrip');
      final store = LocalSidecarStore(dir.path);
      final entry = _entryFor(_writeImage(dir, 'photo.ppm'));
      final name = sidecarName(
        name: entry.name,
        size: entry.size,
        modifiedMs: entry.modified.millisecondsSinceEpoch,
      );

      expect(await store.write(name, Uint8List.fromList([1, 2, 3])), isTrue);
      expect(await store.listNames(), contains(name));
      expect(await store.read(name), Uint8List.fromList([1, 2, 3]));
      expect(await store.localPathFor(name),
          p.join(dir.path, kSidecarDir, name));
    });

    test('leaves nothing behind when a write finishes', () async {
      final dir = _folder('staging');
      final store = LocalSidecarStore(dir.path);
      await store.write('a.webp', Uint8List.fromList([9]));

      final left = Directory(p.join(dir.path, kSidecarDir))
          .listSync()
          .map((e) => p.basename(e.path))
          .toList();
      expect(left, ['a.webp'], reason: 'the .part file must be renamed, not kept');
    });

    test('refuses an entry too large to be a thumbnail', () async {
      // `.thumbs` on a share is writable by other people. A megabyte-plus
      // entry was not written by Notilus and is not decoded to find out what
      // it is.
      final dir = _folder('oversize');
      final store = LocalSidecarStore(dir.path);
      final bloated = Uint8List(kMaxSidecarBytes + 1);
      await store.write('big.webp', bloated);

      expect(await store.listNames(), contains('big.webp'));
      expect(await store.read('big.webp'), isNull);
      expect(
        await store.localPathFor('big.webp'),
        isNull,
        reason: 'the cap must hold on the path handed to the image widget too',
      );
    });

    test('a removed thumbnail is gone and a missing one is not an error',
        () async {
      final dir = _folder('remove');
      final store = LocalSidecarStore(dir.path);
      await store.write('a.webp', Uint8List.fromList([1]));

      await store.remove('a.webp');
      expect(await store.read('a.webp'), isNull);
      await store.remove('never-existed.webp');
    });

    test('a read-only folder reports the failure instead of throwing',
        () async {
      final dir = _folder('readonly');
      // Make the folder unwritable, which is what a mounted-read-only drive or
      // a share without write access looks like from here.
      final result = Process.runSync('chmod', ['a-w', dir.path]);
      if (result.exitCode != 0) {
        markTestSkipped('chmod unavailable');
        return;
      }
      addTearDown(() => Process.runSync('chmod', ['u+w', dir.path]));

      final store = LocalSidecarStore(dir.path);
      expect(await store.write('a.webp', Uint8List.fromList([1])), isFalse);
    }, skip: Platform.isWindows);
  });

  group('encoding, through the real core', () {
    test('a photo becomes a small WebP keyed on its own identity', () async {
      final dir = _folder('encode');
      final source = _writeImage(dir, 'holiday.ppm');
      final entry = _entryFor(source);

      final encoded = await NativeCore.instance.thumbnailBytes(
        src: source.path,
        maxDim: kSidecarMasterDim,
      );

      expect(encoded.width, kSidecarMasterDim);
      expect(encoded.bytes.length, lessThan(kMaxSidecarBytes));
      // RIFF....WEBP — the container's own magic, so this asserts the format
      // rather than trusting the extension.
      expect(encoded.bytes.sublist(0, 4), 'RIFF'.codeUnits);
      expect(encoded.bytes.sublist(8, 12), 'WEBP'.codeUnits);

      final store = LocalSidecarStore(dir.path);
      final name = sidecarName(
        name: entry.name,
        size: entry.size,
        modifiedMs: entry.modified.millisecondsSinceEpoch,
      );
      expect(await store.write(name, encoded.bytes), isTrue);
      expect(await store.read(name), encoded.bytes);
    });

    test('a name written on one machine is the name another machine looks for',
        () async {
      // The whole point of the scheme: the same folder reached through a
      // different mount point must resolve to the same thumbnail. Two paths,
      // one identity.
      final onUsb = FileEntry(
        path: '/media/jayash/photos/holiday.jpg',
        name: 'holiday.jpg',
        isDirectory: false,
        size: 4096,
        modified: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final onMac = FileEntry(
        path: '/Volumes/photos/holiday.jpg',
        name: 'holiday.jpg',
        isDirectory: false,
        size: 4096,
        modified: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

      String nameOf(FileEntry e) => sidecarName(
            name: e.name,
            size: e.size,
            modifiedMs: e.modified.millisecondsSinceEpoch,
          );
      expect(nameOf(onUsb), nameOf(onMac));

      // And the Rust side agrees, which is what lets either language write it.
      final fromRust = await NativeCore.instance.thumbnailSidecarName(
        name: onUsb.name,
        size: onUsb.size,
        modifiedMs: onUsb.modified.millisecondsSinceEpoch,
        dim: kSidecarMasterDim,
      );
      expect(nameOf(onUsb), fromRust);
    });
  }, skip: !NativeTestSupport.isBuilt);

  group('the whole path, end to end', () {
    setUp(SidecarThumbnails.instance.debugReset);

    test('browsing a folder of photos leaves a populated .thumbs behind',
        () async {
      // What device A does. No .thumbs exists; three photos are looked at; a
      // .thumbs appears holding a thumbnail for each.
      final dir = _folder('deviceA');
      final entries = [
        for (final name in ['one.ppm', 'two.ppm', 'three.ppm'])
          _entryFor(_writeImage(dir, name, width: 600, height: 400)),
      ];
      expect(Directory(p.join(dir.path, kSidecarDir)).existsSync(), isFalse);

      for (final entry in entries) {
        final hit = await SidecarThumbnails.instance
            .generateFromFile(entry, entry.path);
        expect(hit, isNotNull, reason: '${entry.name} produced nothing');
        expect(hit!.file, isNotNull, reason: 'a local source stores a file');
      }

      final sidecar = Directory(p.join(dir.path, kSidecarDir));
      expect(sidecar.existsSync(), isTrue, reason: '.thumbs must be created');
      final stored = sidecar
          .listSync()
          .map((e) => p.basename(e.path))
          .toList()
        ..sort();
      expect(stored, hasLength(3));
      expect(stored.every((n) => n.endsWith('.webp')), isTrue);
      for (final entry in entries) {
        expect(
          stored,
          contains(sidecarName(
            name: entry.name,
            size: entry.size,
            modifiedMs: entry.modified.millisecondsSinceEpoch,
          )),
        );
      }
    });

    test('a second device finds them without generating anything', () async {
      // What device B does. Same folder, same files, a cold cache — and the
      // thumbnails are already there.
      final dir = _folder('deviceB');
      final entry = _entryFor(_writeImage(dir, 'shared.ppm'));

      final first =
          await SidecarThumbnails.instance.generateFromFile(entry, entry.path);
      expect(first, isNotNull);
      final written = File(first!.file!.path).readAsBytesSync();

      // A different Notilus, on a different machine, reaching the same folder.
      SidecarThumbnails.instance.debugReset();
      final found = await SidecarThumbnails.instance.lookup(entry);
      expect(found, isNotNull, reason: 'device B must find device A\'s work');
      expect(found!.file!.readAsBytesSync(), written);

      // And it really is the thumbnail, not the original.
      expect(found.file!.path, isNot(entry.path));
      expect(written.sublist(0, 4), 'RIFF'.codeUnits);
    });

    test('an edited file is not shown its old thumbnail', () async {
      final dir = _folder('edited');
      final source = _writeImage(dir, 'photo.ppm', width: 400, height: 300);
      final before = _entryFor(source);
      await SidecarThumbnails.instance.generateFromFile(before, before.path);

      // Rewrite it at a different size, which changes both size and mtime.
      _writeImage(dir, 'photo.ppm', width: 640, height: 480);
      final after = _entryFor(source);
      expect(after.size, isNot(before.size));

      SidecarThumbnails.instance.debugReset();
      expect(
        await SidecarThumbnails.instance.lookup(after),
        isNull,
        reason: 'the stale thumbnail must not answer for the new file',
      );
    });

    test('a stale thumbnail is swept and the current one is kept', () async {
      final dir = _folder('sweep');
      final source = _writeImage(dir, 'photo.ppm', width: 400, height: 300);
      await SidecarThumbnails.instance
          .generateFromFile(_entryFor(source), source.path);
      _writeImage(dir, 'photo.ppm', width: 640, height: 480);
      final current = _entryFor(source);
      SidecarThumbnails.instance.debugReset();
      await SidecarThumbnails.instance
          .generateFromFile(current, current.path);

      final sidecar = Directory(p.join(dir.path, kSidecarDir));
      expect(sidecar.listSync(), hasLength(2), reason: 'old and new coexist');

      final removed =
          await SidecarThumbnails.instance.sweep(dir.path, [current]);
      expect(removed, 1);
      final left =
          sidecar.listSync().map((e) => p.basename(e.path)).toList();
      expect(left, [
        sidecarName(
          name: current.name,
          size: current.size,
          modifiedMs: current.modified.millisecondsSinceEpoch,
        ),
      ]);
    });

    test('a sweep leaves alone anything it did not write', () async {
      final dir = _folder('sweep-foreign');
      final store = LocalSidecarStore(dir.path);
      await store.write('notes.txt', Uint8List.fromList([1]));
      await store.write('deadbeefdeadbeef_1_1_512.webp', Uint8List.fromList([1]));

      final removed = await SidecarThumbnails.instance.sweep(dir.path, const []);
      expect(removed, 0, reason: 'nothing here describes a file we just listed');
      expect(await store.listNames(), hasLength(2));
    });
  }, skip: !NativeTestSupport.isBuilt);

  group('where thumbnails are written', () {
    test('every source keeps them beside the data', () {
      // Including the internal disk: a folder on this machine is what an SMB
      // share publishes, what gets copied to a drive, and what a second
      // machine reaches over SFTP. The machine-local cache is invisible to all
      // three.
      for (final folder in [
        'notilus://abc123/bucket/trip',
        '/media/jayash/photos',
        '/mnt/share/docs',
        '/home/jayash/Documents',
        '/home/jayash/Pictures/2024',
        '/srv/samba/public',
      ]) {
        expect(
          SidecarPolicy.homeFor(folder),
          ThumbnailHome.sidecar,
          reason: folder,
        );
      }
    });

    test('a folder inside a .thumbs does not get one of its own', () {
      // `.thumbs` is a real folder that "show hidden" plus a typed path will
      // reach. Thumbnailing thumbnails into `.thumbs/.thumbs` is the one thing
      // to refuse.
      expect(
        SidecarPolicy.homeFor('/home/jayash/Pictures/$kSidecarDir'),
        ThumbnailHome.central,
      );
      expect(
        SidecarPolicy.homeFor('notilus://c/bucket/$kSidecarDir'),
        ThumbnailHome.central,
      );
    });
  });

  group('the grid tile that a user actually looks at', () {
    // The tests above call the service directly. This one goes through
    // `FilePreviewBuilder` — the widget the icon grid and the info panel both
    // build — because that is the path a user exercises by opening a folder,
    // and a service that works while the widget routes around it looks exactly
    // like a feature that does nothing.

    /// Resolves one tile's preview the way a grid does, and hands back what it
    /// settled on.
    ///
    /// Not `pumpAndSettle`: the work being waited for is a call into the Rust
    /// core, which completes on the real event loop, and a settle loop never
    /// yields to it — the test hangs rather than fails. So real time and frames
    /// are advanced alternately until the tile stops saying "nothing yet".
    Future<FilePreview> resolve(WidgetTester tester, FileEntry entry) async {
      FilePreview? last;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: FilePreviewBuilder(
            entry: entry,
            dim: 320,
            builder: (context, preview) {
              last = preview;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      for (var i = 0; i < 200; i++) {
        if (last != null && last is! FilePreviewNone) return last!;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      fail('the tile never resolved to a preview');
    }

    testWidgets('opening a folder of photos leaves .thumbs behind',
        (tester) async {
      final dir = _folder('grid');
      final entry = _entryFor(
        (await tester.runAsync(() => _writeWebp(dir, 'holiday.webp')))!,
      );
      SidecarThumbnails.instance.debugReset();

      final preview = await resolve(tester, entry);

      // The tile is showing the thumbnail, not the original.
      final shown = (preview as FilePreviewImage).file;
      expect(
        p.basename(shown.parent.path),
        kSidecarDir,
        reason: 'the tile must draw the sidecar, not re-decode the photo',
      );
      expect(
        shown.path,
        p.join(dir.path, kSidecarDir, _nameOf(entry)),
      );
      expect(shown.readAsBytesSync().sublist(0, 4), 'RIFF'.codeUnits);
    });

    testWidgets('the second machine to open it decodes nothing',
        (tester) async {
      final dir = _folder('grid-second');
      final entry = _entryFor(
        (await tester.runAsync(() => _writeWebp(dir, 'shared.webp')))!,
      );
      SidecarThumbnails.instance.debugReset();
      await resolve(tester, entry);

      final written =
          File(p.join(dir.path, kSidecarDir, _nameOf(entry)));
      final stamp = written.lastModifiedSync();
      final bytes = written.readAsBytesSync();

      // Device B: same folder, nothing remembered.
      SidecarThumbnails.instance.debugReset();
      final preview = await resolve(tester, entry);

      expect((preview as FilePreviewImage).file.path, written.path);
      expect(written.readAsBytesSync(), bytes);
      expect(
        written.lastModifiedSync(),
        stamp,
        reason: 'a hit must be read, not rewritten',
      );
    });

    testWidgets('a folder that refuses writes still shows the photo',
        (tester) async {
      // A read-only drive or a share mounted without write access. The tile
      // falls back to the original rather than showing a glyph.
      final dir = _folder('grid-readonly');
      final entry = _entryFor(
        (await tester.runAsync(() => _writeWebp(dir, 'locked.webp')))!,
      );
      SidecarThumbnails.instance.debugReset();
      await tester.runAsync(() => Process.run('chmod', ['a-w', dir.path]));
      addTearDown(() => Process.run('chmod', ['u+w', dir.path]));

      final preview = await resolve(tester, entry);

      expect((preview as FilePreviewImage).file.path, entry.path);
      expect(Directory(p.join(dir.path, kSidecarDir)).existsSync(), isFalse);
    }, skip: !Platform.isLinux && !Platform.isMacOS);
  }, skip: !NativeTestSupport.isBuilt);

  group('deleting a file deletes what it looks like', () {
    // A thumbnail is a readable rendering of the file. One left behind after
    // the photo is deleted is a copy of it the user thinks is gone — and on a
    // share, a copy everyone else can still open.

    test('the thumbnail goes with the file', () async {
      final dir = _folder('forget');
      final photo = _writeImage(dir, 'private.ppm');
      final entry = _entryFor(photo);
      await SidecarThumbnails.instance.generateFromFile(entry, entry.path);
      final sidecar = Directory(p.join(dir.path, kSidecarDir));
      expect(sidecar.listSync(), hasLength(1));

      photo.deleteSync();
      await SidecarThumbnails.instance.forget([entry.path]);

      expect(
        sidecar.listSync(),
        isEmpty,
        reason: 'nothing may survive that shows the deleted file',
      );
    });

    test('older versions of the same file go too', () async {
      // Editing a file leaves the previous thumbnail behind until a sweep. A
      // delete must not leave that one showing either.
      final dir = _folder('forget-stale');
      final photo = _writeImage(dir, 'draft.ppm', width: 400, height: 300);
      final first = _entryFor(photo);
      await SidecarThumbnails.instance.generateFromFile(first, first.path);
      _writeImage(dir, 'draft.ppm', width: 640, height: 480);
      final second = _entryFor(photo);
      SidecarThumbnails.instance.debugReset();
      await SidecarThumbnails.instance.generateFromFile(second, second.path);
      expect(Directory(p.join(dir.path, kSidecarDir)).listSync(), hasLength(2));

      photo.deleteSync();
      await SidecarThumbnails.instance.forget([second.path]);

      expect(Directory(p.join(dir.path, kSidecarDir)).listSync(), isEmpty);
    });

    test('a neighbour keeps its own', () async {
      final dir = _folder('forget-neighbour');
      final gone = _entryFor(_writeImage(dir, 'gone.ppm'));
      final kept = _entryFor(_writeImage(dir, 'kept.ppm'));
      await SidecarThumbnails.instance.generateFromFile(gone, gone.path);
      await SidecarThumbnails.instance.generateFromFile(kept, kept.path);

      await SidecarThumbnails.instance.forget([gone.path]);

      final left = Directory(p.join(dir.path, kSidecarDir))
          .listSync()
          .map((e) => p.basename(e.path))
          .toList();
      expect(left, [_nameOf(kept)]);
    });

    test('a folder that never had thumbnails is not disturbed', () async {
      final dir = _folder('forget-empty');
      final entry = _entryFor(_writeImage(dir, 'photo.ppm'));

      await SidecarThumbnails.instance.forget([entry.path]);

      expect(
        Directory(p.join(dir.path, kSidecarDir)).existsSync(),
        isFalse,
        reason: 'a delete must not create a .thumbs of its own',
      );
    });
  }, skip: !NativeTestSupport.isBuilt);
}
