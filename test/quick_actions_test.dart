import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/models/file_entry.dart';
import 'package:notilus/providers/browser_provider.dart';
import 'package:notilus/providers/file_ops_provider.dart';
import 'package:notilus/services/file_service.dart';
import 'package:notilus/services/native_core.dart';
import 'package:notilus/theme.dart';
import 'package:notilus/widgets/file_list_view.dart';

import 'native_test_support.dart';

/// The context menu's Quick Actions submenu, and the Rust behind it.
///
/// Two halves: the menu is driven through the same `showRowContextMenu` the
/// list and grid call, so the per-type branching is covered as the user meets
/// it; the actions themselves run against the real native core, because their
/// whole point is that the byte work happens there.
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

  FileEntry entry(String path, {bool isDirectory = false}) => FileEntry(
        path: path,
        name: p.basename(path),
        isDirectory: isDirectory,
        size: 10,
        modified: DateTime(2026, 1, 1),
      );

  /// Opens the row menu for [target] and walks into its Quick Actions submenu.
  Future<void> openQuickActions(
    WidgetTester tester,
    FileEntry target, {
    Set<String> selection = const {},
  }) async {
    final browser = BrowserProvider(FileService());
    if (selection.isNotEmpty) browser.replaceSelection(selection);
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(browser));
    await tester.pumpAndSettle();

    showRowContextMenu(
      tester.element(find.byType(SizedBox).first),
      browser,
      target,
      const Offset(120, 120),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Quick Actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('the Quick Actions submenu is built from what is under the cursor', () {
    testWidgets('a folder is offered compression and a size walk',
        (tester) async {
      await openQuickActions(tester, entry('/x/Photos', isDirectory: true));

      expect(find.text('Compress'), findsOneWidget);
      expect(find.text('Calculate Folder Size'), findsOneWidget);
      // Image and archive actions make no sense on a folder.
      expect(find.text('Rotate Left'), findsNothing);
      expect(find.text('Extract Here'), findsNothing);
      // Neither does hashing something with no bytes of its own.
      expect(find.text('Copy SHA-256'), findsNothing);
    });

    testWidgets('an archive is offered both extraction destinations',
        (tester) async {
      await openQuickActions(tester, entry('/x/bundle.tar.gz'));

      // The label names the folder that will actually appear — every archive
      // suffix stripped, not just the last one.
      expect(find.text('Extract to "bundle"'), findsOneWidget);
      expect(find.text('Extract Here'), findsOneWidget);
    });

    testWidgets('an image is offered rotation and conversion', (tester) async {
      await openQuickActions(tester, entry('/x/shot.jpg'));

      expect(find.text('Rotate Left'), findsOneWidget);
      expect(find.text('Rotate Right'), findsOneWidget);
      expect(find.text('Flip Horizontally'), findsOneWidget);
      expect(find.text('Convert To'), findsOneWidget);
      expect(find.text('Copy SHA-256'), findsOneWidget);
    });

    testWidgets('a format the core cannot re-encode gets conversion only',
        (tester) async {
      // A GIF decodes fine but can't be written back without dropping its
      // animation, so offering "Rotate" would be a trap.
      await openQuickActions(tester, entry('/x/anim.gif'));

      expect(find.text('Convert To'), findsOneWidget);
      expect(find.text('Rotate Left'), findsNothing);
    });

    testWidgets('a plain file gets the type-independent actions only',
        (tester) async {
      await openQuickActions(tester, entry('/x/notes.txt'));

      expect(find.text('Compress'), findsOneWidget);
      expect(find.text('Copy SHA-256'), findsOneWidget);
      expect(find.text('Convert To'), findsNothing);
      expect(find.text('Extract Here'), findsNothing);
    });

    testWidgets('a multi-selection is offered only the action that takes a list',
        (tester) async {
      await openQuickActions(
        tester,
        entry('/x/a.jpg'),
        selection: {'/x/a.jpg', '/x/b.jpg', '/x/c.jpg'},
      );

      expect(find.text('Compress 3 Items'), findsOneWidget);
      // Per-type actions need one unambiguous subject.
      expect(find.text('Rotate Left'), findsNothing);
      expect(find.text('Copy SHA-256'), findsNothing);
    });
  });

  group('the display toggles live under View', () {
    testWidgets('the root menu no longer carries them', (tester) async {
      final browser = BrowserProvider(FileService());
      await tester.pumpWidget(host(browser));
      await tester.pumpAndSettle();

      showBackgroundContextMenu(
        tester.element(find.byType(SizedBox).first),
        browser,
        const Offset(120, 120),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('View'), findsOneWidget);
      expect(find.text('Sort By'), findsNothing);
      expect(find.text('Use Groups'), findsNothing);
      expect(find.text('Show Hidden Files/Folders'), findsNothing);

      await tester.tap(find.text('View'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('as Icons'), findsOneWidget);
      expect(find.text('as List'), findsOneWidget);
      expect(find.text('Sort By'), findsOneWidget);
      expect(find.text('Use Groups'), findsOneWidget);
      expect(find.text('Show Hidden Files/Folders'), findsOneWidget);
      expect(find.text('Show View Options'), findsOneWidget);
    });

    testWidgets('the view-mode entries drive the provider', (tester) async {
      final browser = BrowserProvider(FileService());
      await tester.pumpWidget(host(browser));
      await tester.pumpAndSettle();

      showBackgroundContextMenu(
        tester.element(find.byType(SizedBox).first),
        browser,
        const Offset(120, 120),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('View'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(browser.viewMode, ViewMode.icons);
      await tester.tap(find.text('as List'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(browser.viewMode, ViewMode.list);
    });
  });

  group('the native side', () {
    late Directory root;
    late bool native;

    setUpAll(() async {
      native = await NativeTestSupport.ensureLoaded();
    });

    setUp(() async {
      root = await Directory.systemTemp.createTemp('quick_actions_test_');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<File> write(String relative, String contents) async {
      final f = File(p.join(root.path, relative));
      await f.parent.create(recursive: true);
      await f.writeAsString(contents);
      return f;
    }

    /// Drains a Quick Action stream to its outcome.
    Future<QuickOutcome> drain(Stream<QuickEvent> events) async {
      QuickOutcome? outcome;
      await for (final event in events) {
        if (event is QuickEvent_Done) outcome = event.field0;
      }
      return outcome!;
    }

    test('compress then extract round-trips a folder', () async {
      if (!native) return markTestSkipped(NativeTestSupport.skipReason);
      final core = NativeCore.instance;
      await write('src/hello.txt', 'hello world');
      await write('src/nested/deep.txt', 'deeper');

      final zipped = await drain(core.compress(
        sources: [p.join(root.path, 'src')],
        destDir: root.path,
        archiveName: 'src',
        opId: core.newOpId(),
      ));
      expect(zipped.cancelled, isFalse);
      expect(zipped.failed, isEmpty);
      expect(p.basename(zipped.produced.single), 'src.zip');

      // The entries are rooted at the folder's own name, which is what makes
      // the archive unpack into one folder instead of a pile of loose files.
      final names = (await core.listArchive(zipped.produced.single))
          .map((e) => e.name)
          .toList();
      expect(names, contains('src/hello.txt'));
      expect(names, contains('src/nested/deep.txt'));

      final dest = Directory(p.join(root.path, 'out'))..createSync();
      final extracted = await drain(core.extractArchive(
        path: zipped.produced.single,
        destDir: dest.path,
        opId: core.newOpId(),
      ));
      expect(extracted.failed, isEmpty);
      final produced = extracted.produced.single;
      expect(p.basename(produced), 'src');
      expect(
        File(p.join(produced, 'src', 'hello.txt')).readAsStringSync(),
        'hello world',
      );
    });

    test('compressing twice never overwrites the first archive', () async {
      if (!native) return markTestSkipped(NativeTestSupport.skipReason);
      final core = NativeCore.instance;
      final file = await write('notes.txt', 'x');

      final first = await drain(core.compress(
        sources: [file.path],
        destDir: root.path,
        archiveName: 'notes',
        opId: core.newOpId(),
      ));
      final second = await drain(core.compress(
        sources: [file.path],
        destDir: root.path,
        archiveName: 'notes',
        opId: core.newOpId(),
      ));

      expect(second.produced.single, isNot(first.produced.single));
      expect(File(first.produced.single).existsSync(), isTrue);
    });

    test('a folder walk totals the tree and names its biggest file', () async {
      if (!native) return markTestSkipped(NativeTestSupport.skipReason);
      final core = NativeCore.instance;
      await write('a.txt', 'ab');
      await write('nested/big.txt', 'x' * 500);

      FolderStats? stats;
      await for (final event
          in core.folderStats(path: root.path, opId: core.newOpId())) {
        if (event is StatsEvent_Done) stats = event.field0;
      }

      expect(stats, isNotNull);
      expect(stats!.files.toInt(), 2);
      expect(stats.dirs.toInt(), 1);
      expect(stats.bytes.toInt(), 502);
      expect(p.basename(stats.largestPath), 'big.txt');
      expect(stats.cancelled, isFalse);
    });

    test('an entry that would escape the destination is refused', () async {
      if (!native) return markTestSkipped(NativeTestSupport.skipReason);
      final core = NativeCore.instance;

      // The "zip slip" traversal: an entry whose name climbs out of the folder
      // it is being unpacked into. Rust screens names before writing, which is
      // why extraction doesn't just call the zip crate's own `extract`.
      final archive = Archive()
        ..addFile(ArchiveFile.string('../escaped.txt', 'pwned'))
        ..addFile(ArchiveFile.string('safe.txt', 'fine'));
      final zipPath = p.join(root.path, 'hostile.zip');
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive)!);

      final dest = Directory(p.join(root.path, 'out'))..createSync();
      final outcome = await drain(core.extractArchive(
        path: zipPath,
        destDir: dest.path,
        opId: core.newOpId(),
        intoSubfolder: false,
      ));

      expect(outcome.failed, hasLength(1));
      expect(outcome.failed.single.path, contains('escaped.txt'));
      expect(File(p.join(root.path, 'escaped.txt')).existsSync(), isFalse);
      // The safe entry still lands: one hostile name doesn't cost the rest.
      expect(File(p.join(dest.path, 'safe.txt')).existsSync(), isTrue);
    });
  });
}
