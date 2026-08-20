import 'dart:io';

import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/gestures.dart';
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

/// Trackpad two-finger scroll must scroll and nothing else.
///
/// Flutter hands trackpad gestures to drag recognizers as pan-zoom events, so
/// the marquee's pan detector was starting a rubber-band on every scroll — a
/// scroll through a folder left every file it passed selected.
class _StubBrowser extends BrowserProvider {
  _StubBrowser({required this.items}) : super(FileService());

  final List<FileEntry> items;

  @override
  List<EntryGroup> groupedEntries() =>
      [EntryGroup(label: null, entries: items)];
}

void main() {
  late Directory tmp;
  late List<FileEntry> files;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('notilus_marquee_test');
    files = [
      // Enough to overflow the viewport, so there is somewhere to scroll to.
      for (var i = 0; i < 120; i++)
        () {
          final f = File('${tmp.path}/file-$i.bin')..writeAsBytesSync([1]);
          final stat = f.statSync();
          return FileEntry(
            path: f.path,
            name: 'file-$i.bin',
            isDirectory: false,
            size: stat.size,
            modified: stat.modified,
          );
        }(),
    ];
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<MarqueeController> pump(
    WidgetTester tester,
    BrowserProvider browser,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Desktop widths: what the file views set when marquee selection is live.
    final marquee = MarqueeController()..enabled = true;
    addTearDown(marquee.dispose);

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
              Provider<MarqueeController>.value(value: marquee),
            ],
            child: MarqueeSelectionLayer(
              controller: marquee,
              child: FileIconGrid(onSecondaryRowTap: (_, __) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return marquee;
  }

  testWidgets('a trackpad two-finger scroll scrolls without selecting',
      (tester) async {
    final browser = _StubBrowser(items: files);
    final marquee = await pump(tester, browser);
    expect(browser.selectedPaths, isEmpty);

    final centre = tester.getCenter(find.byType(FileIconGrid));
    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await gesture.panZoomStart(centre);
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      // Fingers moving up: content scrolls down, as on a real trackpad. The
      // sideways component is the drift any real two-finger scroll has, and is
      // what gave the buggy rubber-band a box with area.
      await gesture.panZoomUpdate(
        centre,
        pan: Offset(-8.0 * (i + 1), -40.0 * (i + 1)),
      );
      await tester.pump();
      // No rubber-band at any point during the scroll.
      expect(find.byKey(marqueeOverlayKey), findsNothing);
    }
    await gesture.panZoomEnd();
    await tester.pump();

    expect(marquee.scroll.offset, greaterThan(0));
    expect(browser.selectedPaths, isEmpty);
  });

  testWidgets('a mouse drag still rubber-band selects', (tester) async {
    // A short folder, so there is blank space under the single row — where a
    // rubber-band drag actually starts. A drag begun *on* a tile is a
    // file drag, which is a different gesture.
    final browser = _StubBrowser(items: files.take(5).toList());
    await pump(tester, browser);

    final gesture = await tester.startGesture(
      const Offset(700, 500),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(-120, -92));
      await tester.pump();
    }

    expect(find.byKey(marqueeOverlayKey), findsOneWidget);
    expect(browser.selectedPaths, isNotEmpty);

    await gesture.up();
    await tester.pump();
  });

  testWidgets('a mouse wheel scroll does not select either', (tester) async {
    final browser = _StubBrowser(items: files);
    final marquee = await pump(tester, browser);

    final centre = tester.getCenter(find.byType(FileIconGrid));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(centre);
    await tester.sendEventToBinding(
      pointer.scroll(const Offset(0, 220)),
    );
    await tester.pump();

    expect(marquee.scroll.offset, greaterThan(0));
    expect(browser.selectedPaths, isEmpty);
  });
}
