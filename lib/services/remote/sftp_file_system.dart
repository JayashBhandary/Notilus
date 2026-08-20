import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../models/remote/remote_connection.dart';
import 'remote_file_system.dart';
import 'remote_path.dart';

/// A server over SSH — a VPS, a NAS, a build box — browsed as a folder tree.
///
/// SFTP is a subsystem of SSH, so this is the same connection an `ssh` command
/// would make: one authenticated session, then file operations over it. Unlike
/// the object stores, the thing on the other end is a real filesystem, so
/// rename is a rename, directories exist on their own, and permissions and
/// symlinks are real.
///
/// Two capabilities are opportunistic. Copying inside the server and searching
/// it are enormously faster as shell commands (`cp`, `find`) than as bytes
/// pulled through this machine — but an account locked to `internal-sftp` can't
/// run commands at all, so each falls back to the pure-SFTP path when the
/// command fails.
class SftpFileSystem extends RemoteFileSystem {
  SftpFileSystem({
    required String connectionId,
    required this.host,
    required this.port,
    required this.username,
    this.password = '',
    this.privateKeyPath = '',
    this.privateKeyPassphrase = '',
    this.basePath = '',
    this.knownHostKey = '',
    this.onHostKeyLearned,
  }) : super(connectionId) {
    // A configured start folder is known before the session exists; the home
    // directory is not, and is resolved during [connect].
    if (basePath.trim().isNotEmpty) _root = _clean(basePath);
  }

  factory SftpFileSystem.fromConnection(
    RemoteConnection connection,
    Map<String, String> secrets, {
    Future<void> Function(String fingerprint)? onHostKeyLearned,
  }) =>
      SftpFileSystem(
        connectionId: connection.id,
        host: connection.get(RemoteKeys.host),
        port: int.tryParse(connection.get(RemoteKeys.port)) ?? 22,
        username: connection.get(RemoteKeys.username),
        privateKeyPath: connection.get(RemoteKeys.privateKeyPath),
        basePath: connection.get(RemoteKeys.basePath),
        knownHostKey: connection.get(RemoteKeys.hostKey),
        password: secrets[RemoteKeys.password] ?? '',
        privateKeyPassphrase: secrets[RemoteKeys.passphrase] ?? '',
        onHostKeyLearned: onHostKeyLearned,
      );

  final String host;
  final int port;
  final String username;
  final String password;
  final String privateKeyPath;
  final String privateKeyPassphrase;

  /// Directory the virtual root maps to. Empty means the login home, which is
  /// what `sftp user@host` drops you in.
  final String basePath;

  /// The host key fingerprint this connection has seen before, if any.
  final String knownHostKey;

  /// Called the first time a host key is accepted, so it can be pinned.
  final Future<void> Function(String fingerprint)? onHostKeyLearned;

  SSHClient? _client;
  SftpClient? _sftp;
  String _root = '/';
  Future<void>? _connecting;

  // ── session ──────────────────────────────────────────────────────────────

  @override
  Future<void> connect() => _connecting ??= _open().whenComplete(() {
        _connecting = null;
      });

  Future<void> _open() async {
    if (host.isEmpty) throw RemoteException('This server has no host name.');
    if (username.isEmpty) throw RemoteException('This server has no username.');

    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(
        host,
        port,
        timeout: const Duration(seconds: 15),
      );
    } on SocketException catch (e) {
      throw RemoteException(
        'Can\'t reach $host:$port — ${e.osError?.message ?? e.message}.',
      );
    } on TimeoutException {
      throw RemoteException('$host:$port didn\'t answer.');
    }

    final identities = await _identities();
    final client = SSHClient(
      socket,
      username: username,
      identities: identities.isEmpty ? null : identities,
      onPasswordRequest: password.isEmpty ? null : () => password,
      onVerifyHostKey: verifyHostKey,
    );

    try {
      _sftp = await client.sftp();
    } on SSHAuthFailError catch (e) {
      client.close();
      throw RemoteException(
        'The server refused these credentials: ${e.message}',
        statusCode: 401,
      );
    } on SSHAuthAbortError catch (e) {
      client.close();
      throw RemoteException('Sign-in to $host stopped: ${e.message}',
          statusCode: 401);
    } on SSHError catch (e) {
      client.close();
      // Only some SSHError subtypes carry a message; `$e` is their toString,
      // which includes it when there is one.
      throw RemoteException('$host: $e');
    }
    _client = client;

    // Resolve the virtual root once. `.` is the login directory, which is
    // where a plain `sftp user@host` lands, so an unconfigured connection
    // opens on the same folder the user's terminal would.
    if (basePath.trim().isEmpty) {
      try {
        _root = _clean(await _sftp!.absolute('.'));
      } catch (_) {
        _root = '/';
      }
    } else {
      _root = _clean(basePath);
    }
  }

  /// Trust on first use, then pinning.
  ///
  /// dartssh2 accepts any host key when no handler is given, which would make
  /// this connection trivially interceptable. The first key seen is recorded
  /// against the connection; from then on a different key fails the connection
  /// loudly, which is the whole point of the check.
  @visibleForTesting
  FutureOr<bool> verifyHostKey(String type, Uint8List fingerprint) {
    final seen = utf8.decode(fingerprint, allowMalformed: true);
    if (knownHostKey.isEmpty) {
      onHostKeyLearned?.call(seen);
      return true;
    }
    if (knownHostKey == seen) return true;
    // Returning false ends the handshake; the message the user gets comes from
    // [connect]'s error mapping, so state the mismatch there.
    throw RemoteException(
      'The host key for $host has changed.\n\n'
      'Expected $knownHostKey\nGot      $seen\n\n'
      'If you rebuilt the server, remove this source and add it again. '
      'Otherwise the connection is being intercepted.',
    );
  }

  Future<List<SSHKeyPair>> _identities() async {
    if (privateKeyPath.trim().isEmpty) return const [];
    final file = File(privateKeyPath.trim());
    if (!await file.exists()) {
      throw RemoteException('No private key at $privateKeyPath');
    }
    final pem = await file.readAsString();
    try {
      if (SSHKeyPair.isEncryptedPem(pem) && privateKeyPassphrase.isEmpty) {
        throw RemoteException('That private key needs a passphrase.');
      }
      return SSHKeyPair.fromPem(
        pem,
        privateKeyPassphrase.isEmpty ? null : privateKeyPassphrase,
      );
    } on RemoteException {
      rethrow;
    } catch (e) {
      throw RemoteException('Couldn\'t read the private key: $e');
    }
  }

  Future<SftpClient> _session() async {
    final existing = _sftp;
    if (existing != null && _client?.isClosed != true) return existing;
    // The session died — a laptop slept, the server dropped it. Reconnecting
    // here means the user sees a slow listing rather than an error.
    _sftp = null;
    _client = null;
    await connect();
    final reopened = _sftp;
    if (reopened == null) throw RemoteException('Not connected to $host.');
    return reopened;
  }

  // ── paths ────────────────────────────────────────────────────────────────

  static String _clean(String path) {
    var out = path.trim().replaceAll('\\', '/');
    while (out.contains('//')) {
      out = out.replaceAll('//', '/');
    }
    if (!out.startsWith('/')) out = '/$out';
    if (out.length > 1 && out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  /// Virtual path → absolute path on the server.
  String _remote(String vpath) {
    final ref = VPath.parse(vpath);
    if (ref == null) throw RemoteException('Not a remote path: $vpath');
    if (ref.isRoot) return _root;
    return _clean('$_root${ref.path}');
  }

  /// Absolute server path → virtual path, for entries a listing returns.
  String _virtual(String remotePath) {
    final cleaned = _clean(remotePath);
    if (cleaned == _root) return VPath.root(connectionId);
    final relative =
        _root == '/' ? cleaned : cleaned.substring(_root.length);
    return VPath.build(connectionId, relative);
  }

  /// Single-quotes a path for a shell command. Everything inside single quotes
  /// is literal to a POSIX shell except a single quote itself, which is closed,
  /// escaped and reopened — so a file called `it's here` survives intact.
  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";

  // ── RemoteFileSystem ─────────────────────────────────────────────────────

  @override
  Future<List<RemoteEntry>> list(String vpath) async {
    final sftp = await _session();
    final dir = _remote(vpath);
    final List<SftpName> names;
    try {
      names = await sftp.listdir(dir);
    } on SftpStatusError catch (e) {
      throw RemoteException(_describe(e, VPath.basename(vpath)),
          statusCode: _statusOf(e));
    }

    final out = <RemoteEntry>[];
    for (final name in names) {
      if (name.filename == '.' || name.filename == '..') continue;
      final path = _clean('$dir/${name.filename}');
      var isDirectory = name.attr.isDirectory;
      // A symlink's own attributes describe the link, not what it points at.
      // Following it is what makes a symlinked folder open as a folder.
      if (name.attr.isSymbolicLink) {
        try {
          isDirectory = (await sftp.stat(path)).isDirectory;
        } catch (_) {
          isDirectory = false;
        }
      }
      out.add(RemoteEntry(
        path: _virtual(path),
        name: name.filename,
        isDirectory: isDirectory,
        size: isDirectory ? 0 : (name.attr.size ?? 0),
        modified: _time(name.attr.modifyTime),
      ));
    }
    out.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  @override
  Future<RemoteEntry?> stat(String vpath) async {
    final sftp = await _session();
    try {
      final attrs = await sftp.stat(_remote(vpath));
      return RemoteEntry(
        path: vpath,
        name: VPath.basename(vpath),
        isDirectory: attrs.isDirectory,
        size: attrs.isDirectory ? 0 : (attrs.size ?? 0),
        modified: _time(attrs.modifyTime),
      );
    } on SftpStatusError catch (e) {
      if (_statusOf(e) == 404) return null;
      throw RemoteException(_describe(e, VPath.basename(vpath)),
          statusCode: _statusOf(e));
    }
  }

  @override
  Future<RemoteDownload> download(String vpath) async {
    final sftp = await _session();
    final SftpFile file;
    try {
      file = await sftp.open(_remote(vpath));
    } on SftpStatusError catch (e) {
      throw RemoteException(_describe(e, VPath.basename(vpath)),
          statusCode: _statusOf(e));
    }
    final attrs = await file.stat();

    // The handle has to outlive this method and be closed when the consumer
    // stops reading — including when it stops early, which is what a cancelled
    // transfer does.
    Stream<Uint8List> body() async* {
      try {
        yield* file.read();
      } finally {
        await file.close();
      }
    }

    return RemoteDownload(stream: body(), length: attrs.size ?? -1);
  }

  @override
  Future<void> upload({
    required String vpath,
    required Stream<List<int>> data,
    required int length,
  }) async {
    final sftp = await _session();
    final SftpFile file;
    try {
      file = await sftp.open(
        _remote(vpath),
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
    } on SftpStatusError catch (e) {
      throw RemoteException(_describe(e, VPath.basename(vpath)),
          statusCode: _statusOf(e));
    }
    try {
      await file.write(data.map(_asBytes)).done;
    } finally {
      await file.close();
    }
  }

  static Uint8List _asBytes(List<int> chunk) =>
      chunk is Uint8List ? chunk : Uint8List.fromList(chunk);

  @override
  Future<void> createDirectory(String vpath) async {
    final sftp = await _session();
    try {
      await sftp.mkdir(_remote(vpath));
    } on SftpStatusError catch (e) {
      throw RemoteException(_describe(e, VPath.basename(vpath)),
          statusCode: _statusOf(e));
    }
  }

  @override
  Future<void> delete(String vpath, {required bool isDirectory}) async {
    final sftp = await _session();
    final path = _remote(vpath);
    try {
      if (!isDirectory) {
        await sftp.remove(path);
        return;
      }
      // Emptied depth-first through SFTP itself rather than `rm -rf`: an
      // account restricted to internal-sftp has no shell, and a delete is the
      // last operation that should depend on one.
      await _removeTree(sftp, path);
    } on SftpStatusError catch (e) {
      throw RemoteException(_describe(e, VPath.basename(vpath)),
          statusCode: _statusOf(e));
    }
  }

  Future<void> _removeTree(SftpClient sftp, String path) async {
    for (final name in await sftp.listdir(path)) {
      if (name.filename == '.' || name.filename == '..') continue;
      final child = _clean('$path/${name.filename}');
      // A symlink is unlinked, never followed — deleting through one would
      // reach outside the folder being removed.
      if (name.attr.isDirectory && !name.attr.isSymbolicLink) {
        await _removeTree(sftp, child);
      } else {
        await sftp.remove(child);
      }
    }
    await sftp.rmdir(path);
  }

  @override
  Future<String> rename(String vpath, String newName) async {
    final sftp = await _session();
    final destination = VPath.join(VPath.dirname(vpath), newName);
    try {
      await sftp.rename(_remote(vpath), _remote(destination));
    } on SftpStatusError catch (e) {
      throw RemoteException(_describe(e, VPath.basename(vpath)),
          statusCode: _statusOf(e));
    }
    return destination;
  }

  @override
  bool get supportsServerSideCopy => true;

  @override
  Future<void> copyWithin(String fromVPath, String toVPath) async {
    final from = _remote(fromVPath);
    final to = _remote(toVPath);
    final client = _client;
    if (client != null && !client.isClosed) {
      try {
        // Copying on the server is the whole point: duplicating a 4 GB backup
        // inside a VPS shouldn't cost 8 GB of transfer.
        final result = await client.runWithResult(
          'cp -p -- ${_shellQuote(from)} ${_shellQuote(to)}',
          stdout: false,
        );
        if (result.exitCode == 0) return;
        // A non-zero `cp` may still have written a partial file; remove it so
        // the relay below starts from nothing.
        if (result.exitCode != null) {
          try {
            await (await _session()).remove(to);
          } catch (_) {
            // Nothing was created — which is the usual case.
          }
        }
      } catch (_) {
        // No shell at all (an account locked to internal-sftp), or no `cp`.
      }
    }
    final download = await this.download(fromVPath);
    await upload(
      vpath: toVPath,
      data: download.stream,
      length: download.length,
    );
  }

  /// `find` in one round trip beats a listing per folder by orders of
  /// magnitude on a server with a real directory tree. GNU `-printf` gives
  /// size and mtime along with the path, so results carry the same detail a
  /// listing would; anything unexpected falls back to the SFTP walk.
  @override
  Stream<RemoteEntry> search(
    String root,
    String query, {
    int maxResults = 500,
  }) async* {
    if (query.trim().isEmpty) return;
    final client = _client;
    if (client == null || client.isClosed) {
      yield* super.search(root, query, maxResults: maxResults);
      return;
    }

    final String output;
    try {
      final pattern = '*${query.replaceAll('*', r'\*')}*';
      final result = await client.run(
        'find ${_shellQuote(_remote(root))} -maxdepth 12 '
        '-iname ${_shellQuote(pattern)} '
        r"-printf '%y\t%s\t%T@\t%p\n' 2>/dev/null | head -n $maxResults",
        stderr: false,
      );
      output = utf8.decode(result, allowMalformed: true);
    } catch (_) {
      yield* super.search(root, query, maxResults: maxResults);
      return;
    }

    var yielded = 0;
    for (final line in const LineSplitter().convert(output)) {
      final parts = line.split('\t');
      if (parts.length < 4) continue;
      final path = parts.sublist(3).join('\t');
      if (path.isEmpty || _clean(path) == _remote(root)) continue;
      final seconds = double.tryParse(parts[2]) ?? 0;
      yield RemoteEntry(
        path: _virtual(path),
        name: path.substring(path.lastIndexOf('/') + 1),
        isDirectory: parts[0] == 'd',
        size: parts[0] == 'd' ? 0 : (int.tryParse(parts[1]) ?? 0),
        modified: DateTime.fromMillisecondsSinceEpoch(
          (seconds * 1000).round(),
        ),
      );
      if (++yielded >= maxResults) return;
    }
    // An empty result from a server whose `find` is missing or refused looks
    // the same as no matches, so confirm with the protocol-level walk.
    if (yielded == 0) {
      yield* super.search(root, query, maxResults: maxResults);
    }
  }

  /// The `ssh` command that opens a terminal in [vpath], for the shell the app
  /// already ships. Nothing runs it here — it is offered to the user.
  String sshCommandFor(String vpath) {
    final target = port == 22 ? '$username@$host' : '-p $port $username@$host';
    return 'ssh -t $target ${_shellQuote('cd ${_shellQuote(_remote(vpath))} '
        '&& exec \$SHELL -l')}';
  }

  @override
  void close() {
    _sftp?.close();
    _client?.close();
    _sftp = null;
    _client = null;
  }

  // ── error mapping ────────────────────────────────────────────────────────

  static DateTime _time(int? epochSeconds) =>
      DateTime.fromMillisecondsSinceEpoch((epochSeconds ?? 0) * 1000);

  static int? _statusOf(SftpStatusError error) {
    switch (error.code) {
      case 2: // SSH_FX_NO_SUCH_FILE
        return 404;
      case 3: // SSH_FX_PERMISSION_DENIED
        return 403;
      case 11: // SSH_FX_FILE_ALREADY_EXISTS
        return 409;
      default:
        return null;
    }
  }

  static String _describe(SftpStatusError error, String name) {
    switch (error.code) {
      case 2:
        return '"$name" isn\'t there any more.';
      case 3:
        return 'The server won\'t let this account touch "$name".';
      case 11:
        return '"$name" already exists on the server.';
      default:
        return error.message.isEmpty
            ? 'The server refused that (code ${error.code}).'
            : error.message;
    }
  }
}
