import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../models/remote/remote_connection.dart';
import '../native_core.dart';
import 'remote_file_system.dart';
import 'remote_path.dart';

/// A Windows / Samba / NAS share, browsed as a folder tree.
///
/// The protocol work lives in the Rust core, which keeps one authenticated TCP
/// session per connection and hands back an opaque session id. This class is
/// the adapter: it turns virtual paths into share-relative ones, streams reads
/// and writes through the core's file handles, and translates the core's
/// errors into the [RemoteException] the rest of the app understands.
///
/// One session means one socket, and SMB requests on a socket are answered in
/// order. Every call therefore goes through [_serialise], because two
/// overlapping requests would interleave on that socket and neither would get
/// its own reply.
class SmbFileSystem extends RemoteFileSystem {
  SmbFileSystem({
    required String connectionId,
    required this.host,
    required this.port,
    required this.share,
    required this.username,
    this.domain = '',
    this.password = '',
    this.basePath = '',
  }) : super(connectionId);

  factory SmbFileSystem.fromConnection(
    RemoteConnection connection,
    Map<String, String> secrets,
  ) =>
      SmbFileSystem(
        connectionId: connection.id,
        host: connection.get(RemoteKeys.host),
        port: int.tryParse(connection.get(RemoteKeys.port)) ?? 445,
        share: connection.get(RemoteKeys.shareName),
        username: connection.get(RemoteKeys.username),
        domain: connection.get(RemoteKeys.workgroup),
        basePath: connection.get(RemoteKeys.basePath),
        password: secrets[RemoteKeys.password] ?? '',
      );

  final String host;
  final int port;
  final String share;
  final String username;
  final String domain;
  final String password;

  /// Folder inside the share the virtual root maps to. Empty is the share
  /// root, which is what most people want.
  final String basePath;

  String? _sessionId;
  String _dialect = '';
  Future<void>? _connecting;

  /// Serialises every request onto the one socket the session owns.
  Future<void> _queue = Future.value();

  /// The SMB dialect that was negotiated, for the connection's details panel.
  String get dialect => _dialect;

  // ── session ──────────────────────────────────────────────────────────────

  SmbClientSettings get _settings => SmbClientSettings(
        host: host.trim(),
        port: port,
        share: share.trim(),
        username: username.trim(),
        domain: domain.trim(),
        password: password,
      );

  @override
  Future<void> connect() => _connecting ??= _open().whenComplete(() {
        _connecting = null;
      });

  Future<void> _open() async {
    if (host.trim().isEmpty) {
      throw RemoteException('This share has no server name or address.');
    }
    if (share.trim().isEmpty) {
      throw RemoteException('This connection has no share name.');
    }
    await NativeCore.ensureInitialized();
    try {
      final session = await NativeCore.instance.smbConnect(_settings);
      _sessionId = session.id;
      _dialect = session.dialect;
    } catch (e) {
      throw _translate(e);
    }
  }

  /// The live session, reconnecting if the server dropped it.
  Future<String> _session() async {
    final existing = _sessionId;
    if (existing != null) return existing;
    await connect();
    final opened = _sessionId;
    if (opened == null) throw RemoteException('Not connected to $host.');
    return opened;
  }

  /// Runs [action] once every earlier request has finished.
  ///
  /// A dropped session is retried exactly once: a laptop that slept loses its
  /// TCP connection, and a user who clicks a folder should see it open rather
  /// than an error they'd resolve by clicking again.
  Future<T> _serialise<T>(Future<T> Function(String session) action) {
    final result = _queue.then((_) async {
      try {
        return await action(await _session());
      } catch (e) {
        final failure = _translate(e);
        if (!failure.isSessionLost) throw failure;
        _sessionId = null;
        try {
          return await action(await _session());
        } catch (retry) {
          throw _translate(retry);
        }
      }
    });
    // The queue must advance whether or not this call succeeded, but it must
    // not carry the error into the next caller.
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  void close() {
    final session = _sessionId;
    _sessionId = null;
    if (session != null) {
      // Fire and forget: the socket closes either way, and nothing is waiting
      // on the logoff.
      NativeCore.instance.smbDisconnect(session).catchError((_) => false);
    }
  }

  // ── paths ────────────────────────────────────────────────────────────────

  /// Virtual path → share-relative path, in SMB's own spelling.
  @visibleForTesting
  String remotePathFor(String vpath) => _remote(vpath);

  /// Exposed so the mapping from the core's error strings onto statuses can be
  /// checked without a server on the other end.
  @visibleForTesting
  RemoteException translateForTesting(Object error) => _translate(error);

  String _remote(String vpath) {
    final ref = VPath.parse(vpath);
    if (ref == null) throw RemoteException('Not a remote path: $vpath');
    final base = basePath.trim().replaceAll('/', '\\').replaceAll(
          RegExp(r'^\\+|\\+$'),
          '',
        );
    final inner = ref.key.replaceAll('/', '\\');
    if (base.isEmpty) return inner;
    return inner.isEmpty ? base : '$base\\$inner';
  }

  // ── RemoteFileSystem ─────────────────────────────────────────────────────

  @override
  Future<List<RemoteEntry>> list(String vpath) async {
    final entries = await _serialise(
      (session) => NativeCore.instance.smbList(session, _remote(vpath)),
    );
    final out = [
      for (final entry in entries) _toEntry(vpath, entry, isChild: true),
    ];
    out.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  @override
  Future<RemoteEntry?> stat(String vpath) async {
    // The root of a share always exists, and asking a server to stat `""` is
    // the one path some of them answer inconsistently.
    if (VPath.isRemoteRoot(vpath) && basePath.trim().isEmpty) {
      return RemoteEntry(
        path: vpath,
        name: share,
        isDirectory: true,
        size: 0,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
      );
    }
    final entry = await _serialise(
      (session) => NativeCore.instance.smbStat(session, _remote(vpath)),
    );
    if (entry == null) return null;
    return _toEntry(vpath, entry, isChild: false);
  }

  @override
  Future<RemoteDownload> download(String vpath) async {
    final open = await _serialise(
      (session) => NativeCore.instance.smbOpen(
        sessionId: session,
        path: _remote(vpath),
      ),
    );
    final size = open.size.toInt();

    // The handle outlives this method and has to be closed when the consumer
    // stops reading — including when it stops early, which is what a cancelled
    // transfer does. A `StreamController` with an `onCancel` is the only shape
    // that gets both cases.
    late StreamController<List<int>> controller;
    var closed = false;
    // Completed when a paused consumer resumes, so the pump waits instead of
    // buffering the whole file in the controller.
    Completer<void>? resumed;

    Future<void> release() async {
      if (closed) return;
      closed = true;
      resumed?.complete();
      if (_sessionId == null) return;
      try {
        await _serialise(
          (live) => NativeCore.instance.smbClose(live, open.handle),
        );
      } catch (_) {
        // The session is already gone, which closed the handle with it.
      }
    }

    Future<void> pump() async {
      var offset = 0;
      try {
        while (!closed) {
          if (controller.isPaused) {
            resumed ??= Completer<void>();
            await resumed!.future;
            resumed = null;
            continue;
          }
          final chunk = await _serialise(
            (session) => NativeCore.instance.smbRead(
              sessionId: session,
              handle: open.handle,
              offset: offset,
              length: _chunkSize,
            ),
          );
          if (chunk.isEmpty) break;
          offset += chunk.length;
          if (closed) break;
          controller.add(chunk);
        }
      } catch (e) {
        if (!closed) controller.addError(_translate(e));
      } finally {
        await release();
        if (!controller.isClosed) await controller.close();
      }
    }

    controller = StreamController<List<int>>(
      onCancel: release,
      onResume: () {
        if (resumed?.isCompleted == false) resumed!.complete();
      },
    );
    controller.onListen = () => unawaited(pump());
    return RemoteDownload(stream: controller.stream, length: size);
  }

  @override
  Future<void> upload({
    required String vpath,
    required Stream<List<int>> data,
    required int length,
  }) async {
    final open = await _serialise(
      (session) => NativeCore.instance.smbOpen(
        sessionId: session,
        path: _remote(vpath),
        write: true,
        truncate: true,
      ),
    );
    var offset = 0;
    try {
      await for (final chunk in data) {
        var sent = 0;
        while (sent < chunk.length) {
          final slice = _asBytes(chunk).sublist(sent);
          final took = await _serialise(
            (session) => NativeCore.instance.smbWrite(
              sessionId: session,
              handle: open.handle,
              offset: offset + sent,
              data: slice,
            ),
          );
          if (took <= 0) {
            throw RemoteException('$host stopped accepting data.');
          }
          sent += took;
        }
        offset += chunk.length;
      }
    } catch (e) {
      // Close before rethrowing, or the half-written file stays open on the
      // server until the session ends.
      await _closeQuietly(open.handle);
      throw _translate(e);
    }
    await _serialise(
      (session) => NativeCore.instance.smbClose(session, open.handle),
    );
  }

  @override
  Future<void> createDirectory(String vpath) => _serialise(
        (session) =>
            NativeCore.instance.smbCreateDirectory(session, _remote(vpath)),
      ).catchError((Object e) => throw _translate(e));

  @override
  Future<void> delete(String vpath, {required bool isDirectory}) async {
    if (!isDirectory) {
      await _serialise(
        (session) =>
            NativeCore.instance.smbDelete(session, _remote(vpath), false),
      );
      return;
    }
    // SMB has no recursive delete: a folder must be empty before it goes.
    // Depth-first, children before parents.
    final children = await list(vpath);
    for (final child in children) {
      await delete(child.path, isDirectory: child.isDirectory);
    }
    await _serialise(
      (session) => NativeCore.instance.smbDelete(session, _remote(vpath), true),
    );
  }

  @override
  Future<String> rename(String vpath, String newName) async {
    final destination = VPath.join(VPath.dirname(vpath), newName);
    await _serialise(
      (session) => NativeCore.instance.smbRename(
        sessionId: session,
        from: _remote(vpath),
        to: _remote(destination),
      ),
    );
    return destination;
  }

  @override
  bool get supportsServerSideCopy => true;

  @override
  Future<void> copyWithin(String fromVPath, String toVPath) async {
    // The core tries the protocol's own server-side copy first and falls back
    // to relaying the bytes; either way they don't cross this process.
    await _serialise(
      (session) => NativeCore.instance
          .smbCopy(session, _remote(fromVPath), _remote(toVPath)),
    );
  }

  Future<void> _closeQuietly(BigInt handle) async {
    try {
      await _serialise(
        (session) => NativeCore.instance.smbClose(session, handle),
      );
    } catch (_) {
      // Nothing useful to do — the write error is the one worth reporting.
    }
  }

  RemoteEntry _toEntry(
    String parentOrSelf,
    SmbEntry entry, {
    required bool isChild,
  }) =>
      RemoteEntry(
        path: isChild ? VPath.join(parentOrSelf, entry.name) : parentOrSelf,
        name: entry.name,
        isDirectory: entry.isDir,
        size: entry.isDir ? 0 : entry.size.toInt(),
        modified: DateTime.fromMillisecondsSinceEpoch(
          entry.modifiedMs > 0 ? entry.modifiedMs : entry.createdMs,
        ),
      );

  static Uint8List _asBytes(List<int> chunk) =>
      chunk is Uint8List ? chunk : Uint8List.fromList(chunk);

  /// 1 MB matches what the core will send in one SMB request, so a larger ask
  /// would just be split again.
  static const int _chunkSize = 1024 * 1024;

  /// Turns a core error into a [RemoteException].
  ///
  /// The core encodes failures as `smb:<code> <message>`, where the code
  /// distinguishes "wrong password" from "no such file" — which is what the
  /// sidebar needs to decide whether to flag the connection as broken.
  RemoteException _translate(Object error) {
    if (error is RemoteException) return error;
    final text = '$error';
    final match = RegExp(r'^(?:[A-Za-z]+: )?smb:(\d+) (.*)$', dotAll: true)
        .firstMatch(text.trim());
    if (match == null) {
      return RemoteException(text.replaceFirst(RegExp(r'^\w+: '), ''));
    }
    final code = int.tryParse(match.group(1)!) ?? 0;
    return RemoteException(
      match.group(2)!,
      statusCode: code == 0 ? null : code,
    );
  }
}

/// True when a failure means the session is gone rather than the request being
/// wrong — the case worth one silent reconnect.
extension on RemoteException {
  bool get isSessionLost =>
      message.contains('connection has been closed') ||
      message.contains('The connection dropped') ||
      message.contains('connection was closed by the server');
}
