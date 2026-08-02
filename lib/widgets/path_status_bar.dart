import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../providers/browser_provider.dart';
import '../theme.dart';

/// Lets Cmd/Ctrl+L put the status bar into path-editing mode from elsewhere.
final GlobalKey<PathStatusBarState> pathStatusBarKey =
    GlobalKey<PathStatusBarState>();

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
    final parts = path.isEmpty ? <String>[] : p.split(path);
    final count = browser.entryCount;
    final selected = browser.selectedPaths.length;

    return Container(
      height: 26,
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
              fontSize: 11,
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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      style: TextStyle(fontSize: 11, color: palette.text),
      decoration: BoxDecoration(
        color: palette.contentBg,
        border: Border.all(
          color: _error == null ? palette.accent : CupertinoColors.systemRed,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      placeholder: _error ?? 'Type a path',
      placeholderStyle: TextStyle(
        fontSize: 11,
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
    String acc = '';
    for (var i = 0; i < parts.length; i++) {
      acc = i == 0 ? parts[i] : p.join(acc, parts[i]);
      final target = acc;
      final segment = parts[i].isEmpty ? '/' : parts[i];
      out.add(
        _MiniCrumb(
          icon: i == 0
              ? CupertinoIcons.device_laptop
              : CupertinoIcons.folder_fill,
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
            size: 9,
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
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 11,
                color: widget.palette.subtleText,
              ),
              const SizedBox(width: 4),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
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
