import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../providers/browser_provider.dart';
import '../services/remote/remote_hub.dart';
import '../services/remote/remote_path.dart';
import '../theme.dart';
import '../utils/platform.dart';

/// Lets Cmd/Ctrl+L put the status bar into path-editing mode from elsewhere.
///
/// One key per layout rather than one shared key: the wide and compact layouts
/// each build their own status bar, and a single key mounted from two places
/// is what "Multiple widgets used the same GlobalKey" is. Only one layout is
/// ever on screen, so exactly one of these resolves — [pathStatusBarState]
/// picks whichever that is.
final GlobalKey<PathStatusBarState> widePathStatusBarKey =
    GlobalKey<PathStatusBarState>(debugLabel: 'pathStatusBar/wide');
final GlobalKey<PathStatusBarState> compactPathStatusBarKey =
    GlobalKey<PathStatusBarState>(debugLabel: 'pathStatusBar/compact');

/// The mounted status bar, whichever layout is on screen.
PathStatusBarState? get pathStatusBarState =>
    widePathStatusBarKey.currentState ?? compactPathStatusBarKey.currentState;

/// Type sizes and heights for the bar, which is a dense desktop strip on a
/// desktop and a tappable row on a phone.
///
/// 11px text in a 26px strip is a mouse's status bar: legible at a desk,
/// unreadable at arm's length and far too short to hit a crumb inside. On
/// mobile the same widget grows to a 40px row with 13px text — desktop keeps
/// the numbers it had.
double get _barHeight => isMobilePlatform ? 40 : 26;
double get _barFontSize => isMobilePlatform ? 13 : 11;
double get _crumbIconSize => isMobilePlatform ? 14 : 11;

/// Finder-style compact status bar at the bottom of the window.
///
/// Left side: the path, as a clickable chain of ancestors. Clicking the empty
/// space beside it — or pressing Cmd/Ctrl+L — swaps in a text field so a path
/// can be typed or pasted. This is the app's only path display: a second copy
/// above the file list would just be the same control twice.
///
/// Right side: item count + selection summary.
class PathStatusBar extends StatefulWidget {
  const PathStatusBar({super.key});

  @override
  State<PathStatusBar> createState() => PathStatusBarState();
}

class PathStatusBarState extends State<PathStatusBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'PathStatusBar');
  bool _editing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Clicking away without submitting reverts rather than stranding the user
    // in a text field.
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && _editing) _stopEditing();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Enters edit mode with the current path selected, so typing replaces it.
  void beginEditing() {
    final browser = context.read<BrowserProvider>();
    _controller.text = browser.currentPath;
    _controller.selection =
        TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
    setState(() {
      _editing = true;
      _error = null;
    });
    _focusNode.requestFocus();
  }

  void _stopEditing() {
    if (!_editing) return;
    setState(() {
      _editing = false;
      _error = null;
    });
  }

  Future<void> _submit(String raw) async {
    final target = _expand(raw.trim());
    if (target.isEmpty) {
      _stopEditing();
      return;
    }
    // A cloud path can't be probed with dart:io; the listing itself reports
    // whether it exists, and the browser shows that error in place.
    if (VPath.isRemote(target)) {
      final browser = context.read<BrowserProvider>();
      _stopEditing();
      await browser.navigateTo(target);
      return;
    }
    // Accept a path to a file too, and land on its folder with it selected —
    // pasting a full file path is a normal thing to do.
    final type = await FileSystemEntity.type(target);
    if (!mounted) return;

    final browser = context.read<BrowserProvider>();
    switch (type) {
      case FileSystemEntityType.directory:
        _stopEditing();
        await browser.navigateTo(target);
      case FileSystemEntityType.notFound:
        setState(() => _error = 'No such folder');
      default:
        _stopEditing();
        await browser.revealPath(target);
    }
  }

  /// Resolves `~` and makes a relative entry relative to the current folder.
  String _expand(String input) {
    if (input.isEmpty) return input;
    if (VPath.isRemote(input)) return input;
    // A relative entry typed while browsing a cloud folder resolves against
    // that folder, exactly as it would on disk.
    final current = context.read<BrowserProvider>().currentPath;
    if (VPath.isRemote(current) && !input.startsWith('/') && !input.startsWith('~')) {
      return VPath.join(current, input);
    }
    var out = input;
    if (out == '~' || out.startsWith('~/')) {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home != null) {
        out = out == '~' ? home : p.join(home, out.substring(2));
      }
    }
    if (!p.isAbsolute(out)) {
      final current = context.read<BrowserProvider>().currentPath;
      if (current.isNotEmpty) out = p.normalize(p.join(current, out));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserProvider>();
    final palette = AppColors.of(context);
    final path = browser.currentPath;
    final parts = VPath.split(path);
    final count = browser.entryCount;
    final selected = browser.selectedPaths.length;

    return Container(
      height: _barHeight,
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: _editing
                ? _field(palette)
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: beginEditing,
                    child: Row(
                      children: [
                        Flexible(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            reverse: true,
                            child: Row(
                              children: _crumbs(browser, parts, palette),
                            ),
                          ),
                        ),
                        // Empty space beside the crumbs is the "edit the path"
                        // target, so the whole strip is clickable.
                        const Expanded(
                          child: SizedBox(height: double.infinity),
                        ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Text(
            _itemSummary(count, selected),
            style: TextStyle(
              fontSize: _barFontSize,
              color: palette.subtleText,
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(AppPalette palette) {
    return CupertinoTextField(
      controller: _controller,
      focusNode: _focusNode,
      autofocus: true,
      padding: EdgeInsets.symmetric(
        horizontal: 6,
        vertical: isMobilePlatform ? 8 : 1,
      ),
      style: TextStyle(fontSize: _barFontSize, color: palette.text),
      // A path is not prose: the phone keyboards' first guess at one is a
      // capital letter and a spell-check underline, and the Return key should
      // say what it does.
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.go,
      textCapitalization: TextCapitalization.none,
      autocorrect: false,
      enableSuggestions: false,
      decoration: BoxDecoration(
        color: palette.contentBg,
        border: Border.all(
          color: _error == null ? palette.accent : CupertinoColors.systemRed,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      placeholder: _error ?? 'Type a path',
      placeholderStyle: TextStyle(
        fontSize: _barFontSize,
        color: _error == null ? palette.subtleText : CupertinoColors.systemRed,
      ),
      onChanged: (_) {
        if (_error != null) setState(() => _error = null);
      },
      onSubmitted: _submit,
      onTapOutside: (_) => _stopEditing(),
    );
  }

  String _itemSummary(int total, int selected) {
    if (selected == 0) {
      return total == 1 ? '1 item' : '$total items';
    }
    return '$selected of $total selected';
  }

  List<Widget> _crumbs(
    BrowserProvider browser,
    List<String> parts,
    AppPalette palette,
  ) {
    final out = <Widget>[];
    final remote = VPath.parse(browser.currentPath);
    // On a remote path the first crumb is the connection: its id is the
    // addressable part, but the label is what the user named it.
    String acc = remote == null ? '' : VPath.root(remote.connectionId);
    for (var i = 0; i < parts.length; i++) {
      if (remote == null) {
        acc = i == 0 ? parts[i] : p.join(acc, parts[i]);
      } else if (i > 0) {
        acc = VPath.join(acc, parts[i]);
      }
      final target = acc;
      final isSource = i == 0 && remote != null;
      final segment = isSource
          ? (RemoteHub.instance.byId(parts[i])?.label ?? 'Remote')
          : (parts[i].isEmpty ? '/' : parts[i]);
      out.add(
        _MiniCrumb(
          icon: isSource
              ? CupertinoIcons.cloud_fill
              : (i == 0
                  ? CupertinoIcons.device_laptop
                  : CupertinoIcons.folder_fill),
          label: segment,
          onTap: () => browser.navigateTo(target),
          palette: palette,
        ),
      );
      if (i < parts.length - 1) {
        out.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Icon(
            CupertinoIcons.chevron_right,
            size: isMobilePlatform ? 11 : 9,
            color: palette.subtleText,
          ),
        ));
      }
    }
    return out;
  }
}

class _MiniCrumb extends StatefulWidget {
  const _MiniCrumb({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.palette,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final AppPalette palette;

  @override
  State<_MiniCrumb> createState() => _MiniCrumbState();
}

class _MiniCrumbState extends State<_MiniCrumb> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          // Wider on a phone, where each crumb is a tap target rather than a
          // click target with a cursor to aim it.
          padding: EdgeInsets.symmetric(
            horizontal: isMobilePlatform ? 6 : 2,
            vertical: isMobilePlatform ? 8 : 2,
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: _crumbIconSize,
                color: widget.palette.subtleText,
              ),
              const SizedBox(width: 4),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: _barFontSize,
                  color: _hover
                      ? widget.palette.text
                      : widget.palette.subtleText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
