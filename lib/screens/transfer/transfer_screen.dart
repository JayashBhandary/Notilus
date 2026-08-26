import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../models/transfer/contact.dart';
import '../../providers/transfer_controller.dart';
import '../../services/system_info_service.dart' show formatBytes;
import '../../services/transfer/file_transfer.dart';
import '../../theme.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/shad_spinner.dart';

/// Contacts + presence page (center view). Shows this machine's shareable
/// identity (name, QR, code) and the saved peers with online/offline status.
class TransferScreen extends StatelessWidget {
  const TransferScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TransferController>();
    final colors = ShadTheme.of(context).colorScheme;

    Widget body;
    if (!t.isConfigured) {
      body = const _Hint(
        icon: LucideIcons.settings,
        title: 'Set up file transfer',
        message:
            'Fill in your Firebase details in\nlib/config/transfer_config.dart, '
            'then restart Notilus.',
      );
    } else if (t.error != null) {
      body = _Hint(
        icon: LucideIcons.triangleAlert,
        title: 'Couldn\'t connect',
        message: t.error!,
      );
    } else if (!t.ready) {
      body = const Center(child: ShadSpinner(size: 22));
    } else {
      body = const _Ready();
    }

    return Container(color: colors.background, child: body);
  }
}

class _Ready extends StatelessWidget {
  const _Ready();

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TransferController>();
    final colors = ShadTheme.of(context).colorScheme;
    final sectionStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
      color: colors.mutedForeground,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      children: [
        const _MyDeviceCard(),
        const SizedBox(height: 24),
        Row(
          children: [
            Text('Contacts', style: sectionStyle),
            const Spacer(),
            _SmallButton(
              icon: LucideIcons.userPlus,
              label: 'Add',
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
              style: TextStyle(
                fontSize: 12.5,
                color: colors.mutedForeground,
                height: 1.4,
              ),
            ),
          )
        else
          ...t.contacts.map((c) => _ContactTile(contact: c)),
        if (t.transfers.isNotEmpty) ...[
          const SizedBox(height: 24),
          Row(
            children: [
              Text('Transfers', style: sectionStyle),
              const Spacer(),
              if (t.transfers.values.any((p) => p.isFinished))
                _SmallButton(
                  icon: LucideIcons.x,
                  label: 'Clear finished',
                  onTap: t.clearFinishedTransfers,
                ),
            ],
          ),
          const SizedBox(height: 8),
          ...t.transfers.entries.map(
            (e) => _TransferTile(sessionId: e.key, progress: e.value),
          ),
        ],
      ],
    );
  }
}

/// One live or finished transfer: direction, overall bar, per-file lines, and a
/// cancel button while it's still running.
class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.sessionId, required this.progress});

  final String sessionId;
  final BatchProgress progress;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    final active = !progress.isFinished;
    final n = progress.fileCount;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ShadCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  progress.sending
                      ? LucideIcons.circleArrowUp
                      : LucideIcons.circleArrowDown,
                  size: 16,
                  color: colors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${progress.sending ? 'Sending' : 'Receiving'} '
                    '$n file${n == 1 ? '' : 's'} · ${formatBytes(progress.totalBytes)}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.foreground,
                    ),
                  ),
                ),
                Text(
                  _statusLabel(progress.status),
                  style: TextStyle(
                    fontSize: 11,
                    color: _statusColor(progress.status, palette, colors),
                  ),
                ),
                if (active)
                  _IconTap(
                    icon: LucideIcons.circleX,
                    onTap: () => context
                        .read<TransferController>()
                        .cancelTransfer(sessionId),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ShadProgress(
              value: progress.fraction.clamp(0.0, 1.0),
              minHeight: 5,
            ),
            if (progress.error != null) ...[
              const SizedBox(height: 6),
              Text(
                progress.error!,
                style: TextStyle(fontSize: 11.5, color: colors.destructive),
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
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.mutedForeground,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    f.error ?? '${(f.fraction * 100).round()}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: f.status == TransferStatus.failed
                          ? colors.destructive
                          : colors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
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

  static Color _statusColor(
    TransferStatus s,
    AppPalette palette,
    ShadColorScheme colors,
  ) =>
      switch (s) {
        TransferStatus.done => palette.success,
        TransferStatus.failed => colors.destructive,
        TransferStatus.cancelled => colors.mutedForeground,
        _ => colors.primary,
      };
}

class _MyDeviceCard extends StatelessWidget {
  const _MyDeviceCard();

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TransferController>();
    final colors = ShadTheme.of(context).colorScheme;
    final code = t.myCode ?? '';
    return ShadCard(
      padding: const EdgeInsets.all(16),
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
                    const _Dot(online: true),
                    const SizedBox(width: 6),
                    Text(
                      'This device',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.mutedForeground,
                      ),
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
                          color: colors.foreground,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    _IconTap(
                      icon: LucideIcons.pencil,
                      tooltip: 'Rename this device',
                      onTap: () => _showEditName(context, t.myName),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Your machine code — share it so friends can add you:',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 6),
                _CodeBox(code: code),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: colors.background,
        border: Border.all(color: colors.border),
        borderRadius: theme.radius,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              code,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'Menlo',
                fontWeight: FontWeight.w600,
                color: colors.foreground,
              ),
            ),
          ),
          _IconTap(
            icon: LucideIcons.copy,
            tooltip: 'Copy code',
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: code));
            },
          ),
        ],
      ),
    );
  }
}

/// A saved peer. Stateful only to own the overflow popover's controller — the
/// menu anchors to the … button, so it has to live in the tree beside it rather
/// than being pushed as a route the way the old action sheet was.
class _ContactTile extends StatefulWidget {
  const _ContactTile({required this.contact});
  final Contact contact;

  @override
  State<_ContactTile> createState() => _ContactTileState();
}

class _ContactTileState extends State<_ContactTile> {
  final _menu = ShadPopoverController();

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  Future<void> _rename() async {
    _menu.hide();
    final name = await _promptForName(
      context,
      title: 'Rename contact',
      initial: widget.contact.name,
    );
    if (name == null || !mounted) return;
    await context
        .read<TransferController>()
        .renameContact(widget.contact.code, name);
  }

  Future<void> _remove() async {
    _menu.hide();
    await context.read<TransferController>().removeContact(widget.contact.code);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    final t = context.watch<TransferController>();
    final online = t.isOnline(widget.contact.code);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ShadCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            _Dot(online: online),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.contact.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colors.foreground,
                    ),
                  ),
                  Text(
                    '${online ? 'Online' : 'Offline'} · ${widget.contact.code}',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'Menlo',
                      color: online
                          ? palette.success
                          : colors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
            ShadPopover(
              controller: _menu,
              padding: const EdgeInsets.symmetric(vertical: 4),
              popover: (_) => SizedBox(
                width: 150,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _MenuItem(label: 'Rename', onPressed: _rename),
                    _MenuItem(
                      label: 'Remove',
                      destructive: true,
                      onPressed: _remove,
                    ),
                  ],
                ),
              ),
              child: _IconTap(
                icon: LucideIcons.ellipsis,
                tooltip: 'More',
                onTap: _menu.toggle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One row of the contact overflow popover. Left-aligned and full-width, which
/// `ShadButton.ghost` does not do by default.
class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });
  final String label;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return ShadButton.ghost(
      onPressed: onPressed,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      mainAxisAlignment: MainAxisAlignment.start,
      foregroundColor: destructive ? colors.destructive : colors.foreground,
      child: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }
}

// ── small shared bits ─────────────────────────────────────────────────────

class _Dot extends StatelessWidget {
  const _Dot({required this.online});
  final bool online;
  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: online
            ? palette.success
            : colors.mutedForeground.withValues(alpha: 0.4),
      ),
    );
  }
}

class _IconTap extends StatelessWidget {
  const _IconTap({required this.icon, required this.onTap, this.tooltip});
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final button = ShadIconButton.ghost(
      width: 28,
      height: 28,
      padding: EdgeInsets.zero,
      iconSize: 16,
      foregroundColor: colors.mutedForeground,
      onPressed: onTap,
      icon: Icon(icon),
    );
    if (tooltip == null) return button;
    return ShadTooltip(
      builder: (_) => Text(tooltip!, style: const TextStyle(fontSize: 11.5)),
      child: button,
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ShadButton.ghost(
        onPressed: onTap,
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        leading: Icon(icon, size: 14),
        child: Text(label, style: const TextStyle(fontSize: 13)),
      );
}

/// Full-pane empty/error state. Deliberately a centered column rather than a
/// [ShadAlert]: an alert is an inline callout strip, which reads as a banner
/// floating in dead space when it is the only thing in the pane.
class _Hint extends StatelessWidget {
  const _Hint({
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: colors.mutedForeground),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: colors.foreground,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: colors.mutedForeground,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── dialogs ───────────────────────────────────────────────────────────────

/// Shared single-field name prompt, used by both "rename this device" and
/// "rename contact". Returns null on cancel or when the field is left blank.
Future<String?> _promptForName(
  BuildContext context, {
  required String title,
  required String initial,
}) async {
  final controller = TextEditingController(text: initial);
  final name = await showAppDialog<String>(
    context: context,
    builder: (ctx) => ShadDialog.alert(
      title: Text(title),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        ShadButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('Save'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: ShadInput(controller: controller, autofocus: true),
      ),
    ),
  );
  final trimmed = name?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : name;
}

Future<void> _showEditName(BuildContext context, String current) async {
  final name = await _promptForName(
    context,
    title: 'Device name',
    initial: current,
  );
  if (name == null || !context.mounted) return;
  await context.read<TransferController>().setDisplayName(name);
}

Future<void> _showAddContact(BuildContext context) async {
  final nameCtl = TextEditingController();
  final codeCtl = TextEditingController();
  final result = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => ShadDialog.alert(
      title: const Text('Add contact'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        ShadButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Add'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShadInput(
              controller: nameCtl,
              placeholder: const Text('Name (e.g. Bob’s laptop)'),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            ShadInput(
              controller: codeCtl,
              placeholder: const Text('Their machine code (a2:b1:c4:…)'),
            ),
          ],
        ),
      ),
    ),
  );
  if (result != true || !context.mounted) return;

  // Resolving a code hits the network (LAN broadcast, then Firebase), so show a
  // brief spinner while we look the peer up.
  final ctrl = context.read<TransferController>();
  showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const ShadDialog.alert(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: ShadSpinner(size: 22)),
      ),
    ),
  );
  final err = await ctrl.addByCode(codeCtl.text, name: nameCtl.text);
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop(); // spinner
  if (err != null && context.mounted) {
    await showAppDialog<void>(
      context: context,
      builder: (ctx) => ShadDialog.alert(
        title: const Text('Couldn’t add contact'),
        description: Text(err),
        actions: [
          ShadButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
