import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart'
    show CupertinoApp, CupertinoSearchTextField, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:notilus/models/file_entry.dart';
import 'package:notilus/models/media_kind.dart';
import 'package:notilus/providers/file_ops_provider.dart';
import 'package:notilus/providers/media_provider.dart';
import 'package:notilus/screens/media_screen.dart';
import 'package:notilus/theme.dart';

/// The media library pages. The scan is stubbed out with [seedEntries] — what
/// these cover is the page around it: the title and count line, the filter and
/// grouping controls, and the selection bar.
void main() {
  late Directory tmp;
  late MediaProvider media;

  FileEntry entryFor(File f, DateTime modified) => FileEntry(
        path: f.path,
        name: f.path.split(Platform.pathSeparator).last,
        isDirectory: false,
        size: f.statSync().size,
        modified: modified,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('notilus_media_test');
    media = MediaProvider();
  });

  tearDown(() async {
    media.dispose();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// A 1x1 PNG — enough for Image.file to decode rather than error out.
  File png(String name) {
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAF'
      'AAH/q842iQAAAABJRU5ErkJggg==',
    );
    return File('${tmp.path}/$name')..writeAsBytesSync(bytes);
  }

  Widget host(Widget child, {Brightness brightness = Brightness.light}) {
    return ShadApp.custom(
      theme: AppTheme.shadThemeFor(Brightness.light),
      darkTheme: AppTheme.shadThemeFor(Brightness.dark),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      appBuilder: (_) => CupertinoApp(
        localizationsDelegates: const [
          GlobalShadLocalizations.delegate,
          DefaultMaterialLocalizations.delegate,
          DefaultCupertinoLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        builder: (_, inner) => ShadAppBuilder(child: inner!),
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<MediaProvider>.value(value: media),
            ChangeNotifierProvider(create: (_) => FileOpsProvider()),
          ],
          child: child,
        ),
      ),
    );
  }

  Future<void> pump(
    WidgetTester tester,
    MediaKind kind, {
    Size size = const Size(1000, 800),
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(MediaView(kind: kind), brightness: brightness),
    );
    // Lets the post-frame scan kick-off and the roots load resolve.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  void seedImages() {
    media.seedEntries(MediaKind.images, [
      entryFor(png('beach.png'), DateTime(2026, 8, 3)),
      entryFor(png('alps.png'), DateTime(2026, 3, 14)),
      entryFor(png('cat.png'), DateTime(2025, 8, 20)),
    ]);
  }

  group('page chrome', () {
    testWidgets('shows the title and the count for the kind', (tester) async {
      seedImages();
      await pump(tester, MediaKind.images);

      expect(find.text('Images'), findsOneWidget);
      expect(find.text('3 images'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('singular count reads naturally', (tester) async {
      media.seedEntries(MediaKind.videos, [
        entryFor(png('clip.mp4'), DateTime(2026, 1, 2)),
      ]);
      await pump(tester, MediaKind.videos);

      expect(find.text('1 video'), findsOneWidget);
    });

    testWidgets('carries search, sort, grouping, view and select controls',
        (tester) async {
      seedImages();
      await pump(tester, MediaKind.images);

      expect(find.byType(CupertinoSearchTextField), findsOneWidget);
      for (final label in ['Name', 'Date', 'Size']) {
        expect(find.text(label), findsOneWidget);
      }
      for (final label in ['All', 'Years', 'Months']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.byIcon(LucideIcons.layoutGrid), findsOneWidget);
      expect(find.byIcon(LucideIcons.list), findsOneWidget);
      expect(find.text('Select'), findsOneWidget);
    });

    for (final brightness in Brightness.values) {
      testWidgets('lays out without overflow ($brightness)', (tester) async {
        seedImages();
        await pump(tester, MediaKind.images, brightness: brightness);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the controls strip wraps instead of overflowing when narrow',
        (tester) async {
      seedImages();
      await pump(tester, MediaKind.images, size: const Size(420, 800));
      expect(tester.takeException(), isNull);
    });
  });

  group('filtering and grouping', () {
    testWidgets('typing filters the listing and the count line',
        (tester) async {
      seedImages();
      await pump(tester, MediaKind.images);

      await tester.enterText(find.byType(CupertinoSearchTextField), 'cat');
      await tester.pump();

      expect(find.text('1 of 3 images'), findsOneWidget);
      expect(find.text('cat.png'), findsOneWidget);
      expect(find.text('beach.png'), findsNothing);
    });

    testWidgets('an empty result explains itself and offers a way back',
        (tester) async {
      seedImages();
      await pump(tester, MediaKind.images);

      await tester.enterText(find.byType(CupertinoSearchTextField), 'zzz');
      await tester.pump();

      expect(find.text('No matches'), findsOneWidget);
      expect(find.text('Clear search'), findsOneWidget);
    });

    testWidgets('grouping by year renders a header per year', (tester) async {
      seedImages();
      await pump(tester, MediaKind.images);

      await tester.tap(find.text('Years'));
      await tester.pump();

      expect(find.text('2026'), findsOneWidget);
      expect(find.text('2025'), findsOneWidget);
    });

    testWidgets('grouping by month labels the year alongside the month',
        (tester) async {
      seedImages();
      await pump(tester, MediaKind.images);

      await tester.tap(find.text('Months'));
      await tester.pump();

      expect(find.text('August 2026'), findsOneWidget);
      expect(find.text('August 2025'), findsOneWidget);
    });
  });

  group('selection', () {
    testWidgets('Select reveals the bulk actions', (tester) async {
      seedImages();
      await pump(tester, MediaKind.images);

      await tester.tap(find.text('Select'));
      await tester.pump();

      expect(find.text('Nothing selected'), findsOneWidget);
      for (final label in [
        'Select all',
        'Copy to…',
        'Move to…',
        'Send',
        'Compress',
        'Trash',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('Select all reports the count it acted on', (tester) async {
      seedImages();
      await pump(tester, MediaKind.images);

      await tester.tap(find.text('Select'));
      await tester.pump();
      await tester.tap(find.text('Select all'));
      await tester.pump();

      expect(find.text('3 selected'), findsOneWidget);
    });

    testWidgets('Cancel leaves selection mode and hides the bar',
        (tester) async {
      seedImages();
      await pump(tester, MediaKind.images);

      await tester.tap(find.text('Select'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pump();

      expect(find.text('Nothing selected'), findsNothing);
      expect(find.text('Select'), findsOneWidget);
    });
  });

  group('thumbnails', () {
    // No path_provider mock here on purpose: the thumbnail cache is
    // unreachable, which is exactly the "this machine can't render it" path.
    testWidgets('video tiles carry a play badge whether or not a frame renders',
        (tester) async {
      media.seedEntries(MediaKind.videos, [
        entryFor(png('a.mp4'), DateTime(2026, 5, 1)),
        entryFor(png('b.mov'), DateTime(2026, 5, 2)),
      ]);
      await pump(tester, MediaKind.videos);

      expect(find.byIcon(LucideIcons.play), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a format with no renderer falls back to the kind glyph',
        (tester) async {
      media.seedEntries(MediaKind.documents, [
        entryFor(png('contract.docx'), DateTime(2026, 5, 1)),
      ]);
      await pump(tester, MediaKind.documents);

      // One in the page header, one standing in for the missing preview.
      expect(find.byIcon(LucideIcons.fileText), findsNWidgets(2));
      expect(find.text('DOCX'), findsNothing); // list rows omit the badge
      expect(tester.takeException(), isNull);
    });

    testWidgets('the grid labels an unpreviewable document with its type',
        (tester) async {
      media.seedEntries(MediaKind.documents, [
        entryFor(png('contract.docx'), DateTime(2026, 5, 1)),
      ]);
      await pump(tester, MediaKind.documents);

      await tester.tap(find.byIcon(LucideIcons.layoutGrid));
      await tester.pumpAndSettle();

      expect(find.text('DOCX'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('images still render directly from disk', (tester) async {
      seedImages();
      await pump(tester, MediaKind.images);

      expect(find.byType(Image), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });
  });

  group('label toggle', () {
    testWidgets('hides the name and date, leaving a wall of thumbnails',
        (tester) async {
      seedImages();
      await pump(tester, MediaKind.images);

      expect(find.text('beach.png'), findsOneWidget);

      await tester.tap(find.byIcon(LucideIcons.captions));
      await tester.pumpAndSettle();

      expect(find.text('beach.png'), findsNothing);
      expect(find.text('alps.png'), findsNothing);
      // The thumbnails themselves stay — this hides labels, not content.
      expect(find.byType(Image), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggles back', (tester) async {
      seedImages();
      await pump(tester, MediaKind.images);

      await tester.tap(find.byIcon(LucideIcons.captions));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(LucideIcons.captionsOff));
      await tester.pumpAndSettle();

      expect(find.text('beach.png'), findsOneWidget);
    });

    testWidgets('selection still reads on a bare tile', (tester) async {
      seedImages();
      await pump(tester, MediaKind.images);

      await tester.tap(find.byIcon(LucideIcons.captions));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select'));
      await tester.pump();
      await tester.tap(find.text('Select all'));
      await tester.pump();

      expect(find.text('3 selected'), findsOneWidget);
      // One check mark per selected tile, drawn over the image.
      expect(find.byIcon(LucideIcons.check), findsNWidgets(4)); // +Done button
      expect(tester.takeException(), isNull);
    });

    testWidgets('the list view offers no label toggle', (tester) async {
      media.seedEntries(MediaKind.documents, [
        entryFor(png('notes.pdf'), DateTime(2026, 5, 1)),
      ]);
      await pump(tester, MediaKind.documents);

      // A row is nothing but its label, so the control would be a no-op.
      expect(find.byIcon(LucideIcons.captions), findsNothing);

      await tester.tap(find.byIcon(LucideIcons.layoutGrid));
      await tester.pumpAndSettle();
      expect(find.byIcon(LucideIcons.captions), findsOneWidget);
    });

    testWidgets('gallery tiles lay out without overflow when narrow',
        (tester) async {
      seedImages();
      await pump(tester, MediaKind.images, size: const Size(420, 800));

      await tester.tap(find.byIcon(LucideIcons.captions));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('empty states', () {
    testWidgets('a library with nothing in it points at the folder settings',
        (tester) async {
      media.seedEntries(MediaKind.documents, const []);
      await pump(tester, MediaKind.documents);

      expect(find.text('No documents found'), findsOneWidget);
      expect(find.text('Change folders'), findsOneWidget);
    });
  });
}
