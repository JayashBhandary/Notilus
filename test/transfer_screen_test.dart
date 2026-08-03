import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/models/transfer/contact.dart';
import 'package:notilus/providers/transfer_controller.dart';
import 'package:notilus/screens/transfer/transfer_screen.dart';
import 'package:notilus/services/transfer/file_transfer.dart';
import 'package:notilus/theme.dart';
import 'package:notilus/widgets/shad_spinner.dart';

/// Drives TransferScreen through its four states without touching the network.
///
/// The real `TransferController()` runs `_init()` from its constructor, but that
/// bails immediately while `isConfigured` is false — which it is here, since the
/// test dotenv holds only an inert key. Every field the screen reads is an
/// instance getter, so overriding them is enough to pin a state.
class _StubController extends TransferController {
  _StubController({
    this.configured = true,
    this.isReady = true,
    this.failure,
    this.peers = const [],
    this.onlineCodes = const {},
    this.batches = const {},
  });

  final bool configured;
  final bool isReady;
  final String? failure;
  final List<Contact> peers;
  final Set<String> onlineCodes;
  final Map<String, BatchProgress> batches;

  int renameCalls = 0;
  int removeCalls = 0;

  @override
  bool get isConfigured => configured;
  @override
  bool get ready => isReady;
  @override
  String? get error => failure;
  @override
  String get myName => 'Test Machine';
  @override
  String? get myCode => 'a2:b1:c4:ff:07:3d:9e:11';
  @override
  List<Contact> get contacts => peers;
  @override
  bool isOnline(String code) => onlineCodes.contains(code);
  @override
  Map<String, BatchProgress> get transfers => batches;

  @override
  Future<void> renameContact(String code, String name) async => renameCalls++;
  @override
  Future<void> removeContact(String code) async => removeCalls++;
}

Contact _contact(String name, String key) =>
    Contact(name: name, deviceId: 'dev-$key', publicKey: key);

BatchProgress _batch({
  required bool sending,
  required TransferStatus status,
  int size = 100,
  int bytes = 40,
}) {
  final file = FileTransferProgress(index: 0, name: 'movie.mp4', size: size)
    ..bytes = bytes
    ..status = status;
  return BatchProgress(sending: sending, files: [file])..status = status;
}

void main() {
  setUpAll(() {
    // TransferConfig reads through dotenv, which throws if never initialised.
    // An empty string is rejected, so seed one inert key — this also keeps
    // isConfigured false, which is what stops the real _init() doing any work.
    dotenv.loadFromString(envString: 'NOTILUS_TEST=1');
  });

  Widget host(
    TransferController ctrl, {
    Brightness brightness = Brightness.light,
  }) {
    return ShadApp.custom(
      theme: AppTheme.shadThemeFor(Brightness.light),
      darkTheme: AppTheme.shadThemeFor(Brightness.dark),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      // Mirrors app.dart: ShadAppBuilder in `builder` (it is what installs
      // ShadToaster/ShadSonner), content in `home`. Content mounted in
      // `builder` would sit above the Navigator, so showShadDialog would have
      // nothing to push onto.
      appBuilder: (_) => CupertinoApp(
        localizationsDelegates: const [
          GlobalShadLocalizations.delegate,
          DefaultMaterialLocalizations.delegate,
          DefaultCupertinoLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        builder: (_, inner) => ShadAppBuilder(child: inner!),
        home: ChangeNotifierProvider<TransferController>.value(
          value: ctrl,
          child: const TransferScreen(),
        ),
      ),
    );
  }

  Future<void> pump(
    WidgetTester tester,
    TransferController ctrl, {
    Size size = const Size(1000, 1000),
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(ctrl, brightness: brightness));
    await tester.pumpAndSettle();
  }

  group('states', () {
    testWidgets('not configured shows the setup hint', (tester) async {
      await pump(tester, _StubController(configured: false));

      expect(find.text('Set up file transfer'), findsOneWidget);
      expect(find.byIcon(LucideIcons.settings), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('error shows the failure message', (tester) async {
      await pump(tester, _StubController(failure: 'RTDB unreachable'));

      expect(find.text('Couldn\'t connect'), findsOneWidget);
      expect(find.text('RTDB unreachable'), findsOneWidget);
      expect(find.byIcon(LucideIcons.triangleAlert), findsOneWidget);
    });

    testWidgets('not ready shows a spinner', (tester) async {
      // pumpAndSettle would spin forever on the spinner's repeating animation.
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(_StubController(isReady: false)));
      await tester.pump();

      expect(find.byType(ShadSpinner), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ready with no contacts shows the empty hint', (tester) async {
      await pump(tester, _StubController());

      expect(find.text('Contacts'), findsOneWidget);
      expect(find.textContaining('No contacts yet'), findsOneWidget);
      // My-device card is present, so its QR-adjacent controls are too.
      expect(find.text('Test Machine'), findsOneWidget);
      expect(find.text('a2:b1:c4:ff:07:3d:9e:11'), findsOneWidget);
    });
  });

  group('contacts', () {
    late _StubController ctrl;

    setUp(() {
      ctrl = _StubController(
        peers: [_contact('Bob’s laptop', 'kb'), _contact('Phone', 'kp')],
        onlineCodes: {_contact('Bob’s laptop', 'kb').code},
      );
    });

    for (final brightness in Brightness.values) {
      testWidgets('contact tiles lay out cleanly ($brightness)',
          (tester) async {
        await pump(tester, ctrl, brightness: brightness);

        expect(find.byType(ShadCard), findsNWidgets(3)); // device + 2 contacts
        expect(find.text('Bob’s laptop'), findsOneWidget);
        expect(find.text('Phone'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('overflow popover offers Rename and Remove', (tester) async {
      await pump(tester, ctrl);

      // Closed by default — the popover replaced a pushed action sheet, so
      // nothing should be in the tree until the … button is used.
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Remove'), findsNothing);

      await tester.tap(find.byIcon(LucideIcons.ellipsis).first);
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      // The old action sheet needed an explicit Cancel row; a popover dismisses
      // by tapping outside, so that row is intentionally gone.
      expect(find.text('Cancel'), findsNothing);
    });

    testWidgets('Remove reaches the controller', (tester) async {
      await pump(tester, ctrl);

      await tester.tap(find.byIcon(LucideIcons.ellipsis).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(ctrl.removeCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Rename opens a dialog and saves', (tester) async {
      await pump(tester, ctrl);

      await tester.tap(find.byIcon(LucideIcons.ellipsis).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      expect(find.text('Rename contact'), findsOneWidget);
      expect(find.byType(ShadInput), findsOneWidget);

      await tester.enterText(find.byType(ShadInput), 'Renamed');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(ctrl.renameCalls, 1);
    });

    testWidgets('Rename with a blank name is discarded', (tester) async {
      await pump(tester, ctrl);

      await tester.tap(find.byIcon(LucideIcons.ellipsis).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(ShadInput), '   ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(ctrl.renameCalls, 0);
    });

    testWidgets('Add contact opens a two-field dialog', (tester) async {
      await pump(tester, ctrl);

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.text('Add contact'), findsOneWidget);
      expect(find.byType(ShadInput), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });

  group('transfers', () {
    testWidgets('active transfer shows a progress bar and cancel',
        (tester) async {
      await pump(
        tester,
        _StubController(
          peers: [_contact('Bob', 'kb')],
          batches: {
            's1': _batch(sending: true, status: TransferStatus.active),
          },
        ),
      );

      expect(find.text('Transfers'), findsOneWidget);
      expect(find.text('In progress'), findsOneWidget);
      expect(find.byType(ShadProgress), findsOneWidget);
      // 40 of 100 bytes.
      expect(find.text('40%'), findsOneWidget);
      expect(find.byIcon(LucideIcons.circleX), findsOneWidget);
      // Sending, so the up arrow.
      expect(find.byIcon(LucideIcons.circleArrowUp), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('finished transfer drops cancel and offers Clear finished',
        (tester) async {
      await pump(
        tester,
        _StubController(
          batches: {
            's1': _batch(
              sending: false,
              status: TransferStatus.done,
              bytes: 100,
            ),
          },
        ),
      );

      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Clear finished'), findsOneWidget);
      expect(find.byIcon(LucideIcons.circleX), findsNothing);
      expect(find.byIcon(LucideIcons.circleArrowDown), findsOneWidget);
    });

    testWidgets('failed transfer surfaces its error', (tester) async {
      final batch = _batch(sending: true, status: TransferStatus.failed)
        ..error = 'peer closed the connection';
      await pump(tester, _StubController(batches: {'s1': batch}));

      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('peer closed the connection'), findsOneWidget);
    });
  });
}
