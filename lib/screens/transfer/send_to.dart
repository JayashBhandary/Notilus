import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../models/transfer/contact.dart';
import '../../providers/transfer_controller.dart';
import '../../services/system_info_service.dart' show formatBytes;
import '../../services/transfer/file_transfer.dart';
import '../../theme.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/shad_spinner.dart';

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

  // The four preconditions below stay modal: each one means the send is not
  // happening, and that is a fact the user has to acknowledge before the flow
  // ends. The *outcomes* further down are toasted instead — see _toast.
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

/// Centered contact picker. A dialog rather than a bottom sheet: this is
/// triggered from the file browser's right-click menu on a desktop-width
/// window, where a full-width sheet rising from the bottom edge is the wrong
/// idiom for choosing one of a handful of peers.
Future<Contact?> _pickContact(
  BuildContext context,
  TransferController ctrl,
  List<OutgoingFile> files,
) {
  final totalBytes = files.fold<int>(0, (a, f) => a + f.size);
  return showAppDialog<Contact>(
    context: context,
    builder: (ctx) => ShadDialog(
      title: Text(
        'Send ${files.length} file${files.length == 1 ? '' : 's'}',
      ),
      description: Text(formatBytes(totalBytes)),
      constraints: const BoxConstraints(maxWidth: 380),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        // The rows need a concrete width to ellipsize long names — see the note
        // in _ContactRow for why ShadButton cannot supply one itself.
        child: LayoutBuilder(
          builder: (_, constraints) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final c in ctrl.contacts)
                _ContactRow(
                  contact: c,
                  online: ctrl.isOnline(c.code),
                  availableWidth: constraints.maxWidth,
                  onPressed: () => Navigator.pop(ctx, c),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// One selectable peer: presence dot, name, and its presence as a subtitle.
class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.contact,
    required this.online,
    required this.availableWidth,
    required this.onPressed,
  });
  final Contact contact;
  final bool online;
  final double availableWidth;
  final VoidCallback onPressed;

  /// Matches [_hPadding] below on both sides.
  static const double _hPadding = 10;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    return ShadButton.ghost(
      onPressed: onPressed,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: _hPadding),
      mainAxisAlignment: MainAxisAlignment.start,
      // ShadButton's internal Row is mainAxisSize.min, so it hands its child
      // unbounded width no matter what constraints reach the button — an
      // Expanded in here would throw. Pinning the width is what makes the
      // flexible name column (and its ellipsis) legal.
      child: SizedBox(
        width: availableWidth - _hPadding * 2,
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: online
                    ? palette.success
                    : colors.mutedForeground.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    contact.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.foreground,
                    ),
                  ),
                  Text(
                    online ? 'Online' : 'Offline',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: online ? palette.success : colors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _sendAndReport(
  BuildContext context,
  TransferController ctrl,
  Contact contact,
  List<OutgoingFile> files,
) async {
  unawaited(showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => ShadDialog.alert(
      title: const Text('Waiting…'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ShadSpinner(size: 22),
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
  if (!context.mounted) return;

  // Toasted, not modal: by this point the send has already been decided, so
  // there is nothing to acknowledge — a dialog here just makes the user click
  // OK before they can get back to the file browser.
  _toast(
    context,
    accepted ? 'Sending…' : 'Declined / timed out',
    accepted
        ? '${contact.name} accepted. Track progress in File Transfer → '
            'Transfers.'
        : '${contact.name} declined or didn’t respond in time.',
    destructive: !accepted,
  );
}

void _toast(
  BuildContext context,
  String title,
  String message, {
  bool destructive = false,
}) {
  final toast = destructive
      ? ShadToast.destructive(
          title: Text(title),
          description: Text(message),
        )
      : ShadToast(title: Text(title), description: Text(message));
  ShadToaster.of(context).show(toast);
}

Future<void> _alert(BuildContext context, String title, String message) {
  if (!context.mounted) return Future.value();
  return showAppDialog<void>(
    context: context,
    builder: (ctx) => ShadDialog.alert(
      title: Text(title),
      description: Text(message),
      actions: [
        ShadButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
