import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/commands/app_command.dart';
import 'package:notilus/commands/command_registry.dart';
import 'package:notilus/commands/key_combo.dart';

/// A combo's identity for conflict purposes: the same key with the same
/// modifiers. Aliases are expanded so Delete and Backspace both count.
Iterable<String> _signatures(KeyCombo combo) {
  final mods = '${combo.primary ? 'M' : ''}'
      '${combo.shift ? 'S' : ''}'
      '${combo.alt ? 'A' : ''}';
  return [
    for (final key in [combo.key, ...combo.aliases]) '$mods:${key.keyId}',
  ];
}

void main() {
  // KeyCombo.matches reads HardwareKeyboard.instance for the live modifier
  // state, which needs the binding up even in these non-widget tests.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('command registry', () {
    test('command ids are unique', () {
      final seen = <String>{};
      final duplicates = <String>[];
      for (final command in appCommands) {
        if (!seen.add(command.id)) duplicates.add(command.id);
      }
      expect(duplicates, isEmpty, reason: 'duplicate command ids');
    });

    test('no two commands in a scope claim the same keystroke', () {
      // Dispatch returns the *first* match, so a collision within a scope would
      // silently shadow one of the two commands.
      final claimed = <CommandScope, Map<String, String>>{};
      final conflicts = <String>[];

      for (final command in appCommands) {
        final scopeMap = claimed.putIfAbsent(command.scope, () => {});
        for (final combo in command.combos) {
          for (final signature in _signatures(combo)) {
            final existing = scopeMap[signature];
            if (existing != null) {
              conflicts.add(
                '${command.scope.name}: ${command.id} collides with $existing '
                'on $signature',
              );
            } else {
              scopeMap[signature] = command.id;
            }
          }
        }
      }

      expect(conflicts, isEmpty, reason: conflicts.join('\n'));
    });

    test('global shortcuts all carry the primary modifier', () {
      // Global handlers run ahead of focus dispatch, so an unmodified global
      // binding would steal plain letters from every text field in the app.
      final bare = [
        for (final command in appCommands)
          if (command.scope == CommandScope.global &&
              command.combo != null &&
              !command.combo!.primary)
            command.id,
      ];
      expect(bare, isEmpty);
    });

    test('file-mutating global commands are blocked while typing', () {
      // Cmd+N mid-rename must not create a folder behind the dialog.
      for (final id in ['file.newFolder', 'file.newFile']) {
        final command = appCommands.firstWhere((c) => c.id == id);
        expect(command.safeWhileTyping, isFalse, reason: id);
      }
    });

    test('navigation shortcuts yield to text fields', () {
      // Cmd+Up is "jump to start" in a field and Cmd+[/] are indent keys, so
      // these must not fire while typing.
      for (final id in ['nav.back', 'nav.forward', 'nav.up']) {
        final command = appCommands.firstWhere((c) => c.id == id);
        expect(command.safeWhileTyping, isFalse, reason: id);
      }
    });

    test('commands needing host actions are global scope', () {
      // Only the global dispatcher and the palette supply HostActions; a
      // fileList-scope command reaching for env.host! would throw.
      final hostBacked = {
        'app.palette',
        'app.shortcuts',
        'app.terminal',
        'app.settings',
        'view.refresh',
        'view.sidebar',
        'view.rightPanel',
      };
      for (final id in hostBacked) {
        final command = appCommands.firstWhere((c) => c.id == id);
        expect(command.scope, CommandScope.global, reason: id);
      }
    });

    test('every palette command has an icon and a title', () {
      for (final command in paletteCommands()) {
        expect(command.icon, isNotNull, reason: command.id);
        expect(command.title.trim(), isNotEmpty, reason: command.id);
      }
    });

    test('shortcuts dialog groups only commands that have a combo', () {
      final grouped = shortcutsByCategory();
      expect(grouped, isNotEmpty);
      for (final commands in grouped.values) {
        for (final command in commands) {
          expect(command.combo, isNotNull, reason: command.id);
          expect(command.combos, isNotEmpty, reason: command.id);
        }
      }
    });

    test('Move to Trash also answers to the Finder binding', () {
      // Cmd+Delete used to work by accident, via fall-through in the old
      // hand-written switch. Exact modifier matching would have dropped it.
      final trash = appCommands.firstWhere((c) => c.id == 'file.trash');
      expect(trash.combos.length, 2);
      expect(trash.combos.any((c) => c.primary), isTrue);
      expect(trash.combos.any((c) => !c.primary), isTrue);
    });
  });

  group('KeyCombo', () {
    test('labels render per platform', () {
      const combo = KeyCombo(
        LogicalKeyboardKey.keyN,
        primary: true,
        shift: true,
      );
      // Runs on the host platform; assert the shape rather than the exact
      // glyphs so the test is meaningful on macOS and Linux CI alike.
      expect(combo.label, anyOf(equals('⇧⌘N'), equals('Ctrl+Shift+N')));
    });

    test('a Delete/Backspace pair reads as Backspace on macOS', () {
      // Mac keyboards print "delete" on the Backspace key; labelling it ⌦ would
      // name a key most Mac users don't have.
      const trash = KeyCombo(
        LogicalKeyboardKey.delete,
        aliases: [LogicalKeyboardKey.backspace],
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(trash.label, '⌫');

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(trash.label, 'Del');

      // Both keys still trigger it, whatever the label says.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      for (final key in [
        LogicalKeyboardKey.delete,
        LogicalKeyboardKey.backspace,
      ]) {
        expect(
          trash.matches(KeyDownEvent(
            logicalKey: key,
            physicalKey: PhysicalKeyboardKey.backspace,
            timeStamp: Duration.zero,
          )),
          isTrue,
          reason: key.keyLabel,
        );
      }
    });

    test('arrow and named keys get friendly labels', () {
      const up = KeyCombo(LogicalKeyboardKey.arrowUp, primary: true);
      expect(up.label, contains('↑'));

      const f2 = KeyCombo(LogicalKeyboardKey.f2);
      expect(f2.label, 'F2');

      const space = KeyCombo(LogicalKeyboardKey.space);
      expect(space.label, 'Space');
    });
  });
}
