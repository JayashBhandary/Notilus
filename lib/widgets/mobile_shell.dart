import 'package:flutter/widgets.dart';

/// How far in from the left edge a drag has to start to be taken as "open the
/// drawer" rather than "go back".
///
/// Matches the platform back-gesture strip on both phone OSes: wide enough to
/// hit without aiming, narrow enough that a swipe over the listing is still a
/// navigation swipe.
const double kEdgeSwipeWidth = 24;

/// Distance a horizontal swipe has to cover before it counts as navigation.
const double _kNavSwipeThreshold = 64;

/// Speed (px/s) that counts as a fling, so a short fast flick still lands.
const double _kFlingVelocity = 350;

/// Fraction of the drawer that has to be pulled out for a slow drag to settle
/// open rather than snapping back.
const double _kDrawerSettle = 0.5;

/// The phone shell: a slide-in sidebar plus the horizontal swipes that drive
/// browsing on a touchscreen.
///
/// Both live in one widget because both are the same gesture. A single
/// horizontal-drag recognizer at the top of the tree decides what a drag means
/// from where it started and what is already on screen — drawer first, then
/// navigation — which is what keeps them from fighting each other in the
/// gesture arena. Two nested recognizers would not: the inner one always wins,
/// so an edge drag would never reach the drawer.
///
/// [child] is the whole screen, drawn full-bleed. The drawer slides over it
/// rather than pushing it, which is what both phone platforms do.
class MobileShell extends StatefulWidget {
  const MobileShell({
    super.key,
    required this.drawerWidth,
    required this.drawerOpen,
    required this.onDrawerOpenChanged,
    required this.drawer,
    required this.child,
    this.onSwipeBack,
    this.onSwipeForward,
    this.swipeNavigation = true,
  });

  /// How wide the drawer is when fully open.
  final double drawerWidth;

  /// Whether the drawer should be open. Driven from the screen's state so the
  /// menu button and the swipe agree on one source of truth.
  final bool drawerOpen;
  final ValueChanged<bool> onDrawerOpenChanged;

  final Widget drawer;
  final Widget child;

  /// Swipe right (away from the left edge) — usually "go back", falling back to
  /// "go up" when there is no history. Null disables the gesture.
  final VoidCallback? onSwipeBack;

  /// Swipe left — "go forward". Null disables the gesture.
  final VoidCallback? onSwipeForward;

  /// Whether navigation swipes apply at all. False on pages that aren't the
  /// file browser, where a horizontal swipe means nothing.
  final bool swipeNavigation;

  @override
  State<MobileShell> createState() => _MobileShellState();
}

/// What a drag that is already in flight is doing.
enum _DragMode { drawer, navigate, none }

class _MobileShellState extends State<MobileShell>
    with SingleTickerProviderStateMixin {
  /// 0 = closed, 1 = open. Driven directly by the finger mid-drag and animated
  /// on release, so the drawer tracks the gesture instead of snapping.
  late final AnimationController _drawer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
    value: widget.drawerOpen ? 1 : 0,
  );

  _DragMode _mode = _DragMode.none;
  double _navDx = 0;

  /// Where the finger first touched down.
  ///
  /// Not where the drag *starts*: a horizontal drag isn't recognised until the
  /// touch slop is crossed, so `onHorizontalDragStart` reports a point ~18px
  /// along — which is past the edge strip, and turned every edge swipe into a
  /// back swipe.
  double _downX = 0;

  @override
  void didUpdateWidget(MobileShell old) {
    super.didUpdateWidget(old);
    if (widget.drawerOpen == old.drawerOpen) return;
    // A tap on the menu button (or on the scrim) changes the flag; the
    // animation follows it. A drag moves the animation and reports the result,
    // so this is a no-op for gestures.
    if (widget.drawerOpen) {
      _drawer.forward();
    } else {
      _drawer.reverse();
    }
  }

  @override
  void dispose() {
    _drawer.dispose();
    super.dispose();
  }

  bool get _navEnabled =>
      widget.swipeNavigation &&
      (widget.onSwipeBack != null || widget.onSwipeForward != null);

  void _onDragDown(DragDownDetails d) => _downX = d.globalPosition.dx;

  void _onDragStart(DragStartDetails d) {
    _navDx = 0;
    final fromEdge = _downX <= kEdgeSwipeWidth;
    // An open drawer owns every horizontal drag: the only thing left to do
    // with one is push it back.
    if (_drawer.value > 0 || fromEdge) {
      _mode = _DragMode.drawer;
      return;
    }
    _mode = _navEnabled ? _DragMode.navigate : _DragMode.none;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    switch (_mode) {
      case _DragMode.drawer:
        _drawer.value += d.primaryDelta! / widget.drawerWidth;
      case _DragMode.navigate:
        _navDx += d.primaryDelta ?? 0;
      case _DragMode.none:
        break;
    }
  }

  void _onDragEnd(DragEndDetails d) {
    final velocity = d.velocity.pixelsPerSecond.dx;
    switch (_mode) {
      case _DragMode.drawer:
        _settleDrawer(velocity);
      case _DragMode.navigate:
        _settleNavigation(velocity);
      case _DragMode.none:
        break;
    }
    _mode = _DragMode.none;
  }

  void _onDragCancel() {
    if (_mode == _DragMode.drawer) _settleDrawer(0);
    _mode = _DragMode.none;
  }

  void _settleDrawer(double velocity) {
    // A fling decides on its own, whichever way it was heading; a slow drag
    // goes wherever it got past halfway.
    final open = velocity.abs() > _kFlingVelocity
        ? velocity > 0
        : _drawer.value > _kDrawerSettle;
    if (open) {
      _drawer.forward();
    } else {
      _drawer.reverse();
    }
    if (open != widget.drawerOpen) widget.onDrawerOpenChanged(open);
  }

  void _settleNavigation(double velocity) {
    final travelled = _navDx.abs() >= _kNavSwipeThreshold;
    final flung = velocity.abs() > _kFlingVelocity;
    if (!travelled && !flung) return;
    // Direction comes from the distance covered, not the parting velocity: a
    // drag that doubles back should not fire the gesture it ended up pointing.
    if (_navDx > 0) {
      widget.onSwipeBack?.call();
    } else {
      widget.onSwipeForward?.call();
    }
  }

  void _close() => widget.onDrawerOpenChanged(false);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Drags only: taps, long-presses and vertical scrolling belong to
      // whatever is underneath, and are never claimed here.
      behavior: HitTestBehavior.translucent,
      onHorizontalDragDown: _onDragDown,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _onDragCancel,
      child: AnimatedBuilder(
        animation: _drawer,
        builder: (context, _) {
          final f = _drawer.value.clamp(0.0, 1.0);
          return Stack(
            children: [
              Positioned.fill(child: widget.child),
              if (f > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    // Nothing to dismiss until it is actually open, and a
                    // scrim that swallowed taps mid-drag would eat the tap
                    // that follows a flick-closed.
                    ignoring: f < 0.05,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _close,
                      child: ColoredBox(
                        color: Color.fromRGBO(0, 0, 0, 0.4 * f),
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: 0,
                bottom: 0,
                left: -widget.drawerWidth * (1 - f),
                width: widget.drawerWidth,
                child: widget.drawer,
              ),
            ],
          );
        },
      ),
    );
  }
}
