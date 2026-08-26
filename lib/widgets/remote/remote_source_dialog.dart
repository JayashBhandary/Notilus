import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../models/remote/remote_connection.dart';
import '../../providers/browser_provider.dart';
import '../../services/remote/gdrive_file_system.dart';
import '../../services/remote/remote_file_system.dart';
import '../../services/remote/remote_hub.dart';
import '../../services/remote/remote_path.dart';
import '../../utils/platform.dart';
import '../app_dialog.dart';

/// Adds or edits a remote source.
///
/// Returns the connection id when something was saved, so the caller can jump
/// straight into the new location — adding a source and then having to find it
/// would be a strange place to stop.
Future<String?> showRemoteSourceDialog(
  BuildContext context, {
  RemoteConnection? existing,
}) {
  return showAppDialog<String>(
    context: context,
    barrierColor: const Color(0x66000000),
    barrierLabel: existing == null ? 'Add remote source' : 'Edit remote source',
    animated: false,
    builder: (_) => _RemoteSourceDialog(existing: existing),
  );
}

class _RemoteSourceDialog extends StatefulWidget {
  const _RemoteSourceDialog({this.existing});

  final RemoteConnection? existing;

  @override
  State<_RemoteSourceDialog> createState() => _RemoteSourceDialogState();
}

class _RemoteSourceDialogState extends State<_RemoteSourceDialog> {
  late RemoteKind _kind = widget.existing?.kind ?? RemoteKind.s3;

  final _label = TextEditingController();
  // S3
  final _region = TextEditingController(text: 'us-east-1');
  final _endpoint = TextEditingController();
  final _bucket = TextEditingController();
  final _accessKey = TextEditingController();
  final _secretKey = TextEditingController();
  bool _pathStyle = false;
  // Google Drive
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  String _refreshToken = '';
  // WebDAV
  final _baseUrl = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  // SSH / SFTP
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _keyPath = TextEditingController();
  final _passphrase = TextEditingController();
  final _basePath = TextEditingController();
  // SMB
  final _shareName = TextEditingController();
  final _workgroup = TextEditingController();

  bool _busy = false;
  String? _error;
  String? _notice;

  /// Whether the rarely-needed fields for the current kind are shown. Editing
  /// an existing source opens with them out: whoever set them is the one most
  /// likely to be here to change them.
  late bool _advancedOpen = _isEdit;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing == null) return;
    _label.text = existing.label;
    _region.text = existing.get(RemoteKeys.region, 'us-east-1');
    _endpoint.text = existing.get(RemoteKeys.endpoint);
    _bucket.text = existing.get(RemoteKeys.bucket);
    _pathStyle = existing.getFlag(RemoteKeys.pathStyle);
    _clientId.text = existing.get(RemoteKeys.clientId);
    _baseUrl.text = existing.get(RemoteKeys.baseUrl);
    _username.text = existing.get(RemoteKeys.username);
    _host.text = existing.get(RemoteKeys.host);
    _port.text = existing.get(RemoteKeys.port, '22');
    _keyPath.text = existing.get(RemoteKeys.privateKeyPath);
    _basePath.text = existing.get(RemoteKeys.basePath);
    _shareName.text = existing.get(RemoteKeys.shareName);
    _workgroup.text = existing.get(RemoteKeys.workgroup);
    if (existing.kind == RemoteKind.smb) {
      _port.text = existing.get(RemoteKeys.port, '445');
    }
    // Saved credentials are never read back into the form: the fields stay
    // empty and only overwrite what's in the keychain when the user types
    // something. Round-tripping a secret through a text field just to show
    // dots would take it out of the keychain for no benefit.
    RemoteHub.instance.readSecrets(existing.id).then((secrets) {
      if (!mounted) return;
      setState(() => _refreshToken = secrets[RemoteKeys.refreshToken] ?? '');
    });
  }

  @override
  void dispose() {
    for (final controller in [
      _label,
      _region,
      _endpoint,
      _bucket,
      _accessKey,
      _secretKey,
      _clientId,
      _clientSecret,
      _baseUrl,
      _username,
      _password,
      _host,
      _port,
      _keyPath,
      _passphrase,
      _basePath,
      _shareName,
      _workgroup,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String get _defaultLabel {
    switch (_kind) {
      case RemoteKind.s3:
        final bucket = _bucket.text.trim();
        return bucket.isEmpty ? 'S3' : bucket;
      case RemoteKind.gdrive:
        return 'Google Drive';
      case RemoteKind.sftp:
        final host = _host.text.trim();
        return host.isEmpty ? 'Server' : host;
      case RemoteKind.smb:
        final share = _shareName.text.trim();
        if (share.isNotEmpty) return share;
        final host = _host.text.trim();
        return host.isEmpty ? 'Share' : host;
      case RemoteKind.webdav:
        final host = Uri.tryParse(_baseUrl.text.trim())?.host ?? '';
        return host.isEmpty ? 'WebDAV' : host;
    }
  }

  /// Switches the form to another kind, moving the port to that protocol's
  /// default when the user hasn't typed one of their own.
  void _pickKind(RemoteKind kind) {
    setState(() {
      const defaults = {RemoteKind.sftp: '22', RemoteKind.smb: '445'};
      final current = _port.text.trim();
      if (current.isEmpty || defaults.containsValue(current)) {
        _port.text = defaults[kind] ?? current;
      }
      _kind = kind;
      // Each kind hides different things back there, so a section left open
      // on S3 shouldn't decide what SMB opens with.
      _advancedOpen = false;
    });
  }

  ({RemoteConnection connection, Map<String, String> secrets}) _collect() {
    final id = widget.existing?.id ?? RemoteHub.instance.newId();
    final label =
        _label.text.trim().isEmpty ? _defaultLabel : _label.text.trim();

    switch (_kind) {
      case RemoteKind.s3:
        return (
          connection: RemoteConnection(
            id: id,
            kind: RemoteKind.s3,
            label: label,
            config: {
              RemoteKeys.region: _region.text.trim().isEmpty
                  ? 'us-east-1'
                  : _region.text.trim(),
              RemoteKeys.endpoint: _endpoint.text.trim(),
              RemoteKeys.bucket: _bucket.text.trim(),
              RemoteKeys.pathStyle: '$_pathStyle',
            },
          ),
          secrets: {
            RemoteKeys.accessKeyId: _accessKey.text.trim(),
            RemoteKeys.secretAccessKey: _secretKey.text.trim(),
          },
        );
      case RemoteKind.gdrive:
        return (
          connection: RemoteConnection(
            id: id,
            kind: RemoteKind.gdrive,
            label: label,
            config: {RemoteKeys.clientId: _clientId.text.trim()},
          ),
          secrets: {
            RemoteKeys.clientSecret: _clientSecret.text.trim(),
            RemoteKeys.refreshToken: _refreshToken,
          },
        );
      case RemoteKind.sftp:
        return (
          connection: RemoteConnection(
            id: id,
            kind: RemoteKind.sftp,
            label: label,
            config: {
              RemoteKeys.host: _host.text.trim(),
              RemoteKeys.port: _port.text.trim().isEmpty
                  ? '22'
                  : _port.text.trim(),
              RemoteKeys.username: _username.text.trim(),
              RemoteKeys.privateKeyPath: _keyPath.text.trim(),
              RemoteKeys.basePath: _basePath.text.trim(),
              // Pinned on the first successful connection, and preserved
              // across an edit so changing the label doesn't re-trust a key.
              if (widget.existing != null)
                RemoteKeys.hostKey: widget.existing!.get(RemoteKeys.hostKey),
            },
          ),
          secrets: {
            RemoteKeys.password: _password.text,
            RemoteKeys.passphrase: _passphrase.text,
          },
        );
      case RemoteKind.smb:
        return (
          connection: RemoteConnection(
            id: id,
            kind: RemoteKind.smb,
            label: label,
            config: {
              RemoteKeys.host: _host.text.trim(),
              RemoteKeys.port: _port.text.trim().isEmpty
                  ? '445'
                  : _port.text.trim(),
              RemoteKeys.shareName:
                  _shareName.text.trim().replaceAll(RegExp(r'^[\\/]+|[\\/]+$'), ''),
              RemoteKeys.username: _username.text.trim(),
              RemoteKeys.workgroup: _workgroup.text.trim(),
              RemoteKeys.basePath: _basePath.text.trim(),
            },
          ),
          secrets: {RemoteKeys.password: _password.text},
        );
      case RemoteKind.webdav:
        return (
          connection: RemoteConnection(
            id: id,
            kind: RemoteKind.webdav,
            label: label,
            config: {
              RemoteKeys.baseUrl: _baseUrl.text.trim(),
              RemoteKeys.username: _username.text.trim(),
            },
          ),
          secrets: {RemoteKeys.password: _password.text},
        );
    }
  }

  /// Merges what the form holds with what is already in the keychain, so
  /// editing a source without retyping its secret keeps working.
  Future<Map<String, String>> _mergedSecrets(
    String id,
    Map<String, String> typed,
  ) async {
    if (!_isEdit) return typed;
    final stored = await RemoteHub.instance.readSecrets(id);
    return {
      ...stored,
      for (final e in typed.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
  }

  Future<void> _signInToDrive() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = 'Finish signing in in your browser…';
    });
    try {
      final token = await GoogleDriveFileSystem.signIn(
        clientId: _clientId.text.trim(),
        clientSecret: _clientSecret.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _refreshToken = token;
        _notice = 'Signed in. Save to add this Drive.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _notice = null;
        _error = e is RemoteException ? e.message : '$e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _test() async {
    final collected = _collect();
    final secrets =
        await _mergedSecrets(collected.connection.id, collected.secrets);
    await RemoteHub.instance.test(collected.connection, secrets);
    return true;
  }

  Future<void> _testOnly() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await _test();
      if (mounted) setState(() => _notice = 'Connected.');
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is RemoteException ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final collected = _collect();
    try {
      final secrets =
          await _mergedSecrets(collected.connection.id, collected.secrets);
      // Saving verifies first: a source that can't connect is worse than no
      // source, because it looks mounted in the sidebar and fails later.
      await RemoteHub.instance.test(collected.connection, secrets);
      if (_isEdit) {
        await RemoteHub.instance
            .update(collected.connection, secrets: secrets);
      } else {
        await RemoteHub.instance.add(collected.connection, secrets);
      }
      if (!mounted) return;
      Navigator.of(context).pop(collected.connection.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is RemoteException ? e.message : '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    // A phone fits the form or the chrome around it, not both: what follows
    // spends the space on the fields.
    final compact = isMobilePlatform;
    final advanced = _advancedFields(_kind);

    final test = ShadButton.secondary(
      onPressed: _busy ? null : _testOnly,
      child: const Text('Test'),
    );
    final save = ShadButton(
      onPressed: _busy ? null : _save,
      child: Text(_isEdit ? 'Save' : 'Add'),
    );

    return ShadDialog(
      title: Text(_isEdit ? 'Edit source' : 'Add a remote source'),
      // Two centred lines and a gap to say what the title says. Worth it on a
      // desktop, where they cost nothing; not on a phone, where they cost a
      // field.
      description: compact
          ? null
          : const Text(
              'Browse cloud storage next to your local folders, and copy '
              'between them the same way.',
            ),
      // Shad centres a dialog's title below its 640px breakpoint. A form reads
      // from the left edge that its own labels start at.
      titleTextAlign: TextAlign.start,
      constraints: BoxConstraints(maxWidth: 480, maxHeight: maxHeight),
      scrollable: true,
      titlePinned: true,
      // Below that same breakpoint Shad stacks the actions full-width, which
      // turned three buttons into a third of a phone screen. Two of them fit
      // one row — and Cancel is what the close button in the corner already
      // does, so on a phone it goes.
      actionsAxis: compact ? Axis.horizontal : null,
      actionsMainAxisSize: compact ? MainAxisSize.max : null,
      expandActionsWhenTiny: compact ? false : null,
      actions: compact
          ? [Expanded(child: test), Expanded(child: save)]
          : [
              ShadButton.outline(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              test,
              save,
            ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_isEdit) ...[
            _KindPicker(
              selected: _kind,
              onChanged: _pickKind,
            ),
            const SizedBox(height: 14),
          ],
          _Field(
            label: 'Name',
            // The placeholder already shows the name it will take, so on a
            // phone this hint is a line that adds nothing.
            hint: compact ? null : 'Shown in the sidebar',
            child: ShadInput(
              controller: _label,
              placeholder: Text(_defaultLabel),
            ),
          ),
          const SizedBox(height: 12),
          ..._basicFields(_kind),
          // What is left is for self-hosted servers and unusual setups: real
          // settings, but ones that made the common case read as a wall of
          // fields with the buttons pushed off the bottom.
          if (advanced.isNotEmpty) ...[
            const SizedBox(height: 6),
            _Disclosure(
              label: 'Advanced',
              open: _advancedOpen,
              onToggle: () => setState(() => _advancedOpen = !_advancedOpen),
            ),
            if (_advancedOpen) ...[
              const SizedBox(height: 12),
              ...advanced,
            ],
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            _Banner(text: _error!, tone: colors.destructive),
          ],
          if (_notice != null) ...[
            const SizedBox(height: 14),
            _Banner(text: _notice!, tone: colors.primary),
          ],
        ],
      ),
    );
  }

  /// The fields every setup of [kind] has to fill in.
  List<Widget> _basicFields(RemoteKind kind) {
    switch (kind) {
      case RemoteKind.s3:
        return [
          _Field(
            label: 'Access key ID',
            child: ShadInput(
              controller: _accessKey,
              placeholder: Text(_isEdit ? 'Unchanged' : 'AKIA…'),
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'Secret access key',
            child: ShadInput(
              controller: _secretKey,
              obscureText: true,
              placeholder: Text(_isEdit ? 'Unchanged' : ''),
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'Region',
            child: ShadInput(
              controller: _region,
              placeholder: const Text('us-east-1'),
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'Bucket',
            hint: 'Leave empty to browse every bucket in the account.',
            child: ShadInput(
              controller: _bucket,
              placeholder: const Text('my-bucket'),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ];
      case RemoteKind.gdrive:
        return [
          _Field(
            label: 'OAuth client ID',
            hint: 'From a "Desktop app" client in Google Cloud Console.',
            child: ShadInput(
              controller: _clientId,
              placeholder: const Text('…apps.googleusercontent.com'),
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'OAuth client secret',
            child: ShadInput(
              controller: _clientSecret,
              obscureText: true,
              placeholder: Text(_isEdit ? 'Unchanged' : 'GOCSPX-…'),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              ShadButton.secondary(
                onPressed: _busy ? null : _signInToDrive,
                leading: const Icon(LucideIcons.logIn, size: 15),
                child: Text(
                  _refreshToken.isEmpty ? 'Sign in with Google' : 'Sign in again',
                ),
              ),
              const SizedBox(width: 10),
              if (_refreshToken.isNotEmpty)
                const _Chip(icon: LucideIcons.check, label: 'Signed in'),
            ],
          ),
        ];
      case RemoteKind.sftp:
        return [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: _Field(
                  label: 'Host',
                  child: ShadInput(
                    controller: _host,
                    placeholder: const Text('vps.example.com'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Field(
                  label: 'Port',
                  child: ShadInput(
                    controller: _port,
                    placeholder: const Text('22'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'Username',
            child: ShadInput(
              controller: _username,
              placeholder: const Text('root'),
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'Private key file',
            hint: 'Leave empty to sign in with a password.',
            child: ShadInput(
              controller: _keyPath,
              placeholder: const Text('~/.ssh/id_ed25519'),
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'Password',
            hint: 'Used when there is no key, or the key is refused.',
            child: ShadInput(
              controller: _password,
              obscureText: true,
              placeholder: Text(_isEdit ? 'Unchanged' : ''),
            ),
          ),
        ];
      case RemoteKind.smb:
        return [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: _Field(
                  label: 'Server',
                  hint: 'A name or an IP address — no \\\\ needed.',
                  child: ShadInput(
                    controller: _host,
                    placeholder: const Text('nas.local'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Field(
                  label: 'Port',
                  child: ShadInput(
                    controller: _port,
                    placeholder: const Text('445'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'Share',
            hint: 'The folder the server publishes — the "Files" in '
                '\\\\nas.local\\Files.',
            child: ShadInput(
              controller: _shareName,
              placeholder: const Text('Files'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'Username',
            child: ShadInput(
              controller: _username,
              placeholder: const Text('you'),
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'Password',
            child: ShadInput(
              controller: _password,
              obscureText: true,
              placeholder: Text(_isEdit ? 'Unchanged' : ''),
            ),
          ),
        ];
      case RemoteKind.webdav:
        return [
          _Field(
            label: 'Server URL',
            hint: 'Nextcloud: https://host/remote.php/dav/files/<user>',
            child: ShadInput(
              controller: _baseUrl,
              placeholder: const Text('https://cloud.example.com/remote.php/dav'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'Username',
            child: ShadInput(controller: _username),
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'Password or app token',
            child: ShadInput(
              controller: _password,
              obscureText: true,
              placeholder: Text(_isEdit ? 'Unchanged' : ''),
            ),
          ),
        ];
    }
  }

  /// The fields a self-hosted server or an unusual setup needs, and the rest of
  /// the time doesn't. Kept behind a disclosure so the common path is short.
  List<Widget> _advancedFields(RemoteKind kind) {
    switch (kind) {
      case RemoteKind.s3:
        return [
          _Field(
            label: 'Endpoint',
            hint: 'For MinIO, R2, Wasabi, Spaces… Leave empty for AWS.',
            child: ShadInput(
              controller: _endpoint,
              placeholder: const Text('https://minio.example.com'),
            ),
          ),
          const SizedBox(height: 12),
          _Toggle(
            label: 'Force path-style URLs',
            sublabel: 'Needed by most self-hosted servers. AWS uses '
                'virtual-hosted style.',
            value: _pathStyle,
            onChanged: (v) => setState(() => _pathStyle = v),
          ),
        ];
      case RemoteKind.sftp:
        return [
          _Field(
            label: 'Key passphrase',
            child: ShadInput(
              controller: _passphrase,
              obscureText: true,
              placeholder: Text(_isEdit ? 'Unchanged' : 'If the key has one'),
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'Start folder',
            hint: 'Empty opens your home directory, the same as `sftp`. '
                'Use / to browse the whole server.',
            child: ShadInput(
              controller: _basePath,
              placeholder: const Text('/var/www'),
            ),
          ),
          if (_isEdit &&
              (widget.existing?.get(RemoteKeys.hostKey) ?? '').isNotEmpty) ...[
            const SizedBox(height: 12),
            _Field(
              label: 'Pinned host key',
              hint: 'Recorded on the first connection. Notilus refuses to '
                  'connect if the server presents a different one.',
              child: Text(
                widget.existing!.get(RemoteKeys.hostKey),
                style: const TextStyle(fontSize: 11.5),
              ),
            ),
          ],
        ];
      case RemoteKind.smb:
        return [
          _Field(
            label: 'Workgroup or domain',
            hint: 'Leave empty unless the server asked for one.',
            child: ShadInput(
              controller: _workgroup,
              placeholder: const Text('WORKGROUP'),
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            label: 'Start folder',
            hint: 'Empty opens the top of the share.',
            child: ShadInput(
              controller: _basePath,
              placeholder: const Text('Projects'),
            ),
          ),
        ];
      case RemoteKind.gdrive:
      case RemoteKind.webdav:
        return const [];
    }
  }
}

/// Confirms and removes a source. The files themselves are untouched — this
/// only forgets the credentials and the mount.
Future<void> confirmRemoveRemote(
  BuildContext context,
  RemoteConnection connection,
) async {
  final browser = context.read<BrowserProvider>();
  final home = browser.shortcuts['Home'];
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => ShadDialog.alert(
      title: Text('Remove "${connection.label}"?'),
      description: const Text(
        'Notilus forgets the credentials and stops showing this source. '
        'Nothing stored on the service is deleted.',
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        ShadButton.destructive(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  // Walk away from the source before it disappears, or the browser is left
  // pointing at a path nothing can list.
  if (VPath.connectionOf(browser.currentPath) == connection.id &&
      home != null) {
    await browser.navigateTo(home);
  }
  await RemoteHub.instance.remove(connection.id);
}

// ── small building blocks ──────────────────────────────────────────────────

class _KindPicker extends StatelessWidget {
  const _KindPicker({required this.selected, required this.onChanged});

  final RemoteKind selected;
  final ValueChanged<RemoteKind> onChanged;

  @override
  Widget build(BuildContext context) {
    // Five buttons wrap to two rows on a phone, which put 100px of chrome
    // above a form that had none to spare. One row that names the current
    // choice says the same thing.
    if (isMobilePlatform) {
      return _Field(
        label: 'Type',
        child: ShadSelect<RemoteKind>(
          initialValue: selected,
          onChanged: (kind) {
            if (kind != null) onChanged(kind);
          },
          options: [
            for (final kind in RemoteKind.values)
              ShadOption(
                value: kind,
                child: _KindLabel(kind: kind),
              ),
          ],
          selectedOptionBuilder: (context, kind) => _KindLabel(kind: kind),
        ),
      );
    }

    // Wrap rather than a Row of Expandeds: four buttons with icons don't fit
    // one line at a large OS text size, and a second row is better than four
    // clipped labels.
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final kind in RemoteKind.values)
          kind == selected
              ? ShadButton(
                  onPressed: () => onChanged(kind),
                  leading: Icon(kind.icon, size: 15),
                  child: Text(_short(kind)),
                )
              : ShadButton.outline(
                  onPressed: () => onChanged(kind),
                  leading: Icon(kind.icon, size: 15),
                  child: Text(_short(kind)),
                ),
      ],
    );
  }

  static String _short(RemoteKind kind) {
    switch (kind) {
      case RemoteKind.s3:
        return 'S3';
      case RemoteKind.gdrive:
        return 'Drive';
      case RemoteKind.sftp:
        return 'SSH';
      case RemoteKind.smb:
        return 'SMB';
      case RemoteKind.webdav:
        return 'WebDAV';
    }
  }
}

/// A source kind as an icon and its full name, for the phone's picker. The
/// short names the buttons use ("SSH", "SMB") are there because a button is
/// narrow; a row of its own has the width to say what it is.
class _KindLabel extends StatelessWidget {
  const _KindLabel({required this.kind});

  final RemoteKind kind;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(kind.icon, size: 16, color: colors.primary),
        const SizedBox(width: 8),
        Text(_long(kind)),
      ],
    );
  }

  static String _long(RemoteKind kind) {
    switch (kind) {
      case RemoteKind.s3:
        return 'S3 or compatible';
      case RemoteKind.gdrive:
        return 'Google Drive';
      case RemoteKind.sftp:
        return 'SSH / SFTP';
      case RemoteKind.smb:
        return 'SMB share';
      case RemoteKind.webdav:
        return 'WebDAV';
    }
  }
}

/// The header for a group of fields that is usually left alone.
class _Disclosure extends StatelessWidget {
  const _Disclosure({
    required this.label,
    required this.open,
    required this.onToggle,
  });

  final String label;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: ShadButton.link(
        onPressed: onToggle,
        padding: EdgeInsets.zero,
        trailing: Icon(
          open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
          size: 14,
          color: colors.mutedForeground,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: colors.mutedForeground,
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child, this.hint});

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
              style: TextStyle(fontSize: 11, color: colors.mutedForeground),
            ),
          ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
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

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.tone});

  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: tone)),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: colors.primary),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 11.5, color: colors.mutedForeground),
        ),
      ],
    );
  }
}
