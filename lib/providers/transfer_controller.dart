import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../config/transfer_config.dart';
import '../utils/device_code.dart';
import '../models/transfer/contact.dart';
import '../models/transfer/inbox_message.dart';
import '../models/transfer/transfer_request.dart';
import '../services/transfer/contacts_store.dart';
import '../services/transfer/file_transfer.dart';
import '../services/transfer/firebase_auth_client.dart';
import '../services/transfer/identity_service.dart';
import '../services/transfer/prefs_kv_store.dart';
import '../services/transfer/rtc_conduit.dart';
import '../services/settings_store.dart';
import '../services/transfer/local_discovery.dart';
import '../services/transfer/local_transfer_server.dart';
import '../services/transfer/rtdb_client.dart';
import '../services/transfer/signaling_service.dart';
import '../services/transfer/socket_conduit.dart';
import '../services/transfer/signed_messages.dart';
import '../services/transfer/webrtc_session.dart';

/// Outcome of a LAN-direct send attempt. `unreachable` means "couldn't connect —
/// try Firebase instead"; the others are final answers from the peer.
enum _LanOutcome { accepted, declined, unreachable }

/// App-facing facade over the transfer stack (identity + contacts + signaling).
/// Self-initializes: signs in, connects the inbox stream, and polls presence
/// for saved contacts. UI watches this via Provider.
class TransferController extends ChangeNotifier {
  TransferController() {
    _init();
  }

  static const _presenceEvery = Duration(seconds: 25);

  bool _ready = false;
  String? _error; // 'not-configured' or an error message

  IdentityService? _identity;
  ContactsStore? _contacts;
  SignalingService? _signaling;

  final Map<String, bool> _online = {};
  Timer? _presenceTimer;
  StreamSubscription<InboxMessage>? _msgSub;

  static const _uuid = Uuid();
  static const requestTimeout = Duration(seconds: 60);

  // Robustness bounds (Phase 7). An inbox is writable by any authenticated
  // Firebase user, so a verified contact — or a spammer whose junk we drop —
  // must not be able to flood or OOM us.
  static const maxFilesPerRequest = 1000;
  static const maxBytesPerRequest = 50 * 1024 * 1024 * 1024; // 50 GB advertised
  static const maxQueuedRequests = 20;

  // requestIds we've already surfaced, to drop replays. Bounded FIFO.
  static const _maxSeenRequests = 256;
  final Set<String> _seenRequests = {};
  final List<String> _seenOrder = [];

  // Outstanding outgoing requests: requestId → completes true(accept)/false.
  final Map<String, Completer<bool>> _pending = {};
  // Verified incoming requests awaiting the user's decision (FIFO).
  final List<IncomingTransferRequest> _incoming = [];
  // Active WebRTC sessions keyed by requestId (== sessionId).
  final Map<String, WebRtcSession> _sessions = {};

  // Files queued to send, keyed by requestId; consumed when the offerer
  // connects. Receive manifests (name/size from the accepted request) are kept
  // so overall progress has a correct total before headers arrive.
  final Map<String, List<OutgoingFile>> _outgoing = {};
  final Map<String, List<({String name, int size})>> _pendingReceive = {};
  final Map<String, FileSender> _senders = {};
  final Map<String, FileReceiver> _receivers = {};
  // Live + recently-finished transfers, keyed by sessionId, for the UI.
  final Map<String, BatchProgress> _transfers = {};

  // LAN-direct path (no Firebase). Discovery + a TCP server; per-request conduits
  // track incoming LAN requests awaiting a decision and active LAN transfers.
  LocalDiscovery? _discovery;
  LocalTransferServer? _localServer;
  final Map<String, SocketConduit> _localPendingConduits = {}; // reqId → awaiting accept
  final Map<String, SocketConduit> _localActiveConduits = {}; // reqId → transferring

  // ── Public surface ────────────────────────────────────────────────────
  bool get isConfigured => TransferConfig.isConfigured;
  bool get ready => _ready;
  String? get error => _error;

  String get myName => _identity?.displayName ?? '';
  String? get myDeviceId => _identity?.deviceId;

  /// This machine's short code (`a2:b1:c4:ff:07`) — the friendly identity shown
  /// in the UI, used for LAN discovery, and available offline.
  String? get myCode => _identity?.myCode;

  /// The full share payload (name + code anchor + online address) for QR/paste.
  String? get myShareCode => _identity?.asShareableContact().toShareCode();

  /// True once online signaling is up; false while offline / before sign-in.
  bool get onlineAvailable => _signaling != null;

  List<Contact> get contacts => _contacts?.contacts ?? const [];

  /// Whether a saved peer (keyed by machine [code]) is currently online.
  bool isOnline(String code) => _online[code] ?? false;

  /// The next incoming request awaiting a decision, if any (UI shows a dialog).
  IncomingTransferRequest? get incomingRequest =>
      _incoming.isNotEmpty ? _incoming.first : null;

  /// Live + recently-finished transfers keyed by session id, for the activity
  /// UI (the key is what [cancelTransfer] takes).
  Map<String, BatchProgress> get transfers => Map.unmodifiable(_transfers);

  /// Exposed for later phases (WebRTC signaling).
  SignalingService? get signaling => _signaling;

  Future<void> _init() async {
    if (!isConfigured) {
      _error = 'not-configured';
      notifyListeners();
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final store = PrefsKvStore(prefs);

      _identity = IdentityService(store);
      await _identity!.init();

      _contacts = ContactsStore(store)..addListener(notifyListeners);

      // LAN-direct path comes up first and independently of Firebase, so
      // transfers work on a local network with no internet at all. Best effort —
      // if it can't bind, we simply lean on the Firebase path. Our machine code
      // is derived from the keypair, so discovery is ready without sign-in.
      try {
        _localServer = LocalTransferServer(_onLocalSocket);
        await _localServer!.start();
        _discovery = LocalDiscovery(_identity!)..tcpPort = _localServer!.port;
        await _discovery!.start();
      } catch (e) {
        debugPrint('LAN transfer path unavailable: $e');
      }

      // The feature is usable now (identity + LAN ready) even if we never reach
      // Firebase. Online signaling is layered on best-effort below.
      _ready = true;
      notifyListeners();

      unawaited(_startSignaling(store));
    } catch (e) {
      _error = 'Couldn\'t connect: $e';
      notifyListeners();
    }
  }

  /// Brings up online signaling (Firebase sign-in + inbox + presence). Failure
  /// is non-fatal: with no internet, LAN transfers keep working and the online
  /// path just stays unavailable until the next launch reconnects.
  Future<void> _startSignaling(PrefsKvStore store) async {
    try {
      final auth = FirebaseAuthClient(store);
      final sig = SignalingService(
        auth: auth,
        rtdb: RtdbClient(auth),
        identity: _identity!,
      );
      await sig.start();
      _signaling = sig;
      _msgSub = sig.messages.listen(_onMessage);
      notifyListeners();

      unawaited(_refreshPresence());
      _presenceTimer =
          Timer.periodic(_presenceEvery, (_) => _refreshPresence());
    } catch (e) {
      debugPrint('Online signaling unavailable (LAN still works): $e');
    }
  }

  Future<void> setDisplayName(String name) async {
    final id = _identity;
    if (id == null) return;
    await id.setDisplayName(name);
    try {
      await _signaling?.publishProfile();
    } catch (_) {
      // Non-fatal; heartbeat will carry it forward.
    }
    notifyListeners();
  }

  /// Adds a contact from a pasted/scanned share code. Returns an error message
  /// to show the user, or null on success.
  Future<String?> addContactFromCode(String code, {String? name}) async {
    final contact = Contact.fromShareCode(code, overrideName: name);
    if (contact == null) return 'That code doesn\'t look valid.';
    if (contact.code == myCode) return 'That\'s your own code.';
    await _contacts?.upsert(contact);
    unawaited(_refreshPresenceFor(contact));
    return null;
  }

  /// Adds a contact by their machine [input] code (falling back to a legacy full
  /// share code if [input] isn't a machine code). Resolves the code's public key
  /// over the LAN first, then Firebase; the key is trusted only if it re-derives
  /// the code (so a resolver can't hand back an impostor). Returns an error
  /// message to show, or null on success.
  Future<String?> addByCode(String input, {String? name}) async {
    final code = normalizeDeviceCode(input);
    if (code == null) return addContactFromCode(input, name: name);
    if (code == myCode) return 'That\'s your own code.';

    final resolved =
        await _resolveByCode(code, name) ?? await _resolveByCodeOnline(code, name);
    if (resolved == null) {
      return 'Couldn\'t find a device with that code. Make sure it\'s on and '
          'reachable — on the same network, or both signed in.';
    }
    await _contacts?.upsert(resolved);
    unawaited(_refreshPresenceFor(resolved));
    return null;
  }

  /// Resolves [code] over the LAN into a trusted contact, or null.
  Future<Contact?> _resolveByCode(String code, String? name) async {
    final prof = await _discovery?.resolveProfile(code);
    if (prof == null || deviceCodeFromPublicKey(prof.publicKey) != code) {
      return null;
    }
    return Contact(
      name: _pickName(name, prof.name),
      deviceId: prof.uid,
      publicKey: prof.publicKey,
    );
  }

  /// Resolves [code] via the Firebase code index into a trusted contact, or null.
  Future<Contact?> _resolveByCodeOnline(String code, String? name) async {
    final m = await _signaling?.resolveCode(code);
    if (m == null) return null;
    final pk = (m['publicKey'] ?? '') as String;
    if (pk.isEmpty || deviceCodeFromPublicKey(pk) != code) return null;
    return Contact(
      name: _pickName(name, (m['name'] ?? '') as String),
      deviceId: (m['uid'] ?? '') as String,
      publicKey: pk,
    );
  }

  static String _pickName(String? preferred, String fallback) =>
      (preferred?.trim().isNotEmpty ?? false) ? preferred!.trim() : fallback;

  Future<void> renameContact(String code, String name) async =>
      _contacts?.rename(code, name);

  Future<void> removeContact(String code) async {
    await _contacts?.remove(code);
    _online.remove(code);
    notifyListeners();
  }

  /// The Firebase routing uid for a peer identified by machine [code], or null
  /// if we don't have them saved or they have no online address yet.
  String? _uidForCode(String code) {
    final uid = _contacts?.byCode(code)?.deviceId;
    return (uid == null || uid.isEmpty) ? null : uid;
  }

  // ── Transfer request / consent ────────────────────────────────────────

  /// Sends [files] to [to]. Tries the **LAN-direct path first** (find the peer
  /// on the local network → plain-TCP transfer, no Firebase); if the peer isn't
  /// reachable locally, falls back to the Firebase-signaled WebRTC path. Returns
  /// true if the peer accepted, false if declined or timed out.
  Future<bool> sendFiles(Contact to, List<OutgoingFile> files) async {
    final id = _identity;
    if (id == null || files.isEmpty) return false;

    if (await _preferLocalNetwork()) {
      final peer = await _discovery?.locate(to.code, to.publicKey);
      if (peer != null) {
        final outcome = await _sendOverLan(to, files, peer);
        if (outcome != _LanOutcome.unreachable) {
          return outcome == _LanOutcome.accepted;
        }
        // Reached discovery but couldn't connect/transfer — fall back below.
      }
    }
    return _sendOverFirebase(to, files);
  }

  Future<bool> _preferLocalNetwork() async {
    if (_discovery?.isRunning != true) return false;
    try {
      return await SettingsStore().getPreferLocalNetwork();
    } catch (_) {
      return true;
    }
  }

  /// Firebase-signaled path: signs a transfer-request, waits for the decision,
  /// and — on accept — the WebRTC handshake + byte transfer kick off once the
  /// offerer session connects (see [_startSession]).
  Future<bool> _sendOverFirebase(Contact to, List<OutgoingFile> files) async {
    final id = _identity;
    final sig = _signaling;
    // Online path needs our uid, an active signaling channel, and the peer's
    // routable Firebase address (empty for LAN-only contacts).
    if (id == null || sig == null || id.deviceId == null || to.deviceId.isEmpty) {
      return false;
    }

    final requestId = _uuid.v4();
    final msg = await buildSignedMessage(
      id,
      to: to.code,
      type: InboxMessage.typeTransferRequest,
      ts: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'requestId': requestId,
        'count': files.length,
        'files': [
          for (final f in files) TransferFileInfo(name: f.name, size: f.size).toJson()
        ],
      },
    );

    final completer = Completer<bool>();
    _pending[requestId] = completer;
    // Stash before awaiting so the files are ready the instant the offerer
    // connects (the accept can race back very fast on a LAN).
    _outgoing[requestId] = files;
    String? pushId;
    try {
      pushId = await sig.send(to.deviceId, msg);
    } catch (_) {
      _pending.remove(requestId);
      _outgoing.remove(requestId);
      return false;
    }
    final accepted = await completer.future.timeout(
      requestTimeout,
      onTimeout: () {
        _pending.remove(requestId);
        return false;
      },
    );
    if (!accepted) {
      _outgoing.remove(requestId);
      // The peer never accepted — sweep our request out of their inbox so it
      // doesn't linger if they were offline. (A decline already deletes it on
      // their side; a redundant delete is a harmless no-op.)
      unawaited(_deletePeerMessageQuietly(to.deviceId, pushId));
    }
    return accepted;
  }

  Future<void> _deletePeerMessageQuietly(String peerId, String? id) async {
    if (id == null) return;
    try {
      await _signaling?.deletePeerMessage(peerId, id);
    } catch (_) {}
  }

  void _onTransferProgress(String key, BatchProgress p) {
    _transfers[key] = p;
    notifyListeners();
  }

  // ── LAN-direct path ────────────────────────────────────────────────────

  /// Sends [files] to an already-located LAN [peer] over a plain-TCP
  /// [SocketConduit], reusing the same signed handshake + file protocol.
  Future<_LanOutcome> _sendOverLan(
      Contact to, List<OutgoingFile> files, LanPeer peer) async {
    final id = _identity!;
    Socket socket;
    try {
      socket = await Socket.connect(peer.address, peer.port,
          timeout: const Duration(seconds: 5));
    } catch (_) {
      return _LanOutcome.unreachable;
    }
    final conduit = SocketConduit(socket);
    final requestId = _uuid.v4();

    _transfers[requestId] = _batchFor(files.map((f) => (name: f.name, size: f.size)),
        sending: true);
    notifyListeners();

    final decision = Completer<bool>();
    conduit.onText = (text) async {
      final resp =
          await _parseVerified(text, from: to.code, key: to.publicKey);
      if (resp != null &&
          resp.type == InboxMessage.typeTransferResponse &&
          resp.payload['requestId'] == requestId &&
          !decision.isCompleted) {
        decision.complete(resp.payload['accepted'] == true);
      }
    };

    final reqMsg = await buildSignedMessage(
      id,
      to: to.code,
      type: InboxMessage.typeTransferRequest,
      ts: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'requestId': requestId,
        'count': files.length,
        'files': [
          for (final f in files)
            TransferFileInfo(name: f.name, size: f.size).toJson()
        ],
      },
    );
    try {
      await conduit.sendText(jsonEncode(reqMsg.toMap()));
    } catch (_) {
      _transfers.remove(requestId);
      notifyListeners();
      await conduit.close();
      return _LanOutcome.unreachable;
    }

    final accepted =
        await decision.future.timeout(requestTimeout, onTimeout: () => false);
    if (!accepted) {
      _transfers.remove(requestId);
      notifyListeners();
      await conduit.close();
      return _LanOutcome.declined;
    }

    conduit.onText = null; // handshake done — hand the conduit to the sender
    final sender = FileSender(
        conduit: conduit,
        files: files,
        onProgress: (p) => _onTransferProgress(requestId, p));
    _senders[requestId] = sender;
    _localActiveConduits[requestId] = conduit;
    try {
      await sender.send();
    } finally {
      _senders.remove(requestId);
      _localActiveConduits.remove(requestId);
      await conduit.close();
    }
    return _LanOutcome.accepted;
  }

  /// A fresh inbound LAN connection: first frame must be a signed
  /// transfer-request from a saved contact; then it joins the normal consent
  /// queue (same Accept/Decline dialog as the Firebase path).
  void _onLocalSocket(Socket socket) {
    final conduit = SocketConduit(socket);
    var consumed = false;
    conduit.onText = (text) {
      if (consumed) return;
      consumed = true;
      conduit.onText = null;
      unawaited(_handleLanRequest(conduit, text));
    };
    Timer(const Duration(seconds: 15), () {
      if (!consumed) conduit.close();
    });
  }

  Future<void> _handleLanRequest(SocketConduit conduit, String text) async {
    InboxMessage m;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        await conduit.close();
        return;
      }
      m = InboxMessage.fromMap('lan', decoded.cast<String, dynamic>());
    } catch (_) {
      await conduit.close();
      return;
    }
    final contact = await _verifiedSender(m);
    final req = (contact == null || m.type != InboxMessage.typeTransferRequest)
        ? null
        : IncomingTransferRequest.fromMessage(m, fromName: contact.name);
    if (req == null ||
        !_markSeen(req.requestId) ||
        !_withinLimits(req) ||
        _incoming.length >= maxQueuedRequests) {
      await conduit.close();
      return;
    }
    _localPendingConduits[req.requestId] = conduit;
    _incoming.add(req);
    notifyListeners();
  }

  Future<void> _respondLocal(
      IncomingTransferRequest req, bool accept, SocketConduit conduit) async {
    final id = _identity;
    if (id == null) {
      await conduit.close();
      return;
    }

    _transfers[req.requestId] =
        _batchFor(req.files.map((f) => (name: f.name, size: f.size)),
            sending: false);
    notifyListeners();

    final resp = await buildSignedMessage(
      id,
      to: req.fromDeviceId,
      type: InboxMessage.typeTransferResponse,
      ts: DateTime.now().millisecondsSinceEpoch,
      payload: {'requestId': req.requestId, 'accepted': accept},
    );
    try {
      await conduit.sendText(jsonEncode(resp.toMap()));
    } catch (_) {}

    if (!accept) {
      _transfers.remove(req.requestId);
      notifyListeners();
      await conduit.close();
      return;
    }

    final receiver = FileReceiver(
      conduit: conduit,
      destDir: await _destDir(),
      manifest: [for (final f in req.files) (name: f.name, size: f.size)],
      onProgress: (p) => _onTransferProgress(req.requestId, p),
    );
    _receivers[req.requestId] = receiver;
    _localActiveConduits[req.requestId] = conduit;
    try {
      await receiver.receive();
    } finally {
      _receivers.remove(req.requestId);
      _localActiveConduits.remove(req.requestId);
      await conduit.close();
    }
  }

  /// Parses a JSON [text] frame into a verified message from [from] (signed by
  /// [key], addressed to us, fresh), or null.
  Future<InboxMessage?> _parseVerified(String text,
      {required String from, required String key}) async {
    final me = myCode;
    final id = _identity;
    if (me == null || id == null) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final m = InboxMessage.fromMap('lan', decoded.cast<String, dynamic>());
      if (m.from != from) return null;
      final ok = await verifySignedMessage(id, m,
          myId: me, senderPublicKey: key);
      return ok ? m : null;
    } catch (_) {
      return null;
    }
  }

  BatchProgress _batchFor(Iterable<({String name, int size})> files,
      {required bool sending}) {
    var i = 0;
    return BatchProgress(
      sending: sending,
      files: [
        for (final f in files)
          FileTransferProgress(index: i++, name: f.name, size: f.size),
      ],
    );
  }

  /// Cancels an in-flight transfer (sender or receiver side) by session id.
  Future<void> cancelTransfer(String sessionId) async {
    _senders[sessionId]?.cancel();
    await _receivers[sessionId]?.cancel();
    // LAN transfers finish their cancel by closing the socket (WebRTC ones are
    // torn down via _endSession).
    await _localActiveConduits[sessionId]?.close();
  }

  /// Drops finished (done/failed/cancelled) transfers from the activity list.
  void clearFinishedTransfers() {
    final before = _transfers.length;
    _transfers.removeWhere((_, p) => p.isFinished);
    if (_transfers.length != before) notifyListeners();
  }

  /// Answers an incoming request; sends a signed accept/decline to the sender.
  Future<void> respondToRequest(
      IncomingTransferRequest req, bool accept) async {
    _incoming.remove(req);
    notifyListeners();

    // LAN request: answer + receive over the live socket, not the Firebase path.
    final localConduit = _localPendingConduits.remove(req.requestId);
    if (localConduit != null) {
      await _respondLocal(req, accept, localConduit);
      return;
    }

    final id = _identity;
    final sig = _signaling;
    if (id == null || sig == null) return;

    // Drop the request from our inbox now that it's handled.
    try {
      await sig.deleteInboxMessage(req.inboxMessageId);
    } catch (_) {}

    // Stand up the answerer session BEFORE sending the accept, so it's ready
    // for the offer the sender fires as soon as it sees our accept.
    if (accept) {
      _pendingReceive[req.requestId] = [
        for (final f in req.files) (name: f.name, size: f.size)
      ];
      await _startSession(
          req.fromDeviceId, req.requestId, RtcRole.answerer);
    }

    final msg = await buildSignedMessage(
      id,
      to: req.fromDeviceId,
      type: InboxMessage.typeTransferResponse,
      ts: DateTime.now().millisecondsSinceEpoch,
      payload: {'requestId': req.requestId, 'accepted': accept},
    );
    final uid = _uidForCode(req.fromDeviceId);
    if (uid != null) {
      try {
        await sig.send(uid, msg);
      } catch (_) {}
    }
  }

  Future<void> _onMessage(InboxMessage m) async {
    switch (m.type) {
      case InboxMessage.typeTransferRequest:
        await _handleRequest(m);
        break;
      case InboxMessage.typeTransferResponse:
        await _handleResponse(m);
        break;
      case InboxMessage.typeOffer:
      case InboxMessage.typeAnswer:
      case InboxMessage.typeIce:
        await _handleRtcSignal(m);
        break;
      default:
        await _deleteInbox(m.id);
        break;
    }
  }

  /// Returns the sending contact iff [m] is from a saved contact, addressed to
  /// us, and correctly signed by their key; otherwise null.
  Future<Contact?> _verifiedSender(InboxMessage m) async {
    final contact = _contacts?.byCode(m.from);
    if (contact == null || _identity == null || myCode == null) return null;
    final ok = await verifySignedMessage(
      _identity!,
      m,
      myId: myCode!,
      senderPublicKey: contact.publicKey,
    );
    return ok ? contact : null;
  }

  Future<void> _handleRequest(InboxMessage m) async {
    final contact = await _verifiedSender(m);
    final req = contact == null
        ? null
        : IncomingTransferRequest.fromMessage(m, fromName: contact.name);
    // Drop + tidy the inbox now for anything we won't surface: unknown/forged/
    // misaddressed/stale sender, malformed, a replay of a seen request, an
    // over-limit request, or a full queue.
    if (req == null ||
        !_markSeen(req.requestId) ||
        !_withinLimits(req) ||
        _incoming.length >= maxQueuedRequests) {
      await _deleteInbox(m.id);
      return;
    }
    _incoming.add(req);
    notifyListeners();
  }

  /// Records [requestId] as seen; returns false if it was already seen (replay).
  bool _markSeen(String requestId) {
    if (!_seenRequests.add(requestId)) return false;
    _seenOrder.add(requestId);
    if (_seenOrder.length > _maxSeenRequests) {
      _seenRequests.remove(_seenOrder.removeAt(0));
    }
    return true;
  }

  /// Rejects a request advertising too many / too-large / negative-size files.
  static bool _withinLimits(IncomingTransferRequest req) {
    if (req.files.isEmpty || req.files.length > maxFilesPerRequest) return false;
    var total = 0;
    for (final f in req.files) {
      if (f.size < 0) return false;
      total += f.size;
      if (total > maxBytesPerRequest) return false;
    }
    return true;
  }

  Future<void> _handleResponse(InboxMessage m) async {
    final contact = await _verifiedSender(m);
    await _deleteInbox(m.id);
    if (contact == null) return;
    final requestId = m.payload['requestId'] as String?;
    final accepted = m.payload['accepted'] == true;
    _pending.remove(requestId)?.complete(accepted);
    // Sender side: on accept, become the offerer and start negotiating.
    if (accepted && requestId != null && !_sessions.containsKey(requestId)) {
      await _startSession(m.from, requestId, RtcRole.offerer);
    }
  }

  // ── WebRTC ────────────────────────────────────────────────────────────

  Future<void> _handleRtcSignal(InboxMessage m) async {
    final contact = await _verifiedSender(m);
    await _deleteInbox(m.id);
    if (contact == null) return;
    final sessionId = m.payload['sessionId'] as String?;
    final session = sessionId == null ? null : _sessions[sessionId];
    if (session == null) return;
    try {
      switch (m.type) {
        case InboxMessage.typeOffer:
          await session.handleOffer(
              m.payload['sdp'] as String, m.payload['type'] as String);
          break;
        case InboxMessage.typeAnswer:
          await session.handleAnswer(
              m.payload['sdp'] as String, m.payload['type'] as String);
          break;
        case InboxMessage.typeIce:
          final c = m.payload['candidate'];
          if (c is Map) await session.addRemoteIce(c.cast<String, dynamic>());
          break;
      }
    } catch (_) {
      _endSession(sessionId!);
    }
  }

  /// [peerCode] is the peer's machine code; signals are routed to their Firebase
  /// address, looked up per-send in [_sendSignal].
  Future<void> _startSession(
      String peerCode, String sessionId, RtcRole role) async {
    final session = WebRtcSession(
      sessionId: sessionId,
      role: role,
      sendSignal: (type, payload) => _sendSignal(peerCode, type, payload),
    );
    _sessions[sessionId] = session;
    // Show the attempt in the UI right away, so a slow handshake or a dead
    // (no-direct-path) connection is visible instead of silent.
    _transfers[sessionId] = _placeholderProgress(sessionId, role);
    notifyListeners();
    session.onConnected.then((channel) {
      debugPrint('WebRTC connected: session=$sessionId role=$role');
      unawaited(_runTransfer(sessionId, role, RtcConduit(channel)));
    }).catchError((e) {
      debugPrint('WebRTC failed: session=$sessionId — $e');
      _markTransferFailed(
          sessionId, e is WebRtcFailure ? e.message : 'Connection failed.');
      _endSession(sessionId);
    });
    try {
      await session.start();
    } catch (e) {
      debugPrint('WebRTC start error: $e');
      _endSession(sessionId);
    }
  }

  /// A pending "Connecting…" entry for the Transfers list, seeded with the
  /// files we know about (queued outgoing, or the request's manifest).
  BatchProgress _placeholderProgress(String sessionId, RtcRole role) {
    final files = <FileTransferProgress>[];
    if (role == RtcRole.offerer) {
      final out = _outgoing[sessionId] ?? const [];
      for (var i = 0; i < out.length; i++) {
        files.add(FileTransferProgress(
            index: i, name: out[i].name, size: out[i].size));
      }
    } else {
      final man = _pendingReceive[sessionId] ?? const [];
      for (var i = 0; i < man.length; i++) {
        files.add(FileTransferProgress(
            index: i, name: man[i].name, size: man[i].size));
      }
    }
    return BatchProgress(sending: role == RtcRole.offerer, files: files);
  }

  void _markTransferFailed(String sessionId, String message) {
    final bp = _transfers[sessionId];
    if (bp == null || bp.isFinished) return;
    bp.status = TransferStatus.failed;
    bp.error = message;
    notifyListeners();
  }

  /// Runs the Phase-6 byte transfer over a connected channel: the offerer
  /// streams its queued files; the answerer receives into the destination dir.
  Future<void> _runTransfer(
      String sessionId, RtcRole role, RtcConduit conduit) async {
    void onProgress(BatchProgress p) {
      _transfers[sessionId] = p;
      notifyListeners();
    }

    try {
      if (role == RtcRole.offerer) {
        final files = _outgoing.remove(sessionId) ?? const [];
        if (files.isEmpty) {
          _endSession(sessionId);
          return;
        }
        final sender = FileSender(
            conduit: conduit, files: files, onProgress: onProgress);
        _senders[sessionId] = sender;
        await sender.send();
      } else {
        final manifest = _pendingReceive.remove(sessionId) ?? const [];
        final receiver = FileReceiver(
          conduit: conduit,
          destDir: await _destDir(),
          manifest: manifest,
          onProgress: onProgress,
        );
        _receivers[sessionId] = receiver;
        await receiver.receive();
      }
    } catch (e) {
      debugPrint('Transfer error: session=$sessionId — $e');
    } finally {
      _senders.remove(sessionId);
      _receivers.remove(sessionId);
      // Let the last frames flush before we tear the channel down, then close.
      Timer(const Duration(seconds: 3), () => _endSession(sessionId));
    }
  }

  /// Destination for received files: the folder set in Settings, else
  /// `~/Downloads/Notilus`.
  Future<String> _destDir() async {
    try {
      final custom = await SettingsStore().getTransferDestination();
      if (custom.isNotEmpty) return custom;
    } catch (_) {}
    Directory? base;
    try {
      base = await getDownloadsDirectory();
    } catch (_) {}
    if (base == null) {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '.';
      base = Directory(p.join(home, 'Downloads'));
    }
    return p.join(base.path, 'Notilus');
  }

  Future<void> _sendSignal(
      String peerCode, String type, Map<String, dynamic> payload) async {
    final id = _identity;
    final sig = _signaling;
    if (id == null || sig == null) return;
    final uid = _uidForCode(peerCode);
    if (uid == null) return; // no online address for this peer
    final msg = await buildSignedMessage(
      id,
      to: peerCode,
      type: type,
      ts: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
    );
    try {
      await sig.send(uid, msg);
    } catch (_) {}
  }

  void _endSession(String sessionId) {
    _senders.remove(sessionId)?.cancel();
    _receivers.remove(sessionId);
    _outgoing.remove(sessionId);
    _pendingReceive.remove(sessionId);
    final s = _sessions.remove(sessionId);
    s?.close();
  }

  Future<void> _deleteInbox(String? id) async {
    if (id == null) return;
    try {
      await _signaling?.deleteInboxMessage(id);
    } catch (_) {}
  }

  Future<void> _refreshPresence() async {
    for (final c in contacts) {
      await _refreshPresenceFor(c);
    }
  }

  /// Refreshes online status for one [contact]. Queried by their Firebase uid
  /// (online routing) but tracked by their machine code, matching the UI.
  Future<void> _refreshPresenceFor(Contact contact) async {
    final s = _signaling;
    if (s == null || contact.deviceId.isEmpty) return;
    final on = await s.isOnline(contact.deviceId);
    if (_online[contact.code] != on) {
      _online[contact.code] = on;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    _msgSub?.cancel();
    for (final s in _senders.values) {
      s.cancel();
    }
    _senders.clear();
    _receivers.clear();
    for (final s in _sessions.values) {
      s.close();
    }
    _sessions.clear();
    for (final c in _localPendingConduits.values) {
      c.close();
    }
    for (final c in _localActiveConduits.values) {
      c.close();
    }
    _localPendingConduits.clear();
    _localActiveConduits.clear();
    _discovery?.stop();
    _localServer?.stop();
    _contacts?.removeListener(notifyListeners);
    _signaling?.stop();
    super.dispose();
  }
}
