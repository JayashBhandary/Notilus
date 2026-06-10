import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart' as xt;

import '../theme.dart';

/// Bottom-docked PTY-backed terminal panel with VSCode-style tabs.
///
/// Parent owns visibility + height. The panel exposes a drag handle on its
/// top edge that calls [onResize] with delta pixels (negative = drag up =
/// grow). Closing the last tab calls [onClose].
class TerminalPanel extends StatefulWidget {
  const TerminalPanel({
    super.key,
    required this.cwd,
    required this.height,
    required this.onResize,
    required this.onClose,
  });

  /// The working directory new sessions spawn in. When this changes, a
  /// `cd "<path>"` is sent to the *active* session only.
  final String cwd;
  final double height;
  final ValueChanged<double> onResize;
  final VoidCallback onClose;

  @override
  State<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends State<TerminalPanel> {
  final List<_TerminalSession> _sessions = [];
  int _activeIndex = 0;
  int _nextId = 1;

  @override
  void initState() {
    super.initState();
    _spawnSession();
  }

  @override
  void didUpdateWidget(covariant TerminalPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cwd.isNotEmpty &&
        widget.cwd != oldWidget.cwd) {
      final active = _activeSession;
      if (active != null &&
          active.spawnError == null &&
          active.shellCwd != widget.cwd) {
        active.shellCwd = widget.cwd;
        active.sendCd(widget.cwd);
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    for (final s in _sessions) {
      s.dispose();
    }
    super.dispose();
  }

  _TerminalSession? get _activeSession =>
      _sessions.isEmpty ? null : _sessions[_activeIndex];

  void _spawnSession() {
    final session = _TerminalSession(id: _nextId++, cwd: widget.cwd);
    session.spawn();
    setState(() {
      _sessions.add(session);
      _activeIndex = _sessions.length - 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) session.focusNode.requestFocus();
    });
  }

  void _activate(int index) {
    if (index == _activeIndex) return;
    setState(() => _activeIndex = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sessions[index].focusNode.requestFocus();
    });
  }

  void _closeSession(int index) {
    if (index < 0 || index >= _sessions.length) return;
    final closing = _sessions[index];
    closing.dispose();
    setState(() {
      _sessions.removeAt(index);
      if (_sessions.isEmpty) {
        _activeIndex = 0;
      } else if (_activeIndex >= _sessions.length) {
        _activeIndex = _sessions.length - 1;
      } else if (_activeIndex > index) {
        _activeIndex -= 1;
      }
    });
    if (_sessions.isEmpty) {
      widget.onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final active = _activeSession;
    return SizedBox(
      height: widget.height,
      child: Column(
        children: [
          _ResizeHandle(onDelta: widget.onResize, palette: palette),
          _Header(
            cwd: active?.shellCwd ?? '',
            sessionCount: _sessions.length,
            palette: palette,
            onClear: active == null ? null : () => active.clear(),
            onClose: widget.onClose,
          ),
          _TabStrip(
            sessions: _sessions,
            activeIndex: _activeIndex,
            palette: palette,
            onActivate: _activate,
            onClose: _closeSession,
            onNew: _spawnSession,
          ),
          Expanded(
            child: active == null
                ? const SizedBox.shrink()
                : IndexedStack(
                    index: _activeIndex,
                    children: _sessions
                        .map((s) => _SessionView(
                              key: ValueKey(s.id),
                              session: s,
                              palette: palette,
                            ))
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _TerminalSession {
  _TerminalSession({required this.id, required String cwd})
      : label = 'Terminal $id',
        shellCwd = cwd,
        _initialCwd = cwd;

  final int id;
  final String label;
  final String _initialCwd;
  String shellCwd;

  final terminal = xt.Terminal(maxLines: 10000);
  final controller = xt.TerminalController();
  final focusNode = FocusNode();

  Pty? pty;
  StreamSubscription<Uint8List>? _outSub;
  String? spawnError;

  void spawn() {
    try {
      final (exe, args) = _shellForPlatform();
      final p = Pty.start(
        exe,
        arguments: args,
        workingDirectory: _initialCwd.isNotEmpty ? _initialCwd : null,
        rows: 24,
        columns: 80,
      );
      pty = p;
      _outSub = p.output.listen((data) {
        terminal.write(utf8.decode(data, allowMalformed: true));
      });
      terminal.onOutput = (s) {
        p.write(Uint8List.fromList(utf8.encode(s)));
      };
      terminal.onResize = (cols, rows, _, __) {
        p.resize(rows, cols);
      };
      p.exitCode.then((code) {
        terminal.write('\r\n[process exited: $code]\r\n');
      });
    } catch (e) {
      spawnError = '$e';
    }
  }

  (String, List<String>) _shellForPlatform() {
    if (Platform.isWindows) {
      // Prefer PowerShell — nicer UX than legacy cmd, ships with all Windows.
      return ('powershell.exe', const ['-NoLogo']);
    }
    final shell = Platform.environment['SHELL'] ??
        (Platform.isMacOS ? '/bin/zsh' : '/bin/bash');
    return (shell, const ['-l']);
  }

  void sendCd(String path) {
    final p = pty;
    if (p == null) return;
    final quoted = _quoteForShell(path);
    // Ctrl-U clears any pending input on readline-style shells so the
    // injected cd lands on an empty line.
    final cmd = Platform.isWindows
        ? 'Set-Location $quoted\r'
        : '\x15 cd $quoted\r';
    p.write(Uint8List.fromList(utf8.encode(cmd)));
  }

  String _quoteForShell(String path) {
    if (Platform.isWindows) {
      return "'${path.replaceAll("'", "''")}'";
    }
    return "'${path.replaceAll("'", r"'\''")}'";
  }

  void clear() {
    // ESC c — full terminal reset, matches `clear` + resets state.
    terminal.write('\x1bc');
  }

  void dispose() {
    _outSub?.cancel();
    pty?.kill();
    focusNode.dispose();
  }
}

class _SessionView extends StatelessWidget {
  const _SessionView({
    super.key,
    required this.session,
    required this.palette,
  });
  final _TerminalSession session;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.brightness == Brightness.dark
          ? const Color(0xFF111111)
          : const Color(0xFF1E1E1E),
      child: session.spawnError != null
          ? _ErrorView(error: session.spawnError!, palette: palette)
          : xt.TerminalView(
              session.terminal,
              controller: session.controller,
              focusNode: session.focusNode,
              autofocus: false,
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              textStyle: const xt.TerminalStyle(
                fontSize: 13,
                fontFamily: 'Menlo',
                fontFamilyFallback: [
                  'Consolas',
                  'DejaVu Sans Mono',
                  'monospace',
                ],
              ),
              theme: xt.TerminalThemes.defaultTheme,
            ),
    );
  }
}

class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({required this.onDelta, required this.palette});
  final ValueChanged<double> onDelta;
  final AppPalette palette;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hover = false;
  bool _drag = false;

  @override
  Widget build(BuildContext context) {
    final highlight = _hover || _drag;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) => setState(() => _drag = true),
        onVerticalDragEnd: (_) => setState(() => _drag = false),
        onVerticalDragCancel: () => setState(() => _drag = false),
        onVerticalDragUpdate: (d) => widget.onDelta(d.delta.dy),
        child: SizedBox(
          height: 6,
          child: Center(
            child: Container(
              height: 2,
              decoration: BoxDecoration(
                color: highlight
                    ? widget.palette.accent
                    : widget.palette.divider,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.cwd,
    required this.sessionCount,
    required this.palette,
    required this.onClear,
    required this.onClose,
  });

  final String cwd;
  final int sessionCount;
  final AppPalette palette;
  final VoidCallback? onClear;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(
          top: BorderSide(color: palette.divider),
          bottom: BorderSide(color: palette.divider),
        ),
      ),
      child: Row(
        children: [
          Icon(
            CupertinoIcons.chevron_left_slash_chevron_right,
            size: 13,
            color: palette.subtleText,
          ),
          const SizedBox(width: 6),
          Text(
            sessionCount > 1 ? 'Terminal ($sessionCount)' : 'Terminal',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: palette.text,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              cwd,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: palette.subtleText,
              ),
            ),
          ),
          _HeaderButton(
            icon: CupertinoIcons.clear,
            tooltip: 'Clear',
            onTap: onClear,
            palette: palette,
          ),
          const SizedBox(width: 4),
          _HeaderButton(
            icon: CupertinoIcons.chevron_down,
            tooltip: 'Hide panel',
            onTap: onClose,
            palette: palette,
          ),
        ],
      ),
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.sessions,
    required this.activeIndex,
    required this.palette,
    required this.onActivate,
    required this.onClose,
    required this.onNew,
  });

  final List<_TerminalSession> sessions;
  final int activeIndex;
  final AppPalette palette;
  final ValueChanged<int> onActivate;
  final ValueChanged<int> onClose;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < sessions.length; i++)
                    _Tab(
                      label: sessions[i].label,
                      active: i == activeIndex,
                      palette: palette,
                      onTap: () => onActivate(i),
                      onClose: () => onClose(i),
                    ),
                ],
              ),
            ),
          ),
          _HeaderButton(
            icon: CupertinoIcons.add,
            tooltip: 'New terminal',
            onTap: onNew,
            palette: palette,
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  const _Tab({
    required this.label,
    required this.active,
    required this.palette,
    required this.onTap,
    required this.onClose,
  });

  final String label;
  final bool active;
  final AppPalette palette;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final bg = widget.active
        ? p.sidebarSelected
        : (_hover ? p.sidebarHover : null);
    final fg = widget.active ? p.text : p.subtleText;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              right: BorderSide(color: p.divider),
              bottom: widget.active
                  ? BorderSide(color: p.accent, width: 2)
                  : BorderSide.none,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight:
                      widget.active ? FontWeight.w600 : FontWeight.w400,
                  color: fg,
                ),
              ),
              const SizedBox(width: 8),
              if (_hover || widget.active)
                _HeaderButton(
                  icon: CupertinoIcons.xmark,
                  tooltip: 'Close terminal',
                  onTap: widget.onClose,
                  palette: p,
                )
              else
                const SizedBox(width: 20, height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderButton extends StatefulWidget {
  const _HeaderButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.palette,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final AppPalette palette;

  @override
  State<_HeaderButton> createState() => _HeaderButtonState();
}

class _HeaderButtonState extends State<_HeaderButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: _hover && enabled ? widget.palette.sidebarHover : null,
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Icon(
            widget.icon,
            size: 11,
            color: enabled
                ? widget.palette.subtleText
                : widget.palette.subtleText.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.palette});
  final String error;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        'Failed to start shell:\n$error',
        style: const TextStyle(
          fontFamily: 'Menlo',
          fontSize: 12,
          color: Color(0xFFFF6E6E),
          height: 1.5,
        ),
      ),
    );
  }
}
