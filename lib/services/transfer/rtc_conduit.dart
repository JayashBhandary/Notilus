import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'file_transfer.dart';

/// Adapts a live WebRTC [RTCDataChannel] to the transport-agnostic
/// [TransferConduit] the file protocol drives. This is the only part of Phase 6
/// that touches native flutter_webrtc, which is why it's split out — everything
/// in `file_transfer.dart` stays testable under `flutter test`.
class RtcConduit implements TransferConduit {
  RtcConduit(this._channel) {
    _channel.onMessage = (msg) {
      if (msg.isBinary) {
        onBinary?.call(msg.binary);
      } else {
        onText?.call(msg.text);
      }
    };
    _channel.onBufferedAmountLow = (_) => onBufferedLow?.call();
  }

  final RTCDataChannel _channel;

  @override
  void Function(String text)? onText;
  @override
  void Function(Uint8List bytes)? onBinary;
  @override
  void Function()? onBufferedLow;

  @override
  Future<void> sendText(String text) =>
      _channel.send(RTCDataChannelMessage(text));

  @override
  Future<void> sendBinary(Uint8List bytes) =>
      _channel.send(RTCDataChannelMessage.fromBinary(bytes));

  @override
  int get bufferedAmount => _channel.bufferedAmount ?? 0;

  @override
  set bufferedAmountLowThreshold(int bytes) =>
      _channel.bufferedAmountLowThreshold = bytes;

  @override
  Future<void> close() async {
    // The channel's lifecycle is owned by WebRtcSession; nothing to do here.
  }
}
