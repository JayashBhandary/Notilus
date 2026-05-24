import 'package:flutter/widgets.dart';

/// Width below which the app switches from the desktop 3-pane layout to a
/// phone-style compact layout (bottom tab bar + slide-in sidebar drawer).
const double kCompactBreakpoint = 750;

bool isCompactWidth(double width) => width < kCompactBreakpoint;

bool isCompact(BuildContext context) =>
    isCompactWidth(MediaQuery.sizeOf(context).width);
