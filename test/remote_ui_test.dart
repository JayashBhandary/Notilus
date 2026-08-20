import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/models/remote/remote_connection.dart';
import 'package:notilus/providers/browser_provider.dart';
import 'package:notilus/providers/copy_jobs_provider.dart';
import 'package:notilus/services/file_service.dart';
import 'package:notilus/services/remote/remote_file_system.dart';
import 'package:notilus/services/remote/remote_hub.dart';
import 'package:notilus/services/remote/remote_path.dart';
import 'package:notilus/theme.dart';
import 'package:notilus/widgets/remote/transfer_hud.dart';
import 'package:notilus/widgets/sidebar.dart';

/// The two places the remote feature shows itself: the sidebar row that mounts
/// a source, and the corner HUD that reports a transfer.
class _StubBrowser extends BrowserProvider {
  _StubBrowser() : super(FileService());

  final List<String> navigated = [];

  @override
  List<DriveEntry> get drives =>
      [DriveEntry(name: 'Macintosh HD', path: '/', isRoot: true)];

  @override
  Map<String, String?> get shortcuts => const {'Home': '/Users/test'};

  @override
  String get currentPath => '/';

  @override
  CenterView get centerView => CenterView.files;

  @override
  Future<void> navigateTo(String path) async => navigated.add(path);

  @override
  Future<void> refreshDrives() async {}
}

/// A provider that never gets asked anything — the sidebar only needs it to
/// exist for the connection to appear.
class _InertRemote extends RemoteFileSystem {
  _InertRemote(super.connectionId);

  @override
  Future<void> connect() async {}

  @override
  Future<List<RemoteEntry>> list(String vpath) async => const [];

  @override
  Future<RemoteEntry?> stat(String vpath) async => null;

  @override
  Future<RemoteDownload> download(String vpath) async =>
      throw RemoteException('not used');

  @override
  Future<void> upload({
    required String vpath,
    required Stream<List<int>> data,
    required int length,
  }) async {}

  @override
  Future<void> createDirectory(String vpath) async {}

  @override
  Future<void> delete(String vpath, {required bool isDirectory}) async {}

  @override
  Future<String> rename(String vpath, String newName) async => vpath;
}

void main() {
  Widget host(Widget child, {BrowserProvider? browser, CopyJobs? jobs}) {
    Widget body = child;
    if (jobs != null) {
      body = ChangeNotifierProvider<CopyJobs>.value(value: jobs, child: body);
    }
    if (browser != null) {
      body = ChangeNotifierProvider<BrowserProvider>.value(
        value: browser,
        child: body,
      );
    }
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
        home: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [Flexible(child: body)],
        ),
      ),
    );
  }

  Future<void> pump(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    await tester.pump(const Duration(milliseconds: 300));
  }

  tearDown(RemoteHub.instance.resetForTesting);

  group('sidebar locations', () {
    testWidgets('offers a way in when no source is configured', (tester) async {
      final browser = _StubBrowser();
      await pump(tester, host(const Sidebar(), browser: browser));

      expect(find.text('Add remote source…'), findsOneWidget);
      // The `+` beside the Locations header is the durable entry point.
      expect(find.bySemanticsLabel('Add a remote source'), findsOneWidget);
    });

    testWidgets('lists a mounted source and opens it on tap', (tester) async {
      RemoteHub.instance.mountForTesting(
        const RemoteConnection(
          id: 'conn-9',
          kind: RemoteKind.s3,
          label: 'Work S3',
        ),
        _InertRemote('conn-9'),
      );
      final browser = _StubBrowser();
      await pump(tester, host(const Sidebar(), browser: browser));

      expect(find.text('Work S3'), findsOneWidget);
      // The prompt row is only for an empty list.
      expect(find.text('Add remote source…'), findsNothing);

      await tester.tap(find.text('Work S3'));
      await tester.pump();
      expect(browser.navigated, [VPath.root('conn-9')]);
      expect(tester.takeException(), isNull);
    });
  });

  group('transfer HUD', () {
    testWidgets('stays out of the way when nothing is running',
        (tester) async {
      final jobs = CopyJobs();
      addTearDown(jobs.dispose);
      await pump(tester, host(const TransferHud(), jobs: jobs));

      expect(find.byType(TransferHud), findsOneWidget);
      expect(find.textContaining('transfer'), findsNothing);
    });

    testWidgets('shows a running job and cancels it', (tester) async {
      final jobs = CopyJobs();
      addTearDown(jobs.dispose);
      final id =
          jobs.start(title: 'Copying to Work S3', direction: CopyDirection.upload);
      jobs.update(id, filesTotal: 3, bytesTotal: 1000, current: '/tmp/big.iso');
      jobs.addBytes(id, 250);

      await pump(tester, host(const TransferHud(), jobs: jobs));

      expect(find.text('1 transfer in progress'), findsOneWidget);
      expect(find.text('Copying to Work S3'), findsOneWidget);
      expect(find.text('big.iso'), findsOneWidget);
      expect(find.textContaining('of 1000 B'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Cancel'));
      await tester.pump();
      expect(jobs.isCancelled(id), isTrue);
      expect(find.text('Stopping…'), findsOneWidget);
    });

    testWidgets('a failure stays until dismissed, with its reason',
        (tester) async {
      final jobs = CopyJobs();
      addTearDown(jobs.dispose);
      final id = jobs.start(
        title: 'Copying to Work S3',
        direction: CopyDirection.upload,
      );
      jobs.finish(id, state: CopyJobState.failed, error: 'Access denied');

      await pump(tester, host(const TransferHud(), jobs: jobs));
      expect(find.text('Access denied'), findsOneWidget);

      // Well past the auto-dismiss window a successful job would have used.
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Access denied'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Dismiss'));
      await tester.pump();
      expect(jobs.hasJobs, isFalse);
    });
  });
}
