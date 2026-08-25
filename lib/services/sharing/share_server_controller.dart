import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/platform.dart';
import '../native_core.dart';

/// One folder published to the network.
@immutable
class SharedFolder {
  const SharedFolder({
    required this.name,
    required this.path,
    this.readOnly = true,
    this.allowedUsers = const [],
    this.guestOk = false,
  });

  /// What clients see — the `Files` in `\\host\Files`.
  final String name;
  final String path;

  /// Read-only is the default deliberately: publishing a folder is a decision,
  /// and letting strangers write to it is a second one.
  final bool readOnly;

  /// Accounts that may attach to this share. Empty means every account that
  /// can sign in, which is what a one-person setup wants and what this did
  /// before per-share access existed.
  final List<String> allowedUsers;

  /// Whether someone with no account may attach. Off unless asked for: a guest
  /// share is readable by anyone who can reach the port. A guest never writes,
  /// whatever [readOnly] says.
  final bool guestOk;

  /// Whether the share is limited to named accounts rather than open to all.
  bool get isRestricted => allowedUsers.isNotEmpty;

  SharedFolder copyWith({
    String? name,
    String? path,
    bool? readOnly,
    List<String>? allowedUsers,
    bool? guestOk,
  }) =>
      SharedFolder(
        name: name ?? this.name,
        path: path ?? this.path,
        readOnly: readOnly ?? this.readOnly,
        allowedUsers: allowedUsers ?? this.allowedUsers,
        guestOk: guestOk ?? this.guestOk,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'readOnly': readOnly,
        'allowedUsers': allowedUsers,
        'guestOk': guestOk,
      };

  factory SharedFolder.fromJson(Map<String, dynamic> json) => SharedFolder(
        name: '${json['name'] ?? ''}',
        path: '${json['path'] ?? ''}',
        readOnly: json['readOnly'] != false,
        allowedUsers: [
          for (final u in (json['allowedUsers'] as List? ?? const []))
            '$u'.trim(),
        ]..removeWhere((u) => u.isEmpty),
        guestOk: json['guestOk'] == true,
      );

  /// A share name derived from a folder, with the characters SMB can't carry
  /// in one removed.
  static String suggestName(String path) {
    final base = p.basename(path.replaceAll(RegExp(r'[\\/]+$'), ''));
    final cleaned = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    return cleaned.isEmpty ? 'Shared' : cleaned;
  }
}

/// One account allowed to connect.
///
/// The password never lives here — it is in the OS keychain, keyed by user
/// name, and is read once when the server starts.
@immutable
class ShareUser {
  const ShareUser({required this.name, this.generated = false});

  final String name;

  /// True while the password is the one Notilus invented for the machine's own
  /// login account. Nobody has seen it yet, so the panel may still show it —
  /// once someone sets their own, it goes back to being theirs alone.
  final bool generated;

  Map<String, dynamic> toJson() =>
      {'name': name, if (generated) 'generated': true};

  factory ShareUser.fromJson(Map<String, dynamic> json) => ShareUser(
        name: '${json['name'] ?? ''}',
        generated: json['generated'] == true,
      );
}

/// Something the server did, kept for the activity list.
@immutable
class ShareActivity {
  const ShareActivity({
    required this.at,
    required this.icon,
    required this.title,
    this.detail = '',
    this.isError = false,
  });

  final DateTime at;

  /// A short tag the UI maps to a glyph: `up`, `down`, `in`, `out`, `deny`,
  /// `info`. Kept as a string so this file has no widget imports.
  final String icon;
  final String title;
  final String detail;
  final bool isError;
}

/// Owns the SMB server: its configuration, its lifecycle, and what it reports.
///
/// A [ChangeNotifier] rather than a plain service because three separate parts
/// of the UI care — the sharing screen, the sidebar badge, and the status bar —
/// and all of them want the same live view of one process-wide server.
class ShareServerController extends ChangeNotifier {
  ShareServerController._();

  static final ShareServerController instance = ShareServerController._();

  static const _prefsKey = 'smb_share_config';
  static const _secure = FlutterSecureStorage(
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  /// How many activity lines to keep. Enough to see what a transfer did,
  /// bounded so a machine left sharing overnight doesn't grow without limit.
  static const int _maxActivity = 300;

  /// Ports below 1024 need administrator rights on every desktop OS. 445 is
  /// where other machines look for a share, so it is offered — with a warning —
  /// and this is the fallback that works without any.
  static const int defaultPort = 4455;

  List<SharedFolder> _folders = const [];
  List<ShareUser> _users = const [];
  int _port = defaultPort;
  String _serverName = 'NOTILUS';
  String _workgroup = 'WORKGROUP';
  bool _localOnly = false;
  bool _requireSigning = true;
  bool _loaded = false;

  /// Whether the machine's own login account has already been offered once.
  /// Kept so deleting it is a decision that sticks rather than something the
  /// next launch quietly undoes.
  bool _machineUserSeeded = false;

  bool _running = false;
  int _activePort = 0;
  int _connections = 0;
  String? _error;
  bool _starting = false;

  final List<ShareActivity> _activity = [];
  StreamSubscription<SmbServerEvent>? _events;

  /// Peers currently connected, by the server's connection id, so a
  /// disconnect can name who left.
  final Map<int, String> _peers = {};

  List<SharedFolder> get folders => List.unmodifiable(_folders);
  List<ShareUser> get users => List.unmodifiable(_users);
  List<ShareActivity> get activity => List.unmodifiable(_activity);
  int get port => _port;
  String get serverName => _serverName;
  String get workgroup => _workgroup;
  bool get localOnly => _localOnly;
  bool get requireSigning => _requireSigning;
  bool get loaded => _loaded;
  bool get running => _running;
  bool get starting => _starting;
  int get activePort => _activePort;
  int get connections => _connections;
  String? get error => _error;

  /// Whether [start] has everything it needs.
  bool get isConfigured => _folders.isNotEmpty && _users.isNotEmpty;

  // ── persistence ──────────────────────────────────────────────────────────

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        _folders = [
          for (final item in (json['folders'] as List? ?? const []))
            SharedFolder.fromJson(item as Map<String, dynamic>),
        ];
        _users = [
          for (final item in (json['users'] as List? ?? const []))
            ShareUser.fromJson(item as Map<String, dynamic>),
        ];
        _port = (json['port'] as num?)?.toInt() ?? defaultPort;
        _serverName = '${json['serverName'] ?? 'NOTILUS'}';
        _workgroup = '${json['workgroup'] ?? 'WORKGROUP'}';
        _localOnly = json['localOnly'] == true;
        _requireSigning = json['requireSigning'] != false;
        _machineUserSeeded = json['machineUserSeeded'] == true;
      }
    } catch (_) {
      // A corrupt entry shouldn't cost the user their file manager. Sharing
      // starts from nothing, which is the safe default anyway.
      _folders = const [];
      _users = const [];
    }
    await _seedMachineUser();
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        'folders': [for (final f in _folders) f.toJson()],
        'users': [for (final u in _users) u.toJson()],
        'port': _port,
        'serverName': _serverName,
        'workgroup': _workgroup,
        'localOnly': _localOnly,
        'requireSigning': _requireSigning,
        'machineUserSeeded': _machineUserSeeded,
      }),
    );
  }

  // ── configuration ────────────────────────────────────────────────────────

  /// Publishes [path]. Returns the error to show, or null on success.
  ///
  /// Changes to the folder list take effect on the next start; a running
  /// server keeps serving what it was started with, which is what stops a
  /// half-edited configuration from being live.
  Future<String?> addFolder(String path, {String? name, bool readOnly = true}) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      return '$path isn\'t a folder.';
    }
    if (_folders.any((f) => p.equals(f.path, path))) {
      return 'That folder is already shared.';
    }
    final chosen = _uniqueName(name ?? SharedFolder.suggestName(path));
    _folders = [
      ..._folders,
      SharedFolder(name: chosen, path: path, readOnly: readOnly),
    ];
    await _persist();
    notifyListeners();
    return null;
  }

  Future<String?> updateFolder(int index, SharedFolder folder) async {
    if (index < 0 || index >= _folders.length) return null;
    final name = folder.name.trim();
    if (name.isEmpty) return 'A share needs a name.';
    if (name.contains(RegExp(r'[\\/:*?"<>|]'))) {
      return 'A share name can\'t contain \\ / : * ? " < > or |.';
    }
    final clash = _folders.indexWhere(
      (f) => f.name.toLowerCase() == name.toLowerCase(),
    );
    if (clash >= 0 && clash != index) {
      return 'Another share is already called "$name".';
    }
    _folders = [
      for (var i = 0; i < _folders.length; i++)
        if (i == index) folder.copyWith(name: name) else _folders[i],
    ];
    await _persist();
    notifyListeners();
    return null;
  }

  Future<void> removeFolder(int index) async {
    if (index < 0 || index >= _folders.length) return;
    _folders = [
      for (var i = 0; i < _folders.length; i++)
        if (i != index) _folders[i],
    ];
    await _persist();
    notifyListeners();
  }

  String _uniqueName(String wanted) {
    final base = wanted.trim().isEmpty ? 'Shared' : wanted.trim();
    if (!_folders.any((f) => f.name.toLowerCase() == base.toLowerCase())) {
      return base;
    }
    for (var n = 2; n < 100; n++) {
      final candidate = '$base $n';
      if (!_folders.any((f) => f.name.toLowerCase() == candidate.toLowerCase())) {
        return candidate;
      }
    }
    return base;
  }

  // ── the machine's own account ────────────────────────────────────────────

  /// The name of the account someone signed in to this computer uses.
  ///
  /// This is the name a person on the other machine will try first — it is
  /// what the folder they are reaching for is called on this one — so it is
  /// the name the seeded account carries.
  static String get machineUserName {
    const keys = ['USER', 'LOGNAME', 'USERNAME'];
    for (final key in keys) {
      final value = Platform.environment[key]?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return 'notilus';
  }

  /// Creates the machine's own account the first time sharing is opened.
  ///
  /// A share with no account is unreachable, and the alternative — letting the
  /// first connection in unauthenticated — would publish the folder to anyone
  /// who can reach the port. So an account exists from the start, named after
  /// whoever is signed in here, with a password nobody has to invent. It is
  /// seeded once: removing it is a decision, not something to undo on the next
  /// launch.
  ///
  /// The account is only a *login*. It carries no privileges from the OS user
  /// it is named after — what it can reach is the shared folders and nothing
  /// else on the machine.
  Future<void> _seedMachineUser() async {
    if (_machineUserSeeded || !canHostShares) return;
    if (_users.isNotEmpty) {
      // An older configuration that already names its accounts. Nothing to
      // add, but the offer counts as made — deleting them later shouldn't
      // bring a machine account back in their place.
      _machineUserSeeded = true;
      await _persist();
      return;
    }
    final name = machineUserName;
    final password = _inventPassword();
    try {
      await _secure.write(key: _secretKey(name), value: password);
    } catch (_) {
      // No keychain, no account — [start] says so plainly if it comes to that.
      return;
    }
    _users = [ShareUser(name: name, generated: true)];
    _machineUserSeeded = true;
    await _persist();
  }

  /// A password worth typing on another machine: no look-alike characters, and
  /// grouped so it can be read off a screen without losing your place.
  static String _inventPassword() {
    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    final random = Random.secure();
    final groups = [
      for (var g = 0; g < 4; g++)
        [
          for (var i = 0; i < 4; i++)
            alphabet[random.nextInt(alphabet.length)],
        ].join(),
    ];
    return groups.join('-');
  }

  @visibleForTesting
  static String debugInventPassword() => _inventPassword();

  /// The password held for [name], or null when the keychain has none.
  ///
  /// Only worth showing for an account whose password Notilus invented — see
  /// [ShareUser.generated]. A password the user chose is theirs to remember.
  Future<String?> passwordFor(String name) async {
    try {
      final value = await _secure.read(key: _secretKey(name));
      return (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// Adds or replaces a user. The password goes straight to the keychain.
  Future<String?> setUser(String name, String password) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'A user needs a name.';
    if (password.isEmpty) return 'A user needs a password.';
    try {
      await _secure.write(key: _secretKey(trimmed), value: password);
    } catch (e) {
      return 'Couldn\'t save the password securely: $e';
    }
    final existing =
        _users.indexWhere((u) => u.name.toLowerCase() == trimmed.toLowerCase());
    _users = existing >= 0
        ? [
            for (var i = 0; i < _users.length; i++)
              if (i == existing) ShareUser(name: trimmed) else _users[i],
          ]
        : [..._users, ShareUser(name: trimmed)];
    await _persist();
    notifyListeners();
    return null;
  }

  Future<void> removeUser(String name) async {
    _users = [
      for (final u in _users)
        if (u.name.toLowerCase() != name.toLowerCase()) u,
    ];
    // The name is left on any share that listed it deliberately. Quietly
    // dropping it would turn "only Alice" into "every account" the moment
    // Alice is deleted; instead [start] refuses until the user says who the
    // share is for. Stale names are ignored while the server runs.
    try {
      await _secure.delete(key: _secretKey(name));
    } catch (_) {
      // The account is gone from the list either way.
    }
    await _persist();
    notifyListeners();
  }

  /// The share's allow list narrowed to accounts that still exist.
  List<String> _allowedThatExist(SharedFolder folder) => [
        for (final wanted in folder.allowedUsers)
          for (final user in _users)
            if (user.name.toLowerCase() == wanted.toLowerCase()) user.name,
      ];

  static String _secretKey(String user) => 'smb_share_user_${user.toLowerCase()}';

  Future<void> setNetwork({
    int? port,
    String? serverName,
    String? workgroup,
    bool? localOnly,
    bool? requireSigning,
  }) async {
    _port = port?.clamp(0, 65535) ?? _port;
    _serverName = serverName?.trim().toUpperCase() ?? _serverName;
    _workgroup = workgroup?.trim().toUpperCase() ?? _workgroup;
    _localOnly = localOnly ?? _localOnly;
    _requireSigning = requireSigning ?? _requireSigning;
    if (_serverName.isEmpty) _serverName = 'NOTILUS';
    if (_workgroup.isEmpty) _workgroup = 'WORKGROUP';
    await _persist();
    notifyListeners();
  }

  // ── lifecycle ────────────────────────────────────────────────────────────

  /// Starts the server. Returns the error to show, or null on success.
  Future<String?> start() async {
    if (_running || _starting) return null;
    if (_folders.isEmpty) return 'Add a folder to share first.';
    if (_users.isEmpty) return 'Add a user before starting.';

    for (final folder in _folders) {
      if (!await Directory(folder.path).exists()) {
        return '"${folder.name}" points at ${folder.path}, which is gone.';
      }
      // A share limited to accounts that no longer exist would be reachable by
      // nobody, and the empty list Rust reads as "everyone" would silently
      // widen it instead — so say so rather than guess.
      if (folder.isRestricted && _allowedThatExist(folder).isEmpty) {
        return '"${folder.name}" is limited to accounts that no longer exist. '
            'Choose who can use it.';
      }
    }

    final users = <SmbUserConfig>[];
    for (final user in _users) {
      String? password;
      try {
        password = await _secure.read(key: _secretKey(user.name));
      } catch (_) {
        password = null;
      }
      if (password == null || password.isEmpty) {
        return 'The password for "${user.name}" couldn\'t be read from the '
            'keychain. Set it again.';
      }
      users.add(SmbUserConfig(username: user.name, password: password));
    }

    _starting = true;
    _error = null;
    notifyListeners();

    try {
      await NativeCore.ensureInitialized();
      final settings = SmbServerSettings(
        bind: _localOnly ? '127.0.0.1' : '0.0.0.0',
        port: _port,
        serverName: _serverName,
        workgroup: _workgroup,
        shares: [
          for (final folder in _folders)
            SmbShareConfig(
              name: folder.name,
              path: folder.path,
              readOnly: folder.readOnly,
              comment: '',
              allowedUsers: _allowedThatExist(folder),
              guestOk: folder.guestOk,
            ),
        ],
        users: users,
        requireSigning: _requireSigning,
        maxConnections: 32,
      );

      // Listening is what keeps the Rust event sink — and with it the server —
      // alive, so the subscription is held for the server's whole lifetime.
      final completer = Completer<String?>();
      _events = NativeCore.instance.startSharing(settings).listen(
        (event) {
          if (event is SmbServerEvent_Started && !completer.isCompleted) {
            completer.complete(null);
          }
          _onEvent(event);
        },
        onError: (Object e) {
          final message = _readable(e);
          if (!completer.isCompleted) {
            completer.complete(message);
          } else {
            _error = message;
            _running = false;
            _starting = false;
            _note('deny', 'The server stopped', detail: message, isError: true);
            notifyListeners();
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete('The server stopped before it started.');
          }
          _running = false;
          _connections = 0;
          notifyListeners();
        },
      );

      final failure = await completer.future;
      _starting = false;
      if (failure != null) {
        await _events?.cancel();
        _events = null;
        _error = failure;
        notifyListeners();
        return failure;
      }
      _running = true;
      _error = null;
      notifyListeners();
      return null;
    } catch (e) {
      _starting = false;
      _error = _readable(e);
      notifyListeners();
      return _error;
    }
  }

  Future<void> stop() async {
    await NativeCore.instance.stopSharing().catchError((_) => false);
    await _events?.cancel();
    _events = null;
    _running = false;
    _connections = 0;
    _peers.clear();
    _note('info', 'Sharing stopped');
    notifyListeners();
  }

  Future<String?> restart() async {
    if (_running) await stop();
    return start();
  }

  void clearActivity() {
    _activity.clear();
    notifyListeners();
  }

  void _onEvent(SmbServerEvent event) {
    switch (event) {
      case SmbServerEvent_Started(:final field0):
        _activePort = field0;
        _running = true;
        _note('info', 'Sharing started on port $field0');
      case SmbServerEvent_Stopped():
        _running = false;
        _connections = 0;
        _peers.clear();
      case SmbServerEvent_Connected(:final field0):
        _connections++;
        _peers[field0.connection.toInt()] = field0.peer;
        _note('in', 'A device connected', detail: field0.peer);
      case SmbServerEvent_Authenticated(:final field0):
        _note(
          'in',
          '${field0.user} signed in',
          detail: '${field0.peer} · ${field0.detail}',
        );
      case SmbServerEvent_Rejected(:final field0):
        _note(
          'deny',
          'Sign-in refused',
          detail: '${field0.peer} · ${field0.detail}',
          isError: true,
        );
      case SmbServerEvent_Disconnected(:final field0):
        if (_connections > 0) _connections--;
        final peer = _peers.remove(field0.connection.toInt()) ?? field0.peer;
        _note('out', 'A device disconnected', detail: peer);
      case SmbServerEvent_Transfer(:final field0):
        _note(
          field0.outbound ? 'down' : 'up',
          '${field0.outbound ? 'Sent' : 'Received'} ${field0.path.isEmpty ? field0.share : field0.path}',
          detail: '${_bytes(field0.bytes.toInt())} · ${field0.share}',
        );
    }
    notifyListeners();
  }

  void _note(
    String icon,
    String title, {
    String detail = '',
    bool isError = false,
  }) {
    _activity.insert(
      0,
      ShareActivity(
        at: DateTime.now(),
        icon: icon,
        title: title,
        detail: detail,
        isError: isError,
      ),
    );
    if (_activity.length > _maxActivity) {
      _activity.removeRange(_maxActivity, _activity.length);
    }
  }

  static String _readable(Object error) =>
      '$error'.replaceFirst(RegExp(r'^\w*Exception:\s*'), '');

  static String _bytes(int value) {
    if (value < 1024) return '$value B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var size = value / 1024;
    var index = 0;
    while (size >= 1024 && index < units.length - 1) {
      size /= 1024;
      index++;
    }
    return '${size.toStringAsFixed(size >= 10 ? 0 : 1)} ${units[index]}';
  }

  /// The addresses to hand someone who wants to connect.
  ///
  /// Loopback and link-local are filtered out: neither is reachable from the
  /// other machine, and offering one produces a connection attempt that fails
  /// for a reason the user can't see.
  Future<List<String>> localAddresses() async {
    if (_localOnly) return const ['127.0.0.1'];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      final out = <String>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.address.startsWith('169.254.')) continue;
          out.add(address.address);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }
}
