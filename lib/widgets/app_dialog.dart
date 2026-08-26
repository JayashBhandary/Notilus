import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../utils/platform.dart';

/// The gap between a dialog and the edge of the screen.
///
/// A dialog wider than the window — which on a phone is most of them, since
/// several pass a `maxWidth` of 380–480 — otherwise sits corner to corner with
/// nothing between it and the screen edge, and the rounded corners it does have
/// land on the corners of the display where they read as nothing at all. Larger
/// on a phone: a desktop window has a whole desktop behind it, a phone has only
/// this much room to show that there is something behind the dialog.
double get _screenMargin => isMobilePlatform ? 16 : 24;

/// Shows a dialog inset from the edges of the screen.
///
/// The inset can't come from the dialog: nothing in `ShadDialogTheme` insets one
/// (`padding` is inside the box), and a theme-level `maxWidth` would be ignored
/// by the several call sites that pass constraints of their own. So the margin
/// is applied here, around whatever [builder] returns, and every dialog in the
/// app opens through this rather than `showShadDialog` directly.
///
/// The safe-area inset is part of that margin, which is why the dialog theme
/// turns `useSafeArea` off — inside the box it padded the *content* away from a
/// notch the box itself was already under.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color barrierColor = const Color(0xcc000000),
  String barrierLabel = '',

  /// Set false to open with no transition — worth it for a dialog opened often
  /// enough that animating the barrier and the card every time is wasted work.
  bool animated = true,
}) {
  return showShadDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    animateIn: animated ? null : const [],
    animateOut: animated ? null : const [],
    builder: (ctx) => DialogInset(child: builder(ctx)),
  );
}

/// Holds a dialog clear of the screen edges, and of anything the OS draws over
/// them.
class DialogInset extends StatelessWidget {
  const DialogInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final margin = _screenMargin;
    // Per edge, whichever is larger: the app's own margin or the room the OS
    // needs for a notch or a home indicator. Adding them would push a tall
    // dialog needlessly far up the screen on a phone.
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _atLeast(safe.left, margin),
        _atLeast(safe.top, margin),
        _atLeast(safe.right, margin),
        _atLeast(safe.bottom, margin),
      ),
      child: child,
    );
  }

  static double _atLeast(double inset, double margin) =>
      inset > margin ? inset : margin;
}
