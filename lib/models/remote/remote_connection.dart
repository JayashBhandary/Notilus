import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:flutter/widgets.dart' show IconData;

/// The kinds of remote storage Notilus can mount.
///
/// S3 covers far more than AWS — the same signature and API serve MinIO,
/// Cloudflare R2, Backblaze B2, Wasabi and DigitalOcean Spaces — so a single
/// implementation with a configurable endpoint buys most of the object-store
/// world. WebDAV does the same job for Nextcloud / ownCloud / Box, and SMB for
/// Windows machines, NAS boxes, Samba servers and Notilus's own sharing.
enum RemoteKind {
  s3('s3', 'Amazon S3 (or compatible)'),
  gdrive('gdrive', 'Google Drive'),
  sftp('sftp', 'SSH / SFTP server'),
  smb('smb', 'Windows share (SMB)'),
  webdav('webdav', 'WebDAV');

  const RemoteKind(this.id, this.label);

  final String id;
  final String label;

  static RemoteKind fromId(String id) => RemoteKind.values.firstWhere(
        (k) => k.id == id,
        orElse: () => RemoteKind.s3,
      );

  IconData get icon {
    switch (this) {
      case RemoteKind.s3:
        return LucideIcons.cloud;
      case RemoteKind.gdrive:
        return LucideIcons.hardDriveUpload;
      case RemoteKind.sftp:
        return LucideIcons.server;
      case RemoteKind.smb:
        return LucideIcons.network;
      case RemoteKind.webdav:
        return LucideIcons.globe;
    }
  }

  /// Whether this provider can copy inside itself without moving the bytes
  /// through the app.
  bool get hasServerSideCopy => true;
}

/// A configured remote source.
///
/// Only non-secret configuration lives here — it is persisted in
/// shared_preferences. Access keys, passwords and OAuth refresh tokens go to
/// the OS keychain through `RemoteRegistry`, the same rule the LLM API keys
/// already follow.
class RemoteConnection {
  const RemoteConnection({
    required this.id,
    required this.kind,
    required this.label,
    this.config = const {},
  });

  final String id;
  final RemoteKind kind;
  final String label;
  final Map<String, String> config;

  String get(String key, [String fallback = '']) => config[key] ?? fallback;

  bool getFlag(String key, {bool fallback = false}) {
    final raw = config[key];
    if (raw == null) return fallback;
    return raw == 'true' || raw == '1';
  }

  RemoteConnection copyWith({
    String? label,
    Map<String, String>? config,
  }) =>
      RemoteConnection(
        id: id,
        kind: kind,
        label: label ?? this.label,
        config: config ?? this.config,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.id,
        'label': label,
        'config': config,
      };

  factory RemoteConnection.fromJson(Map<String, dynamic> json) =>
      RemoteConnection(
        id: json['id'] as String,
        kind: RemoteKind.fromId(json['kind'] as String? ?? 's3'),
        label: json['label'] as String? ?? 'Remote',
        config: {
          for (final e in ((json['config'] as Map?) ?? const {}).entries)
            '${e.key}': '${e.value}',
        },
      );
}

/// Config keys, spelled once so the dialog, the registry and the providers
/// can't drift apart.
class RemoteKeys {
  const RemoteKeys._();

  // S3
  static const region = 'region';
  static const endpoint = 'endpoint';
  static const bucket = 'bucket';
  static const pathStyle = 'pathStyle';
  static const accessKeyId = 'accessKeyId';
  static const secretAccessKey = 'secretAccessKey';
  static const sessionToken = 'sessionToken';

  // Google Drive
  static const clientId = 'clientId';
  static const clientSecret = 'clientSecret';
  static const refreshToken = 'refreshToken';

  // WebDAV
  static const baseUrl = 'baseUrl';
  static const username = 'username';
  static const password = 'password';

  // SSH / SFTP. `username` and `password` are shared with WebDAV.
  static const host = 'host';
  static const port = 'port';
  static const privateKeyPath = 'privateKeyPath';
  static const passphrase = 'passphrase';

  // SMB. `host`, `port`, `username` and `password` are shared with the above.
  /// The share to attach to — the `Files` in `\\server\Files`.
  static const shareName = 'shareName';
  /// NT domain or workgroup. Empty lets the server name one.
  static const workgroup = 'workgroup';

  /// Directory the virtual root maps to. Empty means the login home.
  static const basePath = 'basePath';

  /// Pinned host key fingerprint, learned on the first connection.
  static const hostKey = 'hostKey';
}

/// Live state of a connection, for the sidebar dot and error reporting.
enum RemoteStatus { idle, connecting, ready, error }
