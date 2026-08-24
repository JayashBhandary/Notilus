import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:notilus/models/remote/remote_connection.dart';
import 'package:notilus/services/native_core.dart';
import 'package:notilus/services/remote/remote_file_system.dart';
import 'package:notilus/services/remote/remote_hub.dart';
import 'package:notilus/services/remote/remote_path.dart';
import 'package:notilus/services/remote/smb_file_system.dart';

import 'native_test_support.dart';

/// Two suites.
///
/// The first checks what needs no server: how a virtual path becomes a
/// share-relative one, and how the core's error strings become statuses the
/// sidebar acts on.
///
/// The second starts Notilus's *own* SMB server and points the client at it
/// over a real socket. Both halves are in the same core, so this exercises the
/// whole path — negotiation, NTLMv2, signing, and every file operation — with
/// nothing mocked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SmbFileSystem build({String basePath = ''}) => SmbFileSystem(
        connectionId: 'nas',
        host: 'nas.local',
        port: 445,
        share: 'Files',
        username: 'alice',
        password: 'secret',
        basePath: basePath,
      );

  group('paths', () {
    test('the virtual root is the top of the share', () {
      expect(build().remotePathFor(VPath.root('nas')), '');
    });

    test('segments become an SMB path', () {
      expect(
        build().remotePathFor(VPath.build('nas', '/Docs/Q1 report.pdf')),
        'Docs\\Q1 report.pdf',
      );
    });

    test('a start folder is prefixed, in either spelling', () {
      expect(
        build(basePath: 'Projects').remotePathFor(VPath.build('nas', '/a/b')),
        'Projects\\a\\b',
      );
      expect(
        build(basePath: '/Team/Shared/')
            .remotePathFor(VPath.build('nas', '/notes.txt')),
        'Team\\Shared\\notes.txt',
      );
      expect(
        build(basePath: 'Projects').remotePathFor(VPath.root('nas')),
        'Projects',
      );
    });

    test('a local path is refused rather than guessed at', () {
      expect(
        () => build().remotePathFor('/home/alice/file.txt'),
        throwsA(isA<RemoteException>()),
      );
    });
  });

  group('errors', () {
    test('a refused sign-in is reported as an auth failure', () {
      final failure = build().translateForTesting(
        Exception('smb:401 The server refused these credentials.'),
      );
      expect(failure.isAuthFailure, isTrue);
      expect(failure.message, 'The server refused these credentials.');
    });

    test('a missing file is a 404, which is not an auth failure', () {
      final failure =
          build().translateForTesting('smb:404 No such file or folder.');
      expect(failure.statusCode, 404);
      expect(failure.isAuthFailure, isFalse);
    });

    test('an unrecognised error keeps its text and carries no status', () {
      final failure = build().translateForTesting(Exception('the disk caught fire'));
      expect(failure.message, 'the disk caught fire');
      expect(failure.statusCode, isNull);
    });
  });

  group('against a live server', () {
    late Directory root;
    late SmbFileSystem fs;
    // Decided synchronously: `skip:` is read while the group is registered,
    // long before setUpAll could set a flag.
    final skip = NativeTestSupport.isBuilt ? null : NativeTestSupport.skipReason;

    setUpAll(() async {
      if (skip != null) return;
      await NativeTestSupport.ensureLoaded();

      root = await Directory.systemTemp.createTemp('notilus-smb-dart-');
      await Directory(p.join(root.path, 'Docs')).create();
      await File(p.join(root.path, 'Docs', 'notes.txt'))
          .writeAsString('hello from the share');
      // Comfortably more than one SMB request, so a read has to loop.
      await File(p.join(root.path, 'big.bin')).writeAsBytes(
        List<int>.filled(300 * 1024, 42),
      );

      // Port 0 asks the OS for a free one, so the suite can't collide with
      // anything already listening.
      final started = Completer<int>();
      final events = NativeCore.instance
          .startSharing(
            SmbServerSettings(
              bind: '127.0.0.1',
              port: 0,
              serverName: 'NOTILUS',
              workgroup: 'WORKGROUP',
              shares: [
                SmbShareConfig(
                  name: 'Files',
                  path: root.path,
                  readOnly: false,
                  comment: '',
                ),
              ],
              users: [
                const SmbUserConfig(
                  username: 'alice',
                  password: 'correct horse',
                ),
              ],
              requireSigning: true,
              maxConnections: 8,
            ),
          )
          .listen((event) {
        if (event is SmbServerEvent_Started && !started.isCompleted) {
          started.complete(event.field0);
        }
      });
      addTearDown(() async {
        await NativeCore.instance.stopSharing();
        await events.cancel();
        if (root.existsSync()) await root.delete(recursive: true);
      });

      final port = await started.future.timeout(const Duration(seconds: 10));
      fs = SmbFileSystem(
        connectionId: 'live',
        host: '127.0.0.1',
        port: port,
        share: 'Files',
        username: 'alice',
        password: 'correct horse',
      );
      await fs.connect();
      addTearDown(fs.close);
    });

    test('signs in and negotiates a modern dialect', () {
      expect(fs.dialect, startsWith('SMB 3'));
    }, skip: skip);

    test('lists folders before files', () async {
      final entries = await fs.list(VPath.root('live'));
      expect(entries.map((e) => e.name), ['Docs', 'big.bin']);
      expect(entries.first.isDirectory, isTrue);
      expect(entries.last.size, 300 * 1024);
      // The dot entries are the server's business, not the browser's.
      expect(entries.map((e) => e.name), isNot(contains('.')));
    }, skip: skip);

    test('stat tells a missing file from a present one', () async {
      final present = await fs.stat(VPath.build('live', '/Docs/notes.txt'));
      expect(present?.size, 20);
      expect(present?.isDirectory, isFalse);
      expect(await fs.stat(VPath.build('live', '/Docs/gone.txt')), isNull);
    }, skip: skip);

    test('downloads a file larger than one request', () async {
      final download = await fs.download(VPath.build('live', '/big.bin'));
      expect(download.length, 300 * 1024);
      final bytes = <int>[];
      await for (final chunk in download.stream) {
        bytes.addAll(chunk);
      }
      expect(bytes.length, 300 * 1024);
      expect(bytes.every((b) => b == 42), isTrue);
    }, skip: skip);

    test('cancelling a download closes the handle rather than leaking it',
        () async {
      final download = await fs.download(VPath.build('live', '/big.bin'));
      final subscription = download.stream.listen((_) {});
      await subscription.cancel();
      // The session must still be usable — a leaked handle or a stuck request
      // queue would hang this.
      final entries = await fs.list(VPath.root('live'));
      expect(entries, isNotEmpty);
    }, skip: skip);

    test('uploads, renames, copies and deletes', () async {
      final target = VPath.build('live', '/Docs/report.txt');
      final payload = utf8.encode('quarterly numbers');
      await fs.upload(
        vpath: target,
        data: Stream.value(payload),
        length: payload.length,
      );
      expect(
        await File(p.join(root.path, 'Docs', 'report.txt')).readAsString(),
        'quarterly numbers',
      );

      final renamed = await fs.rename(target, 'final.txt');
      expect(VPath.basename(renamed), 'final.txt');
      expect(File(p.join(root.path, 'Docs', 'report.txt')).existsSync(), isFalse);

      await fs.copyWithin(renamed, VPath.build('live', '/Docs/copy.txt'));
      expect(
        await File(p.join(root.path, 'Docs', 'copy.txt')).readAsString(),
        'quarterly numbers',
      );

      await fs.delete(renamed, isDirectory: false);
      expect(File(p.join(root.path, 'Docs', 'final.txt')).existsSync(), isFalse);
    }, skip: skip);

    test('deletes a folder by emptying it first', () async {
      final folder = VPath.build('live', '/Archive');
      await fs.createDirectory(folder);
      final payload = utf8.encode('x');
      await fs.upload(
        vpath: VPath.join(folder, 'inside.txt'),
        data: Stream.value(payload),
        length: payload.length,
      );

      await fs.delete(folder, isDirectory: true);
      expect(Directory(p.join(root.path, 'Archive')).existsSync(), isFalse);
    }, skip: skip);

    test('a wrong password is reported as an auth failure', () async {
      final wrong = SmbFileSystem(
        connectionId: 'bad',
        host: '127.0.0.1',
        port: fs.port,
        share: 'Files',
        username: 'alice',
        password: 'guess',
      );
      await expectLater(
        wrong.connect(),
        throwsA(
          isA<RemoteException>().having(
            (e) => e.isAuthFailure,
            'isAuthFailure',
            isTrue,
          ),
        ),
      );
      wrong.close();
    }, skip: skip);
  });

  group('the hub', () {
    test('builds an SMB source from a saved connection', () async {
      const connection = RemoteConnection(
        id: 'saved',
        kind: RemoteKind.smb,
        label: 'NAS',
        config: {
          RemoteKeys.host: 'nas.local',
          RemoteKeys.port: '4455',
          RemoteKeys.shareName: 'Files',
          RemoteKeys.username: 'alice',
          RemoteKeys.workgroup: 'WORKGROUP',
          RemoteKeys.basePath: 'Projects',
        },
      );
      final fs = RemoteHub.instance
          .build(connection, {RemoteKeys.password: 'secret'});
      expect(fs, isA<SmbFileSystem>());
      final smb = fs as SmbFileSystem;
      expect(smb.host, 'nas.local');
      expect(smb.port, 4455);
      expect(smb.share, 'Files');
      expect(smb.remotePathFor(VPath.build('saved', '/a.txt')), 'Projects\\a.txt');
    });
  });
}
