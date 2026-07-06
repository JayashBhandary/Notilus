import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/services/transfer/file_transfer.dart';
import 'package:notilus/services/transfer/socket_conduit.dart';
import 'package:path/path.dart' as p;

/// Exercises the LAN-direct transport: a real loopback TCP socket pair wrapped in
/// [SocketConduit], driving the same [FileSender]/[FileReceiver] used everywhere.
Future<(SocketConduit, SocketConduit)> _connectedPair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final accepted = server.first;
  final client = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
  final serverSocket = await accepted;
  await server.close();
  return (SocketConduit(client), SocketConduit(serverSocket));
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('notilus_sock_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('multi-file transfer round-trips over a TCP SocketConduit', () async {
    final (send, recv) = await _connectedPair();
    final dest = p.join(tmp.path, 'dest');
    final src = Directory(p.join(tmp.path, 'src'))..createSync(recursive: true);

    final f1 = File(p.join(src.path, 'a.txt'))
      ..writeAsBytesSync(List<int>.generate(10, (i) => i));
    final f2 = File(p.join(src.path, 'b.bin'))
      ..writeAsBytesSync(List<int>.generate(64 * 1024, (i) => (i * 7) & 0xff));
    final files = [
      OutgoingFile.forPath(f1.path),
      OutgoingFile.forPath(f2.path),
    ];

    final receiver = FileReceiver(
      conduit: recv,
      destDir: dest,
      manifest: [for (final f in files) (name: f.name, size: f.size)],
    );
    final recvFuture = receiver.receive();
    final sent = await FileSender(conduit: send, files: files).send();
    final got = await recvFuture;

    expect(sent.status, TransferStatus.done);
    expect(got.status, TransferStatus.done);
    for (final f in files) {
      expect(await File(p.join(dest, f.name)).readAsBytes(),
          await File(f.path).readAsBytes(),
          reason: '${f.name} should round-trip byte-identical');
    }

    await send.close();
    await recv.close();
  });

  test('framing preserves text/binary message boundaries and order', () async {
    final (a, b) = await _connectedPair();
    final texts = <String>[];
    final binLengths = <int>[];
    b.onText = texts.add;
    b.onBinary = (bytes) => binLengths.add(bytes.length);

    await a.sendText('hello');
    await a.sendBinary(Uint8List.fromList(List<int>.filled(1000, 7)));
    await a.sendText('world');
    // Give the loopback a moment to deliver all three frames.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(texts, ['hello', 'world']);
    expect(binLengths, [1000]);

    await a.close();
    await b.close();
  });

  test('frames that arrive before a handler is set are buffered, not lost',
      () async {
    final (a, b) = await _connectedPair();
    // Send before b has any handler — SocketConduit must queue and redeliver.
    await a.sendText('early');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final received = <String>[];
    b.onText = received.add; // attaching a handler should flush the backlog
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(received, ['early']);
    await a.close();
    await b.close();
  });
}
