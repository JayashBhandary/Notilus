import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A keyboard shortcut, declared once and used three ways: to match a real key
/// event, to render a badge in the shortcuts dialog, and to label a row in the
/// command palette.
///
/// [primary] means the platform's command modifier — Cmd on macOS, Ctrl
/// everywhere else — so one declaration covers both without any per-platform
/// branching at the call site.
@immutable
class KeyCombo {
  const KeyCombo(
    this.key, {
    this.aliases = const [],
    this.primary = false,
    this.shift = false,
    this.alt = false,
  });

  final LogicalKeyboardKey key;

  /// Extra keys that fire the same command: Backspace alongside Delete,
  /// Numpad Enter alongside Enter.
  final List<LogicalKeyboardKey> aliases;

  /// Cmd on macOS, Ctrl elsewhere.
  final bool primary;
  final bool shift;
  final bool alt;

  static bool get _isMac => defaultTargetPlatform == TargetPlatform.macOS;

  /// True when [event] is a key-*down* carrying **exactly** these modifiers.
  ///
  /// The exactness matters: it's what keeps Delete (trash) and Shift+Delete
  /// (delete permanently) from both firing on the same keystroke.
  bool matches(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final pressed = event.logicalKey;
    if (pressed != key && !aliases.contains(pressed)) return false;

    final keys = HardwareKeyboard.instance;
    final primaryHeld = _isMac ? keys.isMetaPressed : keys.isControlPressed;
    return primaryHeld == primary &&
        keys.isShiftPressed == shift &&
        keys.isAltPressed == alt;
  }

  /// Display label: `⇧⌘N` on macOS, `Ctrl+Shift+N` elsewhere.
  String get label {
    if (_isMac) {
      // macOS renders modifiers glyph-only, in a fixed order: ⌃⌥⇧⌘.
      final buf = StringBuffer();
      if (alt) buf.write('⌥');
      if (shift) buf.write('⇧');
      if (primary) buf.write('⌘');
      buf.write(_keyLabel(_displayKey));
      return buf.toString();
    }
    return [
      if (primary) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      _keyLabel(_displayKey),
    ].join('+');
  }

  /// The key to *show*, which isn't always the one declared first.
  ///
  /// A Mac keyboard prints "delete" on the Backspace key and has no dedicated
  /// forward-delete on most layouts, so a Delete/Backspace pair should read ⌫
  /// there — showing ⌦ would name a key many users don't have.
  LogicalKeyboardKey get _displayKey {
    if (_isMac &&
        key == LogicalKeyboardKey.delete &&
        aliases.contains(LogicalKeyboardKey.backspace)) {
      return LogicalKeyboardKey.backspace;
    }
    return key;
  }

  static String _keyLabel(LogicalKeyboardKey k) {
    // Arrows read the same on every platform.
    if (k == LogicalKeyboardKey.arrowUp) return '↑';
    if (k == LogicalKeyboardKey.arrowDown) return '↓';
    if (k == LogicalKeyboardKey.arrowLeft) return '←';
    if (k == LogicalKeyboardKey.arrowRight) return '→';

    if (k == LogicalKeyboardKey.enter) return _isMac ? '↩' : 'Enter';
    if (k == LogicalKeyboardKey.backspace) return _isMac ? '⌫' : 'Backspace';
    if (k == LogicalKeyboardKey.delete) return _isMac ? '⌦' : 'Del';
    if (k == LogicalKeyboardKey.escape) return _isMac ? '⎋' : 'Esc';
    if (k == LogicalKeyboardKey.space) return 'Space';
    if (k == LogicalKeyboardKey.slash) return '/';
    if (k == LogicalKeyboardKey.comma) return ',';
    if (k == LogicalKeyboardKey.bracketLeft) return '[';
    if (k == LogicalKeyboardKey.bracketRight) return ']';

    final label = k.keyLabel;
    return label.length == 1 ? label.toUpperCase() : label;
  }
}
