import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/transfer/contact.dart';
import '../../providers/transfer_controller.dart';
import '../../services/system_info_service.dart' show formatBytes;
import '../../services/transfer/file_transfer.dart';
import '../../theme.dart';

/// Contacts + presence page (center view). Shows this machine's shareable
/// identity (name, QR, code) and the saved peers with online/offline status.
class TransferScreen extends StatelessWidget {
  const TransferScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TransferController>();
    final palette = AppColors.of(context);

    Widget body;
    if (!t.isConfigured) {
      body = _Hint(
        palette: palette,
        icon: CupertinoIcons.gear_alt,
        title: 'Set up file transfer',
        message:
            'Fill in your Firebase details in\nlib/config/transfer_config.dart, '
            'then restart Notilus.',
      );
    } else if (t.error != null) {
      body = _Hint(
        palette: palette,
        icon: CupertinoIcons.exclamationmark_triangle,
        title: 'Couldn\'t connect',
        message: t.error!,
      );
    } else if (!t.ready) {
      body = const Center(child: CupertinoActivityIndicator());
    } else {
      body = _Ready(palette: palette);
    }

    return Container(color: palette.contentBg, child: body);
  }
}

class _Ready extends StatelessWidget {
  const _Ready({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TransferController>();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      children: [
        _MyDeviceCard(palette: palette),
        const SizedBox(height: 24),
        Row(
          children: [
            Text(
              'Contacts',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: palette.subtleText,
              ),
            ),
            const Spacer(),
            _SmallButton(
              icon: CupertinoIcons.person_add,
              label: 'Add',
              palette: palette,
              onTap: () => _showAddContact(context),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (t.contacts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No contacts yet. Share your code with a friend, and paste '
              'theirs with “Add”.',
              style: TextStyle(fontSize: 12.5, color: palette.subtleText, height: 1.4),
            ),
          )
        else
          ...t.contacts.map((c) => _ContactTile(contact: c, palette: palette)),
        if (t.transfers.isNotEmpty) ...[
          const SizedBox(height: 24),
          Row(
            children: [
              Text(
                'Transfers',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: palette.subtleText,
                ),
              ),
              const Spacer(),
              if (t.transfers.values.any((p) => p.isFinished))
                _SmallButton(
                  icon: CupertinoIcons.clear,
                  label: 'Clear finished',
                  palette: palette,
                  onTap: t.clearFinishedTransfers,
                ),
            ],
          ),
          const SizedBox(height: 8),
          ...t.transfers.entries.map((e) => _TransferTile(
                sessionId: e.key,
                progress: e.value,
                palette: palette,
              )),
        ],
      ],
    );
  }
}

/// One live or finished transfer: direction, overall bar, per-file lines, and a
/// cancel button while it's still running.
class _TransferTile extends StatelessWidget {
  const _TransferTile({
    required this.sessionId,
    required this.progress,
    required this.palette,
  });

  final String sessionId;
  final BatchProgress progress;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final active = !progress.isFinished;
    final n = progress.fileCount;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: palette.cardBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                progress.sending
                    ? CupertinoIcons.arrow_up_circle
                    : CupertinoIcons.arrow_down_circle,
                size: 16,
                color: palette.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${progress.sending ? 'Sending' : 'Receiving'} '
                  '$n file${n == 1 ? '' : 's'} · ${formatBytes(progress.totalBytes)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
              ),
              Text(
                _statusLabel(progress.status),
                style: TextStyle(
                  fontSize: 11,
                  color: _statusColor(progress.status, palette),
                ),
              ),
              if (active)
                _IconTap(
                  icon: CupertinoIcons.xmark_circle,
                  palette: palette,
                  onTap: () =>
                      context.read<TransferController>().cancelTransfer(sessionId),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _Bar(fraction: progress.fraction, palette: palette),
          if (progress.error != null) ...[
            const SizedBox(height: 6),
            Text(
              progress.error!,
              style: const TextStyle(
                fontSize: 11.5,
                color: CupertinoColors.systemRed,
              ),
            ),
          ],
          for (final f in progress.files) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    f.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: palette.subtleText),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  f.error ?? '${(f.fraction * 100).round()}%',
                  style: TextStyle(
                    fontSize: 11,
                    color: f.status == TransferStatus.failed
                        ? CupertinoColors.systemRed
                        : palette.subtleText,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _statusLabel(TransferStatus s) => switch (s) {
        TransferStatus.pending => 'Connecting…',
        TransferStatus.active => 'In progress',
        TransferStatus.done => 'Done',
        TransferStatus.failed => 'Failed',
        TransferStatus.cancelled => 'Cancelled',
      };

  static Color _statusColor(TransferStatus s, AppPalette palette) => switch (s) {
        TransferStatus.done => palette.success,
        TransferStatus.failed => CupertinoColors.systemRed,
        TransferStatus.cancelled => palette.subtleText,
        _ => palette.accent,
      };
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.palette});
  final double fraction;
  final AppPalette palette;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Container(
          height: 5,
          color: palette.divider,
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: fraction.clamp(0.0, 1.0),
            child: Container(color: palette.accent),
          ),
        ),
      );
}

class _MyDeviceCard extends StatelessWidget {
  const _MyDeviceCard({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TransferController>();
    final code = t.myShareCode ?? '';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.cardBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // QR on white so it stays scannable in dark mode.
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFFFF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: code.isEmpty
                ? const SizedBox(width: 128, height: 128)
                : QrImageView(
                    data: code,
                    version: QrVersions.auto,
                    size: 128,
                    backgroundColor: const Color(0xFFFFFFFF),
                  ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _Dot(online: true, palette: palette),
                    const SizedBox(width: 6),
                    Text(
                      'This device',
                      style: TextStyle(fontSize: 11, color: palette.subtleText),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        t.myName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: palette.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    _IconTap(
                      icon: CupertinoIcons.pencil,
                      palette: palette,
                      onTap: () => _showEditName(context, t.myName),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Your code — share it once so friends can add you:',
                  style: TextStyle(fontSize: 11, color: palette.subtleText),
                ),
                const SizedBox(height: 6),
                _CodeBox(code: code, palette: palette),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.code, required this.palette});
  final String code;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: palette.contentBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              code,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'Menlo',
                color: palette.subtleText,
              ),
            ),
          ),
          _IconTap(
            icon: CupertinoIcons.doc_on_doc,
            palette: palette,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: code));
            },
          ),
        ],
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact, required this.palette});
  final Contact contact;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TransferController>();
    final online = t.isOnline(contact.deviceId);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: palette.cardBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _Dot(online: online, palette: palette),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  contact.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
                Text(
                  online ? 'Online' : 'Offline',
                  style: TextStyle(
                    fontSize: 11,
                    color: online ? palette.success : palette.subtleText,
                  ),
                ),
              ],
            ),
          ),
          _IconTap(
            icon: CupertinoIcons.ellipsis,
            palette: palette,
            onTap: () => _showContactActions(context, contact),
          ),
        ],
      ),
    );
  }
}

// ── small shared bits ─────────────────────────────────────────────────────

class _Dot extends StatelessWidget {
  const _Dot({required this.online, required this.palette});
  final bool online;
  final AppPalette palette;
  @override
  Widget build(BuildContext context) => Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: online ? palette.success : palette.subtleText.withValues(alpha: 0.4),
        ),
      );
}

class _IconTap extends StatelessWidget {
  const _IconTap({required this.icon, required this.palette, required this.onTap});
  final IconData icon;
  final AppPalette palette;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => CupertinoButton(
        padding: const EdgeInsets.all(6),
        minimumSize: Size.zero,
        onPressed: onTap,
        child: Icon(icon, size: 16, color: palette.subtleText),
      );
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.icon,
    required this.label,
    required this.palette,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final AppPalette palette;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        onPressed: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: palette.accent),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 13, color: palette.accent)),
          ],
        ),
      );
}

class _Hint extends StatelessWidget {
  const _Hint({
    required this.palette,
    required this.icon,
    required this.title,
    required this.message,
  });
  final AppPalette palette;
  final IconData icon;
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 34, color: palette.subtleText),
              const SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: palette.subtleText, height: 1.5),
              ),
            ],
          ),
        ),
      );
}

// ── dialogs / action sheets ────────────────────────────────────────────────

Future<void> _showEditName(BuildContext context, String current) async {
  final controller = TextEditingController(text: current);
  final name = await showCupertinoDialog<String>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: const Text('Device name'),
      content: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: CupertinoTextField(controller: controller, autofocus: true),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (name != null && name.trim().isNotEmpty && context.mounted) {
    await context.read<TransferController>().setDisplayName(name);
  }
}

Future<void> _showAddContact(BuildContext context) async {
  final nameCtl = TextEditingController();
  final codeCtl = TextEditingController();
  final result = await showCupertinoDialog<bool>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: const Text('Add contact'),
      content: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoTextField(
              controller: nameCtl,
              placeholder: 'Name (e.g. Bob’s laptop)',
              autofocus: true,
            ),
            const SizedBox(height: 8),
            CupertinoTextField(
              controller: codeCtl,
              placeholder: 'Paste their code',
              maxLines: 3,
            ),
          ],
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Add'),
        ),
      ],
    ),
  );
  if (result != true || !context.mounted) return;
  final err = await context.read<TransferController>().addContactFromCode(
        codeCtl.text,
        name: nameCtl.text,
      );
  if (err != null && context.mounted) {
    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Couldn’t add contact'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(err),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

Future<void> _showContactActions(BuildContext context, Contact contact) async {
  final action = await showCupertinoModalPopup<String>(
    context: context,
    builder: (ctx) => CupertinoActionSheet(
      title: Text(contact.name),
      actions: [
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx, 'rename'),
          child: const Text('Rename'),
        ),
        CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(ctx, 'remove'),
          child: const Text('Remove'),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('Cancel'),
      ),
    ),
  );
  if (!context.mounted) return;
  final ctrl = context.read<TransferController>();
  if (action == 'remove') {
    await ctrl.removeContact(contact.deviceId);
  } else if (action == 'rename') {
    final nameCtl = TextEditingController(text: contact.name);
    final name = await showCupertinoDialog<String>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Rename contact'),
        content: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: CupertinoTextField(controller: nameCtl, autofocus: true),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, nameCtl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await ctrl.renameContact(contact.deviceId, name);
    }
  }
}

