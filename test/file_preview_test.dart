import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/models/file_entry.dart';
import 'package:notilus/screens/preview/file_preview_screen.dart';
import 'package:notilus/screens/preview/preview_common.dart';
import 'package:notilus/screens/preview/preview_filmstrip.dart';
import 'package:notilus/screens/preview/preview_info_panel.dart';
import 'package:notilus/screens/preview/preview_viewers.dart';
import 'package:notilus/theme.dart';
import 'package:notilus/widgets/shad_spinner.dart';

/// The redesigned preview: a shell that owns all chrome (top bar, info side
/// panel, sibling filmstrip) with viewers that only render content.
///
/// Fixtures are real files on disk — the viewers read them, and the filmstrip
/// decodes image thumbnails.
void main() {
  late Directory tmp;
  late List<FileEntry> files;

  /// 1×1 transparent PNG.
  final pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAF'
    'AAH/q842iQAAAABJRU5ErkJggg==',
  );

  Future<FileEntry> write(String name, List<int> bytes) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(bytes);
    final entry = await FileEntry.from(f);
    return entry!;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('notilus_preview_test');
    files = [
      await write('a.png', pngBytes),
      await write('notes.txt', utf8.encode('line one\nline two\nline three')),
      await write('readme.md', utf8.encode('# Title\n\nSome **body**.')),
      await write('blob.bin', List<int>.filled(2048, 7)),
    ];
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Widget host(Widget child, {Brightness brightness = Brightness.light}) {
    return ShadApp.custom(
      theme: AppTheme.shadThemeFor(Brightness.light),
      darkTheme: AppTheme.shadThemeFor(Brightness.dark),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      // Mirrors app.dart: ShadAppBuilder in `builder`, content in `home` so
      // showShadSheet has a Navigator to push onto.
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

  Future<void> pump(
    WidgetTester tester, {
    int initialIndex = 0,
    List<FileEntry>? only,
    Size size = const Size(1200, 900),
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        FilePreviewScreen(
          // initialIndex is only read in initState, so a second pump inside one
          // test needs a fresh key or the index change is silently ignored.
          key: ValueKey('preview-$initialIndex-${(only ?? files).length}'),
          files: only ?? files,
          initialIndex: initialIndex,
        ),
        brightness: brightness,
      ),
    );
    // Not pumpAndSettle: viewers read files asynchronously and PreviewLoading
    // holds a ShadSpinner whose controller repeats forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Mounts with real file I/O allowed to complete.
  ///
  /// The text and markdown viewers read their file through `File.readAsString`,
  /// which resolves on the real event loop — a plain `pump` only advances the
  /// fake-async zone, so their FutureBuilders would never produce data.
  Future<void> pumpRead(
    WidgetTester tester, {
    required int initialIndex,
    Size size = const Size(1200, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        host(FilePreviewScreen(files: files, initialIndex: initialIndex)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('shell', () {
    for (final brightness in Brightness.values) {
      testWidgets('lays out without overflow ($brightness)', (tester) async {
        await pump(tester, brightness: brightness);
        expect(tester.takeException(), isNull);
      });
    }

    // 700 is below the 820px side-panel threshold; 400 also drops the badges
    // and the sibling counter out of the top bar.
    for (final width in [820.0, 700.0, 400.0]) {
      testWidgets('lays out without overflow at ${width.toInt()}px',
          (tester) async {
        await pump(tester, size: Size(width, 800));
        expect(tester.takeException(), isNull);
      });
    }

    // Height matters as much as width here: the top bar, filmstrip and info
    // sheet all take a fixed slice, so a short window (a landscape phone, or a
    // half-height desktop window) is where they run out of room.
    for (final size in const [
      Size(1200, 420),
      Size(820, 360),
      Size(600, 320),
      Size(400, 300),
    ]) {
      testWidgets(
          'lays out without overflow at ${size.width.toInt()}x'
          '${size.height.toInt()}', (tester) async {
        await pump(tester, size: size);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('top bar shows identity, badges and position', (tester) async {
      await pump(tester);

      expect(find.text('a.png'), findsWidgets);
      expect(find.text('PNG'), findsOneWidget);
      expect(find.text(formatPreviewBytes(files.first.size)), findsWidgets);
      expect(find.text('1 / 4'), findsOneWidget);
      // Filmstrip / info / external / close, plus back and the two chevrons.
      expect(find.byIcon(LucideIcons.galleryHorizontalEnd), findsOneWidget);
      expect(find.byIcon(LucideIcons.info), findsOneWidget);
      expect(find.byIcon(LucideIcons.externalLink), findsOneWidget);
      expect(find.byIcon(LucideIcons.x), findsWidgets);
    });

    testWidgets('badges and counter are shed on a narrow window',
        (tester) async {
      await pump(tester, size: const Size(400, 800));

      expect(find.text('PNG'), findsNothing);
      expect(find.text('1 / 4'), findsNothing);
      // The actions survive — they are what the bar is for.
      expect(find.byIcon(LucideIcons.info), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('prev is disabled on the first file, next on the last',
        (tester) async {
      await pump(tester);
      ShadIconButton buttonFor(IconData icon) => tester.widget<ShadIconButton>(
            find.ancestor(
              of: find.byIcon(icon),
              matching: find.byType(ShadIconButton),
            ),
          );
      expect(buttonFor(LucideIcons.chevronLeft).enabled, isFalse);
      expect(buttonFor(LucideIcons.chevronRight).enabled, isTrue);

      await pump(tester, initialIndex: files.length - 1);
      expect(buttonFor(LucideIcons.chevronLeft).enabled, isTrue);
      expect(buttonFor(LucideIcons.chevronRight).enabled, isFalse);
    });
  });

  group('sibling navigation', () {
    testWidgets('filmstrip is open by default and lists every sibling',
        (tester) async {
      await pump(tester);

      expect(find.byType(PreviewFilmstrip), findsOneWidget);
      // Every sibling gets a tile; the name also appears in the top bar.
      expect(find.text('notes.txt'), findsWidgets);
      expect(find.text('blob.bin'), findsWidgets);
    });

    testWidgets('a lone file gets no filmstrip and no pager', (tester) async {
      await pump(tester, only: [files.first]);

      expect(find.byType(PreviewFilmstrip), findsNothing);
      expect(find.byIcon(LucideIcons.chevronLeft), findsNothing);
      expect(find.byIcon(LucideIcons.galleryHorizontalEnd), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('F toggles the filmstrip', (tester) async {
      await pump(tester);
      expect(find.byType(PreviewFilmstrip), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(PreviewFilmstrip), findsNothing);
    });

    testWidgets('arrow keys page between siblings', (tester) async {
      await pump(tester);
      expect(find.text('1 / 4'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('2 / 4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a filmstrip tile jumps to it', (tester) async {
      await pump(tester);

      // The tile label, not the top-bar title.
      final tile = find.descendant(
        of: find.byType(PreviewFilmstrip),
        matching: find.text('blob.bin'),
      );
      expect(tile, findsOneWidget);
      await tester.tap(tile);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('4 / 4'), findsOneWidget);
    });
  });

  group('info panel', () {
    testWidgets('is closed until asked for, then docks beside the content',
        (tester) async {
      await pump(tester);
      expect(find.byType(PreviewInfoPanel), findsNothing);

      await tester.tap(find.byIcon(LucideIcons.info));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(PreviewInfoPanel), findsOneWidget);
      // Docked, not modal — the viewer is still on screen next to it.
      expect(find.byType(ImageViewer), findsWidgets);
      expect(find.text('Kind'), findsOneWidget);
      expect(find.text('PNG image'), findsOneWidget);
      expect(find.text('Copy path'), findsOneWidget);
    });

    testWidgets('I toggles it too', (tester) async {
      await pump(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PreviewInfoPanel), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PreviewInfoPanel), findsNothing);
    });

    testWidgets('becomes a sheet below the side-panel threshold',
        (tester) async {
      await pump(tester, size: const Size(700, 800));

      await tester.tap(find.byIcon(LucideIcons.info));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Same panel, presented over the top instead of docked.
      expect(find.byType(ShadSheet), findsOneWidget);
      expect(find.byType(PreviewInfoPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('viewers', () {
    testWidgets('routes each file to the viewer for its kind', (tester) async {
      await pump(tester, initialIndex: 0);
      expect(find.byType(ImageViewer), findsWidgets);

      await pump(tester, initialIndex: 1);
      expect(find.byType(TextViewer), findsWidgets);

      await pump(tester, initialIndex: 2);
      expect(find.byType(MarkdownViewer), findsWidgets);

      await pump(tester, initialIndex: 3);
      expect(find.byType(UnsupportedViewer), findsWidgets);
    });

    testWidgets('image viewer offers zoom and rotate, reset gated on state',
        (tester) async {
      await pump(tester, initialIndex: 0);

      expect(find.text('100%'), findsOneWidget);
      expect(find.byIcon(LucideIcons.zoomIn), findsOneWidget);
      expect(find.byIcon(LucideIcons.rotateCw), findsOneWidget);

      ShadIconButton buttonFor(IconData icon) => tester.widget<ShadIconButton>(
            find.ancestor(
              of: find.byIcon(icon),
              matching: find.byType(ShadIconButton),
            ),
          );
      // Nothing to undo yet.
      expect(buttonFor(LucideIcons.rotateCcw).enabled, isFalse);
      expect(buttonFor(LucideIcons.zoomOut).enabled, isFalse);

      await tester.tap(find.byIcon(LucideIcons.zoomIn));
      await tester.pump();

      expect(find.text('125%'), findsOneWidget);
      expect(buttonFor(LucideIcons.rotateCcw).enabled, isTrue);
      expect(buttonFor(LucideIcons.zoomOut).enabled, isTrue);
    });

    testWidgets('text viewer numbers lines and can toggle wrapping',
        (tester) async {
      await pumpRead(tester, initialIndex: 1);

      // Gutter for the three fixture lines — new in the redesign.
      expect(find.text('1'), findsWidgets);
      expect(find.text('3'), findsWidgets);
      expect(find.text('line two'), findsOneWidget);
      expect(find.text('No wrap'), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(PreviewToolbar),
        matching: find.byIcon(LucideIcons.scanText),
      ));
      await tester.pump();

      expect(find.text('Wrapped'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('markdown viewer renders, and can show source', (tester) async {
      await pumpRead(tester, initialIndex: 2);

      expect(find.text('Rendered'), findsOneWidget);
      expect(find.text('Title'), findsWidgets);

      // fileCode is also the filmstrip glyph for notes.txt, so scope the tap
      // to the viewer's own toolbar.
      await tester.tap(find.descendant(
        of: find.byType(PreviewToolbar),
        matching: find.byIcon(LucideIcons.fileCode),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Source'), findsOneWidget);
      // Raw source shows the markup itself.
      expect(find.textContaining('# Title'), findsOneWidget);
    });

    testWidgets('unsupported file explains itself and offers an escape hatch',
        (tester) async {
      await pump(tester, initialIndex: 3);

      expect(find.textContaining('No inline preview'), findsOneWidget);
      expect(find.text('Open in external app'), findsOneWidget);
    });
  });

  group('loading state', () {
    testWidgets('spinner is centred in the content area at rest',
        (tester) async {
      // A plain pump (no runAsync) leaves the text viewer's file read pending,
      // so it stays in its loading state for the whole test. Deliberately not
      // an archive: that decodes via compute(), and the stranded isolate hangs
      // the run at teardown.
      await pump(tester, initialIndex: 1, size: const Size(1000, 800));

      expect(find.byType(TextViewer), findsWidgets);
      expect(find.byType(ShadSpinner), findsWidgets);
      // Guards the framing of every viewer's loading state: PreviewLoading is a
      // Center, so a settled page puts the spinner on the content area's
      // vertical axis. The filmstrip sits below the content, not beside it, so
      // that axis is the window's.
      final dx = tester.getCenter(find.byType(ShadSpinner).first).dx;
      expect(dx, closeTo(500, 1));
    });
  });

  group('shared helpers', () {
    test('byte formatting agrees across the preview', () {
      expect(formatPreviewBytes(512), '512 B');
      expect(formatPreviewBytes(2048), '2.00 KB');
      expect(formatPreviewBytes(1024 * 1024 * 5), '5.00 MB');
      expect(formatPreviewBytes(1536, exact: true), '1.50 KB (1536 bytes)');
    });

    test('duration formatting only shows hours when there are any', () {
      expect(formatPreviewDuration(const Duration(seconds: 5)), '00:05');
      expect(formatPreviewDuration(const Duration(minutes: 3, seconds: 7)),
          '03:07');
      expect(formatPreviewDuration(const Duration(hours: 1, minutes: 2)),
          '1:02:00');
    });

    test('compound archive suffixes route as one extension', () {
      final entry = FileEntry(
        path: '/tmp/bundle.tar.gz',
        name: 'bundle.tar.gz',
        isDirectory: false,
        size: 10,
        modified: DateTime(2026),
      );
      expect(normalisedExt(entry), '.tar.gz');
      expect(previewKindFor(entry), PreviewKind.archive);
    });
  });
}
