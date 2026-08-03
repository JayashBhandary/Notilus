import 'dart:async';
import 'dart:io';

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
import 'package:notilus/screens/transfer/send_to.dart';
import 'package:notilus/services/transfer/file_transfer.dart';
import 'package:notilus/theme.dart';

/// Stubs the controller so the picker and the outcome reporting can be driven
/// without a peer.
///
/// `sendFiles` blocks on [gate] rather than returning straight away: the real
/// call waits on a remote accept, and if the stub resolved immediately the
/// "Waiting…" dialog would be pushed and popped inside a single frame, so no
/// test could ever observe it. Call [settle] to release it.
class _StubController extends TransferController {
  _StubController({
    this.configured = true,
    this.isReady = true,
    this.peers = const [],
    this.onlineCodes = const {},
    this.acceptSend = true,
  });

  final bool configured;
  final bool isReady;
  final List<Contact> peers;
  final Set<String> onlineCodes;
  final bool acceptSend;

  final gate = Completer<bool>();
  Contact? sentTo;
  int sendCalls = 0;

  /// Releases a pending [sendFiles] with the configured accept/decline answer.
  void settle() {
    if (!gate.isCompleted) gate.complete(acceptSend);
  }

  @override
  bool get isConfigured => configured;
  @override
  bool get ready => isReady;
  @override
  String? get error => null;
  @override
  List<Contact> get contacts => peers;
  @override
  bool isOnline(String code) => onlineCodes.contains(code);

  @override
  Future<bool> sendFiles(Contact to, List<OutgoingFile> files) {
    sendCalls++;
    sentTo = to;
    return gate.future;
  }
}

Contact _contact(String name, String key) =>
    Contact(name: name, deviceId: 'dev-$key', publicKey: key);

void main() {
  setUpAll(() {
    dotenv.loadFromString(envString: 'NOTILUS_TEST=1');
  });

  late Directory tmp;
  late List<String> paths;

  setUp(() async {
    // showSendToSheet drops anything that is not a readable regular file, so
    // the fixture has to be real files on disk.
    tmp = await Directory.systemTemp.createTemp('notilus_sendto_test');
    paths = [
      for (final n in ['a.txt', 'b.txt'])
        (File('${tmp.path}/$n')..writeAsStringSync('x' * 512)).path,
    ];
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// Mounts a button that opens the send-to flow, and returns the stub.
  Future<void> pumpLauncher(
    WidgetTester tester,
    TransferController ctrl,
    List<String> filePaths,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ShadApp.custom(
        theme: AppTheme.shadThemeFor(Brightness.light),
        darkTheme: AppTheme.shadThemeFor(Brightness.dark),
        themeMode: ThemeMode.light,
        // ShadAppBuilder is what installs ShadToaster, which the outcome
        // reporting needs; content lives in `home` so showShadDialog has a
        // Navigator to push onto. Mirrors app.dart.
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
            child: Builder(
              builder: (ctx) => Center(
                child: ShadButton(
                  onPressed: () => showSendToSheet(ctx, filePaths),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  group('preconditions stay modal', () {
    testWidgets('folders only → nothing to send', (tester) async {
      await pumpLauncher(tester, _StubController(), [tmp.path]);

      expect(find.text('Nothing to send'), findsOneWidget);
      expect(find.byType(ShadDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('not configured', (tester) async {
      await pumpLauncher(tester, _StubController(configured: false), paths);
      expect(find.text('File transfer isn’t set up'), findsOneWidget);
    });

    testWidgets('not ready', (tester) async {
      await pumpLauncher(tester, _StubController(isReady: false), paths);
      expect(find.text('Still connecting'), findsOneWidget);
    });

    testWidgets('no contacts', (tester) async {
      await pumpLauncher(tester, _StubController(), paths);
      expect(find.text('No contacts yet'), findsOneWidget);
    });
  });

  group('picker', () {
    testWidgets('lists every contact with its presence', (tester) async {
      final bob = _contact('Bob’s laptop', 'kb');
      await pumpLauncher(
        tester,
        _StubController(
          peers: [bob, _contact('Phone', 'kp')],
          onlineCodes: {bob.code},
        ),
        paths,
      );

      // Title reflects the resolved file count, not the raw path count.
      expect(find.text('Send 2 files'), findsOneWidget);
      // 2 × 512 B; formatBytes uses no decimals at KB.
      expect(find.text('1 KB'), findsOneWidget);
      expect(find.text('Bob’s laptop'), findsOneWidget);
      expect(find.text('Phone'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('singular title for one file', (tester) async {
      await pumpLauncher(
        tester,
        _StubController(peers: [_contact('Bob', 'kb')]),
        [paths.first],
      );
      expect(find.text('Send 1 file'), findsOneWidget);
    });

    testWidgets('Cancel sends nothing', (tester) async {
      final ctrl = _StubController(peers: [_contact('Bob', 'kb')]);
      await pumpLauncher(tester, ctrl, paths);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(ctrl.sendCalls, 0);
      expect(find.byType(ShadDialog), findsNothing);
    });
  });

  group('outcomes are toasted', () {
    // pumpAndSettle is unusable across this stretch of the flow: the waiting
    // dialog holds a ShadSpinner, whose controller repeats forever, and the
    // toast that follows schedules a 5s auto-dismiss. Both are pumped by hand.
    const beat = Duration(milliseconds: 400);
    const pastToast = Duration(seconds: 6);

    testWidgets('accepted → toast, no modal left behind', (tester) async {
      final bob = _contact('Bob’s laptop', 'kb');
      final ctrl = _StubController(peers: [bob], acceptSend: true);
      await pumpLauncher(tester, ctrl, paths);

      await tester.tap(find.text('Bob’s laptop'));
      await tester.pump();
      await tester.pump(beat);
      // Waiting dialog stays up while sendFiles is in flight.
      expect(find.text('Waiting…'), findsOneWidget);
      expect(find.byType(ShadToast), findsNothing);

      ctrl.settle();
      await tester.pump();
      await tester.pump(beat);

      expect(ctrl.sendCalls, 1);
      expect(ctrl.sentTo, same(bob));
      expect(find.byType(ShadToast), findsOneWidget);
      expect(find.text('Sending…'), findsOneWidget);
      // The point of toasting: nothing is left for the user to dismiss.
      expect(find.byType(ShadDialog), findsNothing);
      expect(find.text('OK'), findsNothing);
      expect(tester.takeException(), isNull);

      // Let the auto-dismiss timer fire, or it outlives the widget tree.
      await tester.pump(pastToast);
      await tester.pump(beat);
      expect(find.byType(ShadToast), findsNothing);
    });

    testWidgets('declined → destructive toast', (tester) async {
      final ctrl = _StubController(
        peers: [_contact('Bob', 'kb')],
        acceptSend: false,
      );
      await pumpLauncher(tester, ctrl, paths);

      await tester.tap(find.text('Bob'));
      await tester.pump();
      await tester.pump(beat);
      ctrl.settle();
      await tester.pump();
      await tester.pump(beat);

      expect(find.text('Declined / timed out'), findsOneWidget);
      expect(find.byType(ShadToast), findsOneWidget);
      expect(find.byType(ShadDialog), findsNothing);

      await tester.pump(pastToast);
      await tester.pump(beat);
    });
  });
}
