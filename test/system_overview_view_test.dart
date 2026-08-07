import 'dart:io';

import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/providers/browser_provider.dart';
import 'package:notilus/providers/settings_provider.dart';
import 'package:notilus/screens/system_overview_screen.dart';
import 'package:notilus/services/file_service.dart';
import 'package:notilus/services/system_info_service.dart';
import 'package:notilus/services/settings_store.dart';
import 'package:notilus/theme.dart';
import 'package:notilus/widgets/skeleton.dart';

/// Canned storage stats. The real service spawns `df`, whose future never
/// completes under the tester's fake async — the page would sit on its skeleton
/// forever and leave the probe timeout pending at teardown.
class _FakeInfoService extends SystemInfoService {
  _FakeInfoService() : super(FileService());

  @override
  Future<List<DiskUsage>> diskUsages() async => [
        DiskUsage(
          name: 'System',
          path: '/',
          totalBytes: 500 * 1024 * 1024 * 1024,
          usedBytes: 365 * 1024 * 1024 * 1024,
          freeBytes: 135 * 1024 * 1024 * 1024,
          isRoot: true,
        ),
        DiskUsage(
          name: 'Backup',
          path: '/media/backup',
          totalBytes: 2 * 1024 * 1024 * 1024,
          usedBytes: 1024 * 1024 * 1024,
          freeBytes: 1024 * 1024 * 1024,
          isRemovable: true,
        ),
      ];

  @override
  Future<CategoryBreakdown> shallowBreakdown(String label, String path) async =>
      CategoryBreakdown(
        label: label,
        path: path,
        slices: const {
          FileCategory.images: CategorySlice(files: 12, bytes: 4 * 1024 * 1024),
          FileCategory.videos: CategorySlice(files: 1, bytes: 900 * 1024 * 1024),
          FileCategory.documents: CategorySlice(files: 4, bytes: 32 * 1024),
        },
      );
}

/// The System Overview page is a scrolling grid of shadcn cards whose widths
/// come from a hand-rolled responsive grid, so the failure modes to guard are
/// (a) a row that lays out to nothing because its cross-axis constraint is
/// unbounded, and (b) an overflow at a narrow width.
///
/// The folder snapshot reads `shortcuts` off [BrowserProvider], which the real
/// provider only fills in from the host filesystem during `init()`. This stub
/// starts empty and publishes the map later — exactly the ordering that used to
/// leave the page stuck on "No shortcut folders available".
class _StubBrowser extends BrowserProvider {
  _StubBrowser() : super(FileService());

  Map<String, String?> _shortcuts = const {};

  @override
  Map<String, String?> get shortcuts => _shortcuts;

  void publish(Map<String, String?> value) {
    _shortcuts = value;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('notilus_overview_test');
    File('${tmp.path}/note.txt').writeAsStringSync('x' * 128);
    File('${tmp.path}/clip.mp4').writeAsStringSync('y' * 4096);
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Widget host(
    Widget child, {
    Brightness brightness = Brightness.light,
    BrowserProvider? browser,
  }) {
    return ShadApp.custom(
      theme: AppTheme.shadThemeFor(Brightness.light),
      darkTheme: AppTheme.shadThemeFor(Brightness.dark),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      // Mirrors app.dart: ShadApp.custom wraps CupertinoApp, ShadAppBuilder
      // goes in `builder`, and content in `home` — so showShadDialog and
      // ShadToaster both find an ancestor to attach to.
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
            ChangeNotifierProvider<BrowserProvider>(
              create: (_) => browser ?? _StubBrowser(),
            ),
            ChangeNotifierProvider<SettingsProvider>(
              create: (_) => SettingsProvider(SettingsStore()),
            ),
          ],
          child: child,
        ),
      ),
    );
  }

  /// The injected service resolves on microtasks, so two pumps are enough:
  /// one for the disk future, one for the folder scan.
  Future<void> settleProbe(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  testWidgets('swaps the skeleton for real cards once the probe resolves',
      (tester) async {
    // Tall enough that every section builds — a ListView only creates the
    // children it can lay out.
    tester.view.physicalSize = const Size(1070, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(SystemOverviewView(service: _FakeInfoService())));
    expect(find.byType(SkeletonBlock), findsWidgets);

    await settleProbe(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(SkeletonBlock), findsNothing);
    expect(find.text('DRIVES'), findsOneWidget);
    expect(find.text('FOLDER SNAPSHOT'), findsOneWidget);
    expect(find.text('AI Insights'), findsOneWidget);
  });

  testWidgets('cards in a two-column row have a real height', (tester) async {
    // Regression guard for the grid: a Row's cross axis is vertical, and inside
    // a ListView that constraint is unbounded, so `crossAxisAlignment.stretch`
    // silently collapsed every side-by-side card to nothing.
    tester.view.physicalSize = const Size(1070, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final browser = _StubBrowser();
    await tester.pumpWidget(
      host(SystemOverviewView(service: _FakeInfoService()), browser: browser),
    );
    browser.publish({
      'Desktop': tmp.path,
      'Documents': tmp.path,
      'Downloads': tmp.path,
    });
    await settleProbe(tester);
    await settleProbe(tester);

    expect(tester.takeException(), isNull);
    for (final label in ['Desktop', 'Documents', 'Downloads']) {
      expect(find.text(label), findsOneWidget, reason: label);
      final card = find.ancestor(
        of: find.text(label),
        matching: find.byType(ShadCard),
      );
      expect(tester.getSize(card.first).height, greaterThan(40), reason: label);
    }
  });

  testWidgets('a late shortcut map still gets scanned', (tester) async {
    tester.view.physicalSize = const Size(1070, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final browser = _StubBrowser();
    await tester.pumpWidget(
      host(SystemOverviewView(service: _FakeInfoService()), browser: browser),
    );
    await settleProbe(tester);
    expect(find.text('No shortcut folders available.'), findsOneWidget);

    // BrowserProvider.init() finishing after the page mounted.
    browser.publish({'Documents': tmp.path});
    await settleProbe(tester);
    await settleProbe(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('No shortcut folders available.'), findsNothing);
    expect(find.text('Documents'), findsOneWidget);
  });

  testWidgets('skeleton fits a card barely 200px wide', (tester) async {
    // With both side panels open on a small desktop window the centre pane is
    // ~250px, which leaves the cards under 200px of inner width. The
    // placeholder rows used fixed pixel widths and overflowed there.
    tester.view.physicalSize = const Size(210, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      host(SystemOverviewView(service: _FakeInfoService())),
    );
    expect(find.byType(SkeletonBlock), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lays out without overflow at a narrow width', (tester) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final browser = _StubBrowser()
      ..publish({'Desktop': tmp.path, 'Documents': tmp.path});
    await tester.pumpWidget(
      host(
        SystemOverviewView(service: _FakeInfoService()),
        brightness: Brightness.dark,
        browser: browser,
      ),
    );
    await settleProbe(tester);
    await settleProbe(tester);

    expect(tester.takeException(), isNull);
  });
}
