import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpHeaders;

import '../../models/remote/remote_connection.dart';
import 'http_util.dart';
import 'remote_file_system.dart';
import 'remote_path.dart';
import 'xml_lite.dart';

/// WebDAV — which is how Nextcloud, ownCloud, Box, Synology and a plain Apache
/// `mod_dav` share a folder tree over HTTP.
///
/// It is the closest of the three providers to a real filesystem: it has
/// directories, MOVE and COPY, so rename and server-side copy are single
/// requests rather than the copy-and-delete dance S3 needs.
class WebDavFileSystem extends RemoteFileSystem {
  WebDavFileSystem({
    required String connectionId,
    required String baseUrl,
    required this.username,
    required this.password,
  })  : _base = _normalizeBase(baseUrl),
        super(connectionId);

  factory WebDavFileSystem.fromConnection(
    RemoteConnection connection,
    Map<String, String> secrets,
  ) =>
      WebDavFileSystem(
        connectionId: connection.id,
        baseUrl: connection.get(RemoteKeys.baseUrl),
        username: connection.get(RemoteKeys.username),
        password: secrets[RemoteKeys.password] ?? '',
      );

  final Uri _base;
  final String username;
  final String password;

  final RemoteHttp _http = RemoteHttp();

  static Uri _normalizeBase(String raw) {
    var text = raw.trim();
    if (text.isEmpty) throw RemoteException('This WebDAV source has no URL.');
    if (!text.contains('://')) text = 'https://$text';
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    return Uri.parse(text);
  }

  Map<String, String> get _headers => {
        if (username.isNotEmpty || password.isNotEmpty)
          'authorization':
              'Basic ${base64.encode(utf8.encode('$username:$password'))}',
      };

  Uri _url(String vpath, {bool directory = false}) {
    final ref = VPath.parse(vpath);
    if (ref == null) throw RemoteException('Not a remote path: $vpath');
    final suffix = ref.isRoot ? '' : uriEncodePath(ref.path);
    // A collection URL has to end in a slash or some servers answer 301 for it.
    return Uri.parse('$_base$suffix${directory && !ref.isRoot ? '/' : ''}');
  }

  Never _fail(int status, String what) {
    final detail = switch (status) {
      401 => 'the server rejected the username or password',
      403 => 'the server refused access',
      404 => 'it isn\'t there any more',
      409 => 'the parent folder doesn\'t exist',
      507 => 'the server is out of space',
      _ => 'HTTP $status',
    };
    throw RemoteException('$what — $detail.', statusCode: status);
  }

  // ── RemoteFileSystem ─────────────────────────────────────────────────────

  @override
  Future<void> connect() async {
    await _propfind(VPath.root(connectionId), depth: 0);
  }

  @override
  Future<List<RemoteEntry>> list(String vpath) async {
    final responses = await _propfind(vpath, depth: 1);
    final selfPath = VPath.parse(vpath)!.path;
    final out = <RemoteEntry>[];
    for (final entry in responses) {
      // Depth-1 includes the collection itself; skip it rather than nesting a
      // folder inside itself.
      if (entry.path == selfPath) continue;
      out.add(RemoteEntry(
        path: VPath.build(connectionId, entry.path),
        name: entry.name,
        isDirectory: entry.isDirectory,
        size: entry.size,
        modified: entry.modified,
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
    try {
      final responses = await _propfind(vpath, depth: 0);
      if (responses.isEmpty) return null;
      final entry = responses.first;
      return RemoteEntry(
        path: vpath,
        name: entry.name,
        isDirectory: entry.isDirectory,
        size: entry.size,
        modified: entry.modified,
      );
    } on RemoteException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<List<_DavEntry>> _propfind(String vpath, {required int depth}) async {
    const body = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propfind xmlns:d="DAV:"><d:prop>'
        '<d:displayname/><d:getcontentlength/><d:getlastmodified/>'
        '<d:resourcetype/><d:getcontenttype/>'
        '</d:prop></d:propfind>';
    final encoded = utf8.encode(body);
    Future<({int status, String body, HttpHeaders headers})> ask(bool slash) =>
        _http.sendText(
          'PROPFIND',
          _url(vpath, directory: slash),
          headers: {
            ..._headers,
            'depth': '$depth',
            'content-type': 'application/xml; charset=utf-8',
          },
          body: Stream.value(encoded),
          contentLength: encoded.length,
        );

    // Ask for the plain URL first — a file must not carry a trailing slash —
    // and follow up with the collection form if the server redirects, which is
    // how most of them say "that one is a folder". Redirects aren't followed
    // automatically because a replayed request would drop its auth header.
    var result = await ask(false);
    if (result.status == 301 || result.status == 302 || result.status == 308) {
      result = await ask(true);
    }
    if (result.status == 404) {
      throw RemoteException('"${VPath.basename(vpath)}" isn\'t there.',
          statusCode: 404);
    }
    if (result.status >= 300) {
      _fail(result.status, 'Couldn\'t read "${VPath.basename(vpath)}"');
    }
    final xml = parseXml(result.body);
    if (xml == null) {
      throw RemoteException('The server sent an unreadable listing.');
    }

    final out = <_DavEntry>[];
    for (final response in xml.findAllDeep('response')) {
      final href = response.textOf('href');
      if (href.isEmpty) continue;
      final path = _pathFromHref(href);
      if (path == null) continue;
      final prop = response.findDeep('prop');
      final isDirectory = prop?.findDeep('collection') != null;
      final displayName = prop?.deepTextOf('displayname') ?? '';
      final name = displayName.isNotEmpty
          ? displayName
          : (path == '/' ? '' : path.substring(path.lastIndexOf('/') + 1));
      out.add(_DavEntry(
        path: path,
        name: name,
        isDirectory: isDirectory,
        size: int.tryParse(prop?.deepTextOf('getcontentlength') ?? '') ?? 0,
        modified: _parseHttpDate(prop?.deepTextOf('getlastmodified') ?? ''),
      ));
    }
    return out;
  }

  /// Turns an href from the server — which may be a full URL, and is always
  /// percent-encoded — into a path relative to the configured base.
  String? _pathFromHref(String href) {
    var path = href.startsWith('http') ? Uri.parse(href).path : href;
    try {
      path = Uri.decodeComponent(path);
    } catch (_) {
      // Leave it encoded rather than dropping the row.
    }
    final basePath = Uri.decodeComponent(_base.path);
    if (basePath.isNotEmpty && path.startsWith(basePath)) {
      path = path.substring(basePath.length);
    }
    if (path.isEmpty) return '/';
    if (!path.startsWith('/')) path = '/$path';
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  @override
  Future<RemoteDownload> download(String vpath) async {
    final response =
        await _http.send('GET', _url(vpath), headers: _headers);
    if (response.statusCode >= 300) {
      await response.drain<void>();
      _fail(response.statusCode, 'Couldn\'t download "${VPath.basename(vpath)}"');
    }
    return RemoteDownload(stream: response, length: response.contentLength);
  }

  @override
  Future<void> upload({
    required String vpath,
    required Stream<List<int>> data,
    required int length,
  }) async {
    final response = await _http.send(
      'PUT',
      _url(vpath),
      headers: {..._headers, 'content-type': 'application/octet-stream'},
      body: data,
      contentLength: length,
    );
    if (response.statusCode >= 300) {
      await response.drain<void>();
      _fail(response.statusCode, 'Couldn\'t upload "${VPath.basename(vpath)}"');
    }
    await response.drain<void>();
  }

  @override
  Future<void> createDirectory(String vpath) async {
    final result = await _http.sendText('MKCOL', _url(vpath, directory: true),
        headers: _headers);
    if (result.status >= 300 && result.status != 405) {
      _fail(result.status, 'Couldn\'t create "${VPath.basename(vpath)}"');
    }
  }

  @override
  Future<void> delete(String vpath, {required bool isDirectory}) async {
    final result = await _http.sendText(
      'DELETE',
      _url(vpath, directory: isDirectory),
      headers: _headers,
    );
    if (result.status >= 300 && result.status != 404) {
      _fail(result.status, 'Couldn\'t delete "${VPath.basename(vpath)}"');
    }
  }

  @override
  Future<String> rename(String vpath, String newName) async {
    final destination = VPath.join(VPath.dirname(vpath), newName);
    final result = await _http.sendText(
      'MOVE',
      _url(vpath),
      headers: {
        ..._headers,
        'destination': '${_url(destination)}',
        'overwrite': 'F',
      },
    );
    if (result.status >= 300) {
      _fail(result.status, 'Couldn\'t rename "${VPath.basename(vpath)}"');
    }
    return destination;
  }

  @override
  bool get supportsServerSideCopy => true;

  @override
  Future<void> copyWithin(String fromVPath, String toVPath) async {
    final result = await _http.sendText(
      'COPY',
      _url(fromVPath),
      headers: {
        ..._headers,
        'destination': '${_url(toVPath)}',
        'overwrite': 'F',
        'depth': 'infinity',
      },
    );
    if (result.status >= 300) {
      _fail(result.status, 'Couldn\'t copy "${VPath.basename(fromVPath)}"');
    }
  }

  @override
  void close() => _http.close();

  static DateTime _parseHttpDate(String raw) {
    if (raw.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    try {
      return HttpDateParser.parse(raw).toLocal();
    } catch (_) {
      return DateTime.tryParse(raw)?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0);
    }
  }
}

class _DavEntry {
  const _DavEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int size;
  final DateTime modified;
}

/// `getlastmodified` is an RFC 1123 date, which `DateTime.parse` won't take.
class HttpDateParser {
  const HttpDateParser._();

  static const _months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };

  static DateTime parse(String raw) {
    final match = RegExp(
      r'(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(raw);
    if (match == null) throw FormatException('Not an HTTP date: $raw');
    return DateTime.utc(
      int.parse(match.group(3)!),
      _months[match.group(2)!] ?? 1,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }
}
