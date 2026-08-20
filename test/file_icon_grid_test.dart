import 'dart:io';

import 'package:flutter/cupertino.dart'
    show CupertinoApp, CupertinoIcons, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/models/file_entry.dart';
import 'package:notilus/providers/browser_provider.dart';
import 'package:notilus/services/file_service.dart';
import 'package:notilus/theme.dart';
import 'package:notilus/widgets/file_icon_grid.dart';
import 'package:notilus/widgets/marquee_selection.dart';

/// Guards the icon grid's tile geometry.
///
/// The grid delegate is handed a cell *height* while each tile builds its own
/// content, so the two have to agree. They previously did not: cells were forced
/// square via `childAspectRatio: 1.0` while a tile's content was far shorter,
/// leaving dead space under every label that showed up as a selection highlight
/// running past the filename.
class _StubBrowser extends BrowserProvider {
  _StubBrowser({
    required this.items,
    this.density = 1.0,
    this.iconScale = 1.0,
  }) : super(FileService());

  final List<FileEntry> items;
  final double density;
  final double iconScale;

  @override
  List<EntryGroup> groupedEntries() =>
      [EntryGroup(label: null, entries: items)];

  @override
  Set<String> get selectedPaths => const {};

  @override
  double get rowDensity => density;

  @override
  double get gridIconScale => iconScale;
}

void main() {
  late Directory tmp;
  late List<FileEntry> files;

  FileEntry entryFor(FileSystemEntity e, {bool isDirectory = false}) {
    final stat = e.statSync();
    return FileEntry(
      path: e.path,
      name: e.path.split(Platform.pathSeparator).last,
      isDirectory: isDirectory,
      size: stat.size,
      modified: stat.modified,
    );
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('notilus_grid_test');
    files = [
      for (final n in ['a.bin', 'b.bin', 'c.bin', 'd.bin', 'e.bin'])
        entryFor(File('${tmp.path}/$n')..writeAsBytesSync([1, 2, 3])),
      entryFor(
        File('${tmp.path}/a-very-long-file-name-that-must-wrap-twice.bin')
          ..writeAsBytesSync([1]),
      ),
    ];
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester,
    BrowserProvider browser, {
    Size size = const Size(900, 700),
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ShadApp.custom(
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
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<BrowserProvider>.value(value: browser),
              Provider<MarqueeController>(create: (_) => MarqueeController()),
            ],
            child: Builder(
              builder: (ctx) => MediaQuery(
                data: MediaQuery.of(ctx)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: FileIconGrid(onSecondaryRowTap: (_, __) {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('lays out without overflow', (tester) async {
    await pump(tester, _StubBrowser(items: files));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the extension placeholder survives a large text scale',
      (tester) async {
    // The thumbnail square is a fixed size, but the extension label under its
    // glyph follows the platform text scale — at a desktop scale past 1.0 the
    // pair grew taller than the square and the Column overflowed.
    await pump(tester, _StubBrowser(items: files), textScale: 2.0);
    expect(tester.takeException(), isNull);
    // The label is still there, not clipped away to make room.
    expect(find.text('BIN'), findsWidgets);
  });

  testWidgets('a tile is no taller than the content it holds', (tester) async {
    await pump(tester, _StubBrowser(items: files));

    // The tile's own box, i.e. the thing the selection highlight paints.
    final tile = tester.getRect(find.byType(GridView).first).height;
    expect(tile, greaterThan(0));

    // Every cell should be about gridTileHeight, not a square of the cell
    // width. At 900px wide the old square cells were ~96px tall.
    final expected = gridTileHeight(1.0);
    final cellRect = tester.getRect(
      find
          .ancestor(
            of: find.text('a.bin'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(cellRect.height, closeTo(expected, 1.5));
  });

  testWidgets('a two-line name leaves no slack under its label',
      (tester) async {
    await pump(tester, _StubBrowser(items: files));

    const longName = 'a-very-long-file-name-that-must-wrap-twice.bin';
    final label = tester.getRect(find.text(longName));
    final cell = tester.getRect(
      find
          .ancestor(
            of: find.text(longName),
            matching: find.byType(Container),
          )
          .first,
    );
    // A name that fills both reserved lines should bottom out against the
    // tile's own 2px padding — nothing like the ~34px the square cells left.
    expect(cell.bottom - label.bottom, lessThan(6));
  });

  testWidgets('a one-line name leaves exactly the reserved second line',
      (tester) async {
    await pump(tester, _StubBrowser(items: files));

    final label = tester.getRect(find.text('a.bin'));
    final cell = tester.getRect(
      find
          .ancestor(
            of: find.text('a.bin'),
            matching: find.byType(Container),
          )
          .first,
    );
    // Slack here is intentional and bounded: the height reserves two label
    // lines so every cell in the grid is the same height regardless of name
    // length. One unused line plus padding, and no more.
    const oneLine = kGridLabelSize * 1.2;
    expect(cell.bottom - label.bottom, lessThan(oneLine + 6));
  });

  testWidgets('icon and label use the shared tile metrics', (tester) async {
    await pump(tester, _StubBrowser(items: files));

    final labelStyle = tester.widget<Text>(find.text('a.bin')).style!;
    expect(labelStyle.fontSize, kGridLabelSize);
    // Tightened from the previous 11.5 / 52.
    expect(kGridLabelSize, lessThan(11.5));
    expect(kGridIconSize, lessThan(52));
  });

  testWidgets('tile height tracks row density', (tester) async {
    await pump(tester, _StubBrowser(items: files, density: 1.4));

    final cell = tester.getRect(
      find
          .ancestor(
            of: find.text('a.bin'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(cell.height, closeTo(gridTileHeight(1.4), 1.5));
    // Only the thumbnail scales, so a denser setting is not proportionally
    // taller — the label is a fixed two lines.
    expect(gridTileHeight(1.4), lessThan(gridTileHeight(1.0) * 1.4));
  });

  testWidgets('a large icon size grows the cell in both directions',
      (tester) async {
    await pump(tester, _StubBrowser(items: files, iconScale: 3.2));

    final cell = tester.getRect(
      find
          .ancestor(
            of: find.text('a.bin'),
            matching: find.byType(Container),
          )
          .first,
    );
    // The delegate and the tile still agree, at a scale far past what row
    // density reaches.
    expect(cell.height, closeTo(gridTileHeight(1.0, iconScale: 3.2), 1.5));
    expect(cell.height, greaterThan(gridTileHeight(1.0) * 2));
    // And the cell is wide enough for the thumbnail it now holds, so
    // neighbouring tiles don't overlap.
    expect(cell.width, greaterThan(gridIconEdge(1.0, 3.2)));
  });

  testWidgets('a video tile is marked playable and falls back to a glyph',
      (tester) async {
    // The frame comes from ThumbnailService, which shells out to ffmpeg and
    // may find nothing here — a fixture that is not really h264, or a machine
    // with no renderer. Either way the tile has to read as a video straight
    // away, which is what the badge over the placeholder is for.
    final clip = entryFor(
      File('${tmp.path}/clip.mp4')..writeAsStringSync('not really a video'),
    );
    await pump(tester, _StubBrowser(items: [clip]));

    expect(find.byIcon(CupertinoIcons.play_fill), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.film), findsOneWidget);
    expect(find.text('MP4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long name wraps to two lines without changing tile height',
      (tester) async {
    await pump(tester, _StubBrowser(items: files));

    final short = tester.getRect(
      find
          .ancestor(
            of: find.text('a.bin'),
            matching: find.byType(Container),
          )
          .first,
    );
    final long = tester.getRect(
      find
          .ancestor(
            of: find.text('a-very-long-file-name-that-must-wrap-twice.bin'),
            matching: find.byType(Container),
          )
          .first,
    );
    // Cell height is uniform: gridTileHeight already reserves two label lines.
    expect(long.height, closeTo(short.height, 0.5));
    expect(tester.takeException(), isNull);
  });
}
