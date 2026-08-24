import 'dart:io';

import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/models/file_entry.dart';
import 'package:notilus/screens/preview/preview_common.dart';
import 'package:notilus/screens/preview/preview_viewers.dart';
import 'package:notilus/services/native_core.dart';
import 'package:notilus/theme.dart';

import 'native_test_support.dart';

/// The `.eml` / `.msg` preview, from routing through to what the viewer shows.
///
/// Parsing itself is covered by the Rust suite; what is checked here is that
/// the app asks for it, renders the parts a reader needs, and doesn't render
/// the parts it shouldn't — an HTML body is deliberately shown as text, never
/// as live markup that could fetch a tracking pixel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Decided synchronously: `skip:` is read while the suite is registered, so a
  // flag set later in setUpAll would come too late.
  final needsCore = !NativeTestSupport.isBuilt;
  late Directory dir;

  setUpAll(() async {
    if (needsCore) return;
    await NativeTestSupport.ensureLoaded();
  });

  setUp(() async {
    if (needsCore) return;
    dir = await Directory.systemTemp.createTemp('notilus-mail-test-');
  });

  tearDown(() async {
    if (!needsCore && dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<FileEntry> writeMessage(String name, String content) async {
    final file = File(p.join(dir.path, name));
    await file.writeAsString(content);
    final entry = await FileEntry.from(file);
    return entry!;
  }

  Widget host(Widget child) => ShadApp.custom(
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
          home: child,
        ),
      );

  /// Writes a message and mounts the viewer on it.
  ///
  /// Everything that touches the real world happens inside `runAsync`: a
  /// `testWidgets` body runs in a fake-async zone where file I/O and the FFI
  /// call into the parser never complete. Mounting itself stays outside it, so
  /// the loading spinner's endless animation is driven by the fake clock rather
  /// than the real one.
  Future<void> pumpViewer(
    WidgetTester tester,
    String name,
    String content,
  ) async {
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    FileEntry? entry;
    await tester.runAsync(() async => entry = await writeMessage(name, content));
    await tester.pumpWidget(host(EmailViewer(file: entry!)));
    // Long enough for the parse to come back from Rust.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
  }

  group('routing', () {
    FileEntry entry(String name) => FileEntry(
          path: '/tmp/$name',
          name: name,
          isDirectory: false,
          size: 1,
          modified: DateTime(2024),
        );

    test('mail extensions get the email viewer', () {
      expect(previewKindFor(entry('note.eml')), PreviewKind.email);
      expect(previewKindFor(entry('Meeting.MSG')), PreviewKind.email);
      expect(previewKindFor(entry('note.txt')), PreviewKind.text);
    });

    test('the kind label reads as mail, not as an unknown extension', () {
      expect(previewKind('.eml'), 'Email message');
      expect(previewKind('.msg'), 'Outlook message');
    });
  });

  group('the viewer', () {
    testWidgets('shows the header block and the body', (tester) async {
      await pumpViewer(
        tester,
        'simple.eml',
        'From: Ada Lovelace <ada@example.com>\r\n'
        'To: charles@example.com\r\n'
        'Subject: Analytical Engine\r\n'
        'Date: Tue, 5 Mar 2024 09:30:00 +0100\r\n'
        'Content-Type: text/plain; charset=utf-8\r\n'
        '\r\n'
        'Notes on the engine.\r\n',
      );

      expect(find.text('Analytical Engine'), findsOneWidget);
      expect(find.text('Ada Lovelace <ada@example.com>'), findsOneWidget);
      expect(find.text('charles@example.com'), findsOneWidget);
      // The header's own spelling of the date, which carries the sender's
      // timezone rather than a reformatted UTC stamp.
      expect(find.text('Tue, 5 Mar 2024 09:30:00 +0100'), findsOneWidget);
      expect(find.text('Notes on the engine.'), findsOneWidget);
    }, skip: needsCore);

    testWidgets('a message with no subject says so rather than showing nothing',
        (tester) async {
      await pumpViewer(
        tester,
        'bare.eml',
        'From: a@b.test\r\nContent-Type: text/plain\r\n\r\nbody\r\n',
      );

      expect(find.text('(no subject)'), findsOneWidget);
    }, skip: needsCore);

    testWidgets('an HTML body is shown as text, with its source behind a tab',
        (tester) async {
      await pumpViewer(
        tester,
        'html.eml',
        'Subject: Newsletter\r\n'
        'Content-Type: text/html; charset=utf-8\r\n'
        '\r\n'
        '<p>Hello there</p><p>Second para</p>\r\n',
      );

      expect(find.textContaining('Hello there'), findsOneWidget);
      expect(find.textContaining('<p>'), findsNothing);

      await tester.tap(find.text('HTML source'));
      await tester.pump();
      expect(find.textContaining('<p>Hello there</p>'), findsOneWidget);
    }, skip: needsCore);

    testWidgets('headers are available in full', (tester) async {
      await pumpViewer(
        tester,
        'headers.eml',
        'Subject: Routed\r\n'
        'X-Spam-Score: 0.1\r\n'
        'Content-Type: text/plain\r\n'
        '\r\n'
        'body\r\n',
      );

      await tester.tap(find.text('Headers'));
      await tester.pump();
      expect(find.text('X-Spam-Score'), findsOneWidget);
      expect(find.text('0.1'), findsOneWidget);
    }, skip: needsCore);

    testWidgets('attachments are listed and can be saved beside the message',
        (tester) async {
      await pumpViewer(
        tester,
        'withfile.eml',
        'Subject: Report\r\n'
        'Content-Type: multipart/mixed; boundary="XX"\r\n'
        '\r\n'
        '--XX\r\n'
        'Content-Type: text/plain; charset=utf-8\r\n'
        '\r\n'
        'See attached.\r\n'
        '--XX\r\n'
        'Content-Type: application/pdf; name="q1.pdf"\r\n'
        'Content-Disposition: attachment; filename="q1.pdf"\r\n'
        'Content-Transfer-Encoding: base64\r\n'
        '\r\n'
        'JVBERi0=\r\n'
        '--XX--\r\n',
      );

      expect(find.text('1 attachment'), findsOneWidget);
      expect(find.text('q1.pdf'), findsOneWidget);

      await tester.tap(find.byIcon(LucideIcons.download));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();

      final saved = File(p.join(dir.path, 'q1.pdf'));
      expect(saved.existsSync(), isTrue);
      expect(saved.readAsBytesSync(), '%PDF-'.codeUnits);
      expect(find.text('Saved q1.pdf'), findsOneWidget);
    }, skip: needsCore);

    testWidgets('a file that isn\'t mail explains itself instead of crashing',
        (tester) async {
      await pumpViewer(tester, 'broken.msg', 'this is not a .msg file');

      expect(find.text('Couldn\'t read this message'), findsOneWidget);
    }, skip: needsCore);
  });

  group('saving', () {
    test('an attachment never overwrites what is already there', () async {
      final entry = await writeMessage(
        'collide.eml',
        'Content-Type: multipart/mixed; boundary="B"\r\n'
        '\r\n'
        '--B\r\n'
        'Content-Type: text/plain\r\n'
        '\r\n'
        'body\r\n'
        '--B\r\n'
        'Content-Type: text/plain; name="notes.txt"\r\n'
        'Content-Disposition: attachment; filename="notes.txt"\r\n'
        '\r\n'
        'from the mail\r\n'
        '--B--\r\n',
      );
      final existing = File(p.join(dir.path, 'notes.txt'));
      await existing.writeAsString('already here');

      final written = await NativeCore.instance.saveEmailAttachment(
        path: entry.path,
        index: 0,
        destDir: dir.path,
      );
      expect(p.basename(written), 'notes (2).txt');
      expect(await existing.readAsString(), 'already here');
    }, skip: needsCore ? NativeTestSupport.skipReason : null);
  });
}
