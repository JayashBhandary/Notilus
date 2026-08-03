import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../commands/app_command.dart';
import '../commands/command_registry.dart';
import '../theme.dart';

/// Opens the Cmd/Ctrl+K command palette.
///
/// [hostContext] must be the *home screen's* context, not the palette route's:
/// commands run after the palette has popped, and they need a context that
/// outlives it to reach providers.
Future<void> showCommandPalette({
  required BuildContext hostContext,
  required HostActions host,
}) {
  return showGeneralDialog<void>(
    context: hostContext,
    barrierDismissible: true,
    barrierLabel: 'Command Palette',
    barrierColor: const Color(0x66000000),
    transitionDuration: Duration.zero,
    pageBuilder: (_, __, ___) =>
        _CommandPalette(hostContext: hostContext, host: host),
  );
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({required this.hostContext, required this.host});

  final BuildContext hostContext;
  final HostActions host;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _fieldFocus = FocusNode(debugLabel: 'PaletteQuery');
  final ScrollController _scroll = ScrollController();

  /// Static commands plus the dynamic places, resolved once on open so the list
  /// can't shift under the selection while the user is typing.
  late final List<AppCommand> _all = [
    ...paletteCommands(),
    ...placeCommands(widget.hostContext),
  ];

  List<_Match> _results = const [];
  int _selected = 0;

  static const double _rowHeight = 44;
  static const double _listMaxHeight = 360;

  @override
  void initState() {
    super.initState();
    _results = _filter('');
  }

  @override
  void dispose() {
    _query.dispose();
    _fieldFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Filters and ranks. Commands that can't act right now are dropped rather
  /// than greyed out — a palette is for doing things, and an inert row is just
  /// an obstacle between the query and the match below it.
  List<_Match> _filter(String raw) {
    final env = CommandEnv(context: widget.hostContext, host: widget.host);
    final query = raw.trim().toLowerCase();
    final matches = <_Match>[];

    for (final command in _all) {
      if (!command.enabledIn(env)) continue;
      if (query.isEmpty) {
        matches.add(_Match(command, 0));
        continue;
      }
      final scored = _score(command, query);
      if (scored != null) matches.add(scored);
    }

    if (query.isNotEmpty) {
      matches.sort((a, b) => a.score.compareTo(b.score));
    }
    return matches;
  }

  /// Subsequence match over "Title Category", scored so that earlier and more
  /// contiguous hits win. Lower is better.
  _Match? _score(AppCommand command, String query) {
    final haystack = '${command.title} ${command.category}'.toLowerCase();
    final hits = <int>[];
    var cursor = 0;
    var penalty = 0;

    for (final rune in query.runes) {
      final char = String.fromCharCode(rune);
      if (char == ' ') continue;
      final found = haystack.indexOf(char, cursor);
      if (found < 0) return null;
      // Gaps cost; a run of adjacent characters costs nothing.
      if (hits.isNotEmpty && found != hits.last + 1) penalty += found - cursor;
      hits.add(found);
      cursor = found + 1;
    }

    // Prefer matches that start early, and prefer title hits over category
    // hits by weighting anything past the title's length.
    final start = hits.isEmpty ? 0 : hits.first;
    final pastTitle = start >= command.title.length ? 40 : 0;
    return _Match(command, start + penalty + pastTitle);
  }

  void _onQueryChanged(String value) {
    setState(() {
      _results = _filter(value);
      _selected = 0;
    });
    _revealSelected();
  }

  void _move(int delta) {
    if (_results.isEmpty) return;
    setState(() {
      // Wraps, so ↓ at the bottom returns to the top.
      _selected = (_selected + delta) % _results.length;
      if (_selected < 0) _selected += _results.length;
    });
    _revealSelected();
  }

  /// Keeps the highlighted row inside the viewport. Rows are a fixed height, so
  /// the target offset is arithmetic rather than a layout query.
  void _revealSelected() {
    if (!_scroll.hasClients || _results.isEmpty) return;
    final viewport = _scroll.position.viewportDimension;
    final top = _selected * _rowHeight;
    final bottom = top + _rowHeight;
    final current = _scroll.offset;

    double? target;
    if (top < current) {
      target = top;
    } else if (bottom > current + viewport) {
      target = bottom - viewport;
    }
    if (target == null) return;

    _scroll.jumpTo(
      target.clamp(0.0, _scroll.position.maxScrollExtent),
    );
  }

  void _runSelected() {
    if (_results.isEmpty) return;
    final command = _results[_selected].command;
    Navigator.of(context).pop();
    // Run after the pop so dialogs the command opens aren't stacked underneath
    // a palette that is on its way out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.hostContext.mounted) return;
      command.run(
        CommandEnv(context: widget.hostContext, host: widget.host),
      );
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _runSelected();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        Navigator.of(context).pop();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);

    return Align(
      // Sits high in the window, the way a launcher does — the results grow
      // downward instead of pushing the field around.
      alignment: const Alignment(0, -0.62),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          margin: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: palette.scaffoldBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.divider),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          // Wraps the field rather than taking focus itself. Key dispatch walks
          // from the focused field up through here *before* reaching the
          // app-level text-editing shortcuts, which is what lets ↑/↓ drive the
          // result list instead of moving the caret.
          child: Focus(
            onKeyEvent: _onKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _queryField(palette),
                if (_results.isEmpty)
                  _empty(palette)
                else
                  Flexible(child: _resultsList(palette)),
                _footer(palette),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _queryField(AppPalette palette) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      child: Row(
        children: [
          Icon(CupertinoIcons.search, size: 16, color: palette.subtleText),
          const SizedBox(width: 10),
          Expanded(
            child: CupertinoTextField(
              controller: _query,
              focusNode: _fieldFocus,
              autofocus: true,
              placeholder: 'Type a command…',
              // The field is a bare input; the container above draws the chrome.
              decoration: const BoxDecoration(),
              padding: EdgeInsets.zero,
              style: TextStyle(fontSize: 15, color: palette.text),
              placeholderStyle:
                  TextStyle(fontSize: 15, color: palette.subtleText),
              onChanged: _onQueryChanged,
              // Enter is handled by the enclosing Focus so it works whether or
              // not the field has focus.
              onSubmitted: (_) => _runSelected(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(AppPalette palette) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Text(
        'No matching commands',
        style: TextStyle(fontSize: 13, color: palette.subtleText),
      ),
    );
  }

  Widget _resultsList(AppPalette palette) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: _listMaxHeight),
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemExtent: _rowHeight,
        itemCount: _results.length,
        itemBuilder: (context, index) {
          final match = _results[index];
          return _PaletteRow(
            command: match.command,
            highlighted: index == _selected,
            palette: palette,
            onTap: () {
              setState(() => _selected = index);
              _runSelected();
            },
            onHover: () {
              if (_selected != index) setState(() => _selected = index);
            },
          );
        },
      ),
    );
  }

  Widget _footer(AppPalette palette) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      child: Row(
        children: [
          _hint('↑↓', 'navigate', palette),
          const SizedBox(width: 14),
          _hint('↩', 'run', palette),
          const SizedBox(width: 14),
          _hint('esc', 'close', palette),
          const Spacer(),
          Text(
            '${_results.length} command${_results.length == 1 ? '' : 's'}',
            style: TextStyle(fontSize: 10.5, color: palette.subtleText),
          ),
        ],
      ),
    );
  }

  Widget _hint(String keys, String label, AppPalette palette) {
    return Row(
      children: [
        Text(
          keys,
          style: TextStyle(
            fontSize: 10.5,
            color: palette.text,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 10.5, color: palette.subtleText),
        ),
      ],
    );
  }
}

/// A command plus its ranking against the current query.
class _Match {
  const _Match(this.command, this.score);

  final AppCommand command;
  final int score;
}

class _PaletteRow extends StatelessWidget {
  const _PaletteRow({
    required this.command,
    required this.highlighted,
    required this.palette,
    required this.onTap,
    required this.onHover,
  });

  final AppCommand command;
  final bool highlighted;
  final AppPalette palette;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final combo = command.combo;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: highlighted ? palette.sidebarSelected : null,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(
                command.icon ?? CupertinoIcons.chevron_right,
                size: 15,
                color: highlighted ? palette.accent : palette.subtleText,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  command.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: palette.text,
                    fontWeight:
                        highlighted ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                command.category,
                style: TextStyle(fontSize: 10.5, color: palette.subtleText),
              ),
              if (combo != null) ...[
                const SizedBox(width: 8),
                ShortcutBadge(label: combo.label, palette: palette),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Monospaced key badge, shared by the palette and the shortcuts dialog so a
/// binding looks identical wherever it's shown.
class ShortcutBadge extends StatelessWidget {
  const ShortcutBadge({
    super.key,
    required this.label,
    required this.palette,
  });

  final String label;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: palette.divider),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          height: 1.2,
          color: palette.text,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
