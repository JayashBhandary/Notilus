import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show DefaultMaterialLocalizations, ThemeMode;
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'providers/browser_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/copy_jobs_provider.dart';
import 'providers/file_ops_provider.dart';
import 'providers/media_provider.dart';
import 'providers/search_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/transfer_controller.dart';
import 'providers/workflow_provider.dart';
import 'screens/home_screen.dart';
import 'services/file_service.dart';
import 'services/remote/transfer_engine.dart';
import 'services/settings_store.dart';
import 'theme.dart';
import 'widgets/transfer_request_gate.dart';

class NotilusApp extends StatelessWidget {
  const NotilusApp({super.key});

  @override
  Widget build(BuildContext context) {
    final fileService = FileService();
    final settingsStore = SettingsStore();
    // Copy jobs are shared: the engine writes progress into them and the HUD
    // reads it, so both sides have to see the same object.
    final copyJobs = CopyJobs();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider<CopyJobs>.value(value: copyJobs),
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(settingsStore)..load(),
        ),
        ChangeNotifierProvider(
          create: (_) => BrowserProvider(fileService)..init(),
        ),
        ChangeNotifierProvider(
          create: (_) => FileOpsProvider(
            engine: TransferEngine(jobs: copyJobs),
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => SearchProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              MediaProvider(fileService: fileService, store: settingsStore)
                ..init(),
        ),
        ChangeNotifierProvider(
          create: (_) => ChatProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => WorkflowProvider(settingsStore, fileService)..load(),
        ),
        ChangeNotifierProvider(
          create: (_) => TransferController(),
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

    // Shad wraps Cupertino rather than replacing it: `ShadApp.custom` supplies
    // the ShadTheme every Shad* widget needs, while the inner CupertinoApp
    // keeps the not-yet-migrated Cupertino widgets working. Brightness stays
    // driven by SettingsProvider — themeMode is derived from the already
    // resolved value so there is still one source of truth.
    return ShadApp.custom(
      theme: AppTheme.shadThemeFor(Brightness.light),
      darkTheme: AppTheme.shadThemeFor(Brightness.dark),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      appBuilder: (shadContext) => CupertinoApp(
        title: 'Notilus',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(brightness),
        localizationsDelegates: const [
          GlobalShadLocalizations.delegate,
          DefaultMaterialLocalizations.delegate,
          DefaultCupertinoLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        builder: (_, child) => ShadAppBuilder(child: child!),
        home: const TransferRequestGate(child: HomeScreen()),
      ),
    );
  }
}
