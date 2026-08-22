import 'dart:async';
import 'dart:convert';

import '../../models/remote/remote_connection.dart';
import 'http_util.dart';
import 'oauth_loopback.dart';
import 'remote_file_system.dart';
import 'remote_path.dart';

/// Google Drive, mapped onto a folder tree.
///
/// Drive addresses files by opaque id and lets two files in one folder share a
/// name, so the browser's `String path` has to be resolved to an id on the way
/// in. Every listing seeds a path→id cache, which means the common case —
/// click into a folder, act on what you see — costs no extra round trips; a
/// path typed into the location bar walks the tree a level at a time. Where a
/// folder really does hold two files with the same name, the first one Drive
/// returns wins, and the second is reachable through its own listing row.
class GoogleDriveFileSystem extends RemoteFileSystem {
  GoogleDriveFileSystem({
    required String connectionId,
    required this.clientId,
    required this.clientSecret,
    required String refreshToken,
    required this.onTokensChanged,
  })  : _refreshToken = refreshToken,
        super(connectionId);

  factory GoogleDriveFileSystem.fromConnection(
    RemoteConnection connection,
    Map<String, String> secrets, {
    required Future<void> Function(String refreshToken) onTokensChanged,
  }) =>
      GoogleDriveFileSystem(
        connectionId: connection.id,
        clientId: connection.get(RemoteKeys.clientId),
        clientSecret: secrets[RemoteKeys.clientSecret] ?? '',
        refreshToken: secrets[RemoteKeys.refreshToken] ?? '',
        onTokensChanged: onTokensChanged,
      );

  final String clientId;
  final String clientSecret;

  /// Called when a sign-in or refresh produces a new refresh token, so the
  /// registry can put it back in the keychain.
  final Future<void> Function(String refreshToken) onTokensChanged;

  String _refreshToken;
  String _accessToken = '';
  DateTime _accessExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  final RemoteHttp _http = RemoteHttp();

  /// Virtual path → Drive file id. Seeded with the root, filled by listings.
  final Map<String, String> _ids = {'/': 'root'};

  static const _scopes = ['https://www.googleapis.com/auth/drive'];
  static const _folderMime = 'application/vnd.google-apps.folder';
  static const _fileFields =
      'id,name,mimeType,size,modifiedTime,webViewLink,trashed';

  /// What a Google-native document turns into on the way out. Drive won't hand
  /// over a Doc as bytes, so a download has to pick an export format; these are
  /// the ones that keep the most of the original.
  static const _exportFormats = <String, ({String mime, String extension})>{
    'application/vnd.google-apps.document': (
      mime:
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      extension: '.docx',
    ),
    'application/vnd.google-apps.spreadsheet': (
      mime:
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      extension: '.xlsx',
    ),
    'application/vnd.google-apps.presentation': (
      mime:
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      extension: '.pptx',
    ),
    'application/vnd.google-apps.drawing': (
      mime: 'image/png',
      extension: '.png',
    ),
  };

  LoopbackOAuth get _oauth => LoopbackOAuth(
        authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
        tokenEndpoint: 'https://oauth2.googleapis.com/token',
        clientId: clientId,
        clientSecret: clientSecret,
        scopes: _scopes,
        extraAuthParams: const {
          // Without both of these Google hands back an access token only, and
          // the connection would need a browser round trip every hour.
          'access_type': 'offline',
          'prompt': 'consent',
        },
      );

  /// Runs the browser consent flow and returns the refresh token to store.
  /// Called by the add-connection dialog, before the connection is saved.
  static Future<String> signIn({
    required String clientId,
    required String clientSecret,
  }) async {
    final tokens = await LoopbackOAuth(
      authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
      tokenEndpoint: 'https://oauth2.googleapis.com/token',
      clientId: clientId,
      clientSecret: clientSecret,
      scopes: _scopes,
      extraAuthParams: const {
        'access_type': 'offline',
        'prompt': 'consent',
      },
    ).authorize();
    if (tokens.refreshToken.isEmpty) {
      throw RemoteException(
        'Google didn\'t return a refresh token. Remove Notilus from your '
        'account\'s third-party access and try again.',
      );
    }
    return tokens.refreshToken;
  }

  // ── auth ─────────────────────────────────────────────────────────────────

  Future<String> _token() async {
    if (_accessToken.isNotEmpty && DateTime.now().isBefore(_accessExpiry)) {
      return _accessToken;
    }
    if (_refreshToken.isEmpty) {
      throw RemoteException('This Google Drive source is not signed in.',
          statusCode: 401);
    }
    final tokens = await _oauth.refresh(_refreshToken);
    _accessToken = tokens.accessToken;
    _accessExpiry = tokens.expiresAt.subtract(const Duration(minutes: 2));
    if (tokens.refreshToken.isNotEmpty && tokens.refreshToken != _refreshToken) {
      _refreshToken = tokens.refreshToken;
      await onTokensChanged(_refreshToken);
    }
    return _accessToken;
  }

  Future<Map<String, String>> _authHeaders([Map<String, String> extra = const {}]) async =>
      {'authorization': 'Bearer ${await _token()}', ...extra};

  // ── plumbing ─────────────────────────────────────────────────────────────

  Uri _api(String path, [Map<String, String> query = const {}]) =>
      Uri.https('www.googleapis.com', '/drive/v3$path', {
        'supportsAllDrives': 'true',
        ...query,
      });

  Future<Map<String, dynamic>> _json(
    String method,
    Uri uri, {
    Object? body,
  }) async {
    final encoded = body == null ? null : utf8.encode(jsonEncode(body));
    final result = await _http.sendText(
      method,
      uri,
      headers: await _authHeaders(
        encoded == null ? const {} : {'content-type': 'application/json'},
      ),
      body: encoded == null ? null : Stream.value(encoded),
      contentLength: encoded?.length,
    );
    if (result.status >= 300) _fail(result.status, result.body);
    if (result.body.isEmpty) return const {};
    final decoded = jsonDecode(result.body);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  Never _fail(int status, String body) {
    String message = 'HTTP $status';
    try {
      final json = jsonDecode(body);
      if (json is Map && json['error'] is Map) {
        message = '${(json['error'] as Map)['message'] ?? message}';
      }
    } catch (_) {
      // Not JSON — the status alone is the best available description.
    }
    throw RemoteException('Google Drive: $message', statusCode: status);
  }

  static String _escapeQuery(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  RemoteEntry _toEntry(Map<String, dynamic> file, String parentVPath) {
    final isFolder = file['mimeType'] == _folderMime;
    final name = '${file['name'] ?? ''}';
    final path = VPath.join(parentVPath, name);
    _ids.putIfAbsent(VPath.parse(path)!.path, () => '${file['id']}');
    return RemoteEntry(
      path: path,
      name: name,
      isDirectory: isFolder,
      size: int.tryParse('${file['size'] ?? 0}') ?? 0,
      modified: DateTime.tryParse('${file['modifiedTime'] ?? ''}')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      providerId: '${file['id']}',
      mimeType: '${file['mimeType'] ?? ''}',
      webLink: file['webViewLink'] as String?,
    );
  }

  /// Resolves a virtual path to a Drive id, walking from the root and caching
  /// each level on the way down.
  Future<String> _idFor(String vpath) async {
    final ref = VPath.parse(vpath);
    if (ref == null) throw RemoteException('Not a Drive path: $vpath');
    final cached = _ids[ref.path];
    if (cached != null) return cached;

    var parentId = 'root';
    var walked = '';
    for (final segment in ref.segments) {
      walked = '$walked/$segment';
      final known = _ids[walked];
      if (known != null) {
        parentId = known;
        continue;
      }
      final response = await _json(
        'GET',
        _api('/files', {
          'q': "name = '${_escapeQuery(segment)}' and "
              "'$parentId' in parents and trashed = false",
          'fields': 'files($_fileFields)',
          'pageSize': '1',
          'includeItemsFromAllDrives': 'true',
        }),
      );
      final files = (response['files'] as List?) ?? const [];
      if (files.isEmpty) {
        throw RemoteException('"$segment" isn\'t in this Drive folder.',
            statusCode: 404);
      }
      parentId = '${(files.first as Map)['id']}';
      _ids[walked] = parentId;
    }
    return parentId;
  }

  // ── RemoteFileSystem ─────────────────────────────────────────────────────

  @override
  Future<void> connect() async {
    await _token();
    await _json('GET', _api('/files', {'pageSize': '1', 'fields': 'files(id)'}));
  }

  @override
  Future<List<RemoteEntry>> list(String vpath) async {
    final parentId = await _idFor(vpath);
    final out = <RemoteEntry>[];
    String? pageToken;
    do {
      final response = await _json(
        'GET',
        _api('/files', {
          'q': "'$parentId' in parents and trashed = false",
          'fields': 'nextPageToken,files($_fileFields)',
          'pageSize': '200',
          'orderBy': 'folder,name',
          'includeItemsFromAllDrives': 'true',
          if (pageToken != null) 'pageToken': pageToken,
        }),
      );
      for (final file in (response['files'] as List?) ?? const []) {
        out.add(_toEntry(file as Map<String, dynamic>, vpath));
      }
      pageToken = response['nextPageToken'] as String?;
    } while (pageToken != null && pageToken.isNotEmpty);
    return out;
  }

  @override
  Future<RemoteEntry?> stat(String vpath) async {
    final ref = VPath.parse(vpath);
    if (ref == null) return null;
    if (ref.isRoot) {
      return RemoteEntry(
        path: vpath,
        name: 'Drive',
        isDirectory: true,
        size: 0,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
        providerId: 'root',
      );
    }
    try {
      final id = await _idFor(vpath);
      final file = await _json('GET', _api('/files/$id', {'fields': _fileFields}));
      if (file['trashed'] == true) return null;
      return _toEntry(file, VPath.dirname(vpath));
    } on RemoteException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<RemoteDownload> download(String vpath) async {
    final id = await _idFor(vpath);
    final meta = await _json('GET', _api('/files/$id', {'fields': _fileFields}));
    final mime = '${meta['mimeType'] ?? ''}';
    final export = _exportFormats[mime];

    final uri = export == null
        ? _api('/files/$id', {'alt': 'media'})
        : _api('/files/$id/export', {'mimeType': export.mime});
    final response =
        await _http.send('GET', uri, headers: await _authHeaders());
    if (response.statusCode >= 300) {
      _fail(response.statusCode, await RemoteHttp.readText(response));
    }
    final baseName = '${meta['name'] ?? VPath.basename(vpath)}';
    return RemoteDownload(
      stream: response,
      length: response.contentLength,
      // A Doc downloaded as .docx should land with that extension, or the OS
      // has no idea what it just received.
      name: export == null ? null : '$baseName${export.extension}',
    );
  }

  @override
  Future<void> upload({
    required String vpath,
    required Stream<List<int>> data,
    required int length,
  }) async {
    final parentId = await _idFor(VPath.dirname(vpath));
    final name = VPath.basename(vpath);
    final metadata = utf8.encode(jsonEncode({
      'name': name,
      'parents': [parentId],
    }));

    // Resumable rather than simple upload: it is the only mode Drive supports
    // above 5 MB, and it works the same for a 2 KB file, so there is no reason
    // to carry two code paths.
    final initiate = await _http.send(
      'POST',
      Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
        'uploadType': 'resumable',
        'supportsAllDrives': 'true',
      }),
      headers: await _authHeaders({
        'content-type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Length': '$length',
      }),
      body: Stream.value(metadata),
      contentLength: metadata.length,
    );
    if (initiate.statusCode >= 300) {
      _fail(initiate.statusCode, await RemoteHttp.readText(initiate));
    }
    final location = initiate.headers.value('location');
    await initiate.drain<void>();
    if (location == null) {
      throw RemoteException('Google Drive didn\'t open an upload session.');
    }

    final upload = await _http.send(
      'PUT',
      Uri.parse(location),
      headers: {'content-type': 'application/octet-stream'},
      body: data,
      contentLength: length,
    );
    if (upload.statusCode >= 300) {
      _fail(upload.statusCode, await RemoteHttp.readText(upload));
    }
    final created = await RemoteHttp.readJson(upload);
    final id = created['id'];
    if (id != null) _ids[VPath.parse(vpath)!.path] = '$id';
  }

  @override
  Future<void> createDirectory(String vpath) async {
    final parentId = await _idFor(VPath.dirname(vpath));
    final created = await _json('POST', _api('/files', {'fields': _fileFields}),
        body: {
          'name': VPath.basename(vpath),
          'mimeType': _folderMime,
          'parents': [parentId],
        });
    _ids[VPath.parse(vpath)!.path] = '${created['id']}';
  }

  @override
  Future<void> delete(String vpath, {required bool isDirectory}) async {
    final id = await _idFor(vpath);
    // Trashed, not destroyed: Drive's own UI does the same, and a file manager
    // shouldn't be the one place where a delete is unrecoverable.
    await _json('PATCH', _api('/files/$id'), body: {'trashed': true});
    _ids.remove(VPath.parse(vpath)!.path);
  }

  @override
  Future<String> rename(String vpath, String newName) async {
    final id = await _idFor(vpath);
    await _json('PATCH', _api('/files/$id'), body: {'name': newName});
    final ref = VPath.parse(vpath)!;
    _ids.remove(ref.path);
    final destination = VPath.join(VPath.dirname(vpath), newName);
    _ids[VPath.parse(destination)!.path] = id;
    return destination;
  }

  @override
  bool get supportsServerSideCopy => true;

  @override
  Future<void> copyWithin(String fromVPath, String toVPath) async {
    final id = await _idFor(fromVPath);
    final parentId = await _idFor(VPath.dirname(toVPath));
    await _json('POST', _api('/files/$id/copy', {'fields': _fileFields}), body: {
      'name': VPath.basename(toVPath),
      'parents': [parentId],
    });
  }

  @override
  Future<String?> shareLink(String vpath) async {
    final id = await _idFor(vpath);
    final file = await _json('GET', _api('/files/$id', {'fields': 'webViewLink'}));
    // Whatever sharing the file already has, unchanged — granting access is a
    // decision that belongs in Drive's own sharing dialog, not in a copy-link
    // menu item.
    return file['webViewLink'] as String?;
  }

  @override
  Future<bool> exists(String vpath) async {
    try {
      return await stat(vpath) != null;
    } on RemoteException catch (e) {
      if (e.statusCode == 404) return false;
      rethrow;
    }
  }

  @override
  void close() => _http.close();
}
