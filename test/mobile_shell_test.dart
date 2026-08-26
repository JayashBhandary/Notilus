import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:notilus/widgets/mobile_shell.dart';

/// The phone shell's gestures, in isolation from the screen that uses them.
///
/// One horizontal-drag recognizer serves three jobs — pull the drawer out,
/// push it back, page the history — so what each drag is taken to mean is
/// worth pinning on its own, away from a full app where a stray listing or a
/// missing plugin decides whether the test runs at all.
void main() {
  const drawerWidth = 260.0;

  /// Builds a shell whose drawer is a labelled box, and records what the
  /// gestures asked for.
  Widget host({
    required List<String> log,
    bool open = false,
    bool swipeNavigation = true,
    VoidCallback? onSwipeBack,
    VoidCallback? onSwipeForward,
  }) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: _ShellHost(
        open: open,
        swipeNavigation: swipeNavigation,
        log: log,
        onSwipeBack: onSwipeBack,
        onSwipeForward: onSwipeForward,
      ),
    );
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(child);
    await tester.pumpAndSettle();
  }

  double drawerLeft(WidgetTester tester) =>
      tester.getTopLeft(find.byKey(const ValueKey('drawer'))).dx;

  testWidgets('a drag from the edge pulls the drawer out', (tester) async {
    final log = <String>[];
    await pump(tester, host(log: log));

    expect(drawerLeft(tester), -drawerWidth);

    await tester.timedDragFrom(
      const Offset(6, 400),
      const Offset(240, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();

    expect(drawerLeft(tester), 0);
    expect(log, ['drawer:open']);
  });

  testWidgets('a drag from the middle navigates instead', (tester) async {
    final log = <String>[];
    await pump(
      tester,
      host(
        log: log,
        onSwipeBack: () => log.add('back'),
        onSwipeForward: () => log.add('forward'),
      ),
    );

    await tester.timedDragFrom(
      const Offset(210, 400),
      const Offset(150, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(log, ['back']);
    expect(drawerLeft(tester), -drawerWidth, reason: 'drawer stayed shut');

    await tester.timedDragFrom(
      const Offset(210, 400),
      const Offset(-150, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(log, ['back', 'forward']);
  });

  testWidgets('an open drawer takes the drag back off the navigation',
      (tester) async {
    final log = <String>[];
    await pump(
      tester,
      host(
        log: log,
        open: true,
        onSwipeBack: () => log.add('back'),
        onSwipeForward: () => log.add('forward'),
      ),
    );
    expect(drawerLeft(tester), 0);

    await tester.timedDragFrom(
      const Offset(200, 400),
      const Offset(-150, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();

    // Closed, and *not* read as "go forward" on the way.
    expect(drawerLeft(tester), -drawerWidth);
    expect(log, ['drawer:closed']);
  });

  testWidgets('a short drag settles back where it started', (tester) async {
    final log = <String>[];
    await pump(
      tester,
      host(log: log, onSwipeBack: () => log.add('back')),
    );

    // Past the touch slop but short of the threshold, and slow enough not to
    // count as a fling.
    await tester.timedDragFrom(
      const Offset(210, 400),
      const Offset(40, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();

    expect(log, isEmpty);
    expect(drawerLeft(tester), -drawerWidth);
  });

  testWidgets('navigation swipes are off where they mean nothing',
      (tester) async {
    final log = <String>[];
    await pump(
      tester,
      host(
        log: log,
        swipeNavigation: false,
        onSwipeBack: () => log.add('back'),
      ),
    );

    await tester.timedDragFrom(
      const Offset(210, 400),
      const Offset(200, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();

    expect(log, isEmpty);
    // The edge drag still works: only the page-turning half is off.
    await tester.timedDragFrom(
      const Offset(6, 400),
      const Offset(240, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(drawerLeft(tester), 0);
  });

  testWidgets('tapping the scrim shuts the drawer', (tester) async {
    final log = <String>[];
    await pump(tester, host(log: log, open: true));

    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();

    expect(log, ['drawer:closed']);
    expect(drawerLeft(tester), -drawerWidth);
  });
}

/// Owns the open/closed flag the way the home screen does, so the shell is
/// driven the same way in the test as it is in the app.
class _ShellHost extends StatefulWidget {
  const _ShellHost({
    required this.open,
    required this.swipeNavigation,
    required this.log,
    this.onSwipeBack,
    this.onSwipeForward,
  });

  final bool open;
  final bool swipeNavigation;
  final List<String> log;
  final VoidCallback? onSwipeBack;
  final VoidCallback? onSwipeForward;

  @override
  State<_ShellHost> createState() => _ShellHostState();
}

class _ShellHostState extends State<_ShellHost> {
  late bool _open = widget.open;

  @override
  Widget build(BuildContext context) {
    return MobileShell(
      drawerWidth: 260,
      drawerOpen: _open,
      onDrawerOpenChanged: (open) {
        widget.log.add(open ? 'drawer:open' : 'drawer:closed');
        setState(() => _open = open);
      },
      swipeNavigation: widget.swipeNavigation,
      onSwipeBack: widget.onSwipeBack,
      onSwipeForward: widget.onSwipeForward,
      drawer: const ColoredBox(
        key: ValueKey('drawer'),
        color: Color(0xFF202020),
      ),
      child: const ColoredBox(color: Color(0xFFF0F0F0)),
    );
  }
}
