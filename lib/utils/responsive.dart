import 'package:flutter/widgets.dart';

/// Width below which the app switches from the desktop 3-pane layout to a
/// phone-style compact layout (bottom tab bar + slide-in sidebar drawer).
const double kCompactBreakpoint = 750;

bool isCompactWidth(double width) => width < kCompactBreakpoint;

bool isCompact(BuildContext context) =>
    isCompactWidth(MediaQuery.sizeOf(context).width);

/// Smallest slice of the content area left visible above the terminal panel.
const double kMinContentHeight = 72;

/// Terminal-panel height that still fits inside [available].
///
/// The panel is a fixed-height child of a Column, so it cannot shrink on its
/// own: a short window — or a window shrunk after the user dragged the panel
/// tall — pushed the Column past the viewport and overflowed the whole layout.
/// Clamping at paint time also means the stored drag height survives a resize
/// and comes back when there is room for it again.
double clampTerminalHeight(double requested, double available) {
  if (!available.isFinite) return requested;
  final ceiling = available - kMinContentHeight;
  // Nothing sensible left to reserve — hand the panel whatever there is rather
  // than overflow by the difference.
  if (ceiling <= 0) return available.clamp(0.0, requested);
  return requested.clamp(0.0, ceiling);
}
