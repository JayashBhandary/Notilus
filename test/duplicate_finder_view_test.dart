import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart' show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/providers/browser_provider.dart';
import 'package:notilus/screens/duplicate_finder_screen.dart';
import 'package:notilus/services/file_service.dart';
import 'package:notilus/theme.dart';
import 'package:notilus/widgets/shad_spinner.dart';

/// The duplicate finder is the second screen migrated from Cupertino to
/// shadcn_ui. It is a dense scrolling page of cards whose widths are clamped by
/// a responsive grid, so the failure mode to guard is a render overflow at a
/// narrow width — which surfaces as a pumped-frame exception.
///
/// Scan targets come from [BrowserProvider.drives] / `.shortcuts`, which the
/// real provider only fills in from the host filesystem during `init()`. This
/// stub supplies them directly so the scope card's checkboxes actually render
/// and the counts below are deterministic.
class _StubBrowser extends BrowserProvider {
  _StubBrowser() : super(FileService());

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
}

/// 2 drives + 4 shortcuts.
const _targetCount = 6;

/// Redirects the app-support directory at the platform-interface level.
/// path_provider_linux is a pure-Dart xdg lookup, not a method channel, so
/// mocking a MethodChannel does nothing — the instance has to be swapped.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The results half of the page only renders when DuplicateScanStore restores
  // a saved scan. The store reads a JSON file from getApplicationSupportDirectory
  // and drops any file that no longer exists on disk, so the fixture needs both
  // a redirected support dir and real files.
  late Directory tmp;
  final realPathProvider = PathProviderPlatform.instance;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('notilus_dupe_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    // initState fires _loadPrefs() and _restoreSavedScan() as siblings. Without
    // this, _loadPrefs throws MissingPluginException for shared_preferences and
    // the uncaught async error takes the restore future down with it — the
    // results half then silently never renders.
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    PathProviderPlatform.instance = realPathProvider;
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// Writes a two-group saved scan (3 copies + 2 copies) plus the real files it
  /// points at, so DuplicateScanStore.load() validates them through.
  Future<void> seedSavedScan() async {
    Map<String, dynamic> fileJson(String name, int size) {
      final f = File('${tmp.path}/$name')..writeAsStringSync('x' * size);
      return {
        'path': f.path,
        'name': name,
        'isDirectory': false,
        'size': size,
        'modified': DateTime(2026, 3, 4).millisecondsSinceEpoch,
      };
    }

    final payload = {
      'savedAt': DateTime(2026, 8, 1).millisecondsSinceEpoch,
      'groups': [
        {
          'hash': 'aaa',
          'size': 40,
          'files': [
            fileJson('a1.txt', 40),
            fileJson('a2.txt', 40),
            fileJson('a3.txt', 40),
          ],
        },
        {
          'hash': 'bbb',
          'size': 20,
          'files': [fileJson('b1.txt', 20), fileJson('b2.txt', 20)],
        },
      ],
    };
    File('${tmp.path}/duplicate_scan.json')
        .writeAsStringSync(jsonEncode(payload));
  }

  Widget host(Widget child, {Brightness brightness = Brightness.light}) {
    return ShadApp.custom(
      theme: AppTheme.shadThemeFor(Brightness.light),
      darkTheme: AppTheme.shadThemeFor(Brightness.dark),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      // Mirrors app.dart: ShadApp.custom wraps CupertinoApp, ShadAppBuilder
      // goes in `builder`, and content goes in `home`. Putting the view in
      // `builder` instead would place it *above* the Navigator, so
      // showShadDialog would find nothing to push onto and the confirmation
      // dialogs would silently never appear.
      appBuilder: (_) => CupertinoApp(
        localizationsDelegates: const [
          GlobalShadLocalizations.delegate,
          DefaultMaterialLocalizations.delegate,
          DefaultCupertinoLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        builder: (_, inner) => ShadAppBuilder(child: inner!),
        home: ChangeNotifierProvider<BrowserProvider>(
          create: (_) => _StubBrowser(),
          child: child,
        ),
      ),
    );
  }

  Future<void> pumpAt(WidgetTester tester, Size size,
      {Brightness brightness = Brightness.light}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(const DuplicateFinderView(), brightness: brightness),
    );
    await tester.pump();
  }

  /// Pumps the view with its saved scan restored.
  ///
  /// The first mount has to happen *inside* [WidgetTester.runAsync]: the
  /// restore is kicked off from `initState`, and `DuplicateScanStore` does real
  /// file I/O (`File.exists()` per copy). A future created in the fake-async
  /// zone can't be advanced by a later `runAsync`, so mounting there first is
  /// what lets the chain complete; `pumpAndSettle` then paints the result.
  Future<void> pumpRestored(WidgetTester tester, Size size,
      {Brightness brightness = Brightness.light}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        host(const DuplicateFinderView(), brightness: brightness),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    testWidgets('lays out without overflow ($brightness)', (tester) async {
      await pumpAt(tester, const Size(1400, 1000), brightness: brightness);
      expect(tester.takeException(), isNull);
    });
  }

  // 700px is the single-column case: the grid clamps to 1 column below ~760px
  // and the filters card is at its narrowest, which is where the file-type Wrap
  // has to reflow rather than overflow.
  testWidgets('lays out without overflow at a narrow width', (tester) async {
    await pumpAt(tester, const Size(700, 1000));
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders the migrated shadcn controls', (tester) async {
    await pumpAt(tester, const Size(1400, 1400));

    expect(find.byType(ShadCard), findsWidgets);
    // One checkbox per scan target.
    expect(find.byType(ShadCheckbox), findsNWidgets(_targetCount));
    // Skip dev folders / bundles / include hidden.
    expect(find.byType(ShadSwitch), findsNWidgets(3));
    // Five single-select file-type chips.
    expect(find.byType(ShadBadge), findsNWidgets(5));
    // Custom-exclude field.
    expect(find.byType(ShadInput), findsOneWidget);
    // No scan running, so no spinner or progress bar yet.
    expect(find.text('Find Duplicates'), findsOneWidget);
    expect(find.byType(ShadSpinner), findsNothing);
    expect(find.byType(ShadProgress), findsNothing);
  });

  testWidgets('drives start selected and toggle on tap', (tester) async {
    await pumpAt(tester, const Size(1400, 1400));

    List<ShadCheckbox> boxes() =>
        tester.widgetList<ShadCheckbox>(find.byType(ShadCheckbox)).toList();

    // Drives are the "all drives" default scope; shortcuts start off.
    expect(boxes().where((b) => b.value).length, 2);

    await tester.tap(find.text('Downloads'));
    await tester.pump();

    expect(boxes().where((b) => b.value).length, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('file-type chips are single-select', (tester) async {
    await pumpAt(tester, const Size(1400, 1400));

    // "All files" is the default, so exactly one chip is the filled variant
    // and the other four are outlined.
    int filled() => tester
        .widgetList<ShadBadge>(find.byType(ShadBadge))
        .where((b) => b.variant == ShadBadgeVariant.primary)
        .length;
    expect(filled(), 1);

    await tester.tap(find.text('Videos'));
    await tester.pump();

    expect(filled(), 1, reason: 'selecting a chip must deselect the previous');
    expect(tester.takeException(), isNull);
  });

  group('restored results', () {
    for (final brightness in Brightness.values) {
      testWidgets('group cards and cleanup bar lay out cleanly ($brightness)',
          (tester) async {
        await seedSavedScan();
        await pumpRestored(tester, const Size(1400, 1600),
            brightness: brightness);

        // 3 extra copies; reclaimable = 40×2 + 20×1 = 100 B.
        expect(find.text('2 groups • 3 extra copies • 100 B reclaimable'),
            findsOneWidget);
        expect(find.text('Clean up all groups'), findsOneWidget);
        expect(find.text('Trash extras'), findsNWidgets(2));
        // 5 file tiles across the two groups, each with its own action row.
        expect(find.byType(ShadTooltip), findsNWidgets(_actionsPerTile * 5));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('exactly one copy per group is flagged as keep',
        (tester) async {
      await seedSavedScan();
      await pumpRestored(tester, const Size(1400, 1600));

      expect(find.text('keep'), findsNWidgets(2));
    });

    testWidgets('keep-strategy tabs switch without error', (tester) async {
      await seedSavedScan();
      await pumpRestored(tester, const Size(1400, 1600));

      expect(find.byType(ShadTabs<Object?>), findsNothing,
          reason: 'the keep-strategy control is typed, not dynamic');
      await tester.tap(find.text('Shortest path'));
      await tester.pumpAndSettle();

      expect(find.text('keep'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('cleanup confirmation is a destructive ShadDialog',
        (tester) async {
      await seedSavedScan();
      await pumpRestored(tester, const Size(1400, 1600));

      await tester.tap(find.text('Clean up all groups'));
      await tester.pumpAndSettle();

      expect(find.text('Move duplicates to Trash?'), findsOneWidget);
      // 3 extra copies across the two groups.
      expect(find.text('Trash 3'), findsOneWidget);
      expect(find.byType(ShadDialog), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Cancel must leave the groups untouched.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Trash extras'), findsNWidgets(2));
    });
  });
}

/// Preview + Trash on every tile; Reveal in Finder is macOS-only.
final int _actionsPerTile = Platform.isMacOS ? 3 : 2;
