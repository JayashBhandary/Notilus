import 'dart:io';

import 'package:flutter/foundation.dart';

/// Accepts inbound LAN transfer connections on an ephemeral TCP port. Framing,
/// the signed handshake, and the file protocol are handled by the caller
/// ([TransferController]) via [onSocket]; this just owns the listening socket.
class LocalTransferServer {
  LocalTransferServer(this.onSocket);

  final void Function(Socket socket) onSocket;

  ServerSocket? _server;

  /// The bound port (0 until [start] succeeds) — advertised over discovery.
  int get port => _server?.port ?? 0;

  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      _server!.listen(
        onSocket,
        onError: (Object e) => debugPrint('LocalTransferServer error: $e'),
      );
    } catch (e) {
      debugPrint('LocalTransferServer bind failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
  }
}
