import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/commands/command_registry.dart';

/// Guards two assumptions about focus that the command layer depends on, both
/// of which are easy to get wrong and silent when wrong.
void main() {
  group('palette key routing', () {
    // The palette puts its arrow/Enter handling on a Focus *above* an
    // autofocused text field. That only works because key dispatch walks from
    // the focused node up through its ancestors before reaching the app-level
    // text-editing shortcuts — otherwise ↑/↓ would move the caret and never
    // reach the result list.
    testWidgets('arrows and Enter reach an ancestor Focus above a text field',
        (tester) async {
      final seen = <LogicalKeyboardKey>[];

      await tester.pumpWidget(
        CupertinoApp(
          home: Focus(
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              switch (event.logicalKey) {
                case LogicalKeyboardKey.arrowDown:
                case LogicalKeyboardKey.arrowUp:
                case LogicalKeyboardKey.enter:
                  seen.add(event.logicalKey);
                  return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: const CupertinoTextField(autofocus: true),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(seen, [
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.enter,
      ]);
    });

    testWidgets('typed characters still reach the field', (tester) async {
      // The ancestor handler must not be so greedy that it breaks typing.
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        CupertinoApp(
          home: Focus(
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              return event.logicalKey == LogicalKeyboardKey.arrowDown
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored;
            },
            child: CupertinoTextField(controller: controller, autofocus: true),
          ),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(CupertinoTextField), 'refresh');
      await tester.pump();

      expect(controller.text, 'refresh');
    });
  });

  group('textFieldHasFocus', () {
    testWidgets('true while a text field holds focus', (tester) async {
      await tester.pumpWidget(
        const CupertinoApp(home: CupertinoTextField(autofocus: true)),
      );
      await tester.pump();

      // Regression guard: the focused node's own widget is an internal Focus
      // that EditableText builds, so a direct `is EditableText` test on it is
      // always false. This must look at ancestors instead.
      expect(
        FocusManager.instance.primaryFocus?.context?.widget,
        isNot(isA<EditableText>()),
      );
      expect(textFieldHasFocus(), isTrue);
    });

    testWidgets('false when focus is on a non-text widget', (tester) async {
      final node = FocusNode(debugLabel: 'plain');
      addTearDown(node.dispose);

      await tester.pumpWidget(
        CupertinoApp(
          home: Focus(
            focusNode: node,
            autofocus: true,
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      );
      await tester.pump();

      expect(node.hasPrimaryFocus, isTrue);
      expect(textFieldHasFocus(), isFalse);
    });
  });
}
