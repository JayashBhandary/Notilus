import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/providers/browser_provider.dart';
import 'package:notilus/providers/file_ops_provider.dart';
import 'package:notilus/services/file_service.dart';
import 'package:notilus/theme.dart';
import 'package:notilus/widgets/file_list_view.dart';

/// The View Options dialog, reached from the file browser's context menu.
///
/// Driven through the public `showBackgroundContextMenu` rather than by
/// constructing the private dialog, so the menu wiring is covered too.
///
/// The real [BrowserProvider] is used: `setUseGroups`, `setSort` and
/// `setRowDensity` only mutate fields and notify — nothing here touches the
/// filesystem, and `init()` is never called.
void main() {
  Widget host(BrowserProvider browser) {
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
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<BrowserProvider>.value(value: browser),
            ChangeNotifierProvider<FileOpsProvider>(
              create: (_) => FileOpsProvider(),
            ),
          ],
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  /// Opens the background context menu, then its View Options entry.
  Future<BrowserProvider> openDialog(
    WidgetTester tester, {
    Size size = const Size(1000, 800),
  }) async {
    final browser = BrowserProvider(FileService());
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(browser));
    await tester.pumpAndSettle();

    showBackgroundContextMenu(
      tester.element(find.byType(SizedBox).first),
      browser,
      const Offset(120, 120),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Show View Options'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return browser;
  }

  testWidgets('opens from the context menu with every control', (tester) async {
    await openDialog(tester);

    expect(find.text('View Options'), findsOneWidget);
    expect(find.text('Use Groups'), findsOneWidget);
    expect(find.byType(ShadSwitch), findsOneWidget);
    expect(find.text('Sort by'), findsOneWidget);
    expect(find.text('Row density'), findsOneWidget);
    // Four sort fields plus three densities.
    expect(find.byType(ShadBadge), findsNWidgets(7));
    expect(find.text('Done'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"Modified" renders in full, not clipped to "Modifi"',
      (tester) async {
    await openDialog(tester);

    // The bug this replaced: four labels in a segmented control did not fit the
    // dialog's width, so the longest was truncated.
    expect(find.text('Modified'), findsOneWidget);
    expect(find.text('Modifi'), findsNothing);

    final label = tester.widget<Text>(find.text('Modified'));
    expect(label.overflow, isNot(TextOverflow.ellipsis));
    // And it is not visually clipped either.
    final chip = tester.getRect(
      find.ancestor(of: find.text('Modified'), matching: find.byType(ShadBadge))
          .first,
    );
    final text = tester.getRect(find.text('Modified'));
    expect(text.width, lessThanOrEqualTo(chip.width));
  });

  testWidgets('chips wrap instead of clipping in a narrow window',
      (tester) async {
    await openDialog(tester, size: const Size(420, 800));

    expect(find.text('Modified'), findsOneWidget);
    expect(find.text('Spacious'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('exactly one sort field and one density are selected',
      (tester) async {
    await openDialog(tester);

    int filled() => tester
        .widgetList<ShadBadge>(find.byType(ShadBadge))
        .where((b) => b.variant == ShadBadgeVariant.primary)
        .length;
    // One per group.
    expect(filled(), 2);
  });

  testWidgets('picking a sort field reaches the provider', (tester) async {
    final browser = await openDialog(tester);
    expect(browser.sortField, isNot(SortField.size));

    await tester.tap(find.text('Size'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(browser.sortField, SortField.size);
    // Still exactly one selected in each group after the change.
    final filled = tester
        .widgetList<ShadBadge>(find.byType(ShadBadge))
        .where((b) => b.variant == ShadBadgeVariant.primary)
        .length;
    expect(filled, 2);
  });

  testWidgets('re-picking the current sort field does not flip direction',
      (tester) async {
    final browser = await openDialog(tester);
    final field = browser.sortField;
    final ascending = browser.sortAscending;

    await tester.tap(find.text(field == SortField.name ? 'Name' : 'Kind'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // setSort() toggles ascending when handed the field already in use, so the
    // dialog guards against calling it — direction is the context menu's job.
    if (field == SortField.name) {
      expect(browser.sortAscending, ascending);
    }
  });

  testWidgets('density buttons set the discrete values they name',
      (tester) async {
    final browser = await openDialog(tester);

    await tester.tap(find.text('Compact'));
    await tester.pump();
    expect(browser.rowDensity, 0.85);

    await tester.tap(find.text('Spacious'));
    await tester.pump();
    expect(browser.rowDensity, 1.2);

    await tester.tap(find.text('Default'));
    await tester.pump();
    expect(browser.rowDensity, 1.0);
  });

  testWidgets('a density stored by the old slider still highlights a button',
      (tester) async {
    final browser = await openDialog(tester);
    // 1.3 was reachable on the old 0.85–1.3 slider but is not one of the three
    // steps; the nearest one should read as selected without being rewritten.
    browser.setRowDensity(1.3);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final spacious = tester.widget<ShadBadge>(
      find.ancestor(
        of: find.text('Spacious'),
        matching: find.byType(ShadBadge),
      ).first,
    );
    expect(spacious.variant, ShadBadgeVariant.primary);
    expect(browser.rowDensity, 1.3);
  });

  testWidgets('the switch toggles grouping', (tester) async {
    final browser = await openDialog(tester);
    final before = browser.useGroups;

    await tester.tap(find.byType(ShadSwitch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(browser.useGroups, !before);
  });

  testWidgets('Done closes the dialog', (tester) async {
    await openDialog(tester);
    expect(find.text('View Options'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('View Options'), findsNothing);
  });
}
