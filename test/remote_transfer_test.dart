import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/models/remote/remote_connection.dart';
import 'package:notilus/providers/copy_jobs_provider.dart';
import 'package:notilus/services/remote/remote_file_system.dart';
import 'package:notilus/services/remote/remote_hub.dart';
import 'package:notilus/services/remote/remote_path.dart';
import 'package:notilus/services/remote/transfer_engine.dart';
import 'package:path/path.dart' as p;

/// An in-memory stand-in for a cloud provider.
///
/// The engine is written against [RemoteFileSystem] and nothing else, so a fake
/// that stores bytes in a map exercises every path — recursion, collisions,
/// moves, server-side copies — without a network or a bucket.
class FakeRemote extends RemoteFileSystem {
  FakeRemote(super.connectionId);

  /// vpath → contents.
  final Map<String, List<int>> files = {};
  final Set<String> dirs = {};
  int serverSideCopies = 0;
  int uploads = 0;

  @override
  Future<void> connect() async {}

  String _parentOf(String vpath) => VPath.dirname(vpath);

  @override
  Future<List<RemoteEntry>> list(String vpath) async {
    final out = <RemoteEntry>[];
    for (final dir in dirs) {
      if (_parentOf(dir) == vpath && dir != vpath) {
        out.add(RemoteEntry(
          path: dir,
          name: VPath.basename(dir),
          isDirectory: true,
          size: 0,
          modified: DateTime.utc(2024),
        ));
      }
    }
    for (final entry in files.entries) {
      if (_parentOf(entry.key) != vpath) continue;
      out.add(RemoteEntry(
        path: entry.key,
        name: VPath.basename(entry.key),
        isDirectory: false,
        size: entry.value.length,
        modified: DateTime.utc(2024),
      ));
    }
    return out;
  }

  @override
  Future<RemoteEntry?> stat(String vpath) async {
    if (VPath.parse(vpath)!.isRoot || dirs.contains(vpath)) {
      return RemoteEntry(
        path: vpath,
        name: VPath.basename(vpath),
        isDirectory: true,
        size: 0,
        modified: DateTime.utc(2024),
      );
    }
    final bytes = files[vpath];
    if (bytes == null) return null;
    return RemoteEntry(
      path: vpath,
      name: VPath.basename(vpath),
      isDirectory: false,
      size: bytes.length,
      modified: DateTime.utc(2024),
    );
  }

  /// Set to make the next download throw, for the error-path tests.
  RemoteException? failNextDownloadWith;

  @override
  Future<RemoteDownload> download(String vpath) async {
    final failure = failNextDownloadWith;
    if (failure != null) {
      failNextDownloadWith = null;
      throw failure;
    }
    final bytes = files[vpath];
    if (bytes == null) throw RemoteException('missing: $vpath');
    return RemoteDownload(
      stream: Stream.value(bytes),
      length: bytes.length,
    );
  }

  @override
  Future<void> upload({
    required String vpath,
    required Stream<List<int>> data,
    required int length,
  }) async {
    uploads++;
    final bytes = <int>[];
    await for (final chunk in data) {
      bytes.addAll(chunk);
    }
    files[vpath] = bytes;
  }

  @override
  Future<void> createDirectory(String vpath) async {
    dirs.add(vpath);
  }

  @override
  Future<void> delete(String vpath, {required bool isDirectory}) async {
    if (!isDirectory) {
      files.remove(vpath);
      return;
    }
    dirs.removeWhere((d) => d == vpath || VPath.isWithin(vpath, d));
    files.removeWhere((path, _) => VPath.isWithin(vpath, path));
  }

  @override
  Future<String> rename(String vpath, String newName) async {
    final destination = VPath.join(VPath.dirname(vpath), newName);
    final bytes = files.remove(vpath);
    if (bytes != null) files[destination] = bytes;
    return destination;
  }

  @override
  bool get supportsServerSideCopy => true;

  @override
  Future<void> copyWithin(String fromVPath, String toVPath) async {
    serverSideCopies++;
    files[toVPath] = List.of(files[fromVPath]!);
  }
}

void main() {
  late Directory temp;
  late CopyJobs jobs;
  late TransferEngine engine;
  late FakeRemote remote;

  const connectionId = 'fake-1';
  final root = VPath.root(connectionId);

  setUp(() {
    temp = Directory.systemTemp.createTempSync('notilus-transfer');
    jobs = CopyJobs();
    engine = TransferEngine(jobs: jobs);
    remote = FakeRemote(connectionId);
    RemoteHub.instance.resetForTesting();
    RemoteHub.instance.mountForTesting(
      const RemoteConnection(
        id: connectionId,
        kind: RemoteKind.s3,
        label: 'Fake',
      ),
      remote,
    );
  });

  tearDown(() {
    RemoteHub.instance.resetForTesting();
    jobs.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File writeLocal(String relative, String contents) {
    final file = File(p.join(temp.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    return file;
  }

  test('uploads a local file and reports a finished job', () async {
    final file = writeLocal('notes.txt', 'hello cloud');

    final report = await engine.transfer(
      sources: [file.path],
      destDir: root,
      move: false,
    );

    expect(report.isSuccess, isTrue);
    expect(
      utf8.decode(remote.files[VPath.join(root, 'notes.txt')]!),
      'hello cloud',
    );
    // The original stays put on a copy.
    expect(file.existsSync(), isTrue);

    final job = jobs.jobs.single;
    expect(job.state, CopyJobState.done);
    expect(job.title, contains('Fake'));
    expect(job.filesDone, 1);
    expect(job.bytesDone, 'hello cloud'.length);
  });

  test('uploads a folder, recreating its shape', () async {
    writeLocal('trip/a.txt', 'a');
    writeLocal('trip/raw/b.txt', 'bb');

    final report = await engine.transfer(
      sources: [p.join(temp.path, 'trip')],
      destDir: root,
      move: false,
    );

    expect(report.isSuccess, isTrue);
    expect(remote.dirs, contains(VPath.build(connectionId, '/trip')));
    expect(remote.dirs, contains(VPath.build(connectionId, '/trip/raw')));
    expect(
      utf8.decode(remote.files[VPath.build(connectionId, '/trip/raw/b.txt')]!),
      'bb',
    );
    expect(jobs.jobs.single.filesTotal, 2);
  });

  test('downloads a remote folder to disk and leaves no .part files', () async {
    remote.dirs.add(VPath.build(connectionId, '/docs'));
    remote.files[VPath.build(connectionId, '/docs/one.txt')] =
        utf8.encode('one');
    remote.files[VPath.build(connectionId, '/docs/two.txt')] =
        utf8.encode('two');

    final report = await engine.transfer(
      sources: [VPath.build(connectionId, '/docs')],
      destDir: temp.path,
      move: false,
    );

    expect(report.isSuccess, isTrue);
    expect(File(p.join(temp.path, 'docs', 'one.txt')).readAsStringSync(), 'one');
    expect(File(p.join(temp.path, 'docs', 'two.txt')).readAsStringSync(), 'two');
    final leftovers = temp
        .listSync(recursive: true)
        .where((e) => e.path.endsWith('.notilus-part'));
    expect(leftovers, isEmpty);
  });

  test('a move deletes the source only after the copy succeeds', () async {
    final file = writeLocal('gone.txt', 'bye');

    final report = await engine.transfer(
      sources: [file.path],
      destDir: root,
      move: true,
    );

    expect(report.isSuccess, isTrue);
    expect(file.existsSync(), isFalse);
    expect(remote.files, contains(VPath.join(root, 'gone.txt')));
  });

  test('never overwrites: a second copy lands beside the first', () async {
    final file = writeLocal('report.pdf', 'v1');
    await engine.transfer(sources: [file.path], destDir: root, move: false);
    await engine.transfer(sources: [file.path], destDir: root, move: false);

    expect(remote.files.keys, contains(VPath.join(root, 'report.pdf')));
    expect(remote.files.keys, contains(VPath.join(root, 'report (2).pdf')));
  });

  test('copies inside one source server-side instead of relaying bytes',
      () async {
    remote.files[VPath.build(connectionId, '/a.bin')] = utf8.encode('payload');
    remote.dirs.add(VPath.build(connectionId, '/dest'));

    final report = await engine.transfer(
      sources: [VPath.build(connectionId, '/a.bin')],
      destDir: VPath.build(connectionId, '/dest'),
      move: false,
    );

    expect(report.isSuccess, isTrue);
    expect(remote.serverSideCopies, 1);
    expect(remote.uploads, 0);
    expect(
      utf8.decode(remote.files[VPath.build(connectionId, '/dest/a.bin')]!),
      'payload',
    );
  });

  test('refuses to copy a folder into itself', () async {
    remote.dirs.add(VPath.build(connectionId, '/self'));

    final report = await engine.transfer(
      sources: [VPath.build(connectionId, '/self')],
      destDir: VPath.build(connectionId, '/self'),
      move: false,
    );

    expect(report.isSuccess, isFalse);
    expect(report.failed.single.error, contains('itself'));
    expect(jobs.jobs.single.state, CopyJobState.failed);
  });

  test('a vanished file fails the copy but not the whole source', () async {
    final report = await engine.transfer(
      sources: [VPath.build(connectionId, '/missing.txt')],
      destDir: temp.path,
      move: false,
    );

    expect(report.isSuccess, isFalse);
    expect(report.failed, hasLength(1));
    // A stale listing is not a broken connection: the sidebar light stays on.
    expect(RemoteHub.instance.statusOf(connectionId), RemoteStatus.ready);
  });

  test('an auth failure does mark the source as needing attention', () async {
    remote.failNextDownloadWith =
        RemoteException('token expired', statusCode: 401);
    remote.files[VPath.build(connectionId, '/locked.txt')] = utf8.encode('x');

    final report = await engine.transfer(
      sources: [VPath.build(connectionId, '/locked.txt')],
      destDir: temp.path,
      move: false,
    );

    expect(report.isSuccess, isFalse);
    expect(RemoteHub.instance.statusOf(connectionId), RemoteStatus.error);
    expect(RemoteHub.instance.errorOf(connectionId), 'token expired');
  });

  test('search matches names across the subtree, capped', () async {
    remote.dirs.add(VPath.build(connectionId, '/a'));
    remote.files[VPath.build(connectionId, '/a/report-jan.pdf')] = [1];
    remote.files[VPath.build(connectionId, '/a/notes.txt')] = [1];
    remote.dirs.add(VPath.build(connectionId, '/a/deep'));
    remote.files[VPath.build(connectionId, '/a/deep/REPORT-feb.pdf')] = [1];

    final hits = await remote.search(root, 'report').toList();

    expect(
      hits.map((h) => h.name),
      containsAll(<String>['report-jan.pdf', 'REPORT-feb.pdf']),
    );
    expect(hits.map((h) => h.name), isNot(contains('notes.txt')));

    final capped = await remote.search(root, 'report', maxResults: 1).toList();
    expect(capped, hasLength(1));
  });

  test('involvesRemote decides which engine a copy belongs to', () {
    expect(TransferEngine.involvesRemote(['/a'], '/b'), isFalse);
    expect(TransferEngine.involvesRemote(['/a'], root), isTrue);
    expect(TransferEngine.involvesRemote([root], '/b'), isTrue);
  });

  group('CopyJobs', () {
    test('tracks progress and finishes, keeping failures on screen', () {
      final board = CopyJobs();
      final id = board.start(title: 'Copying', direction: CopyDirection.upload);
      board.update(id, filesTotal: 2, bytesTotal: 100);
      board.addBytes(id, 25);

      expect(board.byId(id)!.fraction, 0.25);
      expect(board.isBusy, isTrue);

      board.finish(id, state: CopyJobState.failed, error: 'nope');
      expect(board.isBusy, isFalse);
      // A failure is not swept away on a timer; the user dismisses it.
      board.dismissFinished();
      expect(board.hasJobs, isFalse);
      board.dispose();
    });

    test('cancellation is visible to the engine and to the UI', () {
      final board = CopyJobs();
      final id = board.start(title: 'Copying', direction: CopyDirection.upload);
      expect(board.isCancelled(id), isFalse);
      board.cancel(id);
      expect(board.isCancelled(id), isTrue);
      expect(board.byId(id)!.cancelRequested, isTrue);
      board.dispose();
    });

    test('an unsized job reports no fraction rather than a wrong one', () {
      final board = CopyJobs();
      final id =
          board.start(title: 'Copying', direction: CopyDirection.download);
      expect(board.byId(id)!.fraction, isNull);
      board.dispose();
    });
  });
}
