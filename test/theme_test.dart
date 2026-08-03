import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/theme.dart';

void main() {
  // Regression: a nav-bar → nav-bar push transition lerps the title into the
  // back-button label. If navTitleTextStyle and navActionTextStyle disagree on
  // `inherit`, TextStyle.lerp throws "Failed to interpolate TextStyles with
  // different inherit values."
  for (final brightness in Brightness.values) {
    test('nav text styles interpolate cleanly ($brightness)', () {
      final textTheme = AppTheme.themeFor(brightness).textTheme;
      final title = textTheme.navTitleTextStyle;
      final action = textTheme.navActionTextStyle;

      expect(title.inherit, action.inherit,
          reason: 'title and back-label must share an inherit value');
      expect(
        () => TextStyle.lerp(title, action, 0.5),
        returnsNormally,
      );
    });
  }

  // Regression: ShadCheckbox is 16px and inherits the theme's global `radius`.
  // At the app's radius of 8 that rounds it into a circle, so it reads as a
  // radio button — wrong for the multi-select lists that use it.
  for (final brightness in Brightness.values) {
    test('checkbox radius stays square-ish ($brightness)', () {
      final theme = AppTheme.shadThemeFor(brightness);
      final radius = theme.checkboxTheme.decoration?.border?.radius;

      expect(radius, isInstanceOf<BorderRadius>(),
          reason: 'checkboxTheme must pin its own radius, not inherit radius');
      final size = theme.checkboxTheme.size ?? 16;
      expect(
        (radius! as BorderRadius).topLeft.x,
        lessThan(size / 2),
        reason: 'a radius of half the box size or more renders as a circle',
      );
    });
  }

  test('theme radius alone would round a checkbox into a circle', () {
    // Documents *why* the override above exists: if someone deletes it, the
    // inherited value is the failure mode, not a harmless default.
    final theme = AppTheme.shadThemeFor(Brightness.light);
    expect(theme.radius.topLeft.x, greaterThanOrEqualTo(8));
  });
}
