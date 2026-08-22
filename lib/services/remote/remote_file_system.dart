import 'dart:async';

import '../../models/file_entry.dart';
import 'remote_path.dart';

/// Raised by a provider when the remote says no. The message is written to be
/// shown to a user as-is: the UI has nowhere better to send them.
class RemoteException implements Exception {
  RemoteException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  /// True when the failure is almost certainly the stored credentials rather
  /// than the request — the sidebar marks the connection as needing attention.
  bool get isAuthFailure => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}

/// One item in a remote listing, in the app's own vocabulary.
class RemoteEntry {
  const RemoteEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.modified,
    this.providerId,
    this.mimeType,
    this.webLink,
  });

  /// Full virtual path (`notilus://<conn>/…`).
  final String path;
  final String name;
  final bool isDirectory;
  final int size;
  final DateTime modified;

  /// The provider's own handle for the item — a Drive file id, an S3 key.
  /// Carried so a second lookup isn't needed to act on it.
  final String? providerId;
  final String? mimeType;

  /// A browser-openable URL for the item, when the provider has one.
  final String? webLink;

  FileEntry toFileEntry() => FileEntry(
        path: path,
        name: name,
        isDirectory: isDirectory,
        size: size,
        modified: modified,
      );
}

/// Bytes plus the length the caller should expect, so a download can drive a
/// determinate progress bar. [length] is -1 when the server won't say.
class RemoteDownload {
  const RemoteDownload({required this.stream, required this.length, this.name});

  final Stream<List<int>> stream;
  final int length;

  /// The name the file should get locally. Providers that transcode on the way
  /// out (Google Docs exported as PDF) set this; everyone else leaves it null.
  final String? name;
}

/// What every remote provider has to be able to do for the browser to treat it
/// like a folder tree.
///
/// Paths in and out are always full virtual paths, so a caller never has to
/// know how a provider addresses things internally (S3 keys, Drive file ids).
abstract class RemoteFileSystem {
  RemoteFileSystem(this.connectionId);

  final String connectionId;

  /// Verifies the credentials and warms anything the provider caches. Called
  /// before the first listing, and again by the "Test" button.
  Future<void> connect();

  Future<List<RemoteEntry>> list(String vpath);

  Future<RemoteEntry?> stat(String vpath);

  Future<RemoteDownload> download(String vpath);

  /// Writes [length] bytes from [data] to [vpath], creating or replacing it.
  Future<void> upload({
    required String vpath,
    required Stream<List<int>> data,
    required int length,
  });

  Future<void> createDirectory(String vpath);

  /// Removes an item. Providers with a trash use it — deleting from a cloud
  /// drive through a file manager should be as recoverable as it is in the
  /// provider's own web UI.
  Future<void> delete(String vpath, {required bool isDirectory});

  Future<String> rename(String vpath, String newName);

  /// Whether [copyWithin] can move bytes without pulling them through the app.
  bool get supportsServerSideCopy => false;

  /// Copies inside this connection. Only called when
  /// [supportsServerSideCopy] is true, and only for files.
  Future<void> copyWithin(String fromVPath, String toVPath) async {
    throw RemoteException('This source cannot copy files server-side.');
  }

  /// A shareable URL for [vpath], or null when the provider has none.
  ///
  /// Implementations must not *change* who can see the item — an S3 presigned
  /// URL expires on its own and a Drive link only works for people who already
  /// have access. Granting access is a decision for the provider's own UI.
  Future<String?> shareLink(String vpath) async => null;

  /// True if the path exists — used for collision-free naming.
  Future<bool> exists(String vpath) async => (await stat(vpath)) != null;

  void close() {}

  /// Depth-first walk of everything under [vpath], directories before their
  /// contents, so a copy can create a folder before filling it.
  Stream<RemoteEntry> walk(String vpath) async* {
    final queue = <String>[vpath];
    while (queue.isNotEmpty) {
      final dir = queue.removeAt(0);
      final entries = await list(dir);
      for (final e in entries) {
        yield e;
        if (e.isDirectory) queue.add(e.path);
      }
    }
  }

  /// Name search under [root].
  ///
  /// The default walks listings, which is correct everywhere and cheap for a
  /// provider whose listings are cheap; a provider that can ask its server the
  /// question directly overrides this. Content search is deliberately absent —
  /// grepping a cloud folder means downloading it.
  Stream<RemoteEntry> search(
    String root,
    String query, {
    int maxResults = 500,
  }) async* {
    final needle = query.toLowerCase();
    if (needle.isEmpty) return;
    var found = 0;
    await for (final entry in walk(root)) {
      if (!entry.name.toLowerCase().contains(needle)) continue;
      yield entry;
      if (++found >= maxResults) return;
    }
  }

  /// Appends " (2)", " (3)"… until nothing is in the way. Mirrors what the
  /// Rust core does for local collisions so a copy behaves the same in both
  /// directions.
  Future<String> uniquePath(String vpath) async {
    if (!await exists(vpath)) return vpath;
    final dir = VPath.dirname(vpath);
    final name = VPath.basename(vpath);
    final dot = name.lastIndexOf('.');
    final stem = dot <= 0 ? name : name.substring(0, dot);
    final ext = dot <= 0 ? '' : name.substring(dot);
    for (var n = 2; n < 1000; n++) {
      final candidate = VPath.join(dir, '$stem ($n)$ext');
      if (!await exists(candidate)) return candidate;
    }
    throw RemoteException('Couldn\'t find a free name for "$name".');
  }
}
