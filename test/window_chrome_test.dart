import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/theme.dart';
import 'package:notilus/widgets/window_chrome.dart';

/// The app's toolbar doubles as the window's title bar on every desktop
/// platform, so what is guarded here is the two halves of that bargain:
///
///  * only the *empty* parts of the bar move the window. The macOS window used
///    to set `isMovableByWindowBackground`, which made every pixel a drag
///    handle — dragging a scrollbar moved the window instead of scrolling.
///  * the controls adapt: macOS leaves a gap for AppKit's traffic lights and
///    draws nothing, Windows and Linux draw minimise / maximise / close.
class _RecordingWindowActions implements WindowActions {
  final List<String> calls = [];

  @override
  Future<void> startDragging() async => calls.add('drag');

  @override
  Future<void> toggleMaximize() async => calls.add('toggleMaximize');

  @override
  Future<void> minimize() async => calls.add('minimize');

  @override
  Future<void> close() async => calls.add('close');
}

void main() {
  late _RecordingWindowActions actions;

  setUp(() {
    actions = _RecordingWindowActions();
    WindowActions.debugReplace(actions);
  });

  tearDown(() {
    WindowActions.debugReset();
    debugWindowButtons = null;
  });

  Widget host(Widget child) {
    return ShadApp.custom(
      theme: AppTheme.shadThemeFor(Brightness.light),
      themeMode: ThemeMode.light,
      appBuilder: (_) => WidgetsApp(
        color: const Color(0xFF000000),
        builder: (_, __) => ShadAppBuilder(child: Center(child: child)),
      ),
    );
  }

  /// A toolbar shaped like the real one: a drag layer under a row of controls.
  Widget toolbar({required VoidCallback onButton}) {
    return SizedBox(
      width: 400,
      height: 48,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const WindowDragRegion(),
          Row(
            children: [
              GestureDetector(
                onTap: onButton,
                child: const SizedBox(
                  width: 40,
                  height: 48,
                  child: Text('btn'),
                ),
              ),
              const Spacer(),
            ],
          ),
        ],
      ),
    );
  }

  group('drag region', () {
    testWidgets('dragging empty toolbar space moves the window',
        (tester) async {
      debugWindowButtons = WindowButtons.native;
      await tester.pumpWidget(host(toolbar(onButton: () {})));

      // Well clear of the button at the leading edge.
      await tester.drag(find.byType(WindowDragRegion), const Offset(60, 0));
      // Long enough for the double-tap recognizer to give up; it holds a timer
      // after every pointer-up and the harness fails on one left pending.
      await tester.pump(const Duration(milliseconds: 500));

      expect(actions.calls, ['drag']);
    });

    testWidgets('a control in the bar still receives its tap', (tester) async {
      debugWindowButtons = WindowButtons.native;
      var tapped = 0;
      await tester.pumpWidget(host(toolbar(onButton: () => tapped++)));

      await tester.tap(find.text('btn'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(tapped, 1);
      // The control is above the drag layer, so this was never a window drag.
      expect(actions.calls, isEmpty);
    });

    testWidgets('double-clicking empty space maximizes', (tester) async {
      debugWindowButtons = WindowButtons.drawn;
      await tester.pumpWidget(host(toolbar(onButton: () {})));

      final centre = tester.getCenter(find.byType(WindowDragRegion));
      await tester.tapAt(centre);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 500));

      expect(actions.calls, ['toggleMaximize']);
    });

    testWidgets('double-click can be turned off', (tester) async {
      debugWindowButtons = WindowButtons.drawn;
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 400,
            height: 48,
            child: WindowDragRegion(enableDoubleClick: false),
          ),
        ),
      );

      final centre = tester.getCenter(find.byType(WindowDragRegion));
      await tester.tapAt(centre);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 500));

      expect(actions.calls, isEmpty);
    });

    testWidgets('off a desktop window nothing is draggable', (tester) async {
      debugWindowButtons = WindowButtons.none;
      await tester.pumpWidget(
        host(
          const SizedBox(width: 400, height: 48, child: WindowDragRegion()),
        ),
      );

      await tester.drag(find.byType(WindowDragRegion), const Offset(60, 0));
      await tester.pump(const Duration(milliseconds: 500));

      expect(actions.calls, isEmpty);
    });
  });

  group('window controls', () {
    testWidgets('Windows and Linux draw their own buttons', (tester) async {
      debugWindowButtons = WindowButtons.drawn;
      await tester.pumpWidget(host(const WindowControls()));

      expect(find.byIcon(LucideIcons.minus), findsOneWidget);
      expect(find.byIcon(LucideIcons.square), findsOneWidget);
      expect(find.byIcon(LucideIcons.x), findsOneWidget);
    });

    testWidgets('macOS draws none — AppKit already has', (tester) async {
      debugWindowButtons = WindowButtons.native;
      await tester.pumpWidget(host(const WindowControls()));

      expect(find.byIcon(LucideIcons.minus), findsNothing);
      expect(find.byIcon(LucideIcons.x), findsNothing);
    });

    testWidgets('each button asks for the matching window operation',
        (tester) async {
      debugWindowButtons = WindowButtons.drawn;
      await tester.pumpWidget(host(const WindowControls()));

      await tester.tap(find.byIcon(LucideIcons.minus));
      await tester.tap(find.byIcon(LucideIcons.square));
      await tester.tap(find.byIcon(LucideIcons.x));
      await tester.pump();

      expect(actions.calls, ['minimize', 'toggleMaximize', 'close']);
    });
  });

  group('traffic light inset', () {
    test('macOS reserves room only for a bar at the window edge', () {
      debugWindowButtons = WindowButtons.native;
      expect(windowLeadingInset(atWindowEdge: true), kTrafficLightInset);
      // With the sidebar open it reserves the space itself, so the toolbar
      // beside it must not double up.
      expect(windowLeadingInset(atWindowEdge: false), 0);
    });

    test('platforms that draw their own buttons need no leading gap', () {
      debugWindowButtons = WindowButtons.drawn;
      expect(windowLeadingInset(atWindowEdge: true), 0);
      expect(windowLeadingInset(atWindowEdge: false), 0);
    });

    test('the reserved width clears all three traffic lights', () {
      // Three 14px buttons at 20px spacing start 20px in — ~68px — so the
      // inset has to exceed that or the leftmost control sits under them.
      expect(kTrafficLightInset, greaterThan(68));
    });
  });
}
