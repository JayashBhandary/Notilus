import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:notilus/models/file_entry.dart';
import 'package:notilus/services/thumbnail_service.dart';

/// Previews for the formats that can't just be handed to `Image.file`.
///
/// The renderer-backed paths (video frames, PDF pages) depend on tools that
/// may not be installed, so those tests skip themselves rather than failing on
/// a machine without ffmpeg or poppler. What always runs is the classification
/// and the embedded-preview extraction, which is pure Dart.

/// Same trick the duplicate-finder test uses: path_provider_linux is a
/// pure-Dart xdg lookup, so the platform instance has to be swapped rather
/// than a method channel mocked.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

bool _hasTool(String exe) {
  try {
    return Process.runSync('which', [exe]).exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  final realPathProvider = PathProviderPlatform.instance;
  final service = ThumbnailService.instance;

  FileEntry entryFor(File f) {
    final stat = f.statSync();
    return FileEntry(
      path: f.path,
      name: p.basename(f.path),
      isDirectory: false,
      size: stat.size,
      modified: stat.modified,
    );
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('notilus_thumb_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    service.debugClearFailures();
  });

  tearDown(() async {
    PathProviderPlatform.instance = realPathProvider;
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  File touch(String name, [String contents = 'x']) =>
      File(p.join(tmp.path, name))..writeAsStringSync(contents);

  group('classification', () {
    test('knows which files can show more than an icon', () {
      expect(service.canPreview(entryFor(touch('a.mp4'))), isTrue);
      expect(service.canPreview(entryFor(touch('a.pdf'))), isTrue);
      expect(service.canPreview(entryFor(touch('a.docx'))), isTrue);
      expect(service.canPreview(entryFor(touch('a.odt'))), isTrue);
      expect(service.canPreview(entryFor(touch('a.epub'))), isTrue);
      expect(service.canPreview(entryFor(touch('a.md'))), isTrue);

      // No renderer and nothing embedded — these stay glyphs.
      expect(service.canPreview(entryFor(touch('a.doc'))), isFalse);
      expect(service.canPreview(entryFor(touch('a.xls'))), isFalse);
      expect(service.canPreview(entryFor(touch('a.pages'))), isFalse);
    });

    test('separates rendered previews from ones already in the file', () {
      expect(service.hasRenderedPreview(entryFor(touch('clip.mov'))), isTrue);
      expect(service.hasRenderedPreview(entryFor(touch('paper.pdf'))), isTrue);
      expect(service.hasRenderedPreview(entryFor(touch('sheet.ods'))), isFalse);
      expect(service.hasEmbeddedPreview(entryFor(touch('sheet.ods'))), isTrue);
    });

    test('recognises the video containers the media page scans', () {
      for (final ext in ['.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v']) {
        expect(service.isVideo(entryFor(touch('clip$ext'))), isTrue,
            reason: ext);
      }
      expect(service.isVideo(entryFor(touch('song.mp3'))), isFalse);
    });
  });

  group('renderer lookup', () {
    test('resolves an installed tool to an absolute executable', () {
      final sh = service.debugResolveTool('sh');
      expect(sh, isNotNull);
      expect(p.isAbsolute(sh!), isTrue);
      // The execute bit is what separates a renderer from a same-named data
      // file sitting earlier on PATH.
      expect(FileStat.statSync(sh).mode & 0x49, isNonZero);
    });

    test('a tool this machine has not got resolves to nothing', () {
      expect(service.debugResolveTool('notilus-no-such-renderer'), isNull);
    });

    test('searches the prefixes a GUI process never inherits', () {
      // A Finder-launched .app gets launchd's PATH — /usr/bin:/bin:/usr/sbin:
      // /sbin — and nothing else, so Homebrew and MacPorts prefixes have to be
      // searched explicitly or ffmpeg is invisible to the shipped app even
      // when every terminal on the machine can see it.
      expect(
        ThumbnailService.debugExtraToolDirs,
        containsAll(['/opt/homebrew/bin', '/usr/local/bin', '/opt/local/bin']),
      );
    });

    test('finds ffmpeg wherever the package manager put it', () {
      const wellKnown = [
        '/opt/homebrew/bin/ffmpeg',
        '/usr/local/bin/ffmpeg',
        '/opt/local/bin/ffmpeg',
        '/usr/bin/ffmpeg',
      ];
      if (!wellKnown.any((c) => File(c).existsSync())) {
        return; // Not installed here — nothing for this test to prove.
      }
      expect(service.debugResolveTool('ffmpeg'), isNotNull);
    });

    test('renders more than three at a time where there are cores for it', () {
      final expected =
          (Platform.numberOfProcessors - 2).clamp(3, 8);
      expect(ThumbnailService.debugMaxConcurrentRenders, expected);
      expect(ThumbnailService.debugMaxConcurrentRenders, greaterThanOrEqualTo(3));
    });
  });

  group('embedded previews', () {
    /// A minimal zip container with [entries] inside, named like a real
    /// office document so the extension routing applies.
    File container(String name, Map<String, List<int>> entries) {
      final path = p.join(tmp.path, name);
      final encoder = ZipFileEncoder()..create(path);
      for (final e in entries.entries) {
        encoder.addArchiveFile(
          ArchiveFile(e.key, e.value.length, e.value),
        );
      }
      encoder.closeSync();
      return File(path);
    }

    // Not a real PNG — nothing decodes it in this test, it only has to come
    // back byte-for-byte.
    final pngBytes = List<int>.generate(64, (i) => (i * 7) % 251);

    test('lifts the ODF thumbnail every LibreOffice file carries', () async {
      final doc = container('report.odt', {
        'mimetype': 'application/vnd.oasis.opendocument.text'.codeUnits,
        'Thumbnails/thumbnail.png': pngBytes,
        'content.xml': '<office/>'.codeUnits,
      });

      final out = await service.embeddedThumbnail(entryFor(doc));
      expect(out, isNotNull);
      expect(out!.readAsBytesSync(), pngBytes);
    });

    test('lifts the OOXML preview when the author saved one', () async {
      final doc = container('deck.pptx', {
        'docProps/thumbnail.jpeg': pngBytes,
        '[Content_Types].xml': '<Types/>'.codeUnits,
      });

      final out = await service.embeddedThumbnail(entryFor(doc));
      expect(out, isNotNull);
      expect(out!.readAsBytesSync(), pngBytes);
    });

    test('falls back to an EPUB cover image', () async {
      final book = container('novel.epub', {
        'META-INF/container.xml': '<container/>'.codeUnits,
        'OEBPS/images/cover.jpg': pngBytes,
      });

      final out = await service.embeddedThumbnail(entryFor(book));
      expect(out, isNotNull);
      expect(out!.readAsBytesSync(), pngBytes);
    });

    test('a document with no preview inside returns nothing', () async {
      final doc = container('plain.docx', {
        'word/document.xml': '<w:document/>'.codeUnits,
      });

      expect(await service.embeddedThumbnail(entryFor(doc)), isNull);
    });

    test('a corrupt container is a miss, not a crash', () async {
      final broken = touch('broken.odt', 'this is not a zip');
      expect(await service.embeddedThumbnail(entryFor(broken)), isNull);
    });

    test('reuses the cached file instead of re-extracting', () async {
      final doc = container('report.odt', {
        'Thumbnails/thumbnail.png': pngBytes,
      });
      final entry = entryFor(doc);

      final first = await service.embeddedThumbnail(entry);
      final second = await service.embeddedThumbnail(entry);

      expect(first, isNotNull);
      expect(second!.path, first!.path);
    });

    test('an edited file gets a different cache entry', () async {
      final doc = container('report.odt', {
        'Thumbnails/thumbnail.png': pngBytes,
      });
      final before = await service.embeddedThumbnail(entryFor(doc));

      // The cache key folds in mtime and size, so a rewritten source can't
      // keep serving the old preview.
      final edited = FileEntry(
        path: doc.path,
        name: 'report.odt',
        isDirectory: false,
        size: doc.statSync().size + 1,
        modified: doc.statSync().modified.add(const Duration(minutes: 1)),
      );
      final after = await service.embeddedThumbnail(edited);

      expect(after, isNotNull);
      expect(after!.path, isNot(before!.path));
    });
  });

  group('video frames', () {
    final hasFfmpeg = _hasTool('ffmpeg') || _hasTool('ffmpegthumbnailer');

    test('extracts a frame from a real clip', () async {
      // A two-second synthetic clip, so the test doesn't ship a binary fixture.
      final clipPath = p.join(tmp.path, 'clip.mp4');
      final made = Process.runSync('ffmpeg', [
        '-y', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc=size=160x120:rate=10:duration=2',
        '-pix_fmt', 'yuv420p',
        clipPath,
      ]);
      expect(made.exitCode, 0, reason: 'fixture encode failed: ${made.stderr}');

      final out = await service.videoThumbnail(entryFor(File(clipPath)));
      expect(out, isNotNull);
      expect(out!.lengthSync(), greaterThan(0));
      // PNG magic number — proves a real image came back.
      expect(out.readAsBytesSync().sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    }, skip: hasFfmpeg ? false : 'no ffmpeg on this machine');

    test('a file that is not really a video degrades to no thumbnail',
        () async {
      final fake = touch('notavideo.mp4', 'definitely not h264');
      expect(await service.videoThumbnail(entryFor(fake)), isNull);
    }, skip: hasFfmpeg ? false : 'no ffmpeg on this machine');

    test('a missing renderer is a miss, not an exception', () async {
      // Whatever this machine has, asking for a nonexistent file must resolve
      // to null rather than throw.
      final ghost = FileEntry(
        path: p.join(tmp.path, 'ghost.mkv'),
        name: 'ghost.mkv',
        isDirectory: false,
        size: 10,
        modified: DateTime(2026),
      );
      expect(await service.videoThumbnail(ghost), isNull);
    });
  });

  group('pdf pages', () {
    final hasPoppler = _hasTool('pdftoppm');

    test('renders the first page', () async {
      // Smallest hand-written PDF that poppler will rasterise.
      const pdf = '%PDF-1.4\n'
          '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
          '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
          '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\n'
          'trailer<</Root 1 0 R>>\n';
      final f = touch('doc.pdf', pdf);

      final out = await service.pdfThumbnail(entryFor(f), dim: 120);
      expect(out, isNotNull);
      expect(out!.readAsBytesSync().sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    }, skip: hasPoppler ? false : 'no poppler on this machine');

    test('a file that is not a PDF degrades to no thumbnail', () async {
      final f = touch('fake.pdf', 'not a pdf at all');
      expect(await service.pdfThumbnail(entryFor(f)), isNull);
    });
  });

  group('text snippets', () {
    test('returns the head of a text file', () async {
      final f = touch('notes.md', '# Title\n\nbody text');
      expect(await service.textSnippet(entryFor(f)), startsWith('# Title'));
    });

    test('refuses binary content', () async {
      final f = File(p.join(tmp.path, 'blob.bin'))
        ..writeAsBytesSync([1, 2, 0, 3, 4]);
      expect(await service.textSnippet(entryFor(f)), isNull);
    });
  });
}
