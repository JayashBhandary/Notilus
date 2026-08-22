import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/models/file_entry.dart';
import 'package:notilus/providers/browser_provider.dart';
import 'package:notilus/providers/file_ops_provider.dart';
import 'package:notilus/screens/text_editor_screen.dart';
import 'package:notilus/services/file_service.dart';
import 'package:notilus/theme.dart';

/// The browser is only consulted so a save can refresh the folder it wrote
/// into; nothing here should reach the filesystem through it.
class _StubBrowser extends BrowserProvider {
  _StubBrowser() : super(FileService());

  int refreshes = 0;

  @override
  String get currentPath => '/nowhere';

  @override
  Future<void> refresh() async => refreshes++;
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('notilus-editor-ui'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  FileEntry write(String name, List<int> bytes) {
    final file = File(p.join(temp.path, name))..writeAsBytesSync(bytes);
    final stat = file.statSync();
    return FileEntry(
      path: file.path,
      name: name,
      isDirectory: false,
      size: stat.size,
      modified: stat.modified,
    );
  }

  Widget host(FileEntry entry, BrowserProvider browser) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<BrowserProvider>.value(value: browser),
        ChangeNotifierProvider<FileOpsProvider>(
          create: (_) => FileOpsProvider(),
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
          home: TextEditorScreen(entry: entry),
        ),
      ),
    );
  }

  /// Lets real file I/O complete, then rebuilds.
  ///
  /// `testWidgets` runs in a fake-async zone where `dart:io` futures never
  /// resolve on their own, and `pumpAndSettle` spins forever against the
  /// loading spinner's animation. Every step that touches the disk is wrapped
  /// in `runAsync` for that reason.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump();
    // Long enough for a dialog's entrance animation to finish.
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Pumps until [condition] holds, letting real I/O progress in between.
  /// A save is several chained disk operations, so one delay isn't a
  /// dependable amount of waiting.
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() condition, {
    String reason = 'condition never became true',
  }) async {
    for (var attempt = 0; attempt < 60; attempt++) {
      if (condition()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    fail(reason);
  }

  Future<void> pump(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(widget);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('shows the file and describes what it is', (tester) async {
    final entry = write('nginx.conf', utf8.encode('server {\n  listen 80;\n}'));

    await pump(tester, host(entry, _StubBrowser()));

    expect(find.text('server {\n  listen 80;\n}'), findsOneWidget);
    expect(find.text('nginx.conf'), findsOneWidget);
    expect(find.textContaining('LF'), findsOneWidget);
    expect(find.textContaining('UTF-8'), findsOneWidget);
    expect(find.textContaining('3 lines'), findsOneWidget);
    // Nothing has been touched yet.
    expect(find.text('Unsaved changes'), findsNothing);
  });

  testWidgets('typing marks the file dirty, and Save writes it', (tester) async {
    final entry = write('notes.txt', utf8.encode('before'));
    final browser = _StubBrowser();

    await pump(tester, host(entry, browser));

    await tester.enterText(find.byType(CupertinoTextField), 'after');
    await tester.pump();

    expect(find.text('Unsaved changes'), findsOneWidget);
    // The title carries the standard unsaved marker.
    expect(find.text('notes.txt •'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await settle(tester);
    await waitFor(
      tester,
      () => File(entry.path).readAsStringSync() == 'after',
      reason: 'the edit was never written to disk',
    );
    // The write lands before the editor has re-stamped the file and rebuilt.
    await waitFor(
      tester,
      () => find.text('Saved').evaluate().isNotEmpty,
      reason: 'the editor never reported the save',
    );
    expect(find.text('Unsaved changes'), findsNothing);
  });

  testWidgets('closing with unsaved work asks first', (tester) async {
    final entry = write('notes.txt', utf8.encode('before'));

    await pump(tester, host(entry, _StubBrowser()));
    await tester.enterText(find.byType(CupertinoTextField), 'edited');
    await tester.pump();

    await tester.tap(find.byIcon(CupertinoIcons.back));
    await settle(tester);

    expect(find.text('Save changes to "notes.txt"?'), findsOneWidget);

    await tester.tap(find.text('Discard'));
    await settle(tester);

    // Discarded, so the file on disk is untouched.
    expect(File(entry.path).readAsStringSync(), 'before');
  });

  testWidgets('a binary file is refused with a reason, not opened',
      (tester) async {
    final entry = write('blob.txt', [0x00, 0x01, 0x02, 0x03]);

    await pump(tester, host(entry, _StubBrowser()));

    expect(find.text('Can\'t edit this file'), findsOneWidget);
    expect(find.textContaining('binary'), findsOneWidget);
    expect(find.byType(CupertinoTextField), findsNothing);
  });

  testWidgets('a file that changed underneath prompts before overwriting',
      (tester) async {
    final entry = write('shared.txt', utf8.encode('mine'));

    await pump(tester, host(entry, _StubBrowser()));
    await tester.enterText(find.byType(CupertinoTextField), 'my edit');
    await tester.pump();

    // Somebody else saves while the editor is open.
    final file = File(entry.path)..writeAsStringSync('theirs, longer');
    file.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));

    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(find.text('Saved by someone else'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await settle(tester);

    // Their version stands, and the edit is still in the editor to deal with.
    expect(file.readAsStringSync(), 'theirs, longer');
    expect(find.text('Unsaved changes'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await settle(tester);
    await tester.tap(find.text('Overwrite'));
    await settle(tester);
    await waitFor(
      tester,
      () => file.readAsStringSync() == 'my edit',
      reason: 'the forced save never landed',
    );
  });
}
