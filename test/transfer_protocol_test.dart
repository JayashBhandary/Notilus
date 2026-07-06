import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/services/transfer/file_transfer.dart';
import 'package:path/path.dart' as p;

/// An in-memory [TransferConduit] pair standing in for a WebRTC DataChannel, so
/// the Phase-6 protocol (chunking / sha256 / reassembly / backpressure / cancel)
/// can be tested without native flutter_webrtc. Delivery is via microtasks so
/// text and binary frames stay in send order, like an ordered SCTP stream.
class _FakeConduit implements TransferConduit {
  late _FakeConduit peer;

  @override
  void Function(String text)? onText;
  @override
  void Function(Uint8List bytes)? onBinary;
  @override
  void Function()? onBufferedLow;

  @override
  int bufferedAmount = 0;
  @override
  int bufferedAmountLowThreshold = 0;

  /// Optional in-flight tamper for the integrity test.
  Uint8List Function(Uint8List)? tamper;

  @override
  Future<void> sendText(String text) async {
    scheduleMicrotask(() => peer.onText?.call(text));
  }

  @override
  Future<void> sendBinary(Uint8List bytes) async {
    final copy = Uint8List.fromList(bytes);
    final out = peer.tamper?.call(copy) ?? copy;
    scheduleMicrotask(() => peer.onBinary?.call(out));
  }

  @override
  Future<void> close() async {}

  static (_FakeConduit, _FakeConduit) pair() {
    final a = _FakeConduit();
    final b = _FakeConduit();
    a.peer = b;
    b.peer = a;
    return (a, b);
  }
}

late Directory _tmp;

Future<OutgoingFile> _writeFile(String name, List<int> bytes) async {
  final f = File(p.join(_tmp.path, 'src', name));
  await f.parent.create(recursive: true);
  await f.writeAsBytes(bytes);
  return OutgoingFile.forPath(f.path);
}

Uint8List _bytes(int n, int seed) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i * 31 + seed) & 0xff));

void main() {
  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('notilus_proto_');
  });
  tearDown(() {
    if (_tmp.existsSync()) _tmp.deleteSync(recursive: true);
  });

  test('multi-file batch transfers, verifies, and commits to disk', () async {
    final (a, b) = _FakeConduit.pair();
    final dest = p.join(_tmp.path, 'dest');

    final files = [
      await _writeFile('a.txt', _bytes(10, 1)),
      await _writeFile('b.bin', _bytes(40 * 1024, 2)), // multi-chunk
      await _writeFile('empty.dat', const []),
    ];

    final receiver = FileReceiver(
      conduit: b,
      destDir: dest,
      manifest: [for (final f in files) (name: f.name, size: f.size)],
    );
    final recvFuture = receiver.receive();

    final sender = FileSender(conduit: a, files: files);
    final sent = await sender.send();
    final got = await recvFuture;

    expect(sent.status, TransferStatus.done);
    expect(got.status, TransferStatus.done);
    expect(got.fraction, 1.0);

    for (final src in files) {
      final out = File(p.join(dest, src.name));
      expect(out.existsSync(), isTrue, reason: '${src.name} should exist');
      expect(await out.readAsBytes(),
          await File(src.path).readAsBytes(),
          reason: '${src.name} bytes should round-trip');
    }
    // No leftover partials.
    expect(
      Directory(dest).listSync().where((e) => e.path.endsWith('.part')),
      isEmpty,
    );
    expect(got.files.every((f) => f.status == TransferStatus.done), isTrue);
    expect(got.files.every((f) => f.savedPath != null), isTrue);
  });

  test('a name collision is committed under a unique name', () async {
    final dest = p.join(_tmp.path, 'dest');
    await Directory(dest).create(recursive: true);
    await File(p.join(dest, 'dup.txt')).writeAsString('existing');

    final (a, b) = _FakeConduit.pair();
    final file = await _writeFile('dup.txt', _bytes(2048, 7));
    final receiver = FileReceiver(conduit: b, destDir: dest);
    final recvFuture = receiver.receive();
    await FileSender(conduit: a, files: [file]).send();
    final got = await recvFuture;

    expect(File(p.join(dest, 'dup.txt')).readAsStringSync(), 'existing');
    expect(File(p.join(dest, 'dup (1).txt')).existsSync(), isTrue);
    expect(got.files.single.savedPath, endsWith('dup (1).txt'));
  });

  test('a corrupted chunk fails the integrity check and drops the partial',
      () async {
    final (a, b) = _FakeConduit.pair();
    final dest = p.join(_tmp.path, 'dest');
    // Flip the first byte of the first binary frame the receiver sees.
    var flipped = false;
    b.tamper = (bytes) {
      if (!flipped && bytes.isNotEmpty) {
        flipped = true;
        bytes[0] = bytes[0] ^ 0xff;
      }
      return bytes;
    };

    final file = await _writeFile('corrupt.bin', _bytes(8 * 1024, 3));
    final receiver = FileReceiver(conduit: b, destDir: dest);
    final recvFuture = receiver.receive();
    await FileSender(conduit: a, files: [file]).send();
    final got = await recvFuture;

    expect(got.status, TransferStatus.failed);
    expect(got.files.single.status, TransferStatus.failed);
    expect(got.files.single.error, contains('Integrity'));
    // Neither the committed file nor its partial should remain.
    expect(File(p.join(dest, 'corrupt.bin')).existsSync(), isFalse);
    expect(File(p.join(dest, 'corrupt.bin.part')).existsSync(), isFalse);
  });

  test('a cancel frame stops the receiver and cleans the partial', () async {
    final (a, b) = _FakeConduit.pair();
    final dest = p.join(_tmp.path, 'dest');
    final receiver = FileReceiver(conduit: b, destDir: dest);
    final recvFuture = receiver.receive();

    // Hand-craft a partial send followed by a cancel (no file-done).
    final payload = _bytes(4096, 9);
    final sha = sha256.convert(payload).toString();
    await a.sendText(jsonEncode({
      'v': 1,
      't': kFileHeader,
      'index': 0,
      'total': 1,
      'name': 'aborted.bin',
      'size': payload.length,
      'sha256': sha,
    }));
    await a.sendBinary(Uint8List.sublistView(payload, 0, 1024));
    await a.sendText(jsonEncode({'v': 1, 't': kCancel}));

    final got = await recvFuture;
    expect(got.status, TransferStatus.cancelled);
    expect(File(p.join(dest, 'aborted.bin')).existsSync(), isFalse);
    expect(File(p.join(dest, 'aborted.bin.part')).existsSync(), isFalse);
  });

  test('sender backpressure waits on a full buffer but still completes',
      () async {
    final (a, b) = _FakeConduit.pair();
    final dest = p.join(_tmp.path, 'dest');
    // Report a full buffer until the low-threshold event is scheduled to fire.
    a.bufferedAmount = 4 * 1024 * 1024;

    final file = await _writeFile('big.bin', _bytes(64 * 1024, 5));
    final receiver = FileReceiver(conduit: b, destDir: dest);
    final recvFuture = receiver.receive();

    final sender = FileSender(
      conduit: a,
      files: [file],
      highWater: 1024 * 1024,
    );
    // Drain the buffer shortly after send starts so _drain unblocks via event.
    Timer(const Duration(milliseconds: 20), () {
      a.bufferedAmount = 0;
      a.onBufferedLow?.call();
    });

    final sent = await sender.send();
    final got = await recvFuture;
    expect(sent.status, TransferStatus.done);
    expect(got.status, TransferStatus.done);
    expect(await File(p.join(dest, 'big.bin')).readAsBytes(),
        await File(file.path).readAsBytes());
  });

  test('receiver fails and cleans the partial when the peer goes silent',
      () async {
    final (a, b) = _FakeConduit.pair();
    final dest = p.join(_tmp.path, 'dest');
    final receiver = FileReceiver(
      conduit: b,
      destDir: dest,
      stallTimeout: const Duration(milliseconds: 150),
    );
    final recvFuture = receiver.receive();

    // Header + one chunk, then the sender vanishes — no file-done ever comes.
    final payload = _bytes(4096, 11);
    final sha = sha256.convert(payload).toString();
    await a.sendText(jsonEncode({
      'v': 1,
      't': kFileHeader,
      'index': 0,
      'total': 1,
      'name': 'silent.bin',
      'size': payload.length,
      'sha256': sha,
    }));
    await a.sendBinary(Uint8List.sublistView(payload, 0, 1024));

    final got = await recvFuture; // resolves via the stall watchdog
    expect(got.status, TransferStatus.failed);
    expect(got.error, contains('stalled'));
    expect(File(p.join(dest, 'silent.bin.part')).existsSync(), isFalse);
    expect(File(p.join(dest, 'silent.bin')).existsSync(), isFalse);
  });

  test('sender fails when the send buffer never drains', () async {
    final (a, b) = _FakeConduit.pair();
    final dest = p.join(_tmp.path, 'dest');
    a.bufferedAmount = 8 * 1024 * 1024; // permanently full, never signals low

    final file = await _writeFile('stuck.bin', _bytes(64 * 1024, 12));
    // Receiver present but the sender should give up on backpressure first.
    final receiver = FileReceiver(
      conduit: b,
      destDir: dest,
      stallTimeout: const Duration(milliseconds: 150),
    );
    final recvFuture = receiver.receive();
    final sender = FileSender(
      conduit: a,
      files: [file],
      highWater: 1024 * 1024,
      stallTimeout: const Duration(milliseconds: 150),
    );
    final sent = await sender.send();
    expect(sent.status, TransferStatus.failed);
    expect(sent.error, contains('Stalled'));
    await recvFuture; // let the receiver's watchdog wind down too
  });

  test('a hostile filename cannot escape the destination directory', () async {
    final (a, b) = _FakeConduit.pair();
    final dest = p.join(_tmp.path, 'dest');
    final receiver = FileReceiver(conduit: b, destDir: dest);
    final recvFuture = receiver.receive();

    final payload = _bytes(512, 4);
    final sha = sha256.convert(payload).toString();
    await a.sendText(jsonEncode({
      'v': 1,
      't': kFileHeader,
      'index': 0,
      'total': 1,
      'name': '../../escape.txt',
      'size': payload.length,
      'sha256': sha,
    }));
    await a.sendBinary(payload);
    await a.sendText(jsonEncode({'v': 1, 't': kFileDone, 'index': 0}));
    await a.sendText(jsonEncode({'v': 1, 't': kBatchDone}));

    final got = await recvFuture;
    expect(got.status, TransferStatus.done);
    // Landed inside dest under a sanitized basename, not two levels up.
    expect(File(p.join(dest, 'escape.txt')).existsSync(), isTrue);
    expect(File(p.join(_tmp.path, 'escape.txt')).existsSync(), isFalse);
  });
}
