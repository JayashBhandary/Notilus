import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:notilus/app.dart';
import 'package:notilus/utils/responsive.dart';

import 'native_test_support.dart';

/// HomeScreen is the app chrome, so it is driven through the real [NotilusApp]
/// rather than a stub host: it needs all seven providers, and its two layouts
/// pull in the sidebar, panels and status bar. Booting the app is what the
/// existing smoke test already does, so the setup is shared.
///
/// The concern this suite guards is the wide toolbar. It sheds controls at three
/// hardcoded widths (440 / 360 / 290 of *center-pane* width) that were tuned to
/// the old hand-rolled control sizes; the shadcn replacements are close but not
/// identical, so every threshold is pumped and checked for overflow.
void main() {
  setUpAll(() async {
    // main() does both of these before the first frame; TransferController
    // reads config during construction, so dotenv has to exist. An empty
    // string is rejected, hence one inert key.
    dotenv.loadFromString(envString: 'NOTILUS_TEST=1');
    await NativeTestSupport.ensureLoaded();
  });

  setUp(() {
    // SettingsProvider.load() and WorkflowProvider.load() both hit prefs.
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const NotilusApp());
    // Not pumpAndSettle: the file listing and panels kick off async loads that
    // keep frames scheduled, and any ShadSpinner on screen repeats forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('wide layout', () {
    // 1400 = everything shown; the rest walk down through the shed thresholds.
    // 760 is just above kCompactBreakpoint, the narrowest wide layout there is.
    for (final width in [1400.0, 1100.0, 1000.0, 900.0, 800.0, 760.0]) {
      testWidgets('lays out without overflow at ${width.toInt()}px',
          (tester) async {
        await pumpAt(tester, Size(width, 900));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('renders the migrated toolbar chrome', (tester) async {
      await pumpAt(tester, const Size(1400, 900));

      // Sidebar toggle, terminal, settings, panel toggle are always present;
      // back/forward/up appear at this width too.
      expect(find.byIcon(LucideIcons.panelLeft), findsOneWidget);
      expect(find.byIcon(LucideIcons.panelRight), findsOneWidget);
      expect(find.byIcon(LucideIcons.terminal), findsOneWidget);
      expect(find.byIcon(LucideIcons.settings), findsOneWidget);
      expect(find.byIcon(LucideIcons.chevronLeft), findsOneWidget);
      expect(find.byIcon(LucideIcons.chevronRight), findsOneWidget);
      expect(find.byIcon(LucideIcons.arrowUp), findsOneWidget);
      // View-mode toggle pair.
      expect(find.byIcon(LucideIcons.layoutGrid), findsOneWidget);
      expect(find.byIcon(LucideIcons.list), findsOneWidget);
    });

    testWidgets('toolbar buttons carry the tooltips that used to be dead',
        (tester) async {
      await pumpAt(tester, const Size(1400, 900));

      // Every _ToolbarIconButton passes a tooltip, and _ViewModeButton does
      // too — none of them rendered before the migration.
      expect(find.byType(ShadTooltip), findsWidgets);
      final tips = tester
          .widgetList<ShadTooltip>(find.byType(ShadTooltip))
          .length;
      expect(tips, greaterThanOrEqualTo(8),
          reason: 'toolbar + view-mode controls should all be tooltipped');
    });

    testWidgets('back/forward start disabled at the initial location',
        (tester) async {
      await pumpAt(tester, const Size(1400, 900));

      // Nothing has been navigated yet, so history is empty. ShadIconButton
      // keys its disabled look off `enabled`, so that flag is what matters.
      final back = tester.widget<ShadIconButton>(
        find.ancestor(
          of: find.byIcon(LucideIcons.chevronLeft),
          matching: find.byType(ShadIconButton),
        ),
      );
      expect(back.enabled, isFalse);
      expect(back.onPressed, isNull);
    });

    testWidgets('right panel tabs switch between Info, Chat and Flows',
        (tester) async {
      await pumpAt(tester, const Size(1400, 900));

      expect(find.byType(ShadTabs<int>), findsOneWidget);
      final tabs = tester.widget<ShadTabs<int>>(find.byType(ShadTabs<int>));
      expect(tabs.value, 0);
      expect(tabs.tabs.length, 3);

      await tester.tap(find.text('Flows').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final after = tester.widget<ShadTabs<int>>(find.byType(ShadTabs<int>));
      expect(after.value, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('connection pill collapses to a dot on a narrow window',
        (tester) async {
      // Wide: the full pill (a ShadBadge) is shown.
      await pumpAt(tester, const Size(1400, 900));
      expect(find.byType(ShadBadge), findsOneWidget);

      // Narrow enough that the center pane drops under 440px and the pill is
      // swapped for the bare dot.
      await pumpAt(tester, const Size(800, 900));
      expect(find.byType(ShadBadge), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('compact layout', () {
    // Comfortably under kCompactBreakpoint.
    const phone = Size(420, 860);

    testWidgets('lays out without overflow', (tester) async {
      expect(isCompactWidth(phone.width), isTrue);
      await pumpAt(tester, phone);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows the bottom tab bar with all four tabs', (tester) async {
      await pumpAt(tester, phone);

      expect(find.text('Files'), findsOneWidget);
      expect(find.text('Info'), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Flows'), findsOneWidget);
      expect(find.byIcon(LucideIcons.folder), findsWidgets);
      expect(find.byIcon(LucideIcons.zap), findsOneWidget);
      // The right-panel ShadTabs belongs to the wide layout only.
      expect(find.byType(ShadTabs<int>), findsNothing);
    });

    testWidgets('bottom tab bar switches panes', (tester) async {
      await pumpAt(tester, phone);

      await tester.tap(find.text('Chat'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.takeException(), isNull);
    });

    testWidgets('compact top bar keeps only its essential controls',
        (tester) async {
      await pumpAt(tester, phone);

      // Menu (panelLeft), terminal, settings — but no right-panel toggle,
      // since the compact layout has no right panel.
      expect(find.byIcon(LucideIcons.panelLeft), findsOneWidget);
      expect(find.byIcon(LucideIcons.terminal), findsOneWidget);
      expect(find.byIcon(LucideIcons.settings), findsOneWidget);
      expect(find.byIcon(LucideIcons.panelRight), findsNothing);
    });
  });
}
