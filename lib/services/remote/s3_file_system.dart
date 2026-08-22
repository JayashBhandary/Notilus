import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/remote/remote_connection.dart';
import 'http_util.dart';
import 'remote_file_system.dart';
import 'remote_path.dart';
import 'xml_lite.dart';

/// S3 and everything that speaks its API — MinIO, Cloudflare R2, Backblaze B2,
/// Wasabi, DigitalOcean Spaces.
///
/// The AWS SDK is not used: it would be a large dependency for the handful of
/// calls a file browser makes, and the request signing (SigV4) is a page of
/// HMAC-SHA256 that has to be right once. Everything below is that one page
/// plus five REST calls — list, get, put, copy, delete.
///
/// **Folders.** S3 has none; it has keys with slashes in them. Listing with
/// `delimiter=/` makes the service report the common prefixes, which is what
/// this maps onto directories. Creating a folder writes a zero-byte object
/// ending in `/`, the same convention the AWS console uses, so an empty folder
/// survives until something is put in it.
class S3FileSystem extends RemoteFileSystem {
  S3FileSystem({
    required String connectionId,
    required this.region,
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken = '',
    String endpoint = '',
    String bucket = '',
    bool forcePathStyle = false,
    DateTime Function()? clock,
  })  : _endpoint = endpoint.trim(),
        _clock = clock ?? (() => DateTime.now().toUtc()),
        fixedBucket = bucket.trim(),
        _forcePathStyle = forcePathStyle,
        super(connectionId);

  factory S3FileSystem.fromConnection(
    RemoteConnection connection,
    Map<String, String> secrets,
  ) =>
      S3FileSystem(
        connectionId: connection.id,
        region: connection.get(RemoteKeys.region, 'us-east-1'),
        endpoint: connection.get(RemoteKeys.endpoint),
        bucket: connection.get(RemoteKeys.bucket),
        forcePathStyle: connection.getFlag(RemoteKeys.pathStyle),
        accessKeyId: secrets[RemoteKeys.accessKeyId] ?? '',
        secretAccessKey: secrets[RemoteKeys.secretAccessKey] ?? '',
        sessionToken: secrets[RemoteKeys.sessionToken] ?? '',
      );

  final String region;
  final String accessKeyId;
  final String secretAccessKey;
  final String sessionToken;
  final String _endpoint;
  final bool _forcePathStyle;

  /// Injectable so the signature can be checked against AWS's published test
  /// vector, which is fixed to one instant.
  final DateTime Function() _clock;

  /// When set, the connection is pinned to one bucket and the virtual root is
  /// that bucket's contents. When empty, the root lists the account's buckets.
  final String fixedBucket;

  final RemoteHttp _http = RemoteHttp();

  static final DateTime _epoch = DateTime.utc(1970);
  static const String _emptyBodySha256 =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
  static const String _unsignedPayload = 'UNSIGNED-PAYLOAD';

  // ── addressing ───────────────────────────────────────────────────────────

  String get _host {
    if (_endpoint.isNotEmpty) return Uri.parse(_normalizedEndpoint).host;
    return region == 'us-east-1'
        ? 's3.amazonaws.com'
        : 's3.$region.amazonaws.com';
  }

  String get _scheme {
    if (_endpoint.isEmpty) return 'https';
    return Uri.parse(_normalizedEndpoint).scheme;
  }

  int? get _port {
    if (_endpoint.isEmpty) return null;
    final uri = Uri.parse(_normalizedEndpoint);
    return uri.hasPort ? uri.port : null;
  }

  String get _normalizedEndpoint =>
      _endpoint.contains('://') ? _endpoint : 'https://$_endpoint';

  /// AWS wants virtual-hosted addressing (`bucket.s3.…`); self-hosted services
  /// like MinIO usually only do path style (`host/bucket/…`). Defaulting on
  /// the host, with an override in the dialog, gets both right without asking.
  bool get _pathStyle =>
      _forcePathStyle || (_endpoint.isNotEmpty && !_host.endsWith('amazonaws.com'));

  ({String? bucket, String key}) _locate(String vpath) {
    final ref = VPath.parse(vpath);
    if (ref == null) {
      throw RemoteException('Not a remote path: $vpath');
    }
    if (fixedBucket.isNotEmpty) return (bucket: fixedBucket, key: ref.key);
    if (ref.isRoot) return (bucket: null, key: '');
    final segments = ref.segments;
    return (bucket: segments.first, key: segments.skip(1).join('/'));
  }

  String _vpathFor(String? bucket, String key) {
    if (fixedBucket.isNotEmpty) return VPath.build(connectionId, '/$key');
    return VPath.build(connectionId, '/${bucket ?? ''}/$key');
  }

  ({Uri uri, String canonicalPath, String signHost}) _request(
    String? bucket,
    String key, {
    Map<String, String> query = const {},
  }) {
    var host = _host;
    var path = '/';
    if (bucket == null) {
      path = '/';
    } else if (_pathStyle) {
      path = '/$bucket${key.isEmpty ? '' : '/$key'}';
    } else {
      host = '$bucket.$_host';
      path = '/$key';
    }
    final port = _port;
    final uri = Uri(
      scheme: _scheme,
      host: host,
      port: port,
      path: path,
      queryParameters: query.isEmpty ? null : query,
    );
    return (
      uri: uri,
      canonicalPath: uriEncodePath(path),
      signHost: port == null ? host : '$host:$port',
    );
  }

  // ── signing ──────────────────────────────────────────────────────────────

  static String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  static List<int> _hmac(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  String _amzDate(DateTime now) =>
      '${_datestamp(now)}T${_two(now.hour)}${_two(now.minute)}${_two(now.second)}Z';

  static String _datestamp(DateTime now) =>
      '${now.year.toString().padLeft(4, '0')}${_two(now.month)}${_two(now.day)}';

  static String _two(int v) => v.toString().padLeft(2, '0');

  String _canonicalQuery(Map<String, String> query) {
    final keys = query.keys.toList()..sort();
    return keys
        .map((k) => '${uriEncodeComponent(k)}=${uriEncodeComponent(query[k]!)}')
        .join('&');
  }

  /// Adds Authorization + the x-amz-* headers a signed request needs.
  Map<String, String> _sign({
    required String method,
    required String canonicalPath,
    required String signHost,
    required Map<String, String> query,
    required Map<String, String> extraHeaders,
    required String payloadHash,
  }) {
    if (accessKeyId.isEmpty || secretAccessKey.isEmpty) {
      throw RemoteException('This S3 source has no access key saved.');
    }
    final now = _clock();
    final amzDate = _amzDate(now);
    final dateStamp = _datestamp(now);

    final headers = <String, String>{
      'host': signHost,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      if (sessionToken.isNotEmpty) 'x-amz-security-token': sessionToken,
      for (final e in extraHeaders.entries) e.key.toLowerCase(): e.value.trim(),
    };

    final signedNames = headers.keys.toList()..sort();
    final canonicalHeaders =
        signedNames.map((h) => '$h:${headers[h]}\n').join();
    final signedHeaders = signedNames.join(';');

    final canonicalRequest = [
      method,
      canonicalPath,
      _canonicalQuery(query),
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final scope = '$dateStamp/$region/s3/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      _sha256Hex(utf8.encode(canonicalRequest)),
    ].join('\n');

    var key = _hmac(utf8.encode('AWS4$secretAccessKey'), dateStamp);
    key = _hmac(key, region);
    key = _hmac(key, 's3');
    key = _hmac(key, 'aws4_request');
    final signature =
        Hmac(sha256, key).convert(utf8.encode(stringToSign)).toString();

    return {
      ...headers,
      'Authorization': 'AWS4-HMAC-SHA256 '
          'Credential=$accessKeyId/$scope, '
          'SignedHeaders=$signedHeaders, '
          'Signature=$signature',
    };
  }

  Future<({int status, String body})> _call(
    String method,
    String? bucket,
    String key, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
  }) async {
    final target = _request(bucket, key, query: query);
    final signed = _sign(
      method: method,
      canonicalPath: target.canonicalPath,
      signHost: target.signHost,
      query: query,
      extraHeaders: headers,
      payloadHash: _emptyBodySha256,
    );
    final result = await _http.sendText(method, target.uri, headers: signed);
    return (status: result.status, body: result.body);
  }

  Never _fail(int status, String body, String what) {
    final xml = parseXml(body);
    final message = xml?.deepTextOf('Message');
    throw RemoteException(
      message != null && message.isNotEmpty
          ? '$what: $message'
          : '$what: HTTP $status',
      statusCode: status,
    );
  }

  // ── RemoteFileSystem ─────────────────────────────────────────────────────

  @override
  Future<void> connect() async {
    if (fixedBucket.isEmpty) {
      final r = await _call('GET', null, '');
      if (r.status >= 300) _fail(r.status, r.body, 'Couldn\'t list buckets');
      return;
    }
    final r = await _call('GET', fixedBucket, '',
        query: {'list-type': '2', 'max-keys': '1'});
    if (r.status >= 300) {
      _fail(r.status, r.body, 'Couldn\'t open bucket "$fixedBucket"');
    }
  }

  @override
  Future<List<RemoteEntry>> list(String vpath) async {
    final loc = _locate(vpath);
    if (loc.bucket == null) return _listBuckets();

    final prefix = loc.key.isEmpty ? '' : '${loc.key}/';
    final out = <RemoteEntry>[];
    String? token;
    do {
      final query = {
        'list-type': '2',
        'delimiter': '/',
        'encoding-type': 'url',
        'max-keys': '1000',
        if (prefix.isNotEmpty) 'prefix': prefix,
        if (token != null) 'continuation-token': token,
      };
      final r = await _call('GET', loc.bucket, '', query: query);
      if (r.status >= 300) _fail(r.status, r.body, 'Couldn\'t list this folder');
      final xml = parseXml(r.body);
      if (xml == null) throw RemoteException('The server sent an unreadable listing.');

      for (final cp in xml.findAll('CommonPrefixes')) {
        final raw = _decodeKey(cp.textOf('Prefix'));
        if (raw.isEmpty) continue;
        final name = raw.substring(prefix.length).replaceAll('/', '');
        if (name.isEmpty) continue;
        out.add(RemoteEntry(
          path: _vpathFor(loc.bucket, '$prefix$name'),
          name: name,
          isDirectory: true,
          size: 0,
          modified: _epoch,
          providerId: raw,
        ));
      }
      for (final item in xml.findAll('Contents')) {
        final rawKey = _decodeKey(item.textOf('Key'));
        if (rawKey.isEmpty || rawKey == prefix) continue;
        final name = rawKey.substring(prefix.length);
        // A zero-byte "folder marker" is the directory itself, already
        // reported through CommonPrefixes.
        if (name.isEmpty || name.endsWith('/')) continue;
        out.add(RemoteEntry(
          path: _vpathFor(loc.bucket, rawKey),
          name: name,
          isDirectory: false,
          size: int.tryParse(item.textOf('Size')) ?? 0,
          modified: _parseDate(item.textOf('LastModified')),
          providerId: rawKey,
        ));
      }
      token = xml.textOf('IsTruncated') == 'true'
          ? _decodeKey(xml.textOf('NextContinuationToken'))
          : null;
    } while (token != null && token.isNotEmpty);

    out.sort(_byKindThenName);
    return out;
  }

  Future<List<RemoteEntry>> _listBuckets() async {
    final r = await _call('GET', null, '');
    if (r.status >= 300) _fail(r.status, r.body, 'Couldn\'t list buckets');
    final xml = parseXml(r.body);
    final out = <RemoteEntry>[];
    for (final bucket in xml?.findAllDeep('Bucket') ?? const <XmlNode>[]) {
      final name = bucket.textOf('Name');
      if (name.isEmpty) continue;
      out.add(RemoteEntry(
        path: VPath.build(connectionId, '/$name'),
        name: name,
        isDirectory: true,
        size: 0,
        modified: _parseDate(bucket.textOf('CreationDate')),
        providerId: name,
      ));
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  @override
  Future<RemoteEntry?> stat(String vpath) async {
    final loc = _locate(vpath);
    if (loc.bucket == null) {
      return RemoteEntry(
        path: vpath,
        name: connectionId,
        isDirectory: true,
        size: 0,
        modified: _epoch,
      );
    }
    if (loc.key.isEmpty) {
      return RemoteEntry(
        path: vpath,
        name: loc.bucket!,
        isDirectory: true,
        size: 0,
        modified: _epoch,
      );
    }

    final head = await _call('HEAD', loc.bucket, loc.key);
    if (head.status == 200) {
      return RemoteEntry(
        path: vpath,
        name: VPath.basename(vpath),
        isDirectory: false,
        // HEAD gives no body to parse; the size comes back on the listing that
        // brought the user here, and callers that need it re-list.
        size: 0,
        modified: _epoch,
        providerId: loc.key,
      );
    }
    if (head.status != 404 && head.status != 403) {
      _fail(head.status, head.body, 'Couldn\'t read "${VPath.basename(vpath)}"');
    }

    // No object under that exact key — it may still be a folder prefix.
    final probe = await _call('GET', loc.bucket, '', query: {
      'list-type': '2',
      'max-keys': '1',
      'prefix': '${loc.key}/',
    });
    if (probe.status >= 300) return null;
    final xml = parseXml(probe.body);
    final hasChildren = (xml?.findAll('Contents').isNotEmpty ?? false) ||
        (xml?.findAll('CommonPrefixes').isNotEmpty ?? false);
    if (!hasChildren) return null;
    return RemoteEntry(
      path: vpath,
      name: VPath.basename(vpath),
      isDirectory: true,
      size: 0,
      modified: _epoch,
      providerId: '${loc.key}/',
    );
  }

  @override
  Future<RemoteDownload> download(String vpath) async {
    final loc = _locate(vpath);
    if (loc.bucket == null || loc.key.isEmpty) {
      throw RemoteException('"${VPath.basename(vpath)}" is a folder.');
    }
    final target = _request(loc.bucket, loc.key);
    final signed = _sign(
      method: 'GET',
      canonicalPath: target.canonicalPath,
      signHost: target.signHost,
      query: const {},
      extraHeaders: const {},
      payloadHash: _emptyBodySha256,
    );
    final response = await _http.send('GET', target.uri, headers: signed);
    if (response.statusCode >= 300) {
      final body = await RemoteHttp.readText(response);
      _fail(response.statusCode, body, 'Couldn\'t download "${VPath.basename(vpath)}"');
    }
    return RemoteDownload(
      stream: response,
      length: response.contentLength,
    );
  }

  @override
  Future<void> upload({
    required String vpath,
    required Stream<List<int>> data,
    required int length,
  }) async {
    final loc = _locate(vpath);
    if (loc.bucket == null || loc.key.isEmpty) {
      throw RemoteException('Pick a bucket to upload into.');
    }
    final target = _request(loc.bucket, loc.key);
    // UNSIGNED-PAYLOAD is S3's own answer to "the body is a stream I can't
    // hash up front"; the request itself is still signed, and TLS protects the
    // bytes. Hashing first would mean reading every file twice.
    final signed = _sign(
      method: 'PUT',
      canonicalPath: target.canonicalPath,
      signHost: target.signHost,
      query: const {},
      extraHeaders: const {},
      payloadHash: _unsignedPayload,
    );
    final response = await _http.send(
      'PUT',
      target.uri,
      headers: signed,
      body: data,
      contentLength: length,
    );
    if (response.statusCode >= 300) {
      final body = await RemoteHttp.readText(response);
      _fail(response.statusCode, body, 'Couldn\'t upload "${VPath.basename(vpath)}"');
    }
    await response.drain<void>();
  }

  @override
  Future<void> createDirectory(String vpath) async {
    final loc = _locate(vpath);
    if (loc.bucket == null) throw RemoteException('Nothing to create here.');
    if (loc.key.isEmpty) {
      // A top-level folder with no fixed bucket means a new bucket.
      final r = await _call('PUT', loc.bucket, '');
      if (r.status >= 300) {
        _fail(r.status, r.body, 'Couldn\'t create bucket "${loc.bucket}"');
      }
      return;
    }
    final r = await _call('PUT', loc.bucket, '${loc.key}/');
    if (r.status >= 300) _fail(r.status, r.body, 'Couldn\'t create this folder');
  }

  @override
  Future<void> delete(String vpath, {required bool isDirectory}) async {
    final loc = _locate(vpath);
    if (loc.bucket == null) throw RemoteException('Nothing to delete here.');
    if (!isDirectory) {
      final r = await _call('DELETE', loc.bucket, loc.key);
      if (r.status >= 300 && r.status != 404) {
        _fail(r.status, r.body, 'Couldn\'t delete "${VPath.basename(vpath)}"');
      }
      return;
    }
    for (final key in await _keysUnder(loc.bucket!, loc.key)) {
      final r = await _call('DELETE', loc.bucket, key);
      if (r.status >= 300 && r.status != 404) {
        _fail(r.status, r.body, 'Couldn\'t delete "$key"');
      }
    }
  }

  /// Every object key under a prefix, the folder marker included. Listed
  /// without a delimiter so one pass covers the whole subtree.
  Future<List<String>> _keysUnder(String bucket, String key) async =>
      [for (final o in await _objectsUnder(bucket, key)) o.key];

  Future<List<({String key, int size, DateTime modified})>> _objectsUnder(
    String bucket,
    String key,
  ) async {
    final prefix = key.isEmpty ? '' : '$key/';
    final out = <({String key, int size, DateTime modified})>[];
    String? token;
    do {
      final r = await _call('GET', bucket, '', query: {
        'list-type': '2',
        'encoding-type': 'url',
        'max-keys': '1000',
        if (prefix.isNotEmpty) 'prefix': prefix,
        if (token != null) 'continuation-token': token,
      });
      if (r.status >= 300) _fail(r.status, r.body, 'Couldn\'t read this folder');
      final xml = parseXml(r.body);
      for (final item in xml?.findAll('Contents') ?? const <XmlNode>[]) {
        final k = _decodeKey(item.textOf('Key'));
        if (k.isEmpty) continue;
        out.add((
          key: k,
          size: int.tryParse(item.textOf('Size')) ?? 0,
          modified: _parseDate(item.textOf('LastModified')),
        ));
      }
      token = xml?.textOf('IsTruncated') == 'true'
          ? _decodeKey(xml!.textOf('NextContinuationToken'))
          : null;
    } while (token != null && token.isNotEmpty);
    return out;
  }

  /// One un-delimited listing covers the whole subtree, so searching an S3
  /// prefix costs a page per thousand keys rather than a request per folder.
  @override
  Stream<RemoteEntry> search(
    String root,
    String query, {
    int maxResults = 500,
  }) async* {
    final loc = _locate(root);
    if (loc.bucket == null) {
      yield* super.search(root, query, maxResults: maxResults);
      return;
    }
    final needle = query.toLowerCase();
    if (needle.isEmpty) return;
    var found = 0;
    for (final object in await _objectsUnder(loc.bucket!, loc.key)) {
      if (object.key.endsWith('/')) continue;
      final name = object.key.substring(object.key.lastIndexOf('/') + 1);
      if (!name.toLowerCase().contains(needle)) continue;
      yield RemoteEntry(
        path: _vpathFor(loc.bucket, object.key),
        name: name,
        isDirectory: false,
        size: object.size,
        modified: object.modified,
      );
      if (++found >= maxResults) return;
    }
  }

  @override
  Future<String> rename(String vpath, String newName) async {
    final loc = _locate(vpath);
    if (loc.bucket == null || loc.key.isEmpty) {
      throw RemoteException('This item can\'t be renamed.');
    }
    final destination = VPath.join(VPath.dirname(vpath), newName);
    final destLoc = _locate(destination);
    final entry = await stat(vpath);
    if (entry == null) throw RemoteException('"${VPath.basename(vpath)}" is gone.');

    if (entry.isDirectory) {
      // S3 has no rename; a folder rename is every key under the prefix copied
      // to the new prefix and the old ones dropped.
      final keys = await _keysUnder(loc.bucket!, loc.key);
      for (final key in keys) {
        final suffix = key.substring(loc.key.length);
        await _copyKey(loc.bucket!, key, destLoc.bucket!, '${destLoc.key}$suffix');
      }
      for (final key in keys) {
        await _call('DELETE', loc.bucket, key);
      }
    } else {
      await _copyKey(loc.bucket!, loc.key, destLoc.bucket!, destLoc.key);
      await _call('DELETE', loc.bucket, loc.key);
    }
    return destination;
  }

  @override
  bool get supportsServerSideCopy => true;

  @override
  Future<void> copyWithin(String fromVPath, String toVPath) async {
    final from = _locate(fromVPath);
    final to = _locate(toVPath);
    if (from.bucket == null || to.bucket == null) {
      throw RemoteException('Pick a bucket to copy into.');
    }
    await _copyKey(from.bucket!, from.key, to.bucket!, to.key);
  }

  Future<void> _copyKey(
    String fromBucket,
    String fromKey,
    String toBucket,
    String toKey,
  ) async {
    final source = '/$fromBucket/${uriEncodePath(fromKey)}';
    final r = await _call(
      'PUT',
      toBucket,
      toKey,
      headers: {'x-amz-copy-source': source},
    );
    if (r.status >= 300) {
      _fail(r.status, r.body, 'Couldn\'t copy "$fromKey"');
    }
  }

  @override
  Future<String?> shareLink(
    String vpath, {
    Duration expiresIn = const Duration(hours: 1),
  }) async {
    final loc = _locate(vpath);
    if (loc.bucket == null || loc.key.isEmpty) return null;

    // A presigned GET: time-limited, and it grants nothing the key itself
    // doesn't already have. No bucket policy or ACL is touched.
    final now = _clock();
    final amzDate = _amzDate(now);
    final dateStamp = _datestamp(now);
    final scope = '$dateStamp/$region/s3/aws4_request';
    final target = _request(loc.bucket, loc.key);

    final query = <String, String>{
      'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
      'X-Amz-Credential': '$accessKeyId/$scope',
      'X-Amz-Date': amzDate,
      'X-Amz-Expires': '${expiresIn.inSeconds}',
      'X-Amz-SignedHeaders': 'host',
      if (sessionToken.isNotEmpty) 'X-Amz-Security-Token': sessionToken,
    };

    final canonicalRequest = [
      'GET',
      target.canonicalPath,
      _canonicalQuery(query),
      'host:${target.signHost}\n',
      'host',
      _unsignedPayload,
    ].join('\n');
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      _sha256Hex(utf8.encode(canonicalRequest)),
    ].join('\n');

    var key = _hmac(utf8.encode('AWS4$secretAccessKey'), dateStamp);
    key = _hmac(key, region);
    key = _hmac(key, 's3');
    key = _hmac(key, 'aws4_request');
    final signature =
        Hmac(sha256, key).convert(utf8.encode(stringToSign)).toString();

    final signedQuery =
        '${_canonicalQuery(query)}&X-Amz-Signature=$signature';
    return '${target.uri.scheme}://${target.signHost}'
        '${target.canonicalPath}?$signedQuery';
  }

  @override
  void close() => _http.close();

  // ── helpers ──────────────────────────────────────────────────────────────

  /// Listings are requested with `encoding-type=url`, which is the only way a
  /// key containing a newline or a control character survives the XML round
  /// trip intact.
  static String _decodeKey(String raw) {
    if (raw.isEmpty || !raw.contains('%')) return raw;
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  static DateTime _parseDate(String raw) =>
      DateTime.tryParse(raw)?.toLocal() ?? _epoch;

  static int _byKindThenName(RemoteEntry a, RemoteEntry b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}
