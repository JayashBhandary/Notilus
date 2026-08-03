import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../commands/app_command.dart';
import '../commands/command_registry.dart';
import '../theme.dart';
import 'command_palette.dart' show ShortcutBadge;

/// Opens the Cmd/Ctrl+/ keyboard-shortcuts reference.
Future<void> showShortcutsDialog(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Keyboard Shortcuts',
    barrierColor: const Color(0x66000000),
    transitionDuration: Duration.zero,
    pageBuilder: (_, __, ___) => const _ShortcutsDialog(),
  );
}

/// Where a scoped shortcut applies, spelled out so a binding that only works
/// in one place doesn't read as broken everywhere else.
String _scopeNote(CommandScope scope) {
  switch (scope) {
    case CommandScope.global:
      return '';
    case CommandScope.fileList:
      return 'in the file list';
    case CommandScope.preview:
      return 'in Quick Look';
  }
}

class _ShortcutsDialog extends StatelessWidget {
  const _ShortcutsDialog();

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    final grouped = shortcutsByCategory();

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 620, maxHeight: maxHeight),
        child: Container(
          margin: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: palette.scaffoldBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.divider),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(context, palette),
              Flexible(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                  children: [
                    for (final entry in grouped.entries)
                      _Section(
                        title: entry.key,
                        palette: palette,
                        rows: [
                          for (final command in entry.value)
                            _Row(
                              label: command.title,
                              note: [
                                if (command.keysNote != null) command.keysNote!,
                                if (_scopeNote(command.scope).isNotEmpty)
                                  _scopeNote(command.scope),
                              ].join(' · '),
                              badges: [
                                for (final combo in command.combos) combo.label,
                              ],
                              separator: 'or',
                              palette: palette,
                            ),
                        ],
                      ),
                    _Section(
                      title: 'Mouse & Trackpad',
                      palette: palette,
                      rows: [
                        for (final gesture in _gestures)
                          _Row(
                            label: gesture.$1,
                            note: gesture.$3,
                            badges: gesture.$2,
                            palette: palette,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, AppPalette palette) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 10, 12),
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      child: Row(
        children: [
          Icon(CupertinoIcons.keyboard, size: 16, color: palette.subtleText),
          const SizedBox(width: 8),
          Text(
            'Keyboard Shortcuts',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: palette.text,
            ),
          ),
          const Spacer(),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: Size.zero,
            onPressed: () => Navigator.of(context).pop(),
            child: Icon(
              CupertinoIcons.xmark,
              size: 15,
              color: palette.subtleText,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pointer gestures, listed by hand: these live in gesture recognisers spread
/// across the file list, the icon grid and the panel dividers rather than in the
/// command registry, so there's nothing to enumerate them from.
///
/// Tuple is (action, badges, note).
final List<(String, List<String>, String)> _gestures = [
  ('Open item', ['Double-click'], ''),
  ('Context menu', ['Right-click'], 'on an item or empty space'),
  ('Context menu (no mouse)', ['Long-press'], ''),
  (
    'Add to selection',
    [_mod, 'Click'],
    'toggles one item',
  ),
  ('Select a range', ['Shift', 'Click'], 'from the last selected item'),
  ('Rubber-band select', ['Drag'], 'from empty space; auto-scrolls at edges'),
  (
    'Add while rubber-banding',
    ['Shift', _mod, 'Drag'],
    'keeps the existing selection',
  ),
  ('Move files', ['Drag'], 'within Notilus, or out to the OS'),
  (
    'Copy instead of move',
    [_copyModifier, 'Drag'],
    'held at drop time, not drag start',
  ),
  ('Clear selection', ['Click'], 'on empty space'),
  ('Resize terminal', ['Drag'], 'the terminal\'s top edge'),
];

/// `⌘` on macOS, `Ctrl` elsewhere — matching `KeyCombo`'s primary modifier.
String get _mod =>
    defaultTargetPlatform == TargetPlatform.macOS ? '⌘' : 'Ctrl';

/// The drag-to-copy modifier, which is Option on macOS and Ctrl elsewhere.
String get _copyModifier =>
    defaultTargetPlatform == TargetPlatform.macOS ? '⌥' : 'Ctrl';

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.palette,
    required this.rows,
  });

  final String title;
  final AppPalette palette;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 2),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: palette.subtleText,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: palette.cardBg,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: palette.divider),
            ),
            child: Column(children: rows),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.note,
    required this.badges,
    required this.palette,
    this.separator = '+',
  });

  final String label;
  final String note;
  final List<String> badges;
  final AppPalette palette;

  /// Joins the badges: `+` for the parts of one gesture (⌘ + Click), `or` for
  /// alternative bindings that each work on their own (⌫ or ⌘⌫).
  final String separator;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 12.5, color: palette.text),
                ),
                if (note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      note,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: palette.subtleText,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          for (var i = 0; i < badges.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Text(
                  separator,
                  style: TextStyle(fontSize: 10, color: palette.subtleText),
                ),
              ),
            ShortcutBadge(label: badges[i], palette: palette),
          ],
        ],
      ),
    );
  }
}
