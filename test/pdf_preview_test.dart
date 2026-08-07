import 'dart:io';

import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/models/file_entry.dart';
import 'package:notilus/screens/preview/preview_viewers.dart';
import 'package:notilus/theme.dart';

/// The Linux PDF viewer, which rasterises pages with poppler.
///
/// It used to render every page — up to a hundred — before painting anything,
/// so opening a long document sat on a spinner. Pages are now rendered on
/// demand; what these tests pin down is that opening a document does *not*
/// render all of it.
void main() {
  bool hasTool(String exe) {
    try {
      return Process.runSync('which', [exe]).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  group('PdfInfo.parse', () {
    test('reads the page count and page ratio pdfinfo reports', () {
      final info = PdfInfo.parse('''
Title:           Something
Pages:           12
Page size:       612 x 792 pts (letter)
File size:       3283 bytes
''');

      expect(info, isNotNull);
      expect(info!.pages, 12);
      expect(info.aspect, closeTo(612 / 792, 0.0001));
    });

    test('handles a landscape page size', () {
      final info = PdfInfo.parse('Pages: 3\nPage size: 842 x 595 pts\n');
      expect(info!.aspect, greaterThan(1));
    });

    test('falls back to letter when the page size is unreadable', () {
      final info = PdfInfo.parse('Pages: 5\nPage size: unknown\n');
      expect(info!.pages, 5);
      expect(info.aspect, closeTo(612 / 792, 0.0001));
    });

    test('a page size of zero does not become an infinite ratio', () {
      final info = PdfInfo.parse('Pages: 2\nPage size: 0 x 792 pts\n');
      expect(info!.aspect, closeTo(612 / 792, 0.0001));
    });

    test('output with no page count is not a document', () {
      expect(PdfInfo.parse('Producer: whatever\n'), isNull);
      expect(PdfInfo.parse('Pages: 0\n'), isNull);
      expect(PdfInfo.parse(''), isNull);
    });
  });

  group('lazy rendering', () {
    final poppler = hasTool('pdftoppm') && hasTool('pdfinfo');

    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('notilus_pdfview_test');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    /// A minimal multi-page PDF, written by hand so the suite ships no binary.
    File writePdf(String name, int pageCount) {
      final objects = <int, String>{};
      final kids = [for (var i = 0; i < pageCount; i++) '${3 + i} 0 R'].join(' ');
      objects[1] = '<</Type/Catalog/Pages 2 0 R>>';
      objects[2] = '<</Type/Pages/Kids[$kids]/Count $pageCount>>';
      for (var i = 0; i < pageCount; i++) {
        objects[3 + i] = '<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]'
            '/Contents ${3 + pageCount + i} 0 R'
            '/Resources<</Font<</F1 ${3 + 2 * pageCount} 0 R>>>>>>';
      }
      for (var i = 0; i < pageCount; i++) {
        final stream = 'BT /F1 48 Tf 100 400 Td (Page ${i + 1}) Tj ET';
        objects[3 + pageCount + i] =
            '<</Length ${stream.length}>>\nstream\n$stream\nendstream';
      }
      objects[3 + 2 * pageCount] =
          '<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>';

      final buffer = StringBuffer('%PDF-1.4\n');
      final offsets = <int, int>{};
      final keys = objects.keys.toList()..sort();
      for (final n in keys) {
        offsets[n] = buffer.length;
        buffer.write('$n 0 obj\n${objects[n]}\nendobj\n');
      }
      final xref = buffer.length;
      final max = keys.last + 1;
      buffer.write('xref\n0 $max\n0000000000 65535 f \n');
      for (var n = 1; n < max; n++) {
        buffer.write('${(offsets[n] ?? 0).toString().padLeft(10, '0')} '
            '00000 n \n');
      }
      buffer.write('trailer<</Size $max/Root 1 0 R>>\n'
          'startxref\n$xref\n%%EOF\n');

      return File('${tmp.path}/$name')..writeAsStringSync(buffer.toString());
    }

    Widget host(Widget child) {
      return ShadApp.custom(
        theme: AppTheme.shadThemeFor(Brightness.light),
        darkTheme: AppTheme.shadThemeFor(Brightness.dark),
        themeMode: ThemeMode.light,
        appBuilder: (_) => CupertinoApp(
          localizationsDelegates: const [
            GlobalShadLocalizations.delegate,
            DefaultMaterialLocalizations.delegate,
            DefaultCupertinoLocalizations.delegate,
            DefaultWidgetsLocalizations.delegate,
          ],
          builder: (_, inner) => ShadAppBuilder(child: inner!),
          home: child,
        ),
      );
    }

    /// Scratch directories the viewer creates, so the test can count how many
    /// pages poppler was actually asked for.
    List<Directory> viewerScratchDirs() => Directory.systemTemp
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.contains('notilus_pdf_'))
        .toList();

    testWidgets('opens a long document without rendering every page',
        (tester) async {
      final before = viewerScratchDirs().map((d) => d.path).toSet();
      final pdf = writePdf('long.pdf', 20);
      final entry = FileEntry(
        path: pdf.path,
        name: 'long.pdf',
        isDirectory: false,
        size: pdf.lengthSync(),
        modified: DateTime(2026),
      );

      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // Everything runs inside runAsync: the viewer spawns real pdfinfo and
      // pdftoppm processes, and Process.start's timers never fire under
      // fake-async — the test would end holding pending timers.
      await tester.runAsync(() async {
        await tester.pumpWidget(host(PopplerPdfViewer(file: entry)));
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          await tester.pump();
        }
      });

      // The toolbar knows the full length from pdfinfo alone.
      expect(find.text('1 / 20'), findsOneWidget);

      final scratch = viewerScratchDirs()
          .where((d) => !before.contains(d.path))
          .toList();
      expect(scratch, hasLength(1), reason: 'viewer should own one temp dir');

      final rendered = scratch.single
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .length;

      // The point of the change: a handful of pages, not all twenty.
      expect(rendered, greaterThan(0), reason: 'first page should be drawn');
      expect(rendered, lessThan(20),
          reason: 'the whole document must not be rasterised up front');

      // Page files are named for the page they hold, so page one is present
      // rather than whatever poppler happened to emit first.
      expect(File('${scratch.single.path}/page-1.png').existsSync(), isTrue);
    }, skip: !poppler); // needs poppler-utils installed

    testWidgets('a file that is not a PDF explains itself', (tester) async {
      final f = File('${tmp.path}/broken.pdf')..writeAsStringSync('nope');
      final entry = FileEntry(
        path: f.path,
        name: 'broken.pdf',
        isDirectory: false,
        size: f.lengthSync(),
        modified: DateTime(2026),
      );

      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(() async {
        await tester.pumpWidget(host(PopplerPdfViewer(file: entry)));
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          await tester.pump();
        }
      });

      expect(find.text('Couldn\'t render this PDF'), findsOneWidget);
      expect(find.text('Open in external viewer'), findsOneWidget);
    }, skip: !poppler); // needs poppler-utils installed
  });
}
