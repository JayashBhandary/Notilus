import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
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
import 'package:notilus/widgets/info_panel.dart';
import 'package:notilus/widgets/sidebar.dart';

/// The app's two side panes, migrated to shadcn.
///
/// Both are hand-composed rather than built on a library component: shadcn_ui
/// 0.56 ships no sidebar. What this guards is that they read from ShadTheme,
/// carry Lucide glyphs, and keep selected distinguishable from hovered.
class _StubBrowser extends BrowserProvider {
  _StubBrowser({this.selection, this.view = CenterView.files})
      : super(FileService());

  final FileEntry? selection;
  final CenterView view;

  int refreshDriveCalls = 0;
  final List<CenterView> shownViews = [];

  @override
  List<DriveEntry> get drives => [
        DriveEntry(name: 'Macintosh HD', path: '/', isRoot: true),
        DriveEntry(name: 'Backup', path: '/Volumes/Backup'),
      ];

  @override
  Map<String, String?> get shortcuts => const {
        'Home': '/Users/test',
        'Desktop': '/Users/test/Desktop',
        'Documents': '/Users/test/Documents',
        'Downloads': '/Users/test/Downloads',
      };

  @override
  CenterView get centerView => view;

  @override
  String get currentPath => '/';

  @override
  FileEntry? get primarySelection => selection;

  @override
  Future<void> refreshDrives() async => refreshDriveCalls++;

  @override
  void showCenterView(CenterView view) => shownViews.add(view);
}

void main() {
  late Directory tmp;

  /// Builds a [FileEntry] without awaiting.
  ///
  /// `FileEntry.from` awaits `stat()`, and real I/O never resolves inside
  /// testWidgets' fake-async zone — awaiting it hangs the test until the
  /// harness gives up. Sync stat is fine here.
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
    tmp = await Directory.systemTemp.createTemp('notilus_sidebars_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Widget host(
    Widget child,
    BrowserProvider browser, {
    Brightness brightness = Brightness.light,
  }) {
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
        home: ChangeNotifierProvider<BrowserProvider>.value(
          value: browser,
          // Mirrors _WideLayout: both panes are fixed-width children of a Row
          // with crossAxisAlignment.stretch. A default Row would centre them
          // and hand them unbounded height, which the info panel's scroll view
          // cannot lay out.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [child],
          ),
        ),
      ),
    );
  }

  Future<void> pump(
    WidgetTester tester,
    Widget child,
    BrowserProvider browser, {
    Size size = const Size(900, 800),
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(child, browser, brightness: brightness));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('left sidebar', () {
    for (final brightness in Brightness.values) {
      testWidgets('lays out without overflow ($brightness)', (tester) async {
        await pump(tester, const Sidebar(), _StubBrowser(),
            brightness: brightness);
        expect(tester.takeException(), isNull);
      });
    }

    // 180 is the narrow-window width the wide layout drops to below 1000px.
    testWidgets('lays out without overflow at its narrow width',
        (tester) async {
      await pump(tester, const Sidebar(width: 180), _StubBrowser());
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders every section with Lucide glyphs', (tester) async {
      await pump(tester, const Sidebar(), _StubBrowser());

      expect(find.text('System'), findsOneWidget);
      expect(find.text('Media'), findsOneWidget);
      expect(find.text('Favorites'), findsOneWidget);
      expect(find.text('Locations'), findsOneWidget);
      expect(find.text('Tags'), findsOneWidget);

      // System pages.
      expect(find.byIcon(LucideIcons.gauge), findsOneWidget);
      expect(find.byIcon(LucideIcons.copy), findsOneWidget);
      expect(find.byIcon(LucideIcons.arrowDownUp), findsOneWidget);
      // Media libraries. "Documents" is deliberately ambiguous in the tree —
      // the media page and the home-folder shortcut share the word — so the
      // rows are matched by their glyphs.
      expect(find.text('Images'), findsOneWidget);
      expect(find.text('Videos'), findsOneWidget);
      expect(find.text('Documents'), findsNWidgets(2));
      expect(find.byIcon(LucideIcons.image), findsOneWidget);
      expect(find.byIcon(LucideIcons.film), findsOneWidget);
      // One for the media library, one for the Documents shortcut.
      expect(find.byIcon(LucideIcons.fileText), findsNWidgets(2));
      // Shortcuts.
      expect(find.byIcon(LucideIcons.house), findsOneWidget);
      expect(find.byIcon(LucideIcons.monitor), findsOneWidget);
      // Drives: root gets a laptop, a mounted volume a hard drive. The old
      // code reached into Material for Icons.storage here.
      expect(find.byIcon(LucideIcons.laptop), findsOneWidget);
      expect(find.byIcon(LucideIcons.hardDrive), findsOneWidget);
      expect(find.byIcon(LucideIcons.refreshCw), findsOneWidget);
    });

    testWidgets('selection is styled distinctly from the unselected rows',
        (tester) async {
      // Duplicate Finder is the active page.
      await pump(
        tester,
        const Sidebar(),
        _StubBrowser(view: CenterView.duplicates),
      );

      // The selected row keeps AppPalette.sidebarSelected — shadcn's `accent`
      // is the *hover* surface, so reusing it would erase the distinction.
      final selectedBg = AppPalette.light.sidebarSelected;
      final decorated = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.decoration is BoxDecoration)
          .map((c) => (c.decoration! as BoxDecoration).color)
          .toList();
      expect(decorated, contains(selectedBg));
      // Exactly one row is selected at a time.
      expect(decorated.where((c) => c == selectedBg).length, 1);
    });

    testWidgets('the Locations refresh control reaches the provider',
        (tester) async {
      final browser = _StubBrowser();
      await pump(tester, const Sidebar(), browser);

      await tester.tap(find.byIcon(LucideIcons.refreshCw));
      await tester.pump();

      expect(browser.refreshDriveCalls, 1);
    });

    testWidgets('a Media row switches the center pane to that library',
        (tester) async {
      final browser = _StubBrowser();
      await pump(tester, const Sidebar(), browser);

      await tester.tap(find.text('Videos'));
      await tester.pump();

      expect(browser.shownViews, [CenterView.mediaVideos]);
    });

    testWidgets('the active Media library is the only selected row',
        (tester) async {
      await pump(
        tester,
        const Sidebar(),
        _StubBrowser(view: CenterView.mediaImages),
      );

      final selectedBg = AppPalette.light.sidebarSelected;
      final selected = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.decoration is BoxDecoration)
          .map((c) => (c.decoration! as BoxDecoration).color)
          .where((c) => c == selectedBg);
      expect(selected.length, 1);
    });

    testWidgets('Tags rows render but are inert', (tester) async {
      await pump(tester, const Sidebar(), _StubBrowser());

      // Seven colour rows, kept because they already shipped. Tapping one must
      // not throw even though nothing is wired behind it.
      for (final name in ['Red', 'Orange', 'Yellow', 'Green', 'Blue']) {
        expect(find.text(name), findsOneWidget);
      }
      await tester.tap(find.text('Red'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('right sidebar — info tab', () {
    testWidgets('empty state prompts for a selection', (tester) async {
      await pump(
        tester,
        const SizedBox(width: 400, child: InfoPanel()),
        _StubBrowser(),
      );

      expect(find.text('Select a file to see details'), findsOneWidget);
      expect(find.byIcon(LucideIcons.info), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final brightness in Brightness.values) {
      testWidgets('details lay out without overflow ($brightness)',
          (tester) async {
        final f = File('${tmp.path}/report.pdf')..writeAsBytesSync([1, 2, 3]);
        final entry = entryFor(f);
        await pump(
          tester,
          const SizedBox(width: 400, child: InfoPanel()),
          _StubBrowser(selection: entry),
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('details show kind, size and location', (tester) async {
      final f = File('${tmp.path}/report.pdf')
        ..writeAsBytesSync(List<int>.filled(2048, 0));
      final entry = entryFor(f);
      await pump(
        tester,
        const SizedBox(width: 400, child: InfoPanel()),
        _StubBrowser(selection: entry),
      );

      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('Information'), findsOneWidget);
      expect(find.text('Modified'), findsOneWidget);
      expect(find.text('Where'), findsOneWidget);
      expect(find.text('Kind'), findsOneWidget);
      expect(find.text('Extension'), findsOneWidget);
      // Uses the app-wide formatBytes, not the preview's own formatter, so the
      // panel agrees with the status bar and the duplicate finder.
      expect(find.text('2 KB'), findsWidgets);
    });

    // 320px is what the right panel shrinks to below a 1100px window — the
    // width that overflowed the ShadTabs header earlier in the migration.
    testWidgets('details survive the narrow 320px panel width',
        (tester) async {
      final f = File('${tmp.path}/a-rather-long-file-name.pdf')
        ..writeAsBytesSync([1]);
      final entry = entryFor(f);
      await pump(
        tester,
        const SizedBox(width: 320, child: InfoPanel()),
        _StubBrowser(selection: entry),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a folder shows the folder glyph and no size row',
        (tester) async {
      final d = Directory('${tmp.path}/somefolder')..createSync();
      final entry = entryFor(d, isDirectory: true);
      await pump(
        tester,
        const SizedBox(width: 400, child: InfoPanel()),
        _StubBrowser(selection: entry),
      );

      expect(find.text('Folder'), findsWidgets);
      expect(find.byIcon(LucideIcons.folder), findsOneWidget);
      expect(find.text('Size'), findsNothing);
    });

    testWidgets('an image renders a thumbnail rather than the placeholder',
        (tester) async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAF'
        'AAH/q842iQAAAABJRU5ErkJggg==',
      );
      final f = File('${tmp.path}/pic.png')..writeAsBytesSync(png);
      final entry = entryFor(f);
      await pump(
        tester,
        const SizedBox(width: 400, child: InfoPanel()),
        _StubBrowser(selection: entry),
      );

      expect(find.byType(Image), findsOneWidget);
      // The generic file glyph belongs to the placeholder path.
      expect(find.byIcon(LucideIcons.file), findsNothing);
    });

    testWidgets('an unknown type falls back to a glyph plus extension badge',
        (tester) async {
      final f = File('${tmp.path}/thing.xyz')..writeAsBytesSync([1]);
      final entry = entryFor(f);
      await pump(
        tester,
        const SizedBox(width: 400, child: InfoPanel()),
        _StubBrowser(selection: entry),
      );

      expect(find.byIcon(LucideIcons.file), findsOneWidget);
      expect(find.text('XYZ'), findsOneWidget);
    });
  });
}
