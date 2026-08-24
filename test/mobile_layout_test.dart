import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:notilus/app.dart';
import 'package:notilus/utils/platform.dart';

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
    expect(find.text('Places'), findsOneWidget);
    expect(find.text('Info'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
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

  testWidgets('a phone offers no terminal and no menu button', (tester) async {
    await pumpPhone(tester, mobile: true);

    expect(find.byIcon(LucideIcons.terminal), findsNothing);
    expect(find.byIcon(LucideIcons.panelLeft), findsNothing);
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

    // The tabs are an IndexedStack, so Places has to be selected before its
    // rows are on stage.
    await tester.tap(find.text('Places'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Locations'), findsOneWidget, reason: 'Places is showing');
    expect(find.text('File Sharing'), findsNothing);
    expect(find.text('System Overview'), findsNothing);
    expect(find.text('Duplicate Finder'), findsNothing);
    // Receiving a transfer is a client's job, so that one stays.
    expect(find.text('File Transfer'), findsOneWidget);
  });

  testWidgets('the desktop sidebar keeps all of it', (tester) async {
    await pumpPhone(tester, mobile: false);

    // The drawer is off-screen but built, so the rows are in the tree.
    expect(find.text('File Sharing'), findsOneWidget);
    expect(find.text('System Overview'), findsOneWidget);
    expect(find.text('Duplicate Finder'), findsOneWidget);
  });
}
