import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../models/remote/remote_connection.dart';
import 'gdrive_file_system.dart';
import 'remote_file_system.dart';
import 'remote_path.dart';
import 's3_file_system.dart';
import 'sftp_file_system.dart';
import 'smb_file_system.dart';
import 'webdav_file_system.dart';

/// The one place that knows which remote sources exist and how to talk to
/// them.
///
/// It is a singleton *and* a [ChangeNotifier]: the sidebar watches it like any
/// other provider, while `FileService` — which has no widget tree around it —
/// reaches it directly. Two objects (a service plus a provider mirroring it)
/// would have to be kept in sync for no benefit.
class RemoteHub extends ChangeNotifier {
  RemoteHub._();

  static final RemoteHub instance = RemoteHub._();

  static const _prefsKey = 'remote_connections';
  static const _uuid = Uuid();

  // Same reasoning as ApiKeyStore: credentials belong in the OS keychain, not
  // in shared_preferences next to the window layout.
  static const _secure = FlutterSecureStorage(
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  List<RemoteConnection> _connections = const [];
  final Map<String, RemoteStatus> _status = {};
  final Map<String, String> _errors = {};
  final Map<String, RemoteFileSystem> _mounted = {};
  final Map<String, Future<RemoteFileSystem>> _connecting = {};
  bool _loaded = false;

  List<RemoteConnection> get connections => List.unmodifiable(_connections);
  bool get isEmpty => _connections.isEmpty;
  bool get loaded => _loaded;

  RemoteStatus statusOf(String id) => _status[id] ?? RemoteStatus.idle;
  String? errorOf(String id) => _errors[id];

  RemoteConnection? byId(String? id) {
    if (id == null) return null;
    for (final c in _connections) {
      if (c.id == id) return c;
    }
    return null;
  }

  RemoteConnection? connectionForPath(String path) =>
      byId(VPath.connectionOf(path));

  /// Display label for a remote path's source, used by the breadcrumb and the
  /// window title so the user sees "Work S3" rather than a uuid.
  String? labelForPath(String path) => connectionForPath(path)?.label;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        _connections = [
          for (final item in list)
            RemoteConnection.fromJson(item as Map<String, dynamic>),
        ];
      }
    } catch (_) {
      // A corrupt entry shouldn't cost the user their file manager; they can
      // re-add the source.
      _connections = const [];
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (_connections.isEmpty) {
      await prefs.remove(_prefsKey);
    } else {
      await prefs.setString(
        _prefsKey,
        jsonEncode([for (final c in _connections) c.toJson()]),
      );
    }
  }

  String newId() => _uuid.v4();

  // ── secrets ──────────────────────────────────────────────────────────────

  Future<Map<String, String>> readSecrets(String id) async {
    try {
      final raw = await _secure.read(key: 'remote_secrets_$id');
      if (raw == null || raw.isEmpty) return const {};
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return {for (final e in map.entries) e.key: '${e.value}'};
    } catch (_) {
      // No keychain (a test host, a Linux box with no libsecret): the source
      // simply can't authenticate, which its status will show.
      return const {};
    }
  }

  Future<void> writeSecrets(String id, Map<String, String> secrets) async {
    final cleaned = {
      for (final e in secrets.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
    try {
      if (cleaned.isEmpty) {
        await _secure.delete(key: 'remote_secrets_$id');
      } else {
        await _secure.write(key: 'remote_secrets_$id', value: jsonEncode(cleaned));
      }
    } catch (e) {
      throw RemoteException('Couldn\'t save the credentials securely: $e');
    }
  }

  // ── connection lifecycle ─────────────────────────────────────────────────

  Future<RemoteConnection> add(
    RemoteConnection connection,
    Map<String, String> secrets,
  ) async {
    await writeSecrets(connection.id, secrets);
    _connections = [..._connections, connection];
    await _persist();
    notifyListeners();
    return connection;
  }

  Future<void> update(
    RemoteConnection connection, {
    Map<String, String>? secrets,
  }) async {
    if (secrets != null) {
      final existing = await readSecrets(connection.id);
      await writeSecrets(connection.id, {...existing, ...secrets});
    }
    _connections = [
      for (final c in _connections)
        if (c.id == connection.id) connection else c,
    ];
    unmount(connection.id);
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    unmount(id);
    _connections = [
      for (final c in _connections)
        if (c.id != id) c,
    ];
    _status.remove(id);
    _errors.remove(id);
    try {
      await _secure.delete(key: 'remote_secrets_$id');
    } catch (_) {
      // Nothing to do — the connection is gone either way.
    }
    await _persist();
    notifyListeners();
  }

  /// Drops the live session for [id] without forgetting the connection. The
  /// next listing signs in again — this is the sidebar's "Eject".
  void unmount(String id) {
    _mounted.remove(id)?.close();
    _connecting.remove(id);
    _status[id] = RemoteStatus.idle;
    _errors.remove(id);
    notifyListeners();
  }

  /// The live filesystem for [id], connecting on first use.
  ///
  /// Concurrent callers share one in-flight connect: a folder listing and a
  /// thumbnail request racing on startup shouldn't produce two OAuth refreshes.
  Future<RemoteFileSystem> fsFor(String id) {
    final mounted = _mounted[id];
    if (mounted != null) return Future.value(mounted);
    final pending = _connecting[id];
    if (pending != null) return pending;

    final future = _mount(id);
    _connecting[id] = future;
    return future.whenComplete(() => _connecting.remove(id));
  }

  Future<RemoteFileSystem> _mount(String id) async {
    final connection = byId(id);
    if (connection == null) {
      throw RemoteException('That remote source has been removed.');
    }
    _status[id] = RemoteStatus.connecting;
    _errors.remove(id);
    notifyListeners();
    try {
      final secrets = await readSecrets(id);
      final fs = build(connection, secrets);
      await fs.connect();
      _mounted[id] = fs;
      _status[id] = RemoteStatus.ready;
      notifyListeners();
      return fs;
    } on RemoteException catch (e) {
      _status[id] = RemoteStatus.error;
      _errors[id] = e.message;
      notifyListeners();
      rethrow;
    } catch (e) {
      _status[id] = RemoteStatus.error;
      _errors[id] = '$e';
      notifyListeners();
      throw RemoteException('$e');
    }
  }

  /// The filesystem a virtual path belongs to, or null for a local path.
  Future<RemoteFileSystem?> fsForPath(String path) async {
    final id = VPath.connectionOf(path);
    if (id == null) return null;
    return fsFor(id);
  }

  /// Registers an already-built filesystem under [id] as if it had connected.
  ///
  /// Exists so the transfer engine can be tested against an in-memory provider:
  /// everything above [RemoteFileSystem] is provider-agnostic, and proving that
  /// with a fake is worth more than mocking HTTP.
  @visibleForTesting
  void mountForTesting(RemoteConnection connection, RemoteFileSystem fs) {
    _connections = [
      for (final c in _connections)
        if (c.id != connection.id) c,
      connection,
    ];
    _mounted[connection.id] = fs;
    _status[connection.id] = RemoteStatus.ready;
    _loaded = true;
    notifyListeners();
  }

  /// Drops every mounted session and forgets the in-memory connection list.
  /// Test-only: the persisted list is untouched.
  @visibleForTesting
  void resetForTesting() {
    for (final fs in _mounted.values) {
      fs.close();
    }
    _mounted.clear();
    _connecting.clear();
    _connections = const [];
    _status.clear();
    _errors.clear();
    _loaded = false;
  }

  /// Builds a provider instance without registering it — used by [test] and by
  /// [_mount].
  RemoteFileSystem build(
    RemoteConnection connection,
    Map<String, String> secrets,
  ) {
    switch (connection.kind) {
      case RemoteKind.s3:
        return S3FileSystem.fromConnection(connection, secrets);
      case RemoteKind.gdrive:
        return GoogleDriveFileSystem.fromConnection(
          connection,
          secrets,
          // A refreshed refresh-token has to survive the session, or the next
          // launch signs in from scratch.
          onTokensChanged: (token) async {
            final current = await readSecrets(connection.id);
            await writeSecrets(connection.id, {
              ...current,
              RemoteKeys.refreshToken: token,
            });
          },
        );
      case RemoteKind.sftp:
        return SftpFileSystem.fromConnection(
          connection,
          secrets,
          // Trust on first use: the key seen on the first connection is
          // pinned, and a later mismatch fails loudly.
          onHostKeyLearned: (fingerprint) =>
              rememberHostKey(connection.id, fingerprint),
        );
      case RemoteKind.smb:
        return SmbFileSystem.fromConnection(connection, secrets);
      case RemoteKind.webdav:
        return WebDavFileSystem.fromConnection(connection, secrets);
    }
  }

  /// Tries a connection's credentials and throws with a readable message if
  /// they don't work. Used by the dialog's "Test" button before saving, so a
  /// broken source never reaches the sidebar.
  Future<void> test(
    RemoteConnection connection,
    Map<String, String> secrets,
  ) async {
    final fs = build(connection, secrets);
    try {
      await fs.connect();
    } finally {
      fs.close();
    }
  }

  /// Pins a host key against a connection.
  ///
  /// Deliberately not [update]: that tears the live session down, and this is
  /// called *during* the handshake that is establishing it.
  Future<void> rememberHostKey(String id, String fingerprint) async {
    final connection = byId(id);
    if (connection == null) return;
    if (connection.get(RemoteKeys.hostKey) == fingerprint) return;
    _connections = [
      for (final c in _connections)
        if (c.id == id)
          c.copyWith(config: {...c.config, RemoteKeys.hostKey: fingerprint})
        else
          c,
    ];
    await _persist();
    notifyListeners();
  }

  /// Marks a connection as broken after an operation failed, so the sidebar
  /// can show it without every call site handling status.
  void reportFailure(String id, Object error) {
    _status[id] = RemoteStatus.error;
    _errors[id] = error is RemoteException ? error.message : '$error';
    // A failed auth means the session is worthless; drop it so the next
    // attempt re-authenticates rather than replaying a dead token.
    if (error is RemoteException && error.isAuthFailure) {
      _mounted.remove(id)?.close();
    }
    notifyListeners();
  }

  void reportSuccess(String id) {
    if (_status[id] == RemoteStatus.ready) return;
    _status[id] = RemoteStatus.ready;
    _errors.remove(id);
    notifyListeners();
  }

  @override
  void dispose() {
    for (final fs in _mounted.values) {
      fs.close();
    }
    _mounted.clear();
    super.dispose();
  }
}
