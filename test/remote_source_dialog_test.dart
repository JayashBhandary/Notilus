import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show DefaultMaterialLocalizations, ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/models/remote/remote_connection.dart';
import 'package:notilus/providers/browser_provider.dart';
import 'package:notilus/services/file_service.dart';
import 'package:notilus/theme.dart';
import 'package:notilus/utils/platform.dart';
import 'package:notilus/widgets/remote/remote_source_dialog.dart';

/// The add-a-source form.
///
/// It asks for up to seven fields, and on a phone the chrome around them — a
/// two-line blurb, five wrapped kind buttons, three full-width action buttons —
/// left the form itself a sliver with a half-drawn field at the bottom. These
/// pin the shape that fixed it: one picker, one row of actions, and the fields
/// nobody needs behind a disclosure.
void main() {
  Widget host() => MultiProvider(
        providers: [
          ChangeNotifierProvider<BrowserProvider>(
            create: (_) => BrowserProvider(FileService()),
          ),
        ],
        child: ShadApp.custom(
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
        ),
      );

  Future<void> open(
    WidgetTester tester, {
    required bool mobile,
    Size size = const Size(393, 852),
  }) async {
    debugMobilePlatformOverride = mobile;
    addTearDown(() => debugMobilePlatformOverride = null);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    showRemoteSourceDialog(tester.element(find.byType(SizedBox).first));
    await tester.pumpAndSettle();
  }

  group('on a phone', () {
    testWidgets('the kind is one picker, not five wrapped buttons',
        (tester) async {
      await open(tester, mobile: true);

      expect(find.byType(ShadSelect<RemoteKind>), findsOneWidget);
      // The picker names the current choice in full, where a button could only
      // fit "S3".
      expect(find.text('S3 or compatible'), findsOneWidget);
      expect(find.text('Drive'), findsNothing);
      expect(find.text('WebDAV'), findsNothing);
    });

    testWidgets('the blurb goes and the actions share one row', (tester) async {
      await open(tester, mobile: true);

      expect(find.textContaining('Browse cloud storage'), findsNothing);
      expect(find.text('Add'), findsOneWidget);
      expect(find.text('Test'), findsOneWidget);
      // The close button in the corner is what Cancel did.
      expect(find.text('Cancel'), findsNothing);

      final add = tester.getRect(find.text('Add'));
      final test = tester.getRect(find.text('Test'));
      expect(
        (add.center.dy - test.center.dy).abs(),
        lessThan(2),
        reason: 'side by side, not stacked',
      );
    });

    testWidgets('the self-hosted fields wait behind Advanced', (tester) async {
      await open(tester, mobile: true);

      // The four every bucket needs.
      expect(find.text('Access key ID'), findsOneWidget);
      expect(find.text('Bucket'), findsOneWidget);
      // The two only a self-hosted server needs.
      expect(find.text('Endpoint'), findsNothing);
      expect(find.text('Force path-style URLs'), findsNothing);

      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();

      expect(find.text('Endpoint'), findsOneWidget);
      expect(find.text('Force path-style URLs'), findsOneWidget);
    });

    testWidgets('switching kind closes Advanced again', (tester) async {
      await open(tester, mobile: true);

      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      expect(find.text('Endpoint'), findsOneWidget);

      await tester.tap(find.byType(ShadSelect<RemoteKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SMB share').last);
      await tester.pumpAndSettle();

      // SMB hides different things back there, so it opens closed.
      expect(find.text('Share'), findsWidgets, reason: 'SMB fields are up');
      expect(find.text('Workgroup or domain'), findsNothing);
    });
  });

  group('on a desktop', () {
    testWidgets('keeps the button row, the blurb and Cancel', (tester) async {
      await open(tester, mobile: false, size: const Size(900, 800));

      expect(find.byType(ShadSelect<RemoteKind>), findsNothing);
      // Two "S3" on this one: the kind button, and the default name in the
      // Name field's placeholder.
      expect(find.text('S3'), findsWidgets);
      expect(find.text('WebDAV'), findsOneWidget);
      expect(find.textContaining('Browse cloud storage'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('hides the advanced fields the same way', (tester) async {
      await open(tester, mobile: false, size: const Size(900, 800));

      expect(find.text('Endpoint'), findsNothing);
      await tester.ensureVisible(find.text('Advanced'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      expect(find.text('Endpoint'), findsOneWidget);
    });
  });
}
