import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show DefaultMaterialLocalizations;
import 'package:provider/provider.dart';

import 'providers/browser_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/workflow_provider.dart';
import 'screens/home_screen.dart';
import 'services/file_service.dart';
import 'services/settings_store.dart';
import 'theme.dart';

class NotilusApp extends StatelessWidget {
  const NotilusApp({super.key});

  @override
  Widget build(BuildContext context) {
    final fileService = FileService();
    final settingsStore = SettingsStore();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(settingsStore)..load(),
        ),
        ChangeNotifierProvider(
          create: (_) => BrowserProvider(fileService)..init(),
        ),
        ChangeNotifierProvider(
          create: (_) => ChatProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => WorkflowProvider(settingsStore, fileService)..load(),
        ),
      ],
      child: const _ThemedApp(),
    );
  }
}

class _ThemedApp extends StatelessWidget {
  const _ThemedApp();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final platformBrightness =
        MediaQuery.platformBrightnessOf(context);
    final brightness = settings.resolveBrightness(platformBrightness);

    return CupertinoApp(
      title: 'Notilus',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(brightness),
      localizationsDelegates: const [
        DefaultMaterialLocalizations.delegate,
        DefaultCupertinoLocalizations.delegate,
        DefaultWidgetsLocalizations.delegate,
      ],
      home: const HomeScreen(),
    );
  }
}
