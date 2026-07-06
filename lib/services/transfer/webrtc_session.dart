import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum RtcRole { offerer, answerer }

class WebRtcFailure implements Exception {
  WebRtcFailure(this.message);
  final String message;
  @override
  String toString() => 'WebRtcFailure: $message';
}

/// One direct peer-to-peer connection for a single transfer, negotiated over an
/// external signaling channel (the RTDB inbox). Transport-agnostic: it emits
/// outbound signaling via [sendSignal] and is fed inbound messages via
/// [handleOffer]/[handleAnswer]/[addRemoteIce]. On success [onConnected]
/// completes with an open, ordered [RTCDataChannel]; on a dead end (no direct
/// path — we ship no TURN) it completes with a [WebRtcFailure].
class WebRtcSession {
  WebRtcSession({
    required this.sessionId,
    required this.role,
    required this.sendSignal,
    this.connectTimeout = const Duration(seconds: 30),
  });

  final String sessionId;
  final RtcRole role;
  final Future<void> Function(String type, Map<String, dynamic> payload)
      sendSignal;
  final Duration connectTimeout;

  // Free public STUN only — no TURN (option A). Direct paths work on most
  // networks; doubly-symmetric-NAT cases fail with a clear message.
  static const _iceServers = {
    'iceServers': [
      {
        'urls': [
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
        ]
      }
    ]
  };

  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  final Completer<RTCDataChannel> _connected = Completer<RTCDataChannel>();
  Timer? _timeout;

  bool _remoteReady = false;
  final List<RTCIceCandidate> _pendingRemote = [];
  final Set<String> _seenLocalTypes = {};

  Future<RTCDataChannel> get onConnected => _connected.future;

  /// Greppable, low-noise diagnostics for live (two-machine) testing.
  void _log(String message) {
    final tag = sessionId.length >= 8 ? sessionId.substring(0, 8) : sessionId;
    debugPrint('[webrtc $tag/${role.name}] $message');
  }

  /// Pulls the `typ <kind>` token out of an ICE candidate line
  /// (host = LAN/direct, srflx = NAT-reflexive/STUN, relay = TURN — which we
  /// don't ship, so it should never appear).
  static String _candidateType(String? candidate) {
    if (candidate == null) return 'unknown';
    final match = RegExp(r'\btyp (\w+)').firstMatch(candidate);
    return match?.group(1) ?? 'unknown';
  }

  Future<void> start() async {
    _pc = await createPeerConnection(_iceServers);
    _timeout = Timer(connectTimeout, () {
      _fail('Couldn’t establish a direct connection on this network.');
    });

    _pc!.onIceCandidate = (c) {
      if (c.candidate == null) return;
      // Log each new local candidate type once, so a live test can see whether
      // we even gathered a reflexive (STUN) candidate for cross-NAT paths.
      final type = _candidateType(c.candidate);
      if (_seenLocalTypes.add(type)) _log('local candidate: $type');
      sendSignal(
          'ice-candidate', {'sessionId': sessionId, 'candidate': c.toMap()});
    };
    _pc!.onConnectionState = (s) {
      _log('connection state: ${s.name}');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _fail('Peer connection failed (no direct path).');
      }
    };
    _pc!.onIceConnectionState = (s) {
      _log('ice state: ${s.name}');
      if (s == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _fail('ICE negotiation failed (no direct path).');
      }
    };

    if (role == RtcRole.offerer) {
      final ch = await _pc!.createDataChannel(
        'files',
        RTCDataChannelInit()..ordered = true,
      );
      _bindChannel(ch);
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      await sendSignal('webrtc-offer',
          {'sessionId': sessionId, 'sdp': offer.sdp, 'type': offer.type});
    } else {
      _pc!.onDataChannel = _bindChannel;
    }
  }

  void _bindChannel(RTCDataChannel ch) {
    _channel = ch;
    if (ch.state == RTCDataChannelState.RTCDataChannelOpen) {
      _succeed(ch);
    }
    ch.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) _succeed(ch);
    };
  }

  Future<void> handleOffer(String sdp, String type) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
    await _flushRemoteIce();
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    await sendSignal('webrtc-answer',
        {'sessionId': sessionId, 'sdp': answer.sdp, 'type': answer.type});
  }

  Future<void> handleAnswer(String sdp, String type) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
    await _flushRemoteIce();
  }

  /// Adds a remote ICE candidate, buffering it until the remote description is
  /// set (candidates can arrive before the offer/answer).
  Future<void> addRemoteIce(Map<String, dynamic> c) async {
    final cand = RTCIceCandidate(
      c['candidate'] as String?,
      c['sdpMid'] as String?,
      (c['sdpMLineIndex'] is int)
          ? c['sdpMLineIndex'] as int
          : int.tryParse('${c['sdpMLineIndex']}'),
    );
    if (!_remoteReady) {
      _pendingRemote.add(cand);
      return;
    }
    await _pc?.addCandidate(cand);
  }

  Future<void> _flushRemoteIce() async {
    _remoteReady = true;
    for (final c in _pendingRemote) {
      await _pc?.addCandidate(c);
    }
    _pendingRemote.clear();
  }

  void _succeed(RTCDataChannel ch) {
    _timeout?.cancel();
    _log('data channel open — connected');
    if (!_connected.isCompleted) _connected.complete(ch);
  }

  void _fail(String reason) {
    _timeout?.cancel();
    if (!_connected.isCompleted) _connected.completeError(WebRtcFailure(reason));
  }

  Future<void> close() async {
    _timeout?.cancel();
    try {
      await _channel?.close();
    } catch (_) {}
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    if (!_connected.isCompleted) {
      _connected.completeError(WebRtcFailure('closed'));
    }
  }
}
