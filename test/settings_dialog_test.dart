import 'package:flutter/cupertino.dart'
    show CupertinoApp, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart'
    show ThemeMode, DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:notilus/providers/settings_provider.dart';
import 'package:notilus/screens/settings_screen.dart';
import 'package:notilus/services/llm/llm_client.dart';
import 'package:notilus/services/settings_store.dart';
import 'package:notilus/theme.dart';

/// The settings dialog is the first screen migrated from Cupertino to
/// shadcn_ui. Its controls are laid out inside a 460px-wide scrollable dialog,
/// so the failure mode to guard is a render overflow — which surfaces as a
/// pumped-frame exception, not a wrong pixel.
void main() {
  Widget host(Widget child, {Brightness brightness = Brightness.light}) {
    return ShadApp.custom(
      theme: AppTheme.shadThemeFor(Brightness.light),
      darkTheme: AppTheme.shadThemeFor(Brightness.dark),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      // Mirrors app.dart: ShadAppBuilder in `builder`, content in `home`.
      // Content mounted in `builder` would sit above the Navigator, so any
      // showShadDialog call from it would have nothing to push onto.
      appBuilder: (_) => CupertinoApp(
        localizationsDelegates: const [
          GlobalShadLocalizations.delegate,
          DefaultMaterialLocalizations.delegate,
          DefaultCupertinoLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        builder: (_, inner) => ShadAppBuilder(child: inner!),
        home: ChangeNotifierProvider(
          create: (_) => SettingsProvider(SettingsStore()),
          child: child,
        ),
      ),
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets('settings dialog lays out without overflow ($brightness)',
        (tester) async {
      // Wide enough that the 460px dialog is not itself the constraint.
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        host(const SettingsDialog(), brightness: brightness),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('settings dialog renders the migrated shadcn controls',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(const SettingsDialog()));
    await tester.pumpAndSettle();

    expect(find.byType(ShadDialog), findsOneWidget);
    // Appearance + AI Provider segmented controls.
    expect(find.byType(ShadTabs<AppThemeMode>), findsOneWidget);
    expect(find.byType(ShadTabs<LlmProviderKind>), findsOneWidget);
    // Background reception + prefer local network.
    expect(find.byType(ShadSwitch), findsNWidgets(2));
    expect(find.byType(ShadSlider), findsOneWidget);
    expect(find.byType(ShadButton), findsWidgets);
    // Destination + the Ollama host field (Ollama is the default provider).
    expect(find.byType(ShadInput), findsNWidgets(2));
  });

  testWidgets('temperature slider declares no divisions', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(const SettingsDialog()));
    await tester.pumpAndSettle();

    // ShadSlider paints one tick mark per division with no way to suppress
    // them, so 30 divisions renders the track as a barcode. Snapping happens
    // in onChanged instead — see settings_screen.dart.
    final slider = tester.widget<ShadSlider>(find.byType(ShadSlider));
    expect(slider.divisions, isNull);
  });

  testWidgets('switches keep their default (LTR) thumb direction',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(const SettingsDialog()));
    await tester.pumpAndSettle();

    // ShadSwitch applies `direction` to the thumb's own stack as well as to
    // the label row, so rtl parks the thumb on the left while the track still
    // reads as on. The toggle is moved right with an explicit Row instead.
    for (final s in tester.widgetList<ShadSwitch>(find.byType(ShadSwitch))) {
      expect(s.direction, isNot(TextDirection.rtl));
    }
  });

  testWidgets('theme selector reports the tapped mode', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(const SettingsDialog()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    final settings = Provider.of<SettingsProvider>(
      tester.element(find.byType(ShadDialog)),
      listen: false,
    );
    expect(settings.themeMode, AppThemeMode.dark);
  });
}
