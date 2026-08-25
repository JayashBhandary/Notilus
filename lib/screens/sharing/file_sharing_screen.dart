import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../services/sharing/share_server_controller.dart';

/// The File Sharing page: what is published, who may connect, and what the
/// server is doing right now.
///
/// Configuration and live state sit on one page deliberately. Sharing a folder
/// is the kind of thing people turn on, check that a colleague can reach, and
/// turn off again — splitting "set it up" from "see who's connected" would put
/// the two halves of that single task in different places.
class FileSharingView extends StatefulWidget {
  const FileSharingView({super.key});

  @override
  State<FileSharingView> createState() => _FileSharingViewState();
}

class _FileSharingViewState extends State<FileSharingView> {
  final _controller = ShareServerController.instance;
  List<String> _addresses = const [];
  String? _message;
  bool _messageIsError = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller.load().then((_) {
      if (mounted) _refreshAddresses();
    });
  }

  Future<void> _refreshAddresses() async {
    final addresses = await _controller.localAddresses();
    if (mounted) setState(() => _addresses = addresses);
  }

  void _report(String? error, {String? success}) {
    setState(() {
      _message = error ?? success;
      _messageIsError = error != null;
    });
  }

  Future<void> _toggle() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final error = _controller.running
        ? (await _controller.stop().then((_) => null))
        : await _controller.start();
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      _report(error);
    } else {
      await _refreshAddresses();
      if (mounted) _report(null);
    }
  }

  Future<void> _addFolder() async {
    final picked = await getDirectoryPath(confirmButtonText: 'Share this folder');
    if (picked == null || !mounted) return;
    final error = await _controller.addFolder(picked);
    if (!mounted) return;
    _report(
      error,
      success: error == null && _controller.running
          ? 'Added. Restart sharing for it to appear.'
          : null,
    );
  }

  Future<void> _editFolder(int index) async {
    final folder = _controller.folders[index];
    final result = await _showFolderDialog(context, folder, _controller.users);
    if (result == null || !mounted) return;
    final error = await _controller.updateFolder(index, result);
    if (!mounted) return;
    _report(error);
  }

  /// Puts a seeded account's password on the clipboard.
  ///
  /// Only ever reached for a password Notilus invented: the person connecting
  /// has to type it on the other machine and has never been shown it.
  Future<void> _copyPassword(String name) async {
    final password = await _controller.passwordFor(name);
    if (!mounted) return;
    if (password == null) {
      _report('The password for "$name" isn\'t in the keychain any more. '
          'Set a new one.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: password));
    if (mounted) {
      _report(null, success: 'Password for "$name" copied.');
    }
  }

  Future<void> _addUser() async {
    final result = await _showUserDialog(context);
    if (result == null || !mounted) return;
    final error = await _controller.setUser(result.name, result.password);
    if (!mounted) return;
    _report(error);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        if (!_controller.loaded) {
          return const Center(child: ShadProgress());
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusBar(
              controller: _controller,
              busy: _busy,
              addresses: _addresses,
              onToggle: _busy ? null : _toggle,
            ),
            if (_message != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                color: (_messageIsError ? colors.destructive : colors.primary)
                    .withValues(alpha: 0.10),
                child: Row(
                  children: [
                    Icon(
                      _messageIsError
                          ? LucideIcons.triangleAlert
                          : LucideIcons.info,
                      size: 15,
                      color: _messageIsError
                          ? colors.destructive
                          : colors.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _message!,
                        style: TextStyle(
                          fontSize: 12,
                          color: _messageIsError
                              ? colors.destructive
                              : colors.foreground,
                        ),
                      ),
                    ),
                    ShadIconButton.ghost(
                      width: 26,
                      height: 26,
                      iconSize: 14,
                      onPressed: () => setState(() => _message = null),
                      icon: const Icon(LucideIcons.x),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                children: [
                  _Panel(
                    title: 'Shared folders',
                    subtitle: 'What other devices can see.',
                    action: ShadButton.outline(
                      height: 30,
                      onPressed: _addFolder,
                      leading: const Icon(LucideIcons.folderPlus, size: 14),
                      child: const Text(
                        'Add folder',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    child: _controller.folders.isEmpty
                        ? const _Empty(
                            icon: LucideIcons.folderOpen,
                            title: 'Nothing is shared yet',
                            body: 'Add a folder and it becomes visible to '
                                'anyone on this network who has an account '
                                'below.',
                          )
                        : Column(
                            children: [
                              for (var i = 0;
                                  i < _controller.folders.length;
                                  i++)
                                _FolderRow(
                                  folder: _controller.folders[i],
                                  onEdit: () => _editFolder(i),
                                  onRemove: () =>
                                      _controller.removeFolder(i),
                                ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 16),
                  _Panel(
                    title: 'Who can connect',
                    subtitle: 'Only these accounts, and only to the folders '
                        'above — never the rest of this computer. Passwords '
                        'are kept in this computer\'s keychain, never in a '
                        'settings file.',
                    action: ShadButton.outline(
                      height: 30,
                      onPressed: _addUser,
                      leading: const Icon(LucideIcons.userPlus, size: 14),
                      child: const Text(
                        'Add user',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    child: _controller.users.isEmpty
                        ? const _Empty(
                            icon: LucideIcons.userRound,
                            title: 'No accounts yet',
                            body: 'A share needs at least one. Anonymous '
                                'access is never allowed.',
                          )
                        : Column(
                            children: [
                              for (final user in _controller.users)
                                _UserRow(
                                  name: user.name,
                                  generated: user.generated,
                                  onCopyPassword: () => _copyPassword(user.name),
                                  onChangePassword: () async {
                                    final result = await _showUserDialog(
                                      context,
                                      existingName: user.name,
                                    );
                                    if (result == null || !mounted) return;
                                    final error = await _controller.setUser(
                                      result.name,
                                      result.password,
                                    );
                                    if (mounted) _report(error);
                                  },
                                  onRemove: () =>
                                      _controller.removeUser(user.name),
                                ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 16),
                  _NetworkPanel(
                    controller: _controller,
                    onChanged: _refreshAddresses,
                  ),
                  const SizedBox(height: 16),
                  _ActivityPanel(controller: _controller),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── status ─────────────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.controller,
    required this.busy,
    required this.addresses,
    required this.onToggle,
  });

  final ShareServerController controller;
  final bool busy;
  final List<String> addresses;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final running = controller.running;
    final port = running ? controller.activePort : controller.port;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(
        color: colors.muted,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: running ? const Color(0xFF34C759) : colors.mutedForeground,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  running
                      ? 'Sharing ${_plural(controller.folders.length, 'folder')}'
                      : 'Sharing is off',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: colors.foreground,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  running
                      ? '${_plural(controller.connections, 'device')} connected'
                      : controller.isConfigured
                          ? 'Start sharing to make these folders reachable.'
                          : 'Add a folder and a user to get started.',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.mutedForeground,
                  ),
                ),
                if (running && addresses.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Connect from another device with:',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.mutedForeground,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final address in addresses)
                        _AddressChip(
                          // Non-default ports need to be spelled out, and how
                          // that is written differs by platform, so show the
                          // form each one accepts.
                          text: port == 445
                              ? '\\\\$address'
                              : 'smb://$address:$port',
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: ShadProgress(),
            )
          else if (running)
            ShadButton.destructive(
              onPressed: onToggle,
              leading: const Icon(LucideIcons.square, size: 14),
              child: const Text('Stop sharing'),
            )
          else
            ShadButton(
              onPressed: controller.isConfigured ? onToggle : null,
              leading: const Icon(LucideIcons.play, size: 14),
              child: const Text('Start sharing'),
            ),
        ],
      ),
    );
  }

  static String _plural(int count, String noun) =>
      count == 1 ? '1 $noun' : '$count ${noun}s';
}

class _AddressChip extends StatefulWidget {
  const _AddressChip({required this.text});
  final String text;

  @override
  State<_AddressChip> createState() => _AddressChipState();
}

class _AddressChipState extends State<_AddressChip> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: widget.text));
        if (!mounted) return;
        setState(() => _copied = true);
        // Long enough to read, short enough that the chip doesn't stay in a
        // state that no longer describes anything.
        await Future<void>.delayed(const Duration(seconds: 2));
        if (mounted) setState(() => _copied = false);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: colors.background,
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.text,
              style: TextStyle(
                fontFamily: 'Menlo',
                fontSize: 11.5,
                color: colors.foreground,
              ),
            ),
            const SizedBox(width: 7),
            Icon(
              _copied ? LucideIcons.check : LucideIcons.copy,
              size: 12,
              color: _copied ? const Color(0xFF34C759) : colors.mutedForeground,
            ),
          ],
        ),
      ),
    );
  }
}

// ── panels ─────────────────────────────────────────────────────────────────

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.child,
    this.subtitle,
    this.action,
  });

  final String title;
  final String? subtitle;
  final Widget? action;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 12, 13),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: colors.foreground,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.35,
                            color: colors.mutedForeground,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (action != null) ...[const SizedBox(width: 12), action!],
              ],
            ),
          ),
          const ShadSeparator.horizontal(margin: EdgeInsets.zero, thickness: 1),
          child,
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 26),
      child: Column(
        children: [
          Icon(icon, size: 26, color: colors.mutedForeground),
          const SizedBox(height: 10),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colors.foreground,
            ),
          ),
          const SizedBox(height: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: colors.mutedForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.folder,
    required this.onEdit,
    required this.onRemove,
  });

  final SharedFolder folder;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      child: Row(
        children: [
          Icon(LucideIcons.folder, size: 16, color: colors.mutedForeground),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        folder.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: colors.foreground,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ShadBadge.outline(
                      child: Text(
                        folder.readOnly ? 'Read-only' : 'Read & write',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                    if (folder.isRestricted) ...[
                      const SizedBox(width: 6),
                      ShadBadge.outline(
                        child: Text(
                          folder.allowedUsers.length == 1
                              ? folder.allowedUsers.single
                              : '${folder.allowedUsers.length} accounts',
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    ],
                    if (folder.guestOk) ...[
                      const SizedBox(width: 6),
                      const ShadBadge.outline(
                        child: Text(
                          'Guests',
                          style: TextStyle(fontSize: 10),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  folder.path,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ShadIconButton.ghost(
            width: 30,
            height: 28,
            iconSize: 15,
            onPressed: onEdit,
            icon: const Icon(LucideIcons.settings2),
          ),
          ShadIconButton.ghost(
            width: 30,
            height: 28,
            iconSize: 15,
            onPressed: onRemove,
            icon: const Icon(LucideIcons.trash2),
          ),
        ],
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({
    required this.name,
    required this.onChangePassword,
    required this.onRemove,
    this.generated = false,
    this.onCopyPassword,
  });

  final String name;

  /// Whether the password is still the one Notilus invented — the only case
  /// where showing it is Notilus telling the user something they don't know.
  final bool generated;
  final VoidCallback? onCopyPassword;
  final VoidCallback onChangePassword;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 9, 10, 9),
      child: Row(
        children: [
          Icon(LucideIcons.userRound, size: 16, color: colors.mutedForeground),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(fontSize: 13, color: colors.foreground),
                ),
                if (generated)
                  Text(
                    'This computer\'s account, with a password Notilus made.',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.mutedForeground,
                    ),
                  ),
              ],
            ),
          ),
          if (generated && onCopyPassword != null)
            ShadButton.ghost(
              height: 28,
              onPressed: onCopyPassword,
              child: const Text(
                'Copy password',
                style: TextStyle(fontSize: 11.5),
              ),
            ),
          ShadButton.ghost(
            height: 28,
            onPressed: onChangePassword,
            child: const Text(
              'Change password',
              style: TextStyle(fontSize: 11.5),
            ),
          ),
          ShadIconButton.ghost(
            width: 30,
            height: 28,
            iconSize: 15,
            onPressed: onRemove,
            icon: const Icon(LucideIcons.trash2),
          ),
        ],
      ),
    );
  }
}

class _NetworkPanel extends StatefulWidget {
  const _NetworkPanel({required this.controller, required this.onChanged});

  final ShareServerController controller;
  final VoidCallback onChanged;

  @override
  State<_NetworkPanel> createState() => _NetworkPanelState();
}

class _NetworkPanelState extends State<_NetworkPanel> {
  late final _port = TextEditingController(
    text: '${widget.controller.port}',
  );
  late final _name = TextEditingController(text: widget.controller.serverName);
  late final _workgroup =
      TextEditingController(text: widget.controller.workgroup);

  @override
  void dispose() {
    _port.dispose();
    _name.dispose();
    _workgroup.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    await widget.controller.setNetwork(
      port: int.tryParse(_port.text.trim()),
      serverName: _name.text,
      workgroup: _workgroup.text,
    );
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final controller = widget.controller;
    final port = int.tryParse(_port.text.trim()) ?? controller.port;

    return _Panel(
      title: 'Network',
      subtitle: controller.running
          ? 'Changes apply the next time sharing starts.'
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _LabelledField(
                    label: 'Port',
                    hint: port == 445
                        ? 'Port 445 is where other machines look first, but '
                            'binding it needs administrator rights.'
                        : 'Other devices will need this in the address.',
                    child: ShadInput(
                      controller: _port,
                      placeholder: const Text('4455'),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _commit(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _LabelledField(
                    label: 'Computer name',
                    hint: 'How this machine identifies itself.',
                    child: ShadInput(
                      controller: _name,
                      placeholder: const Text('NOTILUS'),
                      onSubmitted: (_) => _commit(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _LabelledField(
                    label: 'Workgroup',
                    hint: 'Leave as WORKGROUP unless told otherwise.',
                    child: ShadInput(
                      controller: _workgroup,
                      placeholder: const Text('WORKGROUP'),
                      onSubmitted: (_) => _commit(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _Switch(
              label: 'This computer only',
              sublabel: 'Refuse connections from the network. Useful for '
                  'testing before you open it up.',
              value: controller.localOnly,
              onChanged: (value) async {
                await controller.setNetwork(localOnly: value);
                widget.onChanged();
              },
            ),
            const SizedBox(height: 12),
            _Switch(
              label: 'Require signed connections',
              sublabel: 'Every request is verified, so nothing on the network '
                  'can alter a transfer in flight. Turn this off only for a '
                  'client too old to sign.',
              value: controller.requireSigning,
              onChanged: (value) =>
                  controller.setNetwork(requireSigning: value),
            ),
            if (!controller.requireSigning) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: colors.destructive.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: colors.destructive.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  'Unsigned connections can be tampered with by anything on '
                  'the same network. Sign-in itself is still protected.',
                  style: TextStyle(fontSize: 11.5, color: colors.destructive),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActivityPanel extends StatelessWidget {
  const _ActivityPanel({required this.controller});

  final ShareServerController controller;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final activity = controller.activity;

    return _Panel(
      title: 'Activity',
      subtitle: 'Who connected and what moved.',
      action: activity.isEmpty
          ? null
          : ShadButton.ghost(
              height: 28,
              onPressed: controller.clearActivity,
              child: const Text('Clear', style: TextStyle(fontSize: 12)),
            ),
      child: activity.isEmpty
          ? const _Empty(
              icon: LucideIcons.activity,
              title: 'Nothing yet',
              body: 'Connections and transfers appear here while sharing '
                  'is on.',
            )
          : Column(
              children: [
                // Bounded so a busy session doesn't turn the page into an
                // endless log; the rest is still in memory and scrolls here.
                for (final entry in activity.take(40))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 7, 16, 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(
                            _glyph(entry.icon),
                            size: 14,
                            color: entry.isError
                                ? colors.destructive
                                : colors.mutedForeground,
                          ),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.title,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: entry.isError
                                      ? colors.destructive
                                      : colors.foreground,
                                ),
                              ),
                              if (entry.detail.isNotEmpty)
                                Text(
                                  entry.detail,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: colors.mutedForeground,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _time(entry.at),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: colors.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  static IconData _glyph(String tag) => switch (tag) {
        'in' => LucideIcons.logIn,
        'out' => LucideIcons.logOut,
        'up' => LucideIcons.arrowUp,
        'down' => LucideIcons.arrowDown,
        'deny' => LucideIcons.shieldAlert,
        _ => LucideIcons.info,
      };

  static String _time(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }
}

// ── small building blocks ──────────────────────────────────────────────────

class _LabelledField extends StatelessWidget {
  const _LabelledField({required this.label, required this.child, this.hint});

  final String label;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: colors.foreground,
            ),
          ),
        ),
        child,
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              hint!,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.35,
                color: colors.mutedForeground,
              ),
            ),
          ),
      ],
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch({
    required this.label,
    required this.value,
    required this.onChanged,
    this.sublabel,
  });

  final String label;
  final String? sublabel;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 12.5, color: colors.foreground),
              ),
              if (sublabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    sublabel!,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: colors.mutedForeground,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        ShadSwitch(value: value, onChanged: onChanged),
      ],
    );
  }
}

// ── dialogs ────────────────────────────────────────────────────────────────

Future<SharedFolder?> _showFolderDialog(
  BuildContext context,
  SharedFolder folder,
  List<ShareUser> users,
) {
  final name = TextEditingController(text: folder.name);
  var readOnly = folder.readOnly;
  var guestOk = folder.guestOk;
  // Only accounts that still exist can be ticked. A name left over from a
  // deleted account is dropped by saving, which is the user saying who the
  // share is for.
  final chosen = <String>{
    for (final user in users)
      if (folder.allowedUsers
          .any((u) => u.toLowerCase() == user.name.toLowerCase()))
        user.name,
  };
  // No ticks means every account, which is what a one-person setup wants.
  var everyone = chosen.isEmpty;

  return showShadDialog<SharedFolder>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final noneChosen = !everyone && chosen.isEmpty;
        return ShadDialog(
          title: const Text('Share settings'),
          description: Text(folder.path),
          constraints: const BoxConstraints(maxWidth: 420),
          actions: [
            ShadButton.outline(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ShadButton(
              onPressed: noneChosen
                  ? null
                  : () => Navigator.of(ctx).pop(
                        folder.copyWith(
                          name: name.text.trim(),
                          readOnly: readOnly,
                          allowedUsers:
                              everyone ? const [] : chosen.toList(),
                          guestOk: guestOk,
                        ),
                      ),
              child: const Text('Save'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _LabelledField(
                label: 'Share name',
                hint: 'What other devices see in the list of shares.',
                child: ShadInput(controller: name, autofocus: true),
              ),
              const SizedBox(height: 16),
              _Switch(
                label: 'Allow changes',
                sublabel: 'Off means people can open and copy files but not '
                    'add, edit or delete them.',
                value: !readOnly,
                onChanged: (value) => setState(() => readOnly = !value),
              ),
              const SizedBox(height: 16),
              _LabelledField(
                label: 'Who can use it',
                hint: noneChosen
                    ? 'Pick at least one account.'
                    : 'Applies the next time sharing starts.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ShadCheckbox(
                      value: everyone,
                      onChanged: (value) => setState(() {
                        everyone = value;
                        if (value) chosen.clear();
                      }),
                      label: const Text(
                        'Everyone with an account',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                    if (!everyone)
                      for (final user in users)
                        Padding(
                          padding: const EdgeInsets.only(left: 20, top: 6),
                          child: ShadCheckbox(
                            value: chosen.contains(user.name),
                            onChanged: (value) => setState(() {
                              if (value) {
                                chosen.add(user.name);
                              } else {
                                chosen.remove(user.name);
                              }
                            }),
                            label: Text(
                              user.name,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                        ),
                    if (!everyone && users.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 20, top: 6),
                        child: Text(
                          'No accounts yet — add one first.',
                          style: TextStyle(
                            fontSize: 11,
                            color: ShadTheme.of(ctx).colorScheme.mutedForeground,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _Switch(
                label: 'Allow guests',
                sublabel: 'Anyone who can reach this machine may read the '
                    'folder without a password. Guests never write.',
                value: guestOk,
                onChanged: (value) => setState(() => guestOk = value),
              ),
            ],
          ),
        );
      },
    ),
  );
}

typedef _UserResult = ({String name, String password});

Future<_UserResult?> _showUserDialog(
  BuildContext context, {
  String? existingName,
}) {
  final name = TextEditingController(text: existingName ?? '');
  final password = TextEditingController();
  final confirm = TextEditingController();

  return showShadDialog<_UserResult>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final mismatch = confirm.text.isNotEmpty && confirm.text != password.text;
        return ShadDialog(
          title: Text(existingName == null ? 'Add a user' : 'Change password'),
          description: const Text(
            'This is the name and password someone types on the other device.',
          ),
          constraints: const BoxConstraints(maxWidth: 420),
          actions: [
            ShadButton.outline(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ShadButton(
              onPressed: mismatch ||
                      name.text.trim().isEmpty ||
                      password.text.isEmpty
                  ? null
                  : () => Navigator.of(ctx).pop(
                        (name: name.text.trim(), password: password.text),
                      ),
              child: const Text('Save'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _LabelledField(
                label: 'User name',
                child: ShadInput(
                  controller: name,
                  enabled: existingName == null,
                  autofocus: existingName == null,
                  placeholder: const Text('guest'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: 14),
              _LabelledField(
                label: 'Password',
                child: ShadInput(
                  controller: password,
                  obscureText: true,
                  autofocus: existingName != null,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: 14),
              _LabelledField(
                label: 'Repeat password',
                hint: mismatch ? 'These don\'t match.' : null,
                child: ShadInput(
                  controller: confirm,
                  obscureText: true,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
