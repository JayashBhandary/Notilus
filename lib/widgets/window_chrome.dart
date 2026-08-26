import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../utils/platform.dart';

// ──────────────────────────────────────────────────────────────────────────
// Window chrome
//
// The app's 48px toolbar *is* the title bar on every desktop platform: the OS
// caption is hidden and the toolbar carries the window controls. What differs
// per platform is only where those controls come from.
//
//   macOS    AppKit keeps drawing the traffic lights over the full-size
//            content view, so the app leaves a gap for them and draws nothing.
//   Windows  The caption is hidden by window_manager, so the app draws its own
//   Linux    minimise / maximise / close at the trailing edge.
//
// Dragging is deliberately narrow. macOS used to set
// `isMovableByWindowBackground = true`, which made *every* pixel a drag handle
// — a scrollbar could not be dragged because the window moved instead. Only
// the empty parts of the toolbar move the window now.
// ──────────────────────────────────────────────────────────────────────────

/// Who draws the minimise / maximise / close controls.
enum WindowButtons {
  /// The OS draws them over the content; leave room and draw nothing.
  native,

  /// The app draws them itself, at the trailing edge of the toolbar.
  drawn,

  /// Not a desktop window — no chrome at all.
  none,
}

WindowButtons _forPlatform() {
  if (kIsWeb) return WindowButtons.none;
  // A phone has no window to close, and drawing three window buttons into a
  // 375px top bar is what pushes it past its own width.
  if (isMobilePlatform) return WindowButtons.none;
  if (Platform.isMacOS) return WindowButtons.native;
  if (Platform.isWindows || Platform.isLinux) return WindowButtons.drawn;
  return WindowButtons.none;
}

WindowButtons? _debugButtons;

/// How this platform's window buttons are provided.
WindowButtons get windowButtons => _debugButtons ?? _forPlatform();

/// Test hook: pretend to be another platform's chrome. Pass null to restore.
@visibleForTesting
set debugWindowButtons(WindowButtons? value) => _debugButtons = value;

/// Whether this build runs in a real desktop window at all.
bool get hasDesktopWindow => windowButtons != WindowButtons.none;

/// Horizontal space AppKit's traffic lights need, plus breathing room.
///
/// Only relevant to whichever widget sits at the window's leading edge — with
/// the sidebar open that is the sidebar, which reserves the space vertically
/// instead.
const double kTrafficLightInset = 78;

/// Leading inset for a bar that sits flush against the window's left edge.
double windowLeadingInset({required bool atWindowEdge}) =>
    windowButtons == WindowButtons.native && atWindowEdge
        ? kTrafficLightInset
        : 0;

// ──────────────────────────────────────────────────────────────────────────
// Actions
// ──────────────────────────────────────────────────────────────────────────

/// The window operations the chrome performs.
///
/// Behind a seam so widget tests can press the buttons and assert what was
/// asked for, without a platform plugin on the other end.
abstract class WindowActions {
  Future<void> startDragging();
  Future<void> toggleMaximize();
  Future<void> minimize();
  Future<void> close();

  static WindowActions instance = const _PluginWindowActions();

  @visibleForTesting
  static void debugReplace(WindowActions actions) => instance = actions;

  @visibleForTesting
  static void debugReset() => instance = const _PluginWindowActions();
}

class _PluginWindowActions implements WindowActions {
  const _PluginWindowActions();

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<void> close() => windowManager.close();

  @override
  Future<void> toggleMaximize() async {
    // maximize/unmaximize map to zoom on macOS, which is what double-clicking
    // a title bar does there.
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Drag region
// ──────────────────────────────────────────────────────────────────────────

/// Makes empty toolbar space behave like a title bar: drag to move,
/// double-click to maximise or zoom.
///
/// Meant to be the *bottom* layer of a [Stack] whose upper layer holds the
/// toolbar's controls, so buttons, breadcrumbs and text fields hit-test first
/// and only the gaps between them move the window. Nothing outside the toolbar
/// is ever a drag handle — that is what keeps scrollbars draggable.
class WindowDragRegion extends StatefulWidget {
  const WindowDragRegion({super.key, this.enableDoubleClick = true});

  /// Double-click to maximise/restore, following the OS convention.
  final bool enableDoubleClick;

  @override
  State<WindowDragRegion> createState() => _WindowDragRegionState();
}

class _WindowDragRegionState extends State<WindowDragRegion> {
  Offset? _downAt;
  bool _dragging = false;

  /// How far the pointer must travel before this becomes a window drag.
  ///
  /// A plain click must not start one. A lone pan recognizer wins its gesture
  /// arena unopposed and fires on a click that never moved, which would both
  /// begin a pointless drag session and race the double-click handler — so the
  /// movement test is done directly rather than through a recognizer.
  /// Mouse-sized rather than [kTouchSlop], which is tuned for fingers.
  static const double _dragSlop = 3;

  void _onDown(PointerDownEvent event) {
    _downAt = event.position;
    _dragging = false;
  }

  void _onMove(PointerMoveEvent event) {
    final start = _downAt;
    if (_dragging || start == null) return;
    if ((event.position - start).distance < _dragSlop) return;
    _dragging = true;
    WindowActions.instance.startDragging();
  }

  void _end() {
    _downAt = null;
    _dragging = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!hasDesktopWindow) return const SizedBox.shrink();
    return Listener(
      // Opaque so the gaps in the toolbar are hit targets at all; the controls
      // sit above this layer and are tested first.
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: (_) => _end(),
      onPointerCancel: (_) => _end(),
      // A Listener takes no part in the gesture arena, so the double-tap
      // recognizer below is free to work alongside it.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: widget.enableDoubleClick
            ? () => WindowActions.instance.toggleMaximize()
            : null,
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Turns a bar that spans the top of the window into the window's title bar:
/// drag to move, double-click to maximise, and room left for the buttons the
/// OS draws over the content.
///
/// Every surface that fills the window needs this, not only the main toolbar.
/// A preview or an editor pushed over the whole window *is* the top of the
/// window while it is open, and without this the window cannot be moved from
/// that page at all and its leading control sits under the macOS traffic
/// lights.
///
/// [child] keeps its own internal padding; the traffic-light gap is applied
/// outside it.
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({
    super.key,
    required this.child,
    this.atWindowEdge = true,
  });

  final Widget child;

  /// Whether this bar starts at the window's leading edge. Pass false when
  /// something else — the sidebar — already reserves that space.
  final bool atWindowEdge;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Underneath, so the bar's own controls hit-test first and only the
        // gaps between them move the window.
        const WindowDragRegion(),
        Padding(
          padding: EdgeInsets.only(
            left: windowLeadingInset(atWindowEdge: atWindowEdge),
          ),
          child: child,
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Buttons
// ──────────────────────────────────────────────────────────────────────────

/// Minimise / maximise / close, for the platforms whose native caption is
/// hidden. Renders nothing where the OS draws its own.
class WindowControls extends StatelessWidget {
  const WindowControls({super.key});

  @override
  Widget build(BuildContext context) {
    if (windowButtons != WindowButtons.drawn) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowButton(
          icon: LucideIcons.minus,
          tooltip: 'Minimize',
          onPressed: () => WindowActions.instance.minimize(),
        ),
        _WindowButton(
          icon: LucideIcons.square,
          tooltip: 'Maximize',
          onPressed: () => WindowActions.instance.toggleMaximize(),
        ),
        _WindowButton(
          icon: LucideIcons.x,
          tooltip: 'Close',
          danger: true,
          onPressed: () => WindowActions.instance.close(),
        ),
      ],
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// Close gets the red hover every desktop uses, rather than the neutral one.
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final hovered = _hover;
    final bg = !hovered
        ? null
        : (widget.danger ? const Color(0xFFE81123) : colors.accent);
    final fg = hovered && widget.danger
        ? const Color(0xFFFFFFFF)
        : colors.mutedForeground;

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: Semantics(
          button: true,
          label: widget.tooltip,
          child: Container(
            // Wider than tall, like every native caption button.
            width: 42,
            height: 36,
            color: bg,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 15, color: fg),
          ),
        ),
      ),
    );
  }
}
