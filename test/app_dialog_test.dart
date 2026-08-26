import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show DefaultMaterialLocalizations, ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/theme.dart';
import 'package:notilus/utils/platform.dart';
import 'package:notilus/widgets/app_dialog.dart';

/// Dialog chrome.
///
/// Shad drops a dialog's border radius below its `sm` breakpoint — 640px, so
/// every phone and any narrow desktop window — and nothing in its theme insets
/// the box from the screen. Together that put a square slab in all four corners
/// of a phone screen. The theme keeps the corners; [showAppDialog] keeps the
/// margin that makes them visible.
void main() {
  Widget host() => ShadApp.custom(
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
          home: const SizedBox.expand(),
        ),
      );

  /// Opens a dialog whose content is wide enough to want the whole screen,
  /// which is the case the margin exists for.
  Future<void> open(
    WidgetTester tester, {
    required Size size,
    required bool mobile,
  }) async {
    debugMobilePlatformOverride = mobile;
    addTearDown(() => debugMobilePlatformOverride = null);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    showAppDialog<void>(
      context: tester.element(find.byType(SizedBox).first),
      builder: (ctx) => ShadDialog.alert(
        title: const Text('Delete these files?'),
        description: const Text(
          'They are moved to the Trash, where the system can still be asked '
          'to put them back.',
        ),
        actions: [
          ShadButton.outline(child: const Text('Cancel'), onPressed: () {}),
          ShadButton.destructive(child: const Text('Delete'), onPressed: () {}),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The dialog's own box: the one decorated surface that carries the shadow.
  BoxDecoration boxDecoration(WidgetTester tester) {
    final boxes = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((b) => b.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.boxShadow != null && d.boxShadow!.isNotEmpty);
    expect(boxes, isNotEmpty, reason: 'the dialog box was not found');
    return boxes.first;
  }

  Rect boxRect(WidgetTester tester) => tester.getRect(
        find
            .descendant(
              of: find.byType(ShadDialog),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );

  testWidgets('a phone dialog keeps its rounded corners', (tester) async {
    await open(tester, size: const Size(393, 852), mobile: true);

    expect(boxDecoration(tester).borderRadius, isNotNull);
  });

  testWidgets('a phone dialog stays clear of every screen edge',
      (tester) async {
    const size = Size(393, 852);
    await open(tester, size: size, mobile: true);

    final rect = boxRect(tester);
    expect(rect.left, greaterThanOrEqualTo(16));
    expect(rect.right, lessThanOrEqualTo(size.width - 16));
    expect(rect.top, greaterThanOrEqualTo(16));
    expect(rect.bottom, lessThanOrEqualTo(size.height - 16));
  });

  testWidgets('a narrow desktop window is inset too — same breakpoint',
      (tester) async {
    const size = Size(420, 700);
    await open(tester, size: size, mobile: false);

    final rect = boxRect(tester);
    expect(boxDecoration(tester).borderRadius, isNotNull);
    expect(rect.left, greaterThanOrEqualTo(24));
    expect(rect.right, lessThanOrEqualTo(size.width - 24));
  });

  testWidgets('a wide window is unchanged: the dialog is nowhere near an edge',
      (tester) async {
    await open(tester, size: const Size(1400, 900), mobile: false);

    // Shad's own 512 max width already holds it well clear, so the margin does
    // nothing here — what matters is that it did not shrink the dialog.
    expect(boxRect(tester).width, greaterThan(300));
    expect(tester.takeException(), isNull);
  });
}
