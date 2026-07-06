import 'inbox_message.dart';

/// One file's advertised metadata in a transfer request (no bytes yet).
class TransferFileInfo {
  const TransferFileInfo({required this.name, required this.size});
  final String name;
  final int size;

  Map<String, dynamic> toJson() => {'name': name, 'size': size};

  factory TransferFileInfo.fromJson(Map json) => TransferFileInfo(
        name: (json['name'] ?? '') as String,
        size: (json['size'] is int)
            ? json['size'] as int
            : int.tryParse('${json['size']}') ?? 0,
      );
}

/// A verified, incoming request awaiting the user's Accept/Decline.
class IncomingTransferRequest {
  const IncomingTransferRequest({
    required this.requestId,
    required this.fromDeviceId,
    required this.fromName,
    required this.files,
    required this.inboxMessageId,
  });

  final String requestId;
  final String fromDeviceId;
  final String fromName;
  final List<TransferFileInfo> files;
  final String inboxMessageId; // delete from our inbox once handled

  int get totalBytes => files.fold(0, (a, f) => a + f.size);
  int get count => files.length;

  /// Builds from a verified inbox message + the sender's saved name.
  static IncomingTransferRequest? fromMessage(
    InboxMessage m, {
    required String fromName,
  }) {
    final id = m.payload['requestId'];
    if (id is! String || m.id == null) return null;
    final rawFiles = m.payload['files'];
    final files = <TransferFileInfo>[];
    if (rawFiles is List) {
      for (final f in rawFiles) {
        if (f is Map) files.add(TransferFileInfo.fromJson(f));
      }
    }
    return IncomingTransferRequest(
      requestId: id,
      fromDeviceId: m.from,
      fromName: fromName,
      files: files,
      inboxMessageId: m.id!,
    );
  }
}
