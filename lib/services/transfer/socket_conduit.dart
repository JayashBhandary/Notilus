import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'file_transfer.dart';

/// A [TransferConduit] over a raw TCP [Socket], for the LAN-direct transfer path
/// (no Firebase, no WebRTC). Lets the transport-agnostic [FileSender] /
/// [FileReceiver] run unchanged over a local socket.
///
/// TCP is a byte stream with no message boundaries, so we frame every logical
/// message as `[1 byte type][4 byte big-endian length][payload]` — type 0 =
/// text, 1 = binary. Backpressure is approximated via `flush()`: bytes counted
/// as buffered until the socket's write buffer drains to the OS.
///
/// ⚠ Plain TCP: bytes are **not encrypted** in transit (unlike the WebRTC/DTLS
/// path). Intended for trusted local networks; the sender is still authenticated
/// by the signed transfer-request handshake before any bytes flow.
class SocketConduit implements TransferConduit {
  SocketConduit(this._socket) {
    _sub = _socket.listen(
      _onData,
      onError: (_) => _closeDone(),
      onDone: _closeDone,
      cancelOnError: true,
    );
  }

  static const _typeText = 0;
  static const _typeBinary = 1;

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;

  void Function(String text)? _onText;
  void Function(Uint8List bytes)? _onBinary;
  void Function()? _onBufferedLow;

  final BytesBuilder _rx = BytesBuilder(copy: false);
  // Frames received before a handler was attached (handshake → protocol handoff
  // reassigns handlers); delivered in order once a handler exists.
  final List<(int, Uint8List)> _inbound = [];

  int _pending = 0;
  bool _flushing = false;
  bool _closed = false;
  final Completer<void> _done = Completer<void>();

  /// Completes when the socket closes or errors (mid-transfer drop detection).
  Future<void> get done => _done.future;

  // ── TransferConduit ────────────────────────────────────────────────────
  @override
  set onText(void Function(String text)? cb) {
    _onText = cb;
    _flushInbound();
  }

  @override
  set onBinary(void Function(Uint8List bytes)? cb) {
    _onBinary = cb;
    _flushInbound();
  }

  @override
  set onBufferedLow(void Function()? cb) => _onBufferedLow = cb;

  @override
  int get bufferedAmount => _pending;

  @override
  set bufferedAmountLowThreshold(int bytes) {
    // No native threshold event on a socket; _scheduleFlush drives onBufferedLow.
  }

  @override
  Future<void> sendText(String text) => _send(_typeText, utf8.encode(text));

  @override
  Future<void> sendBinary(Uint8List bytes) => _send(_typeBinary, bytes);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    try {
      await _socket.close();
    } catch (_) {}
    _socket.destroy();
    _closeDone();
  }

  // ── framing ────────────────────────────────────────────────────────────
  Future<void> _send(int type, List<int> payload) async {
    if (_closed) return;
    final frame = Uint8List(5 + payload.length);
    frame[0] = type;
    ByteData.sublistView(frame).setUint32(1, payload.length, Endian.big);
    frame.setRange(5, 5 + payload.length, payload);
    _pending += frame.length;
    try {
      _socket.add(frame);
    } catch (_) {
      return;
    }
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_flushing || _closed) return;
    _flushing = true;
    _socket.flush().then((_) {
      _pending = 0;
      _flushing = false;
      _onBufferedLow?.call();
    }).catchError((_) {
      _flushing = false;
    });
  }

  void _onData(Uint8List data) {
    // ignore: avoid_print
    print('DBG _onData ${data.length} bytes, rx now ${_rx.length + data.length}');
    _rx.add(data);
    if (_rx.length < 5) return;
    var bytes = _rx.takeBytes();
    var offset = 0;
    while (bytes.length - offset >= 5) {
      final len =
          ByteData.sublistView(bytes, offset + 1, offset + 5).getUint32(0, Endian.big);
      if (bytes.length - offset - 5 < len) break; // incomplete frame
      final type = bytes[offset];
      final payload =
          Uint8List.fromList(bytes.sublist(offset + 5, offset + 5 + len));
      _inbound.add((type, payload));
      offset += 5 + len;
    }
    if (offset < bytes.length) {
      _rx.add(Uint8List.sublistView(bytes, offset));
    }
    _flushInbound();
  }

  void _flushInbound() {
    while (_inbound.isNotEmpty) {
      final (type, payload) = _inbound.first;
      if (type == _typeText) {
        final h = _onText;
        if (h == null) break;
        _inbound.removeAt(0);
        h(utf8.decode(payload));
      } else {
        final h = _onBinary;
        if (h == null) break;
        _inbound.removeAt(0);
        h(payload);
      }
    }
  }

  void _closeDone() {
    if (!_done.isCompleted) _done.complete();
  }
}
