import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../../models/transfer/contact.dart';
import '../../providers/transfer_controller.dart';
import '../../services/system_info_service.dart' show formatBytes;
import '../../services/transfer/file_transfer.dart';
import '../../theme.dart';

/// Phase 9 — the real "Send to…" flow, invoked from the file browser's context
/// menu. Resolves [filePaths] to sendable files, lets the user pick a saved
/// contact, then hands off to [TransferController.sendFiles] (the actual byte
/// transfer runs over WebRTC and its progress shows in the File Transfer view).
Future<void> showSendToSheet(
  BuildContext context,
  List<String> filePaths,
) async {
  final ctrl = context.read<TransferController>();

  // Only regular files travel; silently drop folders and anything unreadable.
  final files = <OutgoingFile>[];
  for (final path in filePaths) {
    try {
      if (FileSystemEntity.isFileSync(path)) {
        files.add(OutgoingFile.forPath(path));
      }
    } catch (_) {}
  }

  if (files.isEmpty) {
    return _alert(context, 'Nothing to send',
        'Folders can’t be sent yet — pick one or more files.');
  }
  if (!ctrl.isConfigured) {
    return _alert(context, 'File transfer isn’t set up',
        'Add your Firebase details in lib/config/transfer_config.dart, then '
        'restart Notilus.');
  }
  if (!ctrl.ready) {
    return _alert(context, 'Still connecting',
        'Notilus is still connecting to the transfer service. Try again in a '
        'moment.');
  }
  if (ctrl.contacts.isEmpty) {
    return _alert(context, 'No contacts yet',
        'Open File Transfer and add a contact (swap codes with a friend) '
        'before sending.');
  }

  if (!context.mounted) return;
  final contact = await _pickContact(context, ctrl, files);
  if (contact == null || !context.mounted) return;

  await _sendAndReport(context, ctrl, contact, files);
}

Future<Contact?> _pickContact(
  BuildContext context,
  TransferController ctrl,
  List<OutgoingFile> files,
) {
  final totalBytes = files.fold<int>(0, (a, f) => a + f.size);
  final palette = AppColors.of(context);
  return showCupertinoModalPopup<Contact>(
    context: context,
    builder: (ctx) => CupertinoActionSheet(
      title: Text('Send ${files.length} file${files.length == 1 ? '' : 's'}'),
      message: Text(formatBytes(totalBytes)),
      actions: [
        for (final c in ctrl.contacts)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, c),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ctrl.isOnline(c.code)
                        ? palette.success
                        : palette.subtleText.withValues(alpha: 0.4),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(child: Text(c.name, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('Cancel'),
      ),
    ),
  );
}

Future<void> _sendAndReport(
  BuildContext context,
  TransferController ctrl,
  Contact contact,
  List<OutgoingFile> files,
) async {
  unawaited(showCupertinoDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => CupertinoAlertDialog(
      title: const Text('Waiting…'),
      content: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(),
            const SizedBox(height: 10),
            Text('Waiting for ${contact.name} to accept.'),
          ],
        ),
      ),
    ),
  ));

  final accepted = await ctrl.sendFiles(contact, files);
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop(); // close the waiting dialog

  await _alert(
    context,
    accepted ? 'Sending…' : 'Declined / timed out',
    accepted
        ? '${contact.name} accepted. Track progress in File Transfer → '
            'Transfers.'
        : '${contact.name} declined or didn’t respond in time.',
  );
}

Future<void> _alert(BuildContext context, String title, String message) {
  if (!context.mounted) return Future.value();
  return showCupertinoDialog<void>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(title),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(message),
      ),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
