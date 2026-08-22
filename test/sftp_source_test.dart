import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:notilus/models/remote/remote_connection.dart';
import 'package:notilus/services/remote/remote_file_system.dart';
import 'package:notilus/services/remote/remote_hub.dart';
import 'package:notilus/services/remote/remote_path.dart';
import 'package:notilus/services/remote/sftp_file_system.dart';

/// What can be checked without a server on the other end: how virtual paths
/// map onto server paths, how the shell command is composed, and — the part
/// that matters most — that a changed host key is refused.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SftpFileSystem build({
    String basePath = '',
    int port = 22,
    String knownHostKey = '',
    Future<void> Function(String)? onLearned,
  }) =>
      SftpFileSystem(
        connectionId: 'vps',
        host: 'vps.example.com',
        port: port,
        username: 'deploy',
        basePath: basePath,
        knownHostKey: knownHostKey,
        onHostKeyLearned: onLearned,
      );

  Uint8List fingerprint(String value) => Uint8List.fromList(utf8.encode(value));

  group('paths', () {
    test('the virtual root is the login home unless a folder is configured',
        () {
      // Nothing is resolved before a session exists, so an unconfigured
      // source addresses from / until connect() learns the home directory.
      expect(
        build().sshCommandFor(VPath.build('vps', '/srv/app')),
        contains("'cd '\\''/srv/app'\\'' && exec \$SHELL -l'"),
      );
      expect(
        build(basePath: '/var/www').sshCommandFor(VPath.build('vps', '/site')),
        contains('/var/www/site'),
      );
      // A trailing slash on the configured folder doesn't double up.
      expect(
        build(basePath: '/var/www/').sshCommandFor(VPath.root('vps')),
        contains("'cd '\\''/var/www'\\''"),
      );
    });

    test('the ssh command targets the right host and port', () {
      expect(build().sshCommandFor(VPath.root('vps')),
          startsWith('ssh -t deploy@vps.example.com '));
      expect(build(port: 2222).sshCommandFor(VPath.root('vps')),
          startsWith('ssh -t -p 2222 deploy@vps.example.com '));
    });

    test('a folder name with a quote in it survives both shells', () async {
      // The command is quoted twice on purpose: the local shell strips one
      // layer to hand ssh its argument, and the remote shell strips the other.
      // Asserting on the escaping would just restate the implementation, so
      // this runs the first layer through a real shell and checks what ssh
      // would actually receive.
      final command =
          build().sshCommandFor(VPath.build('vps', "/srv/it's here"));
      final argument = command.replaceFirst('ssh -t deploy@vps.example.com ', '');

      final result = await Process.run(
        'bash',
        ['-c', "printf '%s' $argument"],
      );

      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(
        result.stdout,
        "cd '/srv/it'\\''s here' && exec \$SHELL -l",
      );
    }, skip: Platform.isWindows ? 'POSIX shell quoting' : null);
  });

  group('host key pinning', () {
    test('the first key seen is accepted and handed back to be pinned',
        () async {
      String? learned;
      final fs = build(onLearned: (value) async => learned = value);

      expect(
        await fs.verifyHostKey('ssh-ed25519', fingerprint('SHA256:abc')),
        isTrue,
      );
      expect(learned, 'SHA256:abc');
    });

    test('the same key on a later connection is accepted silently', () async {
      var learnedCalls = 0;
      final fs = build(
        knownHostKey: 'SHA256:abc',
        onLearned: (_) async => learnedCalls++,
      );

      expect(
        await fs.verifyHostKey('ssh-ed25519', fingerprint('SHA256:abc')),
        isTrue,
      );
      expect(learnedCalls, 0);
    });

    test('a changed key fails the connection and says both fingerprints', () {
      final fs = build(knownHostKey: 'SHA256:abc');

      expect(
        () => fs.verifyHostKey('ssh-ed25519', fingerprint('SHA256:xyz')),
        throwsA(
          isA<RemoteException>()
              .having((e) => e.message, 'message', contains('SHA256:abc'))
              .having((e) => e.message, 'message', contains('SHA256:xyz'))
              .having((e) => e.message, 'message', contains('has changed')),
        ),
      );
    });
  });

  group('registry', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      RemoteHub.instance.resetForTesting();
    });
    tearDown(RemoteHub.instance.resetForTesting);

    test('builds an SSH source from a saved connection', () {
      const connection = RemoteConnection(
        id: 'vps',
        kind: RemoteKind.sftp,
        label: 'Prod',
        config: {
          RemoteKeys.host: 'vps.example.com',
          RemoteKeys.port: '2222',
          RemoteKeys.username: 'deploy',
          RemoteKeys.basePath: '/srv',
        },
      );

      final fs = RemoteHub.instance.build(connection, const {});
      expect(fs, isA<SftpFileSystem>());
      expect(
        (fs as SftpFileSystem).sshCommandFor(VPath.build('vps', '/app')),
        allOf(contains('-p 2222'), contains('/srv/app')),
      );
      fs.close();
    });

    test('pinning a host key updates the connection without unmounting it',
        () async {
      const connection = RemoteConnection(
        id: 'vps',
        kind: RemoteKind.sftp,
        label: 'Prod',
        config: {RemoteKeys.host: 'vps.example.com'},
      );
      RemoteHub.instance.mountForTesting(connection, build());

      await RemoteHub.instance.rememberHostKey('vps', 'SHA256:abc');

      expect(
        RemoteHub.instance.byId('vps')!.get(RemoteKeys.hostKey),
        'SHA256:abc',
      );
      // Still connected: the pin happens mid-handshake, so tearing the
      // session down here would abort the connection being established.
      expect(RemoteHub.instance.statusOf('vps'), RemoteStatus.ready);
    });
  });
}
