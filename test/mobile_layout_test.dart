import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:notilus/app.dart';
import 'package:notilus/utils/platform.dart';
import 'package:notilus/widgets/sidebar.dart';

import 'native_test_support.dart';

/// The phone shape of the app.
///
/// iOS is the client half: it browses shares and its own container, and the
/// things that need a whole machine — a shell to spawn, a folder to publish
/// over SMB, a disk to scan for duplicates — aren't there to offer. Two axes
/// decide what shows: width picks the layout, and [isMobilePlatform] picks the
/// features. This suite pins the second one, which is the half a desktop test
/// run would otherwise never exercise.
void main() {
  setUpAll(() async {
    dotenv.loadFromString(envString: 'NOTILUS_TEST=1');
    await NativeTestSupport.ensureLoaded();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    debugMobilePlatformOverride = null;
  });

  /// Phone-sized, so the compact layout is the one under test.
  Future<void> pumpPhone(WidgetTester tester, {required bool mobile}) async {
    debugMobilePlatformOverride = mobile;
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const NotilusApp());
    // Not pumpAndSettle: the listing and panels keep frames scheduled.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('phone tabs lead with browsing and drop the desktop-only ones',
      (tester) async {
    await pumpPhone(tester, mobile: true);
    expect(tester.takeException(), isNull);

    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Info'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    // The places are the drawer now, not a tab: one swipe or one button, and
    // the bar is left for the pages you switch between.
    expect(find.text('Places'), findsNothing);
    // Workflow editing wants a canvas, so it stays on the desktop layouts.
    expect(find.text('Flows'), findsNothing);
  });

  testWidgets('a narrow desktop window keeps its own tabs and its drawer',
      (tester) async {
    await pumpPhone(tester, mobile: false);
    expect(tester.takeException(), isNull);

    expect(find.text('Flows'), findsOneWidget);
    expect(find.text('Places'), findsNothing);
    // The drawer's button: mobile replaces it with the Places tab.
    expect(find.byIcon(LucideIcons.panelLeft), findsOneWidget);
  });

  testWidgets('a phone offers no terminal but does offer the drawer',
      (tester) async {
    await pumpPhone(tester, mobile: true);

    // No shell to spawn inside a mobile sandbox.
    expect(find.byIcon(LucideIcons.terminal), findsNothing);
    // The sidebar is reachable by button as well as by edge-swipe.
    expect(find.byIcon(LucideIcons.panelLeft), findsOneWidget);
  });

  testWidgets('a phone reaches the folder menu by button', (tester) async {
    await pumpPhone(tester, mobile: true);

    // There is no right-click on a touchscreen, so the menu the desktop opens
    // on empty space lives in the top bar.
    final button = find.byIcon(LucideIcons.ellipsisVertical);
    expect(button, findsWidgets);

    await tester.tap(button.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('New Folder'), findsOneWidget);
    expect(find.text('Paste'), findsOneWidget);
  });

  testWidgets('a desktop window carries no touch-only affordances',
      (tester) async {
    await pumpPhone(tester, mobile: false);

    // The per-row and folder menu buttons are the touchscreen's stand-in for
    // a right-click; a narrow desktop window still has one.
    expect(find.byIcon(LucideIcons.ellipsisVertical), findsNothing);
  });

  testWidgets('an edge swipe pulls the drawer out, and one back shuts it',
      (tester) async {
    await pumpPhone(tester, mobile: true);

    // The drawer is always built — it slides in from off-screen — so where it
    // is, not whether it exists, is what says it is open.
    double drawerLeft() => tester.getTopLeft(find.byType(Sidebar)).dx;

    expect(drawerLeft(), lessThan(0), reason: 'drawer starts off-screen');

    // From inside the edge strip: anywhere else and this is a back gesture.
    await tester.timedDragFrom(
      const Offset(6, 400),
      const Offset(240, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(drawerLeft(), 0, reason: 'edge swipe pulled it out');

    await tester.timedDragFrom(
      const Offset(200, 400),
      const Offset(-240, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(drawerLeft(), lessThan(0), reason: 'swipe back shut it');
  });

  testWidgets('a phone gets buttons for the moves a keyboard would do',
      (tester) async {
    await pumpPhone(tester, mobile: true);

    // Back and up: there are no Cmd+[ / Cmd+Up shortcuts on a touchscreen.
    expect(find.byIcon(LucideIcons.chevronLeft), findsOneWidget);
    expect(find.byIcon(LucideIcons.arrowUp), findsOneWidget);
  });

  testWidgets('the phone sidebar hides what a sandbox cannot do',
      (tester) async {
    await pumpPhone(tester, mobile: true);

    // The drawer is built off-screen, so its rows are in the tree either way;
    // opening it is what a user would do and costs nothing to mirror here.
    await tester.tap(find.byIcon(LucideIcons.panelLeft));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Locations'), findsOneWidget, reason: 'drawer is open');
    expect(find.text('File Sharing'), findsNothing);
    expect(find.text('System Overview'), findsNothing);
    expect(find.text('Duplicate Finder'), findsNothing);
    // Receiving a transfer is a client's job, so that one stays.
    expect(find.text('File Transfer'), findsOneWidget);
  });

  group('phone sizes lay out without overflow', () {
    // iPhone SE, iPhone 15, a tall Android, and one in landscape — the last
    // is still under the compact breakpoint, so it is the same layout with
    // very little height to spend.
    const sizes = <String, Size>{
      'iPhone SE': Size(375, 667),
      'iPhone 15': Size(393, 852),
      'tall Android': Size(412, 915),
      'landscape': Size(740, 400),
    };
    sizes.forEach((name, size) {
      testWidgets(name, (tester) async {
        debugMobilePlatformOverride = true;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(const NotilusApp());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(tester.takeException(), isNull);
      });
    });
  });

  testWidgets('the desktop sidebar keeps all of it', (tester) async {
    await pumpPhone(tester, mobile: false);

    // The drawer is off-screen but built, so the rows are in the tree.
    expect(find.text('File Sharing'), findsOneWidget);
    expect(find.text('System Overview'), findsOneWidget);
    expect(find.text('Duplicate Finder'), findsOneWidget);
  });
}
