import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/browser_provider.dart';
import '../theme.dart';

/// Shared state for rubber-band (marquee) selection, provided to the file
/// views and to each selectable item. It owns the scroll controller for the
/// active list/grid and a registry of the currently-built items so the
/// [MarqueeSelectionLayer] can hit-test their render boxes.
///
/// On desktop the list/grid runs with [NeverScrollableScrollPhysics] (see
/// [enabled]); the layer scrolls it manually — via the wheel handler and the
/// auto-scroll timer — so a drag never fights the scroll gesture. On touch
/// layouts [enabled] is false and everything falls back to normal scrolling.
class MarqueeController {
  final ScrollController scroll = ScrollController();

  /// True on desktop widths, where marquee + Shift selection are active.
  bool enabled = false;

  // path -> the element context of the item currently rendered for it. Only
  // built (on-screen) items are present; ListView/GridView recycle the rest.
  final Map<String, BuildContext> _items = {};

  void register(String path, BuildContext ctx) {
    _items[path] = ctx;
  }

  void unregister(String path, BuildContext ctx) {
    // Guard against clobbering after an element was recycled to a new path.
    if (_items[path] == ctx) _items.remove(path);
  }

  void dispose() => scroll.dispose();
}

class MarqueeSelectionLayer extends StatefulWidget {
  const MarqueeSelectionLayer({
    super.key,
    required this.controller,
    required this.child,
  });

  final MarqueeController controller;
  final Widget child;

  @override
  State<MarqueeSelectionLayer> createState() => _MarqueeSelectionLayerState();
}

class _MarqueeSelectionLayerState extends State<MarqueeSelectionLayer> {
  // Drag anchor in *content* space (viewport point + scroll offset at start),
  // so the box stays put over the content while we auto-scroll.
  Offset? _startContent;
  Offset _currentLocal = Offset.zero; // current pointer, viewport-local
  bool _dragging = false;

  // Selection to preserve when the drag is additive (Shift/Cmd/Ctrl held).
  Set<String> _base = {};
  // Paths currently inside the box. Kept across frames so items that scroll
  // out of view (and stop being hit-testable) retain their membership.
  final Set<String> _hits = {};

  Timer? _autoScroll;
  double _autoDir = 0; // -1 up, +1 down, 0 idle
  double _autoSpeed = 0;

  static const double _edgeZone = 48;
  static const double _startSlop = 4;

  MarqueeController get _c => widget.controller;

  double get _offset => _c.scroll.hasClients ? _c.scroll.offset : 0;

  RenderBox? get _layerBox {
    final ro = context.findRenderObject();
    return ro is RenderBox && ro.attached ? ro : null;
  }

  @override
  void dispose() {
    _autoScroll?.cancel();
    super.dispose();
  }

  bool get _additive =>
      HardwareKeyboard.instance.isShiftPressed ||
      HardwareKeyboard.instance.isMetaPressed ||
      HardwareKeyboard.instance.isControlPressed;

  void _onPanStart(DragStartDetails d) {
    final browser = context.read<BrowserProvider>();
    _base = _additive ? Set<String>.from(browser.selectedPaths) : <String>{};
    _hits.clear();
    _currentLocal = d.localPosition;
    _startContent = Offset(d.localPosition.dx, d.localPosition.dy + _offset);
    _dragging = true;
    // Don't clear the selection yet: wait until the drag actually moves past a
    // small slop, so a click that happens to register as a 0px pan (over empty
    // space) doesn't wipe the selection out from under a following tap.
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (!_dragging || _startContent == null) return;
    _currentLocal = d.localPosition;
    final moved = (Offset(_currentLocal.dx, _currentLocal.dy + _offset) -
                _startContent!)
            .distance >
        _startSlop;
    if (moved) {
      _recompute();
      _maybeAutoScroll();
    }
    setState(() {});
  }

  void _onPanDone() {
    _stopAuto();
    if (!_dragging) return;
    _dragging = false;
    _startContent = null;
    setState(() {});
  }

  void _recompute() {
    final layer = _layerBox;
    if (layer == null || _startContent == null) return;
    final offset = _offset;
    final current = Offset(_currentLocal.dx, _currentLocal.dy + offset);
    final box = Rect.fromPoints(_startContent!, current);
    _c._items.forEach((path, ctx) {
      final ro = ctx.findRenderObject();
      if (ro is! RenderBox || !ro.attached) return;
      final topLeft = ro.localToGlobal(Offset.zero, ancestor: layer);
      final rect = (topLeft & ro.size).translate(0, offset); // content coords
      if (box.overlaps(rect)) {
        _hits.add(path);
      } else {
        _hits.remove(path);
      }
    });
    context.read<BrowserProvider>().replaceSelection({..._base, ..._hits});
  }

  // ── Auto-scroll while the pointer sits near a vertical edge ──────────────
  void _maybeAutoScroll() {
    final layer = _layerBox;
    if (layer == null) {
      _stopAuto();
      return;
    }
    final h = layer.size.height;
    if (_currentLocal.dy < _edgeZone) {
      _autoDir = -1;
      _autoSpeed = _speedFor(_edgeZone - _currentLocal.dy);
    } else if (_currentLocal.dy > h - _edgeZone) {
      _autoDir = 1;
      _autoSpeed = _speedFor(_currentLocal.dy - (h - _edgeZone));
    } else {
      _stopAuto();
      return;
    }
    _autoScroll ??=
        Timer.periodic(const Duration(milliseconds: 16), (_) => _autoTick());
  }

  double _speedFor(double depth) =>
      (depth.clamp(0, _edgeZone) / _edgeZone) * 20 + 4; // 4..24 px/tick

  void _autoTick() {
    if (!mounted || !_dragging || _autoDir == 0 || !_c.scroll.hasClients) {
      return;
    }
    final max = _c.scroll.position.maxScrollExtent;
    final target = (_c.scroll.offset + _autoDir * _autoSpeed).clamp(0.0, max);
    if (target == _c.scroll.offset) return;
    _c.scroll.jumpTo(target);
    _recompute(); // pointer stationary, but the box grows as content scrolls
    setState(() {});
  }

  void _stopAuto() {
    _autoScroll?.cancel();
    _autoScroll = null;
    _autoDir = 0;
  }

  // ── Manual wheel / trackpad scrolling (drag-scroll is disabled) ──────────
  void _scrollBy(double dy) {
    if (!_c.scroll.hasClients) return;
    final max = _c.scroll.position.maxScrollExtent;
    final target = (_c.scroll.offset + dy).clamp(0.0, max);
    if (target != _c.scroll.offset) _c.scroll.jumpTo(target);
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) _scrollBy(e.scrollDelta.dy);
  }

  // macOS trackpad two-finger scroll arrives as pan-zoom, not a scroll signal.
  void _onPanZoom(PointerPanZoomUpdateEvent e) => _scrollBy(-e.panDelta.dy);

  Rect _overlayRect() {
    final start = Offset(_startContent!.dx, _startContent!.dy - _offset);
    return Rect.fromPoints(start, _currentLocal);
  }

  @override
  Widget build(BuildContext context) {
    if (!_c.enabled) return widget.child; // touch layout: normal scrolling

    final palette = AppColors.of(context);
    return Listener(
      onPointerSignal: _onSignal,
      onPointerPanZoomUpdate: _onPanZoom,
      child: GestureDetector(
        // translucent: capture pans over empty space while still letting item
        // taps / double-taps through to their own detectors.
        behavior: HitTestBehavior.translucent,
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: (_) => _onPanDone(),
        onPanCancel: _onPanDone,
        child: Stack(
          children: [
            widget.child,
            if (_dragging && _startContent != null)
              Positioned.fromRect(
                rect: _overlayRect(),
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: palette.accent.withValues(alpha: 0.12),
                      border: Border.all(
                        color: palette.accent.withValues(alpha: 0.7),
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Mixin-free helper so both `_FileRow` and `_IconTile` register themselves
/// with the [MarqueeController] the same way. Call [marqueeRegister] from
/// `build` and [marqueeUnregister] from `dispose`.
mixin MarqueeItemRegistration<T extends StatefulWidget> on State<T> {
  MarqueeController? _marqueeCtrl;
  String? _regPath;

  /// The item's current path — subclasses return their entry path.
  String get marqueePath;

  void marqueeRegister() {
    _marqueeCtrl ??= context.read<MarqueeController>();
    final path = marqueePath;
    if (_regPath == path) return;
    if (_regPath != null) _marqueeCtrl!.unregister(_regPath!, context);
    _marqueeCtrl!.register(path, context);
    _regPath = path;
  }

  void marqueeUnregister() {
    if (_regPath != null) {
      _marqueeCtrl?.unregister(_regPath!, context);
      _regPath = null;
    }
  }
}
