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
}
